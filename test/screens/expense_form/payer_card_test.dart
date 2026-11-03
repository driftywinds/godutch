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
import 'package:godutch/screens/expense_form/payer_card.dart';
import 'package:godutch/screens/expense_screen.dart';
import 'package:godutch/sync/outbox.dart';
import 'package:godutch/widgets/grouped_section.dart';

// Who paid: one person for the whole amount, or several each for a part, as
// Spliit Cloud records them.
void main() {
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
      Participant(id: 'cid', name: 'Cid'),
    ],
  );

  /// Alex paid $12 of it and Bea $18, for everyone.
  final dinner = Expense(
    id: 'e1',
    groupId: 'g1',
    title: 'Dinner',
    amountCents: 3000,
    paidBy: 'alex',
    paidByList: const [
      ExpenseShare(participantId: 'alex', shares: 1200),
      ExpenseShare(participantId: 'bea', shares: 1800),
    ],
    isMultiPayer: true,
    paidFor: const [
      ExpenseShare(participantId: 'alex', shares: 1),
      ExpenseShare(participantId: 'bea', shares: 1),
      ExpenseShare(participantId: 'cid', shares: 1),
    ],
    date: DateTime.utc(2026, 9, 10),
  );

  /// The form, over a client that answers only the update; [requests] holds
  /// what it was sent.
  Future<(AppDatabase, List<http.Request>)> open(WidgetTester tester,
      {Expense? editing}) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(banff);
    final requests = <http.Request>[];
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        requests.add(req);
        // Editing's save; anything else (categories) is offline (#132).
        if (!req.url.path.endsWith('groups.expenses.update')) {
          throw http.ClientException('offline');
        }
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
        activeUserId: 'bea',
        existingExpense: editing,
      ),
    ));
    await tester.pumpAndSettle();
    return (db, requests);
  }

  /// The expense an update sent.
  Map<String, dynamic> sentExpense(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final input = (body['0'] as Map)['json'] as Map<String, dynamic>;
    return input['expense'] as Map<String, dynamic>;
  }

  String fieldText(WidgetTester tester, String participantId) =>
      tester.widget<TextFormField>(find.byKey(PayerCard.amountKey(participantId))).controller!.text;

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('an edited multi-payer expense lists each payer and what they paid', (tester) async {
    final (_, requests) = await open(tester, editing: dinner);
    // Several payers: the label above them, as "Paid for"'s.
    expect(find.text('Paid by'), findsOneWidget);
    expect(fieldText(tester, 'alex'), '12.00');
    expect(fieldText(tester, 'bea'), '18.00');
    // Cid didn't pay: no row, but one could be added.
    expect(find.byKey(PayerCard.amountKey('cid')), findsNothing);
    expect(find.byKey(PayerCard.addKey), findsOneWidget);

    await save(tester);
    final sent = sentExpense(requests.single);
    expect(sent['isMultiPayer'], isTrue);
    expect(sent['paidByList'], [
      {'participant': 'alex', 'shares': 1200},
      {'participant': 'bea', 'shares': 1800},
    ]);
    expect(sent['amount'], 3000);
  });

  testWidgets('a single payer is one row, and saves as one payer for it all', (tester) async {
    final (_, requests) =
        await open(tester, editing: dinner.copyWith(paidBy: 'bea', paidByList: const [], isMultiPayer: false));
    // Bea, the active user: the whole amount, with no amounts of their own.
    expect(find.descendant(of: find.widgetWithText(GroupedRow, 'Paid by'), matching: find.text('Bea (you)')),
        findsOneWidget);
    expect(find.byKey(PayerCard.amountKey('bea')), findsNothing);

    await save(tester);
    final sent = sentExpense(requests.single);
    expect(sent['isMultiPayer'], isFalse);
    expect(sent['paidByList'], [
      {'participant': 'bea', 'shares': 3000}
    ]);
  });

  testWidgets('"Add payer" shares the amount out evenly, and the new expense keeps both',
      (tester) async {
    final (db, _) = await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Dinner');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '30');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(PayerCard.addKey));
    await tester.tap(find.byKey(PayerCard.addKey));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Cid')));
    await tester.pumpAndSettle();

    // Bea (the active user) pays a new expense, so the $30 is shared.
    expect(fieldText(tester, 'bea'), '15.00');
    expect(fieldText(tester, 'cid'), '15.00');

    await save(tester);
    final saved = db.rowToExpense((await db.pendingExpenses()).single);
    expect(saved.isMultiPayer, isTrue);
    expect({for (final p in saved.paidByList) p.participantId: p.shares}, {'bea': 1500, 'cid': 1500});
  });

  testWidgets('✕ takes a payer out; the last one left is the single payer again', (tester) async {
    final (_, requests) = await open(tester, editing: dinner);
    await tester.tap(find.byKey(PayerCard.removeKey('bea')));
    await tester.pumpAndSettle();

    expect(find.byKey(PayerCard.amountKey('bea')), findsNothing);
    expect(find.byKey(PayerCard.amountKey('alex')), findsNothing);
    expect(find.descendant(of: find.widgetWithText(GroupedRow, 'Paid by'), matching: find.text('Alex')),
        findsOneWidget);

    await save(tester);
    final sent = sentExpense(requests.single);
    expect(sent['isMultiPayer'], isFalse);
    expect(sent['paidByList'], [
      {'participant': 'alex', 'shares': 3000}
    ]);
  });

  testWidgets('payers that don\'t add up say so, and a save is refused', (tester) async {
    final (_, requests) = await open(tester, editing: dinner);
    await tester.enterText(find.byKey(PayerCard.amountKey('bea')), '10');
    await tester.pumpAndSettle();
    // 12 + 10 is $8 short of $30.
    expect(find.text('The amounts paid must add up to the total (\$8.00 short)'), findsOneWidget);

    await save(tester);
    expect(requests, isEmpty);
    // Still on the form, saying why in red.
    expect(find.byType(ExpenseScreen), findsOneWidget);
    final error = tester.widget<Text>(find.text('The amounts paid must add up to the total (\$8.00 short)'));
    expect(error.style?.color, Theme.of(tester.element(find.byType(PayerCard))).colorScheme.error);
  });

  testWidgets('a payer with no amount says which one', (tester) async {
    final (_, _) = await open(tester, editing: dinner);
    await tester.enterText(find.byKey(PayerCard.amountKey('bea')), '');
    await tester.pumpAndSettle();
    expect(find.text('Bea: enter an amount'), findsOneWidget);
  });

  testWidgets('the rows still fit on a narrow phone at the largest text', (tester) async {
    await open(tester, editing: dinner);
    tester.view.physicalSize = const Size(320, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    // Nothing overflowed, and everyone's amount is still there.
    expect(tester.takeException(), isNull);
    expect(find.byKey(PayerCard.amountKey('alex')), findsOneWidget);
    expect(find.byKey(PayerCard.amountKey('bea')), findsOneWidget);
    expect(find.byKey(PayerCard.removeKey('bea')), findsOneWidget);
  });
}
