import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultCategories.dart';

//Initialize default values in database
Future<bool> initializeDefaultDatabase() async {
  //Initialize default categories, but not after a backup load
  if (isDatabaseImportedOnThisSession != true &&
      (await database.getAllCategories()).length <= 0) {
    await createDefaultCategories();
  }

  // Repair invalid Pakistani default category icon filenames from earlier builds
  await repairBrokenDefaultCategoryIcons();

  if ((await database.getAllWallets()).length <= 0) {
    await database.createOrUpdateWallet(
      defaultWallet(),
      customDateTimeModified: DateTime(0),
    );
  }
  return true;
}

Future<void> repairBrokenDefaultCategoryIcons() async {
  const Map<String, String> iconRepairs = {
    'home.png': 'rent.png',
    'savings.png': 'piggy-bank.png',
    'education.png': 'graduation.png',
  };
  for (final entry in iconRepairs.entries) {
    await database.customStatement(
      'UPDATE categories SET icon_name = ? WHERE icon_name = ?',
      [entry.value, entry.key],
    );
  }

  // Update specific utility categories from generic bills.png to distinct icons if untouched
  const Map<String, String> utilityIconRepairs = {
    'Bijli Bill': 'lightning-bolt.png',
    'Gas Bill': 'gas-valve.png',
    'Pani': 'water-tap.png',
    'Mobile Load / Package': 'smartphone.png',
  };
  for (final entry in utilityIconRepairs.entries) {
    await database.customStatement(
      'UPDATE categories SET icon_name = ? WHERE name = ? AND icon_name = ?',
      [entry.value, entry.key, 'bills.png'],
    );
  }
}

Future<bool> createDefaultCategories() async {
  print("Creating default categories");
  for (TransactionCategory category in defaultCategories()) {
    try {
      await database.getCategory(category.categoryPk).$2;
    } catch (e) {
      print(
          e.toString() + " default category does not already exist, creating");
      await database.createOrUpdateCategory(category,
          customDateTimeModified: DateTime(0));
    }
  }
  return true;
}

TransactionWallet defaultWallet() {
  return TransactionWallet(
    walletPk: "0",
    name: "default-account-name".tr(),
    dateCreated: DateTime.now(),
    order: 0,
    currency: getDevicesDefaultCurrencyCode(),
    dateTimeModified: null,
    decimals: 2,
    homePageWidgetDisplay: defaultWalletHomePageWidgetDisplay,
  );
}
