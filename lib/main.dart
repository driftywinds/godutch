import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/cloud_connection.dart';
import 'api/spliit_client.dart';
import 'db/app_database.dart';
import 'db/connection.dart';
import 'legal/upstream_licenses.dart';
import 'l10n/app_localizations.dart';
import 'models/account.dart';
import 'screens/group_list_screen.dart';
import 'screens/join_group_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/exchange_rates.dart';
import 'services/group_url.dart';
import 'services/settings_service.dart';
import 'services/app_settings.dart';
import 'theme.dart';
import 'services/error_reporting.dart';
import 'services/receipt_cache.dart';
import 'services/receipt_scanner.dart';
import 'widgets/error_message.dart';
import 'widgets/text_scaled.dart';
import 'app_name.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Errors nothing caught, framework and async alike, go through the same
  // reporter the screens use (issue #119 review).
  installErrorHandlers(ErrorReporter.instance);
  // Spliit's and spliit-ios's notices on the licenses page (#109).
  registerUpstreamLicenses();
  final links = AppLinks();
  final settings = await AppSettings.load(SettingsService());
  // The cloud instance and its Better Auth cookie, read before the first
  // frame so a signed-in launch goes straight to the account's groups.
  final connection = await CloudConnection.load();
  // The Document Scanner downloads on first use: get it as soon as the
  // phone is online, so the first scan has it (#125). The same, once, for
  // the phone's language's receipt text model (#153).
  ReceiptScannerWarmup(
    const PlatformReceiptScanner(),
    phoneScript: ReceiptScript.forLanguage(WidgetsBinding.instance.platformDispatcher.locale.languageCode),
  ).start();
  runApp(Spliit2GoApp(
      settings: settings,
      home: AppRoot(
        connection: connection,
        links: links.uriLinkStream,
        initialLink: links.getInitialLink(),
      )));
}

/// The app's navigator, so the uncaught-error snack bar can open its
/// details sheet from above the Navigator (see UncaughtErrorPresenter).
final appNavigatorKey = GlobalKey<NavigatorState>();

class Spliit2GoApp extends StatelessWidget {
  const Spliit2GoApp({super.key, required this.settings, this.home});

  final AppSettings settings;

  /// Allows embedding a screen without opening the production database.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return AppSettingsScope(
      notifier: settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: appName,
          navigatorKey: appNavigatorKey,
          // Lets GroupListScreen hear about routes popped back to it
          // that weren't pushed by its own _openGroup -- e.g. _Root's
          // own auto-open-last-group push right below -- so it can
          // refresh a stale date span (issue #57).
          navigatorObservers: [groupListRouteObserver],
          // i18n (issues #37/#48/#51): AppLocalizations.of(context) (used
          // at every Text() call site) resolves through whatever
          // Localizations ancestor MaterialApp installs from these
          // delegates and supportedLocales -- the latter generated from
          // every lib/l10n/app_*.arb (en, fr, zh).
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Issue #51: the explicit language override from App settings;
          // null (the "System default" choice) lets Flutter resolve the
          // device locale against supportedLocales, falling back to the
          // first supported locale (en). Because this MaterialApp is
          // rebuilt whenever [settings] notifies (see the ListenableBuilder
          // above), changing the override re-localizes the whole running
          // app -- text, and every formatter that reads
          // Localizations.localeOf(context) -- with no restart.
          locale: settings.locale,
          theme: spliit2goLightTheme,
          darkTheme: spliit2goDarkTheme,
          highContrastTheme: spliit2goLightHighContrastTheme,
          highContrastDarkTheme: spliit2goDarkHighContrastTheme,
          themeMode: settings.themeMode,
          home: home ?? const AppRoot(),
          // Issue #24: modern Android (edge-to-edge is mandatory starting
          // with API 35) draws the app behind the status bar *and* the
          // bottom gesture/nav bar, and the system nav bar is always
          // transparent (Window.setNavigationBarColor is a no-op there), so
          // it's the app's job to paint behind it.
          //
          // #24 first inset every route above that bar with an app-wide
          // SafeArea(top: false), and painted the strip below it in the
          // theme's background. #197 keeps it for the sides only (a
          // landscape phone's cutout): content and sheets now run to the
          // screen's bottom edge (the group screen's floating bar has lists
          // scroll behind it), and a sheet's or dialog's barrier dims the
          // whole screen (#190). Each screen and sheet keeps its own last
          // row above the bar instead (withBottomInset, or a SafeArea of
          // its own). The backdrop below is kept for any route that leaves
          // the strip unpainted.
          //
          // Theme.of(context) here resolves to whichever of
          // theme/darkTheme MaterialApp picked for the current system
          // brightness, so both the backdrop and the overlay style stay
          // correct across light and dark mode (issue #25) without needing
          // their own brightness plumbing.
          builder: (context, child) => UncaughtErrorPresenter(
            reporter: ErrorReporter.instance,
            navigatorKey: appNavigatorKey,
            child: spliit2goAppBuilder(context, child),
          ),
        ),
      ),
    );
  }
}

/// The `MaterialApp.builder` above, pulled out as a top-level function
/// so its behavior (the Container backdrop + AnnotatedRegion, both
/// explained in the comment above) is unit-testable directly with a
/// throwaway `home`, without booting the real app's `_Root` and its
/// live AppDatabase/sqlite connection.
Widget spliit2goAppBuilder(BuildContext context, Widget? child) {
  final theme = Theme.of(context);
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: spliit2goSystemUiOverlayStyle(theme),
    child: Container(
      color: theme.scaffoldBackgroundColor,
      // Icons grow with the text size (#294), as text does: in the theme,
      // so a screen's own Theme copied from it keeps them.
      child: Theme(
        data: theme.copyWith(
          iconTheme: theme.iconTheme.copyWith(size: context.textScaled(24)),
          // A text button's icon, beside its label: Material's 18, scaled.
          textButtonTheme: TextButtonThemeData(style: ButtonStyle(iconSize: WidgetStatePropertyAll(context.textScaled(18)))),
          outlinedButtonTheme:
              OutlinedButtonThemeData(style: ButtonStyle(iconSize: WidgetStatePropertyAll(context.textScaled(18)))),
          filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(iconSize: WidgetStatePropertyAll(context.textScaled(18)))),
          // An icon button keeps Material's 24, in the top bar or not: its
          // card or target doesn't grow, and an icon beside text that
          // should grow sets its own size.
          iconButtonTheme: const IconButtonThemeData(style: ButtonStyle(iconSize: WidgetStatePropertyAll(24))),
        ),
        child: _DismissKeyboardOnTap(child: SafeArea(top: false, bottom: false, child: child!)),
      ),
    ),
  );
}

/// On an iPhone, a tap on nothing in particular puts the keyboard away,
/// as iOS apps do (Kenneth, 2026-10-11): Flutter's fields keep it up, and
/// the number pad has no key to close it. Anything that takes taps (a
/// button, a row, another field) gets them first. Android's keyboard has
/// its own button to hide it.
class _DismissKeyboardOnTap extends StatelessWidget {
  const _DismissKeyboardOnTap({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!const {TargetPlatform.iOS, TargetPlatform.macOS}.contains(Theme.of(context).platform)) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Not a button to VoiceOver, which has its own ways to close the
      // keyboard: otherwise the whole screen is one unlabeled tap target
      // (found by the form's guideline tests, #294).
      excludeFromSemantics: true,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: child,
    );
  }
}

/// Always shows GroupListScreen as the app's true root -- see
/// decisions/multi-group-design.md's revision after
/// github.com/sharneng/spliit2go/issues/12: GroupScreen is a detail view
/// *below* the list, not the other way around, so it's reached by
/// pushing onto the list (giving it a normal, always-valid back arrow
/// back to it) rather than the list sometimes being what you back out
/// of. "Launch straight into the last-used group" (decision 3) is done
/// as an automatic push right after the list mounts, once there's a
/// one-time migration (folding a legacy single-group install's
/// SettingsService values into the new AppDatabase-backed joined-groups
/// list) out of the way. Owns the AppDatabase instance (the one
/// long-lived object every screen shares) -- there's no DI framework,
/// just one screen graph.
/// The app root: restores the Spliit Cloud session, then shows either the
/// account screen's signed-out welcome or the account's group list.
///
/// Spliit Cloud is account-bound, so there is no per-group URL to join and
/// no local-only group to launch into before signing in. A group is on
/// this device only because the signed-in account is a member; the cloud
/// group list is the source of truth, with the local cache for offline
/// reading.
class AppRoot extends StatefulWidget {
  const AppRoot({
    super.key,
    this.db,
    this.links,
    this.initialLink,
    this.connection,
    this.clientFactory,
  });

  final AppDatabase? db;
  final Stream<Uri>? links;
  final Future<Uri?>? initialLink;
  final CloudConnection? connection;

  /// Overridable so widget tests can use a MockClient-backed cloud client.
  final SpliitClient Function(String baseUrl)? clientFactory;

  @override
  State<AppRoot> createState() => _RootState();
}

class _RootState extends State<AppRoot> {
  late final _db = widget.db ?? AppDatabase(openConnection());
  late final CloudConnection _connection = widget.connection ??
      CloudConnection.current ??
      CloudConnection(baseUrl: CloudConnection.defaultBaseUrl);
  late SpliitClient _client = _buildClient();
  StreamSubscription<Uri>? _linkSubscription;
  final _pendingLinks = <Uri>[];
  String? _activeLink;
  bool _readyForLinks = false;
  bool _loading = true;
  bool _recoveryRequired = false;
  CloudAccount? _account;

  SpliitClient _buildClient() =>
      widget.clientFactory?.call(_connection.baseUrl) ??
      SpliitClient(
          baseUrl: _connection.baseUrl, connection: _connection);

  Future<void> _start() async {
    try {
      final initial = await widget.initialLink;
      if (initial != null) _receiveLink(initial);
    } catch (error, stack) {
      ErrorReporter.instance
          .report(error, stack, operation: 'Reading the initial app link');
    }
    try {
      _account = await _client.restoreSession();
      if (_account case final account?) {
        // Never show one account's cached groups under another's session.
        final prefs = await SharedPreferences.getInstance();
        final owner = prefs.getString('cloud_cache_owner');
        if (owner != null && owner != account.id) {
          await _db.clearAllGroups();
        }
        await prefs.setString('cloud_cache_owner', account.id);
      }
      if (_account?.isAnonymous == true) {
        // Cloud refuses every account-bound call until the recovery link
        // is acknowledged; gate before the group list rather than showing
        // its errors.
        final status = await _client.anonymousRecoveryStatus();
        _recoveryRequired = !status.onboardingCompleted;
      }
    } catch (error, stack) {
      ErrorReporter.instance
          .report(error, stack, operation: 'Restoring the cloud session');
    }
    if (!mounted) return;
    setState(() => _loading = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _readyForLinks = true;
      if (_pendingLinks.isNotEmpty) unawaited(_drainLinks());
    });
  }

  @override
  void initState() {
    super.initState();
    _linkSubscription =
        widget.links?.listen(_receiveLink, onError: (Object error, StackTrace stack) {
      ErrorReporter.instance
          .report(error, stack, operation: 'Receiving an app link');
    });
    unawaited(ReceiptCache.of(_db).sweep());
    unawaited(ExchangeRates.of(_db).cleanUp());
    unawaited(_applyReceiptLimit());
    unawaited(_start());
  }

  Future<void> _applyReceiptLimit() async {
    try {
      ReceiptCache.of(_db).limit =
          await SettingsService().receiptStorageLimitMb() * 1024 * 1024;
    } catch (e, st) {
      ErrorReporter.instance
          .report(e, st, operation: 'Reading the receipt storage limit');
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    if (widget.db == null) unawaited(_db.close());
    super.dispose();
  }

  /// A cloud link this app can act on: a group invite or a recovery link.
  /// Both are identified by their path, so a self-hosted instance works
  /// exactly like spliit.cloud.
  String? _linkKey(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (uri.path.startsWith('/groups/')) {
      final token = uri.queryParameters['invite'];
      if (token != null && token.isNotEmpty) return 'invite:${uri.path}:$token';
      return null;
    }
    if (uri.path == '/auth/recover') return 'recover:${uri.fragment}';
    return null;
  }

  void _receiveLink(Uri uri) {
    final key = _linkKey(uri);
    if (key == null ||
        key == _activeLink ||
        _pendingLinks.any((link) => _linkKey(link) == key)) {
      return;
    }
    _pendingLinks.add(uri);
    if (_readyForLinks) unawaited(_drainLinks());
  }

  Future<void> _drainLinks() async {
    if (_activeLink != null || !mounted || !_readyForLinks) return;
    while (_pendingLinks.isNotEmpty && mounted) {
      final uri = _pendingLinks.removeAt(0);
      _activeLink = _linkKey(uri);
      try {
        if (uri.path == '/auth/recover') {
          if (_account == null) {
            final code = parseRecoveryLink(uri.fragment);
            if (code == null) continue;
            final account = await Navigator.of(context).push<CloudAccount>(
              MaterialPageRoute(
                builder: (_) =>
                    RecoveryScreen(client: _client, initialCode: code),
              ),
            );
            if (account != null && mounted) await _signedIn(account);
          }
          continue;
        }
        if (_account == null) {
          // The welcome screen owns invite links; keeping the pending link
          // until the user signs in avoids joining a group as the wrong
          // account.
          _pendingLinks.add(uri);
          break;
        }
        if (uri.path.startsWith('/groups/')) {
          final token = uri.queryParameters['invite'];
          if (token == null) continue;
          final joined = await Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (_) => JoinGroupScreen(
                db: _db,
                client: _client,
                initialUrl: uri.toString(),
                clientFactory: widget.clientFactory,
              ),
            ),
          );
          if (!mounted) return;
          if (joined != null) {
            // The group list refreshes on its own route return.
          }
        }
      } finally {
        _activeLink = null;
      }
    }
  }

  Future<void> _signedIn(CloudAccount account) async {
    await _db.clearAllGroups();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cloud_cache_owner', account.id);
    if (!mounted) return;
    setState(() {
      _account = account;
      _recoveryRequired = false;
    });
    if (_pendingLinks.isNotEmpty) unawaited(_drainLinks());
  }

  Future<void> _signedOut() async {
    await _db.clearAllGroups();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cloud_cache_owner');
    if (!mounted) return;
    setState(() {
      _account = null;
      _recoveryRequired = false;
    });
  }

  Future<void> _serverChanged(String value) async {
    await _connection.setBaseUrl(value);
    if (!mounted) return;
    setState(() {
      _client = _buildClient();
      _account = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final account = _account;
    if (account == null) {
      return WelcomeScreen(
        client: _client,
        connection: _connection,
        onSignedIn: _signedIn,
        onServerChanged: _serverChanged,
      );
    }
    if (_recoveryRequired) {
      return RecoverySetupScreen(
        client: _client,
        account: account,
        onSignOut: () async {
          await _client.signOut();
          await _signedOut();
        },
        onDone: () => setState(() => _recoveryRequired = false),
      );
    }
    return GroupListScreen(
      db: _db,
      client: _client,
      account: account,
      onAccountChanged: (value) => setState(() => _account = value),
      onSignOut: _signedOut,
    );
  }
}

