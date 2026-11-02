import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../l10n/context_l10n.dart';
import '../models/group.dart';
import '../services/error_reporting.dart';
import '../utils/money.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/error_message.dart';
import '../widgets/grouped_section.dart';

/// The group's budgets as Cloud computes them. Budgets are created and
/// edited on the web; this is the read-only mobile view of the same
/// period spend, limits and trend.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({
    super.key,
    required this.client,
    required this.group,
  });

  final SpliitClient client;
  final Group group;

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  List<CloudBudget> _budgets = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final budgets = await widget.client.fetchBudgets(widget.group.id);
      if (!mounted) return;
      setState(() {
        _budgets = budgets;
        _loading = false;
      });
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Loading group budgets');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.kind == ErrorKind.connection
            ? context.l10n.errorConnection
            : context.l10n.budgetsLoadFailed;
      });
    }
  }

  String _money(int minor) => formatMoney(minor, widget.group.currency,
      decimalDigits: widget.group.decimalDigits, locale: Localizations.localeOf(context));

  String _period(CloudBudget budget) => switch (budget.periodType) {
        'WEEKLY' => context.l10n.budgetsWeekly,
        'YEARLY' => context.l10n.budgetsYearly,
        'CUSTOM' => context.l10n.budgetsCustom,
        _ => context.l10n.budgetsMonthly,
      };

  @override
  Widget build(BuildContext context) {
    final active = _budgets.where((b) => !b.archived).toList();
    final archived = _budgets.where((b) => b.archived).toList();
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.budgetsTitle)),
      body: AboveBottomBar(
        child: GroupedScrollClip(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: ErrorMessage(_error!),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_budgets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(context.l10n.budgetsEmpty,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant)),
                  )
                else ...[
                  if (active.isNotEmpty)
                    GroupedSection(
                      caption: context.l10n.groupListActive,
                      children: [
                        for (final budget in active) _budgetTile(budget),
                      ],
                    ),
                  if (archived.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    GroupedSection(
                      caption: context.l10n.groupListArchived,
                      children: [
                        for (final budget in archived) _budgetTile(budget),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _budgetTile(CloudBudget budget) {
    final theme = Theme.of(context);
    final over = budget.remaining < 0 || budget.trendStatus == 'OVER';
    final color = over ? theme.colorScheme.error : theme.colorScheme.primary;
    final ratio = (budget.percentage / 100).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(budget.name,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text(_period(budget),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.budgetsSpentOf(
                      _money(budget.used), _money(budget.amount)),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Text(
                over
                    ? context.l10n.budgetsOver(_money(budget.used - budget.amount))
                    : context.l10n.budgetsRemaining(_money(budget.remaining)),
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
          ),
          if (budget.lifecycle == 'ACTIVE' && budget.daysRemaining > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                context.l10n.budgetsDaysLeft(budget.daysRemaining),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
