import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:godutch/main.dart';
import 'package:godutch/screens/app_settings_screen.dart';
import 'package:godutch/services/app_settings.dart';
import 'package:godutch/services/settings_service.dart';
import 'package:godutch/widgets/app_switch.dart';

// Notifications settings: off until asked for, then a switch per kind and
// how often the phone checks.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openSettings(WidgetTester tester) async {
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    await tester.pumpWidget(
        GoDutchApp(settings: settings, home: const AppSettingsScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> show(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(find.text(text), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  testWidgets('off until switched on, then a switch per kind and how often',
      (tester) async {
    await openSettings(tester);
    await show(tester, 'Notify me');

    // Off: nothing else to decide.
    expect(find.text('Expenses'), findsNothing);
    expect(find.text('Check every'), findsNothing);

    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();

    expect(await SettingsService().notificationsEnabled(), isTrue);
    for (final label in ['Expenses', 'Comments', 'Payments', 'Members']) {
      await show(tester, label);
      expect(find.text(label), findsOneWidget);
    }
    await show(tester, 'Check every');
    expect(find.text('Every 15 minutes'), findsOneWidget);
    expect(find.text('Send a test notification'), findsOneWidget);
  });

  testWidgets('a kind can be turned off, and stays off', (tester) async {
    SharedPreferences.setMockInitialValues({'notifications_enabled': true});
    await openSettings(tester);
    await show(tester, 'Comments');

    final row =
        find.ancestor(of: find.text('Comments'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: row, matching: find.byType(AppSwitch)));
    await tester.pumpAndSettle();

    expect(await SettingsService().notificationCategoryEnabled('comments'),
        isFalse);
    // The other kinds are untouched.
    expect(
        await SettingsService().notificationCategoryEnabled('expenses'), isTrue);
  });

  testWidgets('how often changes, and is saved', (tester) async {
    SharedPreferences.setMockInitialValues({'notifications_enabled': true});
    await openSettings(tester);
    await show(tester, 'Check every');

    await tester.tap(find.text('Check every'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every 30 minutes'));
    await tester.pumpAndSettle();

    expect(await SettingsService().notificationIntervalMinutes(), 30);
    await show(tester, 'Every 30 minutes');
    expect(find.text('Every 30 minutes'), findsOneWidget);
  });
}
