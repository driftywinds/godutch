import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/models/expense.dart';
import 'package:godutch/services/expense_shares.dart';

Expense expense({
  required int amountCents,
  required SplitMode splitMode,
  required List<ExpenseShare> paidFor,
  String splitModeTag = '',
  List<ExpenseShare> paidByList = const [],
  SplitMode paidBySplitMode = SplitMode.byAmount,
  String paidBy = 'p1',
  int? originalAmountCents,
  String? originalCurrency,
  double? conversionRate,
  List<ExpenseItem> items = const [],
}) =>
    Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Lunch',
      amountCents: amountCents,
      paidBy: paidBy,
      paidFor: paidFor,
      splitMode: splitMode,
      splitModeTag: splitModeTag,
      paidByList: paidByList,
      paidBySplitMode: paidBySplitMode,
      date: DateTime(2026, 11, 3),
      originalAmountCents: originalAmountCents,
      originalCurrency: originalCurrency,
      conversionRate: conversionRate,
      items: items,
    );

void main() {
  test('an itemized expense\'s amounts are read as stored, not split evenly', () {
    final e = expense(
      amountCents: 3000,
      splitMode: SplitMode.byAmount,
      splitModeTag: 'ITEMIZED',
      paidFor: const [
        ExpenseShare(participantId: 'p1', shares: 1000),
        ExpenseShare(participantId: 'p2', shares: 2000),
      ],
    );
    expect(expenseShareCents(e), {'p1': 1000, 'p2': 2000});
  });

  test('a converted expense\'s stored shares are scaled into the group currency', () {
    // €100 at 1.1 is $110; Cloud keeps the amount-based shares in euros.
    final e = expense(
      amountCents: 11000,
      splitMode: SplitMode.byAmount,
      paidFor: const [
        ExpenseShare(participantId: 'p1', shares: 4000),
        ExpenseShare(participantId: 'p2', shares: 6000),
      ],
      originalAmountCents: 10000,
      originalCurrency: 'EUR',
      conversionRate: 1.1,
    );
    expect(expenseShareCents(e), {'p1': 4400, 'p2': 6600});
  });

  test('a converted itemized expense scales its stored amounts too', () {
    final e = expense(
      amountCents: 11000,
      splitMode: SplitMode.byAmount,
      splitModeTag: 'ITEMIZED',
      paidFor: const [
        ExpenseShare(participantId: 'p1', shares: 2500),
        ExpenseShare(participantId: 'p2', shares: 7500),
      ],
      originalAmountCents: 10000,
      originalCurrency: 'EUR',
      conversionRate: 1.1,
    );
    expect(expenseShareCents(e), {'p1': 2750, 'p2': 8250});
  });

  test('a percentage split is not scaled by the conversion', () {
    final e = expense(
      amountCents: 11000,
      splitMode: SplitMode.byPercentage,
      paidFor: const [
        ExpenseShare(participantId: 'p1', shares: 1000),
        ExpenseShare(participantId: 'p2', shares: 9000),
      ],
      originalAmountCents: 10000,
      originalCurrency: 'EUR',
      conversionRate: 1.1,
    );
    expect(expenseShareCents(e), {'p1': 1100, 'p2': 9900});
  });

  test('a converted expense\'s payer shares are scaled into the group currency', () {
    final e = expense(
      amountCents: 11000,
      splitMode: SplitMode.evenly,
      paidFor: const [
        ExpenseShare(participantId: 'p1', shares: 1),
        ExpenseShare(participantId: 'p2', shares: 4000),
      ],
      paidByList: const [
        ExpenseShare(participantId: 'p1', shares: 10000),
      ],
      originalAmountCents: 10000,
      originalCurrency: 'EUR',
      conversionRate: 1.1,
    );
    expect(expensePaidCents(e), {'p1': 11000});
  });

  test('the scaling keeps the total exact across rounding', () {
    final e = expense(
      amountCents: 10000,
      splitMode: SplitMode.byAmount,
      paidFor: const [
        ExpenseShare(participantId: 'p1', shares: 3333),
        ExpenseShare(participantId: 'p2', shares: 3333),
        ExpenseShare(participantId: 'p3', shares: 3334),
      ],
      originalAmountCents: 9999,
      originalCurrency: 'EUR',
      conversionRate: 1.0,
    );
    final shares = expenseShareCents(e);
    expect(shares.values.fold<int>(0, (a, b) => a + b), 10000);
  });
}
