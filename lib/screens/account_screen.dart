import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/spliit_client.dart';
import '../l10n/context_l10n.dart';
import '../models/account.dart';
import '../services/error_reporting.dart';
import '../theme.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/error_message.dart';
import '../widgets/group_monogram.dart';
import '../widgets/grouped_section.dart';
import 'friends_screen.dart';
import 'welcome_screen.dart' show showRecoveryLinkSheet;

/// The signed-in account: name, identity type, recovery link and server.
class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.client,
    required this.account,
    required this.onAccountChanged,
    required this.onSignOut,
  });

  final SpliitClient client;
  final CloudAccount account;
  final ValueChanged<CloudAccount> onAccountChanged;
  final Future<void> Function() onSignOut;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late CloudAccount _account = widget.account;
  AnonymousRecoveryStatus? _recovery;
  List<AccountInvite> _invites = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRecovery();
    _loadInvites();
  }

  Future<void> _loadInvites() async {
    try {
      final invites = await widget.client.fetchAccountInvitations();
      if (mounted) setState(() => _invites = invites);
    } catch (e, st) {
      ErrorReporter.instance
          .report(e, st, operation: 'Reading pending invitations');
    }
  }

  Future<void> _acceptInvite(AccountInvite invite) async {
    setState(() => _busy = true);
    try {
      await widget.client.acceptAccountInvitation(invite.id);
      if (!mounted) return;
      setState(() => _invites =
          _invites.where((i) => i.id != invite.id).toList());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.accountInvitationAccepted(invite.groupName))),
      );
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Accepting an invitation');
      if (!mounted) return;
      setState(() => _error = error.kind == ErrorKind.connection
          ? context.l10n.errorConnection
          : context.l10n.groupSettingsSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadRecovery() async {
    if (!_account.isAnonymous) return;
    try {
      final status = await widget.client.anonymousRecoveryStatus();
      if (mounted) setState(() => _recovery = status);
    } catch (e, st) {
      // A status read failing must not make the whole screen unusable;
      // the create-link action below surfaces a real error.
      ErrorReporter.instance
          .report(e, st, operation: 'Reading the recovery status');
    }
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _account.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.accountNameEdit),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: context.l10n.createAccountNameLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == _account.name) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.client.updateProfile(name);
      if (!mounted) return;
      setState(() => _account = updated);
      widget.onAccountChanged(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.accountNameUpdated)),
      );
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Updating the account name');
      if (!mounted) return;
      setState(() => _error = error.kind == ErrorKind.connection
          ? context.l10n.errorConnection
          : context.l10n.accountNameFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createRecovery() async {
    final saved = await showRecoveryLinkSheet(
      context,
      client: widget.client,
      account: _account,
    );
    if (saved && mounted) await _loadRecovery();
  }

  Future<void> _signOut() async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.l10n.accountSignOut,
      message: [context.l10n.accountSignOutBody],
      action: context.l10n.accountSignOut,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.client.signOut();
      if (!mounted) return;
      await widget.onSignOut();
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Signing out');
      if (!mounted) return;
      setState(() => _error = error.kind == ErrorKind.connection
          ? context.l10n.errorConnection
          : context.l10n.accountSignOutFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final image = _account.image;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.accountTitle)),
      body: AboveBottomBar(
        child: GroupedScrollClip(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: ErrorMessage(_error!),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    ClipOval(
                      child: image == null
                          ? Monogram(
                              name: _account.displayName,
                              color: monogramPalette[
                                  groupColorIndex(_account.id)],
                              radius: 28)
                          : Image.network(
                              image,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Monogram(
                                  name: _account.displayName,
                                  color: monogramPalette[
                                      groupColorIndex(_account.id)],
                                  radius: 28),
                            ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_account.displayName,
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          if (_account.isAnonymous)
                            Text(l10n.accountAnonymous,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          if (!_account.isAnonymous)
                            Text(_account.email,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l10n.accountNameEdit,
                      onPressed: _busy ? null : _editName,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              GroupedSection(
                caption: l10n.accountTitle,
                children: [
                  ListTile(
                    leading: const Icon(Icons.alternate_email),
                    title: Text(l10n.accountEmail),
                    subtitle: Text(_account.hasRealEmail
                        ? _account.email
                        : l10n.accountAnonymous),
                  ),
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(l10n.accountServer),
                    subtitle: Text(widget.client.baseUrl ==
                            'https://api.spliit.cloud'
                        ? 'spliit.cloud'
                        : widget.client.baseUrl
                            .replaceFirst(RegExp(r'^https://'), '')),
                  ),
                  ListTile(
                    leading: const Icon(Icons.people_outline),
                    title: Text(l10n.friendsTitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => FriendsScreen(client: widget.client),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.open_in_new),
                    title: Text(l10n.accountManageWeb),
                    subtitle: Text(l10n.accountManageWebBody),
                    onTap: () => launchUrl(
                      Uri.parse(
                          '${widget.client.connection.origin}/account/settings'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  if (_account.isAnonymous)
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: Text(l10n.accountRecovery),
                      subtitle: Text(_recovery?.isReady == true
                          ? l10n.accountRecoveryReady
                          : l10n.accountRecoveryMissing),
                      trailing: TextButton(
                        onPressed: _busy ? null : _createRecovery,
                        child: Text(_recovery?.isReady == true
                            ? l10n.accountRecoveryNew
                            : l10n.accountRecoveryCreate),
                      ),
                      onTap: _busy ? null : _createRecovery,
                    ),
                ],
              ),
              if (_invites.isNotEmpty) ...[
                const SizedBox(height: 24),
                GroupedSection(
                  caption: l10n.accountInvitations,
                  dividerIndent: 56,
                  children: [
                    for (final invite in _invites)
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: Text(invite.groupName),
                        subtitle: Text(invite.inviterName == null
                            ? l10n.accountInvitationPending
                            : l10n.accountInvitationFrom(invite.inviterName!)),
                        trailing: TextButton(
                          onPressed:
                              _busy ? null : () => _acceptInvite(invite),
                          child: Text(l10n.accountInvitationAccept),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: Text(l10n.accountSignOut),
                  onPressed: _busy ? null : _signOut,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
