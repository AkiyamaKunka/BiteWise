// How much Android's own backup (Auto Backup) would carry for this app
// (privacy lane item 5): meal pictures are BLOBs inside calorie_tracker.db,
// and above 25 MB per app Android stops backing it up without a word. The
// count follows Auto Backup's rules for an app without a custom agent, on
// a made-up data folder. Sizes only: nothing is read.
import 'dart:io';

import 'package:calorie_tracker/services/android_backup_size.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory data;
  setUp(() => data = Directory.systemTemp.createTempSync('ct_backup_size'));
  tearDown(() => data.deleteSync(recursive: true));

  void file(String rel, int bytes) {
    final f = File('${data.path}/$rel')..createSync(recursive: true);
    f.writeAsBytesSync(List.filled(bytes, 7));
  }

  test('the database with its -wal and -shm, shared_prefs, files/ and the '
      'app_ folders count; the excluded and never-backed-up ones do not',
      () async {
    file('databases/calorie_tracker.db', 1000);
    file('databases/calorie_tracker.db-wal', 200);
    file('databases/calorie_tracker.db-shm', 50);
    file('shared_prefs/FlutterSharedPreferences.xml', 30);
    for (final name in kSecureStoragePrefFiles) {
      file('shared_prefs/$name', 999); // excluded from the backup
    }
    file('files/meal_photos/a.bin', 100);
    file('files/bitewise_local/places.json', 5000); // excluded
    file('files/bitewise_local/deep/token', 5000); // excluded
    file('files/bitewise_localish/y', 7); // a different folder: counts
    file('app_flutter/q', 11);
    file('top_level_file', 3);
    file('cache/big.json', 100000); // never backed up
    file('code_cache/z', 100000);
    file('no_backup/androidx.work.workdb', 100000);
    expect(await androidBackupSetBytes(data),
        1000 + 200 + 50 + 30 + 100 + 7 + 11 + 3);
  });

  test('links are not followed', () async {
    final outside = Directory.systemTemp.createTempSync('ct_outside');
    addTearDown(() => outside.deleteSync(recursive: true));
    File('${outside.path}/huge').writeAsBytesSync(List.filled(4096, 1));
    file('files/real', 10);
    Link('${data.path}/files/link').createSync('${outside.path}/huge');
    Link('${data.path}/lib').createSync(outside.path);
    expect(await androidBackupSetBytes(data), 10);
  });

  test('a folder that does not exist is 0', () async {
    expect(await androidBackupSetBytes(Directory('${data.path}/nope')), 0);
  });

  test('the limits: 25 MB, warned from 20 MB', () {
    expect(kAndroidBackupQuotaBytes, 25 * 1024 * 1024);
    expect(kAndroidBackupWarnBytes, 20 * 1024 * 1024);
    expect(kAndroidBackupWarnBytes, lessThan(kAndroidBackupQuotaBytes));
  });

  test('the secure-storage files are flutter_secure_storage 10\'s four',
      () {
    expect(kSecureStoragePrefFiles, {
      'FlutterSecureStorage.xml',
      'FlutterSecureKeyStorage.xml',
      'FlutterSecureStorageConfiguration.xml',
      'FlutterSecureStorageConfiguration:FlutterSecureStorage.xml',
    });
  });
}
