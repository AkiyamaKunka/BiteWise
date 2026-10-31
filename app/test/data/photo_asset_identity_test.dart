// Photo identity beyond md5 (B1, run 7), against REAL SQLite with the real
// LibraryPhotoIntake and PhotoPipeline.
//
// A photo the user EDITS in Photos after it was logged reads back as new
// bytes (photo_manager's iOS originBytes is the rendered edit; an Android
// in-place save overwrites the file), so a new md5. Every launch's
// catch-up rescans the lookback window with an empty seen-set, so the
// edited photo was analyzed again: a second meal, or a leftover cut of the
// first. Automatic intake now also knows a photo by its library asset.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Asset implements LibraryAsset {
  _Asset(this.id, this.createDateTime, this.bytes);
  @override
  final String id;
  @override
  final DateTime createDateTime;

  /// Mutable: an edit in Photos changes what originBytes reads.
  Uint8List bytes;
  @override
  Future<String> fileName() async => 'IMG_0042.HEIC';
  @override
  Future<Uint8List?> originBytes() async => bytes;
}

class _Library implements PhotoLibrary {
  final List<_Asset> assets = [];
  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId,
          {int size = 160}) async =>
      null;
  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) async =>
      assets.where((a) => a.id == assetId).firstOrNull?.bytes;
  @override
  Future<bool> hasFullAccess() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
          {int limit = 500}) async =>
      assets
          .where((a) => !a.createDateTime.isBefore(cutoff))
          .take(limit)
          .toList();
  @override
  Future<List<LibraryAsset>> recentImages(int limit) async =>
      assets.take(limit).toList();
  @override
  Future<void> startChangeNotify(void Function() onChange) async {}
  @override
  Future<void> stopChangeNotify() async {}
}

class _MealAnalyzer implements AnalyzerService {
  int calls = 0;
  @override
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals}) async {
    calls++;
    return const AnalysisOutcome(
        analysis: {
          'is_food': true,
          'meal_description': 'Beef noodle soup',
          'total_calories': 650,
        },
        isFood: true,
        wall: Duration.zero);
  }

  @override
  Future<Map<String, dynamic>?> textIntent(String prompt) async => null;
  @override
  Future<String?> validateKey(String apiKey) async => null;
  @override
  Future<Map<String, dynamic>?> leftoverIntent(
          Uint8List originalBytes, String originalCompact) async =>
      null;
  @override
  Future<KeyProbe> probeKey(String apiKey) async =>
      const KeyProbe(KeyProbeResult.ok);
}

Uint8List _bytes(int seed) =>
    Uint8List.fromList(List.generate(64, (i) => (i * seed + seed) % 256));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Friday 2026-10-30, 19:30 local.
  final now = DateTime(2026, 10, 30, 19, 30);
  late Database db;
  late SqfliteMealsDao dao;
  late _Library library;
  late _MealAnalyzer analyzer;

  setUp(() async {
    db = await openAppDatabase(path: inMemoryDatabasePath);
    dao = SqfliteMealsDao(db, clock: () => now);
    library = _Library();
    analyzer = _MealAnalyzer();
  });
  tearDown(() async => db.close());

  PhotoPipeline pipeline() => PhotoPipeline(
      dao: dao,
      analyzer: analyzer,
      hasher: (b) async => originalBytesMd5(b),
      thumbnailer: (_) async => null,
      clock: () => now);

  /// One app session: a fresh intake (empty seen-set) and pipeline over the
  /// SAME database, running the launch catch-up over the lookback window.
  Future<void> launchCatchUp() async {
    final intake = LibraryPhotoIntake(
        lookbackDays: () => 2, library: library, clock: () => now);
    pipeline().bind(intake);
    await intake.backfillScan();
  }

  Future<List<Meal>> mealsOf(String assetId) async =>
      (await dao.mealsBetween('2026-10-01', '2026-10-31'))
          .where((m) => m.fileId == assetId)
          .toList();

  _Asset lunch({String id = 'PH-ASSET-1/L0/001', int seed = 1}) {
    final a = _Asset(id, DateTime(2026, 10, 30, 12, 5), _bytes(seed));
    library.assets.add(a);
    return a;
  }

  group('an automatic photo edited after its meal was logged', () {
    test('is not analyzed or logged a second time', () async {
      final asset = lunch();
      await launchCatchUp();
      final logged = await mealsOf(asset.id);
      expect(logged, hasLength(1));

      asset.bytes = _bytes(7); // cropped in Photos: same asset, new bytes
      await launchCatchUp(); // the next launch / resume

      expect(analyzer.calls, 1,
          reason: 'the same asset was uploaded and analyzed again');
      expect(await mealsOf(asset.id), hasLength(1),
          reason: 'one photo, one lunch');
      // The edited copy's hash is ledgered as THAT meal's.
      final edited = await dao.photoStatus(originalBytesMd5(asset.bytes));
      expect(edited?.status, IngestionStatus.saved);
      expect(edited?.mealId, logged.single.id);
    });

    test('counts as logged, not missing, in the coverage check', () async {
      final asset = lunch();
      await launchCatchUp();
      asset.bytes = _bytes(7);
      await launchCatchUp();

      final report = await CoverageAuditor(
              library: library,
              dao: dao,
              hasher: (b) async => originalBytesMd5(b),
              clock: () => now)
          .audit(lookbackDays: 2);
      expect(report.missing, isEmpty,
          reason: '"Log all" would have logged it a second time');
      expect(report.logged.map((i) => i.assetId), [asset.id]);
      expect(report.logged.single.mealId, (await mealsOf(asset.id)).single.id);
    });

    test('a later scan answers from the ledger, without asking again',
        () async {
      final asset = lunch();
      await launchCatchUp();
      asset.bytes = _bytes(7);
      await launchCatchUp();
      final outcome = await pipeline().process(IntakePhoto(
          asset.bytes, asset.id, 'IMG_0042.HEIC',
          capturedAt: asset.createDateTime));
      expect(outcome.kind, PhotoOutcomeKind.alreadyTracked);
      expect(analyzer.calls, 1);
    });

    test('deleting the meal frees its edited copy for a deliberate re-add',
        () async {
      final asset = lunch();
      await launchCatchUp();
      asset.bytes = _bytes(7);
      await launchCatchUp();
      final editedHash = originalBytesMd5(asset.bytes);

      await dao.deleteMeal((await mealsOf(asset.id)).single.id);
      // Not left 'saved' pointing at a meal that is gone.
      expect((await dao.photoStatus(editedHash))?.status,
          IngestionStatus.deleted);
      expect((await dao.photoStatus(editedHash))?.mealId, isNull);

      // Automatic intake leaves it alone (a deleted meal stays deleted)…
      await launchCatchUp();
      expect(await mealsOf(asset.id), isEmpty);
      expect(analyzer.calls, 1);

      // …and the user picking it on purpose logs it.
      final out = await pipeline().process(IntakePhoto(
          asset.bytes, asset.id, 'IMG_0042.HEIC',
          capturedAt: asset.createDateTime, deliberate: true));
      expect(out.kind, PhotoOutcomeKind.saved);
      expect(await mealsOf(asset.id), hasLength(1));
    });
  });

  test('a deliberate add of an edited copy is decided by its bytes, as '
      'before', () async {
    final asset = lunch();
    await launchCatchUp();
    asset.bytes = _bytes(7);
    // Picked in the add flow before any scan saw the edit: the user asked
    // for it, so it is logged (md5 identity, unchanged).
    final out = await pipeline().process(IntakePhoto(
        asset.bytes, asset.id, 'IMG_0042.HEIC',
        capturedAt: asset.createDateTime, deliberate: true));
    expect(out.kind, PhotoOutcomeKind.saved);
    expect(analyzer.calls, 2);
  });

  test('an unedited photo is still recognised by its bytes alone', () async {
    final asset = lunch();
    await launchCatchUp();
    await launchCatchUp();
    expect(analyzer.calls, 1);
    expect(await mealsOf(asset.id), hasLength(1));
  });

  test("another day's meal with the same asset id does not claim a new "
      'photo', () async {
    // A restored backup from another Android phone: MediaStore ids are
    // small integers, so its meals' file_ids can repeat on this phone.
    await dao.saveMeal(
        Meal(
          id: 0,
          date: '2026-10-25',
          time: '12:00 PM',
          timestamp: '2026-10-25T12:00:00.000',
          source: MealSource.appWatch,
          imageHash: 'f' * 32,
          fileId: '1234',
          analysis: const {'is_food': true, 'total_calories': 400},
        ),
        markStatus: IngestionStatus.saved);
    lunch(id: '1234', seed: 3);
    await launchCatchUp();
    expect(analyzer.calls, 1);
    expect(await mealsOf('1234'), hasLength(2));
  });

  group('reservePhotoHash asset rule', () {
    Future<int> mealFor(String assetId, String date) => dao.saveMeal(
        Meal(
          id: 0,
          date: date,
          time: '12:00 PM',
          timestamp: '${date}T12:00:00.000',
          source: MealSource.appWatch,
          imageHash: 'a' * 32,
          fileId: assetId,
          analysis: const {'is_food': true, 'total_calories': 500},
        ),
        markStatus: IngestionStatus.saved);

    test('matches a meal dated within a day of the capture, no further',
        () async {
      await mealFor('asset-x', '2026-10-29');
      final dayAfter = await dao.reservePhotoHash('b' * 32,
          source: MealSource.appWatch,
          assetId: 'asset-x',
          capturedAt: DateTime(2026, 10, 30, 0, 30));
      expect(dayAfter.kind, PhotoReservation.claimed);
      final twoDaysAfter = await dao.reservePhotoHash('c' * 32,
          source: MealSource.appWatch,
          assetId: 'asset-x',
          capturedAt: DateTime(2026, 10, 31, 9));
      expect(twoDaysAfter.kind, PhotoReservation.reserved);
    });

    test('needs both the asset and the capture time, and never applies to '
        'a deliberate add', () async {
      await mealFor('asset-y', '2026-10-30');
      final when = DateTime(2026, 10, 30, 12);
      expect(
          (await dao.reservePhotoHash('d' * 32,
                  source: MealSource.appWatch, assetId: 'asset-y'))
              .kind,
          PhotoReservation.reserved);
      expect(
          (await dao.reservePhotoHash('e' * 32,
                  source: MealSource.appWatch, capturedAt: when))
              .kind,
          PhotoReservation.reserved);
      expect(
          (await dao.reservePhotoHash('9' * 32,
                  source: MealSource.appPhoto,
                  reclaimDeliberate: true,
                  assetId: 'asset-y',
                  capturedAt: when))
              .kind,
          PhotoReservation.reserved);
    });

    test('deleteMeal leaves rows of OTHER meals alone', () async {
      final keep = await mealFor('asset-k', '2026-10-30');
      final drop = await dao.saveMeal(
          Meal(
            id: 0,
            date: '2026-10-30',
            time: '01:00 PM',
            timestamp: '2026-10-30T13:00:00.000',
            source: MealSource.appWatch,
            imageHash: '7' * 32,
            fileId: 'asset-d',
            analysis: const {'is_food': true, 'total_calories': 300},
          ),
          markStatus: IngestionStatus.saved);
      // An edited copy of each.
      final when = DateTime(2026, 10, 30, 12);
      await dao.reservePhotoHash('1' * 32,
          source: MealSource.appWatch, assetId: 'asset-k', capturedAt: when);
      await dao.reservePhotoHash('2' * 32,
          source: MealSource.appWatch, assetId: 'asset-d', capturedAt: when);

      await dao.deleteMeal(drop);
      expect((await dao.photoStatus('2' * 32))?.status,
          IngestionStatus.deleted);
      expect((await dao.photoStatus('7' * 32))?.status,
          IngestionStatus.deleted);
      final kept = await dao.photoStatus('1' * 32);
      expect(kept?.status, IngestionStatus.saved);
      expect(kept?.mealId, keep);
      expect((await dao.photoStatus('a' * 32))?.mealId, keep);
    });
  });
}
