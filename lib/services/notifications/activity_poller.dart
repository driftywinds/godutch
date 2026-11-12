import '../../api/spliit_client.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../../models/activity.dart';
import '../../models/group_organization.dart';
import '../error_reporting.dart';
import '../settings_service.dart';
import 'notification_message.dart';
import 'notification_prefs.dart';

/// Reads each group's activity log for what happened since the last look,
/// and posts a notification for it.
///
/// Spliit Cloud has no push to subscribe to, so the audit log is the only
/// feed of "something happened": this is what a phone can know while the app
/// is closed, on the background poll's schedule.
class ActivityPoller {
  ActivityPoller({
    required this.db,
    required this.client,
    required this.sink,
    required this.settings,
    required this.l10n,
    DateTime Function()? now,
    this.maxGroups = 10,
    this.maxPerGroup = 5,
  }) : _now = now ?? DateTime.now;

  final AppDatabase db;
  final SpliitClient client;
  final NotificationSink sink;
  final SettingsService settings;
  final AppLocalizations l10n;
  final DateTime Function() _now;

  /// How many of the group list's most recently opened groups are polled: a
  /// phone in thirty groups shouldn't make thirty requests every 15 minutes.
  final int maxGroups;

  /// The most notifications one group gets in one poll. A busy day reads as
  /// the newest few, not a wall of banners.
  final int maxPerGroup;

  /// How old an event may be and still notify. Older ones only move the
  /// mark, so coming back from a holiday doesn't empty the shade.
  static const window = Duration(hours: 24);

  /// One page is enough for a group's activity between two polls.
  static const pageSize = 20;

  /// Posts what's new and returns how many notifications went out.
  Future<int> poll() async {
    final prefs = await NotificationPrefs.load(settings);
    if (!prefs.enabled) return 0;
    final groups = (await db.allJoinedGroups())
        .where((row) => row.organization != GroupOrganization.archived)
        .take(maxGroups);
    var shown = 0;
    for (final row in groups) {
      try {
        shown += await _pollGroup(row, prefs);
      } on SpliitApiException catch (e, st) {
        // The session is gone: every other group would fail the same way.
        if (e.isUnauthorized) break;
        ErrorReporter.instance.report(e, st, operation: 'Polling group ${row.id}');
      } catch (e, st) {
        ErrorReporter.instance.report(e, st, operation: 'Polling group ${row.id}');
      }
    }
    return shown;
  }

  /// One group's log, since where the last poll got to.
  Future<int> _pollGroup(GroupRow row, NotificationPrefs prefs) async {
    final page = await client.fetchActivities(groupId: row.id, limit: pageSize);
    final markId = row.notificationsCheckedActivityId;
    final markAt = row.notificationsCheckedAt;
    if (markId == null && markAt == null) {
      // Never looked at this group: start from its newest entry rather than
      // ring for everything in the last day, which is what turning
      // notifications on would otherwise do with every group at once.
      if (page.activities.isEmpty) return 0;
      final newest = page.activities.first;
      await db.setNotificationsChecked(row.id,
          activityId: newest.id, at: newest.time);
      return 0;
    }
    // Newest first, the log's own order: stop at the entry the last poll saw.
    final fresh = <Activity>[];
    for (final activity in page.activities) {
      if (activity.id == markId) break;
      if (markAt != null && !activity.time.isAfter(markAt)) break;
      fresh.add(activity);
    }
    if (fresh.isEmpty) return 0;

    final cutoff = _now().subtract(window);
    final worth = <(Activity, NotificationCategory)>[];
    for (final activity in fresh.reversed) {
      // Oldest first, as the shade reads.
      final category = _categoryOf(activity);
      if (category == null || !prefs.allows(category)) continue;
      if (!activity.time.isAfter(cutoff)) continue;
      worth.add((activity, category));
    }
    final newest =
        worth.length > maxPerGroup ? worth.sublist(worth.length - maxPerGroup) : worth;
    for (final (activity, category) in newest) {
      await sink.show(_messageFor(row, activity, category));
    }
    // Even the ones too old to show: the next poll shouldn't see them again.
    await db.setNotificationsChecked(row.id,
        activityId: fresh.first.id, at: fresh.first.time);
    return newest.length;
  }

  /// Which channel an entry belongs in, or null for one not worth a
  /// notification (a renamed group, an invitation sent).
  static NotificationCategory? _categoryOf(Activity activity) {
    switch (activity.wireType) {
      case 'EXPENSE_CREATED':
      case 'CREATE_EXPENSE':
      case 'EXPENSE_UPDATED':
      case 'UPDATE_EXPENSE':
      case 'EXPENSE_DELETED':
      case 'DELETE_EXPENSE':
        return NotificationCategory.expenses;
      case 'EXPENSE_COMMENT_CREATED':
        return NotificationCategory.comments;
      case 'EXPENSE_PAID':
        return NotificationCategory.settlements;
      // Someone accepted an invitation: a new member. One made or revoked
      // is the group's own business, not news.
      case 'INVITATION_ACCEPTED':
        return NotificationCategory.members;
    }
    if (activity.wireType.isNotEmpty) return null;
    // A response that didn't say: fall back to the kind parsed from it.
    return switch (activity.activityType) {
      ActivityType.createExpense ||
      ActivityType.updateExpense ||
      ActivityType.deleteExpense =>
        NotificationCategory.expenses,
      ActivityType.comment => NotificationCategory.comments,
      ActivityType.payment => NotificationCategory.settlements,
      ActivityType.inviteMember => NotificationCategory.members,
      ActivityType.updateGroup || ActivityType.archiveGroup => null,
    };
  }

  NotificationMessage _messageFor(
      GroupRow row, Activity activity, NotificationCategory category) {
    final actor = _actor(activity);
    final what = activity.data?.trim() ?? '';
    final expense = what.isEmpty ? l10n.notificationAnExpense : what;
    final body = switch (activity.activityType) {
      ActivityType.createExpense => l10n.notificationExpenseAdded(actor, expense),
      ActivityType.updateExpense =>
        l10n.notificationExpenseUpdated(actor, expense),
      ActivityType.deleteExpense =>
        l10n.notificationExpenseDeleted(actor, expense),
      ActivityType.payment => l10n.notificationPayment(actor, expense),
      ActivityType.comment => what.isEmpty
          ? l10n.notificationCommented(actor)
          : l10n.notificationComment(actor, what),
      ActivityType.inviteMember => l10n.notificationJoined(actor),
      ActivityType.updateGroup || ActivityType.archiveGroup =>
        l10n.notificationGroupChanged(actor),
    };
    return NotificationMessage(
      // Stable per entry, so a re-post replaces rather than stacks.
      id: activity.id.hashCode & 0x7fffffff,
      category: category,
      title: row.name,
      body: body,
      groupId: row.id,
      expenseId: activity.expenseId,
    );
  }

  /// The name to credit, or "Someone" when the server has none. Anonymous
  /// accounts are named after their placeholder address, which would put
  /// `guest-…@anonymous.placeholder.local` in the shade.
  String _actor(Activity activity) {
    final name = activity.actorName?.trim() ?? '';
    if (name.isEmpty || name.endsWith('@anonymous.placeholder.local')) {
      return l10n.notificationSomeone;
    }
    return name;
  }
}
