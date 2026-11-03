import 'dart:typed_data';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/transferHelpers.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/outlinedButtonStacked.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/util/saveFile.dart';
import 'package:budget/widgets/util/showDatePicker.dart';
import 'package:drift/drift.dart' as drift;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';

final RegExp _arabicUrduScriptRegex = RegExp(
  r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
);

bool _containsRtlScript(String input) => _arabicUrduScriptRegex.hasMatch(input);

String _primaryCurrencySymbol(AllWallets allWallets) {
  final String? currencyKey =
      allWallets.indexedByPk[appStateSettings["selectedWalletPk"]]?.currency;
  if (currencyKey == null || currencyKey.isEmpty) return "Rs";
  if (currencyKey.toLowerCase() == "pkr") return "Rs";
  final dynamic entry = currenciesJSON[currencyKey.toLowerCase()];
  if (entry != null && entry["Symbol"] != null && entry["Symbol"].toString().isNotEmpty) {
    return entry["Symbol"].toString();
  }
  return currencyKey.toUpperCase();
}

String _walletCurrencySymbol(TransactionWallet wallet) {
  final String? currencyKey = wallet.currency;
  if (currencyKey == null || currencyKey.isEmpty) return "Rs";
  if (currencyKey.toLowerCase() == "pkr") return "Rs";
  final dynamic entry = currenciesJSON[currencyKey.toLowerCase()];
  if (entry != null && entry["Symbol"] != null && entry["Symbol"].toString().isNotEmpty) {
    return entry["Symbol"].toString();
  }
  return currencyKey.toUpperCase();
}

class ExportPDF extends material.StatelessWidget {
  const ExportPDF({super.key});

  Future exportPDF({
    required material.BuildContext boxContext,
    required material.DateTimeRange? dateTimeRange,
    required List<String>? selectedWalletPks,
  }) async {
    await openLoadingPopupTryCatch(() async {
      final material.BuildContext activeContext =
          boxContext.mounted ? boxContext : navigatorKey.currentContext!;
      final DateTime cutoffTomorrow = FinanceDatabase.balanceCutoff();

      final List<TransactionWithCategory> transactions = await database
          .getAllTransactionsWithCategoryWalletBudgetObjectiveSubCategory(
        (tbl) {
          drift.Expression<bool> expr = tbl.paid.equals(true) &
              database.onlyShowBasedOnWalletFks(tbl, selectedWalletPks);
          if (dateTimeRange != null) {
            expr = expr &
                database.onlyShowBasedOnTimeRange(
                  tbl,
                  dateTimeRange.start,
                  dateTimeRange.end,
                  null,
                );
          } else {
            expr = expr & tbl.dateCreated.isSmallerThanValue(cutoffTomorrow);
          }
          return expr;
        },
      );

      if (transactions.isEmpty) {
        openSnackbar(SnackbarMessage(
          title: "no-transactions-within-time-range".tr().capitalizeFirstofEach,
          icon: appStateSettings["outlinedIcons"]
              ? material.Icons.warning_outlined
              : material.Icons.warning_rounded,
        ));
        return;
      }

      final AllWallets allWallets =
          Provider.of<AllWallets>(activeContext, listen: false);
      final String primarySymbol = _primaryCurrencySymbol(allWallets);
      final NumberFormat numFmt = NumberFormat("#,##0.00", "en_US");

      // Compute Income, Expense, and Category Breakdown excluding category "0"
      // (transfers & opening balance corrections) and loans.
      double totalIncome = 0;
      double totalExpense = 0;
      final Map<String, double> categoryTotals = <String, double>{};

      for (final TransactionWithCategory tx in transactions) {
        final Transaction t = tx.transaction;
        final bool isTransferOrBalancing =
            t.categoryFk == "0" || t.pairedTransactionFk != null;
        final bool isLoan = t.objectiveLoanFk != null ||
            t.type == TransactionSpecialType.credit ||
            t.type == TransactionSpecialType.debt;

        if (isTransferOrBalancing || isLoan) {
          continue;
        }

        final double ratio =
            amountRatioToPrimaryCurrency(allWallets, tx.wallet?.currency);
        final double convertedAbs = t.amount.abs() * ratio;

        if (t.income) {
          totalIncome += convertedAbs;
        } else {
          totalExpense += convertedAbs;
          final String catName = tx.category.name;
          categoryTotals[catName] =
              (categoryTotals[catName] ?? 0) + convertedAbs;
        }
      }

      final double netTotal = totalIncome - totalExpense;
      final List<MapEntry<String, double>> sortedCategories =
          categoryTotals.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));

      // Compute per-account closing balances as of the end of the selected period.
      final DateTime periodEndBound = dateTimeRange != null
          ? DateTime(
              dateTimeRange.end.year,
              dateTimeRange.end.month,
              dateTimeRange.end.day + 1,
            )
          : cutoffTomorrow;

      final List<TransactionWithCategory> allPaidUpToEnd = await database
          .getAllTransactionsWithCategoryWalletBudgetObjectiveSubCategory(
        (tbl) =>
            tbl.paid.equals(true) &
            database.onlyShowBasedOnWalletFks(tbl, selectedWalletPks) &
            tbl.dateCreated.isSmallerThanValue(periodEndBound),
      );

      final Map<String, double> walletClosingBalances = <String, double>{};
      for (final TransactionWallet w in allWallets.list) {
        if (selectedWalletPks == null ||
            selectedWalletPks.isEmpty ||
            selectedWalletPks.contains(w.walletPk)) {
          walletClosingBalances[w.walletPk] = 0.0;
        }
      }
      for (final TransactionWithCategory tx in allPaidUpToEnd) {
        final String wPk = tx.transaction.walletFk;
        if (walletClosingBalances.containsKey(wPk)) {
          walletClosingBalances[wPk] =
              (walletClosingBalances[wPk] ?? 0.0) + tx.transaction.amount;
        }
      }

      // Load bundled offline Unicode + Arabic/Urdu fonts
      final pw.Font regularFont =
          pw.Font.ttf(await rootBundle.load("assets/fonts/Inter-Regular.ttf"));
      final pw.Font boldFont =
          pw.Font.ttf(await rootBundle.load("assets/fonts/Inter-Bold.ttf"));
      final pw.Font urduFont = pw.Font.ttf(
        await rootBundle.load("assets/fonts/NotoNaskhArabic-Regular.ttf"),
      );

      pw.Widget buildSmartText(
        String text, {
        double fontSize = 9,
        bool bold = false,
        PdfColor? color,
        pw.TextAlign? align,
      }) {
        final bool rtl = _containsRtlScript(text);
        final pw.TextStyle style = pw.TextStyle(
          font: rtl ? urduFont : (bold ? boldFont : regularFont),
          fontBold: boldFont,
          fontFallback: <pw.Font>[urduFont, regularFont],
          fontSize: fontSize,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: color ?? PdfColors.black,
        );
        return pw.Directionality(
          textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
          child: pw.Text(
            text,
            textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
            textAlign:
                align ?? (rtl ? pw.TextAlign.right : pw.TextAlign.left),
            style: style,
          ),
        );
      }

      pw.Widget cellPad(
        String text, {
        double fontSize = 8.5,
        bool bold = false,
        PdfColor? color,
        pw.TextAlign? align,
      }) {
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: buildSmartText(
            text,
            fontSize: fontSize,
            bold: bold,
            color: color,
            align: align,
          ),
        );
      }

      final pw.Document doc = pw.Document();
      final String periodString = dateTimeRange == null
          ? "All Time (up to ${DateFormat("dd MMM yyyy").format(DateTime.now())})"
          : "${DateFormat("dd MMM yyyy").format(dateTimeRange.start)} - ${DateFormat("dd MMM yyyy").format(dateTimeRange.end)}";

      final DateTime now = DateTime.now();
      final List<TransactionWithCategory> scheduledFuture = transactions
          .where((tx) =>
              tx.transaction.dateCreated.isAfter(now) &&
              !isTransferLeg(tx.transaction) &&
              tx.transaction.categoryFk != "0")
          .toList();
      double futureTotal = 0;
      for (final tx in scheduledFuture) {
        futureTotal += tx.transaction.amount.abs();
      }

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          theme: pw.ThemeData.withFont(
            base: regularFont,
            bold: boldFont,
            fontFallback: <pw.Font>[urduFont],
          ),
          build: (pw.Context pdfContext) {
            return <pw.Widget>[
              // Header
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: <pw.Widget>[
                      pw.Text(
                        "Cashew Pro - Financial Report",
                        style: pw.TextStyle(
                          fontSize: 20,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blueGrey800,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        "Period: $periodString",
                        style: const pw.TextStyle(
                          fontSize: 11,
                          color: PdfColors.grey700,
                        ),
                      ),
                      if (scheduledFuture.isNotEmpty) ...[
                        pw.SizedBox(height: 2),
                        pw.Text(
                          "Includes ${scheduledFuture.length} scheduled item${scheduledFuture.length == 1 ? '' : 's'} after today ($primarySymbol ${numFmt.format(futureTotal)})",
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontStyle: pw.FontStyle.italic,
                            color: PdfColors.orange900,
                          ),
                        ),
                      ],
                    ],
                  ),
                  pw.Text(
                    "Generated ${DateFormat("yyyy-MM-dd HH:mm").format(DateTime.now())}",
                    style: const pw.TextStyle(
                      fontSize: 10,
                      color: PdfColors.grey600,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 14),
              pw.Divider(color: PdfColors.grey300),
              pw.SizedBox(height: 10),

              // Summary Cards
              pw.Text(
                "Income & Expense Summary",
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                "Excludes inter-account transfers, opening balance adjustments, and loans.",
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: PdfColors.grey600,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Expanded(
                    child: pw.Container(
                      padding: const pw.EdgeInsets.all(10),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.green50,
                        borderRadius: pw.BorderRadius.circular(8),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: <pw.Widget>[
                          pw.Text(
                            "Total Income",
                            style: const pw.TextStyle(
                              fontSize: 10,
                              color: PdfColors.green900,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          buildSmartText(
                            "$primarySymbol ${numFmt.format(totalIncome)}",
                            fontSize: 13,
                            bold: true,
                            color: PdfColors.green900,
                          ),
                        ],
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Expanded(
                    child: pw.Container(
                      padding: const pw.EdgeInsets.all(10),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.red50,
                        borderRadius: pw.BorderRadius.circular(8),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: <pw.Widget>[
                          pw.Text(
                            "Total Expense",
                            style: const pw.TextStyle(
                              fontSize: 10,
                              color: PdfColors.red900,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          buildSmartText(
                            "$primarySymbol ${numFmt.format(totalExpense)}",
                            fontSize: 13,
                            bold: true,
                            color: PdfColors.red900,
                          ),
                        ],
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Expanded(
                    child: pw.Container(
                      padding: const pw.EdgeInsets.all(10),
                      decoration: pw.BoxDecoration(
                        color: netTotal >= 0
                            ? PdfColors.blue50
                            : PdfColors.amber50,
                        borderRadius: pw.BorderRadius.circular(8),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: <pw.Widget>[
                          pw.Text(
                            "Net Savings",
                            style: const pw.TextStyle(
                              fontSize: 10,
                              color: PdfColors.blueGrey900,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          buildSmartText(
                            "${netTotal < 0 ? '-' : ''}$primarySymbol ${numFmt.format(netTotal.abs())}",
                            fontSize: 13,
                            bold: true,
                            color: netTotal >= 0
                                ? PdfColors.blue900
                                : PdfColors.amber900,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 16),

              // Account Balances at Period End
              pw.Text(
                "Account Balances (as of period end)",
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
                columnWidths: const <int, pw.TableColumnWidth>{
                  0: pw.FlexColumnWidth(2.5),
                  1: pw.FlexColumnWidth(1.5),
                },
                children: <pw.TableRow>[
                  pw.TableRow(
                    decoration:
                        const pw.BoxDecoration(color: PdfColors.blueGrey700),
                    children: <pw.Widget>[
                      cellPad("Account",
                          fontSize: 9.5, bold: true, color: PdfColors.white),
                      cellPad("Closing Balance",
                          fontSize: 9.5,
                          bold: true,
                          color: PdfColors.white,
                          align: pw.TextAlign.right),
                    ],
                  ),
                  for (final TransactionWallet w in allWallets.list)
                    if (walletClosingBalances.containsKey(w.walletPk))
                      pw.TableRow(
                        children: <pw.Widget>[
                          cellPad(w.name, fontSize: 9),
                          cellPad(
                            "${(walletClosingBalances[w.walletPk] ?? 0) < 0 ? '-' : ''}${_walletCurrencySymbol(w)} ${numFmt.format((walletClosingBalances[w.walletPk] ?? 0).abs())}",
                            fontSize: 9,
                            bold: true,
                            align: pw.TextAlign.right,
                          ),
                        ],
                      ),
                ],
              ),
              pw.SizedBox(height: 16),

              // Expense by Category Breakdown
              if (sortedCategories.isNotEmpty) ...<pw.Widget>[
                pw.Text(
                  "Expense by Category",
                  style: pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.Table(
                  border:
                      pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
                  columnWidths: const <int, pw.TableColumnWidth>{
                    0: pw.FlexColumnWidth(2.5),
                    1: pw.FlexColumnWidth(1.4),
                    2: pw.FlexColumnWidth(1.0),
                  },
                  children: <pw.TableRow>[
                    pw.TableRow(
                      decoration:
                          const pw.BoxDecoration(color: PdfColors.blueGrey700),
                      children: <pw.Widget>[
                        cellPad("Category",
                            fontSize: 9.5, bold: true, color: PdfColors.white),
                        cellPad("Amount ($primarySymbol)",
                            fontSize: 9.5,
                            bold: true,
                            color: PdfColors.white,
                            align: pw.TextAlign.right),
                        cellPad("% of Expense",
                            fontSize: 9.5,
                            bold: true,
                            color: PdfColors.white,
                            align: pw.TextAlign.right),
                      ],
                    ),
                    for (final MapEntry<String, double> entry
                        in sortedCategories)
                      pw.TableRow(
                        children: <pw.Widget>[
                          cellPad(entry.key, fontSize: 9),
                          cellPad(
                            numFmt.format(entry.value),
                            fontSize: 9,
                            align: pw.TextAlign.right,
                          ),
                          cellPad(
                            "${(totalExpense > 0 ? (entry.value / totalExpense) * 100 : 0).toStringAsFixed(1)}%",
                            fontSize: 9,
                            align: pw.TextAlign.right,
                          ),
                        ],
                      ),
                  ],
                ),
                pw.SizedBox(height: 18),
              ],

              // Full Transaction Ledger
              pw.Text(
                "Transactions (${transactions.length})",
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
                columnWidths: const <int, pw.TableColumnWidth>{
                  0: pw.FlexColumnWidth(1.15),
                  1: pw.FlexColumnWidth(2.4),
                  2: pw.FlexColumnWidth(1.45),
                  3: pw.FlexColumnWidth(1.2),
                  4: pw.FlexColumnWidth(1.45),
                },
                children: <pw.TableRow>[
                  pw.TableRow(
                    decoration:
                        const pw.BoxDecoration(color: PdfColors.blueGrey700),
                    children: <pw.Widget>[
                      cellPad("Date",
                          fontSize: 9, bold: true, color: PdfColors.white),
                      cellPad("Title / Note",
                          fontSize: 9, bold: true, color: PdfColors.white),
                      cellPad("Category",
                          fontSize: 9, bold: true, color: PdfColors.white),
                      cellPad("Account",
                          fontSize: 9, bold: true, color: PdfColors.white),
                      cellPad("Amount",
                          fontSize: 9,
                          bold: true,
                          color: PdfColors.white,
                          align: pw.TextAlign.right),
                    ],
                  ),
                  for (final TransactionWithCategory tx in transactions)
                    () {
                      final Transaction t = tx.transaction;
                      final String date =
                          DateFormat("yyyy-MM-dd").format(t.dateCreated);
                      final String title = t.name.isNotEmpty
                          ? (t.note.isNotEmpty ? "${t.name} (${t.note})" : t.name)
                          : (t.note.isNotEmpty
                              ? t.note
                              : specialCategoryName(t));
                      final String cat = t.categoryFk == "0"
                          ? specialCategoryName(t)
                          : tx.category.name;
                      final String acc = tx.wallet?.name ?? "";
                      final String wSym = tx.wallet != null
                          ? _walletCurrencySymbol(tx.wallet!)
                          : primarySymbol;
                      final String sign = t.income ? "+" : "-";
                      return pw.TableRow(
                        children: <pw.Widget>[
                          cellPad(date),
                          cellPad(title),
                          cellPad(cat),
                          cellPad(acc),
                          cellPad(
                            "$sign$wSym ${numFmt.format(t.amount.abs())}",
                            align: pw.TextAlign.right,
                            color: t.income
                                ? PdfColors.green900
                                : PdfColors.red900,
                          ),
                        ],
                      );
                    }(),
                ],
              ),
            ];
          },
        ),
      );

      final Uint8List pdfBytes = await doc.save();
      String fileName;
      if (dateTimeRange != null) {
        final DateTime s = dateTimeRange.start;
        final DateTime e = dateTimeRange.end;
        final bool isFullMonth = s.day == 1 &&
            s.year == e.year &&
            (s.month == e.month ||
                (e.difference(s).inDays >= 27 && e.difference(s).inDays <= 31));
        if (isFullMonth) {
          fileName = "cashew-report-${DateFormat("yyyy-MM").format(s)}.pdf";
        } else {
          fileName =
              "cashew-report-${DateFormat("yyyy-MM-dd").format(s)}.pdf";
        }
      } else {
        fileName =
            "cashew-report-${DateFormat("yyyy-MM-dd").format(DateTime.now())}.pdf";
      }

      await saveFile(
        boxContext: activeContext,
        dataStore: pdfBytes,
        dataString: null,
        fileName: fileName,
        successMessage: "PDF saved successfully",
        errorMessage: "Error saving PDF",
      );
    });
  }

  @override
  material.Widget build(material.BuildContext context) {
    return material.Builder(builder: (boxContext) {
      return SettingsContainer(
        onTap: () async {
          await openBottomSheet(
            context,
            PopupFramework(
              title: "Export PDF",
              hasPadding: false,
              child: ExportPDFPopup(
                exportPDF: exportPDF,
                boxContext: boxContext,
              ),
            ),
          );
        },
        title: "Export PDF",
        icon: appStateSettings["outlinedIcons"]
            ? material.Icons.picture_as_pdf_outlined
            : material.Icons.picture_as_pdf_rounded,
      );
    });
  }
}

class ExportPDFPopup extends material.StatefulWidget {
  const ExportPDFPopup({
    required this.exportPDF,
    required this.boxContext,
    super.key,
  });
  final Function({
    required material.BuildContext boxContext,
    required material.DateTimeRange? dateTimeRange,
    required List<String>? selectedWalletPks,
  }) exportPDF;
  final material.BuildContext boxContext;

  @override
  material.State<ExportPDFPopup> createState() => _ExportPDFPopupState();
}

class _ExportPDFPopupState extends material.State<ExportPDFPopup> {
  List<String>? selectedWallets;

  @override
  material.Widget build(material.BuildContext context) {
    return material.Column(
      children: <material.Widget>[
        WalletChipSelector(
          expand:
              Provider.of<AllWallets>(context, listen: false).list.length > 1,
          onSelected: (selected) {
            selectedWallets = selected;
          },
          initiallySelectedWalletFks: selectedWallets,
        ),
        material.Padding(
          padding:
              const material.EdgeInsetsDirectional.symmetric(horizontal: 18),
          child: material.Column(
            children: <material.Widget>[
              material.Row(
                children: <material.Widget>[
                  material.Expanded(
                    child: OutlinedButtonStacked(
                      text: "This Month",
                      iconData: appStateSettings["outlinedIcons"]
                          ? material.Icons.calendar_month_outlined
                          : material.Icons.calendar_month_rounded,
                      onTap: () async {
                        final material.BuildContext hostCtx = widget.boxContext;
                        popRoute(context);
                        final DateTime now = DateTime.now();
                        final DateTime start = DateTime(now.year, now.month, 1);
                        final DateTime end =
                            DateTime(now.year, now.month + 1, 0, 23, 59, 59);
                        await widget.exportPDF(
                          boxContext: navigatorKey.currentContext ?? hostCtx,
                          dateTimeRange:
                              material.DateTimeRange(start: start, end: end),
                          selectedWalletPks: selectedWallets,
                        );
                      },
                    ),
                  ),
                  material.SizedBox(width: 12),
                  material.Expanded(
                    child: OutlinedButtonStacked(
                      text: "Last Month",
                      iconData: appStateSettings["outlinedIcons"]
                          ? material.Icons.history_outlined
                          : material.Icons.history_rounded,
                      onTap: () async {
                        final material.BuildContext hostCtx = widget.boxContext;
                        popRoute(context);
                        final DateTime now = DateTime.now();
                        final DateTime start =
                            DateTime(now.year, now.month - 1, 1);
                        final DateTime end =
                            DateTime(now.year, now.month, 0, 23, 59, 59);
                        await widget.exportPDF(
                          boxContext: navigatorKey.currentContext ?? hostCtx,
                          dateTimeRange:
                              material.DateTimeRange(start: start, end: end),
                          selectedWalletPks: selectedWallets,
                        );
                      },
                    ),
                  ),
                ],
              ),
              material.SizedBox(height: 12),
              material.Row(
                children: <material.Widget>[
                  material.Expanded(
                    child: OutlinedButtonStacked(
                      text: "date-range".tr().capitalizeFirstofEach,
                      iconData: appStateSettings["outlinedIcons"]
                          ? material.Icons.date_range_outlined
                          : material.Icons.date_range_rounded,
                      onTap: () async {
                        final material.BuildContext hostCtx = widget.boxContext;
                        final DateTimeRangeOrAllTime dateRange =
                            await showCustomDateRangePicker(
                          context,
                          null,
                          initialEntryMode:
                              material.DatePickerEntryMode.calendarOnly,
                          allTimeButton: true,
                        );
                        if (!dateRange.allTime &&
                            dateRange.dateTimeRange == null) {
                          return;
                        }
                        if (context.mounted) {
                          popRoute(context);
                        }
                        await widget.exportPDF(
                          boxContext: navigatorKey.currentContext ?? hostCtx,
                          dateTimeRange: dateRange.allTime
                              ? null
                              : dateRange.dateTimeRange,
                          selectedWalletPks: selectedWallets,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
