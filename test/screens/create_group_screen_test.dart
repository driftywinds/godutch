import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/l10n/app_localizations.dart';
import 'package:godutch/models/currency.dart';
import 'package:godutch/screens/group_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/error_log.dart';

String _groupJson({String name = 'Trip'}) => jsonEncode([
      {
        'result': {
          'data': {
            'json': {
              'group': {
                'id': 'g1',
                'name': name,
                'currency': r'$',
                'currencyCode': 'USD',
                'ledgerId': 'ledger-1',
                'groupType': 'GROUP',
                'participants': [
                  {'id': 'p1', 'name': 'Me'},
                ],
                'members': [],
              },
            },
          },
        },
      },
    ]);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppDatabase> openDb() async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  /// A Cloud whose create/read answers are controlled per request.
  ({SpliitClient client, List<http.Request> requests}) server({
    Future<http.Response> Function()? create,
    Future<http.Response> Function()? get,
  }) {
    final requests = <http.Request>[];
    final client = SpliitClient(
      baseUrl: 'https://api.spliit.test',
      httpClient: MockClient((req) async {
        requests.add(req);
        if (req.url.path.endsWith('groups.create')) {
          if (create != null) return create();
          return http.Response(
              '[{"result":{"data":{"json":{"groupId":"g1"}}}}]', 200);
        }
        if (req.url.path.endsWith('groups.get')) {
          if (get != null) return get();
          return http.Response(_groupJson(), 200);
        }
        return http.Response('unexpected', 500);
      }),
    );
    return (client: client, requests: requests);
  }

  Future<String?> openAndCreate(
    WidgetTester tester,
    AppDatabase db,
    SpliitClient client, {
    String name = 'Trip',
  }) async {
    String? popped;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<String>(MaterialPageRoute(
              builder: (_) => GroupSettingsScreen.create(db: db, client: client),
            ));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (name.isNotEmpty) {
      await tester.enterText(find.widgetWithText(TextField, 'Group name'), name);
    }
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();
    return popped;
  }

  testWidgets('opens as Create group, in the region\'s currency', (tester) async {
    final db = await openDb();
    final s = server();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en', 'US'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen.create(db: db, client: s.client),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Create group'), findsOneWidget);
    expect(find.byTooltip('Create'), findsOneWidget);
    final usd = defaultCurrencyFor(const Locale('en', 'US'));
    expect(find.textContaining(usd.code), findsWidgets);
    expect(s.requests, isEmpty);
  });

  testWidgets('a blank name is refused before any request', (tester) async {
    final db = await openDb();
    final s = server();
    await openAndCreate(tester, db, s.client, name: '');
    expect(find.text('Group name is required.'), findsOneWidget);
    expect(s.requests.where((r) => r.url.path.endsWith('groups.create')), isEmpty);
  });

  testWidgets('creates the group, caches it, and pops its id', (tester) async {
    final db = await openDb();
    final s = server();
    final popped = await openAndCreate(tester, db, s.client);

    expect(popped, 'g1');
    final create = s.requests.firstWhere((r) => r.url.path.endsWith('groups.create'));
    final sent = (jsonDecode(create.body)['0']['json']) as Map<String, dynamic>;
    final values = sent['groupFormValues'] as Map<String, dynamic>;
    expect(values['name'], 'Trip');
    expect(values['currencyCode'], 'USD');
    expect((values['participants'] as List).single, {'name': 'Me'});

    final cached = await db.cachedGroup('g1');
    expect(cached?.name, 'Trip');
    expect((await db.groupRow('g1'))?.lastOpenedAt, isNotNull);
    expect((await db.groupRow('g1'))?.serverUrl, 'https://api.spliit.test');
  });

  testWidgets('a server failure stays on the form with the error', (tester) async {
    final db = await openDb();
    expectUnexpectedError<SpliitApiException>('Saving group settings');
    final s = server(create: () async => http.Response('boom', 500));
    final popped = await openAndCreate(tester, db, s.client);

    expect(popped, isNull);
    expect(find.text("Couldn't save the group settings."), findsOneWidget);
    expect(find.byType(GroupSettingsScreen), findsOneWidget);
    expect(await db.cachedGroup('g1'), isNull);
  });

  testWidgets('a failed read after creating retries the read, never a second create',
      (tester) async {
    final db = await openDb();
    expectUnexpectedError<SpliitApiException>('Saving group settings');
    var gets = 0;
    var failGet = true;
    final s = server(get: () async {
      gets++;
      if (failGet) return http.Response('boom', 500);
      return http.Response(_groupJson(), 200);
    });

    String? popped;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<String>(MaterialPageRoute(
              builder: (_) => GroupSettingsScreen.create(db: db, client: s.client),
            ));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Group name'), 'Trip');
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();

    expect(popped, isNull);
    expect(find.text("Couldn't save the group settings."), findsOneWidget);
    expect(gets, 1);

    failGet = false;
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();

    expect(popped, 'g1');
    expect(gets, 2);
    // Created once, read twice.
    expect(s.requests.where((r) => r.url.path.endsWith('groups.create')), hasLength(1));
    expect(await db.cachedGroup('g1'), isNotNull);
  });
}
