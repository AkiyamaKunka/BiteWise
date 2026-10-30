// A glasses-session photo enters the app's ONE photo pipeline as
// deliberate intake written as 'app_glasses' (feat/meta-dat prototype):
// the adapter (lib/services/glasses/glasses_intake.dart), the pipeline's
// source hook, and the real SQLite ledger's handling of the new source.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/glasses/glasses_intake.dart';
import 'package:calorie_tracker/services/glasses/meta_dat_channel.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ui/fakes.dart';
import 'fake_meta_dat_native.dart';

const _food = AnalysisOutcome(
    analysis: {
      'is_food': true,
      'meal_description': 'Burger and fries',
      'total_calories': 900
    },
    isFood: true,
    wall: Duration.zero);

/// Records what the pipeline reserved with.
class _RecordingDao extends FakeDao {
  final reserved = <({String source, bool reclaim})>[];
  @override
  Future<PhotoReservationResult> reservePhotoHash(String imageHash,
      {required String source, bool reclaimDeliberate = false}) {
    reserved.add((source: source, reclaim: reclaimDeliberate));
    return super.reservePhotoHash(imageHash,
        source: source, reclaimDeliberate: reclaimDeliberate);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 10, 23, 12, 31);
  final shotAt = DateTime(2026, 10, 23, 12, 30, 5);

  test('the wire value is app_glasses; the old intakes keep theirs', () {
    expect(MealSource.appGlasses, 'app_glasses');
    final picked = IntakePhoto(Uint8List(1), 'a', 'a.jpg', deliberate: true);
    final watched = IntakePhoto(Uint8List(1), 'a', 'a.jpg');
    expect(picked.source, MealSource.appPhoto);
    expect(watched.source, MealSource.appWatch);
  });

  group('glassesIntakePhoto', () {
    test('deliberate, app_glasses, no asset, dated by the phone', () {
      final p = glassesIntakePhoto(
          MetaDatPhoto(fakeJpeg(), MetaDatPhotoFormat.jpeg, shotAt),
          now: () => now);
      expect(p, isA<GlassesIntakePhoto>());
      expect(p.deliberate, isTrue);
      expect(p.source, MealSource.appGlasses);
      expect(p.assetId, '');
      expect(p.bytes, fakeJpeg());
      expect(p.capturedAt, shotAt);
      expect(p.fileName, 'meta_glasses_20261023_123005.jpg');
    });

    test('an HEIC keeps its extension', () {
      final p = glassesIntakePhoto(
          MetaDatPhoto(fakeHeic(), MetaDatPhotoFormat.heic, shotAt),
          now: () => now);
      expect(p.fileName, endsWith('.heic'));
    });

    test('an impossible receive time is dropped, not trusted', () {
      for (final at in [
        now.add(const Duration(days: 2)), // ahead of the phone
        now.subtract(const Duration(days: 400)), // a dead clock
      ]) {
        final p = glassesIntakePhoto(
            MetaDatPhoto(fakeJpeg(), MetaDatPhotoFormat.jpeg, at),
            now: () => now);
        expect(p.capturedAt, isNull, reason: '$at');
      }
    });
  });

  group('through the pipeline', () {
    test('the meal and its reservation say app_glasses; deliberate rules',
        () async {
      final dao = _RecordingDao();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _food;
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          hasher: (_) async => 'a' * 32,
          thumbnailer: (_) async => null);
      final outcome = await pipeline.enqueue(glassesIntakePhoto(
          MetaDatPhoto(fakeJpeg(), MetaDatPhotoFormat.jpeg, shotAt),
          now: () => now));
      expect(outcome.kind, PhotoOutcomeKind.saved);
      expect(dao.reserved.single, (source: 'app_glasses', reclaim: true));
      final meal = dao.savedMeals.single;
      expect(meal.source, 'app_glasses');
      expect(meal.date, '2026-10-23');
      expect(meal.time, '12:30 PM');
      expect(meal.fileId, '');
    });

    test('a picked photo is still app_photo, a watched one app_watch',
        () async {
      final dao = _RecordingDao();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _food;
      var n = 0;
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          hasher: (_) async => '${n++}' * 32,
          thumbnailer: (_) async => null);
      await pipeline.enqueue(IntakePhoto(fakeJpeg(), 'p', 'p.jpg',
          capturedAt: shotAt, deliberate: true));
      await pipeline.enqueue(
          IntakePhoto(fakeJpeg(2), 'w', 'w.jpg', capturedAt: shotAt));
      expect([for (final r in dao.reserved) r.source],
          ['app_photo', 'app_watch']);
      expect([for (final m in dao.savedMeals) m.source],
          ['app_photo', 'app_watch']);
    });
  });

  group('real SQLite ledger', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    late Database db;
    late SqfliteMealsDao dao;
    var clock = now;

    setUp(() async {
      clock = now;
      db = await openAppDatabase(path: inMemoryDatabasePath);
      dao = SqfliteMealsDao(db, clock: () => clock);
    });
    tearDown(() async => db.close());

    test('meals and photo_ingestions store app_glasses', () async {
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: FakeAnalyzer()..nextPhotoOutcome = _food,
          hasher: (_) async => 'b' * 32,
          thumbnailer: (_) async => null);
      final outcome = await pipeline.enqueue(glassesIntakePhoto(
          MetaDatPhoto(fakeJpeg(), MetaDatPhotoFormat.jpeg, shotAt),
          now: () => now));
      expect(outcome.kind, PhotoOutcomeKind.saved);
      final meal = (await db.query('meals')).single;
      expect(meal['source'], 'app_glasses');
      final row = (await db.query('photo_ingestions')).single;
      expect(row['source'], 'app_glasses');
      expect(row['status'], 'saved');
    });

    test('an interrupted glasses photo is kept for a retry, like a picked one',
        () async {
      // The launch sweep RELEASES only app_watch rows; a deliberate row
      // (picker, share, glasses) turns 'failed' so the user-visible retry
      // owns it — and a deliberate re-send reclaims it.
      await dao.reservePhotoHash('c' * 32, source: MealSource.appGlasses);
      clock = now.add(const Duration(hours: 1));
      await dao.reclaimStaleProcessing();
      final row = (await db.query('photo_ingestions')).single;
      expect(row['status'], 'failed');
      expect(
          (await dao.reservePhotoHash('c' * 32,
                  source: MealSource.appGlasses, reclaimDeliberate: true))
              .kind,
          PhotoReservation.reserved);
    });
  });
}
