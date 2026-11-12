import 'package:flutter/foundation.dart';

import '../settings_service.dart';
import 'notification_message.dart';

/// The notification settings, read once per poll.
@immutable
class NotificationPrefs {
  const NotificationPrefs({
    this.enabled = false,
    this.categories = allCategories,
    this.interval = defaultInterval,
  });

  static const allCategories = <NotificationCategory>{
    NotificationCategory.expenses,
    NotificationCategory.comments,
    NotificationCategory.settlements,
    NotificationCategory.members,
  };

  /// Android's WorkManager will not run periodic work more often than this.
  static const defaultInterval = Duration(minutes: 15);

  /// What "Check every" offers: the floor, and two calmer choices.
  static const intervals = [
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 60),
  ];

  final bool enabled;

  /// The kinds worth a notification; the rest are read past, so their events
  /// don't come back later.
  final Set<NotificationCategory> categories;

  final Duration interval;

  /// Whether an event in [category] is worth a notification.
  bool allows(NotificationCategory category) =>
      enabled && categories.contains(category);

  /// [minutes] as one of [intervals]: anything else falls back to the
  /// closest allowed choice.
  static Duration intervalFor(int? minutes) {
    if (minutes == null) return defaultInterval;
    final wanted = Duration(minutes: minutes);
    if (intervals.contains(wanted)) return wanted;
    return intervals.reduce(
        (a, b) => (a - wanted).abs() <= (b - wanted).abs() ? a : b);
  }

  static Future<NotificationPrefs> load(SettingsService settings) async {
    final enabled = await settings.notificationsEnabled();
    final categories = <NotificationCategory>{};
    for (final category in NotificationCategory.values) {
      if (await settings.notificationCategoryEnabled(category.id)) {
        categories.add(category);
      }
    }
    return NotificationPrefs(
      enabled: enabled,
      categories: categories,
      interval: intervalFor(await settings.notificationIntervalMinutes()),
    );
  }
}
