import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../l10n/currency_names.dart';
import '../models/currency.dart';
import '../models/group.dart';
import '../models/group_organization.dart';
import '../services/date_span_calculator.dart';
import '../services/error_reporting.dart';
import '../services/settings_service.dart';
import '../theme.dart';
import '../utils/date_format.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/currency_picker.dart';
import '../widgets/error_message.dart';
import '../widgets/flag_glyph.dart';
import '../widgets/group_monogram.dart';
import '../widgets/grouped_section.dart';
import '../widgets/top_bar_buttons.dart';
import 'join_group_screen.dart' show cacheJoinedGroup;

/// The cloud group settings: name, notes, currency, member roster,
/// invitations, archive/delete and leaving.
///
/// Membership is no longer edited as a free-text participant list: Cloud
/// binds every participant to an account, so people join through an
/// invite link, and admins change roles/remove members through the
/// dedicated member endpoints. Spliit Cloud also refuses a currency change
/// once expenses exist, because stored amounts are in that currency.
class GroupSettingsScreen extends StatefulWidget {
  const GroupSettingsScreen({
    super.key,
    required this.client,
    required this.db,
    required this.group,
    this.activeUserId,
  }) : creating = false;

  GroupSettingsScreen.create({
    super.key,
    required this.db,
    SpliitClient? client,
    SpliitClient Function(String baseUrl)? clientFactory,
  })  : client = client ??
            clientFactory?.call('https://api.spliit.cloud') ??
            SpliitClient(baseUrl: 'https://api.spliit.cloud'),
        group = null,
        activeUserId = null,
        creating = true;

  final SpliitClient client;
  final AppDatabase db;
  final Group? group;
  final String? activeUserId;
  final bool creating;

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late final _nameController =
      TextEditingController(text: widget.group?.name ?? '');
  late final _informationController =
      TextEditingController(text: widget.group?.information ?? '');
  late Currency _selectedCurrency =
      currencyByCode(widget.group?.currencyCode);
  late final _customSymbolController =
      TextEditingController(text: widget.group?.currency ?? '');

  bool _saving = false;
  String? _error;
  String? _errorDiagnostics;
  DateSpan? _dateSpan;
  List<GroupInvitation> _invitations = const [];
  bool _loadingInvitations = false;

  bool get _creating => widget.creating;
  Group? get _group => widget.group;

  @override
  void initState() {
    super.initState();
    if (!_creating) {
      _seeded = true;
      _loadCachedMeta();
      if (_group?.canManage == true) {
        unawaited(_loadInvitations());
      }
    }
  }

  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    _selectedCurrency = defaultCurrencyFor(View.of(context).platformDispatcher.locale);
    _customSymbolController.text = _selectedCurrency.symbol;
  }

  Future<void> _loadCachedMeta() async {
    final group = _group;
    if (group == null) return;
    final expenses = await widget.db.expensesForGroup(group.id);
    if (!mounted) return;
    setState(() => _dateSpan = computeDateSpan(expenses));
  }

  Future<void> _loadInvitations() async {
    final group = _group;
    if (group == null) return;
    setState(() => _loadingInvitations = true);
    try {
      final invitations = await widget.client.fetchInvitations(group.id);
      if (!mounted) return;
      setState(() => _invitations = invitations);
    } catch (e, st) {
      ErrorReporter.instance
          .report(e, st, operation: 'Reading pending invitations');
    } finally {
      if (mounted) setState(() => _loadingInvitations = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _informationController.dispose();
    _customSymbolController.dispose();
    super.dispose();
  }

  Future<void> _pickCurrency() async {
    final picked = await pickCurrency(
      context,
      currencies: [Currency.custom, ...supportedCurrencies],
      selectedCode: _selectedCurrency.code,
    );
    if (picked == null) return;
    setState(() {
      _selectedCurrency = picked;
      if (picked.code.isNotEmpty) _customSymbolController.text = picked.symbol;
    });
  }

  String? _problem(String name, bool isCustom, String symbol) {
    final l10n = context.l10n;
    if (name.isEmpty) return l10n.groupSettingsNameRequired;
    if (name.length < 2 || name.length > 50) return l10n.groupSettingsNameLength;
    if (isCustom && symbol.isEmpty) return l10n.groupSettingsSymbolRequired;
    return null;
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final information = _informationController.text.trim();
    final isCustom = _selectedCurrency.code.isEmpty;
    final currencySymbol =
        isCustom ? _customSymbolController.text.trim() : _selectedCurrency.symbol;
    final problem = _problem(name, isCustom, currencySymbol);
    if (problem != null) {
      setState(() {
        _error = problem;
        _errorDiagnostics = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _errorDiagnostics = null;
    });
    try {
      if (_creating) {
        final id = await widget.client.createGroup(
          name: name,
          information: information,
          currency: currencySymbol,
          currencyCode: isCustom ? null : _selectedCurrency.code,
          participantNames: [
            widget.client.connection.account?.name ?? 'Me',
          ],
        );
        final group = await widget.client.fetchGroup(id);
        await cacheJoinedGroup(
          db: widget.db,
          group: group,
          expenses: const [],
          serverUrl: widget.client.baseUrl,
          settings: SettingsService(),
        );
        if (!mounted) return;
        Navigator.of(context).pop(group.id);
        return;
      }
      final group = _group!;
      await widget.client.updateGroup(
        groupId: group.id,
        name: name,
        information: information,
        currency: currencySymbol,
        currencyCode: isCustom ? null : _selectedCurrency.code,
        participants: group.participants,
      );
      final fresh = await widget.client.fetchGroup(group.id);
      await widget.db.cacheGroup(fresh);
      if (!mounted) return;
      Navigator.of(context).pop(fresh);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Saving group settings');
      if (!mounted) return;
      setState(() {
        _error = error.kind == ErrorKind.user && e is SpliitApiException
            ? e.userMessage
            : errorMessageFor(context, error,
                unexpected: context.l10n.groupSettingsSaveFailed);
        _errorDiagnostics = error.diagnostics;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createInvite() async {
    final group = _group;
    if (group == null) return;
    setState(() => _saving = true);
    try {
      final invite = await widget.client.createInviteLink(group.id);
      if (!mounted) return;
      await _showInvite(invite);
      unawaited(_loadInvitations());
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Creating an invite link');
      if (!mounted) return;
      showErrorSnackBar(context,
          e is SpliitApiException
              ? e.userMessage
              : context.l10n.groupSettingsSaveFailed,
          diagnostics: error.diagnostics);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showInvite(CreatedInvite invite) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: withBottomInset(context, const EdgeInsets.fromLTRB(20, 0, 20, 20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(invite.label ?? context.l10n.groupSettingsInviteTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText(invite.inviteUrl),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.share_outlined),
              label: Text(context.l10n.recoveryShare),
              onPressed: () => SharePlus.instance.share(ShareParams(
                  text: invite.inviteUrl,
                  subject: context.l10n.groupSettingsInviteTitle)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _revoke(GroupInvitation invitation) async {
    final confirmed = await showConfirmDialog(context,
        title: context.l10n.groupSettingsRevokeInvite,
        message: [context.l10n.groupSettingsRevokeInviteBody],
        action: context.l10n.groupSettingsRevokeInvite,
        destructive: true);
    if (!confirmed) return;
    try {
      await widget.client.revokeInvitation(invitation.id);
      await _loadInvitations();
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Revoking an invitation');
      if (!mounted) return;
      showErrorSnackBar(context,
          e is SpliitApiException
              ? e.userMessage
              : context.l10n.groupSettingsSaveFailed,
          diagnostics: error.diagnostics);
    }
  }

  Future<void> _memberActions(GroupMember member) async {
    final group = _group;
    if (group == null || !group.canManage || member.accountId == widget.client.connection.account?.id) {
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(member.isAdmin ? Icons.person_outline : Icons.shield_outlined),
              title: Text(member.isAdmin
                  ? context.l10n.groupSettingsMakeMember
                  : context.l10n.groupSettingsMakeAdmin),
              onTap: () => Navigator.of(context).pop(member.isAdmin ? 'demote' : 'promote'),
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined),
              title: Text(context.l10n.groupSettingsRemoveMember),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    try {
      switch (action) {
        case 'promote':
          await widget.client.updateMemberRole(
              groupId: group.id, memberId: member.id, role: 'ADMIN');
        case 'demote':
          await widget.client.updateMemberRole(
              groupId: group.id, memberId: member.id, role: 'MEMBER');
        case 'remove':
          try {
            await widget.client.removeMember(
                groupId: group.id, memberId: member.id);
          } on SpliitApiException catch (e) {
            if (!e.isPreconditionFailed || !mounted) rethrow;
            final settle = await showConfirmDialog(context,
                title: context.l10n.groupSettingsRemoveMember,
                message: [context.l10n.groupSettingsRemoveMemberBalances],
                action: context.l10n.groupSettingsRemoveMember,
                destructive: true);
            if (!settle) return;
            await widget.client.removeMember(
                groupId: group.id,
                memberId: member.id,
                settleBalances: true);
          }
      }
      final fresh = await widget.client.fetchGroup(group.id);
      await widget.db.cacheGroup(fresh);
      if (!mounted) return;
      setState(() {});
      await _loadInvitations();
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Updating group members');
      if (!mounted) return;
      showErrorSnackBar(context,
          e is SpliitApiException
              ? e.userMessage
              : context.l10n.groupSettingsSaveFailed,
          diagnostics: error.diagnostics);
    }
  }

  Future<void> _archive(bool archived) async {
    final group = _group;
    if (group == null) return;
    try {
      if (archived) {
        try {
          await widget.client.archiveGroup(group.id, true);
        } on SpliitApiException catch (e) {
          if (!e.isPreconditionFailed || !mounted) rethrow;
          final force = await showConfirmDialog(context,
              title: context.l10n.groupListArchive,
              message: [context.l10n.groupListArchiveBalances],
              action: context.l10n.groupListArchive,
              destructive: true);
          if (!force) return;
          await widget.client.archiveGroup(group.id, true, force: true);
        }
      } else {
        await widget.client.archiveGroup(group.id, false);
      }
      final fresh = await widget.client.fetchGroup(group.id);
      await widget.db.cacheGroup(fresh);
      await widget.db.setGroupOrganization(
          group.id,
          fresh.archived
              ? GroupOrganization.archived
              : GroupOrganization.active);
      if (!mounted) return;
      Navigator.of(context).pop(fresh);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Archiving the group');
      if (!mounted) return;
      showErrorSnackBar(context,
          e is SpliitApiException
              ? e.userMessage
              : context.l10n.groupSettingsSaveFailed,
          diagnostics: error.diagnostics);
    }
  }

  Future<void> _delete() async {
    final group = _group;
    if (group == null) return;
    final confirmed = await showConfirmDialog(context,
        title: context.l10n.groupSettingsDelete,
        message: [context.l10n.groupSettingsDeleteBody(group.name)],
        action: context.l10n.groupSettingsDelete,
        destructive: true);
    if (!confirmed) return;
    try {
      await widget.client.deleteGroup(group.id);
      await widget.db.leaveGroup(group.id);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Deleting the group');
      if (!mounted) return;
      showErrorSnackBar(context,
          e is SpliitApiException
              ? e.userMessage
              : context.l10n.groupSettingsSaveFailed,
          diagnostics: error.diagnostics);
    }
  }

  Future<void> _leave() async {
    final group = _group;
    if (group == null) return;
    final confirmed = await showConfirmDialog(context,
        title: context.l10n.groupListLeaveTitle,
        message: [context.l10n.groupListLeaveCloudBody(group.name)],
        action: context.l10n.groupListRemove,
        destructive: true);
    if (!confirmed) return;
    try {
      await widget.client.leaveGroup(group.id);
      await widget.db.leaveGroup(group.id);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Leaving the group');
      if (!mounted) return;
      showErrorSnackBar(context,
          e is SpliitApiException
              ? e.userMessage
              : context.l10n.groupSettingsSaveFailed,
          diagnostics: error.diagnostics);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final isCustom = _selectedCurrency.code.isEmpty;
    final isAdmin = !_creating && group?.isAdmin == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(_creating
            ? context.l10n.createGroupTitle
            : context.l10n.groupSettingsTitle),
        actions: [
          if (!isAdmin && !_creating)
            const SizedBox.shrink()
          else
            TopBarButtons(children: [
              _saving
                  ? SizedBox.square(
                      dimension: TopBarButtons.slotSize(context),
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: _creating
                          ? context.l10n.createGroupSubmitTooltip
                          : context.l10n.groupSettingsSaveTooltip,
                      onPressed: _save,
                    ),
            ]),
        ],
      ),
      body: AboveBottomBar(
        child: Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: const InputDecorationTheme(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              filled: false,
            ),
          ),
          child: GroupedScrollClip(
            child: ListView(
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: ErrorMessage(_error!, diagnostics: _errorDiagnostics),
                  ),
                GroupedSection(children: [
                  _cell(TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                        labelText: context.l10n.groupSettingsNameLabel),
                  )),
                  InkWell(
                    onTap: group?.archived == true ? null : _pickCurrency,
                    child: _cell(InputDecorator(
                      decoration: InputDecoration(
                          labelText: context.l10n.groupSettingsCurrencyLabel),
                      child: Row(
                        children: [
                          if (_selectedCurrency.flagEmoji.isNotEmpty) ...[
                            FlagGlyph(_selectedCurrency.flagEmoji, size: 18),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                              child: Text(localizedCurrencyLabel(
                                  context, _selectedCurrency))),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    )),
                  ),
                  if (isCustom)
                    _cell(TextField(
                      controller: _customSymbolController,
                      decoration: InputDecoration(
                        labelText: context.l10n.groupSettingsSymbolLabel,
                        hintText: context.l10n.groupSettingsSymbolHint,
                        helperText: context.l10n.groupSettingsSymbolHelper,
                      ),
                      maxLength: 5,
                    )),
                  if (!_creating)
                    _cell(InputDecorator(
                      decoration: InputDecoration(
                          labelText: context.l10n.groupSettingsDateSpanLabel),
                      child: Text(formatDateSpan(_dateSpan,
                          locale: context.appLocale)),
                    )),
                ]),
                GroupedSection(children: [
                  _cell(TextField(
                    controller: _informationController,
                    decoration: InputDecoration(
                      labelText: context.l10n.groupSettingsInfoLabel,
                      hintText: context.l10n.groupSettingsInfoHint,
                      alignLabelWithHint: true,
                    ),
                    minLines: 2,
                    maxLines: 6,
                    maxLength: 10000,
                  )),
                ]),
                if (!_creating) ...[
                  GroupedSection(
                    caption: context.l10n.groupSettingsMembersHeading,
                    captionTrailing: isAdmin
                        ? IconButton(
                            icon: const Icon(Icons.person_add_outlined),
                            tooltip: context.l10n.groupSettingsInviteTitle,
                            onPressed: _saving ? null : _createInvite,
                          )
                        : null,
                    dividerIndent: 56,
                    children: [
                      if (group != null)
                        for (final member in group.members)
                          ListTile(
                            leading: Monogram(
                              name: member.name,
                              color: monogramPalette[
                                  groupColorIndex(member.accountId)],
                              radius: 14,
                            ),
                            title: Text(member.name),
                            subtitle: Text(member.isAdmin
                                ? context.l10n.groupSettingsRoleAdmin
                                : context.l10n.groupSettingsRoleMember),
                            trailing: isAdmin &&
                                    member.accountId !=
                                        widget.client.connection.account?.id
                                ? const Icon(Icons.more_horiz)
                                : null,
                            onTap: () => _memberActions(member),
                          ),
                      if (_loadingInvitations)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      for (final invitation in _invitations)
                        ListTile(
                          leading: const Icon(Icons.mail_outline),
                          title: Text(invitation.temporaryName ??
                              invitation.email),
                          subtitle: Text(context.l10n.groupSettingsInvitePending),
                          trailing: invitation.canRevoke
                              ? IconButton(
                                  icon: const Icon(Icons.close),
                                  tooltip: context.l10n.groupSettingsRevokeInvite,
                                  onPressed: () => _revoke(invitation),
                                )
                              : null,
                        ),
                    ],
                  ),
                  if (isAdmin)
                    GroupedSection(
                      caption: context.l10n.groupSettingsDangerZone,
                      children: [
                        ListTile(
                          leading: Icon(group?.archived == true
                              ? Icons.unarchive_outlined
                              : Icons.archive_outlined),
                          title: Text(group?.archived == true
                              ? context.l10n.groupListUnarchive
                              : context.l10n.groupListArchive),
                          subtitle: Text(context.l10n.groupSettingsArchiveBody),
                          onTap: () => _archive(group?.archived != true),
                        ),
                        ListTile(
                          leading: Icon(Icons.delete_outline,
                              color: Theme.of(context).colorScheme.error),
                          title: Text(context.l10n.groupSettingsDelete,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                          onTap: _delete,
                        ),
                      ],
                    )
                  else
                    GroupedSection(children: [
                      ListTile(
                        leading: const Icon(Icons.logout),
                        title: Text(context.l10n.groupListRemove),
                        subtitle: Text(context.l10n.accountSignOutBody),
                        onTap: _leave,
                      ),
                    ]),
                ],
                if (_creating)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      context.l10n.createGroupInviteHint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cell(Widget field) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: field,
      );
}

