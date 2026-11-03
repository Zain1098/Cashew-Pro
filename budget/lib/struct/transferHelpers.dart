import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:easy_localization/easy_localization.dart';

bool isTransferLeg(Transaction t) {
  if (t.categoryFk != "0") return false;
  if (t.pairedTransactionFk != null && t.pairedTransactionFk!.isNotEmpty) {
    return true;
  }
  final String note = t.note;
  return note.startsWith("transferred-balance".tr()) ||
      note.startsWith("Transferred Balance") ||
      note.contains(" → ") ||
      note.contains(" ← ");
}

String specialCategoryName(Transaction t) {
  return isTransferLeg(t)
      ? "transfer".tr().capitalizeFirstofEach
      : "default-category-account-amount-balancing".tr();
}
