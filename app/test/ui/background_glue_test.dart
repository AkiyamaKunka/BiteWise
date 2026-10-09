// Background-glue wiring (spec §6.4 integrator layer): headless drain
// semantics, watermark handling, guard rails, periodic-job registration,
// and the app-shell resume catch-up. This wiring was MISSING entirely at
// first device use — the watcher only worked while the app was foreground —
// so these tests pin every seam of the fix.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/background.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Intake whose backfillScan delivers a scripted batch — mimics the real
/// LibraryPhotoIntake (sink-awaited delivery when attached; stream else).
class EmittingIntake implements PhotoIntake {
  final _controller = StreamController<IntakePhoto>.broadcast();
  List<IntakePhoto> batch = const [];
  List<DateTime?> safeFrontiers = const []; // parallel to batch; pads null
  final List<DateTime?> sinceArgs = [];
  int scans = 0;
  bool throwAfterEmit = false; // scan-abort simulation (library query died)
  DateTime? frontier; // returned from a completed scan
  Future<bool> Function(IntakePhoto, DateTime?)? _sink;

  @override
  Stream<IntakePhoto> get photos => _controller.stream;

  @override
  void attachSink(
          Future<bool> Function(IntakePhoto photo, DateTime? safeFrontier)?
              sink) =>
      _sink = sink;

  @override
  Future<DateTime?> backfillScan(
      {int lookbackDays = 0, DateTime? since}) async {
    scans++;
    sinceArgs.add(since);
    for (var i = 0; i < batch.length; i++) {
      final sink = _sink;
      final safe = i < safeFrontiers.length ? safeFrontiers[i] : null;
      if (sink != null) {
        await sink(batch[i], safe); // backpressured, like the real intake
      } else {
        _controller.add(batch[i]);
      }
    }
    if (throwAfterEmit) throw StateError('library query died mid-scan');
    return frontier;
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class RecordingScheduler implements BackgroundScheduler {
  final List<String> calls = [];
  Duration? frequency;
  Map<String, dynamic>? inputData;

  @override
  Future<void> initialize(Function dispatcher) async => calls.add('init');

  @override
  Future<void> registerPeriodic(String uniqueName, String taskName,
      {required Duration frequency, Map<String, dynamic>? inputData}) async {
    calls.add('register:$uniqueName:$taskName');
    this.frequency = frequency;
    this.inputData = inputData;
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async =>
      calls.add('cancel:$uniqueName');
}

IntakePhoto photo(int n) => IntakePhoto(
    Uint8List.fromList([n, n, n]), 'asset$n', 'IMG_$n.jpg');

/// FakeDao that fires a callback on each saveMeal — used to observe the
/// watermark state at the moment each photo lands.
class _CheckpointSpyDao extends FakeDao {
  _CheckpointSpyDao(this.onSave);
  final void Function() onSave;
  @override
  Future<int> saveMeal(Meal meal, {IngestionStatus? markStatus}) {
    onSave();
    return super.saveMeal(meal, markStatus: markStatus);
  }
}

Future<AppSettings> settingsWith(
    {String? key,
    bool watcher = true,
    int lookback = 2,
    DateTime? quotaPauseUntil}) async {
  SharedPreferences.setMockInitialValues({
    'settings.watcher_enabled': watcher,
    'settings.lookback_days': lookback,
    if (quotaPauseUntil != null)
      'settings.quota_pause_until': quotaPauseUntil.toIso8601String(),
  });
  final prefs = await SharedPreferences.getInstance();
  final keys = MemoryKeyStore();
  if (key != null) keys.data['gemini_api_key'] = key;
  return AppSettings.load(prefs: prefs, keyStore: keys);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('drainBackfill', () {
    test('waits for every emitted photo to finish processing', () async {
      final intake = EmittingIntake()..batch = [photo(1), photo(2), photo(3)];
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      final drain = await drainBackfill(
          intake, PhotoPipeline(dao: dao, analyzer: analyzer));
      expect(drain.scanCompleted, isTrue);
      expect(drain.outcomes, hasLength(3));
      expect(drain.outcomes.map((o) => o.kind),
          everyElement(PhotoOutcomeKind.saved));
      expect(dao.meals, hasLength(3)); // effects landed BEFORE drain returned
    });

    test('a scan abort still processes emitted photos, flags incomplete',
        () async {
      final intake = EmittingIntake()
        ..batch = [photo(1)]
        ..throwAfterEmit = true;
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      final drain = await drainBackfill(
          intake, PhotoPipeline(dao: dao, analyzer: analyzer));
      expect(drain.scanCompleted, isFalse);
      expect(drain.outcomes, hasLength(1)); // emitted photo NOT abandoned
      expect(dao.meals, hasLength(1));
    });

    test('past the deadline photos are RELEASED, not processed (iOS ~30 s)',
        () async {
      // The iOS refresh grant is ~30 s; a photo offered after the budget
      // must come back next run, not be burned as failed — and the
      // outcomes list must not claim it.
      final intake = EmittingIntake()..batch = [photo(1), photo(2), photo(3)];
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      var now = DateTime(2026, 9, 30, 12, 0, 0);
      final deadline = DateTime(2026, 9, 30, 12, 0, 15);
      final drain = await drainBackfill(
          intake, PhotoPipeline(dao: dao, analyzer: analyzer),
          deadline: deadline,
          clock: () => now,
          onOutcome: (_, _, _) async {
            now = now.add(const Duration(seconds: 10)); // each photo: 10 s
          });
      expect(drain.outcomes, hasLength(2), reason: '0 s and 10 s fit');
      expect(drain.cutShort, isTrue);
      expect(dao.meals, hasLength(2));
      // No deadline: everything is processed (Android path unchanged).
      final again = await drainBackfill(
          EmittingIntake()..batch = [photo(4)],
          PhotoPipeline(dao: dao, analyzer: analyzer));
      expect(again.cutShort, isFalse);
    });

    test('unsubscribes its listener afterwards', () async {
      final intake = EmittingIntake()..batch = [photo(1)];
      final dao = FakeDao();
      final analyzer = FakeAnalyzer();
      await drainBackfill(intake, PhotoPipeline(dao: dao, analyzer: analyzer));
      final before = dao.ledger.length;
      await intake.backfillScan(); // nobody listening now
      await pumpEventQueue();
      expect(dao.ledger.length, before);
    });
  });

  group('headlessBackfillWith', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('scans, notifies saved meals, and advances to the FRONTIER',
        () async {
      final settings = await settingsWith(key: 'k');
      final frontierMark = DateTime(2026, 7, 23, 11, 30);
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..frontier = frontierMark;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      final cards = <String>[];
      final scanStart = DateTime(2026, 7, 23, 12, 0);
      final ok = await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: analyzer),
        showMealCard: (title, body) async => cards.add(body),
        clock: () => scanStart,
      );
      expect(ok, isTrue);
      expect(intake.scans, 1);
      expect(intake.sinceArgs.single, isNull); // first run: full window
      expect(cards, hasLength(2));
      // FRONTIER, never scanStart: outcomes can't see photos whose byte
      // read failed, so only the intake's frontier is coverage-honest.
      expect(prefs.getString(backgroundWatermarkPrefsKey),
          frontierMark.toUtc().toIso8601String());
    });

    test('a budget turns into a deadline from the scan start', () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1), photo(2)];
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      var now = DateTime(2026, 9, 30, 12, 0, 0);
      final cards = <String>[];
      final ok = await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: analyzer),
        showMealCard: (title, body) async {
          cards.add(body);
          now = now.add(const Duration(seconds: 20)); // one card blows it
        },
        clock: () => now,
        budget: const Duration(seconds: 15),
      );
      expect(ok, isTrue, reason: 'cut short is still success — no retry storm');
      expect(cards, hasLength(1));
    });

    test('passes the persisted watermark minus the overlap', () async {
      final settings = await settingsWith(key: 'k');
      final mark = DateTime(2026, 7, 23, 11, 0);
      // Zone-less, as builds before the UTC fix wrote it: still local.
      await prefs.setString(
          backgroundWatermarkPrefsKey, mark.toIso8601String());
      final intake = EmittingIntake();
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, _) async {},
      );
      expect(intake.sinceArgs.single, mark.subtract(backgroundScanOverlap));
    });

    test('the watermark is stored as a UTC instant and read back as the '
        'same instant', () async {
      // A zone-less local string re-parsed in a new zone after a flight:
      // Shanghai → Chicago moved it 13 h into the future and the scan
      // skipped the airport and in-flight meals (2026-10-08).
      final settings = await settingsWith(key: 'k');
      final frontierMark = DateTime(2026, 10, 20, 11, 30);
      final first = EmittingIntake()
        ..batch = [photo(1)]
        ..frontier = frontierMark;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: first,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: analyzer),
        showMealCard: (_, _) async {},
        clock: () => DateTime(2026, 10, 20, 12, 0),
      );
      final stored = prefs.getString(backgroundWatermarkPrefsKey)!;
      expect(stored, endsWith('Z'), reason: 'an instant, not a wall time');
      expect(DateTime.parse(stored).isAtSameMomentAs(frontierMark), isTrue);

      final second = EmittingIntake();
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: second,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: analyzer),
        showMealCard: (_, _) async {},
        clock: () => DateTime(2026, 10, 20, 13, 0),
      );
      // Same instant AND local, so the intake's date maths is unchanged.
      expect(second.sinceArgs.single,
          frontierMark.subtract(backgroundScanOverlap));
      expect(second.sinceArgs.single!.isUtc, isFalse);
    });

    test('readStoredInstant gives back the stored instant, in local time',
        () {
      final at = DateTime.utc(2026, 10, 20, 3, 30);
      final read = readStoredInstant(at.toIso8601String())!;
      expect(read.isAtSameMomentAs(at), isTrue);
      expect(read.isUtc, isFalse, reason: 'Settings formats .hour directly');
      expect(readStoredInstant(null), isNull);
      expect(readStoredInstant('garbage'), isNull);
    });

    test('does nothing when the watcher toggle is off', () async {
      final settings = await settingsWith(key: 'k', watcher: false);
      final intake = EmittingIntake();
      final launched = DateTime(2026, 9, 30, 14, 2);
      final ok = await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, _) async {},
        clock: () => launched,
      );
      expect(ok, isTrue); // success — never a WorkManager retry storm
      expect(intake.scans, 0);
      expect(prefs.getString(backgroundWatermarkPrefsKey), isNull);
      // "The OS ran us" is recorded BEFORE any guard — Settings shows it.
      expect(prefs.getString(backgroundLastRunPrefsKey),
          launched.toUtc().toIso8601String());
    });

    test('keeps the launch stamp the production runner already wrote',
        () async {
      final settings = await settingsWith(key: 'k', watcher: false);
      final launched = DateTime.utc(2026, 10, 9, 6, 0);
      await recordBackgroundLaunch(prefs, () => launched);
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: EmittingIntake(),
        pipeline: () async =>
            PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, _) async {},
        clock: () => launched.add(const Duration(milliseconds: 40)),
        launchRecorded: true,
      );
      // One launch, one stamp — not a second, later one.
      expect(prefs.getString(backgroundLastRunPrefsKey),
          launched.toIso8601String());
    });

    test(
        'runHeadlessBackfill stamps the launch BEFORE loading settings, and '
        'a failed load (locked iPhone keychain) still ends as success',
        () async {
      final launched = DateTime.utc(2026, 10, 9, 3, 15);
      String? stampSeenByLoad;
      final ok = await runHeadlessBackfill(
        isIOS: true,
        loadPrefs: () async => prefs,
        clock: () => launched,
        loadSettings: () async {
          stampSeenByLoad = prefs.getString(backgroundLastRunPrefsKey);
          throw PlatformException(code: '-25308'); // InteractionNotAllowed
        },
      );
      expect(ok, isTrue, reason: 'no WorkManager retry storm');
      expect(stampSeenByLoad, launched.toIso8601String());
      // The 后台扫描 row shows iOS ran the task, keys readable or not.
      expect(prefs.getString(backgroundLastRunPrefsKey),
          launched.toIso8601String());
      expect(prefs.getString(backgroundWatermarkPrefsKey), isNull);
    });

    test('does nothing without an API key (photos must not burn to failed)',
        () async {
      final settings = await settingsWith(key: null);
      final intake = EmittingIntake();
      final ok = await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, _) async {},
      );
      expect(ok, isTrue);
      expect(intake.scans, 0);
    });

    test('does nothing while the quota-pause latch is armed', () async {
      final settings = await settingsWith(
          key: 'k',
          quotaPauseUntil: DateTime.now().add(const Duration(hours: 3)));
      final intake = EmittingIntake();
      final ok = await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, _) async {},
      );
      expect(ok, isTrue);
      expect(intake.scans, 0);
      expect(prefs.getString(backgroundWatermarkPrefsKey), isNull);
    });

    test('retryable outcomes hold the final watermark at the frontier',
        () async {
      final settings = await settingsWith(key: 'k');
      final frontierMark = DateTime(2026, 7, 24, 3, 0);
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..frontier = frontierMark; // intake: coverage stops here
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'rate limit', retryable: true, wall: Duration.zero);
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: analyzer),
        showMealCard: (_, _) async {},
        clock: () => DateTime(2026, 7, 24, 5, 0),
      );
      // NOT scanStart: released photos must stay ahead of the watermark.
      expect(prefs.getString(backgroundWatermarkPrefsKey),
          frontierMark.toUtc().toIso8601String());
    });

    test('a photo another run is still analyzing holds the watermark in '
        'front of it', () async {
      // iOS expired the PREVIOUS run's grant mid-analysis: its 'processing'
      // row for photo 2 is still in the ledger (the launch sweep has not
      // run). This run must not checkpoint past photo 2 — the old
      // alreadyTracked reading did exactly that, and the photo was never
      // offered again (2026-10-07).
      final settings = await settingsWith(key: 'k');
      final afterPhoto1 = DateTime(2026, 7, 24, 1, 0);
      final afterPhoto2 = DateTime(2026, 7, 24, 2, 0);
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..safeFrontiers = [afterPhoto1, afterPhoto2]
        ..frontier = afterPhoto1; // the real intake halts where photo 2 is released
      final dao = FakeDao();
      final hash2 = md5.convert(photo(2).bytes).toString();
      dao.ledger[hash2] = IngestionStatus.processing;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: dao, analyzer: analyzer),
        showMealCard: (_, _) async {},
        clock: () => DateTime(2026, 7, 24, 5, 0),
      );
      // Photo 1 landed and checkpointed; photo 2's per-photo checkpoint
      // must NOT have advanced the watermark to afterPhoto2.
      expect(prefs.getString(backgroundWatermarkPrefsKey),
          afterPhoto1.toUtc().toIso8601String());
      expect(dao.meals, hasLength(1));
      expect(dao.ledger[hash2], IngestionStatus.processing,
          reason: 'the other run\'s reservation is left for it, or the '
              'launch sweep, to finish');
    });

    test('per-photo checkpoints persist the intake safeFrontier as they go',
        () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..safeFrontiers = [
          DateTime(2026, 7, 24, 1, 0),
          DateTime(2026, 7, 24, 2, 0),
        ];
      final seenMarks = <String?>[];
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(
            dao: _CheckpointSpyDao(
                () => seenMarks.add(
                    prefs.getString(backgroundWatermarkPrefsKey))),
            analyzer: analyzer),
        showMealCard: (_, _) async {},
        clock: () => DateTime(2026, 7, 24, 5, 0),
      );
      // The SECOND photo's save observed the FIRST photo's checkpoint —
      // proof a WorkManager hard-stop mid-batch keeps prior progress.
      expect(seenMarks.length, 2);
      expect(seenMarks[1],
          DateTime(2026, 7, 24, 1, 0).toUtc().toIso8601String());
    });

    test('an aborted scan does NOT advance the watermark', () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..throwAfterEmit = true;
      final ok = await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, _) async {},
      );
      expect(ok, isTrue); // still WorkManager success — no retry storm
      expect(prefs.getString(backgroundWatermarkPrefsKey), isNull);
    });

    test('failed analyses produce no meal card', () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1)];
      final cards = <String>[];
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, body) async => cards.add(body),
      );
      expect(cards, isEmpty);
    });
  });

  group('syncBackgroundScan', () {
    late RecordingScheduler scheduler;

    setUp(() {
      scheduler = RecordingScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = true;
    });

    tearDown(() {
      debugSchedulerOverride = null;
      debugIsAndroidOverride = null;
    });

    test('enabled → replace-registers the periodic job with settings values',
        () async {
      final settings = await settingsWith(key: 'k', lookback: 5);
      await syncBackgroundScan(settings);
      expect(scheduler.calls, [
        'init',
        'cancel:$photoBackfillUniqueName',
        'register:$photoBackfillUniqueName:$photoBackfillTaskName',
      ]);
      expect(scheduler.frequency, backgroundScanFrequency);
      expect(scheduler.inputData, {'lookbackDays': 5});
    });

    test('watcher off → the job STAYS registered, because the daily '
        'summary rides it too', () async {
      // Regression, 2026-08-16: this used to cancel the periodic job, which
      // silently killed the daily coach notification while its own setting
      // still read as enabled. The scan half self-guards inside
      // headlessBackfillWith, so keeping the job costs no extra scanning.
      final settings = await settingsWith(key: 'k', watcher: false);
      await syncBackgroundScan(settings);
      expect(scheduler.calls, [
        'init',
        'cancel:$photoBackfillUniqueName',
        'register:$photoBackfillUniqueName:$photoBackfillTaskName',
      ]);
      expect(scheduler.frequency, backgroundScanFrequency);
    });
  });

  group('HomeShell iOS daily-card re-arm', () {
    // The OS-scheduled summary (iOS) carries content computed at ARM time,
    // so the shell must re-arm on every moment content can change:
    // lifecycle transitions and meal saves. Both pinned here.
    UiServices services(Future<void> Function() rearm) => UiServices(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          executor: FakeExecutor(),
          settings: FakeSettings(watcherEnabled: false),
          picker: FakePicker(),
          requestPhotoPermission: () async => true,
          reports: FakeReports(),
          refreshDailyNotification: rearm,
        );

    testWidgets('every lifecycle transition re-arms (pause included)',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: HomeShell(services: services(() async => calls++))));
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      expect(calls, 3);
    });

    testWidgets('a meal landing re-arms too', (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: HomeShell(services: services(() async => calls++))));
      signalMealsChanged();
      await tester.pump();
      expect(calls, 1);
    });

    // The chat (修改或删除某餐), describe, manual and leftover paths write
    // meals straight through the DAO — not the photo pipeline that fires
    // the signal — so the add flow's return used to reload Today only: a
    // meal deleted at 23:40 with the app left open was still in the 23:55
    // card (loop find 2026-10-07).
    testWidgets('closing a Meals-sheet screen (chat fix) re-arms',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: HomeShell(services: services(() async => calls++))));
      await tester.pumpAndSettle();
      final before = calls;
      await tester.tap(find.byKey(const Key('addMealFab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('addFixMeal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fixMealField')), findsOneWidget);
      expect(calls, before, reason: 'nothing changed yet');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(calls, before + 1);
    });

    testWidgets('closing the editor opened from a Today meal re-arms',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final dao = FakeDao()
        ..seed(Meal(
          id: 1,
          date: now.toIso8601String().substring(0, 10),
          time: '12:30 PM',
          timestamp: now.toIso8601String(),
          source: 'manual_text',
          analysis: const {
            'is_food': true,
            'meal_description': 'Noodles',
            'total_calories': 500,
          },
        ));
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: HomeShell(
              services: UiServices(
        dao: dao,
        analyzer: FakeAnalyzer(),
        executor: FakeExecutor(),
        settings: FakeSettings(watcherEnabled: false),
        picker: FakePicker(),
        requestPhotoPermission: () async => true,
        reports: FakeReports(),
        refreshDailyNotification: () async => calls++,
      ))));
      await tester.pumpAndSettle();
      final before = calls;
      await tester.tap(find.byKey(const ValueKey('meal1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('saveMealButton')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(calls, before + 1);
    });

    testWidgets('Android (no hook) is untouched', (tester) async {
      final intake = FakeIntake();
      await tester.pumpWidget(MaterialApp(
          home: HomeShell(
              services: UiServices(
        dao: FakeDao(),
        analyzer: FakeAnalyzer(),
        executor: FakeExecutor(),
        settings: FakeSettings(watcherEnabled: false),
        picker: FakePicker(),
        requestPhotoPermission: () async => true,
        photoIntake: intake,
        reports: FakeReports(),
      ))));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      signalMealsChanged();
      await tester.pump();
      // Nothing to assert on beyond "no throw": the hook is null on Android.
      expect(intake.backfillScans, 0);
    });
  });

  group('HomeShell resume catch-up', () {
    UiServices services(FakeIntake intake, {required bool watcher}) =>
        UiServices(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          executor: FakeExecutor(),
          settings: FakeSettings(watcherEnabled: watcher),
          picker: FakePicker(),
          requestPhotoPermission: () async => true,
          photoIntake: intake,
          reports: FakeReports(),
        );

    testWidgets('resumed + watcher on → backfillScan', (tester) async {
      final intake = FakeIntake();
      await tester.pumpWidget(
          MaterialApp(home: HomeShell(services: services(intake, watcher: true))));
      final before = intake.backfillScans;
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(intake.backfillScans, before + 1);
      // Flush the delayed post-scan UI refresh so no timer is left pending.
      await tester.pump(const Duration(seconds: 16));
    });

    testWidgets('watcher off → no scan on resume', (tester) async {
      final intake = FakeIntake();
      await tester.pumpWidget(MaterialApp(
          home: HomeShell(services: services(intake, watcher: false))));
      final before = intake.backfillScans;
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(intake.backfillScans, before);
    });

    testWidgets('paused/inactive states never scan', (tester) async {
      final intake = FakeIntake();
      await tester.pumpWidget(
          MaterialApp(home: HomeShell(services: services(intake, watcher: true))));
      final before = intake.backfillScans;
      // Legal lifecycle order: inactive → hidden → paused.
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(intake.backfillScans, before);
    });
  });
}
