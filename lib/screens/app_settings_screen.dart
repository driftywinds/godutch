import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../l10n/app_locales.dart';
import '../l10n/context_l10n.dart';
import '../services/app_settings.dart';
import '../services/error_reporting.dart';
import '../services/exchange_rates.dart';
import '../services/notifications/background.dart';
import '../services/notifications/local_notifications.dart';
import '../services/notifications/notification_message.dart';
import '../services/notifications/notification_prefs.dart';
import '../services/receipt_cache.dart';
import '../services/receipt_downloader.dart';
import '../services/settings_service.dart';
import '../utils/byte_size.dart';
import '../utils/date_format.dart';
import '../widgets/error_message.dart';
import 'about_screen.dart';
import '../widgets/app_switch.dart';
import '../widgets/grouped_section.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/confirm_dialog.dart';

/// App-wide preferences, separate from an individual group's settings.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key, this.receipts});

  /// The receipts stored on this device, for the Storage section (#123).
  /// Without it, the section isn't shown.
  final ReceiptCache? receipts;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appSettingsTitle)),
      body: AboveBottomBar(child: GroupedScrollClip(
        child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          GroupedSection(caption: l10n.appSettingsTheme, children: [
            for (final option in [
              (ThemeMode.light, l10n.appSettingsThemeLight),
              (ThemeMode.dark, l10n.appSettingsThemeDark),
              (ThemeMode.system, l10n.appSettingsThemeSystem),
            ])
              _optionTile(
                context,
                settings: settings,
                label: option.$2,
                selected: settings.themeMode == option.$1,
                onSelected: () => settings.setThemeMode(option.$1),
              ),
          ]),
          // Issue #51: explicit language override. "System default" first
          // (clears the override); the language names are each language's
          // own name for itself, deliberately untranslated, so the list
          // stays findable from any UI language.
          GroupedSection(caption: l10n.appSettingsLanguage, children: [
            _optionTile(
              context,
              settings: settings,
              label: l10n.appSettingsLanguageSystem,
              selected: settings.locale == null,
              onSelected: () => settings.setLocale(null),
            ),
            for (final option in appLocaleOptions)
              _optionTile(
                context,
                settings: settings,
                label: option.nativeName,
                selected: settings.locale == option.locale,
                onSelected: () => settings.setLocale(option.locale),
              ),
          ]),
          GroupedSection(caption: l10n.appSettingsSync, children: const [_AutoRefreshTile()]),
          GroupedSection(caption: l10n.notificationsTitle, children: const [_NotificationsSettings()]),
          if (receipts case final receipts?)
            GroupedSection(caption: l10n.appSettingsStorage, children: [
              _ReceiptStorageTile(receipts),
              _ReceiptDownloadSettings(receipts),
              _ExchangeRatesTile(ExchangeRates.of(receipts.db)),
            ]),
          GroupedSection(caption: l10n.aboutTitle, children: [
            GroupedRow(
              title: Text(l10n.appSettingsAbout),
              navigates: true,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const AboutScreen())),
            ),
          ]),
        ],
      ))),
    );
  }

  /// One selectable row: runs [onSelected] and, if persisting the choice
  /// fails (the setting reverts itself before rethrowing), tells the user.
  Widget _optionTile(
    BuildContext context, {
    required AppSettings settings,
    required String label,
    required bool selected,
    required Future<void> Function() onSelected,
  }) =>
      GroupedRow(
        title: Text(label),
        selected: selected,
        trailing: selected ? const Icon(Icons.check) : null,
        enabled: !settings.saving,
        onTap: () async {
          try {
            await onSelected();
          } catch (e, st) {
            // Saving a setting to the device's storage has no expected
            // failure: logged, with details (#119 review).
            final error = ErrorReporter.instance.report(e, st, operation: 'Saving an app setting');
            if (!context.mounted) return;
            showErrorSnackBar(context, context.l10n.appSettingsSaveError,
                diagnostics: error.diagnostics);
          }
        },
      );
}

/// The exchange rates saved for offline use, with Update (#252): the
/// "before I go offline" button. One update covers every currency.
class _ExchangeRatesTile extends StatefulWidget {
  const _ExchangeRatesTile(this.rates);
  final ExchangeRates rates;

  @override
  State<_ExchangeRatesTile> createState() => _ExchangeRatesTileState();
}

class _ExchangeRatesTileState extends State<_ExchangeRatesTile> {
  SavedRates? _saved;
  bool _loaded = false;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final saved = await widget.rates.saved();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _loaded = true;
      });
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Reading saved exchange rates');
    }
  }

  Future<void> _update() async {
    setState(() => _updating = true);
    try {
      await widget.rates.downloadAhead(force: true);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.l10n.appSettingsExchangeRatesUpdated)));
    } catch (e, st) {
      // Offline says so; anything else was logged by the fetch, with
      // details.
      final error = ErrorReporter.instance.report(e, st, operation: 'Updating exchange rates');
      if (mounted) {
        showErrorSnackBar(
            context,
            error.isUnexpected
                ? context.l10n.appSettingsExchangeRatesFailed
                : context.l10n.appSettingsExchangeRatesOffline,
            diagnostics: error.diagnostics);
      }
    } finally {
      if (mounted) setState(() => _updating = false);
      await _read();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final saved = _saved;
    return GroupedRow(
      title: Text(l10n.appSettingsExchangeRates),
      subtitle: Text(!_loaded
          ? ''
          : saved == null
              ? l10n.appSettingsExchangeRatesNone
              : l10n.appSettingsExchangeRatesSaved(
                  formatDate(saved.publishedOn, locale: context.appLocale, withYear: false),
                  saved.currencies)),
      // Under the name, at the end, when they don't fit (#296).
      value: TextButton(
        onPressed: _updating ? null : _update,
        child: Text(l10n.appSettingsExchangeRatesUpdate),
      ),
    );
  }
}

/// How much space stored receipts use, with Clear (#123). They're only
/// copies: Clear removes them from this device, and they download again
/// when opened.
class _ReceiptStorageTile extends StatefulWidget {
  const _ReceiptStorageTile(this.receipts);
  final ReceiptCache receipts;

  @override
  State<_ReceiptStorageTile> createState() => _ReceiptStorageTileState();
}

class _ReceiptStorageTileState extends State<_ReceiptStorageTile> {
  int? _bytes;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    try {
      final bytes = await widget.receipts.usage();
      if (mounted) setState(() => _bytes = bytes);
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Measuring stored receipts');
    }
  }

  Future<void> _clear() async {
    final l10n = context.l10n;
    final confirmed = await showConfirmDialog(context,
        title: l10n.appSettingsReceiptsClearTitle,
        message: [l10n.appSettingsReceiptsClearBody],
        action: l10n.appSettingsReceiptsClear,
        destructive: true);
    if (!confirmed || !mounted) return;
    setState(() => _clearing = true);
    final downloads = ReceiptDownloader.of(widget.receipts.db);
    try {
      // Favorite groups' downloads stop, and start again only at their
      // next refresh (#127).
      downloads.cancelAll();
      await widget.receipts.clear();
      await downloads.refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.l10n.appSettingsReceiptsCleared)));
    } catch (e, st) {
      // Deleting this app's own files has no expected failure (#119).
      final error = ErrorReporter.instance.report(e, st, operation: 'Clearing stored receipts');
      if (mounted) {
        showErrorSnackBar(context, context.l10n.appSettingsReceiptsClearFailed,
            diagnostics: error.diagnostics);
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
      await _measure();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bytes = _bytes;
    return GroupedRow(
      title: Text(l10n.appSettingsReceipts),
      subtitle: Text(bytes == null
          ? ''
          : bytes == 0
              ? l10n.appSettingsReceiptsNone
              : formatByteSize(context, bytes)),
      value: TextButton(
        onPressed: bytes == null || bytes == 0 || _clearing ? null : _clear,
        child: Text(l10n.appSettingsReceiptsClear),
      ),
    );
  }
}

/// Downloading favorite groups' receipts ahead, and the limit on what
/// receipts may take (#127).
class _ReceiptDownloadSettings extends StatefulWidget {
  const _ReceiptDownloadSettings(this.receipts);
  final ReceiptCache receipts;

  @override
  State<_ReceiptDownloadSettings> createState() => _ReceiptDownloadSettingsState();
}

class _ReceiptDownloadSettingsState extends State<_ReceiptDownloadSettings> {
  final _settings = SettingsService();
  ReceiptDownloadMode? _mode;
  int? _limitMb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final mode = await _settings.receiptDownloadMode();
      final limit = await _settings.receiptStorageLimitMb();
      if (!mounted) return;
      setState(() {
        _mode = mode;
        _limitMb = limit;
      });
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Reading the receipt settings');
    }
  }

  String _modeLabel(ReceiptDownloadMode mode) => switch (mode) {
        ReceiptDownloadMode.off => context.l10n.appSettingsReceiptDownloadsOff,
        ReceiptDownloadMode.wifiOnly => context.l10n.appSettingsReceiptDownloadsWifiOnly,
        ReceiptDownloadMode.always => context.l10n.appSettingsReceiptDownloadsAlways,
      };

  String _limitLabel(int mb) => context.l10n
      .bytesMegabytes(NumberFormat.decimalPattern(context.appLocale.toString()).format(mb));

  Future<T?> _choose<T>(String title, List<(T, String)> options, T current) =>
      showDialog<T>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: Text(title),
          children: [
            for (final (value, label) in options)
              ListTile(
                title: Text(label),
                trailing: value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(dialogContext, value),
              ),
          ],
        ),
      );

  Future<void> _save(Future<void> Function() save) async {
    try {
      await save();
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st, operation: 'Saving an app setting');
      if (mounted) {
        showErrorSnackBar(context, context.l10n.appSettingsSaveError,
            diagnostics: error.diagnostics);
      }
    }
    await _load();
  }

  Future<void> _chooseMode() async {
    final current = _mode;
    if (current == null) return;
    final mode = await _choose(context.l10n.appSettingsReceiptDownloads,
        [for (final m in ReceiptDownloadMode.values) (m, _modeLabel(m))], current);
    if (mode == null || mode == current) return;
    await _save(() async {
      await _settings.setReceiptDownloadMode(mode);
      final downloads = ReceiptDownloader.of(widget.receipts.db);
      // Turned off, or narrowed to Wi-Fi: what's running stops, and the
      // next refresh starts again under the new setting.
      downloads.cancelAll();
      await downloads.refreshAll();
    });
  }

  Future<void> _chooseLimit() async {
    final current = _limitMb;
    if (current == null) return;
    final mb = await _choose(context.l10n.appSettingsReceiptLimit,
        [for (final c in receiptStorageLimitChoicesMb) (c, _limitLabel(c))], current);
    if (mb == null || mb == current) return;
    await _save(() async {
      await _settings.setReceiptStorageLimitMb(mb);
      widget.receipts.limit = mb * 1024 * 1024;
      // A lower limit: the viewing cache makes room now.
      await widget.receipts.makeRoom(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = _mode, limit = _limitMb;
    return Column(children: [
      GroupedRow(
        title: Text(l10n.appSettingsReceiptDownloads),
        subtitle: Text(mode == null
            ? l10n.appSettingsReceiptDownloadsHint
            : '${_modeLabel(mode)} · ${l10n.appSettingsReceiptDownloadsHint}'),
        onTap: mode == null ? null : _chooseMode,
      ),
      const GroupedDivider(),
      GroupedRow(
        title: Text(l10n.appSettingsReceiptLimit),
        subtitle: limit == null ? null : Text(_limitLabel(limit)),
        onTap: limit == null ? null : _chooseLimit,
      ),
    ]);
  }
}

/// How often the open group refreshes on its own (#301).
class _AutoRefreshTile extends StatefulWidget {
  const _AutoRefreshTile();

  @override
  State<_AutoRefreshTile> createState() => _AutoRefreshTileState();
}

class _AutoRefreshTileState extends State<_AutoRefreshTile> {
  final _settings = SettingsService();
  AutoRefresh? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await _settings.autoRefresh();
      if (mounted) setState(() => _value = value);
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Reading the auto refresh setting');
    }
  }

  String _label(AutoRefresh value) => switch (value.interval) {
        null => context.l10n.appSettingsAutoRefreshOff,
        final interval when interval.inMinutes < 60 =>
          context.l10n.appSettingsAutoRefreshMinutes(interval.inMinutes),
        _ => context.l10n.appSettingsAutoRefreshHour,
      };

  Future<void> _choose() async {
    final current = _value;
    if (current == null) return;
    final value = await showDialog<AutoRefresh>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(context.l10n.appSettingsAutoRefresh),
        children: [
          for (final v in AutoRefresh.values)
            ListTile(
              title: Text(_label(v)),
              trailing: v == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(dialogContext, v),
            ),
        ],
      ),
    );
    if (value == null || value == current) return;
    try {
      await _settings.setAutoRefresh(value);
    } catch (e, st) {
      final error = ErrorReporter.instance.report(e, st, operation: 'Saving an app setting');
      if (mounted) {
        showErrorSnackBar(context, context.l10n.appSettingsSaveError, diagnostics: error.diagnostics);
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final value = _value;
    return GroupedRow(
      title: Text(l10n.appSettingsAutoRefresh),
      subtitle: Text(value == null
          ? l10n.appSettingsAutoRefreshHint
          : '${_label(value)} · ${l10n.appSettingsAutoRefreshHint}'),
      onTap: value == null ? null : _choose,
    );
  }
}

/// Notifications: whether to check at all, what for, and how often. Android
/// decides when exactly it runs the check; the hint says so rather than
/// promising a time.
class _NotificationsSettings extends StatefulWidget {
  const _NotificationsSettings();

  @override
  State<_NotificationsSettings> createState() => _NotificationsSettingsState();
}

class _NotificationsSettingsState extends State<_NotificationsSettings> {
  final _settings = SettingsService();
  final _notifications = LocalNotifications.instance;
  bool? _enabled;
  Set<NotificationCategory>? _categories;
  Duration? _interval;
  bool _muted = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await NotificationPrefs.load(_settings);
      final muted = !await _notifications.enabledOnDevice();
      if (!mounted) return;
      setState(() {
        _enabled = prefs.enabled;
        _categories = prefs.categories;
        _interval = prefs.interval;
        _muted = muted;
      });
    } catch (e, st) {
      ErrorReporter.instance
          .report(e, st, operation: 'Reading the notification settings');
    }
  }

  /// Runs [save], then re-reads what's stored so the rows show the truth
  /// even when a write failed.
  Future<void> _save(Future<void> Function() save) async {
    try {
      await save();
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Saving an app setting');
      if (mounted) {
        showErrorSnackBar(context, context.l10n.appSettingsSaveError,
            diagnostics: error.diagnostics);
      }
    }
    await _load();
  }

  Future<void> _setEnabled(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _save(() async {
        if (value) {
          // Android 13 asks here, right after the user said yes, not on
          // launch: a prompt out of nowhere is the quickest way to a no.
          await _notifications.requestPermission();
          await _settings.setNotificationsEnabled(true);
        } else {
          await _settings.setNotificationsEnabled(false);
        }
        // The poll follows the switch without waiting for a restart.
        await NotificationsSchedule.sync();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setCategory(NotificationCategory category, bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _save(
          () => _settings.setNotificationCategoryEnabled(category.id, value));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseInterval() async {
    final current = _interval;
    if (current == null || _busy) return;
    final l10n = context.l10n;
    final chosen = await showDialog<Duration>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.notificationsInterval),
        children: [
          for (final interval in NotificationPrefs.intervals)
            ListTile(
              title: Text(_intervalLabel(l10n, interval)),
              trailing: interval == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(dialogContext, interval),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == current) return;
    setState(() => _busy = true);
    try {
      await _save(() async {
        await _settings.setNotificationIntervalMinutes(chosen.inMinutes);
        await NotificationsSchedule.sync();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendTest() async {
    final l10n = context.l10n;
    await _notifications.show(NotificationMessage(
      id: 1,
      category: NotificationCategory.expenses,
      title: l10n.notificationsTestTitle,
      body: l10n.notificationsTestBody,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.notificationsTestSent)));
  }

  String _intervalLabel(AppLocalizations l10n, Duration interval) =>
      interval.inMinutes < 60
          ? l10n.notificationsEveryMinutes(interval.inMinutes)
          : l10n.notificationsEveryHour;

  String _categoryName(AppLocalizations l10n, NotificationCategory category) =>
      switch (category) {
        NotificationCategory.expenses => l10n.notificationChannelExpenses,
        NotificationCategory.comments => l10n.notificationChannelComments,
        NotificationCategory.settlements =>
          l10n.notificationChannelSettlements,
        NotificationCategory.members => l10n.notificationChannelMembers,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = _enabled;
    final categories = _categories;
    final interval = _interval;
    final ready = enabled != null && categories != null && interval != null;
    return Column(children: [
      GroupedRow(
        title: Text(l10n.notificationsMaster),
        subtitle: Text(enabled == true && _muted
            ? l10n.notificationsBlocked
            : l10n.notificationsMasterHint),
        trailing: AppSwitch(
          value: enabled ?? false,
          onChanged: ready && !_busy ? _setEnabled : null,
        ),
      ),
      // The rest only matters once it's on.
      if (enabled == true) ...[
        for (final category in NotificationCategory.values) ...[
          const GroupedDivider(),
          GroupedRow(
            title: Text(_categoryName(l10n, category)),
            trailing: AppSwitch(
              value: categories!.contains(category),
              onChanged: ready && !_busy
                  ? (value) => _setCategory(category, value)
                  : null,
            ),
          ),
        ],
        const GroupedDivider(),
        GroupedRow(
          title: Text(l10n.notificationsInterval),
          value: Text(_intervalLabel(l10n, interval!)),
          onTap: ready && !_busy ? _chooseInterval : null,
        ),
        const GroupedDivider(),
        GroupedRow(title: Text(l10n.notificationsTest), onTap: _sendTest),
      ],
    ]);
  }
}
