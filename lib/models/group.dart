import 'currency.dart';

/// A group as Spliit Cloud returns it: account-bound, with its member
/// roster, appearance, and the caller's own role. The app's screens keep
/// using this single DTO whether it came from the network or the local
/// cache, exactly as they did before the port.
class Group {
  final String id;
  final String name;

  /// Server creation timestamp; unknown for older cached groups.
  final DateTime? createdAt;

  /// Free-text notes about the group -- the web app calls this field
  /// "Group information" (its Android/iOS counterparts call it "Notes").
  /// Null/empty when unset.
  final String? information;

  /// The currency *symbol* used to display amounts (e.g. '\$', '€') --
  /// always set. This is what expense amounts are rendered with;
  /// [currencyCode] backs the currency picker and exchange-rate lookups.
  final String currency;

  /// The ISO-4217 code backing [currency] (e.g. 'USD'), or null/empty
  /// when the group uses a free-typed custom currency symbol with no
  /// real code behind it.
  final String? currencyCode;

  /// Every ledger participant, including unlinked imported names and
  /// pending invitees. These are the ids expenses are recorded against.
  final List<Participant> participants;

  /// Cloud group-level archive: every member sees the group as read-only.
  final bool archived;

  /// Group appearance from Spliit Cloud. Null = not chosen, '' = none,
  /// otherwise a single emoji / `#rrggbb` color.
  final String? emoji;
  final String? color;

  final String? ledgerId;

  /// `GROUP` for a regular group, `FRIEND` for a two-person friend ledger.
  final String groupType;

  /// The signed-in account's role in this group (`ADMIN` or `MEMBER`),
  /// or null when it isn't known (a stale cache, or a public link).
  final String? role;

  /// The ledger participant that represents the signed-in account. Cloud
  /// gives this directly, so the app no longer has to guess "who are you".
  final String? currentParticipantId;

  /// The account-backed members, with their member ids and roles. Empty
  /// for cached group-list rows that only carry account summaries.
  final List<GroupMember> members;

  /// How many active members the group has, from the cloud group list.
  /// [participants] can include pending/unlinked names, so this is the
  /// number to show in the list.
  final int memberCount;

  const Group({
    required this.id,
    required this.name,
    this.createdAt,
    this.information,
    required this.currency,
    this.currencyCode,
    required this.participants,
    this.archived = false,
    this.emoji,
    this.color,
    this.ledgerId,
    this.groupType = 'GROUP',
    this.role,
    this.currentParticipantId,
    this.members = const [],
    this.memberCount = 0,
  });

  bool get isFriendLedger => groupType == 'FRIEND';
  bool get isAdmin => role == 'ADMIN';
  bool get canManage => isAdmin && !archived;

  int get decimalDigits => currencyByCode(currencyCode).decimalDigits;

  Group copyWith({
    String? name,
    String? information,
    String? currency,
    String? currencyCode,
    List<Participant>? participants,
    bool? archived,
    String? emoji,
    String? color,
    String? role,
    String? currentParticipantId,
    List<GroupMember>? members,
    int? memberCount,
  }) =>
      Group(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        information: information ?? this.information,
        currency: currency ?? this.currency,
        currencyCode: currencyCode ?? this.currencyCode,
        participants: participants ?? this.participants,
        archived: archived ?? this.archived,
        emoji: emoji ?? this.emoji,
        color: color ?? this.color,
        ledgerId: ledgerId,
        groupType: groupType,
        role: role ?? this.role,
        currentParticipantId: currentParticipantId ?? this.currentParticipantId,
        members: members ?? this.members,
        memberCount: memberCount ?? this.memberCount,
      );
}

/// One account-backed member of a cloud group. [id] is the membership id
/// used by `groups.members.*`; [participantId] is the ledger participant
/// the same person is recorded as in expenses.
class GroupMember {
  final String id;
  final String accountId;
  final String name;
  final String? email;
  final String? image;
  final String role;
  final String status;
  final String? participantId;

  const GroupMember({
    required this.id,
    required this.accountId,
    required this.name,
    this.email,
    this.image,
    this.role = 'MEMBER',
    this.status = 'ACTIVE',
    this.participantId,
  });

  bool get isAdmin => role == 'ADMIN';
  bool get isActive => status == 'ACTIVE';

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'name': name,
        if (email != null) 'email': email,
        if (image != null) 'image': image,
        'role': role,
        'status': status,
        if (participantId != null) 'participantId': participantId,
      };

  factory GroupMember.fromJson(Map<String, dynamic> json) => GroupMember(
        id: json['id'] as String,
        accountId: json['accountId'] as String? ?? json['account_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        email: json['email'] as String?,
        image: json['image'] as String?,
        role: json['role'] as String? ?? 'MEMBER',
        status: json['status'] as String? ?? 'ACTIVE',
        participantId: json['participantId'] as String? ?? json['ledgerParticipantId'] as String?,
      );
}

/// [participants] by name, then id: the order every screen lists them in,
/// set as a group is fetched and as it's read from the cache.
List<Participant> participantsByName(Iterable<Participant> participants) => [...participants]
  ..sort((a, b) {
    final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name != 0 ? name : a.id.compareTo(b.id);
  });

class Participant {
  final String id;
  final String name;

  /// The account behind this participant, when it is an account-backed
  /// group member rather than an imported name or a pending invite.
  final String? accountId;

  /// A pending invitation's placeholder participant.
  final bool pending;

  /// A name-only participant from an import, with no account.
  final bool unlinked;

  const Participant({
    required this.id,
    required this.name,
    this.accountId,
    this.pending = false,
    this.unlinked = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (accountId != null) 'accountId': accountId,
        if (pending) 'pending': true,
        if (unlinked) 'unlinked': true,
      };

  factory Participant.fromJson(Map<String, dynamic> json) => Participant(
        id: json['id'] as String,
        name: json['name'] as String,
        accountId: json['accountId'] as String?,
        pending: json['pending'] as bool? ?? false,
        unlinked: json['unlinked'] as bool? ?? false,
      );
}
