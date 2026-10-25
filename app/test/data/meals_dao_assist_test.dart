// Compare-and-set writes against REAL SQLite (design R6a, "Write safety").
//
// The restaurant assist enriches a meal in the foreground some time after
// it was saved, while the user may be editing it, deducting leftovers from
// it or fixing it by chat. Every one of those writers now compares the
// analysis column's RAW text with what it read, in the same statement as
// its write: whoever changed the meal in between wins, and the stale
// writer is told so. These pin the SQL, because a fake cannot: the WHERE
// clauses, the corrected flag, the transaction that rolls a leftover
// tombstone back with its deduction, and rows whose stored JSON is not
// what Dart's jsonEncode would write (the server's Python json.dumps, an
// import) — comparing a re-encoding would fail those forever.
import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final now = DateTime(2026, 10, 24, 13);
  late Database db;
  late SqfliteMealsDao dao;

  setUp(() async {
    db = await openAppDatabase(path: inMemoryDatabasePath);
    dao = SqfliteMealsDao(db, clock: () => now);
  });
  tearDown(() async => db.close());

  const bowl = <String, dynamic>{
    'is_food': true,
    'meal_description': 'Burrito bowl',
    'total_calories': 900,
    'food_items': [
      {'name': 'Burrito bowl', 'estimated_calories': 900, 'brand': 'Chipotle'},
    ],
  };
  final published = <String, dynamic>{
    ...bowl,
    'total_calories': 1050,
    'food_items': [
      {
        'name': 'Burrito bowl',
        'estimated_calories': 1050,
        'brand': 'Chipotle',
        'published': true,
      },
    ],
    'assist': {'v': 2, 'status': 'applied', 'chain_key': 'chipotle'},
  };

  Future<int> save(
          {Map<String, dynamic> analysis = bowl,
          String hash = '',
          bool corrected = false}) =>
      dao.saveMeal(Meal(
        id: 0,
        date: '2026-10-24',
        time: '12:30 PM',
        timestamp: '2026-10-24T12:30:00.000',
        source: MealSource.appWatch,
        imageHash: hash,
        analysis: analysis,
        corrected: corrected,
      ));

  /// A row written the way the server's Python json.dumps writes it
  /// (", " and ": " separators), which jsonEncode never produces.
  Future<int> savePythonFormatted(Map<String, dynamic> analysis) =>
      db.insert('meals', {
        'chat_id': 1,
        'date': '2026-10-24',
        'time': '12:30 PM',
        'timestamp': '2026-10-24T12:30:00.000',
        'source': MealSource.appWatch,
        'image_hash': '',
        'file_id': '',
        'analysis': jsonEncode(analysis)
            .replaceAll(',', ', ')
            .replaceAll(':', ': '),
        'corrected': 0,
      });

  Future<Map<String, Object?>> row(int id) async =>
      (await db.query('meals', where: 'id = ?', whereArgs: [id])).single;

  group('mealSnapshot', () {
    test('hands back the column text byte for byte, and the decoded meal',
        () async {
      final id = await savePythonFormatted(bowl);
      final snap = (await dao.mealSnapshot(id))!;
      expect(snap.rawAnalysis, (await row(id))['analysis']);
      expect(snap.rawAnalysis, contains('"total_calories": 900'),
          reason: 'not a re-encoding');
      expect(snap.meal.id, id);
      expect(snap.meal.analysis['total_calories'], 900);
      expect(snap.corrected, isFalse);
    });

    test('null for a meal that does not exist (or was deleted)', () async {
      final id = await save();
      await dao.deleteMeal(id);
      expect(await dao.mealSnapshot(id), isNull);
      expect(await dao.mealSnapshot(9999), isNull);
    });
  });

  group('applyAssist', () {
    test('writes while unchanged, and keeps corrected=0', () async {
      final id = await save();
      final snap = (await dao.mealSnapshot(id))!;
      expect(
          await dao.applyAssist(id,
              expectedRaw: snap.rawAnalysis, analysis: published),
          isTrue);
      final r = await row(id);
      expect(r['corrected'], 0, reason: 'published numbers are not an edit');
      expect(jsonDecode(r['analysis']! as String)['total_calories'], 1050);
    });

    test('refuses a meal the user corrected, even with matching text',
        () async {
      final id = await save(corrected: true);
      final snap = (await dao.mealSnapshot(id))!;
      expect(
          await dao.applyAssist(id,
              expectedRaw: snap.rawAnalysis, analysis: published),
          isFalse);
      expect(jsonDecode((await row(id))['analysis']! as String),
          bowl, reason: 'nothing written');
    });

    test('refuses once the text changed, and after an edit (corrected=1)',
        () async {
      final id = await save();
      final stale = (await dao.mealSnapshot(id))!.rawAnalysis;
      // A leftover deduction (or any write) lands first.
      await dao.updateMealAnalysis(id, {...bowl, 'total_calories': 600});
      expect(
          await dao.applyAssist(id, expectedRaw: stale, analysis: published),
          isFalse);
      expect(jsonDecode((await row(id))['analysis']! as String)
          ['total_calories'], 600);
    });

    test('works on non-canonical stored JSON (Python-formatted, imported)',
        () async {
      final id = await savePythonFormatted(bowl);
      final snap = (await dao.mealSnapshot(id))!;
      expect(jsonEncode(snap.meal.analysis), isNot(snap.rawAnalysis),
          reason: 'a re-encoding would never match this row');
      expect(
          await dao.applyAssist(id,
              expectedRaw: snap.rawAnalysis, analysis: published),
          isTrue);
      expect((await row(id))['corrected'], 0);
    });

    test('an Undo through applyAssist restores without setting corrected',
        () async {
      final id = await save();
      var snap = (await dao.mealSnapshot(id))!;
      await dao.applyAssist(id,
          expectedRaw: snap.rawAnalysis, analysis: published);
      snap = (await dao.mealSnapshot(id))!;
      expect(
          await dao.applyAssist(id,
              expectedRaw: snap.rawAnalysis, analysis: bowl),
          isTrue);
      final r = await row(id);
      expect(jsonDecode(r['analysis']! as String), bowl);
      expect(r['corrected'], 0);
    });

    test('a missing meal is false, nothing inserted', () async {
      expect(
          await dao.applyAssist(42, expectedRaw: '{}', analysis: published),
          isFalse);
      expect(await db.query('meals'), isEmpty);
    });
  });

  group('updateMealAnalysisIfUnchanged / updateMealFieldsIfUnchanged', () {
    test('write and set corrected=1 while unchanged', () async {
      final id = await save();
      final raw = (await dao.mealSnapshot(id))!.rawAnalysis;
      expect(
          await dao.updateMealAnalysisIfUnchanged(id,
              expectedRaw: raw, analysis: {...bowl, 'total_calories': 700}),
          isTrue);
      var r = await row(id);
      expect(r['corrected'], 1);
      expect(jsonDecode(r['analysis']! as String)['total_calories'], 700);

      final raw2 = (await dao.mealSnapshot(id))!.rawAnalysis;
      expect(
          await dao.updateMealFieldsIfUnchanged(id,
              expectedRaw: raw2,
              analysis: {...bowl, 'total_calories': 720},
              date: '2026-10-23',
              time: '07:00 PM'),
          isTrue);
      r = await row(id);
      expect(r['date'], '2026-10-23');
      expect(r['time'], '07:00 PM');
      expect(r['timestamp'], '2026-10-24T12:30:00.000',
          reason: 'ingestion time never moves (spec §2.2)');
      expect(jsonDecode(r['analysis']! as String)['total_calories'], 720);
    });

    test("an editor's stale copy never overwrites a lookup that landed "
        'while it was open', () async {
      final id = await save();
      final editorRaw = (await dao.mealSnapshot(id))!.rawAnalysis;
      // The assist applies published numbers meanwhile.
      final assistRaw = (await dao.mealSnapshot(id))!.rawAnalysis;
      await dao.applyAssist(id, expectedRaw: assistRaw, analysis: published);

      expect(
          await dao.updateMealFieldsIfUnchanged(id,
              expectedRaw: editorRaw,
              analysis: {...bowl, 'meal_description': 'Bowl'},
              date: '2026-10-23'),
          isFalse);
      expect(
          await dao.updateMealAnalysisIfUnchanged(id,
              expectedRaw: editorRaw, analysis: bowl),
          isFalse);
      final r = await row(id);
      expect(r['date'], '2026-10-24', reason: 'nothing of the save landed');
      expect(r['corrected'], 0);
      expect(jsonDecode(r['analysis']! as String)['total_calories'], 1050);
    });

    test('a deleted meal is false', () async {
      final id = await save();
      final raw = (await dao.mealSnapshot(id))!.rawAnalysis;
      await dao.deleteMeal(id);
      expect(
          await dao.updateMealFieldsIfUnchanged(id,
              expectedRaw: raw, date: '2026-10-23'),
          isFalse);
      expect(
          await dao.updateMealAnalysisIfUnchanged(id,
              expectedRaw: raw, analysis: bowl),
          isFalse);
    });
  });

  group('applyLeftoverVerdict with expectedRaw', () {
    const hash = 'ab12ab12ab12ab12ab12ab12ab12ab12';
    final deducted = <String, dynamic>{...bowl, 'total_calories': 500};

    test('unchanged: the deduction and the tombstone land together',
        () async {
      final id = await save(hash: 'f' * 32);
      final r = await dao.reservePhotoHash(hash, source: MealSource.appWatch);
      final raw = (await dao.mealSnapshot(id))!.rawAnalysis;
      expect(
          await dao.applyLeftoverVerdict(hash, id, deducted,
              ownerStamp: r.stamp, expectedRaw: raw),
          isTrue);
      expect((await dao.photoStatus(hash))?.status, IngestionStatus.skipped);
      final m = await row(id);
      expect(m['corrected'], 1);
      expect(jsonDecode(m['analysis']! as String)['total_calories'], 500);
    });

    test('changed meanwhile: false, nothing written, the photo still held '
        'under its stamp', () async {
      final id = await save(hash: 'f' * 32);
      final r = await dao.reservePhotoHash(hash, source: MealSource.appWatch);
      final stale = (await dao.mealSnapshot(id))!.rawAnalysis;
      final fresh = (await dao.mealSnapshot(id))!.rawAnalysis;
      await dao.applyAssist(id, expectedRaw: fresh, analysis: published);

      expect(
          await dao.applyLeftoverVerdict(hash, id, deducted,
              ownerStamp: r.stamp, expectedRaw: stale),
          isFalse);
      expect((await dao.photoStatus(hash))?.status,
          IngestionStatus.processing,
          reason: 'the tombstone rolled back with the deduction');
      expect(jsonDecode((await row(id))['analysis']! as String)
          ['total_calories'], 1050);
      expect((await row(id))['corrected'], 0);

      // Re-based on the current text, the same run settles it.
      final now = (await dao.mealSnapshot(id))!.rawAnalysis;
      expect(
          await dao.applyLeftoverVerdict(hash, id, deducted,
              ownerStamp: r.stamp, expectedRaw: now),
          isTrue);
      expect((await dao.photoStatus(hash))?.status, IngestionStatus.skipped);
    });

    test('a deleted meal: false, the photo stays held', () async {
      final id = await save(hash: 'f' * 32);
      final r = await dao.reservePhotoHash(hash, source: MealSource.appWatch);
      final raw = (await dao.mealSnapshot(id))!.rawAnalysis;
      await dao.deleteMeal(id);
      expect(
          await dao.applyLeftoverVerdict(hash, id, deducted,
              ownerStamp: r.stamp, expectedRaw: raw),
          isFalse);
      expect((await dao.photoStatus(hash))?.status,
          IngestionStatus.processing);
    });

    test('a lost stamp still wins over a changed meal (ReservationLost)',
        () async {
      final id = await save(hash: 'f' * 32);
      final r = await dao.reservePhotoHash(hash, source: MealSource.appWatch);
      final stale = (await dao.mealSnapshot(id))!.rawAnalysis;
      await dao.updateMealAnalysis(id, {...bowl, 'total_calories': 650});
      await dao.releasePhotoHash(hash); // the launch sweep, say
      await expectLater(
          dao.applyLeftoverVerdict(hash, id, deducted,
              ownerStamp: r.stamp, expectedRaw: stale),
          throwsA(isA<ReservationLost>()));
      expect(jsonDecode((await row(id))['analysis']! as String)
          ['total_calories'], 650);
    });

    test('without expectedRaw: the old unconditional write', () async {
      final id = await save(hash: 'f' * 32);
      final r = await dao.reservePhotoHash(hash, source: MealSource.appWatch);
      await dao.updateMealAnalysis(id, {...bowl, 'total_calories': 650});
      expect(
          await dao.applyLeftoverVerdict(hash, id, deducted,
              ownerStamp: r.stamp),
          isTrue);
      expect(jsonDecode((await row(id))['analysis']! as String)
          ['total_calories'], 500);
    });
  });
}
