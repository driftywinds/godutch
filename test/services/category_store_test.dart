import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:godutch/api/spliit_client.dart';
import 'package:godutch/db/app_database.dart';
import 'package:godutch/models/category.dart';
import 'package:godutch/services/category_store.dart';

// Issue #132: categories work offline. On Spliit Cloud they're defined in
// code, so the store is the same list everywhere, with no read to fail.
void main() {
  late AppDatabase db;
  late SpliitClient client;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    client = SpliitClient(baseUrl: 'https://spliit.test');
  });
  tearDown(() => db.close());

  List<int> ids(List<Category> cs) => [for (final c in cs) c.id];

  test('the store offers the code-defined Cloud categories', () async {
    final store = CategoryStore(db);
    expect(ids(await store.current(client)), ids(cloudCategories));
    expect(ids(await store.watch(client).first), ids(cloudCategories));
  });

  test('refreshing changes nothing and needs no network', () async {
    final store = CategoryStore(db);
    await store.refresh(client);
    await store.refresh(client, force: true);
    expect(ids(await store.current(client)), ids(cloudCategories));
  });
}
