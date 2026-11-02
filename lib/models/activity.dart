/// One entry in a group's server-side audit log -- what changed, when,
/// and (if it's still known) who did it. Mirrors Spliit's `Activity`
/// Prisma model and the `groups.activities.list` tRPC response (see
/// SpliitClient.fetchActivities) -- issue #26.
enum ActivityType {
  updateGroup,
  createExpense,
  updateExpense,
  deleteExpense,
  inviteMember,
  comment,
  archiveGroup,
  payment;

  /// The server's wire values. Older Spliit used `UPDATE_GROUP`,
  /// `CREATE_EXPENSE`, …; Spliit Cloud uses `GROUP_UPDATED`,
  /// `EXPENSE_CREATED`, …. Accept both so a cached/older response and the
  /// fork's own names render through the same screen.
  static ActivityType fromWire(String value) {
    switch (value) {
      case 'UPDATE_GROUP':
      case 'GROUP_UPDATED':
        return ActivityType.updateGroup;
      case 'CREATE_EXPENSE':
      case 'EXPENSE_CREATED':
        return ActivityType.createExpense;
      case 'UPDATE_EXPENSE':
      case 'EXPENSE_UPDATED':
        return ActivityType.updateExpense;
      case 'DELETE_EXPENSE':
      case 'EXPENSE_DELETED':
        return ActivityType.deleteExpense;
      case 'GROUP_ARCHIVED':
      case 'GROUP_UNARCHIVED':
        return ActivityType.archiveGroup;
      case 'INVITATION_CREATED':
      case 'INVITATION_ACCEPTED':
      case 'INVITATION_REVOKED':
        return ActivityType.inviteMember;
      case 'EXPENSE_COMMENT_CREATED':
      case 'EXPENSE_COMMENT_DELETED':
        return ActivityType.comment;
      case 'EXPENSE_PAID':
        return ActivityType.payment;
      default:
        // The server may grow new activity types before this app's next
        // release -- fall back to something displayable rather than
        // throwing and losing the whole list over one unrecognized entry.
        return ActivityType.updateGroup;
    }
  }

  static ActivityType fromCloud(String value) => fromWire(value);
}

class Activity {
  final String id;
  final DateTime time;
  final ActivityType activityType;
  final String? participantId;

  /// The actor's display name, captured by the server so it still reads
  /// after an account is deleted (cloud returns `actorName`).
  final String? actorName;
  final String? expenseId;

  /// The expense's title at the time of this activity -- the server
  /// stores it as a free-text snapshot (`Activity.data`), not a live
  /// reference, so it still reads correctly for a since-deleted expense.
  final String? data;

  /// Whether [expenseId] still points at an expense that exists --
  /// false for a deleted expense (or any create/update whose expense
  /// was later deleted). Only ever true when [expenseId] is set.
  /// Mirrors the web app's `activity.expense !== undefined` check,
  /// which gates whether the activity list item is tappable.
  final bool expenseExists;

  const Activity({
    required this.id,
    required this.time,
    required this.activityType,
    this.participantId,
    this.actorName,
    this.expenseId,
    this.data,
    required this.expenseExists,
  });
}
