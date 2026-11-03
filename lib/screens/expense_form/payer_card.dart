import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../theme.dart';
import '../../utils/money.dart';
import '../../widgets/group_monogram.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/participant_colors.dart';
import '../../widgets/participant_sheet.dart';
import 'expense_form_model.dart';
import 'form_text.dart';
import 'inline_number_field.dart';

/// Who paid (#260) -- a settlement's "From" (#262): one person, normally,
/// who paid the whole amount, or several, each for a part of it, as Spliit
/// Cloud records them.
///
/// One payer is a row that picks them, as it always was. Several are a row
/// each, with what they paid, and a ✕ to take one out again; under them,
/// what doesn't add up to the total. "Add payer" is the last row either
/// way. The card's first row, above "Paid for" (Kenneth, 2026-10-10: a
/// card of its own, one row, looked stranded).
class PayerCard extends StatelessWidget {
  const PayerCard({
    super.key,
    required this.model,
    this.showErrors = false,
    this.footerKey,
  });

  final ExpenseFormModel model;

  /// A save was tried: what's wrong with who paid is said in red, rather
  /// than only in the footer's dimmed text.
  final bool showErrors;

  /// On what the payers say (what doesn't add up), for a refused save to
  /// scroll to.
  final Key? footerKey;

  ExpenseFormModel get _m => model;

  /// A payer's amount field.
  static Key amountKey(String participantId) => ValueKey('payerCard.amount.$participantId');

  /// A payer's ✕.
  static Key removeKey(String participantId) => ValueKey('payerCard.remove.$participantId');

  /// "Add payer".
  static const addKey = ValueKey('payerCard.add');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // A settlement's is "From" (#262).
    final label = _m.isSettlement ? l10n.expenseFromLabel : l10n.expensePaidByLabel;
    final message = _message(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_m.multiPayer)
          _singleRow(context, label)
        else ...[
          _heading(context, label),
          for (final (i, id) in _m.payerIds.indexed) ...[
            // Past the monogram, as the split's own rows.
            GroupedDivider(indent: i == 0 ? 16 : ChoiceRow.monogramIndent),
            _payerRow(context, id),
          ],
        ],
        if (_canAdd) ...[
          GroupedDivider(indent: _m.multiPayer ? ChoiceRow.monogramIndent : 16),
          _addRow(context),
        ],
        if (message != null)
          Padding(
            key: footerKey,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: message,
          ),
      ],
    );
  }

  /// One payer: the label, then them, by their monogram. A tap picks
  /// another.
  Widget _singleRow(BuildContext context, String label) {
    final participants = _m.group.participants;
    final payer = participants.where((p) => p.id == _m.paidBy).firstOrNull;
    // Not a trailing: ListTile gives that all the width it asks for, and a
    // long name squeezed "From" to a letter a line. A name that doesn't
    // fit beside the label goes under it (#263).
    return GroupedRow(
      title: formLabel(context, label),
      value: payer == null
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              Monogram(
                  name: payer.name,
                  color: participantColors(participants, _m.activeUserId)[payer.id]!,
                  radius: 12),
              const SizedBox(width: 8),
              Flexible(child: Text(participantName(context, payer, _m.activeUserId), style: formValueStyle(context))),
            ]),
      onTap: () async {
        // As the screen's other pickers (#267): a field that kept its focus
        // would get it back when the sheet closes, and the form would
        // scroll back to it.
        FocusManager.instance.primaryFocus?.unfocus();
        final picked = await showParticipantSheet(
          context,
          title: label,
          participants: participants,
          checkedIds: _m.payerIds.toSet(),
          activeUserId: _m.activeUserId,
        );
        if (picked != null) _m.paidBy = picked;
      },
    );
  }

  /// Several payers: the label above them, as the split's own heading.
  Widget _heading(BuildContext context, String label) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: GroupedRow.oneLineMinHeight),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 16),
          child: Align(alignment: AlignmentDirectional.centerStart, child: formLabel(context, label)),
        ),
      );

  /// One of several payers: their monogram and name, what they paid, and a
  /// ✕ to take them out.
  Widget _payerRow(BuildContext context, String id) {
    final l10n = context.l10n;
    final participants = _m.group.participants;
    final participant = participants.where((p) => p.id == id).firstOrNull;
    final name = participant?.name ?? id;
    final color = participantColors(participants, _m.activeUserId)[id] ?? monogramPalette.first;
    return GroupedRow(
      title: MonogramLabel(
        monogram: Monogram(name: name, color: color, radius: 12),
        name: Text(participant == null ? name : participantName(context, participant, _m.activeUserId),
            style: Theme.of(context).textTheme.bodyLarge),
        nameStyle: Theme.of(context).textTheme.bodyLarge,
      ),
      value: InlineNumberField(
        fieldKey: amountKey(id),
        controller: _m.payerAmountControllers[id]!,
        name: l10n.expensePayerAmountField(name),
        prefix: '${_m.group.currency} ',
        contentPadding: EdgeInsets.zero,
      ),
      trailing: IconButton(
        key: removeKey(id),
        icon: const Icon(Icons.close),
        tooltip: l10n.expenseRemovePayer(name),
        onPressed: () => _m.removePayer(id),
      ),
    );
  }

  /// Everyone isn't paying yet, so one more can.
  bool get _canAdd => _m.group.participants.any((p) => !_m.isPayer(p.id));

  Widget _addRow(BuildContext context) {
    final muted = TextStyle(color: SpliitColors.of(context).secondaryContent);
    return GroupedRow(
      key: addKey,
      leading: Icon(Icons.add, color: SpliitColors.of(context).secondaryContent),
      title: Text(context.l10n.expenseAddPayer, style: muted),
      onTap: () async {
        FocusManager.instance.primaryFocus?.unfocus();
        final picked = await showParticipantSheet(
          context,
          title: context.l10n.expenseAddPayer,
          participants: _m.group.participants,
          checkedIds: _m.payerIds.toSet(),
          activeUserId: _m.activeUserId,
        );
        if (picked != null) _m.addPayer(picked);
      },
    );
  }

  /// What's wrong with who paid, in words, if anything (#263): what a
  /// refused save scrolls to and says.
  static String? problem(BuildContext context, ExpenseFormModel model) {
    final l10n = context.l10n;
    String nameOf(String participantId) =>
        model.group.participants.where((p) => p.id == participantId).firstOrNull?.name ?? participantId;
    return switch (model.payerProblem()) {
      null => null,
      NoPayer() => l10n.expenseSelectPayer,
      // The same words as a split value's (#260).
      InvalidPayerAmount(:final participantId) => l10n.expenseEnterAmount(nameOf(participantId)),
      PayersDontAddUp(:final difference) => () {
          final by = formatMoney(difference.abs(), model.group.currency,
              decimalDigits: model.digits, locale: context.appLocale);
          return difference > 0 ? l10n.expensePayerAmountShort(by) : l10n.expensePayerAmountOver(by);
        }(),
    };
  }

  /// What's wrong with who paid, if anything: in red once a save was tried,
  /// dimmed while the amounts are being typed.
  Widget? _message(BuildContext context) {
    final text = problem(context, _m);
    if (text == null) return null;
    return Text(text,
        style: GroupedSection.footnoteStyle(context,
            color: showErrors ? Theme.of(context).colorScheme.error : null));
  }
}
