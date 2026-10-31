// Data IMPORT against real SQLite (the export's missing half, 2026-07-31).
//
// Why it must be conformance-tested, not faked: import is the only code
// that WRITES rows the app did not create, and its dedup rules are pure
// SQL. A wrong rule either doubles the owner's calorie history or silently
// drops meals — both invisible until the totals look wrong weeks later.
//
// It also unblocks two real events: moving to a new phone, and the
// eventual release-keystore re-sign (Android treats a re-signed APK as a
// different app and wipes its data).
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/data/meals_logic.dart';
import 'package:calorie_tracker/ui/meal_edit_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final now = DateTime(2026, 7, 31, 16);
  late Database dbA; // the "old phone"
  late Database dbB; // the "new phone"
  late SqfliteMealsDao daoA;
  late SqfliteMealsDao daoB;

  late Directory tmp;

  setUp(() async {
    // DISTINCT files, not two ':memory:' handles — sqflite returns the
    // SAME in-memory database for that path, so "old phone" and "new
    // phone" would silently be one device and every import would look
    // like a duplicate.
    tmp = await Directory.systemTemp.createTemp('ct_import');
    dbA = await openAppDatabase(path: '${tmp.path}/a.db');
    dbB = await openAppDatabase(path: '${tmp.path}/b.db');
    daoA = SqfliteMealsDao(dbA, clock: () => now);
    daoB = SqfliteMealsDao(dbB, clock: () => now);
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tmp.delete(recursive: true);
  });

  Future<int> seed(SqfliteMealsDao dao,
          {required String date,
          String time = '12:00 PM',
          num cal = 500,
          String hash = ''}) =>
      dao.saveMeal(
          Meal(
            id: 0,
            date: date,
            time: time,
            timestamp: '${date}T12:00:00.000',
            source: MealSource.appWatch,
            imageHash: hash,
            analysis: {'is_food': true, 'total_calories': cal},
          ),
          markStatus: hash.isEmpty ? null : IngestionStatus.saved);

  test('a full export moves the food log to a fresh phone', () async {
    await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
    await seed(daoA, date: '2026-07-30', cal: 720, hash: 'h2');
    await daoA.saveBodyWeight('2026-07-30', 72.4);
    await daoA.saveActivity('2026-07-30', steps: 8000, activeCalories: 300);

    final summary = await daoB.importJson(await daoA.exportJson());

    expect(summary.added['meals'], 2);
    expect(summary.added['body_weight'], 1);
    expect(summary.added['activities'], 1);
    expect(summary.exportedAt, isNotNull);
    final moved = await daoB.mealsBetween('2026-07-01', '2026-07-31');
    expect(moved.map((m) => m.analysis['total_calories']), [610, 720]);
    // The ledger travels too, so the new phone's watcher does not
    // re-analyze photos the old phone already logged.
    expect((await daoB.photoStatus('h1'))?.status, IngestionStatus.saved);
  });

  test('importing the SAME file twice adds nothing the second time',
      () async {
    await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
    final payload = await daoA.exportJson();
    await daoB.importJson(payload);
    final second = await daoB.importJson(payload);

    expect(second.totalAdded, 0, reason: 're-import must never double the '
        "owner's calories");
    expect(second.skipped['meals'], 1);
    expect(await daoB.mealsBetween('2026-07-01', '2026-07-31'), hasLength(1));
  });

  test('merge keeps rows that exist only on the target', () async {
    await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
    await seed(daoB, date: '2026-07-31', cal: 200, hash: 'local');

    await daoB.importJson(await daoA.exportJson());

    final all = await daoB.mealsBetween('2026-07-01', '2026-07-31');
    expect(all.map((m) => m.analysis['total_calories']), [610, 200],
        reason: 'import is a MERGE — local meals must survive');
  });

  test('two DIFFERENT meals at the same clock time both survive', () async {
    // The dedup key includes the analysis: a coffee and a sandwich logged
    // in the same minute are two meals, not a duplicate.
    await seed(daoA, date: '2026-07-30', time: '08:00 AM', cal: 90);
    await seed(daoA, date: '2026-07-30', time: '08:00 AM', cal: 450);
    final summary = await daoB.importJson(await daoA.exportJson());
    expect(summary.added['meals'], 2);
  });

  test('imported ids never collide with local ones', () async {
    await seed(daoB, date: '2026-07-31', cal: 111, hash: 'local');
    await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
    await daoB.importJson(await daoA.exportJson());

    final all = await daoB.mealsBetween('2026-07-01', '2026-07-31');
    final ids = all.map((m) => m.id).toList();
    expect(ids.toSet(), hasLength(ids.length),
        reason: 'a reused primary key would overwrite a real meal');
    // And both rows are independently editable afterwards.
    await daoB.updateMealFields(ids.first, date: '2026-07-28');
    final after = await daoB.mealsBetween('2026-07-01', '2026-07-31');
    expect(after, hasLength(2));
  });

  test('a photo-ingestion row never points at a foreign meal id', () async {
    // Burn ids on B so A's meal id (1) would name a DIFFERENT row here.
    await seed(daoB, date: '2026-07-31', cal: 111, hash: 'local1');
    await seed(daoB, date: '2026-07-31', cal: 222, hash: 'local2');
    await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
    await daoB.importJson(await daoA.exportJson());
    final rows = await dbB
        .query('photo_ingestions', where: 'image_hash = ?', whereArgs: ['h1']);
    final local = await dbB
        .query('meals', where: 'image_hash = ?', whereArgs: ['h1']);
    expect(rows.single['meal_id'], local.single['id'],
        reason: 'the old id means nothing here; the link is the LOCAL id');
    expect(rows.single['meal_id'], isNot(1));
    expect(rows.single['status'], 'saved');
  });

  group('imported saved ledger rows name their local meal (run 7, B16)', () {
    // importJson drops every meal_id (old ids are foreign) and used to
    // leave them NULL. The Leftovers flow spots "this leftover photo
    // already became its own meal" only through (saved, mealId), so an
    // imported phone kept both the leftover meal and the deduction.
    test('photoStatus on the new phone returns the imported meal', () async {
      await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
      await seed(daoA, date: '2026-07-30', cal: 720, hash: 'h2');
      await daoB.importJson(await daoA.exportJson());
      for (final hash in ['h1', 'h2']) {
        final meal = await dbB
            .query('meals', where: 'image_hash = ?', whereArgs: [hash]);
        final status = await daoB.photoStatus(hash);
        expect(status?.status, IngestionStatus.saved);
        expect(status?.mealId, meal.single['id'], reason: hash);
      }
    });

    test('only saved rows without a link are touched', () async {
      final localId =
          await seed(daoB, date: '2026-07-31', cal: 200, hash: 'local');
      await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
      // A deleted photo on A: tombstoned ledger row, no meal.
      final gone = await seed(daoA, date: '2026-07-29', cal: 300, hash: 'h3');
      await daoA.deleteMeal(gone);
      // A saved row whose meal never made it (no meals row anywhere).
      await daoA.markPhotoHash('orphan', IngestionStatus.saved);
      await daoB.importJson(await daoA.exportJson());

      expect((await daoB.photoStatus('local'))?.mealId, localId,
          reason: 'an existing link is left alone');
      final deleted = await daoB.photoStatus('h3');
      expect(deleted?.status, IngestionStatus.deleted);
      expect(deleted?.mealId, isNull, reason: 'a tombstone stays unlinked');
      final orphan = await daoB.photoStatus('orphan');
      expect(orphan?.status, IngestionStatus.saved);
      expect(orphan?.mealId, isNull,
          reason: 'no local meal for the photo: nothing to link to');
    });

    test('a second import of the same file changes nothing', () async {
      await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
      final payload = await daoA.exportJson();
      await daoB.importJson(payload);
      final before = await dbB.query('photo_ingestions');
      final again = await daoB.importJson(payload);
      expect(again.totalAdded, 0);
      expect(await dbB.query('photo_ingestions'), before);
    });
  });

  test('an EDITED meal does not re-import as a duplicate of its backup',
      () async {
    // The identity used to include the analysis JSON, so any correction
    // (every edit path rewrites analysis) made an older backup look like a
    // different meal — importing it would have shown the same lunch twice,
    // once with the wrong numbers. A PHOTO meal's identity is its photo.
    final id = await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
    final backup = await daoA.exportJson(); // taken BEFORE the correction
    await daoA.updateMealFields(id,
        analysis: {'is_food': true, 'total_calories': 480});
    await daoB.importJson(await daoA.exportJson()); // current state
    final summary = await daoB.importJson(backup); // the older file

    expect(summary.added['meals'], 0,
        reason: 'the corrected meal and its pre-edit ancestor are ONE meal');
    final meals = await daoB.mealsBetween('2026-07-01', '2026-07-31');
    expect(meals, hasLength(1));
    expect(meals.single.analysis['total_calories'], 480,
        reason: 'the corrected numbers must survive');
  });

  test('an edited PHOTOLESS meal stays ONE meal when backups are imported '
      'oldest-first', () async {
    // The 2026-08-03 guard asked only whether the TARGET already held the
    // corrected copy. A chronological multi-backup restore (or a two-device
    // sync by re-export) puts the pre-edit copy in first, so the edited
    // export — corrected=1, new analysis text — matched neither identity
    // and the same lunch landed twice: 600 kcal and 450 kcal. Every edit
    // path sets corrected=1 and never touches timestamp, so EITHER side
    // being corrected proves sameness.
    final id = await daoA.saveMeal(Meal(
        id: 0,
        date: '2026-07-29',
        time: '12:00 PM',
        timestamp: '2026-07-29T12:00:00.123456',
        source: MealSource.manualText,
        analysis: {'is_food': true, 'total_calories': 600}));
    final backupOld = await daoA.exportJson();
    await daoA.updateMealFields(id,
        analysis: {'is_food': true, 'total_calories': 450});
    final backupNew = await daoA.exportJson();

    final first = await daoB.importJson(backupOld);
    expect(first.added['meals'], 1);
    final second = await daoB.importJson(backupNew);
    expect(second.added['meals'], 0,
        reason: 'the edited export is the meal already restored');
    final meals = await daoB.mealsBetween('2026-07-01', '2026-07-31');
    expect(meals, hasLength(1));

    // The mirror order (the one the 2026-08-03 fix pinned for PHOTO meals)
    // must keep holding for photoless meals too.
    final dbC = await openAppDatabase(path: '${tmp.path}/c.db');
    addTearDown(dbC.close);
    final daoC = SqfliteMealsDao(dbC, clock: () => now);
    await daoC.importJson(backupNew);
    final older = await daoC.importJson(backupOld);
    expect(older.added['meals'], 0);
    expect(
        await daoC.mealsBetween('2026-07-01', '2026-07-31'), hasLength(1));
  });

  test('an import landing MID-ANALYSIS does not double the photo meal',
      () async {
    // The reinstall sequence: 监控相册 is flipped on, backfillScan reserves
    // h1 ('processing') and awaits the analyzer for 10–60 s, and the user
    // pastes the backup from the same Settings screen in that gap. The
    // import lands A's meal for h1 (no meals row had the hash yet) and
    // skips the exported ledger row (our 'processing' row exists). The
    // pipeline's saveMeal(markStatus: saved) must then recognise the
    // imported row instead of inserting a second one (2026-10-07).
    await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
    expect((await daoB.reservePhotoHash('h1', source: MealSource.appWatch)).kind,
        PhotoReservation.reserved);
    final summary = await daoB.importJson(await daoA.exportJson());
    expect(summary.added['meals'], 1);
    expect(summary.skipped['photo_ingestions'], 1,
        reason: 'the live processing row is kept, not overwritten');

    // The analysis finishes: the pipeline saves with the 'saved' mark.
    final id = await seed(daoB, date: '2026-07-29', cal: 590, hash: 'h1');
    final rows = await dbB
        .query('meals', where: 'image_hash = ?', whereArgs: ['h1']);
    expect(rows, hasLength(1), reason: 'one photo, one meal');
    expect(id, rows.single['id'],
        reason: 'the pipeline gets the imported row\'s id back');
    final ledger = await dbB.query('photo_ingestions',
        where: 'image_hash = ?', whereArgs: ['h1']);
    expect(ledger.single['status'], 'saved');
    expect(ledger.single['meal_id'], id);
  });

  test('two photoless meals in the same minute stay distinct', () async {
    // Without a photo there is no stable anchor, so date+time+analysis is
    // the fallback identity — and a coffee is not a sandwich.
    await daoA.saveMeal(Meal(
        id: 0,
        date: '2026-07-30',
        time: '08:00 AM',
        timestamp: '2026-07-30T08:00:00.000',
        source: MealSource.manualText,
        analysis: {'is_food': true, 'total_calories': 90}));
    await daoA.saveMeal(Meal(
        id: 0,
        date: '2026-07-30',
        time: '08:00 AM',
        timestamp: '2026-07-30T08:00:00.000',
        source: MealSource.manualText,
        analysis: {'is_food': true, 'total_calories': 450}));
    final summary = await daoB.importJson(await daoA.exportJson());
    expect(summary.added['meals'], 2);
  });

  group('the SAME hand-typed meal logged twice (run 7, B15)', () {
    // `time` is minute-precise and user-editable, and a hand-typed meal's
    // analysis is built deterministically from the draft, so two 'Coffee
    // 5 kcal' saves are byte-identical in date+time+analysis. Only the
    // ingestion timestamp tells them apart; import used to ignore it and
    // kept one of the two.
    final at = DateTime(2026, 10, 30, 8, 15);
    Future<void> coffee(SqfliteMealsDao dao, String ts, {String? time}) {
      final draft = MealDraft.blank(at)
        ..description = 'Coffee'
        ..calories = '5';
      return dao.saveMeal(Meal(
          id: 0,
          date: draft.dateIso,
          time: time ?? draft.time,
          timestamp: ts,
          source: MealSource.appManual,
          analysis: draft.toAnalysis()));
    }

    test('two saves in the same minute both survive the move', () async {
      await coffee(daoA, '2026-10-30T08:15:03.120000');
      await coffee(daoA, '2026-10-30T08:15:41.990000');
      final summary = await daoB.importJson(await daoA.exportJson());
      expect(summary.added['meals'], 2);
      expect(summary.skipped['meals'], 0);
      expect(await daoB.mealsBetween('2026-10-30', '2026-10-30'),
          hasLength(2));
    });

    test('two entries backdated to the same clock time both survive',
        () async {
      await coffee(daoA, '2026-10-30T09:20:00.000000', time: '08:15 AM');
      await coffee(daoA, '2026-10-30T10:21:00.000000', time: '08:15 AM');
      final summary = await daoB.importJson(await daoA.exportJson());
      expect(summary.added['meals'], 2);
    });

    test('re-importing the same file, or importing it back, adds nothing',
        () async {
      await coffee(daoA, '2026-10-30T08:15:03.120000');
      await coffee(daoA, '2026-10-30T08:15:41.990000');
      final payload = await daoA.exportJson();
      await daoB.importJson(payload);
      final again = await daoB.importJson(payload);
      expect(again.added['meals'], 0,
          reason: 're-import must never double the owner\'s calories');
      expect(again.skipped['meals'], 2);
      final back = await daoA.importJson(await daoB.exportJson());
      expect(back.added['meals'], 0);
      expect(await daoA.mealsBetween('2026-10-30', '2026-10-30'),
          hasLength(2));
    });
  });

  test('two activities on the SAME DAY both survive an import', () async {
    // The dedup key was date-only at first, which would have collapsed a
    // morning walk and an evening run into one row (review 2026-07-31).
    await daoA.saveActivity('2026-07-30', steps: 3000, activeCalories: 120);
    await daoA.saveActivity('2026-07-30', steps: 9000, activeCalories: 480);
    final summary = await daoB.importJson(await daoA.exportJson());
    expect(summary.added['activities'], 2);
    final rows = await dbB.query('activities');
    expect(rows, hasLength(2));
  });

  test('a row rejected by SQLite counts as skipped, never as added',
      () async {
    // INSERT OR IGNORE swallows constraint violations and returns 0
    // instead of throwing, so an unconditional counter reported rows that
    // never landed — and this summary is the user's only evidence the
    // transfer worked.
    final payload = jsonEncode({
      'format': kExportFormat,
      'version': 1,
      'tables': {
        'meals': [
          // NOT NULL violations: no date/time/timestamp/analysis.
          {'chat_id': 1},
          {
            'chat_id': 1,
            'date': '2026-07-30',
            'time': '01:00 PM',
            'timestamp': '2026-07-30T13:00:00.000',
            'source': 'app_photo',
            'image_hash': 'good',
            'analysis': '{"is_food":true,"total_calories":300}',
          },
        ]
      },
    });
    final summary = await daoB.importJson(payload);
    expect(summary.added['meals'], 1);
    expect(summary.skipped['meals'], 1);
    expect(await daoB.mealsBetween('2026-07-01', '2026-07-31'), hasLength(1));
  });

  group('refusal', () {
    test('non-JSON, wrong format tag, and missing tables all throw',
        () async {
      await expectLater(
          daoB.importJson('hello'), throwsA(isA<FormatException>()));
      await expectLater(
          daoB.importJson(jsonEncode({'format': 'someone_elses_app'})),
          throwsA(isA<FormatException>()));
      await expectLater(
          daoB.importJson(jsonEncode(
              {'format': kExportFormat, 'version': 1, 'tables': 'nope'})),
          throwsA(isA<FormatException>()));
      expect(await daoB.mealsBetween('2026-01-01', '2026-12-31'), isEmpty,
          reason: 'a refused import writes NOTHING');
    });

    test('a NEWER export version still imports (forward tolerance)',
        () async {
      await seed(daoA, date: '2026-07-29', cal: 610, hash: 'h1');
      final envelope =
          jsonDecode(await daoA.exportJson()) as Map<String, dynamic>;
      envelope['version'] = 99;
      (envelope['tables'] as Map)['some_future_table'] = [
        {'whatever': 1}
      ];
      final summary = await daoB.importJson(jsonEncode(envelope));
      expect(summary.added['meals'], 1,
          reason: 'a user mid-upgrade must not be stranded');
    });

    test('a row with junk columns is skipped, not fatal', () async {
      final payload = jsonEncode({
        'format': kExportFormat,
        'version': 1,
        'exported_at': '2026-07-31T10:00:00.000',
        'tables': {
          'meals': [
            {'not_a_column': 'x'},
            {
              'chat_id': 0,
              'date': '2026-07-30',
              'time': '01:00 PM',
              'timestamp': '2026-07-30T13:00:00.000',
              'source': 'app_photo',
              'image_hash': 'ok',
              'analysis': '{"is_food":true,"total_calories":300}',
            },
          ]
        },
      });
      final summary = await daoB.importJson(payload);
      expect(summary.added['meals'], 1, reason: 'the good row lands');
      expect(summary.skipped['meals'], 1, reason: 'the junk row does not');
    });
  });

  group('a large export (a year of meals)', () {
    test('decodes off the UI isolate and imports every row', () async {
      for (var d = 0; d < 365; d++) {
        final date = DateTime(2025, 8, 1).add(Duration(days: d));
        final iso = '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}';
        for (var m = 0; m < 3; m++) {
          await daoA.saveMeal(Meal(
            id: 0,
            date: iso,
            time: '0${m + 7}:00 AM',
            timestamp: '${iso}T0${m + 7}:00:00.000',
            source: MealSource.appPhoto,
            imageHash: 'h$d-$m',
            analysis: {
              'is_food': true,
              'meal_description': '番茄炒蛋盖饭 $d-$m',
              'total_calories': 600,
              'food_items': [
                for (var i = 0; i < 4; i++)
                  {'name': 'item $i ' * 20, 'estimated_calories': 150},
              ],
            },
          ));
        }
      }
      final backup = await daoA.exportJson();
      expect(backup.length,
          greaterThan(SqfliteMealsDao.importParseOffIsolateChars),
          reason: 'this must take the worker-isolate path');
      final summary = await daoB.importJson(backup);
      expect(summary.added['meals'], 365 * 3);
      expect(summary.exportedAt, isNotNull);
    });

    test('a large payload that is not an export is still refused with its '
        'reason across the isolate', () async {
      final junk = jsonEncode({
        'format': 'something_else',
        'pad': 'x' * (SqfliteMealsDao.importParseOffIsolateChars + 1),
      });
      await expectLater(
          daoB.importJson(junk),
          throwsA(isA<ExportFormatException>().having(
              (e) => e.refusal, 'refusal', ExportRefusal.wrongFormatTag)));
      await expectLater(
          daoB.importJson('x' * (SqfliteMealsDao.importParseOffIsolateChars + 1)),
          throwsA(isA<ExportFormatException>().having(
              (e) => e.refusal, 'refusal', ExportRefusal.notJson)));
    });
  });
}
