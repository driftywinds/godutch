import 'dart:math';

/// Our own DTO for an expense, decoupled from Spliit's tRPC/Prisma shape.
///
/// [SpliitClient] is responsible for mapping the raw tRPC response into
/// this type. Field set and semantics are verified against a working
/// Python client (see the splitwise2spliit project) that's already
/// exercised this API end-to-end for CSV import -- not guessed.
enum SplitMode { evenly, byShares, byPercentage, byAmount }

extension SplitModeWire on SplitMode {
  String get wireValue => switch (this) {
        SplitMode.evenly => 'EVENLY',
        SplitMode.byShares => 'BY_SHARES',
        SplitMode.byPercentage => 'BY_PERCENTAGE',
        SplitMode.byAmount => 'BY_AMOUNT',
      };

  /// [Expense.splitMode] is what the split's shares mean, not every Cloud
  /// value: `ITEMIZED` stores its shares as exact amounts, like
  /// [SplitMode.byAmount], so that's what it maps to. The raw value is kept
  /// separately ([Expense.splitModeTag]) because Cloud, and the web app,
  /// tell an itemized expense from a flat one by it.
  static SplitMode fromWire(String value) => switch (value) {
        'BY_SHARES' => SplitMode.byShares,
        'BY_PERCENTAGE' => SplitMode.byPercentage,
        'BY_AMOUNT' || 'ITEMIZED' => SplitMode.byAmount,
        _ => SplitMode.evenly,
      };
}

/// How often this expense recurs, mirrored from Spliit's `RecurrenceRule`
/// Prisma enum -- no special client-side logic beyond passing the value
/// through, the server owns the actual recurrence scheduling.
enum RecurrenceRule { none, daily, weekly, monthly }

extension RecurrenceRuleWire on RecurrenceRule {
  String get wireValue => switch (this) {
        RecurrenceRule.none => 'NONE',
        RecurrenceRule.daily => 'DAILY',
        RecurrenceRule.weekly => 'WEEKLY',
        RecurrenceRule.monthly => 'MONTHLY',
      };

  static RecurrenceRule fromWire(String value) => switch (value) {
        'DAILY' => RecurrenceRule.daily,
        'WEEKLY' => RecurrenceRule.weekly,
        'MONTHLY' => RecurrenceRule.monthly,
        _ => RecurrenceRule.none,
      };
}

/// Reads a participant reference that the server sends as a bare id
/// string when *we* write it, but appears to send back as an expanded
/// `{id, name, ...}` object on read endpoints (presumably so the webapp
/// doesn't need a separate lookup to show names). Handles either shape
/// rather than assuming one, since this is exactly the kind of upstream
/// detail we deliberately don't want this client tightly bound to.
///
/// Also tolerates the id itself (bare, or nested in the object) coming
/// back as a number rather than a string -- see
/// github.com/sharneng/spliit2go/issues/14, where a bare `as String`
/// cast on a server-sent id threw and crashed the whole group screen.
String extractParticipantId(dynamic value) {
  if (value is Map) return _idToString(value['id']);
  return _idToString(value);
}

String _idToString(dynamic id) => id is String ? id : id.toString();

/// Same leniency for category, in case it's ever returned as an expanded
/// `{id, name}` object rather than a bare id the way fetchCategories'
/// categories.list response and the create-expense payload use.
int extractCategoryId(dynamic value) {
  if (value is Map) return (value['id'] as num).round();
  return (value as num).round();
}

/// One participant's share of an expense. For [SplitMode.evenly], [shares]
/// is just a nonzero weight (1 per person is the common case); for
/// [SplitMode.byAmount] it's the exact cents they owe.
class ExpenseShare {
  final String participantId;
  final int shares;
  const ExpenseShare({required this.participantId, required this.shares});

  Map<String, dynamic> toJson() => {'participant': participantId, 'shares': shares};

  /// Tolerates the shapes this server sends for who a share belongs to,
  /// because it doesn't send one consistent shape (issue #35): `groups.
  /// expenses.list` (fetchExpenses) selects a nested `participant: {id,
  /// name}` object; the create/update form payload (and this class's own
  /// [toJson]) uses a bare `participant` id string; `groups.expenses.get`
  /// (fetchExpense, singular -- the one edit mode uses) does a plain Prisma
  /// `include: { paidFor: true }` with no field selection, which returns
  /// the *raw join-table row* instead: `{participantId: "...", shares: n}`,
  /// no `participant` key at all (confirmed against spliit-web's
  /// src/lib/api.ts `getExpense`/`getGroupExpenses`); and Cloud's own
  /// writes and reads use `ledgerParticipantId` (or a `ledgerParticipant`
  /// object), which is what a line item's shares and the remainder's come
  /// back as. Before this fix, parsing that third shape via
  /// [extractParticipantId]`(json['participant'])` fed `null` in and got
  /// back the *string* `"null"` (`null.toString()` doesn't throw) -- which
  /// then matched no real participant, so every "Paid for" checkbox in edit
  /// mode came up unchecked regardless of the expense's actual split.
  factory ExpenseShare.fromJson(Map<String, dynamic> json) => ExpenseShare(
        participantId: extractParticipantId(json['participant'] ??
            json['participantId'] ??
            json['ledgerParticipant'] ??
            json['ledgerParticipantId']),
        shares: (json['shares'] as num).round(),
      );
}

/// A document (a receipt photo) attached to an expense on the server:
/// Spliit's `ExpenseDocument`. The app doesn't show or add these yet (#123),
/// but an update must send back every one the expense has, unchanged:
/// Spliit's update deletes each existing document whose [id] isn't in
/// the list it's sent (#128).
class ExpenseDocument {
  final String id;
  final String url;
  final int width;
  final int height;
  const ExpenseDocument(
      {required this.id, required this.url, required this.width, required this.height});

  /// Strict, unlike the lenient parsing above: a document this can't read
  /// fails the edit (an unexpected error, #119) rather than being dropped,
  /// since dropping it would delete it on the next save.
  factory ExpenseDocument.fromJson(Map<String, dynamic> json) => ExpenseDocument(
        id: json['id'] as String,
        url: json['url'] as String,
        width: (json['width'] as num).round(),
        height: (json['height'] as num).round(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'url': url, 'width': width, 'height': height};

  static const _idAlphabet = '-_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// A new document id, as the web app and spliit-ios make them: 21
  /// random characters from a 64-letter alphabet (#123). The server keeps
  /// it on update; create replaces it (#124).
  static String newId([Random? random]) {
    final r = random ?? Random.secure();
    return String.fromCharCodes(
        List.generate(21, (_) => _idAlphabet.codeUnitAt(r.nextInt(_idAlphabet.length))));
  }
}

class Expense {
  final String id;
  final String groupId;
  final String title;
  /// Amount in the group's smallest currency unit -- cents, or whole yen
  /// for a currency with no decimals ([Group.decimalDigits], #251) --
  /// matching how Spliit itself stores amounts; avoids floating point
  /// drift. "Cents" in names across the app means this unit.
  final int amountCents;
  final String paidBy;
  final List<ExpenseShare> paidFor;
  final SplitMode splitMode;

  /// The split mode exactly as Cloud stores it (`EVENLY`, `ITEMIZED`, …),
  /// or '' for a locally-built expense, where [splitMode]'s own wire value
  /// is what's written. [splitMode] can't carry `ITEMIZED` because its
  /// shares are exact amounts, which is what the enum's `byAmount` means;
  /// keeping the tag lets an itemized expense round-trip through an edit as
  /// itemized, and lets the UI show it as one.
  final String splitModeTag;

  /// The same for who paid: Cloud's `paidBySplitMode`.
  final String paidBySplitModeTag;

  /// Cloud's `ITEMIZED`: the split is the expense's lines and their
  /// leftover. Its stored [paidFor] is the amounts those work out to, in
  /// the expense's own currency.
  bool get isItemized => splitModeTag == 'ITEMIZED';

  /// [splitMode] as Cloud's wire value, unless a raw tag was read.
  String get splitModeWireValue =>
      splitModeTag.isEmpty ? splitMode.wireValue : splitModeTag;

  /// [paidBySplitMode] as Cloud's wire value, unless a raw tag was read.
  String get paidBySplitModeWireValue =>
      paidBySplitModeTag.isEmpty ? paidBySplitMode.wireValue : paidBySplitModeTag;

  /// Spliit Cloud's category id (`general`, `groceries`, `settlement`, …).
  /// The legacy [category] int below is kept as the app's local, stable
  /// id for icons, localized names and the picker.
  final String categoryId;

  /// Spliit Cloud can record several payers. The first payer is also kept
  /// in [paidBy] so every single-payer code path (and older cached rows)
  /// keeps working; [paidByList] is authoritative when non-empty.
  final List<ExpenseShare> paidByList;
  final SplitMode paidBySplitMode;
  final bool isMultiPayer;

  /// Cloud's optimistic-concurrency version, required by updates.
  final int version;

  /// What the signed-in account may do, as the cloud reports it.
  final bool canEdit;
  final bool canDelete;
  final bool canManageRecurrence;

  /// Set when this expense belongs to a durable recurring series.
  final String? recurringSeriesId;

  /// Line items, as cloud returns them (empty for a flat expense).
  final List<ExpenseItem> items;

  /// How the money left over after the items is shared, for an itemized
  /// expense. Null for a flat one, and for one whose items add up to its
  /// amount.
  final ExpenseItemizedRemainder? itemizedRemainder;

  final int category;
  final String notes;
  final DateTime date;
  final bool isSettlement;
  final RecurrenceRule recurrenceRule;

  /// Set together to record that this expense was entered in a currency
  /// other than the group's ("Paid in" on the webapp/iOS). [amountCents]
  /// above is always in the *group's* currency -- these three describe
  /// the original entry, mirroring Spliit's own `Expense.originalCurrency`
  /// / `originalAmount` columns. `conversionRate` follows Spliit's
  /// convention in major units: `amount = originalAmount * conversionRate`
  /// (see src/lib/currency-conversion.ts upstream). [originalAmountCents]
  /// is in the *original* currency's smallest unit (#251), so ¥1,000 in a
  /// euro group is 1000 -- see `convertToGroupAmount`. All null together
  /// when the expense was simply entered in the group's own currency.
  final int? originalAmountCents;
  final String? originalCurrency;
  final double? conversionRate;

  /// True if this expense was created locally while offline and hasn't
  /// been confirmed by the server yet. Never true for anything read back
  /// from the API.
  final bool pending;

  /// True once the outbox has given up retrying this pending expense
  /// automatically (issue #44) -- a 4xx rejection from the server, or
  /// too many failed attempts. Still [pending] (it hasn't synced), but
  /// no longer retried on every flush; the UI surfaces this with a
  /// retry/delete affordance instead of the ordinary "syncing…" badge.
  /// Never true for anything read back from the API.
  final bool syncFailed;

  /// The most recent sync failure's message, or null if this expense
  /// has never failed to sync (including every expense read back from
  /// the API, which was never queued in the first place).
  final String? lastError;

  /// When the expense was created: the server's timestamp, or this
  /// device's clock for one added offline and not yet refreshed. Orders
  /// same-day expenses newest-created first, as Spliit's own list does
  /// (issue #88). Null only for rows cached before it was stored.
  final DateTime? createdAt;

  /// The documents attached on the server, as [fetchExpense] read them.
  /// Only that fresh fetch fills this in; the expense list doesn't return
  /// them (#128), and the cache keeps them separately (#123).
  final List<ExpenseDocument> documents;

  /// How many documents the expense has on the server. The expense list
  /// returns only this count (`_count.documents`), not the documents
  /// themselves, so it's what the cache knows before an expense has been
  /// opened online (#123).
  final int documentCount;

  /// When this device last read the expense in full
  /// ([SpliitClient.fetchExpense]), which is the only way to know its
  /// [notes] and [conversionRate]: the expense list sends neither (#237).
  /// Null while they aren't known, which is how a refresh leaves a synced
  /// row, except in a favorite group (AppDatabase.keepsExpenseDetails).
  /// Never set on anything read from the API.
  final DateTime? detailsFetchedAt;

  const Expense({
    required this.id,
    required this.groupId,
    required this.title,
    required this.amountCents,
    required this.paidBy,
    required this.paidFor,
    this.splitMode = SplitMode.evenly,
    this.splitModeTag = '',
    this.paidBySplitModeTag = '',
    this.categoryId = 'general',
    this.paidByList = const [],
    this.paidBySplitMode = SplitMode.byAmount,
    this.isMultiPayer = false,
    this.version = 1,
    this.canEdit = true,
    this.canDelete = true,
    this.canManageRecurrence = true,
    this.recurringSeriesId,
    this.items = const [],
    this.itemizedRemainder,
    this.category = 0,
    this.notes = '',
    required this.date,
    this.isSettlement = false,
    this.recurrenceRule = RecurrenceRule.none,
    this.originalAmountCents,
    this.originalCurrency,
    this.conversionRate,
    this.pending = false,
    this.syncFailed = false,
    this.lastError,
    this.createdAt,
    this.documents = const [],
    this.documentCount = 0,
    this.detailsFetchedAt,
  });

  /// Every payer, falling back to the single [paidBy] for expenses cached
  /// before multi-payer support (and locally created pending rows).
  List<ExpenseShare> get payers => paidByList.isNotEmpty
      ? paidByList
      : [ExpenseShare(participantId: paidBy, shares: amountCents)];

  Expense copyWith({
    String? title,
    int? amountCents,
    String? paidBy,
    List<ExpenseShare>? paidFor,
    SplitMode? splitMode,
    String? splitModeTag,
    String? paidBySplitModeTag,
    String? categoryId,
    List<ExpenseShare>? paidByList,
    SplitMode? paidBySplitMode,
    bool? isMultiPayer,
    int? version,
    bool? canEdit,
    bool? canDelete,
    bool? canManageRecurrence,
    String? recurringSeriesId,
    List<ExpenseItem>? items,
    ExpenseItemizedRemainder? itemizedRemainder,
    int? category,
    String? notes,
    DateTime? date,
    bool? isSettlement,
    RecurrenceRule? recurrenceRule,
    int? originalAmountCents,
    String? originalCurrency,
    double? conversionRate,
    bool? pending,
    bool? syncFailed,
    String? lastError,
    DateTime? createdAt,
    List<ExpenseDocument>? documents,
    int? documentCount,
    DateTime? detailsFetchedAt,
  }) =>
      Expense(
        id: id,
        groupId: groupId,
        title: title ?? this.title,
        amountCents: amountCents ?? this.amountCents,
        paidBy: paidBy ?? this.paidBy,
        paidFor: paidFor ?? this.paidFor,
        splitMode: splitMode ?? this.splitMode,
        splitModeTag: splitModeTag ?? this.splitModeTag,
        paidBySplitModeTag: paidBySplitModeTag ?? this.paidBySplitModeTag,
        categoryId: categoryId ?? this.categoryId,
        paidByList: paidByList ?? this.paidByList,
        paidBySplitMode: paidBySplitMode ?? this.paidBySplitMode,
        isMultiPayer: isMultiPayer ?? this.isMultiPayer,
        version: version ?? this.version,
        canEdit: canEdit ?? this.canEdit,
        canDelete: canDelete ?? this.canDelete,
        canManageRecurrence: canManageRecurrence ?? this.canManageRecurrence,
        recurringSeriesId: recurringSeriesId ?? this.recurringSeriesId,
        items: items ?? this.items,
        itemizedRemainder: itemizedRemainder ?? this.itemizedRemainder,
        category: category ?? this.category,
        notes: notes ?? this.notes,
        date: date ?? this.date,
        isSettlement: isSettlement ?? this.isSettlement,
        recurrenceRule: recurrenceRule ?? this.recurrenceRule,
        originalAmountCents: originalAmountCents ?? this.originalAmountCents,
        originalCurrency: originalCurrency ?? this.originalCurrency,
        conversionRate: conversionRate ?? this.conversionRate,
        pending: pending ?? this.pending,
        syncFailed: syncFailed ?? this.syncFailed,
        lastError: lastError ?? this.lastError,
        createdAt: createdAt ?? this.createdAt,
        documents: documents ?? this.documents,
        documentCount: documentCount ?? this.documentCount,
        detailsFetchedAt: detailsFetchedAt ?? this.detailsFetchedAt,
      );
}

/// One line item of a cloud itemized expense.
class ExpenseItem {
  final String id;
  final String title;
  final int amountCents;
  final int unitPriceCents;
  final int quantityMilli;
  final SplitMode splitMode;
  final List<ExpenseShare> paidFor;
  final String? notes;

  const ExpenseItem({
    required this.id,
    required this.title,
    required this.amountCents,
    this.unitPriceCents = 0,
    this.quantityMilli = 1000,
    this.splitMode = SplitMode.evenly,
    this.paidFor = const [],
    this.notes,
  });

  factory ExpenseItem.fromJson(Map<String, dynamic> json) => ExpenseItem(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        amountCents: (json['amount'] as num?)?.round() ?? 0,
        unitPriceCents: (json['unitPrice'] as num?)?.round() ?? 0,
        quantityMilli: (json['quantity'] as num?)?.round() ?? 1000,
        splitMode: SplitModeWire.fromWire(json['splitMode'] as String? ?? 'EVENLY'),
        paidFor: [
          for (final p in (json['paidFor'] as List? ?? const []))
            ExpenseShare.fromJson(p as Map<String, dynamic>),
        ],
        notes: json['notes'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        'title': title,
        'unitPrice': unitPriceCents,
        'quantity': quantityMilli,
        'amount': amountCents,
        'splitMode': splitMode.wireValue,
        'paidFor': [for (final p in paidFor) p.toJson()],
        if (notes != null) 'notes': notes,
      };
}

/// How an itemized expense's leftover — its amount less its items' — is
/// shared. Cloud stores this object rather than the leftover's amount,
/// which is worked out from the two, and adds [allocationMode] itself
/// ("CUSTOM" when the client allocated the leftover).
///
/// Cloud rejects the field as null, and leaving it out of an update keeps
/// the one already stored, so the app only sends it while there is a
/// leftover to share.
class ExpenseItemizedRemainder {
  final SplitMode splitMode;

  /// Cloud's own tag for how the leftover is allocated; kept as read, and
  /// omitted until the server has given it one.
  final String? allocationMode;

  final List<ExpenseShare> paidFor;

  const ExpenseItemizedRemainder({
    this.splitMode = SplitMode.evenly,
    this.allocationMode,
    this.paidFor = const [],
  });

  factory ExpenseItemizedRemainder.fromJson(Map<String, dynamic> json) => ExpenseItemizedRemainder(
        splitMode: SplitModeWire.fromWire(json['splitMode'] as String? ?? 'EVENLY'),
        allocationMode: json['allocationMode'] as String?,
        paidFor: [
          for (final p in (json['paidFor'] as List? ?? const []))
            ExpenseShare.fromJson(p as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        'splitMode': splitMode.wireValue,
        if (allocationMode case final mode?) 'allocationMode': mode,
        'paidFor': [for (final p in paidFor) p.toJson()],
      };
}

