import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../theme.dart';
import '../../utils/money.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/group_monogram.dart';
import '../../widgets/money.dart';
import '../../widgets/participant_colors.dart';
import '../../widgets/participant_sheet.dart';
import 'expense_form_model.dart';
import 'form_text.dart';
import 'item_draft.dart';
import 'item_sheet.dart';

/// An expense's line items: the switch that makes it itemized, and the lines
/// themselves with what they come to and what they leave over.
///
/// The card is always there for an expense, so itemizing can be turned on; a
/// settlement has none (a settlement says what each person received, not
/// what was bought).
class ItemsCard extends StatelessWidget {
  const ItemsCard({super.key, required this.model, this.showErrors = false, this.footerKey});

  final ExpenseFormModel model;

  /// A save was tried: what's wrong with the lines is said in red.
  final bool showErrors;

  /// On what the lines say, for a refused save to scroll to.
  final Key? footerKey;

  ExpenseFormModel get _m => model;

  static const addKey = ValueKey('itemsCard.add');
  static const leftoverKey = ValueKey('itemsCard.leftover');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final itemized = _m.isItemized;
    final total = _m.itemsTotalCents;
    final left = _m.remainderCents;
    final problem = showErrors ? _m.itemizedProblem() : null;
    final message = problem == null ? _summary(context, total, left) : problemText(context, _m);
    final errorColor = problem != null ? theme.colorScheme.error : null;
    return GroupedSection(
      margin: const EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset, GroupedSection.spacing),
      caption: itemized ? l10n.expenseItemsCaption : null,
      children: [
        ItemizeSwitchRow(
          value: itemized,
          onChanged: (on) {
            FocusScope.of(context).unfocus();
            _m.setItemized(on);
          },
        ),
        if (itemized) ...[
          for (final item in _m.items) ...[
            const GroupedDivider(),
            ItemRow(item: item, onTap: () => _edit(context, item)),
          ],
          const GroupedDivider(),
          GroupedRow(
            key: addKey,
            leading: Icon(Icons.add, color: theme.colorScheme.primary),
            title: Text(l10n.expenseItemsAdd, style: TextStyle(color: theme.colorScheme.primary)),
            onTap: () => _edit(context, _m.addItem()),
          ),
          if (left != null && left > 0) ...[
            const GroupedDivider(),
            GroupedRow(
              key: leftoverKey,
              title: formLabel(context, l10n.expenseItemsLeftover),
              value: Text(
                formatMoney(left, _m.group.currency, decimalDigits: _m.digits, locale: context.appLocale),
                style: formValueStyle(context),
              ),
              navigates: true,
              onTap: () => showLeftoverSheet(context, _m.remainderSplit),
            ),
          ],
          Padding(
            key: footerKey,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(message,
                style: GroupedSection.footnoteStyle(context, color: errorColor)),
          ),
        ],
      ],
    );
  }

  Future<void> _edit(BuildContext context, ItemDraft item) async {
    final removed = await showItemSheet(context, item: item);
    if (removed == false) _m.removeItem(item);
  }

  /// Under the card: what the lines come to, and what they leave.
  String _summary(BuildContext context, int? total, int? left) {
    final l10n = context.l10n;
    final formatted = total == null
        ? '—'
        : formatMoney(total, _m.group.currency, decimalDigits: _m.digits, locale: context.appLocale);
    if (left == null) return l10n.expenseItemsSum(formatted);
    if (left < 0) {
      return l10n.expenseItemsOver(
          formatMoney(-left, _m.group.currency, decimalDigits: _m.digits, locale: context.appLocale));
    }
    if (left == 0) return l10n.expenseItemsExact;
    return '${l10n.expenseItemsSum(formatted)} · ${l10n.expenseItemsLeftoverAmount(
        formatMoney(left, _m.group.currency, decimalDigits: _m.digits, locale: context.appLocale))}';
  }

  /// What a refused save says about the lines, in words (#263).
  static String problemText(BuildContext context, ExpenseFormModel model) {
    final l10n = context.l10n;
    String splitProblem(SplitProblem it, int index) => switch (it) {
          NoOneIncluded() => l10n.expenseItemNotIncluded(index + 1),
          _ => SplitDraftFields.problemFor(context, model.items[index].split, it),
        };
    return switch (model.itemizedProblem()) {
      null => '',
      NoItems() => l10n.expenseItemsAdd,
      ItemUnfinished(:final index, :final fault, :final split) => switch (fault) {
          ItemFault.name => l10n.expenseItemNeedsName(index + 1),
          ItemFault.price => l10n.expenseItemNeedsPrice(index + 1),
          ItemFault.split => splitProblem(split!, index),
        },
      ItemsExceedTotal(:final overBy) => l10n.expenseItemsOver(
          formatMoney(overBy, model.group.currency, decimalDigits: model.digits, locale: context.appLocale)),
      LeftoverProblem(:final problem) => SplitDraftFields.problemFor(context, model.remainderSplit, problem),
    };
  }
}

/// What an itemized expense comes to for each person, as its lines work it
/// out: the payer row, then everyone's share. There's nothing to edit here --
/// the lines are the split.
class ItemizedSplitCard extends StatelessWidget {
  const ItemizedSplitCard({super.key, required this.model, this.payer});

  final ExpenseFormModel model;
  final Widget? payer;

  ExpenseFormModel get _m => model;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = participantColors(_m.group.participants, _m.activeUserId);
    final shares = _m.paidFor();
    return GroupedSection(
      caption: l10n.expenseItemsSplitHeading,
      dividerIndent: ChoiceRow.monogramIndent,
      children: [
        if (payer case final payer?) payer,
        for (final share in shares ?? const [])
          GroupedRow(
            title: MonogramLabel(
              monogram: Monogram(
                name: _nameOf(share.participantId),
                color: colors[share.participantId] ?? monogramPalette.first,
                radius: 12,
              ),
              name: Text(_nameOf(share.participantId)),
            ),
            value: Money(formatMoney(share.shares, _m.group.currency,
                decimalDigits: _m.digits, locale: context.appLocale)),
          ),
      ],
    );
  }

  String _nameOf(String participantId) {
    final participant = _m.group.participants.where((p) => p.id == participantId).firstOrNull;
    return participant?.name ?? participantId;
  }
}

