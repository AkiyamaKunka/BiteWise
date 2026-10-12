// Real-SQLite tests for the reclaim sweep (spec §2.3 as adjusted for the
// two-isolate reality) — the first DB-backed harness in the suite: the
// reclaim SQL had ZERO tests before this file (loop cycle 2 critical gap).
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ui/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final now = DateTime(2026, 7, 24, 4, 0, 0);

  late Database db;
  late SqfliteMealsDao dao;

  setUp(() async {
    db = await openAppDatabase(path: inMemoryDatabasePath);
    dao = SqfliteMealsDao(db, clock: () => now);
  });

  tearDown(() async => db.close());

  Future<void> seedProcessing(String hash, String source,
      {required Duration age}) async {
    await dao.reservePhotoHash(hash, source: source);
    // Backdate the row: reservePhotoHash stamps last_seen_at = now.
    await db.update(
      'photo_ingestions',
      {'last_seen_at': now.subtract(age).toIso8601String()},
      where: 'image_hash = ?',
      whereArgs: [hash],
    );
  }

  test('STALE app_watch processing rows are RELEASED (deleted), not burned',
      () async {
    await seedProcessing('a' * 32, 'app_watch',
        age: const Duration(minutes: 30));
    await dao.reclaimStaleProcessing();
    // Released row = re-reservable by the strict automated path.
    final again =
        (await dao.reservePhotoHash('a' * 32, source: 'app_watch')).kind;
    expect(again, PhotoReservation.reserved,
        reason: 'released watch rows must be re-offerable — burning them '
            'permanently dropped interrupted photos (live bug 2026-07-23)');
  });

  test('STALE deliberate processing rows are marked failed (retry surface)',
      () async {
    await seedProcessing('b' * 32, 'app_photo',
        age: const Duration(minutes: 30));
    await dao.reclaimStaleProcessing();
    // failed → strict path refuses, deliberate re-add reclaims (spec §2.3).
    expect((await dao.reservePhotoHash('b' * 32, source: 'app_watch')).kind,
        PhotoReservation.claimed);
    expect(
        (await dao.reservePhotoHash('b' * 32,
            source: 'app_photo', reclaimDeliberate: true)).kind,
        PhotoReservation.reserved);
  });

  test('FRESH processing rows are untouched — the other isolate may own them',
      () async {
    await seedProcessing('c' * 32, 'app_watch',
        age: const Duration(minutes: 5)); // < 20-min staleness threshold
    await dao.reclaimStaleProcessing();
    // Still reserved: neither released nor failed — and the refusal names
    // the reason, so the caller waits instead of counting the photo done.
    expect((await dao.reservePhotoHash('c' * 32, source: 'app_watch')).kind,
        PhotoReservation.inFlight,
        reason: 'a live background run\'s reservation must survive the '
            'launch sweep (double-log race otherwise)');
  });

  test('a FRESH processing row is IN FLIGHT for both paths until released',
      () async {
    // The iOS case (2026-10-07): BGAppRefresh expired mid-analysis, the
    // row it reserved is still 'processing'. Neither the next background
    // run nor a user picking the same photo may read that as "already
    // logged" — and neither may steal the analysis.
    await dao.reservePhotoHash('f' * 32, source: 'app_watch');
    expect((await dao.reservePhotoHash('f' * 32, source: 'app_watch')).kind,
        PhotoReservation.inFlight);
    expect(
        (await dao.reservePhotoHash('f' * 32,
            source: 'app_photo', reclaimDeliberate: true)).kind,
        PhotoReservation.inFlight,
        reason: 'deliberate reclaim covers failed/skipped/deleted, never a '
            'live reservation (spec §2.3)');
    // Once the owner releases it (or the launch sweep does), it is simply
    // free again.
    await dao.releasePhotoHash('f' * 32);
    expect((await dao.reservePhotoHash('f' * 32, source: 'app_watch')).kind,
        PhotoReservation.reserved);
  });

  test('the meals-table backstop is CLAIMED even beside a stray processing '
      'row', () async {
    // Ledger/meal divergence (a crash between the two writes, an import):
    // the meal exists, so the photo IS logged. Reading the leftover
    // 'processing' row as in flight would park the background frontier in
    // front of this photo until the row aged out.
    await dao.reservePhotoHash('g' * 32, source: 'app_watch');
    await dao.saveMeal(Meal(
      id: 0,
      date: '2026-07-24',
      time: '12:00 PM',
      timestamp: now.toIso8601String(),
      source: 'app_watch',
      imageHash: 'g' * 32,
      analysis: const {'is_food': true},
    )); // no markStatus: the ledger row stays 'processing'
    expect((await dao.photoStatus('g' * 32))?.status,
        IngestionStatus.processing);
    expect((await dao.reservePhotoHash('g' * 32, source: 'app_watch')).kind,
        PhotoReservation.claimed);
    expect(
        (await dao.reservePhotoHash('g' * 32,
            source: 'app_photo', reclaimDeliberate: true)).kind,
        PhotoReservation.claimed);
  });

  test('meal_thumbs: round-trip, replace, delete cascade (spec §9)', () async {
    final id = await dao.saveMeal(Meal(
      id: 0,
      date: '2026-07-26',
      time: '12:00 PM',
      timestamp: now.toIso8601String(),
      source: 'app_watch',
      imageHash: 'd' * 32,
      analysis: const {'is_food': true},
    ));
    await dao.saveMealThumb(id, Uint8List.fromList([1, 2, 3]));
    expect(await dao.mealThumb(id), [1, 2, 3]);

    await dao.saveMealThumb(id, Uint8List.fromList([9]));
    expect(await dao.mealThumb(id), [9]); // replace, not stack

    await dao.deleteMeal(id);
    expect(await dao.mealThumb(id), isNull,
        reason: 'thumb rides the meal row lifecycle');
  });

  test('photoStatus reads the ledger without writing it', () async {
    expect(await dao.photoStatus('e' * 32), isNull);
    final id = await dao.saveMeal(
      Meal(
        id: 0,
        date: '2026-07-26',
        time: '12:00 PM',
        timestamp: now.toIso8601String(),
        source: 'app_watch',
        imageHash: 'e' * 32,
        analysis: const {'is_food': true},
      ),
      markStatus: IngestionStatus.saved,
    );
    final row = await dao.photoStatus('e' * 32);
    expect(row!.status, IngestionStatus.saved);
    expect(row.mealId, id);
    // Reading must not have created/altered ledger state.
    expect((await dao.reservePhotoHash('e' * 32, source: 'app_watch')).kind,
        PhotoReservation.claimed);
  });

  test('reofferUnsavedVerdicts releases one source\'s skipped/failed rows',
      () async {
    // The iOS repair (2026-09-30): verdicts on unreadable HEIC uploads.
    Future<void> seed(String h, String source, IngestionStatus st) async {
      await dao.reservePhotoHash(h, source: source);
      await dao.markPhotoHash(h, st);
    }

    await seed('1' * 32, 'app_watch', IngestionStatus.skipped);
    await seed('2' * 32, 'app_watch', IngestionStatus.failed);
    await seed('3' * 32, 'app_watch', IngestionStatus.saved);
    await seed('4' * 32, 'app_photo', IngestionStatus.skipped);
    await seed('5' * 32, 'app_photo', IngestionStatus.deleted);
    expect(await dao.reofferUnsavedVerdicts(source: 'app_watch'), 2);
    expect(await dao.photoStatus('1' * 32), isNull);
    expect(await dao.photoStatus('2' * 32), isNull);
    expect((await dao.photoStatus('3' * 32))?.status, IngestionStatus.saved);
    expect((await dao.photoStatus('4' * 32))?.status, IngestionStatus.skipped,
        reason: 'another source is another call');
    expect(await dao.reofferUnsavedVerdicts(source: 'app_photo'), 1);
    expect(await dao.photoStatus('4' * 32), isNull);
    expect((await dao.photoStatus('5' * 32))?.status, IngestionStatus.deleted,
        reason: 'a user deletion is never undone');
  });

  group('a run killed mid-analysis does not park the photo for hours '
      '(2026-10-12)', () {
    // A movable clock: the warm paths below never run the launch sweep.
    var clock = DateTime(2026, 10, 12, 12, 0);
    late SqfliteMealsDao warm;
    setUp(() {
      clock = DateTime(2026, 10, 12, 12, 0);
      warm = SqfliteMealsDao(db, clock: () => clock);
    });

    test('orphan at 12:00 → still in flight at 12:29, reserved at 12:31 for '
        'the automatic scan AND a deliberate pick', () async {
      // 12:00 an iOS BGAppRefresh run reserves both photos, then iOS
      // terminates it mid-analysis.
      for (final h in ['a' * 32, 'b' * 32]) {
        expect((await warm.reservePhotoHash(h, source: MealSource.appWatch)).kind,
            PhotoReservation.reserved);
      }
      // 12:05 cold launch: the sweep leaves a 5-min-old row alone.
      clock = DateTime(2026, 10, 12, 12, 5);
      await warm.reclaimStaleProcessing();
      // Warm resume / background run / deliberate pick: no sweep.
      clock = DateTime(2026, 10, 12, 12, 29);
      expect((await warm.reservePhotoHash('a' * 32, source: MealSource.appWatch)).kind,
          PhotoReservation.inFlight);
      expect(
          (await warm.reservePhotoHash('b' * 32,
              source: MealSource.appPhoto, reclaimDeliberate: true)).kind,
          PhotoReservation.inFlight);
      // Under the server's 6 h this stayed inFlight until 18:00.
      clock = DateTime(2026, 10, 12, 12, 31);
      expect((await warm.reservePhotoHash('a' * 32, source: MealSource.appWatch)).kind,
          PhotoReservation.reserved);
      expect(
          (await warm.reservePhotoHash('b' * 32,
              source: MealSource.appPhoto, reclaimDeliberate: true)).kind,
          PhotoReservation.reserved);
      expect((await warm.photoStatus('b' * 32))?.status,
          IngestionStatus.processing,
          reason: 'reclaimed for the new owner, restamped');
    });

    test('owner path: a run iOS cut off at 12:05 and a cold launch at 12:15 '
        '— the photo is offered again at +31 min, not +91', () async {
      clock = DateTime(2026, 10, 12, 12, 5);
      expect((await warm.reservePhotoHash('o' * 32, source: MealSource.appWatch)).kind,
          PhotoReservation.reserved);
      // 12:15 cold launch: the sweep leaves a 10-min-old row alone.
      clock = DateTime(2026, 10, 12, 12, 15);
      await warm.reclaimStaleProcessing();
      expect((await warm.photoStatus('o' * 32))?.status,
          IngestionStatus.processing);
      // The app is then only resumed (no sweep): still in flight at +30.
      clock = DateTime(2026, 10, 12, 12, 35);
      expect((await warm.reservePhotoHash('o' * 32, source: MealSource.appWatch)).kind,
          PhotoReservation.inFlight);
      clock = DateTime(2026, 10, 12, 12, 36);
      expect((await warm.reservePhotoHash('o' * 32, source: MealSource.appWatch)).kind,
          PhotoReservation.reserved);
    });

    test('westbound flight: an orphan stamped on the Shanghai wall clock is '
        'reclaimable on the Chicago one', () async {
      clock = DateTime(2026, 10, 12, 20, 0);
      await warm.reservePhotoHash('c' * 32, source: MealSource.appWatch);
      clock = DateTime(2026, 10, 12, 10, 0); // 10 h "earlier" after landing
      await warm.reclaimStaleProcessing();
      expect((await warm.reservePhotoHash('c' * 32, source: MealSource.appWatch)).kind,
          PhotoReservation.reserved);
    });

    test('a deliberate pick of a 31-min-old processing row analyzes and '
        'saves — no 正在分析 dead end', () async {
      await warm.reservePhotoHash('h' * 32, source: MealSource.appWatch);
      clock = DateTime(2026, 10, 12, 12, 31);
      var calls = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'meal_description': 'Noodles',
                'total_calories': 500},
            isFood: true,
            wall: Duration.zero)
        ..onAnalyze = () async => calls++;
      final pipeline = PhotoPipeline(
          dao: warm, analyzer: analyzer, hasher: (_) async => 'h' * 32);
      final o = await pipeline.process(IntakePhoto(
          Uint8List.fromList([7]), 'p1', 'p1.jpg',
          deliberate: true, capturedAt: DateTime(2026, 10, 12, 12)));
      expect(o.kind, PhotoOutcomeKind.saved);
      expect(calls, 1);
      final row = await warm.photoStatus('h' * 32);
      expect(row?.status, IngestionStatus.saved);
      expect(row?.mealId, isNotNull);
    });

    test('a stale owner\'s late save lands on the meal already logged — '
        'never a second row', () async {
      Meal meal(String source, String name) => Meal(
            id: 0,
            date: '2026-10-12',
            time: '12:00 PM',
            timestamp: clock.toIso8601String(),
            source: source,
            imageHash: 'd' * 32,
            analysis: {'is_food': true, 'description': name},
          );
      // Owner A reserves at 12:00 and is very slow (or presumed dead).
      await warm.reservePhotoHash('d' * 32, source: MealSource.appWatch);
      // 12:31 a deliberate pick reclaims the stale row and saves.
      clock = DateTime(2026, 10, 12, 12, 31);
      expect(
          (await warm.reservePhotoHash('d' * 32,
              source: MealSource.appPhoto, reclaimDeliberate: true)).kind,
          PhotoReservation.reserved);
      final first = await warm.saveMeal(meal(MealSource.appPhoto, 'B'),
          markStatus: IngestionStatus.saved);
      // 12:32 an UNSTAMPED late save (the backstop alone, no ownership
      // check): it returns B's meal instead of inserting a duplicate.
      clock = DateTime(2026, 10, 12, 12, 32);
      final late = await warm.saveMeal(meal(MealSource.appWatch, 'A'),
          markStatus: IngestionStatus.saved);
      expect(late, first);
      expect(await warm.mealsBetween('2026-10-12', '2026-10-12'), hasLength(1));
      final row = await warm.photoStatus('d' * 32);
      expect(row?.status, IngestionStatus.saved);
      expect(row?.mealId, first);
    });
  });

  group('a run SUSPENDED past the stale age cannot settle a photo it lost '
      '(2026-10-12)', () {
    // iOS backgrounding / Android's freezer: run A is not dead, only
    // paused mid-analysis. Its row goes stale, another path reclaims it,
    // and then A wakes up holding a verdict.
    var clock = DateTime(2026, 10, 12, 12, 0);
    late SqfliteMealsDao warm;
    final hash = 'p' * 32;
    setUp(() {
      clock = DateTime(2026, 10, 12, 12, 0);
      warm = SqfliteMealsDao(db, clock: () => clock);
    });

    IntakePhoto photo({bool deliberate = false}) => IntakePhoto(
        Uint8List.fromList([7]), 'p1', 'p1.jpg',
        deliberate: deliberate, capturedAt: DateTime(2026, 10, 12, 12));

    AnalysisOutcome food(String name) => AnalysisOutcome(
        analysis: {'is_food': true, 'meal_description': name,
            'total_calories': 500},
        isFood: true,
        wall: Duration.zero);

    PhotoPipeline pipeline(FakeAnalyzer analyzer, List<PhotoOutcome> said) =>
        PhotoPipeline(
            dao: warm,
            analyzer: analyzer,
            hasher: (_) async => hash,
            notify: said.add);

    test('A reserves, B reclaims at +31 min and saves → A\'s late verdict '
        'is dropped: one meal, B\'s ledger row, nothing said by A',
        () async {
      final saidA = <PhotoOutcome>[], saidB = <PhotoOutcome>[];
      final b = pipeline(FakeAnalyzer()..nextPhotoOutcome = food('B'), saidB);
      PhotoOutcome? outB;
      final analyzerA = FakeAnalyzer()
        ..nextPhotoOutcome = food('A')
        ..onAnalyze = () async {
          // A is suspended here; 31 min later the open app picks the photo.
          clock = DateTime(2026, 10, 12, 12, 31);
          outB = await b.process(photo(deliberate: true));
        };
      final outA = await pipeline(analyzerA, saidA).process(photo());
      expect(outB?.kind, PhotoOutcomeKind.saved);
      expect(outA.kind, PhotoOutcomeKind.inFlight,
          reason: 'retryable and quiet: the next scan finds it claimed');
      expect(outA.retryable, isTrue);
      expect(saidA, isEmpty, reason: 'no second "meal logged" announcement');
      expect(saidB.map((o) => o.kind), [PhotoOutcomeKind.saved]);
      final meals = await warm.mealsBetween('2026-10-12', '2026-10-12');
      expect(meals, hasLength(1));
      expect(meals.single.analysis['meal_description'], 'B');
      final row = await warm.photoStatus(hash);
      expect(row?.status, IngestionStatus.saved);
      expect(row?.mealId, meals.single.id);
    });

    test('A\'s transient failure does not delete B\'s LIVE reservation',
        () async {
      final said = <PhotoOutcome>[];
      String? stampB;
      final analyzerA = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'Rate limited', retryable: true, wall: Duration.zero)
        ..onAnalyze = () async {
          clock = DateTime(2026, 10, 12, 12, 31);
          final r =
              await warm.reservePhotoHash(hash, source: MealSource.appWatch);
          expect(r.kind, PhotoReservation.reserved);
          stampB = r.stamp;
        };
      final outA = await pipeline(analyzerA, said).process(photo());
      expect(outA.kind, PhotoOutcomeKind.inFlight);
      expect(said, isEmpty);
      expect((await warm.photoStatus(hash))?.status,
          IngestionStatus.processing,
          reason: 'B is still mid-analysis — its row must survive');
      // B finishes normally on its own stamp.
      clock = DateTime(2026, 10, 12, 12, 32);
      final id = await warm.saveMeal(
          Meal(
              id: 0,
              date: '2026-10-12',
              time: '12:00 PM',
              timestamp: clock.toIso8601String(),
              source: MealSource.appWatch,
              imageHash: hash,
              analysis: const {'is_food': true}),
          markStatus: IngestionStatus.saved,
          ownerStamp: stampB);
      expect((await warm.photoStatus(hash))?.mealId, id);
      // And A's stamp can no longer release or mark anything.
      expect(await warm.reservePhotoHash(hash, source: MealSource.appWatch),
          isA<PhotoReservationResult>()
              .having((r) => r.kind, 'kind', PhotoReservation.claimed));
    });

    for (final verdict in ['leftover', 'not food']) {
      test('a manual 手动记录 save while A is LIVE wins over A\'s later '
          '$verdict verdict', () async {
        // An earlier meal on the photo's day: the leftover candidate.
        final lunch = await warm.saveMeal(Meal(
          id: 0,
          date: '2026-10-12',
          time: '11:00 AM',
          timestamp: '2026-10-12T11:00:00.000',
          source: MealSource.appWatch,
          imageHash: 'q' * 32,
          analysis: const {
            'is_food': true,
            'meal_description': 'Tray',
            'total_calories': 965,
            'food_items': [
              {'name': 'Rice (~200 g)', 'estimated_calories': 300},
              {'name': 'Pork (~150 g)', 'estimated_calories': 665},
            ],
          },
        ), markStatus: IngestionStatus.saved);
        final before = (await warm.mealsBetween('2026-10-12', '2026-10-12'))
            .singleWhere((m) => m.id == lunch)
            .analysis;
        final said = <PhotoOutcome>[];
        late int manual;
        final analyzerA = FakeAnalyzer()
          ..nextPhotoOutcome = verdict == 'leftover'
              ? const AnalysisOutcome(analysis: {
                  'is_food': true,
                  'leftover_of': 0,
                  'confidence': 0.9,
                  'leftover_fraction': 0.4,
                  'items': [
                    {'name': 'Rice (~200 g)', 'left_fraction': 1.0},
                    {'name': 'Pork (~150 g)', 'left_fraction': 0.0},
                  ],
                }, isFood: true, wall: Duration.zero)
              : const AnalysisOutcome(
                  analysis: {'is_food': false}, wall: Duration.zero)
          ..onAnalyze = () async {
            // No clock jump: A is live. The user, shown 正在分析, taps
            // 手动记录 and the editor saves exactly like this.
            manual = await warm.saveMeal(
                Meal(
                    id: 0,
                    date: '2026-10-12',
                    time: '12:00 PM',
                    timestamp: '2026-10-12T12:00:30.000',
                    source: MealSource.appManualPhoto,
                    imageHash: hash,
                    analysis: const {'is_food': true, 'total_calories': 300}),
                markStatus: IngestionStatus.saved);
          };
        final outA = await pipeline(analyzerA, said).process(photo());
        expect(outA.kind, PhotoOutcomeKind.inFlight);
        expect(said, isEmpty);
        final meals = await warm.mealsBetween('2026-10-12', '2026-10-12');
        expect(meals.singleWhere((m) => m.id == lunch).analysis, before,
            reason: 'the earlier meal is not cut');
        expect(meals, hasLength(2));
        final row = await warm.photoStatus(hash);
        expect(row?.status, IngestionStatus.saved);
        expect(row?.mealId, manual,
            reason: 'the manual meal keeps its ledger row');
      });
    }

    test('stamped writes on a row the stamp no longer holds throw and write '
        'nothing', () async {
      final a = await warm.reservePhotoHash(hash, source: MealSource.appWatch);
      clock = DateTime(2026, 10, 12, 12, 31);
      final b = await warm.reservePhotoHash(hash, source: MealSource.appWatch);
      expect(b.kind, PhotoReservation.reserved);
      expect(b.stamp, isNot(a.stamp));
      await expectLater(warm.releasePhotoHash(hash, ownerStamp: a.stamp),
          throwsA(isA<ReservationLost>()));
      await expectLater(
          warm.markPhotoHash(hash, IngestionStatus.failed,
              ownerStamp: a.stamp),
          throwsA(isA<ReservationLost>()));
      expect((await warm.photoStatus(hash))?.status,
          IngestionStatus.processing);
      // The current owner settles normally.
      await warm.markPhotoHash(hash, IngestionStatus.skipped,
          ownerStamp: b.stamp);
      expect((await warm.photoStatus(hash))?.status, IngestionStatus.skipped);
    });
  });
}
