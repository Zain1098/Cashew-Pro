import 'dart:convert';
import 'dart:io';
import 'package:budget/database/tables.dart';
import 'package:budget/firebase_options.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/syncClient.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart' as signIn;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

const String kDailyBackupUniqueName = "cashew-daily-backup";
const String kDailyBackupTask = "cashew-daily-backup-task";
const String kPauseBackupUniqueName = "cashew-backup-on-pause";
const String kLastSuccessfulDriveBackupKey = "lastSuccessfulDriveBackup";
const String kBackupFailingSinceKey = "backupFailingSince";
const String kLastBackupErrorKey = "lastBackupError";

const String kGoogleServerClientId =
    "649079981215-b5upr6fugr6f6abkqcg7gn27fso9l01p.apps.googleusercontent.com";

final List<String> kDriveSignInScopes = <String>[
  "https://www.googleapis.com/auth/userinfo.profile",
  "https://www.googleapis.com/auth/userinfo.email",
  drive.DriveApi.driveAppdataScope,
  drive.DriveApi.driveFileScope,
];

class _HeadlessGoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _inner = http.Client();

  _HeadlessGoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

Future<void> runHeadlessDriveBackup() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  final String rawSettings = prefs.getString('userSettings') ?? '{}';
  Map<String, dynamic> settingsMap;
  try {
    settingsMap = Map<String, dynamic>.from(json.decode(rawSettings) as Map);
  } catch (_) {
    settingsMap = <String, dynamic>{};
  }

  final bool hasSignedIn = settingsMap['hasSignedIn'] == true;
  final bool autoBackups = settingsMap['autoBackups'] == true;
  if (!hasSignedIn || !autoBackups) {
    debugPrint(
      '[HeadlessBackup] Skipping backup (hasSignedIn=$hasSignedIn, autoBackups=$autoBackups)',
    );
    return;
  }

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    debugPrint('[HeadlessBackup] Firebase init note: $e');
  }

  final signIn.GoogleSignIn gsi = signIn.GoogleSignIn(
    serverClientId: kGoogleServerClientId,
    scopes: kDriveSignInScopes,
  );

  final signIn.GoogleSignInAccount? account = await gsi.signInSilently();
  if (account == null) {
    throw StateError(
      'Silent Google Sign-In returned null (session expired or revoked).',
    );
  }

  final Directory tempDir = await getTemporaryDirectory();
  final String snapPath = p.join(tempDir.path, 'cashew-auto-backup.sqlite');
  final File snapFile = File(snapPath);
  if (await snapFile.exists()) {
    await snapFile.delete();
  }

  final FinanceDatabase db = await constructDb('db');
  try {
    if (rawSettings.isNotEmpty && rawSettings != '{}') {
      await db.createOrUpdateSettings(
        AppSetting(
          settingsPk: 0,
          settingsJSON: rawSettings,
          dateUpdated: DateTime.now(),
        ),
      );
    }
    await db.customStatement('VACUUM INTO ?', [snapPath]);
  } finally {
    await db.close();
  }

  if (!await snapFile.exists()) {
    throw StateError('SQLite VACUUM INTO did not create snapshot file.');
  }
  final Uint8List bytes = await snapFile.readAsBytes();
  if (bytes.isEmpty) {
    throw StateError('SQLite backup snapshot is 0 bytes.');
  }

  final Map<String, String> authHeaders = await account.authHeaders;
  final _HeadlessGoogleAuthClient authClient =
      _HeadlessGoogleAuthClient(authHeaders);
  try {
    final drive.DriveApi driveApi = drive.DriveApi(authClient);
    final String utcStamp =
        DateFormat('yyyy-MM-dd-HHmmss').format(DateTime.now().toUtc());
    final drive.File meta = drive.File()
      ..name = 'db-v$schemaVersionGlobal-auto-$utcStamp.sqlite'
      ..modifiedTime = DateTime.now().toUtc()
      ..parents = <String>['appDataFolder'];

    await driveApi.files.create(
      meta,
      uploadMedia: drive.Media(Stream<List<int>>.value(bytes), bytes.length),
    );

    final int keepCount = (settingsMap['backupLimit'] is int &&
            (settingsMap['backupLimit'] as int) > 0)
        ? settingsMap['backupLimit'] as int
        : 10;

    final drive.FileList listed = await driveApi.files.list(
      spaces: 'appDataFolder',
      orderBy: 'modifiedTime desc',
      $fields: 'files(id, name, modifiedTime, size)',
    );
    final List<drive.File> backupFiles = (listed.files ?? <drive.File>[])
        .where((drive.File f) => !isSyncBackupFile(f.name))
        .toList();

    for (final drive.File oldFile in backupFiles.skip(keepCount)) {
      if (oldFile.id != null && oldFile.id!.isNotEmpty) {
        try {
          await driveApi.files.delete(oldFile.id!);
        } catch (delErr) {
          debugPrint('[HeadlessBackup] Pruning old backup failed: $delErr');
        }
      }
    }

    final String nowIso = DateTime.now().toIso8601String();
    await prefs.setString(kLastSuccessfulDriveBackupKey, nowIso);
    await clearBackupFailure(prefs);
    debugPrint('[HeadlessBackup] Uploaded ${meta.name} (${bytes.length} bytes)');
  } finally {
    authClient.close();
    if (await snapFile.exists()) {
      try {
        await snapFile.delete();
      } catch (_) {}
    }
  }
}

Future<void> clearBackupFailure([SharedPreferences? existingPrefs]) async {
  final SharedPreferences prefs =
      existingPrefs ?? await SharedPreferences.getInstance();
  await prefs.remove(kBackupFailingSinceKey);
  await prefs.remove(kLastBackupErrorKey);
}

Future<void> recordBackupFailure(String errorText) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final DateTime now = DateTime.now();
  await prefs.setString(kLastBackupErrorKey, errorText);

  final String? existingSince = prefs.getString(kBackupFailingSinceKey);
  DateTime failingSince = now;
  if (existingSince == null || existingSince.isEmpty) {
    await prefs.setString(kBackupFailingSinceKey, now.toIso8601String());
  } else {
    failingSince = DateTime.tryParse(existingSince) ?? now;
  }

  if (now.difference(failingSince) >= const Duration(days: 3)) {
    try {
      final FlutterLocalNotificationsPlugin plugin =
          FlutterLocalNotificationsPlugin();
      const AndroidInitializationSettings initAndroid =
          AndroidInitializationSettings('notification_icon_android2');
      await plugin.initialize(
        const InitializationSettings(android: initAndroid),
      );
      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'driveBackupAlerts',
        'Backup Alerts',
        channelDescription: 'Alerts when automatic Google Drive backups fail',
        importance: Importance.high,
        priority: Priority.high,
      );
      await plugin.show(
        9901,
        'Google Drive backup failed for 3 days',
        'Open Cashew Pro and sign in to Google Drive again to protect your data.',
        const NotificationDetails(android: androidDetails),
      );
    } catch (notifErr) {
      debugPrint('[HeadlessBackup] Failure notification error: $notifErr');
    }
  }
}

Future<void> syncDailyBackupWorkManager() async {
  if (kIsWeb || getPlatform() != PlatformOS.isAndroid) return;
  try {
    final bool shouldSchedule = appStateSettings['hasSignedIn'] == true &&
        appStateSettings['autoBackups'] == true;
    if (shouldSchedule) {
      await Workmanager().registerPeriodicTask(
        kDailyBackupUniqueName,
        kDailyBackupTask,
        frequency: const Duration(hours: 24),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 15),
      );
    } else {
      await Workmanager().cancelByUniqueName(kDailyBackupUniqueName);
    }
  } catch (e) {
    debugPrint('[HeadlessBackup] WorkManager sync error: $e');
  }
}

Future<void> triggerBackupOnPauseIfDue() async {
  if (kIsWeb || getPlatform() != PlatformOS.isAndroid) return;
  if (appStateSettings['hasSignedIn'] != true ||
      appStateSettings['autoBackups'] != true) {
    return;
  }
  try {
    await sharedPreferences.reload();
    final String? lastIso =
        sharedPreferences.getString(kLastSuccessfulDriveBackupKey);
    final DateTime? lastDt =
        (lastIso != null && lastIso.isNotEmpty) ? DateTime.tryParse(lastIso) : null;
    if (lastDt == null ||
        DateTime.now().difference(lastDt) > const Duration(hours: 24)) {
      await Workmanager().registerOneOffTask(
        kPauseBackupUniqueName,
        kDailyBackupTask,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 15),
      );
    }
  } catch (e) {
    debugPrint('[HeadlessBackup] Pause backup enqueue error: $e');
  }
}

Future<void> triggerImmediateHeadlessBackupOneOff() async {
  if (kIsWeb || getPlatform() != PlatformOS.isAndroid) return;
  await Workmanager().registerOneOffTask(
    'cashew-backup-manual-oneoff-${DateTime.now().millisecondsSinceEpoch}',
    kDailyBackupTask,
    constraints: Constraints(networkType: NetworkType.connected),
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 15),
  );
}
