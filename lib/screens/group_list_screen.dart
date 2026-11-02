import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../api/cloud_connection.dart';
import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/account.dart';
import '../models/group_organization.dart';
import '../services/date_span_calculator.dart';
import '../services/error_reporting.dart';
import '../services/group_list_order.dart';
import '../services/receipt_cache.dart';
import '../services/receipt_downloader.dart';
import '../services/settings_service.dart';
import '../sync/outbox.dart';
import '../theme.dart';
import '../utils/date_format.dart';
import '../utils/haptics.dart';
import '../utils/spoken.dart';
import '../widgets/app_menu.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/caption_icon.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_message.dart';
import '../widgets/group_monogram.dart';
import '../widgets/group_row_actions.dart';
import '../widgets/grouped_section.dart';
import '../widgets/receipt_download_indicator.dart';
import '../widgets/top_bar_buttons.dart';
import 'account_screen.dart';
import 'app_settings_screen.dart';
import 'group_screen.dart';
import 'group_settings_screen.dart';
import 'join_group_screen.dart';
import '../app_name.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Registered as a `MaterialApp.navigatorObservers` entry (main.dart) so
/// the list refreshes when a route pushed on top of it (a group, account,
/// join flow) is popped back.
final RouteObserver<PageRoute<void>> groupListRouteObserver =
    RouteObserver<PageRoute<void>>();

/// The signed-in account's groups -- the app's root once authenticated.
///
/// Spliit Cloud is the source of truth: [client.fetchGroupSummaries] brings
/// every group the account belongs to, and the local database only caches
/// it for offline reading. Favorites are the account's server preference,
/// so they follow the account to another device.
class GroupListScreen extends StatefulWidget {
  const GroupListScreen({
    super.key,
    required this.db,
    this.client,
    this.account,
    this.onAccountChanged,
    this.onSignOut,
    this.settings,
    this.clientFactory,
  });

  final AppDatabase db;
  final SpliitClient? client;
  final CloudAccount? account;
  final ValueChanged<CloudAccount>? onAccountChanged;
  final Future<void> Function()? onSignOut;
  final SettingsService? settings;

  /// Legacy test hook: lets a widget test inject a MockClient-backed
  /// client when it doesn't have a real [CloudAccount].
  final SpliitClient Function(String baseUrl)? clientFactory;

  @override
  State<GroupListScreen> createState() => _GroupListScreenState();
}

class _GroupListScreenState extends State<GroupListScreen> with RouteAware {
  List<GroupRow> _groups = [];
  bool _loading = true;
  GroupListSort _sort = GroupListSort.lastOpened;
  SettingsService get _settings => widget.settings ?? SettingsService();
  int _loadVersion = 0;
  final Map<String, int> _dismissVersions = {};
  Map<String, DateSpan?> _dateSpans = {};
  String? _syncError;
  bool _syncing = false;

  /// The cloud client, or a stand-in for the widget tests that construct
  /// this screen without an account (they only exercise the local cache).
  SpliitClient get _client =>
      widget.client ??
      widget.clientFactory?.call(CloudConnection.defaultBaseUrl) ??
      SpliitClient(baseUrl: CloudConnection.defaultBaseUrl);

  CloudAccount get _account =>
      widget.account ??
      const CloudAccount(id: 'local', name: 'You', email: '');

  Future<void> _signOut() async => widget.onSignOut?.call();
  void _accountChanged(CloudAccount value) => widget.onAccountChanged?.call(value);

  /// The account's Cloud profile picture, or their initial while it loads,
  /// when there isn't one, or if it can't be fetched.
  Widget _accountButtonIcon() {
    final image = _account.image;
    final initial = Text(
      _account.displayName.isEmpty
          ? '?'
          : _account.displayName.characters.first.toUpperCase(),
      style: const TextStyle(fontSize: 12),
    );
    if (image == null || image.trim().isEmpty) {
      return CircleAvatar(radius: 14, child: initial);
    }
    return CircleAvatar(
      radius: 14,
      foregroundImage: NetworkImage(image),
      // The child is the fallback, so a broken or blocked picture still shows
      // the account's initial rather than an empty circle.
      onForegroundImageError: (_, __) {},
      child: initial,
    );
  }

  bool get _syncEnabled => widget.client != null;

  @override
  void initState() {
    super.initState();
    _load();
    if (_syncEnabled) unawaited(_sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) groupListRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    groupListRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _load();
    if (_syncEnabled) unawaited(_sync());
    unawaited(_rememberInGroup(false));
  }

  Future<void> _rememberInGroup(bool inGroup) async {
    try {
      await _settings.setReopenLastGroup(inGroup);
    } catch (e, st) {
      ErrorReporter.instance
          .report(e, st, operation: 'Remembering the last screen');
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final version = ++_loadVersion;
    final sort = groupListSortFromTag(await _settings.groupListSort());
    final rows = await widget.db.allJoinedGroups();
    final spans = <String, DateSpan?>{};
    for (final row in rows) {
      spans[row.id] = computeDateSpan(await widget.db.expensesForGroup(row.id));
    }
    if (!mounted || version != _loadVersion) return;
    setState(() {
      _sort = sort;
      _groups = rows;
      _dateSpans = spans;
      _loading = false;
    });
  }

  /// Pulls the account's groups from Cloud, caches the summaries, applies
  /// the server-backed favorite/archive state, and drops groups the
  /// account is no longer a member of.
  Future<void> _sync() async {
    if (!_syncEnabled || _syncing) return;
    _syncing = true;
    try {
      final summaries = await _client.fetchGroupSummaries();
      final ids = <String>{};
      for (final summary in summaries) {
        final group = summary.group;
        ids.add(group.id);
        await widget.db.cacheGroupSummary(
          group,
          serverUrl: _client.baseUrl,
        );
        await widget.db.setGroupOrganization(
          group.id,
          group.archived
              ? GroupOrganization.archived
              : summary.starred
                  ? GroupOrganization.favorite
                  : GroupOrganization.active,
        );
      }
      for (final row in await widget.db.allJoinedGroups()) {
        if (!ids.contains(row.id)) await widget.db.leaveGroup(row.id);
      }
      if (mounted) setState(() => _syncError = null);
      await _load();
    } on SpliitApiException catch (e, st) {
      if (e.isUnauthorized) {
        await _signOut();
        return;
      }
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Refreshing cloud groups');
      if (!mounted) return;
      setState(() => _syncError = error.kind == ErrorKind.connection
          ? context.l10n.errorConnection
          : context.l10n.groupListSyncFailed);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Refreshing cloud groups');
      if (!mounted) return;
      setState(() => _syncError = error.kind == ErrorKind.connection
          ? context.l10n.errorConnection
          : context.l10n.groupListSyncFailed);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _openGroup(GroupRow row) async {
    await widget.db.recordGroupOpened(row.id, serverUrl: _client.baseUrl);
    final outbox = Outbox(widget.db, _client, groupId: row.id);
    await _rememberInGroup(true);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupScreen(
          client: _client,
          db: widget.db,
          outbox: outbox,
          groupId: row.id,
        ),
      ),
    );
    await _load();
  }

  Future<void> _joinAnother() async {
    final joinedId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => JoinGroupScreen(
          db: widget.db,
          client: _client,
        ),
      ),
    );
    if (joinedId != null) {
      await _load();
      unawaited(_sync());
    }
  }

  Future<void> _createGroup() async {
    final createdId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => GroupSettingsScreen.create(
          db: widget.db,
          client: _client,
        ),
      ),
    );
    if (createdId != null) {
      await _load();
      unawaited(_sync());
    }
  }

  Future<void> _openAccount() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountScreen(
          client: _client,
          account: _account,
          onAccountChanged: _accountChanged,
          onSignOut: _signOut,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Image.asset('assets/godutch/transparent-logo.png',
              width: 32, height: 32, excludeFromSemantics: true),
          const SizedBox(width: 8),
          const Flexible(
              child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(appName,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: spliitWordmarkGreen)))),
        ]),
        actions: [
          TopBarButtons(children: [
            AppMenuButton(
              tooltip: context.l10n.groupListSort,
              icon: const Icon(Icons.sort),
              items: [
                for (final sort in GroupListSort.values)
                  AppMenuItem(
                      label: _sortLabel(sort),
                      checked: sort == _sort,
                      onSelected: () => _setSort(sort)),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: context.l10n.appSettingsTitle,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) =>
                        AppSettingsScreen(receipts: ReceiptCache.of(widget.db))),
              ),
            ),
            IconButton(
              icon: _accountButtonIcon(),
              tooltip: context.l10n.accountTitle,
              onPressed: _openAccount,
            ),
          ]),
        ],
      ),
      body: _body(context),
      floatingActionButton: FloatingActionButton(
        onPressed: _joinAnother,
        tooltip: context.l10n.groupListJoinTooltip,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final syncError = _syncError;
    final banner = syncError == null
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: ErrorMessage(syncError),
          );
    if (_groups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _sync,
        child: EmptyState.logo(
          title: context.l10n.groupListEmpty,
          description: context.l10n.welcomeTagline,
          actions: [
            FilledButton(
                onPressed: _joinAnother,
                child: Text(context.l10n.groupListEmptyJoinButton)),
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: _createGroup,
                child: Text(context.l10n.joinGroupCreateButton)),
          ],
        ),
      );
    }
    final sorted = [..._groups]
      ..sort((a, b) => compareGroupRows(a, b, _sort, _dateSpans));
    final sections = [
      (
        context.l10n.groupListFavorites,
        sorted
            .where((g) => g.organization == GroupOrganization.favorite)
            .toList()
      ),
      (
        context.l10n.groupListActive,
        sorted.where((g) => g.organization == GroupOrganization.active).toList()
      ),
      (
        context.l10n.groupListArchived,
        sorted
            .where((g) => g.organization == GroupOrganization.archived)
            .toList()
      ),
    ];
    return RefreshIndicator(
      onRefresh: _sync,
      child: SlidableAutoCloseBehavior(
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomBarGap(context)),
          child: GroupedScrollClip(
            child: ListView(
              padding: const EdgeInsets.only(top: 16, bottom: 88),
              children: [
                if (banner != null) banner,
                for (final (caption, groups) in sections)
                  if (groups.isNotEmpty) ...[
                    GroupedCaption(caption, margin: GroupedCaption.listMargin),
                    for (var i = 0; i < groups.length; i++)
                      GroupedItem(
                        key: ValueKey(groups[i].id),
                        first: i == 0,
                        last: i == groups.length - 1,
                        dividerIndent: 80,
                        child: _groupTile(groups[i]),
                      ),
                  ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _sortLabel(GroupListSort sort) => switch (sort) {
        GroupListSort.firstExpense => context.l10n.groupListSortFirst,
        GroupListSort.lastExpense => context.l10n.groupListSortLast,
        GroupListSort.created => context.l10n.groupListSortCreated,
        GroupListSort.lastOpened => context.l10n.groupListSortOpened,
      };

  Future<void> _setSort(GroupListSort sort) async {
    try {
      await _settings.setGroupListSort(sort.name);
      if (mounted) await _load();
    } catch (e, st) {
      _showSaveError(e, st, 'Saving the group list sort');
    }
  }

  void _showSaveError(Object e, StackTrace st, String operation) {
    final error = ErrorReporter.instance.report(e, st, operation: operation);
    if (!mounted) return;
    showErrorSnackBar(context, context.l10n.appSettingsSaveError,
        diagnostics: error.diagnostics);
  }

  Future<bool> _confirmRemove(GroupRow row) => showConfirmDialog(context,
      title: context.l10n.groupListLeaveTitle,
      message: [context.l10n.groupListLeaveCloudBody(row.name)],
      action: context.l10n.groupListRemove,
      destructive: true);

  Future<void> _performGroupAction(GroupRow row, String action) async {
    if (!mounted) return;
    _dismissVersions[row.id] = (_dismissVersions[row.id] ?? 0) + 1;
    try {
      switch (action) {
        case 'favorite':
          final favorite = row.organization != GroupOrganization.favorite;
          await _client.setGroupStarred(row.id, favorite);
          await widget.db.setGroupOrganization(
              row.id,
              favorite
                  ? GroupOrganization.favorite
                  : GroupOrganization.active);
          await _favoriteChanged(row, favorite);
        case 'archive':
          final archived = row.organization != GroupOrganization.archived;
          if (archived) {
            try {
              await _client.archiveGroup(row.id, true);
            } on SpliitApiException catch (e) {
              if (!e.isPreconditionFailed || !mounted) rethrow;
              final force = await showConfirmDialog(context,
                  title: context.l10n.groupListArchive,
                  message: [context.l10n.groupListArchiveBalances],
                  action: context.l10n.groupListArchive,
                  destructive: true);
              if (!force) return;
              await _client.archiveGroup(row.id, true, force: true);
            }
          } else {
            await _client.archiveGroup(row.id, false);
          }
          await widget.db.setGroupOrganization(
              row.id,
              archived
                  ? GroupOrganization.archived
                  : GroupOrganization.active);
          if (row.organization == GroupOrganization.favorite && archived) {
            await _favoriteChanged(row, false);
          }
        case 'remove':
          if (!await _confirmRemove(row)) return;
          await _client.leaveGroup(row.id);
          ReceiptDownloader.of(widget.db).removed(row.id);
          await widget.db.leaveGroup(row.id);
          unawaited(Haptics.deleted());
          unawaited(ReceiptCache.of(widget.db).sweep());
      }
    } on SpliitApiException catch (e, st) {
      if (!mounted) return;
      final error =
          ErrorReporter.instance.report(e, st, operation: 'Updating a group');
      showErrorSnackBar(context,
          e.isForbidden ? context.l10n.groupListAdminOnly : e.userMessage,
          diagnostics: error.diagnostics);
    } catch (e, st) {
      _showSaveError(e, st, 'Updating group ${row.id}');
    } finally {
      if (mounted) await _load();
    }
  }

  Future<void> _favoriteChanged(GroupRow row, bool favorite) async {
    final downloads = ReceiptDownloader.of(widget.db);
    if (favorite) {
      unawaited(downloads.run(row.id, _client));
    } else {
      await downloads.unfavorited(row.id);
    }
  }

  String _sortDateText(GroupRow row) {
    final date = groupSortDate(row, _sort, _dateSpans);
    if (date == null) return '—';
    final local = switch (_sort) {
      GroupListSort.firstExpense || GroupListSort.lastExpense => date,
      GroupListSort.created || GroupListSort.lastOpened => date.toLocal(),
    };
    return formatDate(local, locale: context.appLocale);
  }

  static const _nameStyle = TextStyle(fontWeight: FontWeight.w600);

  String? _spokenSortDate(GroupRow row) {
    final l10n = context.l10n;
    final date = groupSortDate(row, _sort, _dateSpans);
    if (date == null) {
      return switch (_sort) {
        GroupListSort.firstExpense || GroupListSort.lastExpense =>
          l10n.groupListSpokenNoExpenses,
        GroupListSort.created || GroupListSort.lastOpened => null,
      };
    }
    final text = _sortDateText(row);
    return switch (_sort) {
      GroupListSort.firstExpense => l10n.groupListSpokenFirstExpense(text),
      GroupListSort.lastExpense => l10n.groupListSpokenLastExpense(text),
      GroupListSort.created => l10n.groupListSpokenCreated(text),
      GroupListSort.lastOpened => l10n.groupListSpokenOpened(text),
    };
  }

  Widget _groupTile(GroupRow row) {
    final count = row.memberCount > 0
        ? row.memberCount
        : (jsonDecode(row.participantsJson) as List).length;
    final downloads = ReceiptDownloader.of(widget.db);
    void retryDownloads() => unawaited(
        downloads.run(row.id, _client, retry: true));
    final actions = [
      GroupRowAction(
          label: row.organization == GroupOrganization.favorite
              ? context.l10n.groupListUnfavorite
              : context.l10n.groupListFavorite,
          icon: row.organization == GroupOrganization.favorite
              ? Icons.star_border
              : Icons.star,
          onSelected: () => _performGroupAction(row, 'favorite')),
      if (row.role == 'ADMIN' || row.role == null)
        GroupRowAction(
            label: row.organization == GroupOrganization.archived
                ? context.l10n.groupListUnarchive
                : context.l10n.groupListArchive,
            icon: row.organization == GroupOrganization.archived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined,
            onSelected: () => _performGroupAction(row, 'archive')),
      GroupRowAction(
          label: context.l10n.groupListRemove,
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => _performGroupAction(row, 'remove')),
    ];
    final spokenDate = _spokenSortDate(row);
    final spoken = spokenSentences([
      row.name,
      if (spokenDate != null) spokenDate,
      context.l10n.groupListParticipantCount(count),
    ], context.l10n.spokenSentenceEnd);
    final clip = ReceiptRowClip();
    final emoji = row.emoji;
    return GroupRowActions(
      key: ValueKey('${row.id}_${_dismissVersions[row.id] ?? 0}'),
      actions: actions,
      builder: (context, openMenu) => Stack(children: [
        ListTile(
          horizontalTitleGap: 8,
          leading: Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Semantics(
              button: true,
              label: context.l10n.groupListActions(row.name),
              child: Tooltip(
                  message: context.l10n.groupListActions(row.name),
                  child: InkResponse(
                      onTap: openMenu,
                      radius: 24,
                      child: ConstrainedBox(
                          constraints:
                              const BoxConstraints(minWidth: 48, minHeight: 48),
                          child: Center(
                              widthFactor: 1,
                              heightFactor: 1,
                              child: emoji != null && emoji.isNotEmpty
                                  ? Text(emoji,
                                      style: const TextStyle(fontSize: 26))
                                  : GroupMonogram(
                                      id: row.id, name: row.name)))))),
          ),
          title: Semantics(
            label: spoken,
            customSemanticsActions: {
              for (final action in actions)
                CustomSemanticsAction(label: action.label):
                    action.onSelected,
            },
            excludeSemantics: true,
            child: LayoutBuilder(builder: (context, constraints) {
              final style =
                  DefaultTextStyle.of(context).style.merge(_nameStyle);
              final longestWord = row.name
                  .split(' ')
                  .map((word) => (TextPainter(
                          text: TextSpan(text: word, style: style),
                          textDirection: Directionality.of(context),
                          textScaler: MediaQuery.textScalerOf(context),
                          maxLines: 1)
                        ..layout())
                      .width)
                  .fold(0.0, (a, b) => a > b ? a : b);
              return Row(children: [
                Expanded(child: Text(row.name, style: _nameStyle)),
                ReceiptDownloadIndicator(
                  row: clip,
                  status: downloads.status(row.id),
                  onRetry: retryDownloads,
                  maxRowSize: constraints.maxWidth - longestWord - 1,
                ),
              ]);
            }),
          ),
          subtitle: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LayoutBuilder(
                  builder: (context, constraints) => _caption(
                      context, constraints.maxWidth, _sortDateText(row), count)),
            ),
          ),
          trailing: GroupedRow.chevron(context),
          onTap: () => _openGroup(row),
          onLongPress: openMenu,
        ),
        Positioned(
          top: 0,
          left: 0,
          child: ReceiptDownloadTapArea(
              row: clip,
              status: downloads.status(row.id),
              onRetry: retryDownloads),
        ),
      ]),
    );
  }

  Widget _caption(
      BuildContext context, double maxWidth, String dateText, int count) {
    final style = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double widthOf(String text) => (TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 1)
          ..layout())
        .width;
    final icon = captionIconSize(context);
    final fits = icon +
            4 +
            widthOf(dateText) +
            12 +
            widthOf('$count') +
            4 +
            icon <=
        maxWidth;
    final date = Row(mainAxisSize: MainAxisSize.min, children: [
      const CaptionIcon(LucideIcons.calendar),
      const SizedBox(width: 4),
      Flexible(
          child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(dateText, maxLines: 1, softWrap: false))),
    ]);
    final people = Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$count'),
      const SizedBox(width: 4),
      const CaptionIcon(LucideIcons.users),
    ]);
    if (fits) {
      return Row(
          children: [Expanded(child: date), const SizedBox(width: 12), people]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(alignment: AlignmentDirectional.centerStart, child: date),
      const SizedBox(height: 2),
      Align(alignment: AlignmentDirectional.centerEnd, child: people),
    ]);
  }
}


