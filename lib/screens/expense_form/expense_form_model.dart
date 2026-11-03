import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController;

import '../../models/category.dart';
import '../../models/currency.dart';
import '../../models/default_split.dart';
import '../../models/expense.dart';
import '../../models/group.dart';
import '../../services/active_user.dart';
import '../../services/expense_shares.dart';
import '../../utils/decimal_input.dart';
import '../../utils/markdown_note.dart';
import '../../utils/money.dart';
import 'item_draft.dart';
import 'rate_field.dart';
import 'split_problem.dart';

export 'split_problem.dart';

/// What the add/edit expense form holds and works out (#258): what's
/// typed and picked, the amounts derived from it, the conversion, the
/// shares and their validation. The screen builds the widgets and saves;
/// the I/O is [RateLookup]'s and [ReceiptScanController]'s (#289). This
/// holds no [BuildContext] or focus, so it's tested without building
/// widgets.
///
/// The text fields' controllers live here, so the widgets bind to them;
/// any change to one, or to anything set through this, notifies. The
/// rate's field is an [ExchangeRateField] of its own.
class ExpenseFormModel extends ChangeNotifier {
  ExpenseFormModel({
    required this.group,
    this.existing,
    Expense? draft,
    this.activeUserId,
    String decimalSeparator = '.',
  }) : _decimalSeparator = decimalSeparator {
    rateField = ExchangeRateField(
      groupCode: group.currencyCode,
      paidIn: _paidIn,
      parse: parseDecimal,
      decimalSeparator: decimalSeparator,
      onChanged: notifyListeners,
    );
    if ((existing ?? draft) case final e?) {
      _prefillFrom(e);
    } else {
      paidBy = resolveDefaultPaidBy(activeUserId: activeUserId, participants: group.participants);
    }
    for (final c in [titleController, amountController, notesController, originalAmountController,
      rateField.controller, ...splitControllers.values, ...payerAmountControllers.values]) {
      c.addListener(_typed);
    }
    for (final c in [amountController, originalAmountController, rateField.controller]) {
      c.addListener(_amountsChanged);
    }
    rateField.controller.addListener(_refillBalance);
    // A settlement's To amounts make its amount (#262 review).
    for (final c in splitControllers.values) {
      c.addListener(() {
        if (_isSettlement) _convertedAmountInvalid = false;
      });
    }
    markUnchanged();
  }

  final Group group;

  /// The expense being edited, if any.
  final Expense? existing;

  /// Who's using the app in this group: a new expense's payer, and
  /// "(you)" in the form.
  final String? activeUserId;

  final titleController = TextEditingController();
  final amountController = TextEditingController();
  final notesController = TextEditingController();

  /// "Amount paid", in the paid-in currency (#252).
  final originalAmountController = TextEditingController();

  // Per-participant values for the non-evenly modes -- shares (any
  // positive number), percentage (0-100, must sum to 100), or amount
  // (must sum to the total). Empty or 0 is "not included" (#260): only
  // Evenly has checkboxes. Filled in by switching modes ([splitMode]),
  // [_prefillFrom] or [applyDefaultSplit].
  late final Map<String, TextEditingController> splitControllers = {
    for (final p in group.participants) p.id: TextEditingController(),
  };

  late final Map<String, bool> _included = {for (final p in group.participants) p.id: true};

  String? _paidBy;
  String? get paidBy => _paidBy;
  set paidBy(String? id) => _set(() {
        // Picking the same From again changes nothing: an older
        // settlement's own share stays (#281 review).
        if (id == _paidBy) return;
        // Whoever it was already paying stops, so no one pays twice and
        // the rows keep adding up to the total.
        _extraPayerIds.remove(id);
        _paidBy = id;
        _dropPayersFromTo();
        if (multiPayer) _sharePayersEvenly();
      });

  // ---------------------------------------------------------------------
  // Who paid.

  /// The payers after [paidBy]. Spliit Cloud records several people paying
  /// one expense, each for a part of it; the ordinary expense has one, who
  /// paid all of it.
  final List<String> _extraPayerIds = [];

  /// Everyone who paid, [paidBy] first and in the order the card lists
  /// them.
  List<String> get payerIds => [if (_paidBy case final id?) id, ..._extraPayerIds];

  /// Whether more than one person paid: only then does each have an amount
  /// of their own, and only then is one saved.
  bool get multiPayer => _extraPayerIds.isNotEmpty;

  bool isPayer(String id) => id == _paidBy || _extraPayerIds.contains(id);

  /// What each payer paid, as typed, in the group's currency. Only several
  /// payers have one: one pays the whole amount, which the Amount field
  /// already says.
  late final Map<String, TextEditingController> payerAmountControllers = {
    for (final p in group.participants) p.id: TextEditingController(),
  };

  /// What [id] paid, in the group currency's smallest unit, or null while
  /// it isn't a number.
  int? paidByAmount(String id) {
    if (!multiPayer) return id == _paidBy ? amount : null;
    final text = payerAmountControllers[id]?.text.trim() ?? '';
    return switch (parseDecimal(text)) {
      final value? when value >= 0 => toMinorUnits(value, digits),
      _ => null,
    };
  }

  /// What's wrong with who paid, if anything: no one, an amount that isn't
  /// one, or amounts that don't add up to the total. Cloud's payer list
  /// must add up to the amount, as the split must.
  PayerProblem? payerProblem() {
    if (_paidBy == null) return const NoPayer();
    if (!multiPayer) return null;
    // The amount's own field says what's wrong when there's no total yet.
    final total = amount;
    if (total == null) return null;
    var sum = 0;
    for (final id in payerIds) {
      final paid = paidByAmount(id);
      // Everyone paying paid something; a 0 row is one to fill in.
      if (paid == null || paid <= 0) return InvalidPayerAmount(id);
      sum += paid;
    }
    return sum == total ? null : PayersDontAddUp(total - sum);
  }

  /// Who paid, and how much each, for saving: null when [payerProblem]
  /// finds a problem, or while the amount isn't known.
  List<ExpenseShare>? payers() {
    if (payerProblem() != null) return null;
    final amounts = <String, int>{};
    for (final id in payerIds) {
      final paid = paidByAmount(id);
      if (paid == null) return null;
      amounts[id] = paid;
    }
    return [
      for (final MapEntry(:key, :value) in amounts.entries)
        ExpenseShare(participantId: key, shares: value),
    ];
  }

  /// Adds [id] as another payer, sharing the amount out between everyone
  /// paying, evenly to begin with.
  void addPayer(String id) => _set(() {
        if (isPayer(id)) return;
        if (_paidBy == null) {
          _paidBy = id;
        } else {
          _extraPayerIds.add(id);
        }
        // Before sharing it out: a settlement's total is its To amounts,
        // and the new payer's stops counting.
        _dropPayersFromTo();
        if (multiPayer) _sharePayersEvenly();
      });

  /// Stops [id] paying; the last payer stays, since someone paid.
  void removePayer(String id) => _set(() {
        if (!isPayer(id)) return;
        if (_paidBy == id) {
          if (_extraPayerIds.isEmpty) return;
          _paidBy = _extraPayerIds.removeAt(0);
        } else {
          _extraPayerIds.remove(id);
        }
        payerAmountControllers[id]?.text = '';
        if (multiPayer) {
          _sharePayersEvenly();
        } else {
          _clearPayerAmounts();
        }
      });

  /// Shares the amount out evenly between the payers, after one is added or
  /// removed: the odd unit to the first, as the split's Evenly does.
  void _sharePayersEvenly() {
    final ids = payerIds;
    final total = amount;
    _filling = true;
    for (final c in payerAmountControllers.values) {
      c.text = '';
    }
    if (total != null && total > 0) {
      final cents = shareCentsFor(
        amountCents: total,
        splitMode: SplitMode.evenly,
        paidFor: [for (final id in ids) ExpenseShare(participantId: id, shares: 1)],
      );
      for (final id in ids) {
        payerAmountControllers[id]?.text = minorText(cents[id] ?? 0, digits);
      }
    }
    _filling = false;
  }

  void _clearPayerAmounts() {
    _filling = true;
    for (final c in payerAmountControllers.values) {
      c.text = '';
    }
    _filling = false;
  }

  /// A settlement's From isn't one of its To (Kenneth, 2026-10-10): the
  /// card leaves them out, so they mustn't keep an amount it can't show.
  /// Only when someone becomes From: an older settlement saved with its
  /// payer among the To keeps that amount, shown, until they're changed.
  void _dropPayersFromTo() {
    if (!_isSettlement) return;
    for (final id in payerIds) {
      if (!splitControllers.containsKey(id)) continue;
      _included[id] = false;
      splitControllers[id]!.text = '';
    }
  }

  DateTime _date = DateTime.now();
  DateTime get date => _date;

  /// Whether the date or category was picked (or filled from a receipt),
  /// so a scan leaves it alone (#125).
  bool _dateChosen = false;
  bool get dateChosen => _dateChosen;
  bool _categoryChosen = false;
  bool get categoryChosen => _categoryChosen;

  void setDate(DateTime date, {bool chosen = true}) => _set(() {
        _date = date;
        _dateChosen = chosen;
      });

  int _category = 0;
  int get category => _category;
  void setCategory(int id, {bool chosen = true}) => _set(() {
        _category = id;
        _categoryChosen = chosen;
      });

  bool _isSettlement = false;
  bool get isSettlement => _isSettlement;

  /// "Settlement", as filled into an empty title, to clear it again on
  /// switching back if it's untouched (#262).
  String? _autoTitle;

  /// The other kind's split while switched away from it (#262): back to
  /// an expense, its split comes back as it was, and so do a
  /// settlement's To amounts.
  _Split? _otherSplit;

  /// Who paid when [_otherSplit] was set aside: a settlement's To comes
  /// back as it was unless a To became From meanwhile.
  List<String> _otherSplitPayers = const [];

  /// Switches between an expense and a settlement (#262). A settlement's
  /// "To" is the Amount rows, its amount their sum; an expense gets its
  /// split back. [title] fills an empty title.
  void setSettlement(bool value, {required String title}) {
    if (value == _isSettlement) return;
    final clean = !hasChangesBeyondKind;
    _filling = true;
    final recipients = value ? null : includedParticipants;
    final total = value ? null : (converting ? originalAmount : amount);
    final other = _otherSplit;
    final otherPayers = _otherSplitPayers;
    _otherSplit = _currentSplit();
    _otherSplitPayers = payerIds;
    _isSettlement = value;
    _convertedAmountInvalid = false;
    if (other != null) {
      _restore(other);
    } else if (value) {
      // To: no one yet.
      _splitMode = SplitMode.byAmount;
      for (final p in group.participants) {
        _included[p.id] = false;
        splitControllers[p.id]!.text = '';
      }
    } else {
      // An edited settlement's first expense: even, between its
      // recipients, for what they were paid.
      _splitMode = SplitMode.evenly;
      for (final p in group.participants) {
        _included[p.id] = recipients!.isEmpty || recipients.contains(p);
      }
      if (total != null && total > 0) {
        (converting ? originalAmountController : amountController).text =
            minorText(total, converting ? originalDigits : digits);
      }
    }
    if (value && titleController.text.trim().isEmpty) {
      titleController.text = _autoTitle = title;
    } else if (!value && _autoTitle != null && titleController.text == _autoTitle) {
      titleController.text = '';
    }
    if (!value) _autoTitle = null;
    // A fresh settlement's To is empty already.
    if (other != null && !listEquals(otherPayers, payerIds)) _dropPayersFromTo();
    _filling = false;
    _cleanAfterSwitch = clean ? _state() : null;
    notifyListeners();
  }

  /// The form right after a kind switch made with nothing else changed.
  List<Object?>? _cleanAfterSwitch;

  /// Whether anything but the kind (and what switching it filled in)
  /// differs from where the form started (#272): switching a fresh form
  /// back and forth isn't worth asking about.
  bool get hasChangesBeyondKind =>
      hasChanges && !(_cleanAfterSwitch != null && listEquals(_cleanAfterSwitch, _state()));

  _Split _currentSplit() => (
        mode: _splitMode,
        included: Map.of(_included),
        values: {for (final MapEntry(:key, :value) in splitControllers.entries) key: value.text},
      );

  void _restore(_Split split) {
    _splitMode = split.mode;
    _included.addAll(split.included);
    for (final MapEntry(:key, :value) in split.values.entries) {
      splitControllers[key]!.text = value;
    }
  }

  /// "Mark as paid" (#262): the balance it settles, in the group's
  /// currency, and to whom. It's saved exactly as long as the To amounts
  /// are the form's own: the recipient's is the balance (converted, in
  /// another currency) and no one else has one.
  ({int amount, String to})? _balance;

  /// The recipient's To amount as the form last filled it in.
  String? _balanceText;

  bool get _balanceKept {
    final balance = _balance;
    if (balance == null || !_isSettlement) return false;
    return group.participants.every((p) =>
        p.id == balance.to ? splitControllers[p.id]!.text == _balanceText : !isIncluded(p.id));
  }

  /// In another currency, the balance's To amount is the balance
  /// converted, filled in again when the currency or the rate changes.
  void _refillBalance() {
    if (!_balanceKept) return;
    final (balance, rate) = (_balance!, this.rate);
    final shown = !converting
        ? minorText(balance.amount, digits)
        : rate == null
            ? ''
            : minorText(
                convertToOriginalAmount(
                    amount: balance.amount, rate: rate, decimalDigits: digits, originalDecimalDigits: originalDigits),
                originalDigits);
    if (shown == _balanceText) return;
    _balanceText = shown;
    final filling = _filling;
    _filling = true;
    splitControllers[balance.to]!.text = shown;
    _filling = filling;
  }

  bool _saveDefaultSplit = false;
  bool get saveDefaultSplit => _saveDefaultSplit;
  set saveDefaultSplit(bool value) => _set(() => _saveDefaultSplit = value);

  /// The notes are markdown (#311): saved behind [markdownMarker], which
  /// [notesController] doesn't show.
  bool _notesMarkdown = false;
  bool get notesMarkdown => _notesMarkdown;
  set notesMarkdown(bool value) => _set(() => _notesMarkdown = value);

  /// The notes as saved. Markdown keeps its leading spaces (PR #312
  /// review): four of them make a code block. Only an empty note is
  /// emptied, and trailing space dropped.
  String get notes {
    final text = notesController.text;
    if (text.trim().isEmpty) return '';
    return _notesMarkdown ? noteText(text.trimRight(), markdown: true) : text.trim();
  }

  RecurrenceRule _recurrenceRule = RecurrenceRule.none;
  RecurrenceRule get recurrenceRule => _recurrenceRule;
  set recurrenceRule(RecurrenceRule value) => _set(() => _recurrenceRule = value);

  SplitMode _splitMode = SplitMode.evenly;
  SplitMode get splitMode => _splitMode;

  /// Switching modes keeps who's included (#260): in Shares, Percent or
  /// Amount they get equal values, 1 share, equal percentages or equal
  /// amounts, the remainder to the first, and everyone else nothing; back
  /// in Evenly, anyone with a value above 0 is checked. With no total yet,
  /// Amount's values are empty, and Evenly keeps who was checked before.
  set splitMode(SplitMode value) {
    if (value == _splitMode) return;
    final included = includedParticipants;
    if (_splitMode != SplitMode.evenly && included.isNotEmpty) {
      for (final p in group.participants) {
        _included[p.id] = included.contains(p);
      }
    }
    _splitMode = value;
    if (value != SplitMode.evenly) {
      _filling = true;
      final total = switch (value) {
        SplitMode.byPercentage => 10000,
        SplitMode.byAmount => splitTotal,
        _ => null,
      };
      final equal = total == null || included.isEmpty
          ? null
          : shareCentsFor(
              amountCents: total,
              splitMode: SplitMode.evenly,
              paidFor: [for (final p in included) ExpenseShare(participantId: p.id, shares: 1)]);
      for (final p in group.participants) {
        final part = equal?[p.id];
        splitControllers[p.id]!.text = !included.contains(p)
            ? ''
            : switch (value) {
                SplitMode.byShares => '1',
                SplitMode.byPercentage => shareText(part! / 100),
                _ => part == null ? '' : minorText(part, splitDigits),
              };
      }
      _filling = false;
    }
    notifyListeners();
  }

  /// [text] with the locale's decimal separator.
  String _localized(String text) => text.replaceFirst('.', _decimalSeparator);

  /// [value] as a field shows it (#289): [decimalDigits] places, in the
  /// locale's decimal separator. Every number the form writes into a
  /// field goes through this, [minorText] or [shareText], so it reads
  /// back as written.
  String amountText(double value, int decimalDigits) => _localized(value.toStringAsFixed(decimalDigits));

  /// Shares or a percentage: at most 2 places, no trailing zeros.
  String shareText(double value) => _localized(trimTrailingZeros(value));

  /// [minor] smallest units of a currency with [decimalDigits] places, as
  /// a field shows it.
  String minorText(int minor, int decimalDigits) => _localized(minorUnitsText(minor, decimalDigits));

  /// The category saved (#259): a settlement made here is a Payment,
  /// whatever was picked before it was switched to one. An edit keeps its
  /// category, hidden for a settlement, so switching there and back costs
  /// nothing.
  int get categoryToSave => existing == null && isSettlement ? paymentCategoryId : category;

  /// Spliit Cloud's "Settlement" category. The local int is stable for the
  /// cache and the picker; [Expense.categoryId] carries `settlement`.
  static const paymentCategoryId = cloudSettlementCategoryLocalId;

  // ---------------------------------------------------------------------
  // Changes, for "Discard changes?" (#259).

  List<Object?>? _unchanged;

  /// What the user can change, as it stands. A rate filled in from the
  /// published ones isn't the user's, so only a rate of their own counts.
  List<Object?> _state() => [
        titleController.text,
        amountController.text,
        notesController.text,
        // The rate as a value: the pair's order is the device's, not the
        // expense's.
        if (converting) ...[originalAmountController.text, rateField.isOwn ? rate : null],
        _paidIn,
        // Only what the mode uses: Evenly's checks, or the others' values.
        // Switching away and back leaves the hidden ones filled in (#266).
        for (final p in group.participants)
          _splitMode == SplitMode.evenly ? _included[p.id] : splitControllers[p.id]!.text,
        // Who paid, in order, and what each did when more than one did.
        ...payerIds,
        if (multiPayer) for (final id in payerIds) payerAmountControllers[id]!.text,
        // The lines, and how what they leave is shared.
        _itemized,
        if (_itemized) ...[
          for (final item in _items) ...item.state,
          ..._remainderSplit.state,
        ],
        _date,
        _category,
        _isSettlement,
        _saveDefaultSplit,
        _notesMarkdown,
        _recurrenceRule,
        _splitMode,
      ];

  /// Takes the form as it is now as where it started: once it's filled
  /// in, and shows an edit's saved rate.
  void markUnchanged() => _unchanged = _state();

  /// Whether anything differs from where the form started.
  bool get hasChanges => _unchanged != null && !listEquals(_unchanged, _state());

  /// The calculated amount (or amount to transfer) can't be saved, e.g.
  /// it rounds to zero. Set by [amountsToSave], cleared once an amount,
  /// the rate or the currency changes.
  bool _convertedAmountInvalid = false;
  bool get convertedAmountInvalid => _convertedAmountInvalid;

  void _amountsChanged() => _convertedAmountInvalid = false;

  /// Filling in several fields at once, which tells listeners once at the
  /// end rather than for each.
  bool _filling = false;

  void _typed() {
    if (!_filling) notifyListeners();
  }

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Numbers as typed.

  String _decimalSeparator;

  /// The locale's decimal separator, which decides only "1,234" (#238)
  /// and is how numbers are written into fields. Given when the form is
  /// made, so an edit's numbers show in it from the start (#289); set
  /// again if the locale changes, for what's written from then on.
  set decimalSeparator(String separator) {
    _decimalSeparator = separator;
    rateField.decimalSeparator = separator;
    for (final item in _items) {
      item.decimalSeparator = separator;
    }
    _remainderSplit.decimalSeparator = separator;
  }

  /// [parseFlexibleDecimal] with this locale's decimal separator.
  double? parseDecimal(String input) =>
      parseFlexibleDecimal(input, decimalSeparator: _decimalSeparator, currencies: [group.currency]);

  /// Whether [text] is an amount of at least one smallest unit once
  /// rounded to [decimalDigits] (#254 review): 0.1 yen rounds to 0, which
  /// would save a zero amount, and as an original amount an infinite rate.
  bool isPositiveAmount(String? text, int decimalDigits) {
    final parsed = parseDecimal(text ?? '');
    return parsed != null && toMinorUnits(parsed, decimalDigits) > 0;
  }

  // ---------------------------------------------------------------------
  // Currency and conversion (#251, #252).

  /// The group currency's decimal places (#251): every amount on this
  /// form is stored in its smallest unit.
  int get digits => group.decimalDigits;

  /// Whether the group has a real ISO currency code (as opposed to a
  /// free-typed custom symbol): only then can it be converted from.
  bool get hasGroupCurrencyCode => group.currencyCode != null && group.currencyCode!.isNotEmpty;

  /// The currency the expense was paid in (#252): the group's unless
  /// another is picked, which only a group with an ISO code can do.
  late String? _paidIn = group.currencyCode;
  String? get paidIn => _paidIn;

  /// Paid in another currency than the group's (#252): "Amount paid" and
  /// "Exchange rate" show, and one amount is calculated from the other.
  bool get converting => hasGroupCurrencyCode && _paidIn != null && _paidIn != group.currencyCode;

  Currency get paidInCurrency => currencyByCode(_paidIn);

  /// The paid-in currency's decimal places.
  int get originalDigits => paidInCurrency.decimalDigits;

  /// The paid-in currency's symbol, or its code when it has none.
  String get paidInSymbol => paidInCurrency.symbol.isEmpty ? (_paidIn ?? '') : paidInCurrency.symbol;

  /// Picks the paid-in currency. A rate belongs to a pair of currencies,
  /// so it can't come along; back to the group's own currency, the
  /// calculated total is kept as the amount (spliit-ios). Returns whether
  /// anything changed, so the screen knows to look the rate up.
  bool choosePaidIn(String code) {
    if (code == _paidIn) return false;
    final converted = converting && !_isSettlement ? amount : null;
    _paidIn = code;
    _convertedAmountInvalid = false;
    rateField.pairWith(code);
    if (!converting && converted != null) amountController.text = minorText(converted, digits);
    _refillBalance();
    notifyListeners();
    return true;
  }

  /// The exchange rate's field (#261): its order, swap, and where its
  /// rate comes from.
  late final ExchangeRateField rateField;

  /// Whether a lookup may fill the rate in: always for [force] ("Use the
  /// published rate"), otherwise only into an empty or auto-filled field.
  bool wantsRate({bool force = false}) => converting && (force || !rateField.isOwn);

  /// The conversion's rate, 1 paid-in unit in group units.
  double? get rate => rateField.value;

  /// The amount as typed, in the group currency's smallest unit.
  int? get typedAmount => switch (parseDecimal(amountController.text.trim())) {
        final amount? => toMinorUnits(amount, digits),
        null => null,
      };

  /// The amount paid, in the paid-in currency's smallest unit: typed for
  /// an expense, the To amounts' sum for a settlement (#262).
  int? get originalAmount => _isSettlement
      ? _toTotal
      : switch (parseDecimal(originalAmountController.text.trim())) {
          final amount? => toMinorUnits(amount, originalDigits),
          null => null,
        };

  /// What a settlement's To amounts add up to, in the paid-in currency.
  int? get _toTotal {
    var total = 0;
    for (final p in includedParticipants) {
      final value = typedValue(p);
      if (value == null || value < 0) return null;
      total += toMinorUnits(value, splitDigits);
    }
    return total;
  }

  /// A settlement's total, as the To card shows it under the amounts.
  int? get settlementTotal => _isSettlement ? _toTotal : null;

  /// The edited expense as the form opened it: what's saved stays saved
  /// until its inputs change (#255 review, #261, #289). spliit-web lets a
  /// total differ a little from the amount paid times the rate, and
  /// converting shares back and forth can move the odd unit, so neither
  /// is worked out afresh while what it came from reads as it did. The
  /// saved rate is the rate field's ([ExchangeRateField.isSaved]).
  ({int amount, int? originalAmount, String? paidIn, bool isSettlement, List<Object?> split})? _saved;

  bool get _splitUnchanged => listEquals(_splitState(), _saved?.split);

  /// The conversion is the edited expense's, untouched: same currency,
  /// rate, settlement flag and the amount it was worked out from.
  bool get conversionUnchanged {
    final saved = _saved;
    if (saved == null || saved.originalAmount == null) return false;
    return _paidIn == saved.paidIn &&
        _isSettlement == saved.isSettlement &&
        rateField.isSaved &&
        // A settlement's amount paid is its To amounts: moved between
        // people, the sum can stay while the inputs changed (#262 review).
        (_isSettlement ? _splitUnchanged : originalAmount == saved.originalAmount);
  }

  /// The amount in the group's currency: calculated from the amount paid
  /// during a conversion, so the rate always explains it; typed
  /// otherwise. A settlement's is its To amounts' sum (#262), or while
  /// "Mark as paid" fills them in, the balance it settles.
  int? get amount {
    if (_balanceKept) return _balance!.amount;
    if (!converting) return _isSettlement ? _toTotal : typedAmount;
    if (conversionUnchanged) return _saved!.amount;
    final (original, rate) = (originalAmount, this.rate);
    if (original == null || rate == null) return null;
    return convertToGroupAmount(
        originalAmount: original, rate: rate, originalDecimalDigits: originalDigits, decimalDigits: digits);
  }

  // ---------------------------------------------------------------------
  // Paid for.

  /// In Evenly, whether they're checked; in the other modes, whether
  /// they have a value other than 0 (#260). A value that isn't a number
  /// counts, so the split says what's wrong with it.
  bool isIncluded(String participantId) {
    if (_splitMode == SplitMode.evenly) return _included[participantId] ?? false;
    final text = splitControllers[participantId]?.text.trim() ?? '';
    return text.isNotEmpty && parseDecimal(text) != 0;
  }

  /// Checks or unchecks [participantId], in Evenly.
  void setIncluded(String participantId, bool included) => _set(() => _included[participantId] = included);

  List<Participant> get includedParticipants => group.participants.where((p) => isIncluded(p.id)).toList();

  bool get allIncluded => group.participants.every((p) => isIncluded(p.id));

  /// Flips every participant's included flag to the opposite of
  /// [allIncluded] -- "Select all"/"Select none" always offers the
  /// complement of the current state (issue #29 section 2), and leaves
  /// typed values untouched so re-including someone brings their number
  /// back rather than resetting it.
  void toggleSelectAll() => _set(() {
        final target = !allIncluded;
        for (final p in group.participants) {
          _included[p.id] = target;
        }
      });

  /// Applies this group's remembered "Paid for" split (issue #29,
  /// decisions/paid-for-split-ux-spec.md section 7), if it still applies
  /// to the group's current participants.
  void applyDefaultSplit(DefaultSplit split) {
    if (!split.appliesTo(group.participants)) return;
    // It arrives after the form opens: what it fills in is where the
    // form starts, not a change of the user's.
    final unchanged = !hasChanges;
    _splitMode = split.splitMode;
    if (split.shares case final shares?) {
      for (final p in group.participants) {
        final value = shares[p.id];
        _included[p.id] = value != null;
        splitControllers[p.id]!.text = value == null
            ? ''
            : switch (split.splitMode) {
                // Inverse of the x100 done in [paidFor] -- issue #34: both
                // are x100-scaled on the wire, to allow decimal precision.
                SplitMode.byShares || SplitMode.byPercentage => shareText(value / 100),
                _ => value.toString(),
              };
      }
    }
    if (unchanged) markUnchanged();
    notifyListeners();
  }

  /// The typed value for [p] in the current non-evenly split mode, or
  /// null if it isn't currently a number -- every non-evenly mode takes
  /// a decimal (issue #34), matching [paidFor]'s own parsing so the live
  /// footer/preview never disagree with what Save would actually do.
  double? typedValue(Participant p) => parseDecimal(splitControllers[p.id]!.text.trim());

  /// Rounded basis points (percentage x 100) for [p]'s typed value -- the
  /// exact integer [paidFor] sends on the wire, and the same thing
  /// spliit-web's own expenseFormSchema sums to validate a BY_PERCENTAGE
  /// split (must total 10000). Validating in basis points rather than
  /// summing raw decimals avoids floating-point drift (e.g. three
  /// 33.33...s never quite summing to exactly 100.0).
  int? percentageBasisPoints(Participant p) {
    final value = typedValue(p);
    return value == null ? null : (value * 100).round();
  }

  /// How much of the total is still unaccounted for, in the field's own
  /// unit (percentage points, or major units of money) -- null for
  /// Evenly/Shares, which have no "must sum to X" concept (issue #29
  /// section 6 step 2). Positive means "still to allocate", negative
  /// means "over".
  double? unallocated() {
    // A settlement's amounts make its total: nothing to allocate.
    if (_isSettlement) return null;
    if (_splitMode == SplitMode.byPercentage) {
      var totalBasisPoints = 0;
      for (final p in includedParticipants) {
        final bp = percentageBasisPoints(p);
        if (bp == null) return null;
        totalBasisPoints += bp;
      }
      return (10000 - totalBasisPoints) / 100;
    }
    if (_splitMode == SplitMode.byAmount) {
      final amountMinor = splitTotal;
      if (amountMinor == null) return null;
      // In minor units, as [splitProblem] counts it: 0.10 + 0.20 summed
      // as doubles is a hair over 0.30, which showed as "€0.00 over" (#288).
      var totalMinor = 0;
      for (final p in includedParticipants) {
        final v = typedValue(p);
        if (v == null) return null;
        totalMinor += toMinorUnits(v, splitDigits);
      }
      return fromMinorUnits(amountMinor - totalMinor, splitDigits);
    }
    return null;
  }

  /// Ported from spliit-ios's `ExpenseFormDraft.showsShareAmounts` --
  /// issue #29 section 4. Amount mode never shows a computed preview
  /// (the typed field already *is* the amount); Percent only once the
  /// typed percentages land exactly on 100.
  bool get showsLivePreview {
    if (_isSettlement || _splitMode == SplitMode.byAmount) return false;
    if (includedParticipants.isEmpty) return false;
    if (_splitMode == SplitMode.evenly) return true;
    for (final p in includedParticipants) {
      final v = typedValue(p);
      if (v == null || v <= 0) return false;
    }
    return _splitMode == SplitMode.byPercentage ? unallocated() == 0 : true;
  }

  /// The live per-participant amounts, computed with the same
  /// apportionment [shareCentsFor] uses at Save time, but from whatever
  /// is currently typed rather than a saved [Expense]. Null when
  /// [showsLivePreview] is false or the amount isn't known yet.
  Map<String, int>? livePreviewAmounts() {
    if (!showsLivePreview) return null;
    final amountMinor = amount;
    if (amountMinor == null) return null;
    final paidFor = _splitMode == SplitMode.evenly
        ? [for (final p in includedParticipants) ExpenseShare(participantId: p.id, shares: 1)]
        : [
            for (final p in includedParticipants)
              ExpenseShare(participantId: p.id, shares: (typedValue(p)! * 100).round()),
          ];
    return shareCentsFor(amountCents: amountMinor, splitMode: _splitMode, paidFor: paidFor);
  }

  /// What's wrong with the split, if anything -- pure, so the live footer
  /// (once Save was tried, issue #29 section 6 step 1) and [paidFor] at
  /// Save time can never disagree about what counts as a blocking problem.
  SplitProblem? splitProblem() {
    final included = includedParticipants;
    if (included.isEmpty) return const NoOneIncluded();
    switch (_splitMode) {
      case SplitMode.evenly:
        return null;
      case SplitMode.byShares:
        for (final p in included) {
          final value = typedValue(p);
          if (value == null || value <= 0) return InvalidValue(p);
        }
        return null;
      case SplitMode.byPercentage:
        var totalBasisPoints = 0;
        for (final p in included) {
          final bp = percentageBasisPoints(p);
          if (bp == null || bp < 0) return InvalidValue(p);
          totalBasisPoints += bp;
        }
        return totalBasisPoints == 10000 ? null : PercentagesDontAddUp(totalBasisPoints);
      // Each recipient's amount is at least one smallest unit (#262).
      case SplitMode.byAmount when _isSettlement:
        for (final p in included) {
          final value = typedValue(p);
          if (value == null || toMinorUnits(value, splitDigits) <= 0) return InvalidValue(p);
        }
        return null;
      case SplitMode.byAmount:
        final amountMinor = splitTotal ?? 0;
        var total = 0;
        for (final p in included) {
          final value = typedValue(p);
          if (value == null || value < 0) return InvalidValue(p);
          total += toMinorUnits(value, splitDigits);
        }
        return total == amountMinor ? null : AmountsDontAddUp(amountMinor - total);
    }
  }

  /// The paidFor list for the current split mode, or null if
  /// [splitProblem] finds a problem. Evenly needs no per-participant
  /// input at all -- every included participant just gets an equal
  /// weight.
  ///
  /// [SplitMode.byShares] and [SplitMode.byPercentage] both take a decimal
  /// (issue #34) and both send [ExpenseShare.shares] as the typed value
  /// x100, rounded -- e.g. "1.5" shares -> wire 150, "33.3"% -> wire
  /// 3330. That's the exact transform spliit-web's own expenseFormSchema
  /// applies to every non-BY_AMOUNT split before submitting (src/lib/
  /// schemas.ts and expense-form.tsx upstream), and what makes decimal
  /// shares/percentages representable on the wire at all (`shares` is
  /// stored as an integer). [_prefillFrom]/[applyDefaultSplit] divide
  /// back by 100 to redisplay an existing value.
  List<ExpenseShare>? paidFor() {
    // An itemized expense's split is its lines and their leftover, worked
    // out rather than typed; Cloud stores what it's sent here.
    if (isItemized) return _itemizedPaidFor();
    if (splitProblem() != null) return null;
    // The balance settled, exactly: converting it there and back could
    // leave a unit owed (#262, acceptance case 1).
    if (_balanceKept) return [ExpenseShare(participantId: _balance!.to, shares: _balance!.amount)];
    if (_keepsSavedSplit) return existing!.paidFor;
    final included = includedParticipants;
    return switch (_splitMode) {
      SplitMode.evenly => [for (final p in included) ExpenseShare(participantId: p.id, shares: 1)],
      SplitMode.byShares || SplitMode.byPercentage => [
          for (final p in included) ExpenseShare(participantId: p.id, shares: (typedValue(p)! * 100).round()),
        ],
      SplitMode.byAmount when !_splitsPaidIn => [
          for (final p in included) ExpenseShare(participantId: p.id, shares: toMinorUnits(typedValue(p)!, digits)),
        ],
      SplitMode.byAmount => switch (amount) {
          // Typed in the paid-in currency (#261): the converted amount is
          // shared out in proportion, adding up to it exactly.
          final total? => [
              for (final MapEntry(:key, :value) in shareCentsFor(
                amountCents: total,
                splitMode: SplitMode.byShares,
                paidFor: [
                  for (final p in included)
                    ExpenseShare(participantId: p.id, shares: toMinorUnits(typedValue(p)!, originalDigits)),
                ],
              ).entries)
                ExpenseShare(participantId: key, shares: value),
            ],
          null => null,
        },
    };
  }

  /// What's saved stays saved while its inputs read as they did (#261,
  /// acceptance case 2): converting back and forth can tie or swap who
  /// has the odd unit, and a settlement's mode, even before #262, stays.
  bool get _keepsSavedSplit {
    final saved = _saved;
    return saved != null &&
        _splitMode == SplitMode.byAmount &&
        _isSettlement == saved.isSettlement &&
        _paidIn == saved.paidIn &&
        (!converting || conversionUnchanged) &&
        _splitUnchanged;
  }

  /// The split mode to save: an untouched edit's own, or Amount for an
  /// itemized expense, whose shares are the exact amounts its lines work
  /// out to.
  SplitMode get splitModeToSave =>
      isItemized ? SplitMode.byAmount : (_keepsSavedSplit ? existing!.splitMode : _splitMode);

  /// Amounts are typed in the paid-in currency (#261, #262): an expense
  /// split by amount's, adding up to the amount paid, and a settlement's
  /// To amounts, making it.
  bool get _splitsPaidIn => converting;

  /// What the amounts of an expense split by amount add up to, and the
  /// currency they're in.
  int? get splitTotal => _isSettlement ? null : (_splitsPaidIn ? originalAmount : amount);
  int get splitDigits => _splitsPaidIn ? originalDigits : digits;
  String get splitSymbol => _splitsPaidIn ? paidInSymbol : group.currency;

  /// The split as it reads, to tell if it's the saved one.
  List<Object?> _splitState() => [
        _splitMode,
        for (final p in group.participants) ...[_included[p.id], splitControllers[p.id]!.text],
      ];

  // ---------------------------------------------------------------------
  // Line items.

  final List<ItemDraft> _items = [];

  /// The lines this expense is made of, as they're being typed.
  List<ItemDraft> get items => List.unmodifiable(_items);

  bool _itemized = false;

  /// Whether this is an itemized expense: its lines, and the leftover, are
  /// what it's split by. A settlement is never one -- switching to it keeps
  /// the lines for switching back, as the other kind's split is kept.
  bool get isItemized => _itemized && !_isSettlement;

  /// Cloud's own tag for how the leftover is allocated, kept as read so an
  /// edit sends back what it found.
  String? _remainderAllocationMode;

  /// Who shares what the items leave of the amount.
  late final SplitDraft _remainderSplit = SplitDraft(
    group: group,
    activeUserId: activeUserId,
    total: () => remainderCents,
    mode: SplitMode.evenly,
    decimalSeparator: _decimalSeparator,
  );

  SplitDraft get remainderSplit => _remainderSplit;

  /// Turns itemizing on, with one line to fill in, or off.
  void setItemized(bool value) => _set(() {
        if (value == _itemized) return;
        _itemized = value;
        if (value && _items.isEmpty) _addItem();
        if (!value) {
          for (final item in _items) {
            item.dispose();
          }
          _items.clear();
          _remainderAllocationMode = null;
        }
      });

  /// Adds a line, at [at] or last, and returns it.
  ItemDraft addItem({int? at}) {
    final item = _addItem(at: at);
    notifyListeners();
    return item;
  }

  ItemDraft _addItem({int? at, String id = ''}) {
    final item = ItemDraft(
      group: group,
      activeUserId: activeUserId,
      id: id,
      decimalSeparator: _decimalSeparator,
    );
    for (final c in item.fields) {
      c.addListener(_typed);
    }
    _items.insert(at ?? _items.length, item);
    return item;
  }

  /// Takes a line away; the last one leaves the expense flat again.
  void removeItem(ItemDraft item) => _set(() {
        if (!_items.remove(item)) return;
        item.dispose();
        if (_items.isEmpty) _itemized = false;
      });

  /// What the lines add up to, in the group currency's smallest unit, or
  /// null while one of them can't be worked out.
  int? get itemsTotalCents {
    var total = 0;
    for (final item in _items) {
      final amount = item.amountCents;
      if (amount == null) return null;
      total += amount;
    }
    return total;
  }

  /// What the lines leave of the amount, in the group currency's smallest
  /// unit: negative when they come to more than it.
  int? get remainderCents {
    final (total, items) = (amount, itemsTotalCents);
    if (total == null || items == null) return null;
    return total - items;
  }

  /// What's wrong with the lines and the leftover, if anything; null while
  /// the expense isn't itemized.
  ItemizedProblem? itemizedProblem() {
    if (!isItemized) return null;
    if (_items.isEmpty) return const NoItems();
    for (final (index, item) in _items.indexed) {
      if (!item.hasTitle) return ItemUnfinished(index, ItemFault.name);
      if (!item.hasPrice) return ItemUnfinished(index, ItemFault.price);
      if (item.split.problem() case final problem?) {
        return ItemUnfinished(index, ItemFault.split, split: problem);
      }
    }
    final left = remainderCents;
    if (left == null) return null;
    if (left < 0) return ItemsExceedTotal(-left);
    if (left > 0) {
      if (_remainderSplit.problem() case final problem?) return LeftoverProblem(problem);
    }
    return null;
  }

  /// The lines to save: null while nothing says anything about them (a flat
  /// expense leaves the field out), an empty list when an edit took them all
  /// away, and the lines themselves when there are some.
  List<ExpenseItem>? itemsToSave() {
    if (!isItemized) {
      final had = existing?.items.isNotEmpty ?? false;
      return had ? const [] : null;
    }
    return [for (final item in _items) item.toItem()!];
  }

  /// How the leftover is shared, for saving: null while there's nothing
  /// left over, which leaves whatever Cloud has stored alone.
  ExpenseItemizedRemainder? remainderToSave() {
    if (!isItemized) return null;
    final left = remainderCents;
    if (left == null || left <= 0) return null;
    return ExpenseItemizedRemainder(
      splitMode: _remainderSplit.mode,
      allocationMode: _remainderAllocationMode,
      paidFor: _remainderSplit.paidFor()!,
    );
  }

  /// Everyone's share of an itemized expense: what each line works out to,
  /// plus the leftover, as exact amounts (which is what Cloud stores).
  List<ExpenseShare>? _itemizedPaidFor() {
    if (itemizedProblem() != null) return null;
    final money = <String, int>{};
    void add(List<ExpenseShare> share, int amount, SplitMode mode) {
      shareCentsFor(amountCents: amount, splitMode: mode, paidFor: share).forEach((id, cents) {
        money.update(id, (was) => was + cents, ifAbsent: () => cents);
      });
    }

    for (final item in _items) {
      add(item.split.paidFor()!, item.amountCents!, item.split.mode);
    }
    if (remainderCents case final left? when left > 0) {
      add(_remainderSplit.paidFor()!, left, _remainderSplit.mode);
    }
    return [
      for (final MapEntry(:key, :value) in money.entries)
        if (value > 0) ExpenseShare(participantId: key, shares: value),
    ];
  }

  // ---------------------------------------------------------------------
  // Saving.

  /// The amounts to save, or null when a conversion's calculated amount
  /// (or amount to transfer) can't be saved, which [convertedAmountInvalid]
  /// then says. A conversion's amounts are in each currency's own smallest
  /// unit (#251), related by the rate (#252): the amount is calculated
  /// from the amount paid, or for a settlement the amount to transfer
  /// from the amount settled. Either can round to nothing. Call once the
  /// fields have validated.
  ExpenseAmounts? amountsToSave() {
    if (!converting) {
      return switch (amount) {
        final amount? => ExpenseAmounts(amount: amount),
        null => null,
      };
    }
    final original = originalAmount;
    final total = amount;
    if (original == null || original <= 0 || total == null || total <= 0) {
      _set(() => _convertedAmountInvalid = true);
      return null;
    }
    return ExpenseAmounts(amount: total, originalAmount: original, originalCurrency: _paidIn, conversionRate: rate);
  }

  // ---------------------------------------------------------------------

  /// Fills everything from [e] -- edit and draft mode's starting point.
  /// Runs once; the form doesn't re-sync with a changing expense.
  void _prefillFrom(Expense e) {
    titleController.text = e.title;
    amountController.text = minorText(e.amountCents, digits);
    notesController.text = noteBody(e.notes);
    _notesMarkdown = isMarkdownNote(e.notes);
    // Everyone who paid, in the order Cloud lists them: one, or several
    // with an amount each. A payer who's left the group isn't shown, as a
    // split's participant who has. Their shares are read as what they paid
    // ([expensePaidCents]), whatever mode they were saved in, and saved
    // back as amounts.
    final paid = expensePaidCents(e);
    _extraPayerIds.clear();
    _paidBy = null;
    for (final payer in e.payers) {
      final id = payer.participantId;
      if (!payerAmountControllers.containsKey(id)) continue;
      if (_paidBy == null) {
        _paidBy = id;
      } else if (id != _paidBy) {
        _extraPayerIds.add(id);
      }
    }
    if (multiPayer) {
      for (final id in payerIds) {
        payerAmountControllers[id]?.text = minorText(paid[id] ?? 0, digits);
      }
    }
    _category = e.category;
    _date = e.date;
    _isSettlement = e.isSettlement;
    _recurrenceRule = e.recurrenceRule;
    // A settlement's To is amounts (#262), whatever it was saved as.
    _splitMode = e.isSettlement ? SplitMode.byAmount : e.splitMode;

    // Whoever isn't in it has no value: not included (#260).
    for (final p in group.participants) {
      _included[p.id] = false;
    }
    // A settlement saved another way (Mark as paid's even split, or the
    // web's) shows what each was paid.
    final shares = e.isSettlement && e.splitMode != SplitMode.byAmount
        ? [
            for (final MapEntry(:key, :value)
                in shareCentsFor(amountCents: e.amountCents, splitMode: e.splitMode, paidFor: e.paidFor).entries)
              ExpenseShare(participantId: key, shares: value),
          ]
        : e.paidFor;
    // Converted, each amount is in the paid-in currency (#261, #262): the
    // amount paid, shared out in proportion to the saved shares, adding up
    // to it exactly.
    final converted = e.originalCurrency != null && hasGroupCurrencyCode;
    final paidInShares = converted && _splitMode == SplitMode.byAmount && e.originalAmountCents != null
        ? shareCentsFor(amountCents: e.originalAmountCents!, splitMode: SplitMode.byShares, paidFor: shares)
        : null;
    final shareDigits = paidInShares == null ? digits : currencyByCode(e.originalCurrency).decimalDigits;
    for (final share in shares) {
      _included[share.participantId] = true;
      final controller = splitControllers[share.participantId];
      if (controller == null) continue;
      controller.text = switch (_splitMode) {
        SplitMode.byAmount => minorText(paidInShares?[share.participantId] ?? share.shares, shareDigits),
        // Shares/Percentage are both x100 on the wire (issue #34) --
        // inverse of the x100 done in [paidFor], formatted back down to
        // at most 2 decimal places with no trailing zeros so "150"
        // redisplays as "1.5", not "1.50" or "150".
        SplitMode.byShares || SplitMode.byPercentage => shareText(share.shares / 100),
        // Evenly's per-participant "shares" is just an equal weight,
        // stored by spliit-web as 100 for everyone, not 1 (issue #34
        // follow-up): switching an edited expense from Evenly to Shares
        // should show the "1" a new expense starts with, not "100".
        SplitMode.evenly => '1',
      };
    }

    // Only originalCurrency says "converted": the server keeps the old
    // amount and rate of a conversion that was removed (#252).
    if (e.originalCurrency != null && hasGroupCurrencyCode) {
      _paidIn = e.originalCurrency;
      rateField.pairWith(_paidIn);
      if (e.originalAmountCents case final original?) {
        originalAmountController.text = minorText(original, originalDigits);
      }
      if (e.conversionRate case final rate?) rateField.showSaved(rate);
    }
    // The lines, and what their leftover is shared by: read as they were
    // saved, so an untouched edit sends them back as they came.
    for (final item in e.items) {
      final draft = _addItem(id: item.id);
      draft.titleController.text = item.title;
      draft.unitPriceController.text = minorText(item.unitPriceCents, digits);
      draft.quantityController.text = trimTrailingZeros(item.quantityMilli / 1000);
      draft.split.mode = item.splitMode;
      draft.split.loadFrom(item.paidFor);
    }
    if (e.items.isNotEmpty || e.itemizedRemainder != null) {
      _itemized = true;
      if (e.itemizedRemainder case final remainder?) {
        _remainderAllocationMode = remainder.allocationMode;
        _remainderSplit.mode = remainder.splitMode;
        _remainderSplit.loadFrom(remainder.paidFor);
      } else {
        // No leftover of its own: everyone, as a fresh one starts.
        _remainderSplit.loadFrom([for (final p in group.participants) ExpenseShare(participantId: p.id, shares: 1)]);
      }
    }
    if (identical(e, existing)) {
      // Not for a draft: it's a new expense, worked out afresh.
      _saved = (
        amount: e.amountCents,
        originalAmount: _paidIn == null ? null : e.originalAmountCents,
        paidIn: _paidIn,
        isSettlement: e.isSettlement,
        split: _splitState(),
      );
    } else if (e.isSettlement && shares.length == 1) {
      // Mark as paid's draft (#262): one recipient, the balance.
      final to = shares.single.participantId;
      if (splitControllers[to] case final controller?) {
        _balance = (amount: e.amountCents, to: to);
        _balanceText = controller.text;
      }
    }
  }

  @override
  void dispose() {
    for (final c in [titleController, amountController, notesController, originalAmountController,
      ...splitControllers.values, ...payerAmountControllers.values]) {
      c.dispose();
    }
    for (final item in _items) {
      item.dispose();
    }
    _remainderSplit.dispose();
    rateField.dispose();
    super.dispose();
  }
}

/// A split as it stands: kept for the other kind while switched away.
typedef _Split = ({SplitMode mode, Map<String, bool> included, Map<String, String> values});

/// Which part of a line item is unfinished: what a refused save says.
enum ItemFault { name, price, split }

/// Why an itemized expense can't be saved; the items card says it in words.
sealed class ItemizedProblem {
  const ItemizedProblem();
}

/// There aren't any line items.
class NoItems extends ItemizedProblem {
  const NoItems();
}

/// The line at [index] isn't finished: [fault] says what's missing, and
/// [split] what's wrong with its split.
class ItemUnfinished extends ItemizedProblem {
  const ItemUnfinished(this.index, this.fault, {this.split});
  final int index;
  final ItemFault fault;
  final SplitProblem? split;
}

/// The lines come to [overBy] more than the expense, in the group
/// currency's smallest unit.
class ItemsExceedTotal extends ItemizedProblem {
  const ItemsExceedTotal(this.overBy);
  final int overBy;
}

/// What the lines leave can't be shared as the leftover says.
class LeftoverProblem extends ItemizedProblem {
  const LeftoverProblem(this.problem);
  final SplitProblem problem;
}

/// What [ExpenseFormModel.amountsToSave] found to save.
@immutable
class ExpenseAmounts {
  const ExpenseAmounts({required this.amount, this.originalAmount, this.originalCurrency, this.conversionRate});

  /// In the group currency's smallest unit.
  final int amount;

  /// In the paid-in currency's smallest unit; all three null together
  /// without a conversion.
  final int? originalAmount;
  final String? originalCurrency;
  final double? conversionRate;
}

