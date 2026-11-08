import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:godutch/api/cloud_connection.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/models/category.dart';
import 'package:godutch/models/expense.dart';
import 'package:godutch/services/device_time_zone.dart';

/// A cloud client backed by [handler], with its own in-memory session.
SpliitClient cloudClient(Future<http.Response> Function(http.Request) handler) {
  final connection = CloudConnection(
    baseUrl: 'https://api.example.test',
    cookies: const {'__Secure-better-auth.session_token': 'test-token'},
  );
  return SpliitClient(
    baseUrl: connection.baseUrl,
    connection: connection,
    httpClient: MockClient(handler),
  );
}

String trpcJson(Object? data) => jsonEncode([
      {
        'result': {
          'data': {'json': data}
        }
      }
    ]);

String trpcError(String code, String message, {int status = 400}) => jsonEncode([
      {
        'error': {
          'json': {
            'message': message,
            'code': -32000,
            'data': {'code': code, 'httpStatus': status},
          }
        }
      }
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // CloudConnection.save() persists through SharedPreferences.
    SharedPreferences.setMockInitialValues({});
    // The timezone database is normally initialized by the platform name
    // lookup; in a unit test no platform channel exists.
    DeviceTimeZone.dateInZone(DateTime.utc(2026, 1, 1), 'UTC');
  });

  test('sign-in stores the Better Auth cookies and updates the name', () async {
    final requests = <http.Request>[];
    final client = cloudClient((request) async {
      requests.add(request);
      if (request.url.path == '/auth/sign-in/anonymous') {
        return http.Response(
          jsonEncode({
            'token': 'token',
            'user': {
              'id': 'u1',
              'name': 'guest@anonymous.placeholder.local',
              'email': 'guest@anonymous.placeholder.local',
              'isAnonymous': true,
            }
          }),
          200,
          headers: {
            'set-cookie':
                '__Secure-better-auth.session_token=abc123; Path=/; HttpOnly; Secure; SameSite=Lax, '
                    '__Secure-better-auth.session_data=data456; Path=/; HttpOnly; Secure; SameSite=Lax'
          },
        );
      }
      if (request.url.path == '/trpc/account.updateProfile') {
        return http.Response(
          trpcJson({
            'account': {
              'id': 'u1',
              'name': 'Ada',
              'email': 'guest@anonymous.placeholder.local',
              'isAnonymous': true,
            }
          }),
          200,
        );
      }
      fail('unexpected request ${request.method} ${request.url}');
    });

    final account = await client.signInAnonymously(name: 'Ada');

    expect(account.name, 'Ada');
    expect(account.isAnonymous, isTrue);
    expect(client.connection.cookieHeader,
        contains('__Secure-better-auth.session_token=abc123'));
    expect(client.connection.cookieHeader,
        contains('__Secure-better-auth.session_data=data456'));
    final profile = requests.last;
    expect(profile.headers['cookie'], contains('session_token=abc123'));
    expect(profile.headers['origin'], 'https://api.example.test');
    expect(jsonDecode(profile.body), {
      '0': {
        'json': {'name': 'Ada'}
      }
    });
  });

  test('restoreSession clears a rejected cookie', () async {
    final client = cloudClient((request) async =>
        http.Response(jsonEncode({'message': 'invalid'}), 401));
    expect(await client.restoreSession(), isNull);
    expect(client.connection.hasSession, isFalse);
  });

  test('fetchGroup maps members, participants and the current identity',
      () async {
    late Uri uri;
    final client = cloudClient((request) async {
      uri = request.url;
      return http.Response(
        trpcJson({
          'group': {
            'id': 'g1',
            'name': 'Trip',
            'information': 'notes',
            'archived': false,
            'createdAt': '2026-01-01T00:00:00.000Z',
            'groupType': 'GROUP',
            'emoji': '✈️',
            'color': '#ff0000',
            'ledgerId': 'l1',
            'ledger': {'currency': r'$', 'currencyCode': 'USD'},
            'members': [
              {
                'id': 'm1',
                'accountId': 'u1',
                'role': 'ADMIN',
                'status': 'ACTIVE',
                'account': {
                  'id': 'u1',
                  'name': 'Ada',
                  'email': 'ada@example.test',
                  'image': null
                },
                'ledgerParticipant': {'id': 'p1'},
              },
              {
                'id': 'm2',
                'accountId': 'u2',
                'role': 'MEMBER',
                'status': 'ACTIVE',
                'account': {
                  'id': 'u2',
                  'name': 'Bea',
                  'email': 'bea@example.test',
                  'image': null
                },
                'ledgerParticipant': {'id': 'p2'},
              },
            ],
            'participants': [
              {'id': 'p1', 'name': 'Ada', 'account': {'id': 'u1'}, 'pending': false, 'unlinked': false},
              {'id': 'p2', 'name': 'Bea', 'account': {'id': 'u2'}, 'pending': false, 'unlinked': false},
            ],
          },
          'displayName': 'Trip',
          'currentLedgerParticipantId': 'p1',
          'currentMember': {'id': 'm1', 'role': 'ADMIN', 'status': 'ACTIVE'},
          'currentInvitation': null,
          'linkInviteState': null,
          'viewer': {
            'source': 'MEMBER',
            'access': 'READ_WRITE',
            'canMutate': true,
            'canAcceptInvitation': false,
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final group = await client.fetchGroup('g1');

    expect(group.name, 'Trip');
    expect(group.emoji, '✈️');
    expect(group.ledgerId, 'l1');
    expect(group.isAdmin, isTrue);
    expect(group.currentParticipantId, 'p1');
    expect(group.members.map((m) => m.name), ['Ada', 'Bea']);
    expect(group.participants.map((p) => p.id), ['p1', 'p2']);
    expect(uri.queryParameters['input'], contains('g1'));
  });

  test('fetchExpenses follows pages and maps Cloud shares/date/zone',
      () async {
    var page = 0;
    final client = cloudClient((request) async {
      page++;
      return http.Response(
        trpcJson({
          'expenses': [
            {
              'id': 'e$page',
              'title': 'Dinner',
              'amount': 1200,
              'expenseDate': '2026-01-01T18:30:00.000Z',
              'expenseTimeZone': 'Asia/Calcutta',
              'categoryId': 'groceries',
              'category': {
                'id': 'groceries',
                'grouping': 'Food and Drink',
                'name': 'Groceries'
              },
              'splitMode': 'EVENLY',
              'paidBySplitMode': 'BY_AMOUNT',
              'paidByList': [
                {
                  'ledgerParticipant': {'id': 'p1'},
                  'shares': 600
                },
                {
                  'ledgerParticipant': {'id': 'p2'},
                  'shares': 600
                },
              ],
              'paidFor': [
                {'ledgerParticipant': {'id': 'p1'}, 'shares': 1},
                {'ledgerParticipant': {'id': 'p2'}, 'shares': 1},
              ],
              'isMultiPayer': true,
              'recurringSeriesId': null,
              'recurringSeriesStatus': null,
              'documentCount': 0,
              'permissions': {
                'canEdit': true,
                'canDelete': false,
                'canManageRecurrence': false
              },
              'createdAt': '2026-01-01T00:00:00.000Z',
            }
          ],
          'hasMore': page == 1,
          'nextCursor': page == 1 ? 1 : 2,
        }),
        200,
      );
    });
    final expenses = await client.fetchExpenses('g1');

    expect(expenses, hasLength(2));
    final expense = expenses.first;
    expect(expense.categoryId, 'groceries');
    expect(expense.category, 9);
    expect(expense.isMultiPayer, isTrue);
    expect(expense.payers, hasLength(2));
    expect(expense.paidBy, 'p1');
    expect(expense.date, DateTime(2026, 1, 2));
    expect(expense.canDelete, isFalse);
  });

  test('createExpense sends Cloud payload with idempotency and settlement',
      () async {
    late Map<String, dynamic> body;
    final client = cloudClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(trpcJson({'expenseId': 'e1'}), 200);
    });
    final id = await client.createExpense(
      groupId: 'g1',
      title: 'Rent',
      amountCents: 1000,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p2', shares: 1000)],
      splitMode: SplitMode.byAmount,
      category: 46,
      isSettlement: true,
      date: DateTime(2026, 2, 3),
      requestId: '00000000-0000-4000-8000-000000000000',
    );

    expect(id, 'e1');
    final input = (body['0'] as Map)['json'] as Map<String, dynamic>;
    expect(input['requestId'], '00000000-0000-4000-8000-000000000000');
    final expense = input['expense'] as Map<String, dynamic>;
    expect(expense['category'], 'settlement');
    expect(expense['amount'], 1000);
    expect(expense['paidBySplitMode'], 'BY_AMOUNT');
    expect((expense['paidByList'] as List).single, {
      'participant': 'p1',
      'shares': 1000
    });
    expect(expense['paidFor'], [
      {'participant': 'p2', 'shares': 1000}
    ]);
    expect(expense['expenseTimeZone'], 'UTC');
    expect(DateTime.parse(expense['expenseDate']).toUtc(), DateTime.utc(2026, 2, 3, 12));
    // A flat expense says nothing about items, as it always did.
    expect(expense.containsKey('items'), isFalse);
    expect(expense.containsKey('itemizedRemainder'), isFalse);
  });

  test('fetchExpense reads the items and the leftover, as Cloud sends them', () async {
    final client = cloudClient((request) async => http.Response(
          trpcJson({
            'expense': {
              'id': 'e1',
              'title': 'Dinner',
              'amount': 3000,
              'expenseDate': '2026-11-03T12:00:00.000Z',
              'expenseTimeZone': 'UTC',
              'categoryId': 'general',
              'splitMode': 'BY_AMOUNT',
              'paidBySplitMode': 'BY_AMOUNT',
              'paidByList': [
                {'ledgerParticipantId': 'p1', 'shares': 3000}
              ],
              'paidFor': [
                {'ledgerParticipantId': 'p1', 'shares': 1000},
                {'ledgerParticipantId': 'p2', 'shares': 2000}
              ],
              'items': [
                {
                  'id': 'i1',
                  'title': 'Starter',
                  'unitPrice': 500,
                  'quantity': 2000,
                  'amount': 1000,
                  'splitMode': 'BY_SHARES',
                  'paidFor': [
                    {'ledgerParticipantId': 'p1', 'shares': 300},
                    {'ledgerParticipantId': 'p2', 'shares': 100}
                  ],
                },
              ],
              'itemizedRemainder': {
                'splitMode': 'EVENLY',
                'allocationMode': 'CUSTOM',
                'paidFor': [
                  {'ledgerParticipantId': 'p2', 'shares': 1}
                ],
              },
              'version': 1,
              'createdAt': '2026-11-03T00:00:00.000Z',
              'notes': '',
              'documents': [],
            }
          }),
          200,
        ));

    final expense = await client.fetchExpense(groupId: 'g1', expenseId: 'e1');
    final item = expense.items.single;
    expect((item.id, item.title, item.amountCents, item.unitPriceCents, item.quantityMilli),
        ('i1', 'Starter', 1000, 500, 2000));
    expect(item.splitMode, SplitMode.byShares);
    expect(item.paidFor.map((s) => (s.participantId, s.shares)), [('p1', 300), ('p2', 100)]);
    final remainder = expense.itemizedRemainder!;
    expect((remainder.splitMode, remainder.allocationMode), (SplitMode.evenly, 'CUSTOM'));
    expect(remainder.paidFor.single.participantId, 'p2');
  });

  test('an itemized update sends its items and leftover; a flat one leaves them out',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final client = cloudClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(trpcJson({'expenseId': 'e1'}), 200);
    });

    Map<String, dynamic> expenseOf(Map<String, dynamic> body) =>
        ((body['0'] as Map)['json'] as Map<String, dynamic>)['expense'] as Map<String, dynamic>;

    await client.updateExpense(
      groupId: 'g1',
      expenseId: 'e1',
      title: 'Dinner',
      amountCents: 3000,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 1000)],
      documents: const [],
      expectedVersion: 1,
      items: const [
        ExpenseItem(
          id: 'i1',
          title: 'Starter',
          amountCents: 1000,
          unitPriceCents: 500,
          quantityMilli: 2000,
          splitMode: SplitMode.byShares,
          paidFor: [
            ExpenseShare(participantId: 'p1', shares: 300),
            ExpenseShare(participantId: 'p2', shares: 100),
          ],
        ),
      ],
      itemizedRemainder: const ExpenseItemizedRemainder(
        splitMode: SplitMode.byPercentage,
        paidFor: [ExpenseShare(participantId: 'p2', shares: 10000)],
      ),
    );
    final sent = expenseOf(bodies.last);
    expect(sent['items'], [
      {
        'id': 'i1',
        'title': 'Starter',
        'unitPrice': 500,
        'quantity': 2000,
        'amount': 1000,
        'splitMode': 'BY_SHARES',
        'paidFor': [
          {'participant': 'p1', 'shares': 300},
          {'participant': 'p2', 'shares': 100},
        ],
      }
    ]);
    // Cloud's own tag isn't invented when it isn't known.
    expect(sent['itemizedRemainder'], {
      'splitMode': 'BY_PERCENTAGE',
      'paidFor': [
        {'participant': 'p2', 'shares': 10000}
      ],
    });

    // An edit that took every item away says so, so Cloud clears them.
    await client.updateExpense(
      groupId: 'g1',
      expenseId: 'e1',
      title: 'Dinner',
      amountCents: 3000,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
      documents: const [],
      expectedVersion: 2,
      items: const [],
    );
    expect(expenseOf(bodies.last)['items'], isEmpty);
    expect(expenseOf(bodies.last).containsKey('itemizedRemainder'), isFalse);
  });

  test('createExpense sends every payer, each with what they paid', () async {
    late Map<String, dynamic> body;
    final client = cloudClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(trpcJson({'expenseId': 'e1'}), 200);
    });
    await client.createExpense(
      groupId: 'g1',
      title: 'Dinner',
      amountCents: 3000,
      paidBy: 'p1',
      payers: const [
        ExpenseShare(participantId: 'p1', shares: 1200),
        ExpenseShare(participantId: 'p2', shares: 1800),
      ],
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 100)],
    );

    final input = (body['0'] as Map)['json'] as Map<String, dynamic>;
    final expense = input['expense'] as Map<String, dynamic>;
    expect(expense['isMultiPayer'], isTrue);
    expect(expense['paidBySplitMode'], 'BY_AMOUNT');
    expect(expense['paidByList'], [
      {'participant': 'p1', 'shares': 1200},
      {'participant': 'p2', 'shares': 1800},
    ]);
    expect(expense['amount'], 3000);
  });

  test('an update reads the version first when the caller has none', () async {
    final requests = <String>[];
    final client = cloudClient((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/trpc/groups.expenses.get') {
        return http.Response(
          trpcJson({
            'expense': {
              'id': 'e1',
              'title': 'Old',
              'amount': 100,
              'expenseDate': '2026-01-01T12:00:00.000Z',
              'expenseTimeZone': 'UTC',
              'categoryId': 'general',
              'category': {'id': 'general', 'grouping': 'Uncategorized', 'name': 'General'},
              'splitMode': 'EVENLY',
              'paidBySplitMode': 'BY_AMOUNT',
              'paidByList': [
                {'ledgerParticipantId': 'p1', 'shares': 100}
              ],
              'paidFor': [
                {'ledgerParticipantId': 'p1', 'shares': 1}
              ],
              'version': 7,
              'createdAt': '2026-01-01T00:00:00.000Z',
              'notes': null,
              'documents': [],
              'items': [],
              'itemizedRemainder': null,
              'recurringSeriesId': null,
              'recurringSeries': null,
              'recurrence': null,
              'permissions': {
                'canEdit': true,
                'canDelete': true,
                'canManageRecurrence': true
              },
            }
          }),
          200,
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final input = (body['0'] as Map)['json'] as Map<String, dynamic>;
      expect(input['expectedVersion'], 7);
      return http.Response(trpcJson({'expenseId': 'e1', 'version': 8}), 200);
    });

    await client.updateExpense(
      groupId: 'g1',
      expenseId: 'e1',
      title: 'New',
      amountCents: 100,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
      documents: const [],
    );

    expect(requests, [
      '/trpc/groups.expenses.get',
      '/trpc/groups.expenses.update'
    ]);
  });

  test('tRPC errors keep Cloud code and message', () async {
    final client = cloudClient((request) async => http.Response(
        trpcError('PRECONDITION_FAILED', 'unsettled balances', status: 412),
        412));
    expect(
      () => client.archiveGroup('g1', true),
      throwsA(isA<SpliitApiException>()
          .having((e) => e.isPreconditionFailed, 'precondition', isTrue)
          .having((e) => e.message, 'message', 'unsettled balances')),
    );
  });

  test('unauthorized is recognized', () async {
    final client = cloudClient((request) async => http.Response('', 401));
    expect(
      () => client.fetchGroupSummaries(),
      throwsA(isA<SpliitApiException>()
          .having((e) => e.isUnauthorized, 'unauthorized', isTrue)),
    );
  });

  test('invite preview and accept use the current instance', () async {
    final client = cloudClient((request) async {
      if (request.url.path == '/trpc/invitations.previewLink') {
        return http.Response(
          trpcJson({
            'preview': {
              'group': {'id': 'g1', 'name': 'Trip', 'groupType': 'GROUP'},
              'inviter': {'name': 'Ada'},
              'role': 'MEMBER',
              'usable': true,
              'memberCount': 2,
            }
          }),
          200,
        );
      }
      return http.Response(trpcJson({'groupId': 'g1', 'role': 'MEMBER'}), 200);
    });
    final preview = await client.previewInvite(
        'invite-token-1234567890');
    expect(preview?.groupName, 'Trip');
    expect(await client.acceptInvite('invite-token-1234567890'), 'g1');
  });

  test('cloud category mapping round-trips', () {
    expect(localCategoryIdForCloud('groceries'), 9);
    expect(cloudCategoryIdForLocal(9), 'groceries');
    expect(cloudCategoryIdForLocal(46), 'settlement');
  });

  test('a converted expense sends its paid-in amount and rate, not the group total', () async {
    // Cloud resolves `amount` in the expense's currency and multiplies it by
    // the rate: €100 at 1.1 is $110. Sending $110 with the same rate would
    // store $121.
    late Map<String, dynamic> input;
    final client = cloudClient((request) async {
      input = ((jsonDecode(request.body) as Map)['0'] as Map)['json'] as Map<String, dynamic>;
      return http.Response(trpcJson({'expenseId': 'e1'}), 200);
    });
    await client.createExpense(
      groupId: 'g1',
      title: 'Dinner',
      amountCents: 11000,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 10000)],
      originalAmountCents: 10000,
      originalCurrency: 'EUR',
      conversionRate: 1.1,
      date: DateTime(2026, 11, 3),
    );

    final expense = input['expense'] as Map<String, dynamic>;
    expect(expense['amount'], 10000);
    expect(expense['conversion'], {'type': 'custom', 'currency': 'EUR', 'rate': 1.1});
    // One payer pays the same paid-in amount.
    expect(expense['paidByList'], [
      {'participant': 'p1', 'shares': 10000}
    ]);
  });

  test('a converted expense splits its payers across the paid-in amount', () async {
    late Map<String, dynamic> input;
    final client = cloudClient((request) async {
      input = ((jsonDecode(request.body) as Map)['0'] as Map)['json'] as Map<String, dynamic>;
      return http.Response(trpcJson({'expenseId': 'e1'}), 200);
    });
    await client.createExpense(
      groupId: 'g1',
      title: 'Taxi',
      amountCents: 11000,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
      payers: const [
        ExpenseShare(participantId: 'p1', shares: 5500),
        ExpenseShare(participantId: 'p2', shares: 5500),
      ],
      originalAmountCents: 10000,
      originalCurrency: 'EUR',
      conversionRate: 1.1,
      date: DateTime(2026, 11, 3),
    );
    final expense = input['expense'] as Map<String, dynamic>;
    expect(expense['amount'], 10000);
    expect(expense['paidByList'], [
      {'participant': 'p1', 'shares': 5000},
      {'participant': 'p2', 'shares': 5000},
    ]);
  });

  test('an itemized expense keeps Cloud\'s split mode', () async {
    late Map<String, dynamic> input;
    final client = cloudClient((request) async {
      input = ((jsonDecode(request.body) as Map)['0'] as Map)['json'] as Map<String, dynamic>;
      return http.Response(trpcJson({'expenseId': 'e1'}), 200);
    });
    await client.createExpense(
      groupId: 'g1',
      title: 'Groceries',
      amountCents: 3000,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 3000)],
      splitMode: SplitMode.byAmount,
      date: DateTime(2026, 11, 3),
      items: const [
        ExpenseItem(
          id: '',
          title: 'Milk',
          amountCents: 3000,
          unitPriceCents: 1500,
          quantityMilli: 2000,
          paidFor: [ExpenseShare(participantId: 'p1', shares: 1)],
        ),
      ],
    );
    final expense = input['expense'] as Map<String, dynamic>;
    expect(expense['splitMode'], 'ITEMIZED');
  });

  test('a non-JSON error response keeps its HTTP status', () async {
    final client = cloudClient((request) async =>
        http.Response('<html>Bad gateway</html>', 502));
    expect(
      () => client.fetchGroupSummaries(),
      throwsA(isA<SpliitApiException>().having((e) => e.statusCode, 'status', 502)),
    );
  });

  test('an ITEMIZED expense is read as exact amounts, with its tag', () async {
    final client = cloudClient((request) async => http.Response(
          trpcJson({
            'expense': {
              'id': 'e1',
              'title': 'Groceries',
              'amount': 3000,
              'expenseDate': '2026-11-03T12:00:00.000Z',
              'expenseTimeZone': 'UTC',
              'categoryId': 'groceries',
              'splitMode': 'ITEMIZED',
              'paidBySplitMode': 'BY_AMOUNT',
              'paidByList': [
                {'ledgerParticipantId': 'p1', 'shares': 3000}
              ],
              'paidFor': [
                {'ledgerParticipantId': 'p1', 'shares': 1000},
                {'ledgerParticipantId': 'p2', 'shares': 2000}
              ],
              'version': 1,
            }
          }),
          200,
        ));
    final expense = await client.fetchExpense(groupId: 'g1', expenseId: 'e1');
    expect(expense.isItemized, isTrue);
    expect(expense.splitMode, SplitMode.byAmount);
    expect(expense.splitModeTag, 'ITEMIZED');
    expect(expense.paidFor.map((s) => s.shares), [1000, 2000]);
  });
}
