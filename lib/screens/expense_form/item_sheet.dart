import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../models/expense.dart';
import '../../models/group.dart';
import '../../theme.dart';
import '../../utils/money.dart';
import '../../widgets/app_switch.dart';
import '../../widgets/group_monogram.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/label_and_value.dart';
import '../../widgets/participant_colors.dart';
import '../../widgets/participant_sheet.dart';
import '../../widgets/segmented_pill.dart';
import 'expense_form_model.dart';
import 'form_text.dart';
import 'inline_number_field.dart';
import 'item_draft.dart';

/// The split a line item (or an itemized expense's leftover) is shared by:
/// the mode, then who's in it with their value, and under them what doesn't
/// add up. The same rows the expense's own "Paid for" has, without its
/// settlement, conversion and saved-split corners.
class SplitDraftFields extends StatefulWidget {
  const SplitDraftFields({super.key, required this.draft, this.fieldPrefix = 'item'});

  final SplitDraft draft;

  /// Keeps each sheet's keys apart from another's.
  final String fieldPrefix;

  Key valueKey(String participantId) => ValueKey('$fieldPrefix.value.$participantId');

  /// A split problem in words, as the expense's own card says it (#260).
  static String problemText(BuildContext context, SplitProblem problem,
      {String? symbol, int? digits}) {
    final l10n = context.l10n;
    return switch (problem) {
      NoOneIncluded() => l10n.expenseSelectAtLeastOne,
      InvalidValue(:final participant) => l10n.expenseEnterAmount(participant.name),
      PercentagesDontAddUp(:final totalBasisPoints) => () {
          final by = trimTrailingZeros((10000 - totalBasisPoints).abs() / 100);
          return totalBasisPoints < 10000 ? l10n.expensePercentageShort(by) : l10n.expensePercentageOverBy(by);
        }(),
      AmountsDontAddUp(:final difference) => () {
          final by = formatMoney(difference.abs(), symbol ?? '',
              decimalDigits: digits ?? 2, locale: context.appLocale);
          return difference > 0 ? l10n.expenseAmountShort(by) : l10n.expenseAmountOverBy(by);
        }(),
    };
  }

  /// The same, for a draft's own currency: its fields hold the group's.
  static String problemFor(BuildContext context, SplitDraft draft, SplitProblem problem) =>
      problemText(context, problem, symbol: draft.group.currency, digits: draft.digits);

  @override
  State<SplitDraftFields> createState() => _SplitDraftFieldsState();
}

class _SplitDraftFieldsState extends State<SplitDraftFields> {
  SplitDraft get _d => widget.draft;

  static String _modeName(BuildContext context, SplitMode mode) {
    final l10n = context.l10n;
    return switch (mode) {
      SplitMode.evenly => l10n.expenseSplitEvenly,
      SplitMode.byShares => l10n.expenseSplitShares,
      SplitMode.byPercentage => l10n.expenseSplitPercent,
      SplitMode.byAmount => l10n.expenseSplitAmount,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final evenly = _d.mode == SplitMode.evenly;
    final colors = participantColors(_d.group.participants, _d.activeUserId);
    final problem = _d.problem();
    final message = problem == null ? _hint(context) : problemTextOf(context, problem);
    final pill = SegmentedPill<SplitMode>(
      segments: {for (final mode in SplitMode.values) mode: _modeName(context, mode)},
      selected: _d.mode,
      tapPadding: const EdgeInsets.only(top: 1, bottom: 12),
      onChanged: (mode) {
        FocusScope.of(context).unfocus();
        setState(() => _d.mode = mode);
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: pill),
        const SizedBox(height: 4),
        for (final (i, p) in _d.group.participants.indexed) ...[
          if (i > 0) const GroupedDivider(indent: ChoiceRow.monogramIndent),
          _row(context, p, colors[p.id] ?? monogramPalette.first, evenly),
        ],
        if (message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(message,
                style: GroupedSection.footnoteStyle(context,
                    color: problem == null ? null : theme.colorScheme.error)),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, Participant p, Color color, bool evenly) {
    final theme = Theme.of(context);
    final included = _d.isIncluded(p.id);
    final name = Text(participantName(context, p, _d.activeUserId),
        style: theme.textTheme.bodyLarge
            ?.copyWith(color: included ? null : theme.colorScheme.onSurface.withValues(alpha: 0.4)));
    final monogram = Opacity(
        opacity: included ? 1 : 0.4,
        child: Monogram(name: p.name, color: color, radius: 12));
    Widget layout(Widget name, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: GroupedRow.oneLineMinHeight),
            child: LabelAndValue(
              label: MonogramLabel(monogram: monogram, name: name, nameStyle: theme.textTheme.bodyLarge),
              value: value,
              gap: 12,
              runGap: 6,
            ),
          ),
        );
    if (evenly) {
      return Semantics(
        checked: included,
        child: InkWell(
          onTap: () => setState(() => _d.setIncluded(p.id, !included)),
          child: layout(
            name,
            Visibility.maintain(
                visible: included,
                child: Icon(Icons.check, color: theme.colorScheme.primary)),
          ),
        ),
      );
    }
    return InlineNumberField(
      fieldKey: widget.valueKey(p.id),
      controller: _d.controllers[p.id]!,
      name: context.l10n.expenseFieldName(p.name, _modeName(context, _d.mode)),
      prefix: _d.mode == SplitMode.byAmount ? '${_d.group.currency} ' : null,
      suffix: _d.mode == SplitMode.byPercentage ? '%' : null,
      contentPadding: EdgeInsets.zero,
      row: (context, field) => layout(ExcludeSemantics(child: name), field),
    );
  }

  /// What's still to allocate, or the mode's own explanation.
  String? _hint(BuildContext context) {
    final l10n = context.l10n;
    final unallocated = _d.unallocated();
    if (unallocated != null && unallocated != 0) {
      final over = unallocated < 0;
      final magnitude = unallocated.abs();
      if (_d.mode == SplitMode.byPercentage) {
        final formatted = trimTrailingZeros(magnitude);
        return over ? l10n.expensePercentOver(formatted) : l10n.expensePercentRemaining(formatted);
      }
      final formatted = formatMoney(toMinorUnits(magnitude, _d.digits), _d.group.currency,
          decimalDigits: _d.digits, locale: context.appLocale);
      return over ? l10n.expenseAmountOver(formatted) : l10n.expenseAmountRemaining(formatted);
    }
    return switch (_d.mode) {
      SplitMode.evenly => l10n.expenseHintEvenly,
      SplitMode.byShares => l10n.expenseHintShares,
      SplitMode.byPercentage => l10n.expenseHintPercentage,
      SplitMode.byAmount => l10n.expenseHintAmount,
    };
  }

  /// A split problem in words, as the expense's own card says it (#260).
  String problemTextOf(BuildContext context, SplitProblem problem) =>
      SplitDraftFields.problemText(context, problem, symbol: _d.group.currency, digits: _d.digits);
}

/// The sheet that edits one line: what it was, the unit price and how many,
/// and who shares it. Answers false when the line is to be removed.
Future<bool?> showItemSheet(BuildContext context, {required ItemDraft item}) =>
    showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ItemSheet(item: item),
    );

class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.item});

  final ItemDraft item;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  final _titleFocus = FocusNode();

  /// The fields this sheet redraws as they're typed: the two that work out
  /// the total, and every split value.
  final _watched = <TextEditingController>[];

  @override
  void initState() {
    super.initState();
    _watched.addAll([
      widget.item.unitPriceController,
      widget.item.quantityController,
      ...widget.item.split.fields,
    ]);
    for (final c in _watched) {
      c.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in _watched) {
      c.removeListener(_changed);
    }
    _titleFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final item = widget.item;
    final total = item.amountCents;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitle(l10n.expenseItemSheetTitle),
            GroupedSection(
              margin: const EdgeInsets.symmetric(horizontal: GroupedSection.inset),
              children: [
                _field(
                  context,
                  child: TextFormField(
                    key: const ValueKey('itemSheet.title'),
                    controller: item.titleController,
                    focusNode: _titleFocus,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(labelText: l10n.expenseItemTitle),
                  ),
                ),
                formFieldRow(
                  context,
                  formLabel(context, l10n.expenseItemUnitPrice),
                  InlineNumberField(
                    fieldKey: const ValueKey('itemSheet.unitPrice'),
                    controller: item.unitPriceController,
                    name: l10n.expenseItemUnitPrice,
                    prefix: '${item.group.currency} ',
                  ),
                ),
                formFieldRow(
                  context,
                  formLabel(context, l10n.expenseItemQuantity),
                  InlineNumberField(
                    fieldKey: const ValueKey('itemSheet.quantity'),
                    controller: item.quantityController,
                    name: l10n.expenseItemQuantity,
                  ),
                ),
                GroupedRow(
                  title: formLabel(context, l10n.expenseItemTotal),
                  value: Text(
                    total == null
                        ? '—'
                        : formatMoney(total, item.group.currency,
                            decimalDigits: item.digits, locale: context.appLocale),
                    style: formValueStyle(context),
                  ),
                ),
              ],
            ),
            GroupedSection(
              margin: const EdgeInsets.symmetric(horizontal: GroupedSection.inset),
              caption: l10n.expenseItemSharedBy,
              dividerIndent: ChoiceRow.monogramIndent,
              children: [SplitDraftFields(draft: item.split, fieldPrefix: 'itemSheet')],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 8, GroupedSection.inset, 0),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l10n.expenseItemRemove),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(l10n.commonDone),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _field(BuildContext context, {required Widget child}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: child,
      );
}

/// The sheet that says how the leftover is shared.
Future<void> showLeftoverSheet(BuildContext context, SplitDraft draft) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitle(context.l10n.expenseItemsLeftover),
              GroupedSection(
                margin: const EdgeInsets.symmetric(horizontal: GroupedSection.inset),
                dividerIndent: ChoiceRow.monogramIndent,
                children: [SplitDraftFields(draft: draft, fieldPrefix: 'leftover')],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 12, GroupedSection.inset, 24),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.commonDone),
                ),
              ),
            ],
          ),
        ),
      ),
    );

/// One item in the card's list: its name, and what it comes to.
class ItemRow extends StatelessWidget {
  const ItemRow({super.key, required this.item, required this.onTap});

  final ItemDraft item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final amount = item.amountCents;
    final quantity = item.quantityMilli;
    final unit = item.unitPriceCents;
    final showBreakdown = quantity != null && quantity != 1000 && unit != null;
    return GroupedRow(
      title: Text(
        item.hasTitle ? item.titleController.text.trim() : l10n.expenseItemNew,
        style: item.hasTitle ? null : TextStyle(color: SpliitColors.of(context).secondaryContent),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: showBreakdown
          ? Text(l10n.expenseItemQuantityTimes(trimTrailingZeros(quantity / 1000),
              formatMoney(unit, item.group.currency, decimalDigits: item.digits, locale: context.appLocale)))
          : null,
      value: Text(
        amount == null
            ? '—'
            : formatMoney(amount, item.group.currency, decimalDigits: item.digits, locale: context.appLocale),
        style: formValueStyle(context)?.copyWith(
            color: amount == null ? theme.colorScheme.error : null),
      ),
      navigates: true,
      onTap: onTap,
    );
  }
}

/// "Itemise this expense", the switch that turns the lines on.
class ItemizeSwitchRow extends StatelessWidget {
  const ItemizeSwitchRow({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: GroupedRow(
          title: Text(context.l10n.expenseItemize),
          subtitle: Text(context.l10n.expenseItemizeHint),
          value: AppSwitch(value: value, onChanged: onChanged),
          onTap: () => onChanged(!value),
        ),
      );
}

