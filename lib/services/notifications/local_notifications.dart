import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../error_reporting.dart';
import 'notification_message.dart';

/// This phone's notifications: the four channels, the permission, and what a
/// tap asks the app to open.
///
/// A single instance, because a tapped notification arrives long after the
/// screen that posted it has gone. Nothing here is ever fatal: a desktop
/// build and a widget test have no plugin behind it, which is a normal state
/// rather than an error, and losing a notification is never worth losing the
/// app over.
class LocalNotifications implements NotificationSink {
  LocalNotifications._();

  static final instance = LocalNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _channelNames = <NotificationCategory, String>{};
  bool _initialized = false;

  /// What a tap asked for, for the app root to open; cleared once it has.
  final openRequest = ValueNotifier<NotificationTarget?>(null);

  static bool get _supported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Creates the channels and picks up a notification that launched the app.
  /// [channelNames] are the localized names the system's settings list.
  Future<void> initialize({
    required Map<NotificationCategory, String> channelNames,
  }) async {
    if (_initialized || !_supported) return;
    _channelNames
      ..clear()
      ..addAll(channelNames);
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_godutch'),
          // Asked for when the user turns notifications on, not at launch.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (response) => _tapped(response.payload),
      );
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final category in NotificationCategory.values) {
        // The system keeps a channel once it exists: only its name and
        // description can change later, never its id or importance.
        await android?.createNotificationChannel(AndroidNotificationChannel(
          category.id,
          channelNames[category] ?? category.id,
          importance: Importance.defaultImportance,
        ));
      }
      _initialized = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _tapped(launch?.notificationResponse?.payload);
      }
    } catch (_) {
      // No plugin on this platform (desktop, tests): nothing to post.
    }
  }

  void _tapped(String? payload) {
    final target = NotificationTarget.fromPayload(payload);
    if (target != null) openRequest.value = target;
  }

  /// Android 13's runtime permission (and iOS's alert). True when the phone
  /// will show notifications.
  Future<bool> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? true;
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(alert: true, badge: true, sound: true) ??
          true;
    } catch (_) {
      // No plugin: there is no permission to ask for.
      return true;
    }
  }

  /// Whether the phone allows any notification from this app at all: the
  /// user may have turned them off in the system settings.
  Future<bool> enabledOnDevice() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.areNotificationsEnabled() ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> show(NotificationMessage message) async {
    try {
      await _plugin.show(
        id: message.id,
        title: message.title,
        body: message.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            message.category.id,
            _channelNames[message.category] ?? message.category.id,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            // The whole sentence, even where the shade has one line for it.
            styleInformation: BigTextStyleInformation(message.body),
          ),
        ),
        payload: message.payload,
      );
    } catch (e, st) {
      // Initialized and still failing is worth knowing about; before that,
      // the platform simply has no plugin.
      if (_initialized && !isMissingPlugin(e)) {
        ErrorReporter.instance
            .report(e, st, operation: 'Showing a notification');
      }
    }
  }
}
