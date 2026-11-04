import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/main.dart' show goDutchAppBuilder;
import 'package:godutch/theme.dart';
import 'package:godutch/widgets/scrolling_title.dart';

// A group's name in the title bar: smaller, and scrolling on a loop rather
// than cut off, when it doesn't fit.
void main() {
  const long = 'Banff Trip with the whole extended family';

  Future<void> pumpTitle(
    WidgetTester tester,
    String text, {
    double width = 220,
    TextScaler scaler = TextScaler.noScaling,
    bool reduceMotion = false,
    TextDirection direction = TextDirection.ltr,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: goDutchLightTheme,
      builder: goDutchAppBuilder,
      home: Directionality(
        textDirection: direction,
        child: MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(textScaler: scaler, disableAnimations: reduceMotion),
          child: Scaffold(
            body: Center(child: SizedBox(width: width, child: ScrollingTitle(text))),
          ),
        ),
      ),
    ));
  }

  Transform looped(WidgetTester tester) => tester.widget<Transform>(
      find.descendant(of: find.byType(ScrollingTitle), matching: find.byType(Transform)).first);

  // A loop runs for as long as it's on screen: take it down rather than leave
  // it ticking into the teardown.
  Future<void> disposeTree(WidgetTester tester) => tester.pumpWidget(const SizedBox.shrink());

  testWidgets('a name that fits is an ordinary line, still', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: goDutchLightTheme,
      builder: goDutchAppBuilder,
      home: const Scaffold(body: Center(child: ScrollingTitle('Banff Trip'))),
    ));
    expect(find.text('Banff Trip'), findsOneWidget);
    expect(find.descendant(of: find.byType(ScrollingTitle), matching: find.byType(Transform)),
        findsNothing);
  });

  testWidgets('a name too long for the room is drawn twice and travels', (tester) async {
    await pumpTitle(tester, long);
    // Twice over, with a gap between, so the wrap has no jump in it.
    expect(find.text(long), findsNWidgets(2));

    final start = looped(tester).transform.storage[12];
    await tester.pump(const Duration(seconds: 3));
    final later = looped(tester).transform.storage[12];
    expect(start, 0);
    expect(later, lessThan(start), reason: 'the line moves left, showing later words');
    await disposeTree(tester);
  });

  testWidgets('the loop comes round again', (tester) async {
    await pumpTitle(tester, long);
    // However long one pass takes, it is under a minute; the offset must
    // have come back to the start by then rather than run on forever.
    await tester.pump(const Duration(seconds: 30));
    final x = looped(tester).transform.storage[12];
    expect(x, lessThanOrEqualTo(0));
    expect(x, greaterThan(-2000));
    await disposeTree(tester);
  });

  testWidgets('right-to-left, the line travels the other way', (tester) async {
    await pumpTitle(tester, long, direction: TextDirection.rtl);
    final start = looped(tester).transform.storage[12];
    await tester.pump(const Duration(seconds: 3));
    expect(looped(tester).transform.storage[12], greaterThan(start));
    await disposeTree(tester);
  });

  testWidgets('a larger text size pushes a fitting name into scrolling', (tester) async {
    await pumpTitle(tester, 'Banff Trip', width: 120);
    expect(find.text('Banff Trip'), findsOneWidget);

    // Twice the size, so the same name no longer fits: it scrolls instead.
    await pumpTitle(tester, 'Banff Trip', width: 120, scaler: const TextScaler.linear(2));
    expect(find.text('Banff Trip'), findsNWidgets(2));
    await disposeTree(tester);
  });

  testWidgets('with Reduce motion, the ellipsis is kept and nothing moves', (tester) async {
    await pumpTitle(tester, long, reduceMotion: true);
    expect(find.text(long), findsOneWidget);
    expect(find.descendant(of: find.byType(ScrollingTitle), matching: find.byType(Transform)),
        findsNothing);
    expect(tester.widget<Text>(find.text(long)).overflow, TextOverflow.ellipsis);
  });

  testWidgets('the caller\'s style is applied, keeping the bar\'s colour', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: goDutchLightTheme,
      builder: goDutchAppBuilder,
      home: Scaffold(
        appBar: AppBar(
          title: const ScrollingTitle('Banff Trip', style: TextStyle(fontSize: 20)),
        ),
      ),
    ));
    final text = tester.widget<Text>(find.text('Banff Trip'));
    expect(text.style!.fontSize, 20);
    expect(text.style!.color, isNotNull, reason: 'the title bar\'s own colour, not black');
  });
}
