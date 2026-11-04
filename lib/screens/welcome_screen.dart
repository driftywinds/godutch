import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../api/cloud_connection.dart';
import '../api/spliit_client.dart';
import '../l10n/context_l10n.dart';
import '../models/account.dart';
import '../services/error_reporting.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_message.dart';
import '../widgets/grouped_section.dart';

/// First run and signed-out screen: the fork's account model is explained
/// here, with the anonymous, email and recovery routes side by side.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({
    super.key,
    required this.client,
    required this.connection,
    required this.onSignedIn,
    required this.onServerChanged,
  });

  final SpliitClient client;
  final CloudConnection connection;
  final ValueChanged<CloudAccount> onSignedIn;
  final ValueChanged<String> onServerChanged;

  Future<void> _createAccount(BuildContext context) async {
    final account = await Navigator.of(context).push<CloudAccount>(
      MaterialPageRoute(builder: (_) => CreateAccountScreen(client: client)),
    );
    if (account != null && context.mounted) onSignedIn(account);
  }

  Future<void> _signIn(BuildContext context) async {
    final account = await Navigator.of(context).push<CloudAccount>(
      MaterialPageRoute(builder: (_) => SignInScreen(client: client)),
    );
    if (account != null && context.mounted) onSignedIn(account);
  }

  Future<void> _recover(BuildContext context) async {
    final account = await Navigator.of(context).push<CloudAccount>(
      MaterialPageRoute(builder: (_) => RecoveryScreen(client: client)),
    );
    if (account != null && context.mounted) onSignedIn(account);
  }

  Future<void> _changeServer(BuildContext context) async {
    final controller = TextEditingController(
        text: connection.baseUrl == CloudConnection.defaultBaseUrl
            ? 'spliit.cloud'
            : connection.baseUrl.replaceFirst('https://', ''));
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.welcomeServerTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: context.l10n.welcomeServerTitle,
            hintText: context.l10n.welcomeServerHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () {
              final normalized = normalizeBaseUrl(controller.text);
              Navigator.of(context).pop(normalized ?? '');
            },
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    if (value.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.welcomeServerInvalid)),
        );
      }
      return;
    }
    onServerChanged(value);
  }

  String get _serverLabel {
    final uri = Uri.tryParse(connection.baseUrl);
    if (uri == null) return connection.baseUrl;
    // The public API's host is api.spliit.cloud; people know the service
    // as spliit.cloud.
    final host = uri.host == 'api.spliit.cloud' ? 'spliit.cloud' : uri.host;
    return '$host${uri.path == '/' ? '' : uri.path}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: SafeArea(
        child: EmptyState.logo(
          title: l10n.welcomeTitle,
          description: l10n.welcomeTagline,
          actions: [
            FilledButton.icon(
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: Text(l10n.welcomeCreateAccount),
              onPressed: () => _createAccount(context),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.login),
              label: Text(l10n.welcomeSignIn),
              onPressed: () => _signIn(context),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => _recover(context),
              child: Text(l10n.welcomeRecovery),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.dns_outlined, size: 18),
              label: Text(l10n.welcomeServer(_serverLabel)),
              onPressed: () => _changeServer(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Creates the fork's anonymous account: a name, no email, no social login.
class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key, required this.client});

  final SpliitClient client;

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account =
          await widget.client.signInAnonymously(name: _name.text.trim());
      if (!mounted) return;
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (sheetContext) => RecoverySetupScreen(
            client: widget.client,
            account: account,
            onSignOut: () async {
              await widget.client.signOut();
              if (sheetContext.mounted) Navigator.of(sheetContext).pop(false);
            },
          ),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(completed == true ? account : null);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Creating a cloud account');
      if (!mounted) return;
      setState(() {
        _error = error.kind == ErrorKind.user
            ? (e is CloudAuthException ? e.message : context.l10n.createAccountFailed)
            : error.kind == ErrorKind.connection
                ? context.l10n.errorConnection
                : context.l10n.createAccountFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.createAccountTitle)),
      body: SingleChildScrollView(
        padding: withBottomInset(context, const EdgeInsets.all(16)),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                ErrorMessage(_error!),
                const SizedBox(height: 12),
              ],
              GroupedSection(children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: TextFormField(
                    controller: _name,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _busy ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: l10n.createAccountNameLabel,
                      helperText: l10n.createAccountNameHelper,
                      helperMaxLines: 2,
                    ),
                    validator: (value) {
                      final name = value?.trim() ?? '';
                      if (name.isEmpty) return l10n.commonRequired;
                      if (name.length < 2) return l10n.groupSettingsNameLength;
                      return null;
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.createAccountSubmit),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                EmailSignUpScreen(client: widget.client),
                          ),
                        ),
                child: Text(l10n.signUpEmailTitle),
              ),
              Text(
                l10n.welcomeTagline,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Creates a regular email account. Cloud sends a verification link; the
/// account can sign in once that link has been opened (the web page
/// completes it, then this app's Sign in works).
class EmailSignUpScreen extends StatefulWidget {
  const EmailSignUpScreen({super.key, required this.client});

  final SpliitClient client;

  @override
  State<EmailSignUpScreen> createState() => _EmailSignUpScreenState();
}

class _EmailSignUpScreenState extends State<EmailSignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.client.signUpWithEmail(
        name: _name.text.trim(),
        email: _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.signUpEmailSentTitle),
          content: Text(context.l10n.signUpEmailSent),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Creating an email account');
      if (!mounted) return;
      setState(() => _error = error.kind == ErrorKind.user && e is CloudAuthException
          ? e.message
          : error.kind == ErrorKind.connection
              ? context.l10n.errorConnection
              : context.l10n.signUpEmailFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signUpEmailTitle)),
      body: SingleChildScrollView(
        padding: withBottomInset(context, const EdgeInsets.all(16)),
        // AutofillGroup, so Android's autofill -- Bitwarden, Keyguard, a
        // keychain -- sees the three fields as one form to fill and, when
        // the screen closes, offers to save them (Android 8+).
        child: AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  ErrorMessage(_error!),
                  const SizedBox(height: 12),
                ],
                GroupedSection(children: [
                  _field(_name, l10n.createAccountNameLabel,
                      autofillHints: const [AutofillHints.name],
                      textInputAction: TextInputAction.next),
                  _field(_email, l10n.signInEmail,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [
                        AutofillHints.newUsername,
                        AutofillHints.email,
                      ],
                      textInputAction: TextInputAction.next),
                  _field(_password, l10n.signInPassword,
                      obscure: true,
                      // A new password, so managers offer to generate and
                      // save one rather than fill an old one in.
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _busy ? null : _submit()),
                ]),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n.signUpEmailSubmit),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label,
          {TextInputType? keyboardType,
          bool obscure = false,
          List<String>? autofillHints,
          TextInputAction? textInputAction,
          ValueChanged<String>? onSubmitted}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscure,
          autofillHints: autofillHints,
          autocorrect: false,
          enableSuggestions: !obscure,
          textInputAction: textInputAction,
          onFieldSubmitted: onSubmitted,
          decoration: InputDecoration(labelText: label),
          validator: (value) => (value == null || value.trim().isEmpty)
              ? context.l10n.commonRequired
              : null,
        ),
      );
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.client});

  final SpliitClient client;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await widget.client.signInWithEmail(
        email: _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Signing in to Spliit Cloud');
      if (!mounted) return;
      setState(() {
        _error = error.kind == ErrorKind.user
            ? (e is CloudAuthException ? e.message : context.l10n.signInFailed)
            : error.kind == ErrorKind.connection
                ? context.l10n.errorConnection
                : context.l10n.signInFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = context.l10n.commonRequired);
      return;
    }
    try {
      await widget.client.requestPasswordReset(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.passwordResetSent)),
      );
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Requesting a password reset');
      if (!mounted) return;
      setState(() => _error = error.kind == ErrorKind.connection
          ? context.l10n.errorConnection
          : context.l10n.signInFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signInTitle)),
      body: SingleChildScrollView(
        padding: withBottomInset(context, const EdgeInsets.all(16)),
        // AutofillGroup, so Android's autofill -- Bitwarden, Keyguard, a
        // keychain -- sees the email and password as one form to fill and
        // to offer to save (Android 8+).
        child: AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  ErrorMessage(_error!),
                  const SizedBox(height: 12),
                ],
                GroupedSection(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: TextFormField(
                      controller: _email,
                      autofocus: true,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      enableSuggestions: false,
                      // Signs the account in, so a manager fills it in;
                      // both hints, since managers look for either.
                      autofillHints: const [
                        AutofillHints.username,
                        AutofillHints.email,
                      ],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.signInEmail),
                      validator: (value) {
                        final email = value?.trim() ?? '';
                        if (email.isEmpty) return l10n.commonRequired;
                        if (!email.contains('@')) return l10n.signInEmail;
                        return null;
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _busy ? null : _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.signInPassword,
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (value) =>
                          (value == null || value.isEmpty) ? l10n.commonRequired : null,
                    ),
                  ),
                ]),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: _busy ? null : _forgot,
                    child: Text(l10n.signInForgot),
                  ),
                ),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.signInSubmit),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) =>
                                  CreateAccountScreen(client: widget.client),
                            ),
                          ),
                  child: Text(l10n.signInNoAccount),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pastes a saved anonymous recovery link or its code.
class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key, required this.client, this.initialCode});

  final SpliitClient client;
  final String? initialCode;

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  static final _codePattern = RegExp(r'spliit_anonymous_v1_[A-Za-z0-9_-]{43}');

  @override
  void initState() {
    super.initState();
    if (widget.initialCode case final code?) _code.text = code;
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String? _parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final direct = _codePattern.firstMatch(trimmed);
    if (direct != null) return direct.group(0);
    try {
      final uri = Uri.parse(trimmed);
      final fromFragment = Uri.splitQueryString(uri.fragment)['code'];
      return fromFragment == null
          ? null
          : _codePattern.firstMatch(fromFragment)?.group(0);
    } catch (_) {
      return null;
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final code = _parse(_code.text);
    if (code == null) {
      setState(() => _error = context.l10n.recoveryFailed);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await widget.client.signInWithRecoveryCode(code);
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Recovering a cloud account');
      if (!mounted) return;
      setState(() {
        _error = error.kind == ErrorKind.user
            ? (e is CloudAuthException ? e.message : context.l10n.recoveryFailed)
            : error.kind == ErrorKind.connection
                ? context.l10n.errorConnection
                : context.l10n.recoveryFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.recoveryTitle)),
      body: SingleChildScrollView(
        padding: withBottomInset(context, const EdgeInsets.all(16)),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                ErrorMessage(_error!),
                const SizedBox(height: 12),
              ],
              GroupedSection(children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: TextFormField(
                    controller: _code,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.recoveryPasteLabel,
                      helperText: l10n.recoveryPasteHelper,
                      helperMaxLines: 2,
                    ),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                            ? l10n.commonRequired
                            : null,
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.recoverySubmit),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen, non-dismissible recovery setup used after anonymous
/// sign-up and on launch while Cloud still reports setup incomplete.
///
/// Cloud refuses every account-bound API (including the group list) until
/// the recovery link is acknowledged (`ANONYMOUS_SETUP_REQUIRED`), so this
/// gate is part of the account, not an optional reminder.
class RecoverySetupScreen extends StatefulWidget {
  const RecoverySetupScreen({
    super.key,
    required this.client,
    required this.account,
    this.onSignOut,
    this.onDone,
  });

  final SpliitClient client;
  final CloudAccount account;
  final Future<void> Function()? onSignOut;
  final VoidCallback? onDone;

  @override
  State<RecoverySetupScreen> createState() => _RecoverySetupScreenState();
}

class _RecoverySetupScreenState extends State<RecoverySetupScreen> {
  AnonymousRecoveryKey? _key;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final key = await widget.client.setupAnonymousRecovery();
      if (!mounted) return;
      setState(() {
        _key = key;
        _busy = false;
      });
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Creating a recovery link');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.kind == ErrorKind.connection
            ? context.l10n.errorConnection
            : context.l10n.recoverySetupFailed;
      });
    }
  }

  Future<void> _copy() async {
    final key = _key;
    if (key == null) return;
    await Clipboard.setData(ClipboardData(text: key.recoveryUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.recoveryCopied)),
    );
  }

  Future<void> _share() async {
    final key = _key;
    if (key == null) return;
    await SharePlus.instance.share(ShareParams(
        text: key.recoveryUrl, subject: context.l10n.recoveryTitle));
  }

  Future<void> _done() async {
    final key = _key;
    if (key == null) return;
    setState(() => _busy = true);
    try {
      await widget.client.acknowledgeAnonymousRecovery(key.code);
      if (!mounted) return;
      if (widget.onDone != null) {
        widget.onDone!();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Confirming a recovery link');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.kind == ErrorKind.connection
            ? context.l10n.errorConnection
            : context.l10n.recoverySetupFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final key = _key;
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.recoverySaveTitle),
          automaticallyImplyLeading: false,
        ),
        body: SingleChildScrollView(
          padding: withBottomInset(context, const EdgeInsets.all(20)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.key_outlined,
                  size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(l10n.recoverySaveBody,
                  style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 20),
              if (_busy)
                const Center(child: CircularProgressIndicator())
              else if (_error != null) ...[
                ErrorMessage(_error!),
                const SizedBox(height: 12),
                OutlinedButton(
                    onPressed: _setup, child: Text(l10n.commonRetry)),
              ] else if (key != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    key.recoveryUrl,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy),
                      label: Text(l10n.recoveryCopy),
                      onPressed: _copy,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.share_outlined),
                      label: Text(l10n.recoveryShare),
                      onPressed: _share,
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy || _error != null ? null : _done,
                child: Text(l10n.recoveryDone),
              ),
              if (widget.onSignOut != null)
                TextButton(
                  onPressed: _busy ? null : () => widget.onSignOut!(),
                  child: Text(l10n.accountSignOut),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

///
/// Returns true once the user confirms they saved it, false when they
/// skipped. Either way the account already exists; this only decides
/// whether the safeguard is marked as done.
Future<bool> showRecoveryLinkSheet(
  BuildContext context, {
  required SpliitClient client,
  required CloudAccount account,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _RecoveryLinkSheet(client: client, account: account),
  );
  return saved ?? false;
}

class _RecoveryLinkSheet extends StatefulWidget {
  const _RecoveryLinkSheet({required this.client, required this.account});

  final SpliitClient client;
  final CloudAccount account;

  @override
  State<_RecoveryLinkSheet> createState() => _RecoveryLinkSheetState();
}

class _RecoveryLinkSheetState extends State<_RecoveryLinkSheet> {
  AnonymousRecoveryKey? _key;
  bool _busy = true;
  bool _copied = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      AnonymousRecoveryKey key;
      try {
        key = await widget.client.setupAnonymousRecovery();
      } on CloudAuthException catch (e) {
        // An already-saved key can't be shown again; replacing it is the
        // only way to get a new copy, and the server asks for an explicit
        // confirmation before doing so.
        if (e.code != 'RECOVERY_KEY_ALREADY_ACKNOWLEDGED') rethrow;
        key = await widget.client.replaceAnonymousRecovery();
      }
      if (!mounted) return;
      setState(() {
        _key = key;
        _busy = false;
      });
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Creating a recovery link');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.kind == ErrorKind.connection
            ? context.l10n.errorConnection
            : context.l10n.recoverySetupFailed;
      });
    }
  }

  Future<void> _copy() async {
    final key = _key;
    if (key == null) return;
    await Clipboard.setData(ClipboardData(text: key.recoveryUrl));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.recoveryCopied)),
    );
  }

  Future<void> _share() async {
    final key = _key;
    if (key == null) return;
    await SharePlus.instance.share(
      ShareParams(text: key.recoveryUrl, subject: context.l10n.recoveryTitle),
    );
  }

  Future<void> _done() async {
    final key = _key;
    if (key == null) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.client.acknowledgeAnonymousRecovery(key.code);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Confirming a recovery link');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.kind == ErrorKind.connection
            ? context.l10n.errorConnection
            : context.l10n.recoverySetupFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final key = _key;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.key_outlined,
                size: 36, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(l10n.recoverySaveTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              l10n.recoverySaveBody,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (_busy)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              ErrorMessage(_error!, textAlign: TextAlign.center)
            else if (key != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  key.recoveryUrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(_copied ? Icons.check : Icons.copy),
                      label: Text(l10n.recoveryCopy),
                      onPressed: _copy,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.share_outlined),
                      label: Text(l10n.recoveryShare),
                      onPressed: _share,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _error != null ? null : _done,
              child: Text(l10n.recoveryDone),
            ),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: Text(l10n.recoverySkip),
            ),
          ],
        ),
      ),
    );
  }
}
