/// What's wrong with a split, in words the cards turn into sentences: the
/// expense's own "Paid for" and each line item's. Its own library because
/// both use it -- `expense_form_model.dart` re-exports it, so this file must
/// not import that one.
library;

import '../../models/group.dart';

/// Why a split can't be saved.
sealed class SplitProblem {
  const SplitProblem();
}

/// Nobody is in the split.
class NoOneIncluded extends SplitProblem {
  const NoOneIncluded();
}

/// [participant]'s share, percentage or amount isn't a valid number.
class InvalidValue extends SplitProblem {
  const InvalidValue(this.participant);
  final Participant participant;
}

/// The percentages come to [totalBasisPoints] / 100 %, not 100 %.
class PercentagesDontAddUp extends SplitProblem {
  const PercentagesDontAddUp(this.totalBasisPoints);
  final int totalBasisPoints;
}

/// The amounts miss the total by [difference] (positive: short of it), in
/// the smallest unit of the currency they're in.
class AmountsDontAddUp extends SplitProblem {
  const AmountsDontAddUp(this.difference);
  final int difference;
}

/// Why who paid can't be saved.
sealed class PayerProblem {
  const PayerProblem();
}

/// Nobody is set as having paid.
class NoPayer extends PayerProblem {
  const NoPayer();
}

/// [participantId]'s amount paid isn't a positive number.
class InvalidPayerAmount extends PayerProblem {
  const InvalidPayerAmount(this.participantId);
  final String participantId;
}

/// The payers' amounts miss the total by [difference] (positive: short of
/// it), in the group currency's smallest unit.
class PayersDontAddUp extends PayerProblem {
  const PayersDontAddUp(this.difference);
  final int difference;
}

/// Formats a decimal to at most 2 places with no trailing zeros (or
/// trailing decimal point) -- e.g. 1.5 stays "1.5", 2.0 becomes "2", 33.3
/// stays "33.3". Used to redisplay a Shares/Percentage wire value and in
/// the footer's "still to allocate" hint.
String trimTrailingZeros(double value) {
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}
