import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/l10n/app_localizations.dart';
import 'package:godutch/main.dart';
import 'package:godutch/models/account.dart';
import 'package:godutch/models/expense.dart';
import 'package:godutch/models/group.dart';
import 'package:godutch/screens/group_list_screen.dart';
import 'package:godutch/screens/group_screen.dart';
import 'package:godutch/screens/join_group_screen.dart';
import 'package:godutch/screens/welcome_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/error_log.dart';

/// A signed-in Cloud where every name is a group. Links no longer open a
/// group directly (Cloud groups are invite-only), so these tests are about
/// routing: an invite opens Join, a recovery link opens Recovery, and a
/// launch with neither reopens where the app was left (#316).
class _FakeCloud extends SpliitClient {
  _FakeCloud({List<String>? groups})
      : groups = groups ?? ['g1'],
        super(baseUrl: 'https://api.spliit.test');

  final List<String> groups;
  final joined = <String>[];

  @override
  Future<CloudAccount?> restoreSession() async => const CloudAccount(
      id: 'a1', name: 'Ada', email: 'ada@example.test');

  @override
  Future<List<CloudGroupSummary>> fetchGroupSummaries() async => [
        for (final id in groups)
          CloudGroupSummary(
            group: Group(id: id, name: _name(id), currency: '€', participants: const []),
          ),
      ];

  @override
  Future<Group> fetchGroup(String groupId) async =>
      Group(id: groupId, name: _name(groupId), currency: '€', participants: const []);

  @override
  Future<List<Expense>> fetchExpenses(String groupId) async => const [];

  @override
  Future<InvitePreview?> previewInvite(String token) async => const InvitePreview(
        groupId: 'new',
        groupName: 'New trip',
        inviterName: 'Ada',
        usable: true,
        memberCount: 2,
      );

  @override
  Future<String> acceptInvite(String token, {String? expectedGroupId}) async {
    final id = expectedGroupId ?? 'new';
    joined.add(id);
    if (!groups.contains(id)) groups.add(id);
    return id;
  }

  String _name(String id) => switch (id) {
        'g1' => 'Trip',
        'new' => 'New trip',
        _ => id,
      };
}

void main() {
  late AppDatabase db;
  late StreamController<Uri> links;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    links = StreamController<Uri>();
  });
  tearDown(() async {
    await links.close();
    await db.close();
  });

  // A Cloud invite token is 16-128 url-safe characters; a plain group URL
  // is not joinable on Cloud.
  Uri invite({String group = 'new', String token = 'abcdefghijklmnop1234'}) =>
      Uri.parse('https://spliit.cloud/groups/$group?invite=$token');

  Future<void> mount(WidgetTester tester,
      {Future<Uri?>? initial, _FakeCloud? cloud}) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [groupListRouteObserver],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppRoot(
          db: db,
          links: links.stream,
          initialLink: initial,
          clientFactory: (_) => cloud ?? _FakeCloud()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a cold invite link prefills Join, and takes precedence over the last group',
      (tester) async {
    await db.cacheGroup(
        const Group(id: 'g1', name: 'Trip', currency: '€', participants: []));
    await db.recordGroupOpened('g1', serverUrl: 'https://api.spliit.test');
    await mount(tester, initial: Future.value(invite()));

    expect(find.byType(JoinGroupScreen), findsOneWidget);
    expect(find.byType(GroupScreen), findsNothing);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField))
          .controller!
          .text,
      invite().toString(),
    );
    await dispose(tester);
  });

  testWidgets('duplicate warm links open just one route', (tester) async {
    await mount(tester, cloud: _FakeCloud(groups: []));
    links.add(invite());
    links.add(invite());
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsNothing);
    expect(find.byType(GroupListScreen), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('unrelated and malformed links are ignored; a valid invite still works',
      (tester) async {
    expectUnexpectedError<Exception>('Receiving an app link');
    await mount(tester, cloud: _FakeCloud(groups: []));
    for (final url in [
      'https://evil.test/groups/g1',
      'http://api.spliit.test/groups/g1?invite=abcdefghijklmnop1234',
      'https://api.spliit.test/groups/g1',
      'https://api.spliit.test/groups/',
      'https://api.spliit.test/about',
      'http://api.spliit.test:8443/groups/g1?invite=abcdefghijklmnop1234',
      'https://api.spliit.test/groups/g1?invite=short',
    ]) {
      links.add(Uri.parse(url));
    }
    links.addError(Exception('invalid platform event'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsNothing);

    links.add(invite());
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('joining an invite opens the fetched group; back returns to the list',
      (tester) async {
    final cloud = _FakeCloud(groups: []);
    await mount(tester, initial: Future.value(invite()), cloud: cloud);
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(cloud.joined, ['new']);
    // The join flow returns to the list, whose sync then shows the group;
    // it doesn't also push the group on top.
    expect(find.byType(GroupScreen), findsNothing);
    expect(find.byType(JoinGroupScreen), findsNothing);
    expect((await db.groupRow('new'))?.serverUrl, 'https://api.spliit.test');
    await tester.pumpAndSettle();
    expect(find.byType(GroupListScreen), findsOneWidget);
    expect(find.text('New trip'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('a plain group URL does not open anything (Cloud groups are private)',
      (tester) async {
    await mount(tester, cloud: _FakeCloud(groups: []));
    links.add(Uri.parse('https://api.spliit.test/groups/g1'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsNothing);
    expect(find.byType(WelcomeScreen), findsNothing);
    expect(find.byType(GroupListScreen), findsOneWidget);
    await dispose(tester);
  });

  group('a launch starts where the app was left (#316)', () {
    setUp(() async {
      await db.cacheGroup(
          const Group(id: 'g1', name: 'Trip', currency: '€', participants: []));
      await db.recordGroupOpened('g1', serverUrl: 'https://api.spliit.test');
    });

    // A new launch: the app's link stream is a fresh one.
    Future<void> relaunch(WidgetTester tester) async {
      await dispose(tester);
      // Not awaited: its done event goes to a listener that's gone.
      unawaited(links.close());
      links = StreamController<Uri>();
      await mount(tester);
    }

    Future<bool?> reopen() async =>
        (await SharedPreferences.getInstance()).getBool('reopen_last_group');

    testWidgets('in the last group, as before, on an install from before #316',
        (tester) async {
      await mount(tester);
      expect(find.byType(GroupScreen), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('on the list, once the user went back to it', (tester) async {
      await mount(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await reopen(), isFalse);

      await relaunch(tester);
      expect(find.byType(GroupScreen), findsNothing);
      expect(find.byType(GroupListScreen), findsOneWidget);

      // Opening a group from the list: the next launch is in it again.
      await tester.tap(find.text('Trip'));
      await tester.pumpAndSettle();
      expect(await reopen(), isTrue);
      await relaunch(tester);
      expect(find.byType(GroupScreen), findsOneWidget);
      await dispose(tester);
    });
  });
}
