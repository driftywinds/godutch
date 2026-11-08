import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:godutch/widgets/grouped_section.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/l10n/app_localizations.dart';
import 'package:godutch/models/group.dart';
import 'package:godutch/screens/expense_screen.dart';
import 'package:godutch/sync/outbox.dart';

// Issue #51, item 3: the expense form's category field and picker show
// translated names/headings, search matches translated names, and the
// underlying English model (what the icon lookup keys on) is untouched.
void main() {
  const group = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  // Real seed ids: General 0, Groceries 9, Gas/Fuel 31 -- plus id 999,
  // a category this app has no translation for (a later server addition,
  // or a self-hosted instance's own).
  const categoriesBody = '[{"result":{"data":{"json":{"categories":'
      '[{"id":0,"name":"General","grouping":"Uncategorized"},'
      '{"id":9,"name":"Groceries","grouping":"Food and Drink"},'
      '{"id":31,"name":"Gas/Fuel","grouping":"Transportation"},'
      '{"id":999,"name":"Mystery","grouping":"Other"}]}}}}]';

  Future<void> pumpForm(WidgetTester tester, Locale locale) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response(categoriesBody, 200)),
    );
    final outbox = Outbox(db, client, groupId: 'g1');
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester, String currentLabel) async {
    await tester.ensureVisible(find.widgetWithText(GroupedRow, currentLabel));
    await tester.tap(find.widgetWithText(GroupedRow, currentLabel));
    await tester.pumpAndSettle();
  }

  // The expense form behind the bottom sheet has TextFields of its own;
  // the picker's search field is the one inside the sheet.
  Finder searchField() => find.descendant(
      of: find.byType(BottomSheet), matching: find.byType(TextField));

  testWidgets('French: field, headings and names are translated', (tester) async {
    await pumpForm(tester, const Locale('fr'));
    // The selected category (id 0) shows as the translated General.
    expect(find.widgetWithText(GroupedRow, 'Général'), findsOneWidget);
    expect(find.widgetWithText(GroupedRow, 'General'), findsNothing);

    await openPicker(tester, 'Général');
    // The Cloud catalogue is long: search to bring the row into view.
    await tester.enterText(searchField(), 'épic');
    await tester.pumpAndSettle();
    expect(find.text('Non classé'), findsNothing);
    expect(find.text('Nourriture et boissons'), findsOneWidget);
    expect(find.text('Épicerie'), findsOneWidget);
    expect(find.text('Groceries'), findsNothing);
    expect(find.text('Food and Drink'), findsNothing);

    await tester.enterText(searchField(), 'ess');
    await tester.pumpAndSettle();
    expect(find.text('Transport'), findsOneWidget);
    expect(find.text('Essence/Carburant'), findsOneWidget);
  });

  testWidgets('French: searching by the translated name finds it, headings follow',
      (tester) async {
    await pumpForm(tester, const Locale('fr'));
    await openPicker(tester, 'Général');

    await tester.enterText(searchField(), 'épic');
    await tester.pumpAndSettle();
    expect(find.text('Épicerie'), findsOneWidget);
    expect(find.text('Nourriture et boissons'), findsOneWidget);
    // Non-matching rows and their now-empty sections are gone.
    expect(find.text('Essence/Carburant'), findsNothing);
    expect(find.text('Transport'), findsNothing);

    await tester.tap(find.text('Épicerie'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(GroupedRow, 'Épicerie'), findsOneWidget);
  });

  testWidgets('French: the English name still matches', (tester) async {
    await pumpForm(tester, const Locale('fr'));
    await openPicker(tester, 'Général');

    await tester.enterText(searchField(), 'grocer');
    await tester.pumpAndSettle();
    expect(find.text('Épicerie'), findsOneWidget);
  });

  testWidgets('French: no match shows the translated empty state', (tester) async {
    await pumpForm(tester, const Locale('fr'));
    await openPicker(tester, 'Général');

    await tester.enterText(searchField(), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('Aucune catégorie correspondante'), findsOneWidget);
  });

  testWidgets('Simplified Chinese: names, headings and search', (tester) async {
    await pumpForm(tester, const Locale('zh'));
    expect(find.widgetWithText(GroupedRow, '通用'), findsOneWidget);

    await openPicker(tester, '通用');
    await tester.enterText(searchField(), '杂货');
    await tester.pumpAndSettle();
    expect(find.text('饮食'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '杂货'), findsOneWidget);

    await tester.enterText(searchField(), '交通');
    await tester.pumpAndSettle();
    expect(find.text('交通'), findsWidgets);
    expect(find.text('饮食'), findsNothing);
  });

  testWidgets('translating labels does not break the icon lookup', (tester) async {
    // category_icon.dart keys on the English '<grouping>/<name>' -- if the
    // model fields had been translated in place, Groceries would fall back
    // to the banknote glyph here.
    await pumpForm(tester, const Locale('fr'));
    await openPicker(tester, 'Général');
    await tester.enterText(searchField(), 'épic');
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.shoppingCart), findsOneWidget);
    await tester.enterText(searchField(), 'ess');
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.fuel), findsOneWidget);
  });
}
