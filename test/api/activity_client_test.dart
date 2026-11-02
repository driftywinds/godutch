import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/cloud_connection.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/models/activity.dart';

void main() {
  group('ActivityType.fromWire', () {
    test('parses both the old and Cloud wire values', () {
      expect(ActivityType.fromWire('UPDATE_GROUP'), ActivityType.updateGroup);
      expect(ActivityType.fromWire('GROUP_UPDATED'), ActivityType.updateGroup);
      expect(ActivityType.fromWire('CREATE_EXPENSE'), ActivityType.createExpense);
      expect(
          ActivityType.fromWire('EXPENSE_CREATED'), ActivityType.createExpense);
      expect(
          ActivityType.fromWire('EXPENSE_DELETED'), ActivityType.deleteExpense);
      expect(ActivityType.fromWire('INVITATION_CREATED'),
          ActivityType.inviteMember);
    });

    test('falls back to updateGroup for an unrecognized value', () {
      expect(ActivityType.fromWire('SOMETHING_NEW'), ActivityType.updateGroup);
    });
  });

  group('SpliitClient.fetchActivities', () {
    test('parses Cloud activities, actor snapshots and pagination', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'activities': [
                  {
                    'id': 'a1',
                    'time': '2026-09-01T12:00:00.000Z',
                    'type': 'EXPENSE_CREATED',
                    'actorType': 'ACCOUNT',
                    'actorId': 'u1',
                    'actorName': 'Ada',
                    'subjectType': 'EXPENSE',
                    'subjectId': 'e1',
                    'data': {'summary': 'Groceries'},
                    'expense': {'id': 'e1'},
                  },
                  {
                    'id': 'a2',
                    'time': '2026-09-01T09:00:00.000Z',
                    'type': 'EXPENSE_DELETED',
                    'actorType': 'ACCOUNT',
                    'actorId': 'u1',
                    'actorName': 'Ada',
                    'subjectType': 'EXPENSE',
                    'subjectId': 'e2',
                    'data': null,
                    'expense': null,
                  },
                  {
                    'id': 'a3',
                    'time': '2026-08-31T08:00:00.000Z',
                    'type': 'GROUP_UPDATED',
                    'actorType': null,
                    'actorId': null,
                    'actorName': null,
                    'subjectType': 'GROUP',
                    'subjectId': 'g1',
                    'data': null,
                    'expense': null,
                  },
                ],
                'hasMore': true,
                'nextCursor': 3,
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://api.example.test',
        connection: CloudConnection(
            baseUrl: 'https://api.example.test',
            cookies: const {'better-auth.session_token': 't'}),
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final page = await client.fetchActivities(groupId: 'g1');

      expect(page.activities, hasLength(3));
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 3);

      final created = page.activities[0];
      expect(created.activityType, ActivityType.createExpense);
      expect(created.actorName, 'Ada');
      expect(created.expenseId, 'e1');
      expect(created.expenseExists, isTrue);
      expect(created.data, 'Groceries');

      final deleted = page.activities[1];
      expect(deleted.activityType, ActivityType.deleteExpense);
      expect(deleted.expenseExists, isFalse);

      final groupUpdate = page.activities[2];
      expect(groupUpdate.activityType, ActivityType.updateGroup);
      expect(groupUpdate.actorName, isNull);
      expect(groupUpdate.expenseId, isNull);
    });

    test('a missing nested expense still yields the subject id', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'activities': [
                  {
                    'id': 'a1',
                    'time': '2026-09-01T12:00:00.000Z',
                    'type': 'GROUP_UPDATED',
                    'actorName': 'Ada',
                    'subjectType': 'GROUP',
                    'subjectId': 'g1',
                    'data': null,
                    'expense': null,
                  },
                ],
                'hasMore': false,
                'nextCursor': 1,
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://api.example.test',
        connection: CloudConnection(
            baseUrl: 'https://api.example.test',
            cookies: const {'better-auth.session_token': 't'}),
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final page = await client.fetchActivities(groupId: 'g1');

      expect(page.activities.single.expenseExists, isFalse);
      expect(page.hasMore, isFalse);
    });
  });
}
