import 'dart:convert';
import 'dart:io';
import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:universal_html/html.dart' show AnchorElement;

const MethodChannel _nativeFilesChannel =
    MethodChannel('com.budget.tracker_app/native_files');

String _mimeTypeForFileName(String fileName) {
  final String lower = fileName.toLowerCase();
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.csv')) return 'text/csv';
  if (lower.endsWith('.json')) return 'application/json';
  return 'application/octet-stream';
}

String _trOrFallback(String key, String fallback) {
  final String translated = key.tr();
  return translated == key ? fallback : translated;
}

Future<void> showSavedFileDialog({
  required BuildContext context,
  required String displayName,
  required String uri,
  required String mimeType,
  required Uint8List fileBytes,
}) async {
  await openPopup(
    context,
    icon: appStateSettings["outlinedIcons"]
        ? Icons.download_done_outlined
        : Icons.download_done_rounded,
    title: "Saved: $displayName",
    description: displayName,
    onCancelLabel: _trOrFallback("close", "Close").capitalizeFirst,
    onCancel: () {
      popRoute(context);
    },
    onExtraLabel: _trOrFallback("share", "Share").capitalizeFirst,
    onExtra: () async {
      popRoute(context);
      try {
        await Share.shareXFiles(
          [
            XFile.fromData(
              fileBytes,
              name: displayName,
              mimeType: mimeType,
            ),
          ],
          subject: displayName,
          fileNameOverrides: [displayName],
        );
      } catch (e) {
        openSnackbar(SnackbarMessage(
          title: _trOrFallback("an-error-occured", "Error"),
          description: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.warning_outlined
              : Icons.warning_rounded,
        ));
      }
    },
    onSubmitLabel: _trOrFallback("open", "Open").capitalizeFirst,
    onSubmit: () async {
      popRoute(context);
      try {
        await _nativeFilesChannel.invokeMethod('openFile', {
          'uri': uri,
          'mimeType': mimeType,
        });
      } catch (e) {
        openSnackbar(SnackbarMessage(
          title: _trOrFallback("an-error-occured", "Unable to open file"),
          description: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.warning_outlined
              : Icons.warning_rounded,
        ));
      }
    },
  );
}

Future<bool> saveFile({
  required BuildContext boxContext,
  required List<int>? dataStore,
  required String? dataString,
  required String fileName,
  required String successMessage,
  required String errorMessage,
  String? customDirectory,
  bool shareFile = false,
}) async {
  if (dataStore == null && dataString == null) {
    throw ("Both arguments cannot be null");
  }

  if (kIsWeb) {
    try {
      String base64String = base64Encode(
          dataStore != null ? dataStore : utf8.encode(dataString!));
      AnchorElement anchor = AnchorElement(
          href: 'data:application/octet-stream;base64,$base64String')
        ..download = fileName
        ..style.display = 'none';
      anchor.click();
      openSnackbar(SnackbarMessage(
        title: successMessage,
        description: fileName,
        icon: appStateSettings["outlinedIcons"]
            ? Icons.download_done_outlined
            : Icons.download_done_rounded,
      ));
      return true;
    } catch (e) {
      openSnackbar(SnackbarMessage(
        title: errorMessage,
        description: e.toString(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_outlined
            : Icons.warning_rounded,
      ));
      print("Error saving file to device: " + e.toString());
      return false;
    }
  }

  final Uint8List fileBytes = dataStore != null
      ? Uint8List.fromList(dataStore)
      : Uint8List.fromList(utf8.encode(dataString!));
  final String mimeType = _mimeTypeForFileName(fileName);

  if (shareFile || getPlatform() == PlatformOS.isIOS) {
    try {
      final List<XFile> files = [
        XFile.fromData(
          fileBytes,
          name: fileName,
          mimeType: mimeType,
        )
      ];

      final RenderBox? box = boxContext.mounted
          ? boxContext.findRenderObject() as RenderBox?
          : null;
      final ShareResult result = await Share.shareXFiles(
        files,
        subject: fileName,
        sharePositionOrigin:
            box != null ? box.localToGlobal(Offset.zero) & box.size : null,
        fileNameOverrides: [fileName],
      );
      if (result.status == ShareResultStatus.dismissed) {
        return false;
      }

      openSnackbar(SnackbarMessage(
        title: successMessage,
        description: fileName,
        icon: appStateSettings["outlinedIcons"]
            ? Icons.download_done_outlined
            : Icons.download_done_rounded,
        timeout: const Duration(milliseconds: 5000),
      ));
      return true;
    } catch (e) {
      openSnackbar(SnackbarMessage(
        title: errorMessage,
        description: e.toString(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_outlined
            : Icons.warning_rounded,
      ));
      print("Error sharing file: " + e.toString());
      return false;
    }
  }

  if (getPlatform() == PlatformOS.isAndroid) {
    try {
      final Map<dynamic, dynamic>? response = await _nativeFilesChannel
          .invokeMapMethod<dynamic, dynamic>('saveFile', {
        'fileName': fileName,
        'mimeType': mimeType,
        'bytes': fileBytes,
      });

      if (response == null || response['cancelled'] == true) {
        openSnackbar(SnackbarMessage(
          title: "Nothing saved",
          description: _trOrFallback("no-folder-selected", "Save cancelled"),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.info_outlined
              : Icons.info_outline_rounded,
        ));
        return false;
      }

      if (response['saved'] == true) {
        final String savedUri = (response['uri'] ?? '').toString();
        final String displayName =
            (response['displayName'] ?? fileName).toString();
        openSnackbar(SnackbarMessage(
          title: successMessage,
          description: "Saved: $displayName",
          icon: appStateSettings["outlinedIcons"]
              ? Icons.download_done_outlined
              : Icons.download_done_rounded,
          timeout: const Duration(milliseconds: 5000),
        ));
        Future.delayed(const Duration(milliseconds: 120), () {
          final BuildContext? dialogCtx = navigatorKey.currentContext;
          if (dialogCtx != null) {
            showSavedFileDialog(
              context: dialogCtx,
              displayName: displayName,
              uri: savedUri,
              mimeType: mimeType,
              fileBytes: fileBytes,
            );
          }
        });
        return true;
      }
      return false;
    } catch (e) {
      print("Error saving file via native Android SAF: " + e.toString());
      openSnackbar(SnackbarMessage(
        title: errorMessage,
        description: e.toString(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_outlined
            : Icons.warning_rounded,
      ));
      return false;
    }
  }

  try {
    final String directory =
        customDirectory ?? (await getApplicationDocumentsDirectory()).path;
    final String filePath = "$directory/$fileName";
    final File savedFile = File(filePath);
    await savedFile.writeAsBytes(fileBytes);

    openSnackbar(SnackbarMessage(
      title: successMessage,
      description: "Saved: $fileName",
      icon: appStateSettings["outlinedIcons"]
          ? Icons.download_done_outlined
          : Icons.download_done_rounded,
      timeout: const Duration(milliseconds: 5000),
      onTap: () async {
        await Share.shareXFiles([XFile(filePath, name: fileName)],
            subject: fileName);
      },
    ));
    return true;
  } catch (e) {
    print("Error saving file to desktop directory: " + e.toString());
    openSnackbar(SnackbarMessage(
      title: errorMessage,
      description: e.toString(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.warning_outlined
          : Icons.warning_rounded,
    ));
    return false;
  }
}
