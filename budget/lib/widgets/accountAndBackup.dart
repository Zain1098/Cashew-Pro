import 'dart:async';
import 'package:budget/colors.dart';
import 'package:budget/database/generatePreviewData.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/firebase_options.dart';
import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/pages/aboutPage.dart';
import 'package:budget/pages/accountsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/headlessBackup.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/shareBudget.dart';
import 'package:budget/struct/syncClient.dart';
import 'package:budget/widgets/animatedExpanded.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/exportCSV.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/importDB.dart';
import 'package:budget/widgets/moreIcons.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/util/saveFile.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:googleapis/abusiveexperiencereport/v1.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/gmail/v1.dart' as gMail;
import 'package:google_sign_in/google_sign_in.dart' as signIn;
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'package:universal_html/html.dart' as html;
import 'dart:io';
import 'package:budget/struct/randomConstants.dart';

Future<bool> checkConnection() async {
  late bool isConnected;
  if (!kIsWeb) {
    try {
      final result = await InternetAddress.lookup('example.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        isConnected = true;
      }
    } on SocketException catch (e) {
      print(e.toString());
      isConnected = false;
    }
  } else {
    isConnected = true;
  }
  return isConnected;
}

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = new http.Client();
  GoogleAuthClient(this._headers);
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

signIn.GoogleSignIn? googleSignIn;
signIn.GoogleSignInAccount? googleUser;
Object? lastSignInError;

class SignInErrorDetails {
  final String title;
  final String description;
  const SignInErrorDetails(this.title, this.description);
}

SignInErrorDetails describeSignInError(Object? error) {
  final String raw = error?.toString() ?? "";
  if (error is SocketException ||
      raw.contains("network_error") ||
      raw.contains("ApiException: 7") ||
      raw.contains("7:") ||
      raw.toLowerCase().contains("failed host lookup")) {
    return const SignInErrorDetails(
      "No internet connection",
      "Could not reach Google servers. Check your Wi-Fi or mobile data connection and try again.",
    );
  }
  if (raw.contains("sign_in_canceled") ||
      raw.contains("12501") ||
      raw.contains("SIGN_IN_DISMISSED") ||
      raw.contains("Login failed")) {
    return const SignInErrorDetails(
      "Sign-in cancelled",
      "No Google account was selected. You can retry or continue offline.",
    );
  }
  if (raw.contains("ApiException: 10") ||
      raw.contains("10:") ||
      raw.contains("DEVELOPER_ERROR")) {
    return const SignInErrorDetails(
      "Google Sign-In setup mismatch",
      "OAuth client error (code 10): This APK's signing SHA-1 is not registered for com.budget.tracker_app.pro in Firebase / Google Cloud Console.",
    );
  }
  if (raw.contains("12500")) {
    return const SignInErrorDetails(
      "Google Play Services error",
      "Google Sign-In failed (code 12500). Please ensure Google Play Services is updated and a Google account is added on this device.",
    );
  }
  return SignInErrorDetails(
    "Sign-in failed",
    raw.isEmpty
        ? "Unable to sign in with Google right now. Please try again."
        : raw,
  );
}

Future<void> showSignInErrorPopup(
  BuildContext context,
  Object? error, {
  VoidCallback? onRetry,
  String? cancelLabel,
}) async {
  final SignInErrorDetails details = describeSignInError(error);
  await openPopup(
    context,
    icon: appStateSettings["outlinedIcons"]
        ? Icons.error_outline
        : Icons.error_rounded,
    title: details.title,
    description: details.description,
    onCancelLabel: cancelLabel ?? "close".tr().capitalizeFirst,
    onCancel: () {
      popRoute(context);
    },
    onSubmitLabel: onRetry != null ? "Retry" : null,
    onSubmit: onRetry != null
        ? () {
            popRoute(context);
            onRetry();
          }
        : null,
  );
}

Future<bool> signInGoogle(
    {BuildContext? context,
    bool? waitForCompletion,
    bool? gMailPermissions,
    bool? drivePermissionsAttachments,
    bool? silentSignIn,
    Function()? next}) async {
  if (await checkLockedFeatureIfInDemoMode(context) == false) return false;
  if (appStateSettings["emailScanning"] == false) gMailPermissions = false;
  gMailPermissions = false; // Personal use: keep sign-in to Drive scopes only
  lastSignInError = null;

  try {
    if (gMailPermissions == true &&
        googleUser != null &&
        !(await testIfHasGmailAccess())) {
      await signOutGoogle();
      googleSignIn = null;
      settingsPageStateKey.currentState?.refreshState();
    } else if (googleUser == null) {
      googleSignIn = null;
      settingsPageStateKey.currentState?.refreshState();
    }

    if (waitForCompletion == true && context != null) openLoadingPopup(context);
    if (googleUser == null) {
      List<String> scopes = List<String>.from(kDriveSignInScopes);
      googleSignIn = getPlatform() == PlatformOS.isIOS
          ? signIn.GoogleSignIn(
              clientId: DefaultFirebaseOptions.currentPlatform.iosClientId,
              scopes: scopes)
          : signIn.GoogleSignIn(
              serverClientId: kGoogleServerClientId, scopes: scopes);

      final signIn.GoogleSignInAccount? account = silentSignIn == true
          ? kIsWeb
              ? await googleSignIn?.signIn()
              : await googleSignIn?.signInSilently()
          : await googleSignIn?.signIn();

      if (account != null) {
        googleUser = account;
        await updateSettings("currentUserEmail", googleUser?.email ?? "",
            updateGlobalState: false);
      } else {
        throw StateError("SIGN_IN_DISMISSED");
      }
    }
    if (waitForCompletion == true && context != null) popRoute(context);
    if (next != null) next();

    if (appStateSettings["hasSignedIn"] == false) {
      await updateSettings("hasSignedIn", true, updateGlobalState: false);
    }
    await syncDailyBackupWorkManager();

    refreshUIAfterLoginChange();
    return true;
  } catch (e) {
    lastSignInError = e;
    print("signInGoogle error: $e");
    if (waitForCompletion == true && context != null) popRoute(context);
    if (silentSignIn == true) {
      final SignInErrorDetails details = describeSignInError(e);
      openSnackbar(
        SnackbarMessage(
          title: details.title,
          description: details.description,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded,
          timeout: const Duration(milliseconds: 3400),
        ),
      );
    }
    googleUser = null;
    await updateSettings("currentUserEmail", "", updateGlobalState: false);
    if (runningCloudFunctions) {
      errorSigningInDuringCloud = true;
    } else {
      await updateSettings("hasSignedIn", false, updateGlobalState: false);
      await syncDailyBackupWorkManager();
    }
    refreshUIAfterLoginChange();
    rethrow;
  }
}

void refreshUIAfterLoginChange() {
  sidebarStateKey.currentState?.refreshState();
  accountsPageStateKey.currentState?.refreshState();
  settingsGoogleAccountLoginButtonKey.currentState?.refreshState();
}

Future<bool> testIfHasGmailAccess() async {
  print("TESTING GMAIL");
  try {
    final authHeaders = await googleUser!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    gMail.GmailApi gmailApi = gMail.GmailApi(authenticateClient);
    gMail.ListMessagesResponse results = await gmailApi.users.messages
        .list(googleUser!.id.toString(), maxResults: 1);
  } catch (e) {
    print(e.toString());
    print("NO GMAIL");
    return false;
  }
  return true;
}

Future<bool> signOutGoogle() async {
  await googleSignIn?.signOut();
  googleUser = null;
  await updateSettings("currentUserEmail", "", updateGlobalState: false);
  await updateSettings("hasSignedIn", false, updateGlobalState: false);
  await syncDailyBackupWorkManager();
  refreshUIAfterLoginChange();
  settingsPageStateKey.currentState?.refreshState();
  print("Signedout");
  return true;
}

Future<bool> refreshGoogleSignIn() async {
  await signOutGoogle();
  await signInGoogle(silentSignIn: kIsWeb ? false : true);
  return true;
}

Future<bool> signInAndSync(BuildContext context,
    {required dynamic Function() next, bool showErrorPopup = true}) async {
  dynamic result = true;
  if (getPlatform() == PlatformOS.isIOS &&
      appStateSettings["hasSignedIn"] != true) {
    result = await openPopup(
      null,
      icon: appStateSettings["outlinedIcons"]
          ? Icons.badge_outlined
          : Icons.badge_rounded,
      title: "backups".tr(),
      description: "google-drive-backup-disclaimer".tr(),
      onSubmitLabel: "continue".tr(),
      onSubmit: () {
        popRoute(null, true);
      },
      onCancel: () {
        popRoute(null);
      },
      onCancelLabel: "cancel".tr(),
    );
  }

  if (result != true) return false;
  loadingIndeterminateKey.currentState?.setVisibility(true);
  try {
    await signInGoogle(
      context: context,
      waitForCompletion: false,
      next: next,
    );
    if (appStateSettings["username"] == "" && googleUser != null) {
      await updateSettings("username", googleUser?.displayName ?? "",
          pagesNeedingRefresh: [0], updateGlobalState: false);
    }
    if (googleUser != null) {
      loadingIndeterminateKey.currentState?.setVisibility(true);
      await syncData(context);
      loadingIndeterminateKey.currentState?.setVisibility(true);
      await syncPendingQueueOnServer();
      loadingIndeterminateKey.currentState?.setVisibility(true);
      await getCloudBudgets();
      loadingIndeterminateKey.currentState?.setVisibility(true);
      await createBackupInBackground(context);
    } else {
      throw StateError("SIGN_IN_DISMISSED");
    }
    loadingIndeterminateKey.currentState?.setVisibility(false);
    settingsPageStateKey.currentState?.refreshState();
    return true;
  } catch (e) {
    print("Error syncing data after login!");
    print(e.toString());
    loadingIndeterminateKey.currentState?.setVisibility(false);
    if (showErrorPopup && context.mounted) {
      await showSignInErrorPopup(
        context,
        lastSignInError ?? e,
        onRetry: () {
          signInAndSync(
            context,
            next: next,
            showErrorPopup: showErrorPopup,
          );
        },
      );
    }
    return false;
  }
}

Future<void> createBackupInBackground(context) async {
  if (appStateSettings["hasSignedIn"] == false) return;
  if (errorSigningInDuringCloud == true) return;
  if (kIsWeb && !entireAppLoaded) return;
  if (appStateSettings["autoBackups"] == true) {
    await sharedPreferences.reload();
    final String? lastRealIso =
        sharedPreferences.getString(kLastSuccessfulDriveBackupKey);
    final DateTime? lastRealDt = (lastRealIso != null && lastRealIso.isNotEmpty)
        ? DateTime.tryParse(lastRealIso)
        : null;
    final int freqDays = (appStateSettings["autoBackupsFrequency"] is int &&
            appStateSettings["autoBackupsFrequency"] > 0)
        ? appStateSettings["autoBackupsFrequency"]
        : 1;
    final bool isDue = lastRealDt == null ||
        DateTime.now().difference(lastRealDt) >= Duration(days: freqDays);
    if (isDue) {
      print("auto backing up");
      bool hasSignedIn = false;
      if (googleUser == null) {
        try {
          hasSignedIn = await signInGoogle(
              context: context,
              gMailPermissions: false,
              waitForCompletion: false,
              silentSignIn: true);
        } catch (e) {
          print("Silent sign-in in foreground auto-backup failed: $e");
          await recordBackupFailure(e.toString());
          return;
        }
      } else {
        hasSignedIn = true;
      }
      if (hasSignedIn == false || googleUser == null) {
        return;
      }
      await createBackup(context, silentBackup: true, deleteOldBackups: true);
    } else {
      print("backup already made within frequency window");
    }
  }
  return;
}

Future forceDeleteDB() async {
  if (kIsWeb) {
    final html.Storage localStorage = html.window.localStorage;
    localStorage.clear();
  } else {
    final dbFolder = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
    await dbFile.delete();
  }
}

bool openDatabaseCorruptedPopup(BuildContext context) {
  if (isDatabaseCorrupted) {
    openPopup(
      context,
      icon: appStateSettings["outlinedIcons"]
          ? Icons.heart_broken_outlined
          : Icons.heart_broken_rounded,
      title: "database-corrupted".tr(),
      description: "database-corrupted-description".tr(),
      descriptionWidget: CodeBlock(
        text: databaseCorruptedError,
      ),
      barrierDismissible: false,
      onSubmit: () async {
        popRoute(context);
        await importDB(context, ignoreOverwriteWarning: true);
      },
      onSubmitLabel: "import-backup".tr(),
      onCancel: () async {
        popRoute(context);
        await openLoadingPopupTryCatch(() async {
          await forceDeleteDB();
          await sharedPreferences.clear();
        });
        restartAppPopup(context);
      },
      onCancelLabel: "reset".tr(),
    );
    // Lock the side navigation
    lockAppWaitForRestart = true;
    appStateKey.currentState?.refreshAppState();
    return true;
  }
  return false;
}

Future<bool> createBackup(
  context, {
  bool? silentBackup,
  bool deleteOldBackups = false,
  String? clientIDForSync,
}) async {
  if (googleUser == null) {
    loadingIndeterminateKey.currentState?.setVisibility(false);
    return false;
  }
  try {
    if (silentBackup == false || silentBackup == null) {
      loadingIndeterminateKey.currentState?.setVisibility(true);
    }
    await backupSettings();
  } catch (e) {
    if (silentBackup == false || silentBackup == null) {
      loadingIndeterminateKey.currentState?.setVisibility(false);
    }
    openSnackbar(
      SnackbarMessage(
          title: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded),
    );
  }

  try {
    if (deleteOldBackups)
      await deleteRecentBackups(context, appStateSettings["backupLimit"],
          silentDelete: true);

    DBFileInfo currentDBFileInfo = await getCurrentDBFileInfo();

    final authHeaders = await googleUser!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    final driveApi = drive.DriveApi(authenticateClient);

    var media = new drive.Media(
        currentDBFileInfo.mediaStream, currentDBFileInfo.dbFileBytes.length);

    var driveFile = new drive.File();
    final timestamp =
        DateFormat("yyyy-MM-dd-HHmmss").format(DateTime.now().toUtc());
    driveFile.name = "cashew-backup-$timestamp.sqlite";
    if (clientIDForSync != null)
      driveFile.name =
          getCurrentDeviceSyncBackupFileName(clientIDForSync: clientIDForSync);
    driveFile.modifiedTime = DateTime.now().toUtc();
    driveFile.parents = ["appDataFolder"];

    await driveApi.files.create(driveFile, uploadMedia: media);

    if (clientIDForSync == null) {
      final String nowIso = DateTime.now().toIso8601String();
      await sharedPreferences.setString(kLastSuccessfulDriveBackupKey, nowIso);
      await clearBackupFailure(sharedPreferences);
      await updateSettings("lastBackup", nowIso,
          pagesNeedingRefresh: [], updateGlobalState: false);
      await syncDailyBackupWorkManager();
      settingsPageStateKey.currentState?.refreshState();
      openSnackbar(
        SnackbarMessage(
          title: "backup-created".tr(),
          description: driveFile.name,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.backup_outlined
              : Icons.backup_rounded,
        ),
      );
    }

    if (silentBackup == false || silentBackup == null) {
      loadingIndeterminateKey.currentState?.setVisibility(false);
    }
    return true;
  } catch (e) {
    if (silentBackup == false || silentBackup == null) {
      loadingIndeterminateKey.currentState?.setVisibility(false);
    }
    if (clientIDForSync == null) {
      await recordBackupFailure(e.toString());
    }
    if (e is DetailedApiRequestError && e.status == 401) {
      await refreshGoogleSignIn();
    } else if (e is PlatformException) {
      await refreshGoogleSignIn();
    } else {
      openSnackbar(
        SnackbarMessage(
            title: e.toString(),
            icon: appStateSettings["outlinedIcons"]
                ? Icons.error_outlined
                : Icons.error_rounded),
      );
    }
    return false;
  }
}

Future<void> deleteRecentBackups(context, amountToKeep,
    {bool? silentDelete}) async {
  try {
    if (silentDelete == false || silentDelete == null) {
      loadingIndeterminateKey.currentState?.setVisibility(true);
    }

    final authHeaders = await googleUser!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    final driveApi = drive.DriveApi(authenticateClient);

    drive.FileList fileList = await driveApi.files.list(
      spaces: 'appDataFolder',
      orderBy: 'modifiedTime desc',
      $fields: 'files(id, name, modifiedTime, size)',
    );
    List<drive.File>? files = fileList.files;
    if (files == null) {
      throw "No backups found.";
    }

    int index = 0;
    files.forEach((file) {
      // subtract 1 because we just made a backup
      if (index >= amountToKeep - 1) {
        // only delete excess backups that don't belong to a client sync
        if (!isSyncBackupFile(file.name)) deleteBackup(driveApi, file.id ?? "");
      }
      if (!isSyncBackupFile(file.name)) index++;
    });
    if (silentDelete == false || silentDelete == null) {
      loadingIndeterminateKey.currentState?.setVisibility(false);
    }
  } catch (e) {
    if (silentDelete == false || silentDelete == null) {
      loadingIndeterminateKey.currentState?.setVisibility(false);
    }
    openSnackbar(
      SnackbarMessage(
          title: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded),
    );
  }
}

Future<void> deleteBackup(drive.DriveApi driveApi, String fileId) async {
  try {
    await driveApi.files.delete(fileId);
  } catch (e) {
    openSnackbar(SnackbarMessage(title: e.toString()));
  }
}

Future<void> chooseBackup(context,
    {bool isManaging = false,
    bool isClientSync = false,
    bool hideDownloadButton = false}) async {
  try {
    openBottomSheet(
      context,
      BackupManagement(
        isManaging: isManaging,
        isClientSync: isClientSync,
        hideDownloadButton: hideDownloadButton,
      ),
    );
  } catch (e) {
    popRoute(context);
    openSnackbar(
      SnackbarMessage(
          title: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded),
    );
  }
}

Future<void> loadBackup(
    BuildContext context, drive.DriveApi driveApi, drive.File file) async {
  try {
    openLoadingPopup(context);

    await cancelAndPreventSyncOperation();

    List<int> dataStore = [];
    dynamic response = await driveApi.files
        .get(file.id ?? "", downloadOptions: drive.DownloadOptions.fullMedia);
    response.stream.listen(
      (data) {
        // print("Data: ${data.length}");
        dataStore.insertAll(dataStore.length, data);
      },
      onDone: () async {
        await overwriteDefaultDB(Uint8List.fromList(dataStore));

        // if this is added, it doesn't restore the database properly on web
        // await database.close();
        popRoute(context);
        await resetLanguageToSystem(context);
        await updateSettings("databaseJustImported", true,
            pagesNeedingRefresh: [], updateGlobalState: false);
        await updateSettings("hasSignedIn", true,
            pagesNeedingRefresh: [], updateGlobalState: false);
        await updateSettings("autoBackups", true,
            pagesNeedingRefresh: [], updateGlobalState: false);
        print(appStateSettings);
        openSnackbar(
          SnackbarMessage(
              title: "backup-restored".tr(),
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.settings_backup_restore_outlined
                  : Icons.settings_backup_restore_rounded),
        );
        popRoute(context);
        restartAppPopup(
          context,
          description: kIsWeb
              ? "refresh-required-to-load-backup".tr()
              : "restart-required-to-load-backup".tr(),
          // codeBlock: file.name.toString() +
          //     (file.modifiedTime == null
          //         ? ""
          //         : ("\n" +
          //             getWordedDateShort(
          //               file.modifiedTime!,
          //               showTodayTomorrow: false,
          //               includeYear: true,
          //             ))),
        );
      },
      onError: (error) {
        openSnackbar(
          SnackbarMessage(
              title: error.toString(),
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.error_outlined
                  : Icons.error_rounded),
        );
      },
    );
  } catch (e) {
    popRoute(context);
    openSnackbar(
      SnackbarMessage(
          title: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.error_outlined
              : Icons.error_rounded),
    );
  }
}

class GoogleAccountLoginButton extends StatefulWidget {
  const GoogleAccountLoginButton({
    super.key,
    this.navigationSidebarButton = false,
    this.isButtonSelected = false,
    this.isOutlinedButton = true,
    this.forceButtonName,
  });
  final bool navigationSidebarButton;
  final bool isButtonSelected;
  final bool isOutlinedButton;
  final String? forceButtonName;

  @override
  State<GoogleAccountLoginButton> createState() =>
      GoogleAccountLoginButtonState();
}

class GoogleAccountLoginButtonState extends State<GoogleAccountLoginButton> {
  void refreshState() {
    setState(() {});
  }

  void openPage({VoidCallback? onNext}) {
    if (widget.navigationSidebarButton) {
      pageNavigationFrameworkKey.currentState!
          .changePage(8, switchNavbar: true);
      appStateKey.currentState?.refreshAppState();
    } else {
      if (onNext != null) onNext();
    }
  }

  void loginWithSync({VoidCallback? onNext}) {
    signInAndSync(
      widget.navigationSidebarButton
          ? navigatorKey.currentContext ?? context
          : context,
      next: () {
        setState(() {});
        openPage(onNext: onNext);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.navigationSidebarButton == true) {
      return AnimatedSwitcher(
        duration: Duration(milliseconds: 600),
        child: googleUser == null
            ? getPlatform() == PlatformOS.isIOS
                ? NavigationSidebarButton(
                    key: ValueKey("login"),
                    label: "backup".tr(),
                    icon: MoreIcons.google_drive,
                    iconScale: 0.87,
                    onTap: loginWithSync,
                    isSelected: false,
                  )
                : NavigationSidebarButton(
                    key: ValueKey("login"),
                    label: "login".tr(),
                    icon: MoreIcons.google,
                    onTap: loginWithSync,
                    isSelected: false,
                  )
            : getPlatform() == PlatformOS.isIOS
                ? NavigationSidebarButton(
                    key: ValueKey("user"),
                    label: "backup".tr(),
                    icon: MoreIcons.google_drive,
                    iconScale: 0.87,
                    onTap: openPage,
                    isSelected: widget.isButtonSelected,
                  )
                : NavigationSidebarButton(
                    key: ValueKey("user"),
                    label: googleUser!.displayName ?? "",
                    icon: widget.forceButtonName == null
                        ? appStateSettings["outlinedIcons"]
                            ? Icons.person_outlined
                            : Icons.person_rounded
                        : MoreIcons.google_drive,
                    iconScale: widget.forceButtonName == null ? 1 : 0.87,
                    onTap: openPage,
                    isSelected: widget.isButtonSelected,
                  ),
      );
    }
    return googleUser == null
        ? getPlatform() == PlatformOS.isIOS
            ? SettingsContainerOpenPage(
                openPage: AccountsPage(),
                isOutlined: widget.isOutlinedButton,
                onTap: (openContainer) {
                  loginWithSync(onNext: openContainer);
                },
                title: widget.forceButtonName ?? "backup".tr(),
                icon: MoreIcons.google_drive,
                iconScale: 0.87,
              )
            : SettingsContainerOpenPage(
                openPage: AccountsPage(),
                isOutlined: widget.isOutlinedButton,
                onTap: (openContainer) {
                  loginWithSync(onNext: openContainer);
                },
                title: widget.forceButtonName ?? "login".tr(),
                icon: widget.forceButtonName == null
                    ? MoreIcons.google
                    : MoreIcons.google_drive,
                iconScale: widget.forceButtonName == null ? 1 : 0.87,
              )
        : getPlatform() == PlatformOS.isIOS
            ? SettingsContainerOpenPage(
                openPage: AccountsPage(),
                title: widget.forceButtonName ?? "backup".tr(),
                icon: MoreIcons.google_drive,
                isOutlined: widget.isOutlinedButton,
                iconScale: 0.87,
              )
            : SettingsContainerOpenPage(
                openPage: AccountsPage(),
                title: widget.forceButtonName ?? googleUser!.displayName ?? "",
                icon: widget.forceButtonName == null
                    ? appStateSettings["outlinedIcons"]
                        ? Icons.person_outlined
                        : Icons.person_rounded
                    : MoreIcons.google_drive,
                iconScale: widget.forceButtonName == null ? 1 : 0.87,
                isOutlined: widget.isOutlinedButton,
              );
  }
}

Future<(drive.DriveApi? driveApi, List<drive.File>?)> getDriveFiles() async {
  try {
    final authHeaders = await googleUser!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    drive.DriveApi driveApi = drive.DriveApi(authenticateClient);

    drive.FileList fileList = await driveApi.files.list(
        spaces: 'appDataFolder',
        orderBy: 'modifiedTime desc',
        $fields: 'files(id, name, modifiedTime, size)');
    return (driveApi, fileList.files);
  } catch (e) {
    if (e is DetailedApiRequestError && e.status == 401) {
      await refreshGoogleSignIn();
      return await getDriveFiles();
    } else if (e is PlatformException) {
      await refreshGoogleSignIn();
      return await getDriveFiles();
    } else {
      openSnackbar(
        SnackbarMessage(
            title: e.toString(),
            icon: appStateSettings["outlinedIcons"]
                ? Icons.error_outlined
                : Icons.error_rounded),
      );
    }
  }
  return (null, null);
}

class BackupManagement extends StatefulWidget {
  const BackupManagement({
    Key? key,
    required this.isManaging,
    required this.isClientSync,
    this.hideDownloadButton = false,
  }) : super(key: key);

  final bool isManaging;
  final bool isClientSync;
  final bool hideDownloadButton;

  @override
  State<BackupManagement> createState() => _BackupManagementState();
}

class _BackupManagementState extends State<BackupManagement> {
  List<drive.File> filesState = [];
  List<int> deletedIndices = [];
  late drive.DriveApi driveApiState;
  UniqueKey dropDownKey = UniqueKey();
  bool isLoading = true;
  bool autoBackups = appStateSettings["autoBackups"];
  bool backupSync = appStateSettings["backupSync"];

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, () async {
      (drive.DriveApi?, List<drive.File>?) result = await getDriveFiles();
      drive.DriveApi? driveApi = result.$1;
      List<drive.File>? files = result.$2;
      if (files == null || driveApi == null) {
        setState(() {
          filesState = [];
          isLoading = false;
        });
      } else {
        setState(() {
          filesState = files;
          driveApiState = driveApi;
          isLoading = false;
        });
        bottomSheetControllerGlobal.snapToExtent(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isClientSync) {
      if (filesState.length > 0) {
        print(appStateSettings["devicesHaveBeenSynced"]);
        filesState =
            filesState.where((file) => isSyncBackupFile(file.name)).toList();
        updateSettings("devicesHaveBeenSynced", filesState.length,
            updateGlobalState: false);
      }
    } else {
      if (filesState.length > 0) {
        filesState =
            filesState.where((file) => !isSyncBackupFile(file.name)).toList();
        updateSettings("numBackups", filesState.length,
            updateGlobalState: false);
      }
    }
    Iterable<MapEntry<int, drive.File>> filesMap = filesState.asMap().entries;
    return PopupFramework(
      title: widget.isClientSync
          ? "devices".tr().capitalizeFirst
          : widget.isManaging
              ? "backups".tr()
              : "restore-a-backup".tr(),
      subtitle: widget.isClientSync
          ? "manage-syncing-info".tr()
          : widget.isManaging
              ? appStateSettings["backupLimit"].toString() +
                  " " +
                  "stored-backups".tr()
              : "overwrite-warning".tr(),
      child: Column(
        children: [
          widget.isClientSync && kIsWeb == false
              ? Row(
                  children: [
                    Expanded(
                      child: AboutInfoBox(
                        title: "web-app".tr(),
                        link: "https://budget-track.web.app/",
                        color: appStateSettings["materialYou"]
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : getColor(context, "lightDarkAccentHeavyLight"),
                        padding: EdgeInsetsDirectional.only(
                          start: 5,
                          end: 5,
                          bottom: 10,
                          top: 5,
                        ),
                      ),
                    ),
                  ],
                )
              : SizedBox.shrink(),
          widget.isManaging && widget.isClientSync == false
              ? SettingsContainerSwitch(
                  enableBorderRadius: true,
                  onSwitched: (value) async {
                    await updateSettings("autoBackups", value,
                        pagesNeedingRefresh: [], updateGlobalState: false);
                    setState(() {
                      autoBackups = value;
                    });
                  },
                  initialValue: appStateSettings["autoBackups"],
                  title: "auto-backups".tr(),
                  description: "auto-backups-description".tr(),
                  icon: appStateSettings["outlinedIcons"]
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_done_rounded,
                )
              : SizedBox.shrink(),
          widget.isClientSync
              ? SettingsContainerSwitch(
                  enableBorderRadius: true,
                  onSwitched: (value) async {
                    // Only update global is the sidebar is shown
                    await updateSettings("backupSync", value,
                        pagesNeedingRefresh: [], updateGlobalState: false);
                    sidebarStateKey.currentState?.refreshState();
                    setState(() {
                      backupSync = value;
                    });
                    // Future.delayed(Duration(milliseconds: 100), () {
                    //   bottomSheetControllerGlobal.snapToExtent(0);
                    // });
                  },
                  initialValue: appStateSettings["backupSync"],
                  title: "sync-data".tr(),
                  description: "sync-data-description".tr(),
                  icon: appStateSettings["outlinedIcons"]
                      ? Icons.cloud_sync_outlined
                      : Icons.cloud_sync_rounded,
                )
              : SizedBox.shrink(),
          // Only allow sync on every change for web
          // Only on web, disabled automatically in initializeSettings if not web
          widget.isClientSync && kIsWeb
              ? AnimatedExpanded(
                  expand: backupSync,
                  child: SettingsContainerSwitch(
                    enableBorderRadius: true,
                    onSwitched: (value) async {
                      await updateSettings("syncEveryChange", value,
                          pagesNeedingRefresh: [], updateGlobalState: false);
                    },
                    initialValue: appStateSettings["syncEveryChange"],
                    title: "sync-every-change".tr(),
                    descriptionWithValue: (value) {
                      return value
                          ? "sync-every-change-description1".tr()
                          : "sync-every-change-description2".tr();
                    },
                    icon: appStateSettings["outlinedIcons"]
                        ? Icons.all_inbox_outlined
                        : Icons.all_inbox_rounded,
                  ),
                )
              : SizedBox.shrink(),
          widget.isManaging && widget.isClientSync == false
              ? AnimatedExpanded(
                  expand: autoBackups,
                  child: SettingsContainerDropdown(
                    enableBorderRadius: true,
                    items: ["1", "2", "3", "7", "10", "14"],
                    onChanged: (value) async {
                      await updateSettings(
                          "autoBackupsFrequency", int.parse(value),
                          pagesNeedingRefresh: [], updateGlobalState: false);
                    },
                    initial:
                        appStateSettings["autoBackupsFrequency"].toString(),
                    title: "backup-frequency".tr(),
                    description: "number-of-days".tr(),
                    icon: appStateSettings["outlinedIcons"]
                        ? Icons.event_repeat_outlined
                        : Icons.event_repeat_rounded,
                  ),
                )
              : SizedBox.shrink(),
          widget.isManaging &&
                  widget.isClientSync == false &&
                  appStateSettings["showBackupLimit"]
              ? SettingsContainerDropdown(
                  enableBorderRadius: true,
                  key: dropDownKey,
                  verticalPadding: 5,
                  title: "backup-limit".tr(),
                  icon: Icons.format_list_numbered_rtl_outlined,
                  initial: appStateSettings["backupLimit"].toString(),
                  items: ["10", "15", "20", "30"],
                  onChanged: (value) async {
                    if (int.parse(value) < appStateSettings["backupLimit"]) {
                      openPopup(
                        context,
                        icon: appStateSettings["outlinedIcons"]
                            ? Icons.delete_outlined
                            : Icons.delete_rounded,
                        title: "change-limit".tr(),
                        description: "change-limit-warning".tr(),
                        onSubmit: () async {
                          await updateSettings("backupLimit", int.parse(value),
                              updateGlobalState: false);
                          popRoute(context);
                        },
                        onSubmitLabel: "change".tr(),
                        onCancel: () {
                          popRoute(context);
                          setState(() {
                            dropDownKey = UniqueKey();
                          });
                        },
                        onCancelLabel: "cancel".tr(),
                      );
                    } else {
                      await updateSettings("backupLimit", int.parse(value),
                          updateGlobalState: false);
                    }
                  },
                )
              : SizedBox.shrink(),
          if ((widget.isManaging == false && widget.isClientSync == false) ==
              false)
            SizedBox(height: 10),
          isLoading
              ? Column(
                  children: [
                    for (int i = 0;
                        i <
                            (widget.isClientSync
                                ? appStateSettings["devicesHaveBeenSynced"]
                                : appStateSettings["numBackups"]);
                        i++)
                      LoadingShimmerDriveFiles(
                          isManaging: widget.isManaging, i: i),
                  ],
                )
              : SizedBox.shrink(),
          ...filesMap
              .map(
                (MapEntry<int, drive.File> file) => AnimatedSizeSwitcher(
                  child: deletedIndices.contains(file.key)
                      ? Container(
                          key: ValueKey(1),
                        )
                      : Padding(
                          padding:
                              const EdgeInsetsDirectional.only(bottom: 8.0),
                          child: Tappable(
                            onTap: () async {
                              if (!widget.isManaging) {
                                final result = await openPopup(
                                  context,
                                  title: "load-backup".tr(),
                                  subtitle: getWordedDateShortMore(
                                        (file.value.modifiedTime ??
                                                DateTime.now())
                                            .toLocal(),
                                        includeTime: true,
                                        includeYear: true,
                                        showTodayTomorrow: false,
                                      ) +
                                      "\n" +
                                      getWordedTime(
                                          navigatorKey.currentContext?.locale
                                              .toString(),
                                          (file.value.modifiedTime ??
                                                  DateTime.now())
                                              .toLocal()),
                                  beforeDescriptionWidget: Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      top: 8,
                                      bottom: 5,
                                    ),
                                    child: CodeBlock(
                                        text: (file.value.name ?? "No name")),
                                  ),
                                  description: "load-backup-warning".tr(),
                                  icon: appStateSettings["outlinedIcons"]
                                      ? Icons.warning_outlined
                                      : Icons.warning_rounded,
                                  onSubmit: () async {
                                    popRoute(context, true);
                                  },
                                  onSubmitLabel: "load".tr(),
                                  onCancelLabel: "cancel".tr(),
                                  onCancel: () {
                                    popRoute(context);
                                  },
                                );
                                if (result == true)
                                  loadBackup(
                                      context, driveApiState, file.value);
                              }
                              // else {
                              //   await openPopup(
                              //     context,
                              //     title: "Backup Details",
                              //     description: (file.value.name ?? "") +
                              //         "\n" +
                              //         (file.value.size ?? "") +
                              //         "\n" +
                              //         (file.value.description ?? ""),
                              //     icon: appStateSettings["outlinedIcons"] ? Icons.warning_outlined : Icons.warning_rounded,
                              //     onSubmit: () async {
                              //       popRoute(context, true);
                              //     },
                              //     onSubmitLabel: "Close",
                              //   );
                              // }
                            },
                            borderRadius: 15,
                            color: widget.isClientSync &&
                                    isCurrentDeviceSyncBackupFile(
                                        file.value.name)
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.4)
                                : appStateSettings["materialYou"]
                                    ? Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                    : getColor(
                                        context, "lightDarkAccentHeavyLight"),
                            child: Container(
                              padding: EdgeInsetsDirectional.symmetric(
                                  horizontal: 20, vertical: 15),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Icon(
                                          widget.isClientSync
                                              ? appStateSettings[
                                                      "outlinedIcons"]
                                                  ? Icons.devices_outlined
                                                  : Icons.devices_rounded
                                              : appStateSettings[
                                                      "outlinedIcons"]
                                                  ? Icons.description_outlined
                                                  : Icons.description_rounded,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .secondary,
                                          size: 30,
                                        ),
                                        SizedBox(
                                            width:
                                                widget.isClientSync ? 17 : 13),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              TextFont(
                                                text: getTimeAgo(
                                                  (file.value.modifiedTime ??
                                                          DateTime.now())
                                                      .toLocal(),
                                                ).capitalizeFirst,
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                maxLines: 2,
                                              ),
                                              TextFont(
                                                text: (isSyncBackupFile(
                                                        file.value.name)
                                                    ? getDeviceFromSyncBackupFileName(
                                                            file.value.name) +
                                                        " " +
                                                        "sync"
                                                    : file.value.name ??
                                                        "No name"),
                                                fontSize: 14,
                                                maxLines: 2,
                                              ),
                                              // isSyncBackupFile(
                                              //         file.value.name)
                                              //     ? Padding(
                                              //         padding:
                                              //             const EdgeInsetsDirectional
                                              //                 .only(top: 3),
                                              //         child: TextFont(
                                              //           text:
                                              //               file.value.name ??
                                              //                   "",
                                              //           fontSize: 11,
                                              //           maxLines: 2,
                                              //         ),
                                              //       )
                                              //     : SizedBox.shrink()
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  widget.isManaging
                                      ? Row(
                                          children: [
                                            widget.hideDownloadButton
                                                ? SizedBox.shrink()
                                                : Padding(
                                                    padding:
                                                        const EdgeInsetsDirectional
                                                            .only(
                                                      start: 8.0,
                                                    ),
                                                    child: Builder(
                                                        builder: (boxContext) {
                                                      return ButtonIcon(
                                                        color: appStateSettings[
                                                                "materialYou"]
                                                            ? Theme.of(context)
                                                                .colorScheme
                                                                .onSecondaryContainer
                                                                .withOpacity(
                                                                    0.08)
                                                            : getColor(context,
                                                                    "lightDarkAccentHeavy")
                                                                .withOpacity(
                                                                    0.7),
                                                        onTap: () {
                                                          saveDriveFileToDevice(
                                                            boxContext:
                                                                boxContext,
                                                            driveApi:
                                                                driveApiState,
                                                            fileToSave:
                                                                file.value,
                                                          );
                                                        },
                                                        icon: Icons
                                                            .download_rounded,
                                                      );
                                                    }),
                                                  ),
                                            Padding(
                                              padding:
                                                  const EdgeInsetsDirectional
                                                      .only(start: 5),
                                              child: ButtonIcon(
                                                color: appStateSettings[
                                                        "materialYou"]
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .onSecondaryContainer
                                                        .withOpacity(0.08)
                                                    : getColor(context,
                                                            "lightDarkAccentHeavy")
                                                        .withOpacity(0.7),
                                                onTap: () {
                                                  openPopup(
                                                    context,
                                                    icon: appStateSettings[
                                                            "outlinedIcons"]
                                                        ? Icons.delete_outlined
                                                        : Icons.delete_rounded,
                                                    title: "delete-backup".tr(),
                                                    subtitle:
                                                        getWordedDateShortMore(
                                                              (file.value.modifiedTime ??
                                                                      DateTime
                                                                          .now())
                                                                  .toLocal(),
                                                              includeTime: true,
                                                              includeYear: true,
                                                              showTodayTomorrow:
                                                                  false,
                                                            ) +
                                                            "\n" +
                                                            getWordedTime(
                                                                navigatorKey
                                                                    .currentContext
                                                                    ?.locale
                                                                    .toString(),
                                                                (file.value.modifiedTime ??
                                                                        DateTime
                                                                            .now())
                                                                    .toLocal()),
                                                    beforeDescriptionWidget:
                                                        Padding(
                                                      padding:
                                                          const EdgeInsetsDirectional
                                                              .only(
                                                        top: 8,
                                                        bottom: 5,
                                                      ),
                                                      child: CodeBlock(
                                                        text: (file.value
                                                                    .name ??
                                                                "No name") +
                                                            "\n" +
                                                            convertBytesToMB(file
                                                                        .value
                                                                        .size ??
                                                                    "0")
                                                                .toStringAsFixed(
                                                                    2) +
                                                            " MB",
                                                      ),
                                                    ),
                                                    description: (widget
                                                            .isClientSync
                                                        ? "delete-sync-backup-warning"
                                                            .tr()
                                                        : null),
                                                    onSubmit: () async {
                                                      popRoute(context);
                                                      loadingIndeterminateKey
                                                          .currentState
                                                          ?.setVisibility(true);
                                                      await deleteBackup(
                                                          driveApiState,
                                                          file.value.id ?? "");
                                                      openSnackbar(
                                                        SnackbarMessage(
                                                            title:
                                                                "deleted-backup"
                                                                    .tr(),
                                                            description: (file
                                                                    .value
                                                                    .name ??
                                                                "No name"),
                                                            icon: Icons
                                                                .delete_rounded),
                                                      );
                                                      setState(() {
                                                        deletedIndices
                                                            .add(file.key);
                                                      });
                                                      // bottomSheetControllerGlobal
                                                      //     .snapToExtent(0);
                                                      if (widget.isClientSync)
                                                        await updateSettings(
                                                            "devicesHaveBeenSynced",
                                                            appStateSettings[
                                                                    "devicesHaveBeenSynced"] -
                                                                1,
                                                            updateGlobalState:
                                                                false);
                                                      if (widget.isManaging) {
                                                        await updateSettings(
                                                            "numBackups",
                                                            appStateSettings[
                                                                    "numBackups"] -
                                                                1,
                                                            updateGlobalState:
                                                                false);
                                                      }
                                                      loadingIndeterminateKey
                                                          .currentState
                                                          ?.setVisibility(
                                                              false);
                                                    },
                                                    onSubmitLabel:
                                                        "delete".tr(),
                                                    onCancel: () {
                                                      popRoute(context);
                                                    },
                                                    onCancelLabel:
                                                        "cancel".tr(),
                                                  );
                                                },
                                                icon: appStateSettings[
                                                        "outlinedIcons"]
                                                    ? Icons.close_outlined
                                                    : Icons.close_rounded,
                                              ),
                                            ),
                                          ],
                                        )
                                      : SizedBox.shrink(),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              )
              .toList(),
        ],
      ),
    );
  }
}

double convertBytesToMB(String bytesString) {
  try {
    int bytes = int.parse(bytesString);
    double megabytes = bytes / (1024 * 1024);
    return megabytes;
  } catch (e) {
    print("Error parsing bytes string: $e");
    return 0.0; // or throw an exception, depending on your requirements
  }
}

class LoadingShimmerDriveFiles extends StatelessWidget {
  const LoadingShimmerDriveFiles({
    Key? key,
    required this.isManaging,
    required this.i,
  }) : super(key: key);

  final bool isManaging;
  final int i;

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      period:
          Duration(milliseconds: (1000 + randomDouble[i % 10] * 520).toInt()),
      baseColor: appStateSettings["materialYou"]
          ? Theme.of(context).colorScheme.secondaryContainer
          : getColor(context, "lightDarkAccentHeavyLight"),
      highlightColor: appStateSettings["materialYou"]
          ? Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.2)
          : getColor(context, "lightDarkAccentHeavy").withAlpha(20),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(bottom: 8.0),
        child: Tappable(
          onTap: () {},
          borderRadius: 15,
          color: appStateSettings["materialYou"]
              ? Theme.of(context)
                  .colorScheme
                  .secondaryContainer
                  .withOpacity(0.5)
              : getColor(context, "lightDarkAccentHeavy").withOpacity(0.5),
          child: Container(
              padding:
                  EdgeInsetsDirectional.symmetric(horizontal: 20, vertical: 15),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          appStateSettings["outlinedIcons"]
                              ? Icons.description_outlined
                              : Icons.description_rounded,
                          color: Theme.of(context).colorScheme.secondary,
                          size: 30,
                        ),
                        SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadiusDirectional.all(
                                      Radius.circular(5)),
                                  color: Colors.white,
                                ),
                                height: 20,
                                width: 70 + randomDouble[i % 10] * 120 + 13,
                              ),
                              SizedBox(height: 6),
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadiusDirectional.all(
                                      Radius.circular(5)),
                                  color: Colors.white,
                                ),
                                height: 14,
                                width: 90 + randomDouble[i % 10] * 120,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 13),
                  isManaging
                      ? Row(
                          children: [
                            ButtonIcon(
                                onTap: () {},
                                icon: appStateSettings["outlinedIcons"]
                                    ? Icons.close_outlined
                                    : Icons.close_rounded),
                            SizedBox(width: 5),
                            ButtonIcon(
                                onTap: () {},
                                icon: appStateSettings["outlinedIcons"]
                                    ? Icons.close_outlined
                                    : Icons.close_rounded),
                          ],
                        )
                      : SizedBox.shrink(),
                ],
              )),
        ),
      ),
    );
  }
}

Future<bool> saveDriveFileToDevice({
  required BuildContext boxContext,
  required drive.DriveApi driveApi,
  required drive.File fileToSave,
}) async {
  List<int> dataStore = [];
  dynamic response = await driveApi.files
      .get(fileToSave.id!, downloadOptions: drive.DownloadOptions.fullMedia);
  await for (var data in response.stream) {
    dataStore.insertAll(dataStore.length, data);
  }
  String fileName = "cashew-" +
      ((fileToSave.name ?? "") +
              cleanFileNameString(
                  (fileToSave.modifiedTime ?? DateTime.now()).toString()))
          .replaceAll(".sqlite", "") +
      ".sqlite";

  return await saveFile(
    boxContext: boxContext,
    dataStore: dataStore,
    dataString: null,
    fileName: fileName,
    successMessage: "backup-downloaded-success".tr(),
    errorMessage: "error-downloading".tr(),
  );
}

bool openBackupReminderPopupCheck(BuildContext context) {
  if ((appStateSettings["currentUserEmail"] == null ||
          appStateSettings["currentUserEmail"] == "") &&
      ((appStateSettings["numLogins"] + 1) % 7 == 0) &&
      appStateSettings["canShowBackupReminderPopup"] == true) {
    openPopup(
      context,
      icon: MoreIcons.google_drive,
      iconScale: 0.9,
      title: "backup-your-data-reminder".tr(),
      description: "backup-your-data-reminder-description".tr() +
          " " +
          "google-drive".tr(),
      onSubmitLabel: "backup".tr().capitalizeFirst,
      onSubmit: () async {
        popRoute(context);
        await signInAndSync(context, next: () {});
      },
      onCancelLabel: "never".tr().capitalizeFirst,
      onCancel: () async {
        popRoute(context);
        await updateSettings("canShowBackupReminderPopup", false,
            updateGlobalState: false);
      },
      onExtraLabel: "later".tr().capitalizeFirst,
      onExtra: () {
        popRoute(context);
      },
    );
    return true;
  }
  return false;
}
