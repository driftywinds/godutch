import 'dart:convert';

import 'package:flutter/foundation.dart';

/// What a notification is about, one Android channel each: the system's own
/// notification settings list them by those names, so each can be silenced
/// on its own.
enum NotificationCategory {
  expenses('expenses'),
  comments('comments'),
  settlements('settlements'),
  members('members');

  const NotificationCategory(this.id);

  /// The Android channel's id. Never change one: a channel is permanent once
  /// a phone has seen it.
  final String id;
}

/// One notification to post: the group's name in bold, what happened under
/// it.
@immutable
class NotificationMessage {
  const NotificationMessage({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    this.groupId,
    this.expenseId,
  });

  /// The shade's id: the same id replaces its notification instead of
  /// stacking another.
  final int id;

  final NotificationCategory category;

  /// The group's name.
  final String title;

  /// What happened, in a sentence.
  final String body;

  /// Where a tap goes; null for a notification that opens nothing (the test
  /// one).
  final String? groupId;
  final String? expenseId;

  String get payload => jsonEncode({
        if (groupId != null) 'groupId': groupId,
        if (expenseId != null) 'expenseId': expenseId,
      });
}

/// Where a poll's notifications go: the phone's shade, or a list in a test.
abstract class NotificationSink {
  Future<void> show(NotificationMessage message);
}

/// What a tapped notification asks the app to open.
@immutable
class NotificationTarget {
  const NotificationTarget({required this.groupId, this.expenseId});

  final String groupId;
  final String? expenseId;

  /// Reads a [NotificationMessage.payload] back; null for anything else.
  static NotificationTarget? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final json = jsonDecode(payload);
      if (json is! Map) return null;
      final groupId = json['groupId'];
      if (groupId is! String || groupId.isEmpty) return null;
      final expenseId = json['expenseId'];
      return NotificationTarget(
        groupId: groupId,
        expenseId: expenseId is String && expenseId.isNotEmpty ? expenseId : null,
      );
    } on FormatException {
      return null;
    }
  }
}
