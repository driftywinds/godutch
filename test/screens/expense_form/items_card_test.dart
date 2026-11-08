import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/l10n/app_localizations.dart';
import 'package:godutch/models/expense.dart';
import 'package:godutch/models/group.dart';
import 'package:godutch/screens/expense_form/currency_card.dart';
import 'package:godutch/screens/expense_form/items_card.dart';
import 'package:godutch/screens/expense_screen.dart';
import 'package:godutch/sync/outbox.dart';

// An expense broken into lines: each line's own split, and what they leave.
void main() {
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  /// Dinner, $30: pizza $10 that Alex and Bea shared, steak $20 for Alex.
  /// The split is what those lines come to: $25 for Alex, $5 for Bea.
  final itemized = Expense(
    id: 'e1',
    groupId: 'g1',
    title: 'Dinner',
    amountCents: 3000,
    paidBy: 'alex',
    paidFor: const [
      ExpenseShare(participantId: 'alex', shares: 2500),
      ExpenseShare(participantId: 'bea', shares: 500),
    ],
    splitMode: SplitMode.byAmount,
    items: const [
      ExpenseItem(
        id: 'i1',
        title: 'Pizza',
        amountCents: 1000,
        unitPriceCents: 1000,
        paidFor: [
          ExpenseShare(participantId: 'alex', shares: 1),
          ExpenseShare(participantId: 'bea', shares: 1),
        ],
      ),
      ExpenseItem(
        id: 'i2',
        title: 'Steak',
        amountCents: 2000,
        unitPriceCents: 2000,
        paidFor: [ExpenseShare(participantId: 'alex', shares: 1)],
      ),
    ],
    date: DateTime.utc(2026, 10, 1),
  );

  Future<(AppDatabase, List<http.Request>)> open(WidgetTester tester, {Expense? editing}) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(banff);
    final requests = <http.Request>[];
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        requests.add(req);
        if (!req.url.path.endsWith('groups.expenses.update')) throw http.ClientException('offline');
        return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
      }),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseScreen(
        client: client,
        db: db,
        outbox: Outbox(db, client, groupId: 'g1'),
        group: banff,
        activeUserId: 'alex',
        existingExpense: editing,
      ),
    ));
    await tester.pumpAndSettle();
    return (db, requests);
  }

  Map<String, dynamic> sentExpense(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final input = (body['0'] as Map)['json'] as Map<String, dynamic>;
    return input['expense'] as Map<String, dynamic>;
  }

  Future<void> tapItemize(WidgetTester tester) async {
    final row = find.text('Itemise this expense');
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Fills the open item sheet in and closes it.
  Future<void> fillItem(WidgetTester tester, String title, String price,
      {String? quantity, List<String>? sharedBy}) async {
    await tester.enterText(find.byKey(const ValueKey('itemSheet.title')), title);
    await tester.enterText(find.byKey(const ValueKey('itemSheet.unitPrice')), price);
    if (quantity != null) {
      await tester.enterText(find.byKey(const ValueKey('itemSheet.quantity')), quantity);
    }
    if (sharedBy != null) {
      // Evenly: everyone starts in, so take out whoever doesn't share it.
      for (final name in ['Alex', 'Bea']) {
        if (!sharedBy.contains(name)) {
          final row = find.descendant(of: find.byType(BottomSheet), matching: find.text(name));
          await tester.ensureVisible(row);
          await tester.tap(row);
          await tester.pumpAndSettle();
        }
      }
    }
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('an edited itemized expense lists its lines and sends them back', (tester) async {
    final (_, requests) = await open(tester, editing: itemized);
    expect(find.text('Pizza'), findsOneWidget);
    expect(find.text('Steak'), findsOneWidget);
    // The split is what the lines work out to, and there's nothing over.
    expect(find.text('The items add up to the whole amount.'), findsOneWidget);

    await save(tester);
    final sent = sentExpense(requests.single);
    expect(sent['splitMode'], 'ITEMIZED');
    expect(sent['paidFor'], [
      {'participant': 'alex', 'shares': 2500},
      {'participant': 'bea', 'shares': 500},
    ]);
    final items = sent['items'] as List;
    expect(items.map((i) => (i as Map)['title']), ['Pizza', 'Steak']);
    expect((items.first as Map)['id'], 'i1');
    expect((items.first as Map)['paidFor'], [
      {'participant': 'alex', 'shares': 1},
      {'participant': 'bea', 'shares': 1},
    ]);
    // No leftover, so nothing is said about one.
    expect(sent.containsKey('itemizedRemainder'), isFalse);
  });

  testWidgets('turning itemizing on adds a line; what it costs splits the expense', (tester) async {
    final (db, _) = await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Dinner');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '30');
    await tapItemize(tester);

    // The one empty line is opened and filled in: $30 of pizza for Alex only.
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await fillItem(tester, 'Pizza', '30', sharedBy: ['Alex']);

    expect(find.text('Pizza'), findsOneWidget);
    expect(find.text('The items add up to the whole amount.'), findsOneWidget);

    await save(tester);
    final saved = db.rowToExpense((await db.pendingExpenses()).single);
    expect(saved.items.single.title, 'Pizza');
    expect(saved.items.single.amountCents, 3000);
    // Alex ate it, so Alex owes all of it.
    expect({for (final s in saved.paidFor) s.participantId: s.shares}, {'alex': 3000});
    expect(saved.splitMode, SplitMode.byAmount);
  });

  testWidgets('lines that leave something share the leftover with everyone', (tester) async {
    final (db, _) = await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Dinner');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '30');
    await tapItemize(tester);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await fillItem(tester, 'Pizza', '10');

    // $20 of the $30 is left over, and the card says so.
    expect(find.textContaining('left over'), findsWidgets);
    expect(find.byKey(ItemsCard.leftoverKey), findsOneWidget);

    await save(tester);
    final saved = db.rowToExpense((await db.pendingExpenses()).single);
    // $5 each of the pizza, plus $10 each of the leftover.
    expect({for (final s in saved.paidFor) s.participantId: s.shares}, {'alex': 1500, 'bea': 1500});
    expect(saved.itemizedRemainder, isNotNull);
    expect(saved.itemizedRemainder!.paidFor.map((s) => s.participantId), ['alex', 'bea']);
  });

  testWidgets('lines that come to more than the expense can\'t be saved', (tester) async {
    final (_, requests) = await open(tester, editing: itemized);
    // Take the total down under the lines' $30.
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '20');
    await tester.pumpAndSettle();
    expect(find.text('The items come to \$10.00 more than the expense'), findsOneWidget);

    await save(tester);
    expect(requests, isEmpty);
    expect(find.byType(ExpenseScreen), findsOneWidget);
  });

  testWidgets('a line of two at \$5.00 is worked out, and its own shares are sent', (tester) async {
    final (db, _) = await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Drinks');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '10');
    await tapItemize(tester);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await fillItem(tester, 'Beers', '5', quantity: '2');

    // 2 × $5.00 shows under the name, and comes to $10.
    expect(find.text('2 × \$5.00'), findsOneWidget);
    expect(find.text('The items add up to the whole amount.'), findsOneWidget);

    await save(tester);
    final saved = db.rowToExpense((await db.pendingExpenses()).single);
    expect((saved.items.single.unitPriceCents, saved.items.single.quantityMilli), (500, 2000));
    expect(saved.items.single.amountCents, 1000);
  });

  testWidgets('a line can be shared by shares instead', (tester) async {
    final (db, _) = await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Dinner');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '30');
    await tapItemize(tester);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('itemSheet.title')), 'Steak');
    await tester.enterText(find.byKey(const ValueKey('itemSheet.unitPrice')), '30');

    // Shares: Alex 2, Bea 1.
    await tester.tap(find.descendant(
        of: find.byType(BottomSheet), matching: find.text('Shares')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('itemSheet.value.alex')), '2');
    await tester.enterText(find.byKey(const ValueKey('itemSheet.value.bea')), '1');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    await save(tester);
    final saved = db.rowToExpense((await db.pendingExpenses()).single);
    expect(saved.items.single.splitMode, SplitMode.byShares);
    expect({for (final s in saved.items.single.paidFor) s.participantId: s.shares}, {'alex': 200, 'bea': 100});
    expect({for (final s in saved.paidFor) s.participantId: s.shares}, {'alex': 2000, 'bea': 1000});
  });

  testWidgets('Remove item takes a line away; taking the last leaves it flat', (tester) async {
    await open(tester, editing: itemized);
    await tester.tap(find.text('Steak'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove item'));
    await tester.pumpAndSettle();
    expect(find.text('Steak'), findsNothing);
    expect(find.text('Pizza'), findsOneWidget);

    await tester.tap(find.text('Pizza'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove item'));
    await tester.pumpAndSettle();
    // Flat again: the switch is off and the split is back to what you type.
    expect(find.text('Itemise this expense'), findsOneWidget);
    expect(find.byKey(ItemsCard.addKey), findsNothing);
    expect(find.text('Paid for'), findsOneWidget);
  });
}

