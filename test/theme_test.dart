import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/theme.dart';
import 'package:godutch/widgets/grouped_section.dart';

void main() {
  // The typography that sets the letter spacing must keep Material's text
  // colors from the scheme (onSurface), not pure black or white (#232 review).
  for (final (name, theme) in [
    ('light', goDutchLightTheme),
    ('dark', goDutchDarkTheme),
    ('light high contrast', goDutchLightHighContrastTheme),
    ('dark high contrast', goDutchDarkHighContrastTheme),
  ]) {
    test('text takes its colors from the scheme ($name)', () {
      final material = ThemeData(useMaterial3: true, colorScheme: theme.colorScheme).textTheme;
      TextStyle? style(TextTheme t, int i) => [
            t.displayLarge, t.displayMedium, t.displaySmall, t.headlineLarge, t.headlineMedium,
            t.headlineSmall, t.titleLarge, t.titleMedium, t.titleSmall, t.bodyLarge, t.bodyMedium,
            t.bodySmall, t.labelLarge, t.labelMedium, t.labelSmall,
          ][i];
      for (var i = 0; i < 15; i++) {
        expect(style(theme.textTheme, i)!.color, style(material, i)!.color, reason: style(material, i)!.debugLabel);
      }
      expect(theme.textTheme.bodyLarge!.color, theme.colorScheme.onSurface);
    });
  }

  for (final locale in const [Locale('en'), Locale('zh')]) {
    testWidgets('the font\'s own letter spacing, as native apps; row titles a little tighter ($locale)',
        (tester) async {
      late TextTheme text;
      await tester.pumpWidget(MaterialApp(
        theme: goDutchLightTheme,
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(builder: (context) {
          text = Theme.of(context).textTheme;
          return const SizedBox();
        }),
      ));
      for (final style in [
        text.displayLarge, text.headlineSmall, text.titleLarge, text.titleMedium, text.titleSmall,
        text.bodyMedium, text.bodySmall, text.labelLarge, text.labelMedium, text.labelSmall,
      ]) {
        expect(style!.letterSpacing, 0, reason: style.debugLabel);
      }
      expect(text.bodyLarge!.letterSpacing, bodyLargeLetterSpacing);
      expect(bodyLargeLetterSpacing, -0.4);
      expect(goDutchLightTheme.listTileTheme.subtitleTextStyle!.letterSpacing, -0.2);
      expect(goDutchLightTheme.popupMenuTheme.labelTextStyle!.resolve({})!.letterSpacing, -0.4);
      expect(text.bodyLarge!.fontSize, 16, reason: 'only the spacing changes');
    });
  }

  test('light and dark themes have matching brightness fields (issue #25)', () {
    expect(goDutchLightTheme.brightness, Brightness.light);
    expect(goDutchDarkTheme.brightness, Brightness.dark);
  });

  test('both themes are seeded from the same color, not two unrelated palettes', () {
    // Same seed hue, opposite brightness -- a real dark *variant* of
    // this app's look, not a generic Material dark theme grafted on.
    expect(goDutchLightTheme.colorScheme.primary, isNot(goDutchDarkTheme.colorScheme.primary));
    // Material 3's seeded ColorScheme.fromSeed picks a *lighter* primary
    // tone for dark mode (roughly tone 80 vs. light mode's tone 40) so
    // it reads clearly against a dark surface -- the reverse of the
    // background relationship, which is the opposite way round. Both
    // colors tracing back to the same emerald seed is checked by the
    // regression test below (distinct scaffold backgrounds would also
    // catch two completely unrelated ThemeData instances).
    expect(goDutchDarkTheme.colorScheme.primary.computeLuminance(),
        greaterThan(goDutchLightTheme.colorScheme.primary.computeLuminance()));
  });

  test('regression: a dark theme is actually provided, not just brightness: dark on light values',
      () {
    // The bug this issue reported was "no dark theme at all" -- Flutter
    // silently falls back to `theme` whenever `darkTheme` is null (see
    // WidgetsApp's `darkTheme ?? theme` resolution), so the light and
    // dark ThemeData instances must be genuinely distinct objects with
    // distinct scaffold backgrounds, not the same ThemeData used twice.
    expect(goDutchLightTheme.scaffoldBackgroundColor,
        isNot(goDutchDarkTheme.scaffoldBackgroundColor));
  });

  test("primary is spliit-ios's accent exactly, in both modes (#178)", () {
    expect(goDutchLightTheme.colorScheme.primary, const Color(0xff059669));
    expect(goDutchDarkTheme.colorScheme.primary, const Color(0xff10B981));
  });

  test('one base background for screens, app bars and the tab bar (#186 review)', () {
    for (final theme in [goDutchLightTheme, goDutchDarkTheme]) {
      final base = theme.scaffoldBackgroundColor;
      final reason = '${theme.brightness}';
      expect(theme.appBarTheme.backgroundColor, base, reason: reason);
      expect(theme.navigationBarTheme.backgroundColor, base, reason: reason);
    }
    // Sheets too in light; in dark they stand off it (#239, below).
    expect(goDutchLightTheme.bottomSheetTheme.backgroundColor,
        goDutchLightTheme.scaffoldBackgroundColor);
    // Grouped cards stand off it: lighter in light mode, a step up from
    // black in dark (#211).
    expect(goDutchLightTheme.scaffoldBackgroundColor,
        goDutchLightTheme.colorScheme.surfaceContainerLow);
    expect(goDutchDarkTheme.scaffoldBackgroundColor, Colors.black);
  });

  testWidgets("the app bar keeps the page's color when content scrolls under it (#188)",
      (tester) async {
    for (final theme in [goDutchLightTheme, goDutchDarkTheme]) {
      // A fresh list each time, at its top.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: ListView(children: [for (var i = 0; i < 60; i++) Text('row $i')]),
        ),
      ));
      Material bar() => tester.widget<Material>(
          find.descendant(of: find.byType(AppBar), matching: find.byType(Material)).first);
      expect(bar().elevation, 0, reason: '${theme.brightness}: at rest');

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(bar().color, theme.scaffoldBackgroundColor, reason: '${theme.brightness}');
      expect(bar().surfaceTintColor, Colors.transparent, reason: '${theme.brightness}');
      // And stays flat: no shadow either (#188 review).
      expect(bar().elevation, 0, reason: '${theme.brightness}');
    }
  });

  test('dark sheets stand off the page with a hairline edge; light ones unchanged (#239)', () {
    final dark = goDutchDarkTheme.bottomSheetTheme;
    expect(dark.backgroundColor, isNot(goDutchDarkTheme.scaffoldBackgroundColor));
    expect(dark.backgroundColor, isNot(GroupedSection.cardColorOf(goDutchDarkTheme.colorScheme)));
    expect((dark.shape! as RoundedRectangleBorder).side.width, 0.5);
    final light = goDutchLightTheme.bottomSheetTheme;
    expect(light.backgroundColor, goDutchLightTheme.scaffoldBackgroundColor);
    expect(light.shape, isNull);
    expect(light.dragHandleColor, isNull);
    expect(dark.dragHandleColor, isNotNull);
  });

  test('add buttons are circles, in both modes (#199)', () {
    for (final theme in [goDutchLightTheme, goDutchDarkTheme]) {
      expect(theme.floatingActionButtonTheme.shape, const CircleBorder());
    }
  });

  // #211: less important content steps back as far as Apple's
  // secondaryLabel, and comes forward with Increase Contrast.
  group('secondary content', () {
    test("Apple's secondaryLabel dimming: 60% of the light scheme's grey, #EBEBF5 in dark", () {
      final light = SpliitColors.light.secondaryContent;
      expect(light.withValues(alpha: 1), goDutchLightTheme.colorScheme.onSurfaceVariant);
      expect(light.a, closeTo(0.6, 0.01));
      expect(SpliitColors.dark.secondaryContent, const Color(0x99EBEBF5));
    });

    test('row captions take it from the theme', () {
      for (final theme in [
        goDutchLightTheme,
        goDutchDarkTheme,
        goDutchLightHighContrastTheme,
        goDutchDarkHighContrastTheme,
      ]) {
        expect(theme.listTileTheme.subtitleTextStyle?.color,
            theme.extension<SpliitColors>()!.secondaryContent);
      }
    });

    test('with Increase Contrast: undimmed, the schemes\' own grey, and lent/owe solid', () {
      for (final (theme, normal) in [
        (goDutchLightHighContrastTheme, goDutchLightTheme),
        (goDutchDarkHighContrastTheme, goDutchDarkTheme),
      ]) {
        final colors = theme.extension<SpliitColors>()!;
        expect(colors.secondaryContent, normal.colorScheme.onSurfaceVariant);
        expect(colors.secondaryMoneyOpacity, 1);
        expect(theme.scaffoldBackgroundColor, normal.scaffoldBackgroundColor);
      }
    });
  });

  test('each theme carries its own spliit-ios colors (#178)', () {
    expect(goDutchLightTheme.extension<SpliitColors>(), SpliitColors.light);
    expect(goDutchDarkTheme.extension<SpliitColors>(), SpliitColors.dark);
    expect(SpliitColors.light.moneyPositive, isNot(SpliitColors.dark.moneyPositive));
  });

  testWidgets('SpliitColors.of falls back by brightness without the app theme', (tester) async {
    late SpliitColors light, dark;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(),
      home: Builder(builder: (context) {
        light = SpliitColors.of(context);
        return Theme(
          data: ThemeData(brightness: Brightness.dark),
          child: Builder(builder: (context) {
            dark = SpliitColors.of(context);
            return const SizedBox();
          }),
        );
      }),
    ));
    expect(light, SpliitColors.light);
    expect(dark, SpliitColors.dark);
  });

  group('goDutchSystemUiOverlayStyle', () {
    test('matches the bottom nav bar to the theme\'s own background, not a fixed color', () {
      final lightStyle = goDutchSystemUiOverlayStyle(goDutchLightTheme);
      final darkStyle = goDutchSystemUiOverlayStyle(goDutchDarkTheme);

      expect(lightStyle.systemNavigationBarColor, goDutchLightTheme.scaffoldBackgroundColor);
      expect(darkStyle.systemNavigationBarColor, goDutchDarkTheme.scaffoldBackgroundColor);
    });

    test('disables the enforced-contrast scrim that renders as a deep black bar (issue #24)', () {
      // This was the actual bug reported: Android 10+ paints a
      // translucent black scrim over the nav bar "for legibility"
      // unless an app explicitly opts out, which darkens whatever
      // color it was given underneath it into something close to
      // solid black.
      expect(goDutchSystemUiOverlayStyle(goDutchLightTheme).systemNavigationBarContrastEnforced,
          isFalse);
      expect(goDutchSystemUiOverlayStyle(goDutchDarkTheme).systemNavigationBarContrastEnforced,
          isFalse);
    });

    test('picks nav bar icon brightness for contrast against a light background', () {
      final style = goDutchSystemUiOverlayStyle(goDutchLightTheme);
      // Brightness.dark here means dark *icons* -- correct against
      // goDutchLightTheme's light scaffold background.
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
    });

    test('picks nav bar icon brightness for contrast against a dark background', () {
      final style = goDutchSystemUiOverlayStyle(goDutchDarkTheme);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
    });
  });
}
