// The DAO half of iCloud Backup (1.7.0), against real SQLite: the change
// counter the triggers keep (schema v4), the counts and month prints a
// backup run reads, and the import of pictures — onto the local meal of
// the same photo, never replacing one — with photo meals deleted on this
// phone left deleted.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/data/meals_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The smallest byte run the importer accepts as a JPEG.
Uint8List _jpeg(int tag, {int size = 64}) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(size - 6, tag), 0xFF, 0xD9]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final now = DateTime(2026, 11, 11, 9);
  late Directory tmp;
  late Database dbA, dbB;
  late SqfliteMealsDao a, b;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_backup_dao');
    dbA = await openAppDatabase(path: '${tmp.path}/a.db');
    dbB = await openAppDatabase(path: '${tmp.path}/b.db');
    a = SqfliteMealsDao(dbA, clock: () => now);
    b = SqfliteMealsDao(dbB, clock: () => now);
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tmp.delete(recursive: true);
  });

  Future<int> seed(SqfliteMealsDao dao,
          {required String date, String hash = '', num cal = 500}) =>
      dao.saveMeal(
          Meal(
            id: 0,
            date: date,
            time: '12:00 PM',
            timestamp: '${date}T12:00:00.000',
            source: hash.isEmpty ? MealSource.manualText : MealSource.appWatch,
            imageHash: hash,
            analysis: {'is_food': true, 'total_calories': cal},
          ),
          markStatus: hash.isEmpty ? null : IngestionStatus.saved);

  /// A pictures-style envelope (what backup_files writes for a month).
  String picturesFile(List<Map<String, Object?>> rows,
          {Map<String, Object?> extraTables = const {}}) =>
      jsonEncode({
        'format': kExportFormat,
        'version': 2,
        'exported_at': now.toIso8601String(),
        'tables': {...extraTables, 'meal_thumbs': rows},
      });

  Map<String, Object?> thumbRow(String hash, Uint8List jpeg) =>
      {'chat_id': localChatId, 'image_hash': hash, 'jpeg_b64': base64Encode(jpeg)};

  group('the change counter (schema v4)', () {
    test('every write to a backed-up table bumps records; pictures bump '
        'thumbs', () async {
      final c0 = await a.backupCounts();
      final id = await seed(a, date: '2026-11-10', hash: 'h1');
      final c1 = await a.backupCounts();
      expect(c1.recordsChange, greaterThan(c0.recordsChange));
      await a.updateMealAnalysis(id, {'is_food': true, 'total_calories': 1});
      final c2 = await a.backupCounts();
      expect(c2.recordsChange, greaterThan(c1.recordsChange));
      await a.saveBodyWeight('2026-11-10', 70);
      await a.saveBodyMeasurements('2026-11-10', waistCm: 80);
      final c3 = await a.backupCounts();
      expect(c3.recordsChange, greaterThan(c2.recordsChange));
      expect(c3.thumbsChange, c0.thumbsChange);
      await a.saveMealThumb(id, _jpeg(1));
      final c4 = await a.backupCounts();
      expect(c4.thumbsChange, greaterThan(c3.thumbsChange));
      expect(c4.recordsChange, c3.recordsChange,
          reason: 'a picture alone is not a records change');
      await a.deleteMeal(id);
      final c5 = await a.backupCounts();
      expect(c5.recordsChange, greaterThan(c4.recordsChange));
      expect(c5.thumbsChange, greaterThan(c4.thumbsChange));
    });

    test('reads leave it alone', () async {
      await seed(a, date: '2026-11-10');
      final before = await a.backupCounts();
      await a.mealsBetween('2026-01-01', '2026-12-31');
      await a.backupRecordTables();
      await a.thumbMonthPrints();
      await a.exportJson();
      final after = await a.backupCounts();
      expect(after.recordsChange, before.recordsChange);
      expect(after.thumbsChange, before.thumbsChange);
    });

    test('data_changes is never exported', () async {
      final tables = (jsonDecode(await a.exportJson())['tables'] as Map).keys;
      expect(tables, isNot(contains('data_changes')));
      expect((await a.backupRecordTables()).keys, kExportTables);
    });

    test('a v3 database gains the counter and its triggers on reopen',
        () async {
      final path = '${tmp.path}/v3.db';
      final old = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, v) async {
              for (final ddl in kSchemaDdl) {
                if (ddl.contains('data_changes')) continue;
                await db.execute(ddl);
              }
            },
          ));
      await old.insert('meals', {
        'chat_id': localChatId,
        'date': '2026-01-01',
        'time': '12:00 PM',
        'timestamp': '2026-01-01T12:00:00',
        'analysis': '{}',
      });
      await old.close();
      final upgraded = await openAppDatabase(path: path);
      final dao = SqfliteMealsDao(upgraded, clock: () => now);
      final before = await dao.backupCounts();
      expect(before.meals, 1);
      final triggers = await upgraded.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' "
          "AND name LIKE 'dc_%'");
      expect(triggers, hasLength(24));
      await seed(dao, date: '2026-01-02');
      expect((await dao.backupCounts()).recordsChange,
          greaterThan(before.recordsChange));
      await upgraded.close();
    });
  });

  test('counts: what the user logged, the date range and the pictures',
      () async {
    final id = await seed(a, date: '2026-10-03', hash: 'h1');
    await seed(a, date: '2026-11-09');
    await a.saveMealThumb(id, _jpeg(1));
    await a.saveBodyWeight('2026-11-09', 70);
    await a.saveActivity('2026-11-09', steps: 1000, activeCalories: 50);
    final c = await a.backupCounts();
    expect(c.meals, 2);
    expect(c.bodyWeight, 1);
    expect(c.activities, 1);
    expect(c.thumbs, 1);
    expect(c.records, 4, reason: 'the ledger is not counted');
    expect(c.firstDate, '2026-10-03');
    expect(c.lastDate, '2026-11-09');
  });

  test('month prints group the photo meals by the meal date, and move with '
      'it', () async {
    final oct1 = await seed(a, date: '2026-10-03', hash: 'h1');
    final oct2 = await seed(a, date: '2026-10-30', hash: 'h2');
    final nov = await seed(a, date: '2026-11-01', hash: 'h3');
    final text = await seed(a, date: '2026-11-01');
    for (final id in [oct1, oct2, nov, text]) {
      await a.saveMealThumb(id, _jpeg(id, size: 100));
    }
    final prints = await a.thumbMonthPrints();
    expect(prints.keys.toSet(), {'2026-10', '2026-11'});
    expect(prints['2026-10']!.count, 2);
    expect(prints['2026-10']!.bytes, 200);
    expect(prints['2026-10']!.maxMealId, oct2);
    expect(prints['2026-11']!.count, 1,
        reason: 'a picture without a photo hash cannot be matched back');
    final oct = await a.thumbsForMonth('2026-10');
    expect([for (final t in oct) t.imageHash], ['h1', 'h2']);
    expect(oct.first.jpeg, _jpeg(oct1, size: 100));
    // The meal moves to November: both months change.
    expect(
        await a.updateMealFieldsIfUnchanged(oct2,
            expectedRaw: (await dbA.query('meals',
                    columns: ['analysis'], where: 'id = ?', whereArgs: [oct2]))
                .first['analysis'] as String,
            date: '2026-11-02'),
        isTrue);
    final moved = await a.thumbMonthPrints();
    expect(moved['2026-10']!.key, isNot(prints['2026-10']!.key));
    expect(moved['2026-11']!.count, 2);
  });

  group('importing pictures', () {
    test('records first, then pictures, onto the local meal of the photo',
        () async {
      final id = await seed(a, date: '2026-10-03', hash: 'h1');
      await a.saveMealThumb(id, _jpeg(7));
      final records = await b.importJson(await a.exportJson());
      expect(records.added['meals'], 1);
      final pics = await b.importJson(picturesFile([thumbRow('h1', _jpeg(7))]));
      expect(pics.thumbsAdded, 1);
      expect(pics.thumbsSkipped, 0);
      expect(pics.noMatchingMeals, isFalse);
      final local = (await b.mealsBetween('2026-10-01', '2026-10-31')).single;
      expect(await b.mealThumb(local.id), _jpeg(7));
      // Again: nothing new, nothing replaced.
      final again =
          await b.importJson(picturesFile([thumbRow('h1', _jpeg(9))]));
      expect(again.thumbsAdded, 0);
      expect(again.thumbsSkipped, 1);
      expect(await b.mealThumb(local.id), _jpeg(7));
    });

    test('a file with its meals and their pictures lands in one import',
        () async {
      await seed(a, date: '2026-10-03', hash: 'h1');
      final tables = jsonDecode(await a.exportJson())['tables'] as Map;
      final full = picturesFile([thumbRow('h1', _jpeg(3))],
          extraTables: tables.cast<String, Object?>());
      final s = await b.importJson(full);
      expect(s.added['meals'], 1);
      expect(s.thumbsAdded, 1);
    });

    test('pictures with no meal here say so', () async {
      final s = await b.importJson(picturesFile([thumbRow('h1', _jpeg(1))]));
      expect(s.thumbsAdded, 0);
      expect(s.thumbsSkipped, 1);
      expect(s.noMatchingMeals, isTrue);
      expect(s.totalAdded, 0);
    });

    test('not a JPEG, too big, not base64 or missing fields: refused',
        () async {
      await seed(b, date: '2026-10-03', hash: 'h1');
      final s = await b.importJson(picturesFile([
        thumbRow('h1', Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2])),
        thumbRow('h1', _jpeg(1, size: 64 * 1024 + 10)),
        {'chat_id': localChatId, 'image_hash': 'h1', 'jpeg_b64': '***'},
        {'chat_id': localChatId, 'jpeg_b64': base64Encode(_jpeg(1))},
        {'chat_id': 'one', 'image_hash': 'h1', 'jpeg_b64': base64Encode(_jpeg(1))},
      ]));
      expect(s.thumbsAdded, 0);
      expect(s.thumbsSkipped, 5);
      final local = (await b.mealsBetween('2026-10-01', '2026-10-31')).single;
      expect(await b.mealThumb(local.id), isNull);
    });
  });

  group('a photo meal deleted on this phone', () {
    test('is not brought back by a restore, and neither is its picture',
        () async {
      final kept = await seed(a, date: '2026-10-03', hash: 'keep');
      final gone = await seed(a, date: '2026-10-04', hash: 'gone');
      await a.saveMealThumb(kept, _jpeg(1));
      await a.saveMealThumb(gone, _jpeg(2));
      final records = await a.exportJson();
      // The same log is on B (an earlier restore); the user deletes one.
      await b.importJson(records);
      final onB = await b.mealsBetween('2026-10-01', '2026-10-31');
      await b.deleteMeal(onB.firstWhere((m) => m.imageHash == 'gone').id);

      final s = await b.importJson(records);
      expect(s.added['meals'], 0);
      expect(s.mealsSkippedDeleted, 1);
      final pics = await b.importJson(picturesFile(
          [thumbRow('keep', _jpeg(1)), thumbRow('gone', _jpeg(2))]));
      expect(pics.thumbsAdded, 1);
      expect(
          [for (final m in await b.mealsBetween('2026-10-01', '2026-10-31')) m.imageHash],
          ['keep']);
      expect((await b.photoStatus('gone'))?.status, IngestionStatus.deleted);
    });

    test('a deliberate re-add on this phone is a meal again, and the import '
        'does not double it', () async {
      final gone = await seed(a, date: '2026-10-04', hash: 'gone');
      expect(gone, greaterThan(0));
      final records = await a.exportJson();
      await b.importJson(records);
      final onB = (await b.mealsBetween('2026-10-01', '2026-10-31')).single;
      await b.deleteMeal(onB.id);
      await seed(b, date: '2026-10-04', hash: 'gone'); // re-added
      final s = await b.importJson(records);
      expect(s.added['meals'], 0);
      expect(s.mealsSkippedDeleted, 0);
      expect(await b.mealsBetween('2026-10-01', '2026-10-31'), hasLength(1));
    });

    test('a fresh phone with no ledger restores every meal', () async {
      await seed(a, date: '2026-10-03', hash: 'h1');
      await seed(a, date: '2026-10-04');
      final s = await b.importJson(await a.exportJson());
      expect(s.added['meals'], 2);
      expect(s.mealsSkippedDeleted, 0);
    });
  });
}
