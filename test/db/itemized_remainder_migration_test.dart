import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/models/expense.dart';

// Schema 23 keeps an itemized expense's leftover, so an edit round-trips it.
void main() {
  test('a schema 22 database keeps its items, with no leftover of its own', () async {
    final dir = await Directory.systemTemp.createTemp('itemized_remainder_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // Schema 22 is today's without the column.
    final current = AppDatabase(NativeDatabase(file));
    await current.replaceServerExpenses('g1', [
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 3000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        items: const [
          ExpenseItem(
              id: 'i1',
              title: 'Starter',
              amountCents: 1000,
              unitPriceCents: 1000,
              splitMode: SplitMode.evenly,
              paidFor: [ExpenseShare(participantId: 'p1', shares: 1)]),
        ],
        itemizedRemainder:
            const ExpenseItemizedRemainder(paidFor: [ExpenseShare(participantId: 'p1', shares: 1)]),
        date: DateTime(2026, 10, 1),
      ),
    ]);
    await current.customStatement('ALTER TABLE expenses DROP COLUMN itemized_remainder_json');
    await current.customStatement('PRAGMA user_version = 22');
    await current.close();

    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final expense = migrated.rowToExpense((await migrated.expensesForGroup('g1')).single);
    expect(expense.title, 'Dinner');
    // The items were already stored; the leftover is new, so it's gone.
    expect(expense.items.single.title, 'Starter');
    expect(expense.itemizedRemainder, isNull);
  });

  test('items and the leftover are cached and read back', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 3000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        items: const [
          ExpenseItem(
            id: 'i1',
            title: 'Starter',
            amountCents: 1000,
            unitPriceCents: 500,
            quantityMilli: 2000,
            splitMode: SplitMode.byShares,
            paidFor: [
              ExpenseShare(participantId: 'p1', shares: 300),
              ExpenseShare(participantId: 'p2', shares: 100),
            ],
          ),
        ],
        itemizedRemainder: const ExpenseItemizedRemainder(
          splitMode: SplitMode.byPercentage,
          allocationMode: 'CUSTOM',
          paidFor: [ExpenseShare(participantId: 'p1', shares: 6000)],
        ),
        date: DateTime(2026, 10, 1),
      ),
    ]);

    final expense = db.rowToExpense((await db.expensesForGroup('g1')).single);
    final item = expense.items.single;
    expect((item.title, item.amountCents, item.unitPriceCents, item.quantityMilli),
        ('Starter', 1000, 500, 2000));
    expect(item.splitMode, SplitMode.byShares);
    expect(item.paidFor.map((s) => (s.participantId, s.shares)), [('p1', 300), ('p2', 100)]);
    final remainder = expense.itemizedRemainder!;
    expect(remainder.splitMode, SplitMode.byPercentage);
    expect(remainder.allocationMode, 'CUSTOM');
    expect(remainder.paidFor.single.participantId, 'p1');
    expect(remainder.paidFor.single.shares, 6000);
  });
}
