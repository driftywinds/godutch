import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/category.dart';

/// Expense categories, available offline (#132).
///
/// Spliit Cloud's categories are defined in code (`cloudCategories`, in
/// `models/category.dart`): every instance has the same list, under the same
/// slug ids, and a server read can't add to or reorder it. So there is
/// nothing to fetch or cache -- the list is always here, and works offline
/// by construction. The class keeps the small interface the screens use.
class CategoryStore {
  CategoryStore(this.db);

  final AppDatabase db;

  static final _byDb = Expando<CategoryStore>('CategoryStore');

  /// The store for [db], shared by every screen using it.
  static CategoryStore of(AppDatabase db) => _byDb[db] ??= CategoryStore(db);

  /// Every category, in the order the app shows them. Follows every change
  /// (there are none: a stream so call sites stay live-ready).
  Stream<List<Category>> watch(SpliitClient client) => Stream.value(cloudCategories);

  /// Every category as they are now; see [watch].
  Future<List<Category>> current(SpliitClient client) async => cloudCategories;

  /// Kept for the call sites' sake: there is no server list to read. A
  /// future user-defined category list would fetch here.
  Future<void> refresh(SpliitClient client, {bool force = false}) async {}
}
