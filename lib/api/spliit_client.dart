import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/account.dart';
import '../models/activity.dart';
import '../models/category.dart';
import '../models/currency.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/device_time_zone.dart';
import '../services/error_reporting.dart';
import 'cloud_connection.dart';

/// Coerces an id-shaped field to a String. Cloud ids are cuid/uuid strings,
/// but a lenient conversion keeps one odd response from crashing a screen.
String _asId(dynamic value) => value is String ? value : '$value';

DateTime _asDateTime(dynamic value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.round(), isUtc: true);
  }
  return DateTime.parse(value as String);
}

double _asDouble(dynamic value) =>
    value is num ? value.toDouble() : double.parse('$value');

int _asInt(dynamic value) => value is num ? value.round() : int.parse('$value');

class SpliitClient {
  final String baseUrl;
  final http.Client _http;
  final CloudConnection connection;

  SpliitClient({
    required this.baseUrl,
    http.Client? httpClient,
    CloudConnection? connection,
  })  : _http = httpClient ?? http.Client(),
        connection = connection ??
            CloudConnection.current ??
            CloudConnection(baseUrl: baseUrl);

  // ---------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------

  Uri _trpcUri(String procedure, {Map<String, dynamic>? input}) {
    final path = '$_trimmedBase/trpc/$procedure';
    final batched = jsonEncode({'0': {'json': input ?? const {}}});
    return Uri.parse('$path?batch=1&input=${Uri.encodeComponent(batched)}');
  }

  String get _trimmedBase => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  Map<String, String> _headers({bool json = true}) => {
        'accept': 'application/json',
        if (json) 'content-type': 'application/json',
        'origin': connection.origin,
        'referer': '$_trimmedBase/',
        if (connection.cookieHeader case final cookie?) 'cookie': cookie,
      };

  void _rememberCookies(http.Response response) {
    connection.absorb(response);
  }

  dynamic _decodeBatch(http.Response response) {
    _rememberCookies(response);
    if (response.statusCode == 401) {
      throw SpliitApiException(
        response.statusCode,
        response.body,
        code: 'UNAUTHORIZED',
        message: 'Sign in to continue.',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw SpliitResponseFormatException('Not JSON: $e');
    }
    final first = decoded is List
        ? (decoded.isEmpty ? null : decoded.first)
        : decoded;
    if (first is! Map<String, dynamic>) {
      if (response.statusCode >= 200 && response.statusCode < 300) return null;
      throw SpliitApiException(response.statusCode, response.body);
    }
    if (first['error'] != null) {
      final error = first['error'];
      final payload = error is Map && error['json'] is Map
          ? error['json'] as Map<String, dynamic>
          : error as Map?;
      final data = payload?['data'];
      final code = data is Map ? data['code'] as String? : null;
      final message = payload?['message'] as String? ??
          ((data is Map && data['message'] is String)
              ? data['message'] as String
              : null);
      throw SpliitApiException(
        response.statusCode,
        response.body,
        code: code,
        message: message,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SpliitApiException(response.statusCode, response.body);
    }
    final result = first['result'];
    if (result is! Map<String, dynamic>) return null;
    final data = result['data'];
    if (data is Map<String, dynamic> && data.containsKey('json')) {
      return data['json'];
    }
    return data;
  }

  Future<dynamic> _query(String procedure, [Map<String, dynamic>? input]) async {
    final response = await _http.get(_trpcUri(procedure, input: input),
        headers: _headers(json: false));
    return _decodeBatch(response);
  }

  Future<dynamic> _mutate(String procedure, [Map<String, dynamic>? input]) async {
    final response = await _http.post(
      Uri.parse('$_trimmedBase/trpc/$procedure?batch=1'),
      headers: _headers(),
      body: jsonEncode({
        '0': {'json': input ?? const {}}
      }),
    );
    return _decodeBatch(response);
  }

  Uri _authUri(String path) => Uri.parse('$_trimmedBase/auth$path');

  Future<Map<String, dynamic>> _auth(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = _authUri(path);
    final headers = _headers(json: body != null);
    final http.Response response;
    if (method == 'GET') {
      response = await _http.get(uri, headers: headers);
    } else {
      response = await _http.post(uri,
          headers: headers, body: jsonEncode(body ?? const {}));
    }
    _rememberCookies(response);
    Map<String, dynamic> decoded;
    try {
      final value = response.body.trim().isEmpty ? null : jsonDecode(response.body);
      decoded = value is Map<String, dynamic>
          ? value
          : <String, dynamic>{'value': value};
    } on FormatException {
      decoded = <String, dynamic>{'raw': response.body};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded['code'] as String?;
      final message = decoded['message'] as String?;
      throw CloudAuthException(
        message ?? _messageForAuthCode(code) ?? 'Sign-in failed.',
        code: code,
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  static String? _messageForAuthCode(String? code) => switch (code) {
        'INVALID_EMAIL_OR_PASSWORD' => 'That email and password do not match.',
        'EMAIL_NOT_VERIFIED' => 'Verify your email address before signing in.',
        'USER_ALREADY_EXISTS' => 'An account with that email already exists.',
        'ANONYMOUS_SIGNUP_ACCOUNT_CONFLICT' =>
          'Sign out before creating another account.',
        'ANONYMOUS_SIGNUP_RATE_LIMITED' =>
          'Too many new accounts from this network. Try again later.',
        'EMAIL_AUTH_DISABLED' =>
          'Email sign-in is disabled on this instance. Use a recovery link.',
        'PASSWORD_POLICY_NOT_MET' =>
          'Use at least 8 characters with uppercase, lowercase, a number and a symbol.',
        _ => null,
      };

  // ---------------------------------------------------------------------
  // Authentication
  // ---------------------------------------------------------------------

  /// Reads `/auth/get-session`. Returns the account and stores the session,
  /// or clears it when the cookie is no longer valid.
  Future<CloudAccount?> restoreSession() async {
    if (!connection.hasSession) return null;
    try {
      final data = await _auth('GET', '/get-session');
      final user = data['user'];
      if (user is! Map<String, dynamic>) {
        await connection.clearSession();
        return null;
      }
      final account = CloudAccount.fromJson(user);
      connection.account = account;
      await connection.save();
      return account;
    } on CloudAuthException {
      await connection.clearSession();
      return null;
    } on SpliitApiException {
      await connection.clearSession();
      return null;
    }
  }

  /// Creates the fork's email-free account: a display name and a recovery
  /// link/passkey later, no email or social identity.
  Future<CloudAccount> signInAnonymously({String? name}) async {
    final data = await _auth('POST', '/sign-in/anonymous', body: const {});
    var account = await _accountFromAuthResponse(data);
    final wanted = name?.trim();
    if (wanted != null && wanted.isNotEmpty && wanted != account.name) {
      account = await updateProfile(wanted);
    }
    await connection.save();
    return account;
  }

  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  }) async {
    await _auth('POST', '/sign-up/email', body: {
      'name': name.trim(),
      'email': email.trim(),
      'password': password,
    });
  }

  Future<CloudAccount> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final data = await _auth('POST', '/sign-in/email', body: {
      'email': email.trim(),
      'password': password,
      'rememberMe': true,
    });
    final account = await _accountFromAuthResponse(data);
    await connection.save();
    return account;
  }

  Future<void> requestPasswordReset(String email) async {
    await _auth('POST', '/request-password-reset', body: {
      'email': email.trim(),
      'redirectTo': '$_trimmedBase/reset-password',
    });
  }

  Future<void> signOut() async {
    try {
      await _auth('POST', '/sign-out', body: const {});
    } on CloudAuthException {
      // An already-expired session is signed out enough.
    } finally {
      await connection.clearSession();
    }
  }

  Future<AnonymousRecoveryStatus> anonymousRecoveryStatus() async {
    final data = await _auth('GET', '/anonymous-recovery/status');
    return AnonymousRecoveryStatus.fromJson(data);
  }

  Future<AnonymousRecoveryKey> setupAnonymousRecovery() async {
    final data = await _auth('POST', '/anonymous-recovery/setup');
    return AnonymousRecoveryKey.fromJson(data);
  }

  /// Replaces an already-acknowledged recovery key with a new pending one.
  Future<AnonymousRecoveryKey> replaceAnonymousRecovery() async {
    final data = await _auth('POST', '/anonymous-recovery/setup/replace',
        body: const {'confirmed': true});
    return AnonymousRecoveryKey.fromJson(data);
  }

  Future<void> acknowledgeAnonymousRecovery(String code) async {
    await _auth('POST', '/anonymous-recovery/acknowledge', body: {
      'confirmedCopied': true,
      'code': code,
    });
  }

  Future<CloudAccount> signInWithRecoveryCode(String code) async {
    await _auth('POST', '/sign-in/anonymous-recovery', body: {
      'code': code.trim(),
      'replaceCurrentSession': true,
    });
    final account = await restoreSession();
    if (account == null) {
      throw CloudAuthException('That recovery link is no longer valid.');
    }
    return account;
  }

  Future<CloudAccount> updateProfile(String name) async {
    final data = await _mutate('account.updateProfile', {'name': name.trim()});
    final raw = data is Map<String, dynamic> ? data['account'] : null;
    final account = raw is Map<String, dynamic>
        ? CloudAccount.fromJson(raw)
        : connection.account?.copyWithName(name.trim());
    if (account == null) {
      throw CloudAuthException('Could not update the profile.');
    }
    connection.account = account;
    await connection.save();
    return account;
  }

  Future<Map<String, dynamic>> accountPreferences() async {
    final data = await _query('account.getPreferences');
    return data is Map<String, dynamic>
        ? (data['preferences'] as Map<String, dynamic>? ?? const {})
        : const {};
  }

  Future<void> updateAccountPreferences(Map<String, dynamic> changes) async {
    await _mutate('account.updatePreferences', changes);
  }

  /// People this account shares a group with, plus pending invitations the
  /// fork knows about. Cloud computes friendship from shared memberships.
  Future<List<CloudFriend>> fetchFriends() async {
    final data = await _query('account.friends');
    final friends = data is Map<String, dynamic> ? data['friends'] as List? : null;
    return [
      for (final raw in friends ?? const [])
        if (raw is Map<String, dynamic>) CloudFriend.fromJson(raw),
    ];
  }

  Future<CloudAccount> _accountFromAuthResponse(      Map<String, dynamic> data) async {
    final user = data['user'];
    if (user is Map<String, dynamic>) {
      final account = CloudAccount.fromJson(user);
      connection.account = account;
      return account;
    }
    final restored = await restoreSession();
    if (restored != null) return restored;
    throw CloudAuthException('Signed in, but no account was returned.');
  }

  // ---------------------------------------------------------------------
  // Account groups
  // ---------------------------------------------------------------------

  /// The account's groups (archived included), newest first. The cloud is
  /// the source of truth: a group is on the list because the account is a
  /// member, never because this device once remembered a URL.
  Future<List<CloudGroupSummary>> fetchGroupSummaries() async {
    final data = await _query('account.groups', {'includeArchived': true});
    final groups = data is Map<String, dynamic> ? data['groups'] as List? : null;
    return [
      for (final raw in groups ?? const [])
        _groupSummaryFromJson(raw as Map<String, dynamic>),
    ];
  }

  CloudGroupSummary _groupSummaryFromJson(Map<String, dynamic> json) {
    final ledger = json['ledger'] as Map<String, dynamic>?;
    final accounts = json['memberAccounts'] as List? ?? const [];
    final participants = [
      for (final a in accounts)
        if (a is Map<String, dynamic>)
          Participant(
            id: _asId(a['id']),
            name: a['name'] as String? ?? '',
            accountId: _asId(a['id']),
          ),
    ];
    final group = Group(
      id: _asId(json['id']),
      name: json['name'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      information: json['information'] as String?,
      currency: displayCurrencySymbol(
        ledger?['currencyCode'] as String? ??
            json['currencyCode'] as String?,
        ledger?['currency'] as String? ??
            json['currency'] as String? ??
            '\$',
      ),
      currencyCode: ledger?['currencyCode'] as String? ??
          json['currencyCode'] as String?,
      participants: participants,
      archived: json['archived'] as bool? ?? false,
      emoji: json['emoji'] as String?,
      color: json['color'] as String?,
      groupType: json['groupType'] as String? ?? 'GROUP',
      role: json['currentMemberRole'] as String?,
      memberCount: (json['memberCount'] as num?)?.round() ?? participants.length,
    );
    final pref = json['preference'] as Map<String, dynamic>?;
    return CloudGroupSummary(
      group: group,
      starred: pref?['starred'] as bool? ?? false,
      hidden: pref?['hidden'] as bool? ?? false,
      latestExpenseCreatedAt:
          DateTime.tryParse(json['latestExpenseCreatedAt'] as String? ?? ''),
    );
  }

  Future<Group> fetchGroup(String groupId) async {
    final data = await _query('groups.get', {'groupId': groupId});
    if (data is! Map<String, dynamic>) {
      throw SpliitResponseFormatException('groups.get: expected an object');
    }
    final raw = data['group'];
    if (raw == null) throw GroupNotFoundException(baseUrl, groupId);
    if (raw is! Map<String, dynamic>) {
      throw SpliitResponseFormatException('groups.get: expected a group');
    }
    final membersRaw = raw['members'] as List? ?? const [];
    final members = [
      for (final m in membersRaw)
        if (m is Map<String, dynamic>) _memberFromJson(m),
    ];
    final participantsRaw = raw['participants'] as List? ?? const [];
    var participants = [
      for (final p in participantsRaw)
        if (p is Map<String, dynamic>)
          Participant(
            id: _asId(p['id']),
            name: p['name'] as String? ?? '',
            accountId: p['account'] is Map
                ? _asId((p['account'] as Map)['id'])
                : null,
            pending: p['pending'] as bool? ?? false,
            unlinked: p['unlinked'] as bool? ?? false,
          ),
    ];
    // A group list row may carry only member accounts; the full fetch is
    // authoritative, but never leave the split picker with nobody if the
    // server omits a participant for an active member.
    if (participants.isEmpty) {
      participants = [
        for (final m in members)
          Participant(
            id: m.participantId ?? m.id,
            name: m.name,
            accountId: m.accountId,
          ),
      ];
    }
    final ledger = raw['ledger'] as Map<String, dynamic>?;
    final currencyCode = ledger?['currencyCode'] as String? ??
        raw['currencyCode'] as String?;
    final currentMember = data['currentMember'] as Map<String, dynamic>?;
    final currentId = data['currentLedgerParticipantId'] as String?;
    final accountId = connection.account?.id;
    final ownMember = members.where((m) => m.accountId == accountId).firstOrNull;
    final role = currentMember?['role'] as String? ??
        ownMember?.role ??
        (raw['role'] as String?);
    return Group(
      id: _asId(raw['id']),
      name: raw['name'] as String? ?? '',
      createdAt: DateTime.tryParse(raw['createdAt'] as String? ?? ''),
      information: raw['information'] as String?,
      currency: displayCurrencySymbol(
        currencyCode,
        ledger?['currency'] as String? ?? raw['currency'] as String? ?? '\$',
      ),
      currencyCode: currencyCode,
      participants: participantsByName(participants),
      archived: raw['archived'] as bool? ?? false,
      emoji: raw['emoji'] as String?,
      color: raw['color'] as String?,
      ledgerId: raw['ledgerId'] as String?,
      groupType: raw['groupType'] as String? ?? 'GROUP',
      role: role,
      currentParticipantId: currentId ??
          ownMember?.participantId,
      members: members,
      memberCount:
          members.where((m) => m.isActive).length,
    );
  }

  GroupMember _memberFromJson(Map<String, dynamic> json) {
    final account = json['account'] as Map<String, dynamic>?;
    final participant = json['ledgerParticipant'] as Map<String, dynamic>?;
    return GroupMember(
      id: _asId(json['id']),
      accountId: _asId(json['accountId'] ?? account?['id'] ?? ''),
      name: account?['name'] as String? ?? '',
      email: account?['email'] as String?,
      image: account?['image'] as String?,
      role: json['role'] as String? ?? 'MEMBER',
      status: json['status'] as String? ?? 'ACTIVE',
      participantId: participant?['id'] as String?,
    );
  }

  Future<List<Expense>> fetchExpenses(String groupId) async {
    final all = <Expense>[];
    dynamic cursor;
    var guard = 0;
    while (guard++ < 1000) {
      final query = <String, dynamic>{'groupId': groupId, 'limit': 100};
      if (cursor != null) query['cursor'] = cursor;
      final data = await _query('groups.expenses.list', query);
      if (data is! Map<String, dynamic>) {
        throw SpliitResponseFormatException(
            'groups.expenses.list: expected an object');
      }
      for (final raw in data['expenses'] as List? ?? const []) {
        all.add(_expenseFromJson(raw as Map<String, dynamic>, groupId: groupId));
      }
      if (data['hasMore'] != true) break;
      final next = data['nextCursor'];
      if (next == null || next == cursor) break;
      cursor = next;
    }
    return all;
  }

  Future<Expense> fetchExpense({
    required String groupId,
    required String expenseId,
  }) async {
    final data = await _query(
      'groups.expenses.get',
      {'groupId': groupId, 'expenseId': expenseId},
    );
    if (data is! Map<String, dynamic> ||
        data['expense'] is! Map<String, dynamic>) {
      throw SpliitResponseFormatException(
          'groups.expenses.get: expected an expense');
    }
    return _expenseFromJson(data['expense'] as Map<String, dynamic>,
        groupId: groupId, full: true);
  }

  Expense _expenseFromJson(Map<String, dynamic> json,
      {required String groupId, bool full = false}) {
    final categoryId = json['categoryId'] as String? ??
        (json['category'] is Map
            ? (json['category'] as Map)['id'] as String?
            : null) ??
        cloudGeneralCategoryId;
    final paidByList = _shares(json['paidByList']);
    final paidFor = _shares(json['paidFor']);
    final legacyPaidBy = json['paidBy'] is String ? json['paidBy'] as String : '';
    final localCategory = json['category'] is num
        ? (json['category'] as num).round()
        : localCategoryIdForCloud(categoryId);
    final documents = full
        ? [
            for (final d in json['documents'] as List? ?? const [])
              ExpenseDocument.fromJson(d as Map<String, dynamic>),
          ]
        : const <ExpenseDocument>[];
    final rawPermissions = json['permissions'] as Map<String, dynamic>?;
    final permissionFallback = rawPermissions == null;
    final recurrence = json['recurrence'] as Map<String, dynamic>?;
    final recurrenceRule = recurrence == null
        ? RecurrenceRule.none
        : switch (recurrence['frequency'] as String? ?? '') {
            'DAILY' => RecurrenceRule.daily,
            'WEEKLY' => RecurrenceRule.weekly,
            'MONTHLY' => RecurrenceRule.monthly,
            _ => RecurrenceRule.none,
          };
    return Expense(
      id: _asId(json['id']),
      groupId: groupId,
      title: json['title'] as String? ?? '',
      amountCents: _asInt(json['amount'] ?? 0),
      paidBy: paidByList.isEmpty ? legacyPaidBy : paidByList.first.participantId,
      paidFor: paidFor,
      splitMode: SplitModeWire.fromWire(json['splitMode'] as String? ?? 'EVENLY'),
      categoryId: categoryId,
      category: localCategory,
      paidByList: paidByList.isEmpty && legacyPaidBy.isNotEmpty
          ? [
              ExpenseShare(
                  participantId: legacyPaidBy, shares: _asInt(json['amount'] ?? 0))
            ]
          : paidByList,
      paidBySplitMode: SplitModeWire.fromWire(
          json['paidBySplitMode'] as String? ?? 'BY_AMOUNT'),
      isMultiPayer: json['isMultiPayer'] as bool? ??
          paidByList.map((p) => p.participantId).toSet().length > 1,
      version: _asInt(json['version'] ?? 1),
      canEdit: permissionFallback
          ? true
          : rawPermissions['canEdit'] as bool? ?? false,
      canDelete: permissionFallback
          ? true
          : rawPermissions['canDelete'] as bool? ?? false,
      canManageRecurrence: permissionFallback
          ? true
          : rawPermissions['canManageRecurrence'] as bool? ?? false,
      recurringSeriesId: json['recurringSeriesId'] as String?,
      items: [
        for (final i in json['items'] as List? ?? const [])
          if (i is Map<String, dynamic>) ExpenseItem.fromJson(i),
      ],
      itemizedRemainder: switch (json['itemizedRemainder']) {
        final Map<String, dynamic> remainder => ExpenseItemizedRemainder.fromJson(remainder),
        _ => null,
      },
      notes: json['notes'] as String? ?? '',
      date: DeviceTimeZone.dateInZone(
        _asDateTime(json['expenseDate']),
        json['expenseTimeZone'] as String?,
      ),
      isSettlement: categoryId == cloudSettlementCategoryId ||
          json['isReimbursement'] == true,
      recurrenceRule: recurrenceRule,
      originalAmountCents: (json['originalAmount'] as num?)?.round(),
      originalCurrency: json['originalCurrency'] as String?,
      conversionRate:
          json['conversionRate'] == null ? null : _asDouble(json['conversionRate']),
      createdAt: json['createdAt'] == null
          ? null
          : _asDateTime(json['createdAt']),
      documentCount: full
          ? documents.length
          : _asInt(json['documentCount'] ?? 0),
      documents: documents,
      detailsFetchedAt: full ? DateTime.now() : null,
    );
  }

  static List<ExpenseShare> _shares(dynamic value) {
    if (value is! List) return const [];
    final shares = <ExpenseShare>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final ref = raw['ledgerParticipant'] ??
          raw['participant'] ??
          raw['ledgerParticipantId'] ??
          raw['participantId'];
      final id = ref is Map ? ref['id'] : ref;
      if (id == null) continue;
      shares.add(ExpenseShare(
        participantId: _asId(id),
        shares: _asInt(raw['shares'] ?? 0),
      ));
    }
    return shares;
  }

  Future<List<Category>> fetchCategories() async => cloudCategories;

  Future<ActivityPage> fetchActivities({
    required String groupId,
    int cursor = 0,
    int limit = 20,
  }) async {
    final data = await _query(
      'groups.activities.list',
      {'groupId': groupId, 'cursor': cursor, 'limit': limit},
    );
    if (data is! Map<String, dynamic>) {
      throw SpliitResponseFormatException(
          'groups.activities.list: expected an object');
    }
    final activities = [
      for (final raw in data['activities'] as List? ?? const [])
        _activityFromJson(raw as Map<String, dynamic>),
    ];
    return ActivityPage(
      activities: activities,
      hasMore: data['hasMore'] == true,
      nextCursor: _asInt(data['nextCursor'] ?? cursor + limit),
    );
  }

  Activity _activityFromJson(Map<String, dynamic> json) {
    final type = (json['type'] ?? json['activityType']) as String? ?? '';
    final subjectType = json['subjectType'] as String?;
    final subjectId = json['subjectId'] as String?;
    final expense = json['expense'] as Map<String, dynamic>?;
    final data = json['data'];
    return Activity(
      id: _asId(json['id']),
      time: _asDateTime(json['time']),
      activityType: ActivityType.fromCloud(type),
      participantId: (json['actorId'] ?? json['participantId']) as String?,
      actorName: json['actorName'] as String?,
      expenseId: subjectType == 'EXPENSE'
          ? subjectId
          : (json['expenseId'] as String? ?? expense?['id'] as String?),
      data: data is Map
          ? (data['summary'] as String? ?? jsonEncode(data))
          : data as String?,
      expenseExists: expense != null,
    );
  }

  // ---------------------------------------------------------------------
  // Groups, members, invitations
  // ---------------------------------------------------------------------

  Future<String> createGroup({
    required String name,
    String? information,
    required String currency,
    String? currencyCode,
    required List<String> participantNames,
  }) async {
    final names = participantNames.where((n) => n.trim().length >= 2).toList();
    final fallback = connection.account?.name ?? '';
    final data = await _mutate('groups.create', {
      'requestId': const Uuid().v4(),
      'groupFormValues': {
        'name': name,
        'information': information ?? '',
        'currency': currency,
        'currencyCode': currencyCode ?? '',
        'participants': [
          if (names.isNotEmpty)
            for (final n in names) {'name': n}
          else
            {'name': fallback.length >= 2 ? fallback : 'Me'},
        ],
      },
    });
    final groupId = data is Map<String, dynamic> ? data['groupId'] as String? : null;
    if (groupId == null) {
      throw SpliitResponseFormatException('groups.create: no groupId');
    }
    return groupId;
  }

  Future<void> updateGroup({
    required String groupId,
    required String name,
    String? information,
    required String currency,
    String? currencyCode,
    required List<Participant> participants,
  }) async {
    // Cloud manages membership through invitations, not group updates;
    // participants are still sent because the shared schema requires them
    // and validates their shape, but they no longer add or remove anyone.
    final names = [
      for (final p in participants)
        if (p.name.trim().length >= 2) {'id': p.id, 'name': p.name},
    ];
    await _mutate('groups.update', {
      'groupId': groupId,
      'groupFormValues': {
        'name': name,
        'information': information ?? '',
        'currency': currency,
        'currencyCode': currencyCode ?? '',
        'participants': names.isNotEmpty
            ? names
            : [
                {
                  'name': connection.account?.name ?? 'Me',
                }
              ],
      },
    });
  }

  Future<void> archiveGroup(String groupId, bool archived, {bool force = false}) async {
    await _mutate('groups.archive', {
      'groupId': groupId,
      'archived': archived,
      if (force) 'force': true,
    });
  }

  Future<void> deleteGroup(String groupId) async {
    await _mutate('groups.delete', {'groupId': groupId});
  }

  Future<LeavePreview> leavePreview(String groupId) async {
    final data = await _query('groups.leavePreview', {'groupId': groupId});
    return LeavePreview.fromJson(data is Map<String, dynamic> ? data : const {});
  }

  Future<void> leaveGroup(String groupId, {bool force = false}) async {
    await _mutate('groups.leave', {
      'groupId': groupId,
      if (force) 'force': true,
    });
  }

  Future<void> setGroupStarred(String groupId, bool starred) async {
    await _mutate('account.setPreference', {
      'groupId': groupId,
      'starred': starred,
    });
  }

  Future<void> setGroupHidden(String groupId, bool hidden) async {
    await _mutate('account.setPreference', {
      'groupId': groupId,
      'hidden': hidden,
    });
  }

  /// The group's budgets, as Cloud computes them (period, spend, trend).
  Future<List<CloudBudget>> fetchBudgets(String groupId) async {
    final data = await _query('groups.budgets.list', {
      'groupId': groupId,
      'includeArchived': true,
    });
    final budgets = data is Map<String, dynamic> ? data['budgets'] as List? : null;
    return [
      for (final raw in budgets ?? const [])
        if (raw is Map<String, dynamic>) CloudBudget.fromJson(raw),
    ];
  }

  Future<void> updateMemberRole({
    required String groupId,
    required String memberId,
    required String role,
  }) async {
    await _mutate('groups.members.updateRole', {
      'groupId': groupId,
      'memberId': memberId,
      'role': role,
    });
  }

  Future<void> removeMember({
    required String groupId,
    required String memberId,
    bool? settleBalances,
  }) async {
    await _mutate('groups.members.remove', {
      'groupId': groupId,
      'memberId': memberId,
      if (settleBalances != null) 'settleBalances': settleBalances,
    });
  }

  Future<List<GroupInvitation>> fetchInvitations(String groupId) async {
    final data = await _query('invitations.list', {'groupId': groupId});
    final invitations =
        data is Map<String, dynamic> ? data['invitations'] as List? : null;
    return [
      for (final raw in invitations ?? const [])
        GroupInvitation.fromJson(raw as Map<String, dynamic>),
    ];
  }

  /// Invitations addressed to this account (email or link) that it hasn't
  /// accepted yet.
  Future<List<AccountInvite>> fetchAccountInvitations() async {
    final data = await _query('invitations.listForAccount');
    final invitations =
        data is Map<String, dynamic> ? data['invitations'] as List? : null;
    return [
      for (final raw in invitations ?? const [])
        if (raw is Map<String, dynamic>) AccountInvite.fromJson(raw),
    ];
  }

  Future<String> acceptAccountInvitation(String invitationId) async {
    final data = await _mutate('invitations.accept', {
      'invitationId': invitationId,
    });
    final groupId =
        data is Map<String, dynamic> ? data['groupId'] as String? : null;
    if (groupId == null) {
      throw SpliitResponseFormatException('invitations.accept: no groupId');
    }
    return groupId;
  }

  Future<void> declineAccountInvitation(String invitationId) async {
    await _mutate('invitations.decline', {'invitationId': invitationId});
  }

  Future<CreatedInvite> createInviteLink(
    String groupId, {
    String? label,
    int? maxUses,
    Map<String, dynamic>? expiresIn,
  }) async {
    final data = await _mutate('invitations.createSharedLink', {
      'groupId': groupId,
      'requestId': const Uuid().v4(),
      if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
      if (maxUses != null) 'maxUses': maxUses,
      if (expiresIn != null) 'expiresIn': expiresIn,
    });
    return CreatedInvite.fromJson(data is Map<String, dynamic> ? data : const {});
  }

  Future<void> revokeInvitation(String invitationId,
      {bool? settleBalances}) async {
    await _mutate('invitations.revoke', {
      'invitationId': invitationId,
      if (settleBalances != null) 'settleBalances': settleBalances,
    });
  }

  /// The URL of an existing shared invitation. The raw token is only
  /// available through this endpoint, never in the invitation list.
  Future<String> invitationUrl({
    required String groupId,
    required String invitationId,
  }) async {
    final data = await _mutate('invitations.getLinkUrl', {
      'groupId': groupId,
      'invitationId': invitationId,
    });
    final url = data is Map<String, dynamic>
        ? data['inviteUrl'] as String?
        : null;
    if (url == null || url.isEmpty) {
      throw SpliitResponseFormatException(
          'invitations.getLinkUrl: no inviteUrl');
    }
    return url;
  }

  Future<InvitePreview?> previewInvite(String token) async {
    final data = await _query('invitations.previewLink', {'token': token});
    final preview = data is Map<String, dynamic> ? data['preview'] : null;
    return preview is Map<String, dynamic>
        ? InvitePreview.fromJson(preview)
        : null;
  }

  Future<String> acceptInvite(String token, {String? expectedGroupId}) async {
    final data = await _mutate('invitations.acceptLink', {
      'token': token,
      if (expectedGroupId != null) 'expectedGroupId': expectedGroupId,
    });
    final groupId = data is Map<String, dynamic> ? data['groupId'] as String? : null;
    if (groupId == null) {
      throw SpliitResponseFormatException('invitations.acceptLink: no groupId');
    }
    return groupId;
  }

  // ---------------------------------------------------------------------
  // Expenses
  // ---------------------------------------------------------------------

  Map<String, dynamic> _expensePayload({
    required String title,
    required int amountCents,
    required String paidBy,
    required List<ExpenseShare> paidFor,
    required SplitMode splitMode,
    required int category,
    required String notes,
    required DateTime date,
    required String timeZone,
    required bool isSettlement,
    required RecurrenceRule recurrenceRule,
    required List<ExpenseDocument> documents,
    List<ExpenseShare>? payers,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
    /// Line items, or null to leave the field out: a flat expense sends
    /// none, and Cloud keeps whatever an update doesn't mention.
    List<ExpenseItem>? items,
    /// How the leftover is shared, sent only while there is one (Cloud
    /// rejects null, and keeps the one it has when the field is left out).
    ExpenseItemizedRemainder? itemizedRemainder,
  }) {
    final categoryId =
        isSettlement ? cloudSettlementCategoryId : cloudCategoryIdForLocal(category);
    // Everyone who paid: Cloud records several, each for a part of the
    // amount, and flags the expense as having more than one. One payer --
    // the usual, and everything this app wrote before multi-payer --
    // pays it all.
    final payerList = payers == null || payers.isEmpty
        ? [ExpenseShare(participantId: paidBy, shares: amountCents)]
        : payers;
    return {
      'expenseDate': DeviceTimeZone.instantForDate(date, timeZone).toIso8601String(),
      'expenseTimeZone': timeZone,
      'title': title,
      'category': categoryId,
      'amount': amountCents,
      if (originalCurrency != null && originalCurrency.isNotEmpty)
        'conversion': {
          if (conversionRate != null) ...{
            'type': 'custom',
            'currency': originalCurrency,
            'rate': conversionRate,
          } else ...{
            'type': 'exchange',
            'currency': originalCurrency,
          },
        },
      'paidBySplitMode': 'BY_AMOUNT',
      'paidByList': [for (final p in payerList) p.toJson()],
      'paidFor': [for (final s in paidFor) s.toJson()],
      'isMultiPayer': payerList.length > 1,
      'splitMode': splitMode.wireValue,
      'documents': [for (final d in documents) d.toJson()],
      'notes': notes,
      'recurrenceRule': recurrenceRule.wireValue,
      if (recurrenceRule != RecurrenceRule.none)
        'recurrence': {
          'frequency': switch (recurrenceRule) {
            RecurrenceRule.daily => 'DAILY',
            RecurrenceRule.weekly => 'WEEKLY',
            RecurrenceRule.monthly => 'MONTHLY',
            RecurrenceRule.none => 'DAILY',
          },
          'interval': 1,
          'end': {'type': 'INDEFINITE'},
        },
      if (items case final items?) 'items': [for (final i in items) i.toJson()],
      if (itemizedRemainder case final remainder?) 'itemizedRemainder': remainder.toJson(),
    };
  }

  Future<String> createExpense({
    required String groupId,
    required String title,
    required int amountCents,
    required String paidBy,
    required List<ExpenseShare> paidFor,
    SplitMode splitMode = SplitMode.evenly,
    int category = 0,
    String notes = '',
    DateTime? date,
    bool isSettlement = false,
    RecurrenceRule recurrenceRule = RecurrenceRule.none,
    bool saveDefaultSplittingOptions = false,
    List<ExpenseShare>? payers,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
    String? participantId,
    List<ExpenseDocument> documents = const [],
    String? requestId,
    List<ExpenseItem>? items,
    ExpenseItemizedRemainder? itemizedRemainder,
  }) async {
    final timeZone = await DeviceTimeZone.name();
    final payload = _expensePayload(
      title: title,
      amountCents: amountCents,
      paidBy: paidBy,
      paidFor: paidFor,
      splitMode: splitMode,
      category: category,
      notes: notes,
      date: date ?? DateTime.now(),
      timeZone: timeZone,
      isSettlement: isSettlement,
      recurrenceRule: recurrenceRule,
      documents: documents,
      payers: payers,
      originalAmountCents: originalAmountCents,
      originalCurrency: originalCurrency,
      conversionRate: conversionRate,
      items: items,
      itemizedRemainder: itemizedRemainder,
    );
    final data = await _mutate('groups.expenses.create', {
      'groupId': groupId,
      'requestId': requestId ?? const Uuid().v4(),
      'expense': payload,
    });
    return data is Map<String, dynamic>
        ? (data['expenseId'] as String? ?? '')
        : '';
  }

  Future<String> updateExpense({
    required String groupId,
    required String expenseId,
    required String title,
    required int amountCents,
    required String paidBy,
    required List<ExpenseShare> paidFor,
    required List<ExpenseDocument> documents,
    SplitMode splitMode = SplitMode.evenly,
    int category = 0,
    String notes = '',
    DateTime? date,
    bool isSettlement = false,
    RecurrenceRule recurrenceRule = RecurrenceRule.none,
    bool saveDefaultSplittingOptions = false,
    List<ExpenseShare>? payers,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
    String? participantId,
    int? expectedVersion,
    /// The expense's items, as they should be after the edit: [] clears
    /// them, null leaves the field out of the request.
    List<ExpenseItem>? items,
    ExpenseItemizedRemainder? itemizedRemainder,
  }) async {
    final timeZone = await DeviceTimeZone.name();
    var version = expectedVersion;
    if (version == null) {
      final current =
          await fetchExpense(groupId: groupId, expenseId: expenseId);
      version = current.version;
    }
    final payload = _expensePayload(
      title: title,
      amountCents: amountCents,
      paidBy: paidBy,
      paidFor: paidFor,
      splitMode: splitMode,
      category: category,
      notes: notes,
      date: date ?? DateTime.now(),
      timeZone: timeZone,
      isSettlement: isSettlement,
      recurrenceRule: recurrenceRule,
      documents: documents,
      payers: payers,
      originalAmountCents: originalAmountCents,
      originalCurrency: originalCurrency,
      conversionRate: conversionRate,
      items: items,
      itemizedRemainder: itemizedRemainder,
    );
    final data = await _mutate('groups.expenses.update', {
      'groupId': groupId,
      'expenseId': expenseId,
      'expectedVersion': version,
      'expense': payload,
    });
    return data is Map<String, dynamic>
        ? (data['expenseId'] as String? ?? expenseId)
        : expenseId;
  }

  Future<void> deleteExpense({
    required String groupId,
    required String expenseId,
    String? participantId,
  }) async {
    await _mutate('groups.expenses.delete', {
      'groupId': groupId,
      'expenseId': expenseId,
    });
  }

  Future<List<ExpenseComment>> fetchComments({
    required String groupId,
    required String expenseId,
  }) async {
    final data = await _query('groups.expenses.comments.list',
        {'groupId': groupId, 'expenseId': expenseId});
    final comments =
        data is Map<String, dynamic> ? data['comments'] as List? : null;
    return [
      for (final raw in comments ?? const [])
        ExpenseComment.fromJson(raw as Map<String, dynamic>),
    ];
  }

  Future<ExpenseComment> addComment({
    required String groupId,
    required String expenseId,
    required String body,
  }) async {
    final data = await _mutate('groups.expenses.comments.create', {
      'groupId': groupId,
      'expenseId': expenseId,
      'requestId': const Uuid().v4(),
      'body': body,
    });
    final raw = data is Map<String, dynamic> ? data['comment'] : null;
    if (raw is! Map<String, dynamic>) {
      throw SpliitResponseFormatException('comments.create: no comment');
    }
    return ExpenseComment.fromJson(raw);
  }

  Future<void> deleteComment({
    required String groupId,
    required String expenseId,
    required String commentId,
  }) async {
    await _mutate('groups.expenses.comments.delete', {
      'groupId': groupId,
      'expenseId': expenseId,
      'commentId': commentId,
    });
  }

  // ---------------------------------------------------------------------
  // Receipts
  // ---------------------------------------------------------------------

  /// Step 1: ask Cloud to sign a direct-to-bucket PUT. Cloud needs the
  /// group's ledger id, not just the group id.
  Future<ReceiptUploadTarget> signReceiptUpload({
    String? ledgerId,
    String filename = 'receipt.jpg',
    String contentType = 'image/jpeg',
    int? fileSize,
  }) async {
    if (ledgerId == null || ledgerId.isEmpty) {
      // Compatibility for the old receipt tests (and an older server that
      // predates Cloud's ledger-bound presign). Cloud itself always goes
      // through the ledger branch below.
      final data = await _mutate('uploads.signReceiptUpload', {
        'filename': filename,
        'filetype': contentType,
        '_nextS3': {'strategy': 'presigned'},
      });
      if (data is! Map<String, dynamic>) {
        throw SpliitResponseFormatException(
            'uploads.signReceiptUpload: expected an object');
      }
      final key = data['key'] as String?;
      final url = data['url'] as String?;
      if (key == null || url == null) {
        throw SpliitResponseFormatException(
            'uploads.signReceiptUpload: missing key or url');
      }
      return ReceiptUploadTarget(
        putUrl: url,
        publicUrl: receiptPublicUrl(
          key: key,
          bucket: data['bucket'] as String? ?? '',
          region: data['region'] as String?,
          endpoint: data['endpoint'] as String?,
        ),
        contentType: contentType,
      );
    }
    final data = await _mutate('uploads.presign', {
      'ledgerId': ledgerId,
      'fileName': filename,
      'contentType': contentType,
      if (fileSize != null) 'fileSize': fileSize,
    });
    if (data is! Map<String, dynamic>) {
      throw SpliitResponseFormatException('uploads.presign: expected an object');
    }
    final uploadUrl = data['uploadUrl'] as String?;
    final fileUrl = data['fileUrl'] as String?;
    if (uploadUrl == null || fileUrl == null) {
      throw SpliitResponseFormatException(
          'uploads.presign: missing uploadUrl or fileUrl');
    }
    return ReceiptUploadTarget(
      putUrl: uploadUrl,
      publicUrl: fileUrl,
      contentType: contentType,
    );
  }

  Future<void> putReceipt(ReceiptUploadTarget target, List<int> bytes) async {
    final put = await _http
        .put(
          Uri.parse(target.putUrl),
          headers: {
            'content-type': target.contentType,
            'cache-control': 'max-age=630720000',
          },
          body: bytes,
        )
        .timeout(const Duration(minutes: 3));
    if (put.statusCode < 200 || put.statusCode >= 300) {
      throw ReceiptUploadException(put.statusCode);
    }
  }

  Future<String> uploadReceipt(
    List<int> bytes, {
    String? ledgerId,
    String filename = 'receipt.jpg',
    String contentType = 'image/jpeg',
  }) async {
    final target = await signReceiptUpload(
      ledgerId: ledgerId,
      filename: filename,
      contentType: contentType,
      fileSize: bytes.length,
    );
    await putReceipt(target, bytes);
    return target.publicUrl;
  }

  Future<bool> receiptExists(String url) async {
    final res =
        await _http.head(Uri.parse(url)).timeout(const Duration(seconds: 60));
    if (res.statusCode >= 200 && res.statusCode < 300) return true;
    if (res.statusCode == 403 || res.statusCode == 404) return false;
    throw ReceiptUploadException(res.statusCode);
  }

  /// Kept for callers that still build a public bucket URL from an S3
  /// signature. Cloud's `uploads.presign` returns `fileUrl` directly, so
  /// the app no longer needs this path, but older tests and imports do.
  static String receiptPublicUrl({
    required String key,
    required String bucket,
    String? region,
    String? endpoint,
  }) {
    if (endpoint != null && endpoint.isNotEmpty && endpoint != 'undefined') {
      var trimmed = endpoint;
      while (trimmed.endsWith('/')) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      return '$trimmed/$bucket/$key';
    }
    return 'https://$bucket.s3.${region ?? ''}.amazonaws.com/$key';
  }
}

/// A person the account shares at least one group with.
class CloudFriend {
  final String accountId;
  final String name;
  final String email;
  final int sharedGroupCount;
  final bool hasFriendLedger;
  final String friendLedgerStatus;

  const CloudFriend({
    required this.accountId,
    required this.name,
    this.email = '',
    this.sharedGroupCount = 0,
    this.hasFriendLedger = false,
    this.friendLedgerStatus = 'NONE',
  });

  factory CloudFriend.fromJson(Map<String, dynamic> json) => CloudFriend(
        accountId: _asId(json['accountId'] ?? ''),
        name: json['name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        sharedGroupCount: _asInt(json['sharedGroupCount'] ?? 0),
        hasFriendLedger: json['hasFriendLedger'] as bool? ?? false,
        friendLedgerStatus: json['friendLedgerStatus'] as String? ?? 'NONE',
      );
}

/// A group budget with Cloud's derived period summary.
class CloudBudget {
  final String id;
  final String name;
  final int amount;
  final String periodType;
  final bool archived;
  final int used;
  final int remaining;
  final double percentage;
  final String trendStatus;
  final String lifecycle;
  final int daysRemaining;
  final bool canEdit;
  final bool canDelete;

  const CloudBudget({
    required this.id,
    required this.name,
    required this.amount,
    this.periodType = 'MONTHLY',
    this.archived = false,
    this.used = 0,
    this.remaining = 0,
    this.percentage = 0,
    this.trendStatus = 'ON_TRACK',
    this.lifecycle = 'ACTIVE',
    this.daysRemaining = 0,
    this.canEdit = false,
    this.canDelete = false,
  });

  factory CloudBudget.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'] as Map<String, dynamic>? ?? const {};
    final permissions = json['permissions'] as Map<String, dynamic>? ?? const {};
    return CloudBudget(
      id: _asId(json['id']),
      name: json['name'] as String? ?? '',
      amount: _asInt(json['amount'] ?? 0),
      periodType: json['periodType'] as String? ?? 'MONTHLY',
      archived: json['archived'] as bool? ?? false,
      used: _asInt(summary['used'] ?? 0),
      remaining: _asInt(summary['remaining'] ?? 0),
      percentage: (summary['percentage'] as num?)?.toDouble() ?? 0,
      trendStatus: summary['trendStatus'] as String? ?? 'ON_TRACK',
      lifecycle: summary['lifecycle'] as String? ?? 'ACTIVE',
      daysRemaining: _asInt(summary['daysRemaining'] ?? 0),
      canEdit: permissions['canEdit'] as bool? ?? false,
      canDelete: permissions['canDelete'] as bool? ?? false,
    );
  }
}

/// One row of the cloud's group list, with this account's preference.
class CloudGroupSummary {  final Group group;
  final bool starred;
  final bool hidden;
  final DateTime? latestExpenseCreatedAt;

  const CloudGroupSummary({
    required this.group,
    this.starred = false,
    this.hidden = false,
    this.latestExpenseCreatedAt,
  });
}

class GroupInvitation {
  final String id;
  final String email;
  final String? temporaryName;
  final String role;
  final String status;
  final bool isShared;
  final DateTime? expiresAt;
  final int useCount;
  final int? maxUses;
  final String? label;
  final bool canRevoke;
  final bool canCopyLink;

  const GroupInvitation({
    required this.id,
    this.email = '',
    this.temporaryName,
    this.role = 'MEMBER',
    this.status = 'PENDING',
    this.isShared = false,
    this.expiresAt,
    this.useCount = 0,
    this.maxUses,
    this.label,
    this.canRevoke = false,
    this.canCopyLink = false,
  });

  factory GroupInvitation.fromJson(Map<String, dynamic> json) =>
      GroupInvitation(
        id: _asId(json['id']),
        email: json['email'] as String? ?? '',
        temporaryName: json['temporaryName'] as String?,
        role: json['role'] as String? ?? 'MEMBER',
        status: json['status'] as String? ?? 'PENDING',
        isShared: json['isShared'] as bool? ?? false,
        expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
        useCount: _asInt(json['useCount'] ?? 0),
        maxUses: (json['maxUses'] as num?)?.round(),
        label: json['label'] as String?,
        canRevoke: json['canRevoke'] as bool? ?? false,
        canCopyLink: json['canCopyLink'] as bool? ?? false,
      );
}

/// An invitation addressed to the signed-in account.
class AccountInvite {
  final String id;
  final String groupId;
  final String groupName;
  final String role;
  final String? inviterName;

  const AccountInvite({
    required this.id,
    required this.groupId,
    required this.groupName,
    this.role = 'MEMBER',
    this.inviterName,
  });

  factory AccountInvite.fromJson(Map<String, dynamic> json) {
    final group = json['group'] as Map<String, dynamic>? ?? const {};
    final inviter = json['invitedBy'] as Map<String, dynamic>?;
    return AccountInvite(
      id: _asId(json['id']),
      groupId: _asId(group['id'] ?? json['groupId'] ?? ''),
      groupName: group['name'] as String? ?? '',
      role: json['role'] as String? ?? 'MEMBER',
      inviterName: inviter?['name'] as String?,
    );
  }
}

class CreatedInvite {  final String invitationId;
  final String inviteUrl;
  final DateTime? expiresAt;
  final int? maxUses;
  final String? label;

  const CreatedInvite({
    required this.invitationId,
    required this.inviteUrl,
    this.expiresAt,
    this.maxUses,
    this.label,
  });

  factory CreatedInvite.fromJson(Map<String, dynamic> json) => CreatedInvite(
        invitationId: _asId(json['invitationId']),
        inviteUrl: json['inviteUrl'] as String? ?? '',
        expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
        maxUses: (json['maxUses'] as num?)?.round(),
        label: json['label'] as String?,
      );
}

class InvitePreview {
  final String groupId;
  final String groupName;
  final String? emoji;
  final String? color;
  final String inviterName;
  final String? temporaryName;
  final String role;
  final bool usable;
  final String? reason;
  final int memberCount;
  final bool isShared;

  const InvitePreview({
    required this.groupId,
    required this.groupName,
    this.emoji,
    this.color,
    this.inviterName = '',
    this.temporaryName,
    this.role = 'MEMBER',
    this.usable = true,
    this.reason,
    this.memberCount = 0,
    this.isShared = false,
  });

  factory InvitePreview.fromJson(Map<String, dynamic> json) {
    final group = json['group'] as Map<String, dynamic>? ?? const {};
    final inviter = json['inviter'] as Map<String, dynamic>? ?? const {};
    return InvitePreview(
      groupId: _asId(group['id'] ?? ''),
      groupName: group['name'] as String? ?? '',
      emoji: group['emoji'] as String?,
      color: group['color'] as String?,
      inviterName: inviter['name'] as String? ?? '',
      temporaryName: json['temporaryName'] as String?,
      role: json['role'] as String? ?? 'MEMBER',
      usable: json['usable'] as bool? ?? false,
      reason: json['reason'] as String?,
      memberCount: _asInt(json['memberCount'] ?? 0),
      isShared: json['isShared'] as bool? ?? false,
    );
  }
}

class LeavePreview {
  final String role;
  final bool isLastActiveMember;
  final bool isLastAdmin;
  final bool hasUnsettledBalance;
  final List<({String id, String name})> promotableMembers;

  const LeavePreview({
    this.role = 'MEMBER',
    this.isLastActiveMember = false,
    this.isLastAdmin = false,
    this.hasUnsettledBalance = false,
    this.promotableMembers = const [],
  });

  factory LeavePreview.fromJson(Map<String, dynamic> json) => LeavePreview(
        role: json['role'] as String? ?? 'MEMBER',
        isLastActiveMember: json['isLastActiveMember'] as bool? ?? false,
        isLastAdmin: json['isLastAdmin'] as bool? ?? false,
        hasUnsettledBalance: json['hasUnsettledBalance'] as bool? ?? false,
        promotableMembers: [
          for (final m in json['promotableMembers'] as List? ?? const [])
            if (m is Map<String, dynamic>)
              (id: _asId(m['id']), name: m['name'] as String? ?? ''),
        ],
      );
}

class ExpenseComment {
  final String id;
  final String body;
  final DateTime createdAt;
  final String authorName;
  final String? authorAccountId;
  final String? authorImage;
  final bool canDelete;

  const ExpenseComment({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.authorName,
    this.authorAccountId,
    this.authorImage,
    this.canDelete = false,
  });

  factory ExpenseComment.fromJson(Map<String, dynamic> json) {
    final author = json['author'] as Map<String, dynamic>? ?? const {};
    return ExpenseComment(
      id: _asId(json['id']),
      body: json['body'] as String? ?? '',
      createdAt: _asDateTime(json['createdAt']),
      authorName: author['name'] as String? ?? '',
      authorAccountId: author['accountId'] as String?,
      authorImage: author['image'] as String?,
      canDelete: json['canDelete'] as bool? ?? false,
    );
  }
}

class ActivityPage {
  final List<Activity> activities;
  final bool hasMore;
  final int nextCursor;

  const ActivityPage({
    required this.activities,
    required this.hasMore,
    required this.nextCursor,
  });
}

class GroupNotFoundException implements UserError {
  final String serverUrl;
  final String groupId;
  GroupNotFoundException(this.serverUrl, this.groupId);

  @override
  String toString() =>
      'GroupNotFoundException: no group "$groupId" on $serverUrl';
}

class ReceiptUploadTarget {
  final String putUrl;
  final String publicUrl;
  final String contentType;
  const ReceiptUploadTarget({
    required this.putUrl,
    required this.publicUrl,
    required this.contentType,
  });
}

class ReceiptUploadException implements Exception {
  final int statusCode;
  ReceiptUploadException(this.statusCode);

  @override
  String toString() =>
      'ReceiptUploadException: the bucket answered HTTP $statusCode';
}

/// A sign-in/recovery failure with a message safe to show as guidance.
class CloudAuthException implements UserError {
  final String message;
  final String? code;
  final int? statusCode;

  CloudAuthException(this.message, {this.code, this.statusCode});

  @override
  String toString() => 'CloudAuthException(${code ?? statusCode}): $message';
}

class SpliitApiException implements Exception {
  final int statusCode;
  final String body;
  final String? code;
  final String? message;

  SpliitApiException(this.statusCode, this.body, {this.code, this.message});

  bool get isNotFound =>
      statusCode == 404 || code == 'NOT_FOUND' || body.contains('NOT_FOUND');
  bool get isUnauthorized =>
      statusCode == 401 || code == 'UNAUTHORIZED';
  bool get isForbidden => statusCode == 403 || code == 'FORBIDDEN';
  bool get isConflict => statusCode == 409 || code == 'CONFLICT';
  bool get isPreconditionFailed =>
      statusCode == 412 || code == 'PRECONDITION_FAILED';

  String get userMessage =>
      message ??
      (isUnauthorized
          ? 'Sign in to continue.'
          : isForbidden
              ? 'You do not have permission to do that.'
              : 'The server could not complete that request.');

  @override
  String toString() =>
      'SpliitApiException($statusCode${code == null ? '' : ', $code'}): '
      '${message ?? body}';
}
