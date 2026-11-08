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
import 'package:godutch/screens/group_settings_screen.dart';

/// A client for tests about local data only: the settings screen asks the
/// server for pending invitations, which are none here.
http.Client localClient() => MockClient((req) async => http.Response(
    '[{"result":{"data":{"json":{"invitations":[]}}}}]', 200));

void main() {
  const group = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    role: 'ADMIN',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  String freshGroupResponse(Map<String, dynamic> g) => jsonEncode([
        {
          'result': {
            'data': {
              'json': {'group': g},
            },
          },
        },
      ]);

  testWidgets('saving a rename posts groups.update and pops the fresh group', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    http.Request? updateRequest;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) {
          updateRequest = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }
        // groups.get: return the renamed group as the server's truth.
        return http.Response(
          freshGroupResponse({
            'id': 'g1',
            'name': 'Renamed Trip',
            'currency': '\$',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
              {'id': 'bea', 'name': 'Bea'},
            ],
          }),
          200,
        );
      }),
    );

    Group? popped;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<Group>(
              MaterialPageRoute(
                builder: (_) => GroupSettingsScreen(client: client, db: db, group: group),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Banff Trip'), 'Renamed Trip');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['name'], 'Renamed Trip');

    expect(popped, isNotNull);
    expect(popped!.name, 'Renamed Trip');
    // The fresh group should also have landed in the local cache.
    expect((await db.cachedGroup('g1'))?.name, 'Renamed Trip');
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });


  testWidgets('blank group name blocks save with an inline error', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var updateCalled = false;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) updateCalled = true;
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Banff Trip'), '');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateCalled, isFalse);
    expect(find.text('Group name is required.'), findsOneWidget);
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a group with no currencyCode shows Custom, prefilled with its symbol (issue #23)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200)),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Custom'), findsOneWidget);
    expect(find.widgetWithText(TextField, '\$'), findsOneWidget);
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('clearing the custom currency symbol blocks save with an inline error',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var updateCalled = false;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) updateCalled = true;
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '\$'), '');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateCalled, isFalse);
    expect(find.text('Enter at least one character.'), findsOneWidget);
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('picking a real currency from the picker fills the symbol and sends its code',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    http.Request? updateRequest;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) {
          updateRequest = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }
        // Encoded as UTF-8: http.Response(String) is Latin-1 only, and '€'
        // isn't in it.
        return http.Response.bytes(
          utf8.encode(freshGroupResponse({
            'id': 'g1',
            'name': 'Banff Trip',
            'currency': '€',
            'currencyCode': 'EUR',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
              {'id': 'bea', 'name': 'Bea'},
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(InputDecorator, 'Custom'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Search currency...'), 'Euro');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Euro (EUR)'));
    await tester.pumpAndSettle();

    // Custom's symbol field should be gone now that a real currency is
    // selected -- nothing left to validate as "at least one character".
    expect(find.text('Currency symbol'), findsNothing);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['currency'], '€');
    expect(formValues['currencyCode'], 'EUR');
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('editing group information sends it in the update request', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    http.Request? updateRequest;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) {
          updateRequest = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }
        return http.Response(
          freshGroupResponse({
            'id': 'g1',
            'name': 'Banff Trip',
            'currency': '\$',
            'information': 'Split hotel evenly.',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
              {'id': 'bea', 'name': 'Bea'},
            ],
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Group information'),
      'Split hotel evenly.',
    );
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['information'], 'Split hotel evenly.');
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // Issue #55: date span shown on this screen, computed from the
  // group's cached expenses -- first expense date to last.
  // Local, date-only DateTimes -- see the comment on date_span_calculator_test.dart's
  // expense() helper: AppDatabase's drift round-trip only preserves a
  // DateTime.utc(...) fixture's calendar date on a machine at UTC+0, and
  // shifts it a day west of UTC otherwise.
  testWidgets('shows the date span computed from the earliest and latest cached expense dates',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 1000,
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
        date: DateTime(2026, 1, 2),
      ),
      Expense(
        id: 'e2',
        groupId: 'g1',
        title: 'Hotel',
        amountCents: 5000,
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
        date: DateTime(2026, 6, 15),
      ),
    ]);

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: localClient(),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Jan 2, 2026 – Jun 15, 2026'), findsOneWidget);
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('shows the em-dash placeholder when the group has no cached expenses',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: localClient(),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('—'), findsOneWidget);
    // Same drift-stream-cancel/pending-Timer workaround
    // group_screen_test.dart already uses throughout (issue #57):
    // cancelling GroupSettingsScreen's watchExpensesForGroup
    // subscription in dispose() schedules a zero-duration Timer
    // (drift's StreamQueryStore.markAsClosed) that needs one more
    // pump to fire, or flutter_test's automatic end-of-test teardown
    // trips "A Timer is still pending even after the widget tree was
    // disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

