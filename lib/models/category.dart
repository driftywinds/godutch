/// One entry from Spliit's `categories.list` -- id, display name, and
/// which [grouping] it's filed under (e.g. "Food and Drink", "Home",
/// "Transportation"). The server's list is already grouped/ordered
/// sensibly (same grouping's categories are adjacent), so callers that
/// want a grouped picker (issue #19) don't need to re-sort, just fold
/// consecutive same-grouping entries into sections.
class Category {
  final int id;
  final String name;
  final String grouping;

  const Category({required this.id, required this.name, required this.grouping});

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: (json['id'] as num).round(),
        name: json['name'] as String,
        // A server predating the grouping column, or one that omits it
        // for some reason, still gets a usable (if flat) picker rather
        // than a crash -- falls back to a single catch-all section.
        grouping: json['grouping'] as String? ?? 'Other',
      );
}

/// The categories every Spliit instance starts with (#132): seeded by
/// its migrations with fixed ids, so "Groceries" is 9 on spliit.app and
/// on a self-hosted instance alike (spliit-ios relies on the same,
/// `CategoryEntity.swift`). Used for a server whose own list this device
/// hasn't read yet, so the picker works offline from the first launch.
///
/// Spliit cc796210, in `categories.list`'s order (by id):
/// prisma/migrations/20240108194443_add_categories and
/// 20250308000000_add_category_donation (43, Donation, filed under Life).
const spliitSeedCategories = <Category>[
  Category(id: 0, grouping: 'Uncategorized', name: 'General'),
  Category(id: 1, grouping: 'Uncategorized', name: 'Payment'),
  Category(id: 2, grouping: 'Entertainment', name: 'Entertainment'),
  Category(id: 3, grouping: 'Entertainment', name: 'Games'),
  Category(id: 4, grouping: 'Entertainment', name: 'Movies'),
  Category(id: 5, grouping: 'Entertainment', name: 'Music'),
  Category(id: 6, grouping: 'Entertainment', name: 'Sports'),
  Category(id: 7, grouping: 'Food and Drink', name: 'Food and Drink'),
  Category(id: 8, grouping: 'Food and Drink', name: 'Dining Out'),
  Category(id: 9, grouping: 'Food and Drink', name: 'Groceries'),
  Category(id: 10, grouping: 'Food and Drink', name: 'Liquor'),
  Category(id: 11, grouping: 'Home', name: 'Home'),
  Category(id: 12, grouping: 'Home', name: 'Electronics'),
  Category(id: 13, grouping: 'Home', name: 'Furniture'),
  Category(id: 14, grouping: 'Home', name: 'Household Supplies'),
  Category(id: 15, grouping: 'Home', name: 'Maintenance'),
  Category(id: 16, grouping: 'Home', name: 'Mortgage'),
  Category(id: 17, grouping: 'Home', name: 'Pets'),
  Category(id: 18, grouping: 'Home', name: 'Rent'),
  Category(id: 19, grouping: 'Home', name: 'Services'),
  Category(id: 20, grouping: 'Life', name: 'Childcare'),
  Category(id: 21, grouping: 'Life', name: 'Clothing'),
  Category(id: 22, grouping: 'Life', name: 'Education'),
  Category(id: 23, grouping: 'Life', name: 'Gifts'),
  Category(id: 24, grouping: 'Life', name: 'Insurance'),
  Category(id: 25, grouping: 'Life', name: 'Medical Expenses'),
  Category(id: 26, grouping: 'Life', name: 'Taxes'),
  Category(id: 27, grouping: 'Transportation', name: 'Transportation'),
  Category(id: 28, grouping: 'Transportation', name: 'Bicycle'),
  Category(id: 29, grouping: 'Transportation', name: 'Bus/Train'),
  Category(id: 30, grouping: 'Transportation', name: 'Car'),
  Category(id: 31, grouping: 'Transportation', name: 'Gas/Fuel'),
  Category(id: 32, grouping: 'Transportation', name: 'Hotel'),
  Category(id: 33, grouping: 'Transportation', name: 'Parking'),
  Category(id: 34, grouping: 'Transportation', name: 'Plane'),
  Category(id: 35, grouping: 'Transportation', name: 'Taxi'),
  Category(id: 36, grouping: 'Utilities', name: 'Utilities'),
  Category(id: 37, grouping: 'Utilities', name: 'Cleaning'),
  Category(id: 38, grouping: 'Utilities', name: 'Electricity'),
  Category(id: 39, grouping: 'Utilities', name: 'Heat/Gas'),
  Category(id: 40, grouping: 'Utilities', name: 'Trash'),
  Category(id: 41, grouping: 'Utilities', name: 'TV/Phone/Internet'),
  Category(id: 42, grouping: 'Utilities', name: 'Water'),
  Category(id: 43, grouping: 'Life', name: 'Donation'),
];

/// Spliit Cloud's in-code category list (`packages/domain/src/categories.ts`).
///
/// The cloud has no `categories.list` procedure: category ids are stable
/// English slugs and descriptions live in code. The app keeps its own
/// integer ids (for icons, translations, and the existing cache schema),
/// so each cloud id is mapped to the same int the old Spliit category had
/// where the names match, and to a new int for the categories the fork
/// added. [Expense.categoryId] keeps the cloud slug, which is what writes
/// to the API; [Expense.category] keeps the int for display.
const cloudCategories = <Category>[
  Category(id: 44, grouping: 'Uncategorized', name: 'Uncategorized'),
  Category(id: 0, grouping: 'Uncategorized', name: 'General'),
  Category(id: 1, grouping: 'Uncategorized', name: 'Payment'),
  Category(id: 45, grouping: 'Income', name: 'Income'),
  // `settlement` is deliberately not in the picker: the form's settlement
  // toggle owns that category (its amounts mean "paid to", not "spent").
  Category(id: 2, grouping: 'Entertainment', name: 'Entertainment'),
  Category(id: 3, grouping: 'Entertainment', name: 'Games'),
  Category(id: 4, grouping: 'Entertainment', name: 'Movies'),
  Category(id: 5, grouping: 'Entertainment', name: 'Music'),
  Category(id: 6, grouping: 'Entertainment', name: 'Sports'),
  Category(id: 7, grouping: 'Food and Drink', name: 'Food and Drink'),
  Category(id: 8, grouping: 'Food and Drink', name: 'Dining Out'),
  Category(id: 9, grouping: 'Food and Drink', name: 'Groceries'),
  Category(id: 10, grouping: 'Food and Drink', name: 'Liquor'),
  Category(id: 11, grouping: 'Home', name: 'Home'),
  Category(id: 12, grouping: 'Home', name: 'Electronics'),
  Category(id: 13, grouping: 'Home', name: 'Furniture'),
  Category(id: 14, grouping: 'Home', name: 'Household Supplies'),
  Category(id: 15, grouping: 'Home', name: 'Maintenance'),
  Category(id: 16, grouping: 'Home', name: 'Mortgage'),
  Category(id: 47, grouping: 'Home', name: 'Gardening'),
  Category(id: 17, grouping: 'Home', name: 'Pets'),
  Category(id: 48, grouping: 'Home', name: 'Plants'),
  Category(id: 18, grouping: 'Home', name: 'Rent'),
  Category(id: 19, grouping: 'Home', name: 'Services'),
  Category(id: 56, grouping: 'Life', name: 'Life'),
  Category(id: 20, grouping: 'Life', name: 'Childcare'),
  Category(id: 21, grouping: 'Life', name: 'Clothing'),
  Category(id: 22, grouping: 'Life', name: 'Education'),
  Category(id: 23, grouping: 'Life', name: 'Gifts'),
  Category(id: 24, grouping: 'Life', name: 'Insurance'),
  Category(id: 25, grouping: 'Life', name: 'Medical Expenses'),
  Category(id: 26, grouping: 'Life', name: 'Taxes'),
  Category(id: 43, grouping: 'Life', name: 'Donation'),
  Category(id: 27, grouping: 'Transportation', name: 'Transportation'),
  Category(id: 28, grouping: 'Transportation', name: 'Bicycle'),
  Category(id: 29, grouping: 'Transportation', name: 'Bus/Train'),
  Category(id: 30, grouping: 'Transportation', name: 'Car'),
  Category(id: 31, grouping: 'Transportation', name: 'Gas/Fuel'),
  Category(id: 32, grouping: 'Transportation', name: 'Hotel'),
  Category(id: 33, grouping: 'Transportation', name: 'Parking'),
  Category(id: 34, grouping: 'Transportation', name: 'Plane'),
  Category(id: 35, grouping: 'Transportation', name: 'Taxi'),
  Category(id: 49, grouping: 'Transportation', name: 'Tolls'),
  Category(id: 36, grouping: 'Utilities', name: 'Utilities'),
  Category(id: 37, grouping: 'Utilities', name: 'Cleaning'),
  Category(id: 38, grouping: 'Utilities', name: 'Electricity'),
  Category(id: 39, grouping: 'Utilities', name: 'Heat/Gas'),
  Category(id: 40, grouping: 'Utilities', name: 'Trash'),
  Category(id: 41, grouping: 'Utilities', name: 'TV/Phone/Internet'),
  Category(id: 42, grouping: 'Utilities', name: 'Water'),
  Category(id: 50, grouping: 'Social and Activities', name: 'Social and Activities'),
  Category(id: 51, grouping: 'Social and Activities', name: 'Events and Activities'),
  Category(id: 52, grouping: 'Subscriptions and Memberships', name: 'Subscriptions and Memberships'),
  Category(id: 53, grouping: 'Subscriptions and Memberships', name: 'Digital Subscriptions'),
  Category(id: 54, grouping: 'Subscriptions and Memberships', name: 'Memberships'),
  Category(id: 55, grouping: 'Personal Care and Wellness', name: 'Personal Care and Wellness'),
];

/// The categories the cloud exposes in its list, keyed by their cloud slug.
const Map<String, Category> cloudCategoriesById = {
  'uncategorized': Category(id: 44, grouping: 'Uncategorized', name: 'Uncategorized'),
  'general': Category(id: 0, grouping: 'Uncategorized', name: 'General'),
  'payment': Category(id: 1, grouping: 'Uncategorized', name: 'Payment'),
  'income': Category(id: 45, grouping: 'Income', name: 'Income'),
  'settlement': Category(id: 46, grouping: 'Settlement', name: 'Settlement'),
  'entertainment': Category(id: 2, grouping: 'Entertainment', name: 'Entertainment'),
  'games': Category(id: 3, grouping: 'Entertainment', name: 'Games'),
  'movies': Category(id: 4, grouping: 'Entertainment', name: 'Movies'),
  'music': Category(id: 5, grouping: 'Entertainment', name: 'Music'),
  'sports': Category(id: 6, grouping: 'Entertainment', name: 'Sports'),
  'food-and-drink': Category(id: 7, grouping: 'Food and Drink', name: 'Food and Drink'),
  'dining-out': Category(id: 8, grouping: 'Food and Drink', name: 'Dining Out'),
  'groceries': Category(id: 9, grouping: 'Food and Drink', name: 'Groceries'),
  'liquor': Category(id: 10, grouping: 'Food and Drink', name: 'Liquor'),
  'home': Category(id: 11, grouping: 'Home', name: 'Home'),
  'electronics': Category(id: 12, grouping: 'Home', name: 'Electronics'),
  'furniture': Category(id: 13, grouping: 'Home', name: 'Furniture'),
  'household-supplies': Category(id: 14, grouping: 'Home', name: 'Household Supplies'),
  'maintenance': Category(id: 15, grouping: 'Home', name: 'Maintenance'),
  'mortgage': Category(id: 16, grouping: 'Home', name: 'Mortgage'),
  'gardening': Category(id: 47, grouping: 'Home', name: 'Gardening'),
  'pets': Category(id: 17, grouping: 'Home', name: 'Pets'),
  'plants': Category(id: 48, grouping: 'Home', name: 'Plants'),
  'rent': Category(id: 18, grouping: 'Home', name: 'Rent'),
  'services': Category(id: 19, grouping: 'Home', name: 'Services'),
  'life': Category(id: 56, grouping: 'Life', name: 'Life'),
  'childcare': Category(id: 20, grouping: 'Life', name: 'Childcare'),
  'clothing': Category(id: 21, grouping: 'Life', name: 'Clothing'),
  'education': Category(id: 22, grouping: 'Life', name: 'Education'),
  'gifts': Category(id: 23, grouping: 'Life', name: 'Gifts'),
  'insurance': Category(id: 24, grouping: 'Life', name: 'Insurance'),
  'medical-expenses': Category(id: 25, grouping: 'Life', name: 'Medical Expenses'),
  'taxes': Category(id: 26, grouping: 'Life', name: 'Taxes'),
  'donation': Category(id: 43, grouping: 'Life', name: 'Donation'),
  'transportation': Category(id: 27, grouping: 'Transportation', name: 'Transportation'),
  'bicycle': Category(id: 28, grouping: 'Transportation', name: 'Bicycle'),
  'bus-train': Category(id: 29, grouping: 'Transportation', name: 'Bus/Train'),
  'car': Category(id: 30, grouping: 'Transportation', name: 'Car'),
  'gas-fuel': Category(id: 31, grouping: 'Transportation', name: 'Gas/Fuel'),
  'hotel': Category(id: 32, grouping: 'Transportation', name: 'Hotel'),
  'parking': Category(id: 33, grouping: 'Transportation', name: 'Parking'),
  'plane': Category(id: 34, grouping: 'Transportation', name: 'Plane'),
  'taxi': Category(id: 35, grouping: 'Transportation', name: 'Taxi'),
  'tolls': Category(id: 49, grouping: 'Transportation', name: 'Tolls'),
  'utilities': Category(id: 36, grouping: 'Utilities', name: 'Utilities'),
  'cleaning': Category(id: 37, grouping: 'Utilities', name: 'Cleaning'),
  'electricity': Category(id: 38, grouping: 'Utilities', name: 'Electricity'),
  'heat-gas': Category(id: 39, grouping: 'Utilities', name: 'Heat/Gas'),
  'trash': Category(id: 40, grouping: 'Utilities', name: 'Trash'),
  'tv-phone-internet': Category(id: 41, grouping: 'Utilities', name: 'TV/Phone/Internet'),
  'water': Category(id: 42, grouping: 'Utilities', name: 'Water'),
  'social-and-activities': Category(id: 50, grouping: 'Social and Activities', name: 'Social and Activities'),
  'events-and-activities': Category(id: 51, grouping: 'Social and Activities', name: 'Events and Activities'),
  'subscriptions-and-memberships': Category(id: 52, grouping: 'Subscriptions and Memberships', name: 'Subscriptions and Memberships'),
  'digital-subscriptions': Category(id: 53, grouping: 'Subscriptions and Memberships', name: 'Digital Subscriptions'),
  'memberships': Category(id: 54, grouping: 'Subscriptions and Memberships', name: 'Memberships'),
  'personal-care-and-wellness': Category(id: 55, grouping: 'Personal Care and Wellness', name: 'Personal Care and Wellness'),
};

const cloudGeneralCategoryId = 'general';
const cloudPaymentCategoryId = 'payment';
const cloudSettlementCategoryId = 'settlement';
const cloudSettlementCategoryLocalId = 46;

/// The app's integer category id for a cloud slug; unknown slugs fall back
/// to General, exactly like the icon fallback.
int localCategoryIdForCloud(String id) => cloudCategoriesById[id]?.id ?? 0;

/// The cloud slug for one of the app's integer category ids; an id this
/// build doesn't know falls back to General.
String cloudCategoryIdForLocal(int id) {
  for (final entry in cloudCategoriesById.entries) {
    if (entry.value.id == id) return entry.key;
  }
  return cloudGeneralCategoryId;
}

/// The [Category] for a cloud slug, or General when it isn't known.
Category cloudCategoryFor(String id) =>
    cloudCategoriesById[id] ?? cloudCategoriesById[cloudGeneralCategoryId]!;

