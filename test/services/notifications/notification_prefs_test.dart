import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:godutch/services/notifications/notification_message.dart';
import 'package:godutch/services/notifications/notification_prefs.dart';
import 'package:godutch/services/settings_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('off by default, every kind on, every 15 minutes', () async {
    final prefs = await NotificationPrefs.load(SettingsService());
    expect(prefs.enabled, isFalse);
    expect(prefs.categories, containsAll(NotificationCategory.values));
    expect(prefs.interval, const Duration(minutes: 15));
    // Off means off, whatever is ticked.
    for (final category in NotificationCategory.values) {
      expect(prefs.allows(category), isFalse);
    }
  });

  test('a saved choice comes back', () async {
    final settings = SettingsService();
    await settings.setNotificationsEnabled(true);
    await settings.setNotificationCategoryEnabled(
        NotificationCategory.comments.id, false);
    await settings.setNotificationIntervalMinutes(60);

    final prefs = await NotificationPrefs.load(settings);
    expect(prefs.enabled, isTrue);
    expect(prefs.allows(NotificationCategory.expenses), isTrue);
    expect(prefs.allows(NotificationCategory.comments), isFalse);
    expect(prefs.interval, const Duration(hours: 1));
  });

  test('an interval outside the offered ones falls back to the nearest', () {
    expect(NotificationPrefs.intervalFor(null), const Duration(minutes: 15));
    expect(NotificationPrefs.intervalFor(15), const Duration(minutes: 15));
    expect(NotificationPrefs.intervalFor(30), const Duration(minutes: 30));
    expect(NotificationPrefs.intervalFor(60), const Duration(hours: 1));
    expect(NotificationPrefs.intervalFor(20), const Duration(minutes: 15));
    expect(NotificationPrefs.intervalFor(50), const Duration(hours: 1));
    // Whatever a phone from a future version wrote.
    expect(NotificationPrefs.intervalFor(1), const Duration(minutes: 15));
  });
}
