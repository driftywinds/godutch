import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../api/cloud_connection.dart';
import '../../api/spliit_client.dart';
import '../../db/app_database.dart';
import '../../db/connection.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/app_locales.dart';
import '../error_reporting.dart';
import '../settings_service.dart';
import 'activity_poller.dart';
import 'local_notifications.dart';
import 'notification_message.dart';
import 'notification_prefs.dart';

/// The periodic task, under one unique name: registering again replaces the
/// schedule rather than adding a second.
const notificationTaskName = 'godutch-notifications';

/// WorkManager's entry point: a bare isolate, no UI, no screens.
@pragma('vm:entry-point')
void notificationCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await pollForNotifications();
    } catch (e, st) {
      ErrorReporter.instance
          .report(e, st, operation: 'Checking for new activity');
    }
    // Never retry: a retry would ring twice for the same change, and the
    // next period asks again anyway.
    return true;
  });
}

/// One poll, wherever it runs: the background isolate, or a test.
Future<int> pollForNotifications() async {
  final settings = SettingsService();
  final prefs = await NotificationPrefs.load(settings);
  if (!prefs.enabled) return 0;
  final connection = await CloudConnection.load();
  if (!connection.hasSession) return 0;
  final db = AppDatabase(openConnection());
  try {
    final client =
        SpliitClient(baseUrl: connection.baseUrl, connection: connection);
    final l10n = await loadNotificationStrings(settings);
    final notifications = LocalNotifications.instance;
    await notifications.initialize(channelNames: channelNames(l10n));
    final shown = await ActivityPoller(
      db: db,
      client: client,
      sink: notifications,
      settings: settings,
      l10n: l10n,
    ).poll();
    // Reading the session can rotate its cookie; keep the rotation even if
    // this isolate is about to end, or the app next opens signed out.
    await connection.save();
    return shown;
  } finally {
    await db.close();
  }
}

/// The channels' names, as Android's notification settings list them.
Map<NotificationCategory, String> channelNames(AppLocalizations l10n) => {
      NotificationCategory.expenses: l10n.notificationChannelExpenses,
      NotificationCategory.comments: l10n.notificationChannelComments,
      NotificationCategory.settlements: l10n.notificationChannelSettlements,
      NotificationCategory.members: l10n.notificationChannelMembers,
    };

/// The app's language, for a notification built where there is no
/// `BuildContext`: the chosen one, else the phone's, else English.
Future<AppLocalizations> loadNotificationStrings(SettingsService settings) async {
  final tag = await settings.preferredLocaleTag();
  final wanted =
      localeFromTag(tag) ?? WidgetsBinding.instance.platformDispatcher.locale;
  final locale = AppLocalizations.supportedLocales.firstWhere(
    (supported) => supported.languageCode == wanted.languageCode,
    orElse: () => AppLocalizations.supportedLocales.first,
  );
  return AppLocalizations.delegate.load(locale);
}

/// Keeps Android's periodic work in step with the setting: one task while
/// notifications are on, none while they're off.
class NotificationsSchedule {
  const NotificationsSchedule._();

  /// Registers the poll (or stops it), after the setting or the interval
  /// changed, and at every launch.
  static Future<void> sync() async {
    try {
      final prefs = await NotificationPrefs.load(SettingsService());
      if (!prefs.enabled) {
        await Workmanager().cancelByUniqueName(notificationTaskName);
        return;
      }
      // Registers the isolate's entry point, and keeps the handle for the
      // task WorkManager runs with the app closed.
      await Workmanager().initialize(notificationCallbackDispatcher);
      await Workmanager().registerPeriodicTask(
        notificationTaskName,
        notificationTaskName,
        frequency: prefs.interval,
        // `update` rather than `keep`: a changed interval takes effect, and
        // a phone with a shorter one already registered is moved to it.
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        // Doze decides the rest; let it wait for a network rather than wake
        // to find none.
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } catch (e, st) {
      // Desktop builds and widget tests have no WorkManager, and scheduling
      // is never worth failing a launch over.
      if (!_unsupported(e)) {
        ErrorReporter.instance
            .report(e, st, operation: 'Scheduling the notification poll');
      }
    }
  }

  /// Signed out: nothing more to check.
  static Future<void> cancel() async {
    try {
      await Workmanager().cancelByUniqueName(notificationTaskName);
    } catch (e, st) {
      if (!_unsupported(e)) {
        ErrorReporter.instance
            .report(e, st, operation: 'Stopping the notification poll');
      }
    }
  }

  /// No plugin behind the call: the desktop, or a test. WorkManager's own
  /// fallback throws [UnimplementedError] there.
  static bool _unsupported(Object error) =>
      isMissingPlugin(error) ||
      error is UnimplementedError ||
      (error is PlatformException && error.code == 'channel-error');
}
