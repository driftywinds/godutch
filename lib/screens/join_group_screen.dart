import 'package:flutter/material.dart';

import '../api/cloud_connection.dart';
import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/error_reporting.dart';
import '../services/group_url.dart';
import '../services/settings_service.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/error_message.dart';
import '../widgets/paste_link_button.dart';
import 'group_settings_screen.dart';
import 'qr_scanner_screen.dart';

/// Joins a Spliit Cloud group from the invite link its members share.
///
/// Cloud groups are account-bound: there is no public group URL to join
/// without a member's invite, and no per-group server to pick. The link
/// carries the one-time/shared token; accepting it makes the signed-in
/// account a member, then the group and its expenses are cached so it is
/// readable offline straight away.
class JoinGroupScreen extends StatefulWidget {
  JoinGroupScreen({
    super.key,
    required this.db,
    SpliitClient? client,
    this.initialUrl,
    SpliitClient Function(String baseUrl)? clientFactory,
    this.clipboardHasLink = clipboardProbablyHasLink,
  })  : client = client,
        clientFactory = clientFactory ??
            ((url) => client ?? SpliitClient(baseUrl: url));

  final AppDatabase db;
  final SpliitClient? client;
  final String? initialUrl;
  final SpliitClient Function(String baseUrl) clientFactory;
  final Future<bool> Function() clipboardHasLink;

  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _urlController = TextEditingController(text: widget.initialUrl);
  final _settings = SettingsService();

  SpliitClient get _client =>
      widget.client ?? widget.clientFactory(CloudConnection.defaultBaseUrl);

  bool _joining = false;
  String? _error;
  String? _errorDiagnostics;
  bool _clipboardHasLink = false;
  late final _lifecycle = AppLifecycleListener(onResume: _checkClipboard);

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _checkClipboard();
    _urlController.addListener(_emptyChanged);
  }

  late bool _empty = widget.initialUrl?.trim().isEmpty ?? true;

  void _emptyChanged() {
    final empty = _urlController.text.trim().isEmpty;
    if (empty == _empty) return;
    setState(() => _empty = empty);
    if (empty) _checkClipboard();
  }

  Future<void> _checkClipboard() async {
    final hasLink = await widget.clipboardHasLink();
    if (mounted && hasLink != _clipboardHasLink) {
      setState(() => _clipboardHasLink = hasLink);
    }
  }

  void _pasted(String text) {
    if (!mounted) return;
    _urlController.text = text.trim();
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (scanned == null || !mounted) return;
    _urlController.text = scanned;
    setState(() => _error = null);
    await _join();
  }

  Future<void> _join() async {
    if (!_formKey.currentState!.validate()) return;
    final parsed = parseCloudInviteUrl(_urlController.text);
    if (parsed == null) {
      setState(() {
        _error = context.l10n.joinGroupInviteInvalid;
        _errorDiagnostics = null;
      });
      return;
    }

    setState(() {
      _joining = true;
      _error = null;
      _errorDiagnostics = null;
    });
    try {
      // Cloud groups belong to the signed-in account's instance: the link
      // may point at the web origin (spliit.cloud) while the API lives on
      // api.spliit.cloud, so use this app's configured client rather than
      // the link's host.
      final client = widget.client ?? widget.clientFactory(_client.baseUrl);
      final preview = await client.previewInvite(parsed.token);
      if (preview != null && !preview.usable) {
        if (!mounted) return;
        setState(() {
          _error = _endedMessage(preview.reason);
          _errorDiagnostics = null;
        });
        return;
      }
      final groupId = await client.acceptInvite(
        parsed.token,
        expectedGroupId: parsed.groupId,
      );
      final group = await client.fetchGroup(groupId);
      final expenses = await client.fetchExpenses(group.id);
      await cacheJoinedGroup(
        db: widget.db,
        group: group,
        expenses: expenses,
        serverUrl: client.baseUrl,
        settings: _settings,
      );
      if (!mounted) return;
      Navigator.of(context).pop(group.id);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Joining a Spliit Cloud group');
      if (!mounted) return;
      setState(() {
        _error = errorMessageFor(context, error,
            unexpected: context.l10n.joinGroupJoinFailed,
            userMessage: (e) => e is SpliitApiException
                ? _serverMessage(e)
                : e is GroupNotFoundException
                    ? context.l10n.joinGroupNotFound(serverDisplayName(parsed.serverUrl))
                    : null);
        _errorDiagnostics = error.diagnostics;
      });
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  String _endedMessage(String? reason) => switch (reason) {
        'expired' => 'This invite link has expired. Ask for a new one.',
        'full' => 'This invite link has reached its join limit.',
        'revoked' => 'This invite link was revoked.',
        _ => context.l10n.joinGroupJoinFailed,
      };

  String _serverMessage(SpliitApiException e) {
    if (e.code == 'INVITE_EXPIRED') {
      return 'This invite link has expired. Ask for a new one.';
    }
    if (e.code == 'INVITE_FULL') {
      return 'This invite link has reached its join limit.';
    }
    if (e.code == 'INVITE_REVOKED') {
      return 'This invite link was revoked.';
    }
    if (e.isUnauthorized) return context.l10n.cloudSignInRequired;
    return e.userMessage;
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
    if (createdId == null || !mounted) return;
    Navigator.of(context).pop(createdId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.joinGroupScreenTitle)),
      body: SingleChildScrollView(
        padding: withBottomInset(context, const EdgeInsets.all(16)),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                ErrorMessage(_error!, diagnostics: _errorDiagnostics),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: context.l10n.joinGroupUrlLabel,
                  helperText: context.l10n.joinGroupInviteHelper,
                  helperMaxLines: 3,
                  suffixIcon: _clipboardHasLink && _empty
                      ? Padding(
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: Center(
                              widthFactor: 1,
                              child: PasteLinkButton(onPaste: _pasted)),
                        )
                      : null,
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? context.l10n.commonRequired
                    : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _joining ? null : _join,
                child: _joining
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.l10n.joinGroupSubmitButton),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(context.l10n.joinGroupScanButton),
                onPressed: _joining ? null : _scan,
              ),
              const SizedBox(height: 32),
              Text(context.l10n.joinGroupOrCreate,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.group_add_outlined),
                label: Text(context.l10n.joinGroupCreateButton),
                onPressed: _joining ? null : _createGroup,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stores a group this device has just joined or created: the group, its
/// expenses, and the cloud instance. The active participant comes from the
/// account binding, so no "who are you?" guess is needed.
Future<void> cacheJoinedGroup({
  required AppDatabase db,
  required Group group,
  required List<Expense> expenses,
  required String serverUrl,
  required SettingsService settings,
}) async {
  await db.transaction(() async {
    await db.cacheGroup(group);
    await db.replaceServerExpenses(group.id, expenses);
    await db.recordGroupOpened(group.id, serverUrl: serverUrl);
    if (group.currentParticipantId case final participantId?) {
      await db.setActiveParticipant(group.id, participantId);
    }
  });
}



