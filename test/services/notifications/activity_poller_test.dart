import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:godutch/api/cloud_connection.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/l10n/app_localizations.dart';
import 'package:godutch/models/group.dart';
import 'package:godutch/services/notifications/activity_poller.dart';
import 'package:godutch/services/notifications/notification_message.dart';
import 'package:godutch/services/settings_service.dart';

/// Remembers what went to the shade, in order.
class RecordingSink implements NotificationSink {
  final shown = <NotificationMessage>[];

  @override
  Future<void> show(NotificationMessage message) async => shown.add(message);
}

void main() {
  const baseUrl = 'https://example.test';

  /// A new activity-log entry, as Cloud sends it: `data.summary` is the
  /// expense's title.
  Map<String, dynamic> entry({
    required String id,
    required String type,
    required DateTime at,
    String? actor = 'Ana',
    String? title = 'Lunch',
  }) =>
      {
        'id': id,
        'time': at.toUtc().toIso8601String(),
        'type': type,
        'actorId': 'a1',
        'actorName': actor,
        'subjectType': title == null ? null : 'EXPENSE',
        'subjectId': title == null ? null : 'e-$id',
        'expense': null,
        'data': title == null
            ? null
            : {'kind': 'expense', 'summary': title, 'title': title},
      };

  String pageBody(List<Map<String, dynamic>> activities) => jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'activities': activities,
                'hasMore': false,
                'nextCursor': 20,
              }
            }
          }
        }
      ]);

  Future<AppDatabase> cachedGroup() async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
      id: 'g1',
      name: 'Banff Trip',
      currency: '\$',
      participants: [Participant(id: 'p1', name: 'Ken')],
    ));
    await db.recordGroupOpened('g1', serverUrl: baseUrl, at: DateTime(2026, 11, 1));
    return db;
  }

  /// The poller wired to a fake server that answers with [activities].
  Future<(ActivityPoller, RecordingSink, List<Uri>)> pollerFor(
    AppDatabase db,
    List<Map<String, dynamic>> activities, {
    DateTime? markAt,
    String? markId,
    Map<String, Object> prefs = const {'notifications_enabled': true},
    DateTime? now,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    if (markAt != null) {
      await db.setNotificationsChecked('g1', activityId: markId, at: markAt);
    }
    final requests = <Uri>[];
    final client = SpliitClient(
      baseUrl: baseUrl,
      connection: CloudConnection(baseUrl: baseUrl),
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response(pageBody(activities), 200);
      }),
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final sink = RecordingSink();
    final poller = ActivityPoller(
      db: db,
      client: client,
      sink: sink,
      settings: SettingsService(),
      l10n: l10n,
      now: () => now ?? DateTime(2026, 11, 12, 12),
    );
    return (poller, sink, requests);
  }

  DateTime at(int hours, [int minutes = 0]) =>
      DateTime(2026, 11, 12, hours, minutes);

  test('notifies about what is newer than the last look, oldest first', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [
        entry(id: 'a4', type: 'EXPENSE_CREATED', at: at(11), title: 'Dinner'),
        entry(id: 'a3', type: 'EXPENSE_CREATED', at: at(10, 30), title: 'Coffee'),
        entry(id: 'a2', type: 'EXPENSE_CREATED', at: at(10), title: 'Older'),
        entry(id: 'a1', type: 'EXPENSE_CREATED', at: at(9), title: 'Oldest'),
      ],
      markAt: at(10),
      markId: 'a2',
    );

    expect(await poller.poll(), 2);
    expect([for (final n in sink.shown) n.body], [
      'Ana added “Coffee”.',
      'Ana added “Dinner”.',
    ]);
    expect(sink.shown.first.title, 'Banff Trip');
    expect(sink.shown.first.category, NotificationCategory.expenses);
    expect(sink.shown.first.groupId, 'g1');
    expect(sink.shown.first.expenseId, 'e-a3');
    // The poll moved on to the newest entry it saw.
    final row = (await db.groupRow('g1'))!;
    expect(row.notificationsCheckedActivityId, 'a4');
    expect(row.notificationsCheckedAt, at(11));
  });

  test('a kind switched off is read past, not left to come back', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [
        entry(id: 'a2', type: 'EXPENSE_COMMENT_CREATED', at: at(11), title: 'Lunch'),
        entry(id: 'a1', type: 'EXPENSE_CREATED', at: at(10, 30), title: 'Coffee'),
      ],
      markAt: at(10),
      prefs: const {
        'notifications_enabled': true,
        'notification_category.comments': false,
      },
    );

    expect(await poller.poll(), 1);
    expect(sink.shown.single.category, NotificationCategory.expenses);
    // The comment still moved the mark: it is never notified about later.
    expect((await db.groupRow('g1'))!.notificationsCheckedActivityId, 'a2');
  });

  test('events older than the window move the mark without ringing', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [
        entry(id: 'a1', type: 'EXPENSE_CREATED', at: DateTime(2026, 11, 11, 10), title: 'Old'),
      ],
      markAt: DateTime(2026, 11, 10),
    );

    expect(await poller.poll(), 0);
    expect(sink.shown, isEmpty);
    expect((await db.groupRow('g1'))!.notificationsCheckedActivityId, 'a1');
  });

  test('each kind goes on its own channel, and only real news does', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [
        entry(id: 'a5', type: 'INVITATION_ACCEPTED', at: at(12), actor: 'Bea', title: null),
        entry(id: 'a4', type: 'GROUP_UPDATED', at: at(11, 30), title: null),
        entry(id: 'a3', type: 'EXPENSE_PAID', at: at(11), title: 'Taxi'),
        entry(id: 'a2', type: 'INVITATION_CREATED', at: at(10, 30), title: null),
        entry(id: 'a1', type: 'EXPENSE_UPDATED', at: at(10), title: 'Dinner'),
      ],
      markAt: at(9),
    );

    expect(await poller.poll(), 3);
    expect([for (final n in sink.shown) n.category], [
      NotificationCategory.expenses,
      NotificationCategory.settlements,
      NotificationCategory.members,
    ]);
    expect(sink.shown.last.body, 'Bea joined the group.');
    expect(sink.shown[1].body, 'Ana recorded a payment for “Taxi”.');
  });

  test('one poll notifies about the newest few, and no more', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [
        for (var i = 7; i >= 1; i--)
          entry(id: 'a$i', type: 'EXPENSE_CREATED', at: at(10, i), title: 'Item $i'),
      ],
      markAt: at(9),
    );

    expect(await poller.poll(), 5);
    expect([for (final n in sink.shown) n.body], [
      'Ana added “Item 3”.',
      'Ana added “Item 4”.',
      'Ana added “Item 5”.',
      'Ana added “Item 6”.',
      'Ana added “Item 7”.',
    ]);
  });

  test('switched off, it asks the server nothing at all', () async {
    final db = await cachedGroup();
    final (poller, sink, requests) = await pollerFor(
      db,
      [entry(id: 'a1', type: 'EXPENSE_CREATED', at: at(11))],
      prefs: const {},
    );

    expect(await poller.poll(), 0);
    expect(sink.shown, isEmpty);
    expect(requests, isEmpty);
  });

  test('a muted group is not asked about at all', () async {
    final db = await cachedGroup();
    await db.cacheGroup(const Group(
        id: 'g2', name: 'Ski Trip', currency: '\$', participants: []));
    await db.recordGroupOpened('g2', serverUrl: baseUrl, at: DateTime(2026, 11, 2));
    final (poller, sink, requests) = await pollerFor(
      db,
      [entry(id: 'a1', type: 'EXPENSE_CREATED', at: at(11))],
      markAt: at(10),
      prefs: const {
        'notifications_enabled': true,
        'notification_muted_groups': <String>['g1'],
      },
    );

    expect(await poller.poll(), 0);
    expect(sink.shown, isEmpty);
    // The muted group costs no request; the other one is still checked.
    expect(requests, hasLength(1));
    expect(requests.single.query, contains('g2'));
  });

  test('a group never polled before starts from its newest entry, quietly', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [
        entry(id: 'a2', type: 'EXPENSE_CREATED', at: at(11)),
        entry(id: 'a1', type: 'EXPENSE_CREATED', at: at(10)),
      ],
    );

    expect(await poller.poll(), 0);
    expect(sink.shown, isEmpty);
    // From here on, only what happens next is news.
    final row = (await db.groupRow('g1'))!;
    expect(row.notificationsCheckedActivityId, 'a2');
    expect(row.notificationsCheckedAt, at(11));
  });

  test('an anonymous account is named Someone, not its placeholder address', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [
        entry(
          id: 'a1',
          type: 'EXPENSE_CREATED',
          at: at(11),
          actor: 'guest-fab5012e@anonymous.placeholder.local',
        ),
      ],
      markAt: at(10),
    );

    await poller.poll();
    expect(sink.shown.single.body, 'Someone added “Lunch”.');
  });

  test('the payload reads back as where to go', () async {
    final db = await cachedGroup();
    final (poller, sink, _) = await pollerFor(
      db,
      [entry(id: 'a1', type: 'EXPENSE_CREATED', at: at(11))],
      markAt: at(10),
    );

    await poller.poll();
    final target = NotificationTarget.fromPayload(sink.shown.single.payload);
    expect(target, isNotNull);
    expect(target!.groupId, 'g1');
    expect(target.expenseId, 'e-a1');
  });
}
