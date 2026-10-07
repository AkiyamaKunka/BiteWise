// Coverage audit (spec §9): classification against the ledger, missing
// detection, truncation honesty, and loadForProcessing round-trips.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/watcher.dart'
    show backfillQueryLimit;
import 'package:flutter_test/flutter_test.dart';

import '../ui/fakes.dart' show FakeDao;
import 'watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;

/// Test hasher: hex-free but deterministic — `h<firstByte>`.
Future<String> testHash(List<int> bytes) async => 'h${bytes.first}';

void main() {
  final now = DateTime(2026, 7, 26, 12, 0);

  late FakePhotoLibrary library;
  late FakeDao dao;
  late CoverageAuditor auditor;

  setUp(() {
    library = FakePhotoLibrary();
    dao = FakeDao();
    auditor = CoverageAuditor(
        library: library, dao: dao, hasher: testHash, clock: () => now);
  });

  FakeAsset asset(int n, {String? name, DateTime? at, Uint8List? bytes}) =>
      FakeAsset('a$n', name ?? 'IMG_$n.jpg',
          at ?? DateTime(2026, 7, 26, 8, n), bytes ?? bytesOf(n));

  test('classifies every ledger state and finds the missing photo', () async {
    library.assets = [
      asset(1), // saved → logged
      asset(2), // skipped (non-food)
      asset(3), // failed
      asset(4), // deleted
      asset(5), // processing
      asset(6), // NOT in the ledger → missing
    ];
    dao.ledger['h1'] = IngestionStatus.saved;
    dao.ledger['h2'] = IngestionStatus.skipped;
    dao.ledger['h3'] = IngestionStatus.failed;
    dao.ledger['h4'] = IngestionStatus.deleted;
    dao.ledger['h5'] = IngestionStatus.processing;
    dao.seed(Meal(
      id: 42,
      date: '2026-07-26',
      time: '08:01 AM',
      timestamp: 'x',
      source: 'app_watch',
      imageHash: 'h1',
      analysis: const {'is_food': true},
    ));

    final report = await auditor.audit(lookbackDays: 2);
    expect(report.scanned, 6);
    expect(report.logged.single.mealId, 42);
    expect(report.skippedNonFood, hasLength(1));
    expect(report.failed.single.assetId, 'a3');
    expect(report.deleted, 1);
    expect(report.inFlight, 1);
    expect(report.missing.single.assetId, 'a6');
    expect(report.missing.single.fileName, 'IMG_6.jpg');
    expect(report.fullyCovered, isFalse);
  });

  test('fully covered when everything is accounted for', () async {
    library.assets = [asset(1), asset(2)];
    dao.ledger['h1'] = IngestionStatus.saved;
    dao.ledger['h2'] = IngestionStatus.skipped;
    final report = await auditor.audit(lookbackDays: 2);
    expect(report.fullyCovered, isTrue);
    expect(report.missing, isEmpty);
  });

  Meal leftoverMeal(int id, String date, String md5) => Meal(
        id: id,
        date: date,
        time: '12:00 PM',
        timestamp: 'x',
        source: 'app_watch',
        analysis: {
          'is_food': true,
          'total_calories': 300,
          'leftover': {'leftover_photo_md5': md5, 'applied_total': 300},
        },
      );

  test('a leftover photo is NOT "not food": its own count, no re-analysis',
      () async {
    // Both leftover paths tombstone the photo 'skipped' — the same status as
    // the model's "not food" verdict. Listed under not-food, its re-analyze
    // button logged the remains as a NEW meal on top of the original that
    // had already been reduced (double count).
    library.assets = [asset(2), asset(3)];
    dao.ledger['h2'] = IngestionStatus.skipped; // leftover of meal 7
    dao.ledger['h3'] = IngestionStatus.skipped; // plain "not food"
    dao.seed(leftoverMeal(7, '2026-07-26', 'H2')); // case-insensitive md5

    final report = await auditor.audit(lookbackDays: 2);
    expect(report.leftoverApplied, 1);
    expect(report.skippedNonFood.single.assetId, 'a3',
        reason: 'a real not-food verdict still gets the re-analyze offer');
    expect(report.fullyCovered, isTrue);
  });

  test("a leftover deducted from YESTERDAY's meal is recognised at the "
      'window edge', () async {
    // The manual flow offers yesterday's meals; a 1-day window starts today.
    library.assets = [asset(2)];
    dao.ledger['h2'] = IngestionStatus.skipped;
    dao.seed(leftoverMeal(7, '2026-07-25', 'h2'));
    final report = await auditor.audit(lookbackDays: 1);
    expect(report.leftoverApplied, 1);
    expect(report.skippedNonFood, isEmpty);
  });

  test('a leftover md5 only reclassifies SKIPPED rows', () async {
    // The manual flow may record a photo that is some meal's own saved
    // photo; that row stays "logged".
    library.assets = [asset(1)];
    dao.ledger['h1'] = IngestionStatus.saved;
    dao.seed(leftoverMeal(7, '2026-07-26', 'h1'));
    final report = await auditor.audit(lookbackDays: 2);
    expect(report.logged, hasLength(1));
    expect(report.leftoverApplied, 0);
  });

  test('unreadable bytes are counted, not crashed on, not "missing"',
      () async {
    library.assets = [
      asset(1),
      FakeAsset('gone', 'IMG_gone.jpg', DateTime(2026, 7, 26, 9), null),
    ];
    dao.ledger['h1'] = IngestionStatus.saved;
    final report = await auditor.audit(lookbackDays: 2);
    expect(report.unreadable, 1);
    expect(report.missing, isEmpty);
    expect(report.fullyCovered, isFalse); // can't promise coverage
  });

  test('oversize photos get their OWN honest bucket, never "not food"',
      () async {
    library.assets = [
      FakeAsset('big', 'IMG_big.jpg', DateTime(2026, 7, 26, 9),
          Uint8List(maxPhotoBytes + 1)),
    ];
    final report = await auditor.audit(lookbackDays: 2);
    expect(report.missing, isEmpty); // intake refuses them by design (§8)
    expect(report.skippedNonFood, isEmpty,
        reason: 'calling an unanalyzable photo "not food" was a lie');
    expect(report.tooLargeToAnalyze, 1);
    expect(report.fullyCovered, isFalse,
        reason: 'a photo that can never be logged is not "accounted for"');
  });

  test('limited photo access denies the full-coverage claim', () async {
    library.assets = [asset(1)];
    dao.ledger['h1'] = IngestionStatus.saved;
    library.fullAccess = false;
    final report = await auditor.audit(lookbackDays: 2);
    expect(report.limitedAccess, isTrue);
    expect(report.fullyCovered, isFalse,
        reason: 'the audit only saw the granted subset');
  });

  test('a capped window reports truncated and never claims full coverage',
      () async {
    library.assets = List.generate(
        backfillQueryLimit,
        (i) => FakeAsset('t$i', 'IMG_t$i.jpg',
            DateTime(2026, 7, 26, 6, i ~/ 60, i % 60), bytesOf(1)));
    dao.ledger['h1'] = IngestionStatus.saved; // all share bytesOf(1) → h1
    final report = await auditor.audit(lookbackDays: 30);
    expect(report.truncated, isTrue);
    expect(report.fullyCovered, isFalse);
  });

  test('progress runs 0..total inclusive', () async {
    library.assets = [asset(1), asset(2), asset(3)];
    final seen = <(int, int)>[];
    await auditor.audit(
        lookbackDays: 2, onProgress: (d, t) => seen.add((d, t)));
    expect(seen.first, (0, 3));
    expect(seen.last, (3, 3));
  });

  test('loadForProcessing round-trips a missing item as a DELIBERATE photo',
      () async {
    library.assets = [
      asset(6, name: 'IMG_20260726_080600.jpg'),
    ];
    final report = await auditor.audit(lookbackDays: 2);
    final photo =
        await auditor.loadForProcessing(report.missing.single);
    expect(photo, isNotNull);
    expect(photo!.assetId, 'a6');
    expect(photo.deliberate, isTrue); // user-initiated: may reclaim failed
    expect(photo.bytes, bytesOf(6));
    expect(photo.capturedAt, DateTime(2026, 7, 26, 8, 6, 0));
  });

  test('loadForProcessing returns null when the asset vanished', () async {
    library.assets = [asset(6)];
    final report = await auditor.audit(lookbackDays: 2);
    library.assets = []; // deleted from the gallery meanwhile
    expect(await auditor.loadForProcessing(report.missing.single), isNull);
  });
}
