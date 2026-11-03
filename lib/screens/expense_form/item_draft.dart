import 'package:flutter/widgets.dart' show TextEditingController;

import '../../models/expense.dart';
import '../../models/group.dart';
import '../../utils/decimal_input.dart';
import '../../utils/money.dart';
import 'split_problem.dart';

/// Who shares something and how: the mode, who's in, and each person's value.
///
/// The expense's own "Paid for" works all this out in [ExpenseFormModel],
/// which also carries a settlement's To, a conversion's paid-in currency and
/// a saved split; a line item and the leftover of an itemized expense need
/// only the plain part, so they share this smaller piece, and its
/// [SplitProblem]s, without taking state into that delicate code.
class SplitDraft {
  SplitDraft({
    required this.group,
    required this.activeUserId,
    required this.total,
    SplitMode mode = SplitMode.evenly,
    String decimalSeparator = '.',
  })  : _mode = mode,
        _decimalSeparator = decimalSeparator {
    for (final p in group.participants) {
      _included[p.id] = true;
      controllers[p.id] = TextEditingController();
    }
  }

  final Group group;
  final String? activeUserId;

  /// What's being split, in the group currency's smallest unit, or null
  /// while it isn't known: an item's own amount, or what the items left of
  /// the expense.
  final int? Function() total;

  SplitMode _mode;
  SplitMode get mode => _mode;

  /// Switching modes keeps who's included and gives everyone an equal value
  /// in the new one, as the expense's own split does.
  set mode(SplitMode value) {
    if (value == _mode) return;
    _mode = value;
    fillEqual();
  }

  String _decimalSeparator;
  set decimalSeparator(String separator) => _decimalSeparator = separator;

  final Map<String, bool> _included = {};

  /// Shares, a percentage, or an amount per participant; only the current
  /// non-Evenly mode reads them. One per participant, made in the
  /// constructor.
  final Map<String, TextEditingController> controllers = {};

  /// Every field a keystroke can change, for the form to listen to.
  Iterable<TextEditingController> get fields => controllers.values;

  int get digits => group.decimalDigits;

  double? parse(String input) =>
      parseFlexibleDecimal(input, decimalSeparator: _decimalSeparator, currencies: [group.currency]);

  double? typedValue(Participant p) => parse(controllers[p.id]!.text.trim());

  bool isIncluded(String participantId) {
    if (_mode == SplitMode.evenly) return _included[participantId] ?? false;
    final text = controllers[participantId]?.text.trim() ?? '';
    return text.isNotEmpty && parse(text) != 0;
  }

  void setIncluded(String participantId, bool included) => _included[participantId] = included;

  List<Participant> get includedParticipants => group.participants.where((p) => isIncluded(p.id)).toList();

  bool get allIncluded => group.participants.every((p) => isIncluded(p.id));

  /// Everyone in the split if they weren't, out if they all were.
  void toggleAll() {
    final target = !allIncluded;
    for (final p in group.participants) {
      _included[p.id] = target;
    }
  }

  /// Rounded basis points (percentage × 100), the exact integer sent.
  int? percentageBasisPoints(Participant p) {
    final value = typedValue(p);
    return value == null ? null : (value * 100).round();
  }

  /// How much of the total is still unallocated, in the mode's own unit
  /// (percentage points, or major units of money); null for Evenly and
  /// Shares, and while the total isn't known.
  double? unallocated() {
    final amountMinor = total();
    if (_mode == SplitMode.byPercentage) {
      var basisPoints = 0;
      for (final p in includedParticipants) {
        final bp = percentageBasisPoints(p);
        if (bp == null) return null;
        basisPoints += bp;
      }
      return (10000 - basisPoints) / 100;
    }
    if (_mode == SplitMode.byAmount) {
      if (amountMinor == null) return null;
      var totalMinor = 0;
      for (final p in includedParticipants) {
        final value = typedValue(p);
        if (value == null) return null;
        totalMinor += toMinorUnits(value, digits);
      }
      return fromMinorUnits(amountMinor - totalMinor, digits);
    }
    return null;
  }

  /// What's wrong with this split, if anything.
  SplitProblem? problem() {
    final included = includedParticipants;
    if (included.isEmpty) return const NoOneIncluded();
    switch (_mode) {
      case SplitMode.evenly:
        return null;
      case SplitMode.byShares:
        for (final p in included) {
          final value = typedValue(p);
          if (value == null || value <= 0) return InvalidValue(p);
        }
        return null;
      case SplitMode.byPercentage:
        var basisPoints = 0;
        for (final p in included) {
          final bp = percentageBasisPoints(p);
          if (bp == null || bp < 0) return InvalidValue(p);
          basisPoints += bp;
        }
        return basisPoints == 10000 ? null : PercentagesDontAddUp(basisPoints);
      case SplitMode.byAmount:
        final amountMinor = total();
        if (amountMinor == null) return null;
        var sum = 0;
        for (final p in included) {
          final value = typedValue(p);
          if (value == null || value < 0) return InvalidValue(p);
          sum += toMinorUnits(value, digits);
        }
        return sum == amountMinor ? null : AmountsDontAddUp(amountMinor - sum);
    }
  }

  /// The shares to save, or null while [problem] finds one. Shares and
  /// percentages are ×100 on the wire, as the expense's are.
  List<ExpenseShare>? paidFor() {
    if (problem() != null) return null;
    final included = includedParticipants;
    return switch (_mode) {
      SplitMode.evenly => [for (final p in included) ExpenseShare(participantId: p.id, shares: 1)],
      SplitMode.byShares || SplitMode.byPercentage => [
          for (final p in included) ExpenseShare(participantId: p.id, shares: (typedValue(p)! * 100).round()),
        ],
      SplitMode.byAmount => [
          for (final p in included) ExpenseShare(participantId: p.id, shares: toMinorUnits(typedValue(p)!, digits)),
        ],
    };
  }

  /// Fills who's in and their values from saved shares, as an edit opens
  /// them: the inverse of [paidFor].
  void loadFrom(List<ExpenseShare> shares) {
    for (final p in group.participants) {
      _included[p.id] = false;
      controllers[p.id]!.text = '';
    }
    for (final share in shares) {
      final controller = controllers[share.participantId];
      if (controller == null) continue;
      _included[share.participantId] = true;
      controller.text = switch (_mode) {
        SplitMode.evenly => '1',
        SplitMode.byShares || SplitMode.byPercentage => trimTrailingZeros(share.shares / 100),
        SplitMode.byAmount => minorUnitsText(share.shares, digits),
      };
    }
  }

  /// Equal values for everyone included in the new mode, the remainder to
  /// the first.
  void fillEqual() {
    final amountMinor = total();
    final included = includedParticipants;
    final each = amountMinor == null || included.isEmpty ? null : amountMinor ~/ included.length;
    for (final p in group.participants) {
      final controller = controllers[p.id]!;
      if (_mode == SplitMode.evenly) continue;
      if (!included.contains(p)) {
        controller.text = '';
        continue;
      }
      switch (_mode) {
        case SplitMode.byShares:
          controller.text = '1';
        case SplitMode.byPercentage:
          controller.text = trimTrailingZeros(100 / included.length);
        case SplitMode.byAmount:
          controller.text = each == null ? '' : minorUnitsText(each, digits);
        case SplitMode.evenly:
          break;
      }
    }
    // The odd unit goes to the first, as the expense's Evenly does.
    if (_mode == SplitMode.byAmount && amountMinor != null && each != null) {
      controllers[included.first.id]!.text =
          minorUnitsText(amountMinor - each * (included.length - 1), digits);
    }
  }

  /// What the fields and checks are, for change tracking.
  List<Object?> get state => [
        _mode,
        for (final p in group.participants) ...[_included[p.id], controllers[p.id]!.text],
      ];

  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
  }
}

/// One line item while it's being typed: its name, unit price and quantity,
/// and who shares it and how.
class ItemDraft {
  ItemDraft({
    required this.group,
    required this.activeUserId,
    this.id = '',
    String title = '',
    String unitPrice = '',
    String quantity = '1',
    String decimalSeparator = '.',
    SplitMode mode = SplitMode.evenly,
  }) : _decimalSeparator = decimalSeparator {
    titleController.text = title;
    unitPriceController.text = unitPrice;
    quantityController.text = quantity;
    // Captures this item: its total is the amount its own fields work out.
    split = SplitDraft(
      group: group,
      activeUserId: activeUserId,
      total: () => amountCents,
      mode: mode,
      decimalSeparator: decimalSeparator,
    );
  }

  final Group group;
  final String? activeUserId;

  /// Cloud's id, kept so an edit updates the item rather than replacing it;
  /// empty for a new one.
  final String id;

  final titleController = TextEditingController();
  final unitPriceController = TextEditingController();
  final quantityController = TextEditingController();

  late final SplitDraft split;

  String _decimalSeparator;
  set decimalSeparator(String separator) {
    _decimalSeparator = separator;
    split.decimalSeparator = separator;
  }

  int get digits => group.decimalDigits;

  double? parse(String input) =>
      parseFlexibleDecimal(input, decimalSeparator: _decimalSeparator, currencies: [group.currency]);

  /// The unit price, in the group currency's smallest unit, or null while it
  /// isn't a number.
  int? get unitPriceCents => switch (parse(unitPriceController.text.trim())) {
        final value? when value >= 0 => toMinorUnits(value, digits),
        _ => null,
      };

  /// The quantity in thousandths, or null while it isn't a number.
  int? get quantityMilli => switch (parse(quantityController.text.trim())) {
        final value? when value > 0 => (value * 1000).round(),
        _ => null,
      };

  /// What the line comes to, as Cloud works it out from the two: the unit
  /// price times the quantity in thousandths.
  int? get amountCents {
    final (unit, quantity) = (unitPriceCents, quantityMilli);
    if (unit == null || quantity == null) return null;
    return (unit * quantity / 1000).round();
  }

  bool get hasTitle => titleController.text.trim().isNotEmpty;
  bool get hasPrice => amountCents != null && amountCents! > 0;

  /// The line as Cloud takes it, or null while it can't be saved: no name,
  /// no price, or a split that doesn't work.
  ExpenseItem? toItem() {
    final amount = amountCents;
    final shares = split.paidFor();
    if (!hasTitle || amount == null || amount <= 0 || shares == null) return null;
    return ExpenseItem(
      id: id,
      title: titleController.text.trim(),
      amountCents: amount,
      unitPriceCents: unitPriceCents ?? 0,
      quantityMilli: quantityMilli ?? 1000,
      splitMode: split.mode,
      paidFor: shares,
    );
  }

  Iterable<TextEditingController> get fields =>
      [titleController, unitPriceController, quantityController, ...split.fields];

  List<Object?> get state => [
        id,
        titleController.text,
        unitPriceController.text,
        quantityController.text,
        ...split.state,
      ];

  void dispose() {
    titleController.dispose();
    unitPriceController.dispose();
    quantityController.dispose();
    split.dispose();
  }
}
