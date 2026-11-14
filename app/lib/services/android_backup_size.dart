/// How much of this app Android's own backup (Auto Backup) would carry,
/// and the 25 MB it stops at.
///
/// Meal pictures are BLOBs inside calorie_tracker.db (db.dart), so a log
/// with pictures grows past Android's per-app quota, and above it Android
/// stops backing the app up WITHOUT a word: the default backup agent gets
/// no onQuotaExceeded call, and nothing tells the user. Diagnostics shows
/// the size, and Settings › Your Data warns above
/// [kAndroidBackupWarnBytes] and points at Export › Save to device.
///
/// The count follows Auto Backup's own rules for an app without a custom
/// agent: every file under the app's data folder except
/// - cache/, code_cache/ and no_backup/ (never backed up) and lib/;
/// - files/bitewise_local/ (excluded by res/xml/data_extraction_rules.xml
///   and backup_rules.xml);
/// - flutter_secure_storage's preference files ([kSecureStoragePrefFiles],
///   excluded by the same rules once the native lane's item lands; a few
///   KB either way).
/// So it covers databases/ (calorie_tracker.db with its -wal and -shm),
/// shared_prefs/, files/ and the app_* folders (app_flutter). Symbolic
/// links are not followed. It reads sizes only, never contents.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

/// Android's Auto Backup quota per app (developer.android.com, "Back up
/// user data with Auto Backup": 25 MB).
const int kAndroidBackupQuotaBytes = 25 * 1024 * 1024;

/// Above this, Settings › Your Data recommends Save to device.
const int kAndroidBackupWarnBytes = 20 * 1024 * 1024;

/// Top-level folders of the data folder that Auto Backup never carries.
const Set<String> _neverBackedUp = {'cache', 'code_cache', 'no_backup', 'lib'};

/// flutter_secure_storage 10's preference files (its README, "Disabling
/// Auto Backup"): kept out of the backup, so not counted.
const Set<String> kSecureStoragePrefFiles = {
  'FlutterSecureStorage.xml',
  'FlutterSecureKeyStorage.xml',
  'FlutterSecureStorageConfiguration.xml',
  'FlutterSecureStorageConfiguration:FlutterSecureStorage.xml',
};

/// The bytes Auto Backup would carry from [dataDir], the app's data
/// folder (`/data/user/0/<package>`). 0 when it does not exist; a file
/// that vanishes or cannot be read meanwhile is skipped.
Future<int> androidBackupSetBytes(Directory dataDir) async {
  if (!await dataDir.exists()) return 0;
  var total = 0;
  await for (final top in dataDir.list(followLinks: false)) {
    final name = _baseName(top.path);
    if (top is File) {
      total += await _length(top);
      continue;
    }
    if (top is! Directory || _neverBackedUp.contains(name)) continue;
    await for (final e in top.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(top.path.length + 1);
      if (name == 'files' &&
          (rel == 'bitewise_local' || rel.startsWith('bitewise_local/'))) {
        continue;
      }
      if (name == 'shared_prefs' && kSecureStoragePrefFiles.contains(rel)) {
        continue;
      }
      total += await _length(e);
    }
  }
  return total;
}

/// [androidBackupSetBytes] for this app on this phone: the data folder is
/// the parent of files/ (getApplicationSupportDirectory on Android). Null
/// when it cannot be read.
Future<int?> readAndroidBackupSetBytes() async {
  try {
    final files = await getApplicationSupportDirectory();
    return await androidBackupSetBytes(files.parent);
  } catch (_) {
    return null;
  }
}

String _baseName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

Future<int> _length(File f) async {
  try {
    return await f.length();
  } catch (_) {
    return 0;
  }
}
