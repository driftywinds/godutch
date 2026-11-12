import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/models/group.dart';

// Schema 25 keeps where the notification poll got to in each group's
// activity log.
void main() {
  test('a schema 24 database gains the notification marks, empty', () async {
    final dir = await Directory.systemTemp.createTemp('notifications_seen');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // Schema 24 is today's without the two columns.
    final current = AppDatabase(NativeDatabase(file));
    await current.cacheGroup(const Group(
        id: 'g1', name: 'Banff Trip', currency: '\$', participants: []));
    await current.customStatement(
        'ALTER TABLE "groups" DROP COLUMN notifications_checked_activity_id');
    await current.customStatement(
        'ALTER TABLE "groups" DROP COLUMN notifications_checked_at');
    await current.customStatement('PRAGMA user_version = 24');
    await current.close();

    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final row = await migrated.groupRow('g1');
    expect(row!.name, 'Banff Trip');
    expect(row.notificationsCheckedActivityId, isNull);
    expect(row.notificationsCheckedAt, isNull);

    // Opening the group marks it seen by time alone.
    await migrated.markGroupSeen('g1', at: DateTime(2026, 11, 12, 9));
    final seen = (await migrated.groupRow('g1'))!;
    expect(seen.notificationsCheckedActivityId, isNull);
    expect(seen.notificationsCheckedAt, DateTime(2026, 11, 12, 9));

    // A poll moves it on to the newest entry it read.
    await migrated.setNotificationsChecked('g1',
        activityId: 'a1', at: DateTime(2026, 11, 12, 10));
    final polled = (await migrated.groupRow('g1'))!;
    expect(polled.notificationsCheckedActivityId, 'a1');
    expect(polled.notificationsCheckedAt, DateTime(2026, 11, 12, 10));
  });
}
