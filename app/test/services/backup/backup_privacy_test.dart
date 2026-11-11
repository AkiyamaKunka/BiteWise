// What iCloud Backup may never touch (1.7.0 rules): the API keys and the
// key stores, setup-link secrets, server credentials, the AI and
// restaurant consents, and the backup-excluded local store
// (bitewise_local: learned places, the photo change token, the assist's
// files). The backup code reads the export tables and the pictures through
// the DAO, and its own `settings.backup_*` preferences — nothing else.
import 'dart:io';

import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/backup/backup_files.dart';
import 'package:calorie_tracker/services/backup/backup_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

void main() {
  test('the backup code never reaches the keys, the consents or the local '
      'store', () {
    final dir = Directory('${_appRoot().path}/lib/services/backup');
    final sources = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(sources, isNotEmpty);
    const banned = [
      'local_store',
      'bitewise_local',
      'assist_',
      'KeyStore',
      'keystore',
      'secure_storage',
      'SecureStorage',
      'api_key',
      'apiKey',
      'ai_consent',
      'restaurant_assist',
      'setup_link',
      'serverBaseUrl',
      'server_base_url',
      'AppSettings',
      "'flutter.",
      '"flutter.',
    ];
    for (final f in sources) {
      final text = f.readAsStringSync();
      for (final word in banned) {
        expect(text.contains(word), isFalse,
            reason: '${f.path.split('/').last} mentions $word');
      }
    }
  });

  test('every backup preference is under settings.backup_', () {
    for (final k in BackupPrefs.allKeys) {
      expect(k, startsWith('settings.backup_'));
    }
  });

  test('a full export carries the tables and pictures, nothing from '
      'settings', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tmp = await Directory.systemTemp.createTemp('ct_backup_priv');
    final db = await openAppDatabase(path: '${tmp.path}/a.db');
    final dao = SqfliteMealsDao(db);
    await dao.saveBodyWeight('2026-11-10', 70);
    final f = await BackupFileWriter(dao: dao, platform: 'ios')
        .writeFull('${tmp.path}/full.json', installId: '0123456789abcdef0123456789abcdef');
    final text = await File(f.path).readAsString();
    for (final word in ['api_key', 'server', 'consent', 'assist_jobs', 'photo_change']) {
      expect(text.contains(word), isFalse, reason: word);
    }
    expect(text, isNot(contains('data_changes')));
    await db.close();
    await tmp.delete(recursive: true);
  });
}
