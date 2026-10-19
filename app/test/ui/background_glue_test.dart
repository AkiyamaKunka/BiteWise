// Background-glue wiring (spec §6.4 integrator layer): headless drain
// semantics, watermark handling, guard rails, periodic-job registration,
// and the app-shell resume catch-up. This wiring was MISSING entirely at
// first device use — the watcher only worked while the app was foreground —
// so these tests pin every seam of the fix.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart' show AnalysisErrorKind;
import 'package:calorie_tracker/services/analyzer/gemini_analyzer.dart'
    show GeminiAnalyzer;
import 'package:calorie_tracker/services/analyzer/normalize.dart'
    show kAnalysisJpegQuality, kAnalysisLongSidePx, normalizeForAnalysis;
import 'package:calorie_tracker/services/analyzer/platform_decode.dart'
    show decodeForUpload, imageIOChannel, isHeadlessEngine;
import 'package:calorie_tracker/services/photo/background.dart';
import 'package:calorie_tracker/services/photo/background_runs.dart';
import 'package:calorie_tracker/services/photo/deferred_assets.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/coach_strings.dart' show localizationsFor;
import 'package:calorie_tracker/ui/outcome_text.dart' show autoScanPausedLine;
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart' show MockClient;
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Intake whose backfillScan delivers a scripted batch — mimics the real
/// LibraryPhotoIntake (sink-awaited delivery when attached; stream else).
class EmittingIntake implements PhotoIntake {
  final _controller = StreamController<IntakePhoto>.broadcast();
  List<IntakePhoto> batch = const [];
  List<DateTime?> safeFrontiers = const []; // parallel to batch; pads null
  final List<DateTime?> sinceArgs = [];
  final List<bool> newestDayFirstArgs = [];
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

  /// Photos the scan left unread because shouldContinue said stop.
  int unread = 0;

  @override
  Future<DateTime?> backfillScan(
      {int lookbackDays = 0,
      DateTime? since,
      bool Function()? shouldContinue,
      Future<void> Function(DateTime safeFrontier)? onCovered,
      bool newestDayFirst = false}) async {
    scans++;
    sinceArgs.add(since);
    newestDayFirstArgs.add(newestDayFirst);
    for (var i = 0; i < batch.length; i++) {
      // Asked before the (here notional) byte read, like the real intake.
      if (shouldContinue != null && !shouldContinue()) {
        unread++;
        continue;
      }
      final sink = _sink;
      final safe = i < safeFrontiers.length ? safeFrontiers[i] : null;
      if (sink != null) {
        // Backpressured, like the real intake.
        final terminal = await sink(batch[i], safe);
        if (terminal && safe != null) await onCovered?.call(safe);
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

/// Intake that spends [before] (reading and hashing the photos ahead of
/// it, iCloud downloads included) and only then offers [photo].
class _LateIntake implements PhotoIntake {
  _LateIntake(this.photo, {required this.before});
  final IntakePhoto photo;
  final Duration before;
  Future<bool> Function(IntakePhoto, DateTime?)? _sink;

  @override
  Stream<IntakePhoto> get photos => const Stream.empty();

  @override
  void attachSink(
          Future<bool> Function(IntakePhoto photo, DateTime? safeFrontier)?
              sink) =>
      _sink = sink;

  @override
  Future<DateTime?> backfillScan(
      {int lookbackDays = 0,
      DateTime? since,
      bool Function()? shouldContinue,
      Future<void> Function(DateTime safeFrontier)? onCovered,
      bool newestDayFirst = false}) async {
    await Future<void>.delayed(before);
    await _sink?.call(photo, null);
    return null;
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

/// A FakeDao that notes WHEN a reservation was released.
class _ReleaseClockDao extends FakeDao {
  _ReleaseClockDao(this.clock);
  final DateTime Function() clock;
  DateTime? releasedAt;

  @override
  Future<void> releasePhotoHash(String imageHash, {String? ownerStamp}) {
    releasedAt = clock();
    return super.releasePhotoHash(imageHash, ownerStamp: ownerStamp);
  }
}

/// A pipeline that answers each photo with the next scripted outcome —
/// for outcome kinds a FakeAnalyzer cannot reach on its own.
class _ScriptedPipeline extends PhotoPipeline {
  _ScriptedPipeline(this.outcomes)
      : super(dao: FakeDao(), analyzer: FakeAnalyzer());
  final List<PhotoOutcome> outcomes;
  var _next = 0;

  @override
  Future<PhotoOutcome> process(IntakePhoto photo) async =>
      outcomes[_next++];
}

/// FakeDao that fires a callback on each saveMeal — used to observe the
/// watermark state at the moment each photo lands.
class _CheckpointSpyDao extends FakeDao {
  _CheckpointSpyDao(this.onSave);
  final void Function() onSave;
  @override
  Future<int> saveMeal(Meal meal,
      {IngestionStatus? markStatus, String? ownerStamp}) {
    onSave();
    return super
        .saveMeal(meal, markStatus: markStatus, ownerStamp: ownerStamp);
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

    test('past the deadline the intake is told to stop BEFORE reading, and '
        'every photo it left counts as released', () async {
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2), photo(3), photo(4)];
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero);
      var now = DateTime(2026, 9, 30, 12, 0, 0);
      final drain = await drainBackfill(
          intake, PhotoPipeline(dao: dao, analyzer: analyzer),
          deadline: DateTime(2026, 9, 30, 12, 0, 15),
          clock: () => now,
          onOutcome: (_, _, _) async {
            now = now.add(const Duration(seconds: 10));
          });
      expect(drain.outcomes, hasLength(2));
      expect(intake.unread, 2, reason: 'photos 3 and 4 were never read');
      expect(drain.cutShort, isTrue);
      expect(drain.deadlineReleases, 2);
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

  // 2026-10-18: one entry per background run, rewritten at every step
  // (background_runs.dart) — the record the frozen-watermark days lacked.
  group('the background-run record', () {
    late SharedPreferences prefs;
    final t0 = DateTime.utc(2026, 10, 18, 3, 0);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Future<BackgroundRunRecorder> begun() async {
      final r = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await r.begin();
      return r;
    }

    BackgroundRunRecord stored() =>
        decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey)).single;

    AnalyzerService food() => FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true, 'food_items': []},
          isFood: true,
          wall: Duration.zero);

    test('a full run: every count, the watermark it reached, "done"',
        () async {
      final settings = await settingsWith(key: 'k');
      final frontier = DateTime.utc(2026, 10, 18, 2, 40);
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..safeFrontiers = [DateTime.utc(2026, 10, 18, 2, 30), frontier]
        ..frontier = frontier;
      final recorder = await begun();
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: food()),
        showMealCard: (_, _) async {},
        clock: () => t0,
        recorder: recorder,
        photoAccess: () async => true,
      );
      final r = stored();
      expect(r.finished, isTrue);
      expect(r.stopReason, BackgroundStop.done);
      expect((r.offered, r.analyzed, r.saved, r.released), (2, 2, 2, 0));
      expect(r.watermarkAfter, frontier);
    });

    test('killed mid-analysis (iOS expired the grant): the entry already '
        'says "processing a photo", 1 read, 0 processed', () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1)];
      final never = Completer<void>();
      final analyzer = FakeAnalyzer()..onAnalyze = () => never.future;
      final recorder = await begun();
      unawaited(headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(
            dao: FakeDao(),
            analyzer: analyzer,
            hasher: (b) async => md5.convert(b).toString()),
        showMealCard: (_, _) async {},
        clock: () => t0,
        recorder: recorder,
      ));
      for (var i = 0; i < 50 && recorder.current!.offered == 0; i++) {
        await pumpEventQueue();
      }
      // The process dies here; only what reached the store survives.
      final r = stored();
      expect(r.finished, isFalse);
      expect(r.stage, BackgroundRunStage.photo);
      expect((r.offered, r.analyzed), (1, 0));
    });

    test('the time budget: the photo it never started counts as left for '
        'later, and the reason is "budget"', () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1), photo(2)];
      var now = t0;
      final recorder = await begun();
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: food()),
        showMealCard: (_, _) async =>
            now = now.add(const Duration(seconds: 20)),
        clock: () => now,
        budget: const Duration(seconds: 15),
        recorder: recorder,
      );
      final r = stored();
      expect(r.stopReason, BackgroundStop.budget);
      expect((r.offered, r.analyzed, r.saved, r.released), (1, 1, 1, 1));
    });

    test('a deferred photo (retryable) counts as left for later', () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1)];
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'rate limit', retryable: true, wall: Duration.zero);
      final recorder = await begun();
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: analyzer),
        showMealCard: (_, _) async {},
        clock: () => t0,
        recorder: recorder,
      );
      expect((stored().analyzed, stored().released), (1, 1));
    });

    test('the guards name themselves: watcher off, no key, paused',
        () async {
      Future<String?> stopFor(AppSettings settings) async {
        final recorder = await begun();
        await headlessBackfillWith(
          settings: settings,
          prefs: prefs,
          intake: EmittingIntake()..batch = [photo(1)],
          pipeline: () async => fail('no pipeline past a guard'),
          showMealCard: (_, _) async {},
          clock: () => t0,
          recorder: recorder,
        );
        return recorder.current!.stopReason;
      }

      expect(await stopFor(await settingsWith(key: 'k', watcher: false)),
          BackgroundStop.watcherOff);
      expect(await stopFor(await settingsWith(key: null)),
          BackgroundStop.noKey);
      expect(
          await stopFor(await settingsWith(
              key: 'k',
              quotaPauseUntil: DateTime.now().add(const Duration(hours: 3)))),
          BackgroundStop.paused);
    });

    test('nothing listed + no photo access → "no_permission"; with access '
        'it is just a quiet "done"', () async {
      Future<String?> stopFor(bool? access) async {
        final settings = await settingsWith(key: 'k');
        final recorder = await begun();
        await headlessBackfillWith(
          settings: settings,
          prefs: prefs,
          intake: EmittingIntake(),
          pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: food()),
          showMealCard: (_, _) async {},
          clock: () => t0,
          recorder: recorder,
          photoAccess: () async => access,
        );
        return recorder.current!.stopReason;
      }

      expect(await stopFor(false), BackgroundStop.noPermission);
      expect(await stopFor(true), BackgroundStop.done);
      expect(await stopFor(null), BackgroundStop.done,
          reason: 'unknown access is not a verdict');
    });

    test('a scan that died is recorded by its error class', () async {
      final settings = await settingsWith(key: 'k');
      final recorder = await begun();
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: EmittingIntake()..throwAfterEmit = true,
        pipeline: () async => PhotoPipeline(dao: FakeDao(), analyzer: food()),
        showMealCard: (_, _) async {},
        clock: () => t0,
        recorder: recorder,
        photoAccess: () async => true,
      );
      expect(stored().stopReason, 'error:StateError');
    });

    // 2026-10-19: iOS kills a run still going ~30 s after launch; the
    // BGTask then never completes and the photo stays reserved.
    group('the whole-run deadline (finishWithinGrant)', () {
      test('a photo stuck in flight still ends the run: success, recorded '
          'as budget, and the entry stays final', () async {
        final settings = await settingsWith(key: 'k');
        final never = Completer<void>();
        final analyzer = FakeAnalyzer()..onAnalyze = () => never.future;
        final recorder = await begun();
        final dao = FakeDao();
        final pipeline = PhotoPipeline(
            dao: dao,
            analyzer: analyzer,
            hasher: (b) async => md5.convert(b).toString());
        final stuck = headlessBackfillWith(
          settings: settings,
          prefs: prefs,
          intake: EmittingIntake()..batch = [photo(1), photo(2)],
          pipeline: () async => pipeline,
          showMealCard: (_, _) async {},
          clock: () => t0,
          recorder: recorder,
        );
        final ok = await finishWithinGrant(stuck,
            left: const Duration(milliseconds: 40),
            recorder: recorder,
            abandon: () async {
              await pipeline.abandon();
            });
        expect(ok, isTrue, reason: 'the reply is what completes the BGTask');
        // The reply destroys the engine: the photo in flight would never
        // finish, so its reservation is released BEFORE the reply — no
        // 'processing' row to refuse the next run and the app for 30 min.
        expect(dao.ledger.values, isNot(contains(IngestionStatus.processing)));
        var r = stored();
        expect(r.finished, isTrue);
        expect(r.stopReason, BackgroundStop.budget);
        expect((r.offered, r.analyzed), (1, 0));
        // The abandoned run reporting late cannot reopen the entry.
        await recorder.processed(saved: true, released: false);
        await recorder.checkpoint(t0);
        r = stored();
        expect((r.stage, r.analyzed, r.saved),
            (BackgroundRunStage.done, 0, 0));
      });

      test('a stuck abandon cannot hold the reply past its limit', () async {
        final recorder = await begun();
        final ok = await finishWithinGrant(Completer<bool>().future,
            left: Duration.zero,
            recorder: recorder,
            abandon: () => Completer<void>().future,
            abandonLimit: const Duration(milliseconds: 20));
        expect(ok, isTrue);
        expect(stored().stopReason, BackgroundStop.budget);
      });

      test('RunInFlight: releases the photo in flight and notes it deferred; '
          'cut off twice, later runs pass it over', () async {
        final dao = FakeDao();
        final hang = Completer<void>();
        final pipeline = PhotoPipeline(
            dao: dao,
            analyzer: FakeAnalyzer()..onAnalyze = () => hang.future,
            hasher: (b) async => md5.convert(b).toString());
        Future<void> cutOff() async {
          final run = RunInFlight()
            ..pipeline = pipeline
            ..deferred = await DeferredAssets.load(prefs);
          unawaited(pipeline.process(photo(1)));
          while (!dao.ledger.values.contains(IngestionStatus.processing)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          await run.abandon();
          expect(dao.ledger.values,
              isNot(contains(IngestionStatus.processing)));
        }

        await cutOff();
        expect((await DeferredAssets.load(prefs)).passOver('asset1'), isFalse,
            reason: 'once may be a late offer');
        // A fresh pipeline per run, as each run builds its own.
        final second = PhotoPipeline(
            dao: dao,
            analyzer: FakeAnalyzer()..onAnalyze = () => hang.future,
            hasher: (b) async => md5.convert(b).toString());
        final run = RunInFlight()
          ..pipeline = second
          ..deferred = await DeferredAssets.load(prefs);
        unawaited(second.process(photo(1)));
        while (!dao.ledger.values.contains(IngestionStatus.processing)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await run.abandon();
        expect((await DeferredAssets.load(prefs)).passOver('asset1'), isTrue,
            reason: 'twice: too slow for any run, the app logs it');
        // Nothing built yet (the deadline hit during the settings load):
        // nothing to release, nothing noted.
        await RunInFlight().abandon();
      });

      test('runHeadlessBackfill on iOS ends at the deadline even when the '
          'settings load never returns', () async {
        addTearDown(() => isHeadlessEngine = false);
        // Dart entry at t0; every later reading is 40 ms short of the
        // deadline, so the wrapper has 40 ms of real time left.
        var calls = 0;
        DateTime clock() => calls++ == 0
            ? t0
            : t0.add(iosRunDeadline - const Duration(milliseconds: 40));
        final ok = await runHeadlessBackfill(
          isIOS: true,
          loadPrefs: () async => prefs,
          clock: clock,
          loadSettings: () => Completer<AppSettings>().future,
        ).timeout(const Duration(seconds: 5));
        expect(ok, isTrue, reason: 'the reply completes the BGTask');
        final run =
            decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
                .first;
        expect(run.stopReason, BackgroundStop.budget);
        // Android has no such wrapper: the same hang is WorkManager's to end.
        calls = 0;
        final android = runHeadlessBackfill(
          isIOS: false,
          loadPrefs: () async => prefs,
          clock: clock,
          loadSettings: () => Completer<AppSettings>().future,
        );
        var ended = false;
        unawaited(android.then((_) => ended = true));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(ended, isFalse);
      });

      test('a run that ends first is the answer, and the deadline never '
          'fires', () async {
        final recorder = await begun();
        final ok = await finishWithinGrant(Future.value(false),
            left: const Duration(milliseconds: 20), recorder: recorder);
        expect(ok, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(stored().finished, isFalse);
      });

      test('a run that throws first throws (handleBackgroundTask contains '
          'it)', () async {
        final recorder = await begun();
        await expectLater(
            finishWithinGrant(Future<bool>.error(StateError('db')),
                left: const Duration(seconds: 25), recorder: recorder),
            throwsStateError);
      });

      test('the deadline is 22 s from the run start: room for the unmeasured '
          'launch and the teardown inside the ~30 s grant, after the 15 s '
          'offer budget', () {
        expect(iosRunDeadline, const Duration(seconds: 22));
        expect(iosRunDeadline - iosBackgroundBudget,
            greaterThanOrEqualTo(const Duration(seconds: 7)));
      });

      group('the run start (backgroundRunStart)', () {
        final entry = DateTime.utc(2026, 10, 19, 3, 0, 10);
        test("the native stamp when it is this run's", () {
          expect(
              backgroundRunStart('2026-10-19T03:00:08.500Z', entry),
              DateTime.utc(2026, 10, 19, 3, 0, 8, 500));
        });
        test('the Dart entry without one, or with one that is not this '
            "run's", () {
          for (final stamp in [
            null,
            '',
            'garbage',
            '2026-10-19T03:00:10.001Z', // after the entry
            '2026-10-19T02:30:00.000Z', // an earlier run's
          ]) {
            expect(backgroundRunStart(stamp, entry), entry, reason: '$stamp');
          }
        });
      });

      test('runHeadlessBackfill counts the deadline from the native launch '
          'stamp, and records the boot', () async {
        addTearDown(() => isHeadlessEngine = false);
        // The engine was created 2 s before Dart's first line.
        await prefs.setString(backgroundNativeLaunchPrefsKey,
            t0.subtract(const Duration(seconds: 2)).toIso8601String());
        var calls = 0;
        // 40 ms short of the deadline as counted from the STAMP; from the
        // Dart entry 2.04 s would remain.
        DateTime clock() => calls++ == 0
            ? t0
            : t0.add(iosRunDeadline -
                const Duration(seconds: 2, milliseconds: 40));
        final watch = Stopwatch()..start();
        final ok = await runHeadlessBackfill(
          isIOS: true,
          loadPrefs: () async => prefs,
          clock: clock,
          loadSettings: () => Completer<AppSettings>().future,
        ).timeout(const Duration(seconds: 5));
        expect(ok, isTrue);
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        final run =
            decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
                .first;
        expect(run.stopReason, BackgroundStop.budget);
        expect(run.bootMs, 2000);
      });
    });
  });

  // 2026-10-19: every successful foreground sweep left the background
  // watermark days behind, and the next background run re-read everything
  // the app had just logged before reaching a new photo.
  group('the foreground catch-up moves the background watermark', () {
    final t1 = DateTime.utc(2026, 10, 18, 10);
    final t2 = DateTime.utc(2026, 10, 18, 11);
    final t3 = DateTime.utc(2026, 10, 18, 12);
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    DateTime? storedMark() =>
        readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey))
            ?.toUtc();

    test('advanceBackgroundWatermark re-reads the store: a stale cache never '
        'moves it back over the other engine\'s progress', () async {
      final app = prefs; // this engine's cache
      SharedPreferences.resetStatic(); // the background engine: its own
      final background = await SharedPreferences.getInstance();
      await background.setString(
          backgroundWatermarkPrefsKey, t2.toIso8601String());
      expect(await advanceBackgroundWatermark(app, t1, cap: t3), isNull);
      expect(app.getString(backgroundWatermarkPrefsKey), t2.toIso8601String(),
          reason: 'still the later mark');
      expect(await advanceBackgroundWatermark(app, t3, cap: t3), t3);
      await background.reload();
      expect(background.getString(backgroundWatermarkPrefsKey),
          t3.toIso8601String(),
          reason: 'forward, and written as a UTC instant');
    });

    test('never past the cap (the scan start)', () async {
      expect(await advanceBackgroundWatermark(prefs, t3, cap: t2), t2);
      expect(storedMark(), t2);
    });

    test('checkpoints each covered photo as it terminates, then the final '
        'frontier — never past the scan start', () async {
      final seenMidScan = <DateTime?>[];
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..safeFrontiers = [t1, t2]
        ..frontier = t3;
      intake.attachSink((p, _) async {
        seenMidScan.add(storedMark());
        return true;
      });
      final scanStart = t3.subtract(const Duration(minutes: 1));
      final frontier = await foregroundCatchUp(intake,
          clock: () => scanStart, loadPrefs: () async => prefs);
      expect(frontier, t3);
      expect(intake.newestDayFirstArgs, [true],
          reason: 'a quick open logs today\'s meal first');
      expect(seenMidScan, [null, t1],
          reason: 'photo 1\'s checkpoint landed before photo 2 started');
      expect(storedMark(), scanStart, reason: 'capped at the scan start');
    });

    test('a covered photo at or before the mark the store already holds '
        'costs no store round-trip', () async {
      final background = DateTime.utc(2026, 10, 18, 11, 30);
      await prefs.setString(
          backgroundWatermarkPrefsKey, background.toIso8601String());
      var loads = 0;
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2), photo(3), photo(4)]
        // A week of already-logged photos older than the background
        // run's own watermark, then one newer.
        ..safeFrontiers = [t1, t1.add(const Duration(minutes: 5)), t2, t3]
        ..frontier = t3;
      intake.attachSink((_, _) async => true);
      await foregroundCatchUp(intake,
          clock: () => t3.add(const Duration(minutes: 1)),
          loadPrefs: () async {
            loads++;
            return prefs;
          });
      expect(loads, 2,
          reason: 'the first read learns 11:30; t1+5 min and t2 are at or '
              'before it; t3 moves it; the final frontier t3 is known');
      expect(storedMark(), t3);
    });

    // 2026-10-19: once the user leaves (iOS), only the photo in flight may
    // spend the background time; the scan reads nothing more.
    test('the stuck hint clears once the catch-up moved the watermark past '
        'the hung runs (backgroundScanStuckNow reads both fresh)', () async {
      final wm = t1;
      // Three runs hung on a photo, written by the background engine.
      SharedPreferences.resetStatic();
      final background = await SharedPreferences.getInstance();
      await background.setString(backgroundWatermarkPrefsKey,
          wm.toIso8601String());
      for (var i = 0; i < 3; i++) {
        final r = BackgroundRunRecorder(background,
            platform: 'ios', clock: () => t2.add(Duration(minutes: i)));
        await r.begin(watermarkBefore: wm);
        await r.offered();
      }
      SharedPreferences.resetStatic();
      final app = await SharedPreferences.getInstance();
      expect(
          await backgroundScanStuckNow(
              clock: () => t3, loadPrefs: () async => app),
          isTrue);
      // The app opens and its catch-up logs everything up to t2.
      final intake = EmittingIntake()
        ..batch = [photo(1)]
        ..safeFrontiers = [t2]
        ..frontier = t2;
      intake.attachSink((_, _) async => true);
      await foregroundCatchUp(intake,
          clock: () => t3, loadPrefs: () async => app);
      expect(
          await backgroundScanStuckNow(
              clock: () => t3, loadPrefs: () async => app),
          isFalse,
          reason: 'the hint would tell the user to open the app they are in');
      expect(
          await backgroundScanStuckNow(
              loadPrefs: () async => throw StateError('no store')),
          isFalse);
    });

    test('shouldContinue reaches the intake: past it nothing more is read',
        () async {
      var open = true;
      final intake = EmittingIntake()..batch = [photo(1), photo(2), photo(3)];
      final processed = <String>[];
      intake.attachSink((p, _) async {
        processed.add(p.assetId);
        open = false; // the user leaves during the first photo
        return true;
      });
      await foregroundCatchUp(intake,
          loadPrefs: () async => prefs, shouldContinue: () => open);
      expect(processed, ['asset1']);
      expect(intake.unread, 2);
    });

    test('a released photo is not checkpointed, and a scan that throws '
        '(truncated window) writes no final frontier', () async {
      final intake = EmittingIntake()
        ..batch = [photo(1)]
        ..safeFrontiers = [t1]
        ..frontier = t3
        ..throwAfterEmit = true;
      intake.attachSink((p, _) async => false); // released
      await expectLater(
          foregroundCatchUp(intake,
              clock: () => t3, loadPrefs: () async => prefs),
          throwsStateError);
      expect(storedMark(), isNull);
    });

    test('a preferences failure never stops the scan', () async {
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..safeFrontiers = [t1, t2]
        ..frontier = t2;
      final delivered = <String>[];
      intake.attachSink((p, _) async {
        delivered.add(p.assetId);
        return true;
      });
      final frontier = await foregroundCatchUp(intake,
          clock: () => t3,
          loadPrefs: () async => throw StateError('no store'));
      expect(delivered, ['asset1', 'asset2']);
      expect(frontier, t2);
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

    test('the budget counts from the run\'s entry (startedAt), so the '
        'settings load and the database open spend it too', () async {
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1)];
      final entry = DateTime(2026, 9, 30, 12, 0, 0);
      // The keychain and settings took 10 s; opening the database 6 more.
      var now = entry.add(const Duration(seconds: 10));
      final dao = FakeDao();
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async {
          now = now.add(const Duration(seconds: 6));
          return PhotoPipeline(
              dao: dao,
              analyzer: FakeAnalyzer()
                ..nextPhotoOutcome = const AnalysisOutcome(
                    analysis: {'is_food': true, 'food_items': []},
                    isFood: true,
                    wall: Duration.zero));
        },
        showMealCard: (_, _) async {},
        clock: () => now,
        budget: const Duration(seconds: 15),
        startedAt: entry,
      );
      expect(intake.unread, 1, reason: '16 s in: nothing may be read');
      expect(dao.meals, isEmpty);
    });

    // 2026-10-19: one photo the background engine cannot decode froze its
    // watermark until the app next opened.
    test('a photo this engine keeps deferring is passed over by later runs; '
        'a verdict forgets it', () async {
      final settings = await settingsWith(key: 'k');
      final undecodable = FakeAnalyzer()
        ..nextPhotoOutcome =
            const AnalysisOutcome(error: 'decode failed', wall: Duration.zero);
      Future<void> runWith(AnalyzerService analyzer) async =>
          headlessBackfillWith(
            settings: settings,
            prefs: prefs,
            intake: EmittingIntake()..batch = [photo(1)],
            pipeline: () async => PhotoPipeline(
                dao: FakeDao(), analyzer: analyzer, deferUndecodable: true),
            showMealCard: (_, _) async {},
            deferred: await DeferredAssets.load(prefs),
          );
      await runWith(undecodable);
      expect((await DeferredAssets.load(prefs)).passOver('asset1'), isFalse);
      await runWith(undecodable);
      expect((await DeferredAssets.load(prefs)).passOver('asset1'), isTrue,
          reason: 'deferred twice: the next run counts it covered');
      expect(
          decodeDeferredAssets(prefs.getString(deferredAssetsPrefsKey))
              .single
              .count,
          2);
      // A run that settles it (any verdict) forgets it.
      await runWith(FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': false}, isFood: false, wall: Duration.zero));
      expect(prefs.getString(deferredAssetsPrefsKey), isNull);
    });

    test('other retryable outcomes (rate limit) are not deferrals', () async {
      final settings = await settingsWith(key: 'k');
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: EmittingIntake()..batch = [photo(1)],
        pipeline: () async => PhotoPipeline(
            dao: FakeDao(),
            analyzer: FakeAnalyzer()
              ..nextPhotoOutcome = const AnalysisOutcome(
                  error: 'rate limit', retryable: true, wall: Duration.zero),
            deferUndecodable: true),
        showMealCard: (_, _) async {},
        deferred: await DeferredAssets.load(prefs),
      );
      expect(prefs.getString(deferredAssetsPrefsKey), isNull);
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
      expect(intake.newestDayFirstArgs.single, isFalse,
          reason: 'the background drain stays oldest-first from its mark');
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
      isHeadlessEngine = false;
      addTearDown(() => isHeadlessEngine = false);
      bool? headlessBeforePrefs;
      final ok = await runHeadlessBackfill(
        isIOS: true,
        loadPrefs: () async {
          headlessBeforePrefs = isHeadlessEngine;
          return prefs;
        },
        clock: () => launched,
        loadSettings: () async {
          stampSeenByLoad = prefs.getString(backgroundLastRunPrefsKey);
          throw PlatformException(code: '-25308'); // InteractionNotAllowed
        },
      );
      expect(ok, isTrue, reason: 'no WorkManager retry storm');
      // The decode guard is up before anything else runs: on iOS a dart:ui
      // decode in this engine never finishes (2026-10-18).
      expect(headlessBeforePrefs, isTrue);
      expect(stampSeenByLoad, launched.toIso8601String());
      // And the run says so on the diagnostics page: it got as far as the
      // launch, and the settings load ended it (by class, no message).
      final run = decodeBackgroundRuns(
              prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect(run.platform, 'ios');
      expect(run.start, launched);
      expect(run.stage, BackgroundRunStage.done);
      expect(run.stopReason, 'error:PlatformException');
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

    test('a rejected key burns nothing and holds the watermark: the photos '
        'are scanned again next run', () async {
      // The analyzer calls a 401 non-retryable; the automatic scan used to
      // mark every photo 'failed' and checkpoint past them, so fixing the
      // key brought none of them back (2026-10-12).
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()
        ..batch = [photo(1), photo(2)]
        ..safeFrontiers = [
          DateTime(2026, 7, 24, 1, 0),
          DateTime(2026, 7, 24, 2, 0),
        ]; // frontier null: the real intake halts at the released photo 1
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'The provider rejected the API key. Check Settings.',
            wall: Duration.zero);
      Future<void> run() => headlessBackfillWith(
            settings: settings,
            prefs: prefs,
            intake: intake,
            pipeline: () async => PhotoPipeline(dao: dao, analyzer: analyzer),
            showMealCard: (_, _) async {},
            clock: () => DateTime(2026, 7, 24, 5, 0),
          );
      await run();
      expect(prefs.getString(backgroundWatermarkPrefsKey), isNull);
      expect(dao.ledger, isEmpty);

      // Key fixed: the next run analyzes and saves both.
      analyzer.nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true, 'food_items': []},
          isFood: true,
          wall: Duration.zero);
      await run();
      expect(dao.meals, hasLength(2));
      expect(prefs.getString(backgroundWatermarkPrefsKey),
          DateTime(2026, 7, 24, 2, 0).toUtc().toIso8601String());
    });

    test('a rejected key LATCHES the scan: the rest of the run makes no '
        'analyzer call, the next run reads no bytes, a key edit lifts it',
        () async {
      // Every 30 minutes the job re-uploaded the whole window against a
      // key that refuses every photo (~20 MB a run, review 2026-10-12).
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1), photo(2), photo(3)];
      final dao = FakeDao();
      var calls = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'The provider rejected the API key. Check Settings.',
            wall: Duration.zero)
        ..onAnalyze = () async => calls++;
      Future<void> run() => headlessBackfillWith(
            settings: settings,
            prefs: prefs,
            intake: intake,
            // Production wiring (runHeadlessBackfill): the settings latch.
            pipeline: () async => PhotoPipeline(
                dao: dao,
                analyzer: analyzer,
                latch: autoScanLatchFor(settings)),
            showMealCard: (_, _) async {},
            clock: () => DateTime(2026, 7, 24, 5, 0),
          );
      await run();
      expect(calls, 1, reason: 'photos 2 and 3 never uploaded');
      expect(settings.analysisBlockedKind, 'rejectedKey');
      expect(dao.ledger, isEmpty);
      expect(intake.scans, 1);

      await run();
      expect(intake.scans, 1, reason: 'guarded out before reading bytes');
      expect(calls, 1);

      // The user fixes the key: the next run analyzes every photo.
      await settings.setGeminiApiKey('k2');
      analyzer.nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true, 'food_items': []},
          isFood: true,
          wall: Duration.zero);
      await run();
      expect(intake.scans, 2);
      expect(dao.meals, hasLength(3));
    });

    test('a run that ARMS the pause posts one notice saying so; the runs '
        'it guards out post nothing more', () async {
      // The background has no snackbar: the scan used to just stop, for up
      // to a day, with only a Settings footer to say why (review
      // 2026-10-12).
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1), photo(2), photo(3)];
      final cards = <(String, String)>[];
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'The provider rejected the API key. Check Settings.',
            wall: Duration.zero);
      Future<void> run() => headlessBackfillWith(
            settings: settings,
            prefs: prefs,
            intake: intake,
            pipeline: () async => PhotoPipeline(
                dao: FakeDao(),
                analyzer: analyzer,
                latch: autoScanLatchFor(settings)),
            showMealCard: (t, b) async => cards.add((t, b)),
            clock: () => DateTime(2026, 7, 24, 5, 0),
          );
      await run();
      expect(cards, hasLength(1));
      final l = localizationsFor(settings.appLanguage);
      expect(cards.single.$1, l.autoScanPausedTitle);
      expect(
          cards.single.$2,
          autoScanPausedLine(l,
              kind: 'rejectedKey',
              until: settings.analysisBlockedUntil!,
              provider: settings.provider.name,
              serverBackend: settings.serverBackend));
      await run();
      await run();
      expect(cards, hasLength(1), reason: 'one notice per arm');

      // A run that releases photos WITHOUT arming (a network failure)
      // says nothing.
      await settings.setGeminiApiKey('k2');
      analyzer.nextPhotoOutcome = const AnalysisOutcome(
          error: 'Error contacting the provider (network or service issue).',
          retryable: true,
          wall: Duration.zero);
      await run();
      expect(cards, hasLength(1));
      expect(settings.isAnalysisBlocked, isFalse);
    });

    test('no pause notice when the foreground edited the key during the run',
        () async {
      // The arm landed, then the user saved a new key in the app (another
      // isolate, its own preferences cache): the pause is gone on disk, and
      // "photos will not be logged automatically" would be stale.
      final settings = await settingsWith(key: 'k');
      final intake = EmittingIntake()..batch = [photo(1)];
      final cards = <(String, String)>[];
      final real = autoScanLatchFor(settings);
      final latch = AutoScanLatch(
        blockedKind: real.blockedKind,
        revision: real.revision,
        block: (kind, revision) async {
          await real.block(kind, revision);
          SharedPreferences.resetStatic(); // the foreground isolate
          final fg = await AppSettings.load(
              prefs: await SharedPreferences.getInstance(),
              keyStore: MemoryKeyStore());
          await fg.setGeminiApiKey('k2');
        },
        clear: real.clear,
      );
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'The provider rejected the API key. Check Settings.',
            wall: Duration.zero);
      await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(
            dao: FakeDao(), analyzer: analyzer, latch: latch),
        showMealCard: (t, b) async => cards.add((t, b)),
        clock: () => DateTime(2026, 7, 24, 5, 0),
      );
      expect(cards, isEmpty);
      expect(settings.isAnalysisBlocked, isFalse);
    });

    test('does nothing while a blocked region latched the scan', () async {
      final settings = await settingsWith(key: 'k');
      await settings.blockAutomaticAnalysis('regionBlocked');
      final intake = EmittingIntake()..batch = [photo(1)];
      final ok = await headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: intake,
        pipeline: () async =>
            PhotoPipeline(dao: FakeDao(), analyzer: FakeAnalyzer()),
        showMealCard: (_, _) async {},
      );
      expect(ok, isTrue);
      expect(intake.scans, 0);
      expect(prefs.getString(backgroundWatermarkPrefsKey), isNull);
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

    for (final (lang, title, body) in const [
      // The card's summary is in the app language too (zh 千卡).
      ('zh', '🍽️ 已扣除剩菜', '已扣除剩菜：Noodles —— 减 300 千卡，现约 300 千卡'),
      ('en', '🍽️ Leftovers deducted',
          'Leftovers deducted: Noodles — −300 kcal, now ~300 kcal'),
    ]) {
      test('[$lang] a leftover deduction posts ONE card; not-food and '
          'failures still post none', () async {
        // A second photo of the same plate cuts a logged meal's calories
        // unattended — it used to happen with no card at all.
        final settings = await settingsWith(key: 'k');
        await settings.setAppLanguage(lang);
        final intake = EmittingIntake()
          ..batch = [photo(1), photo(2), photo(3)];
        final cards = <(String, String)>[];
        await headlessBackfillWith(
          settings: settings,
          prefs: prefs,
          intake: intake,
          pipeline: () async => _ScriptedPipeline([
            const PhotoOutcome(PhotoOutcomeKind.leftoverApplied,
                'Leftovers deducted: Noodles — −300 kcal, now ~300 kcal',
                detail: 'Noodles — −300 kcal, now ~300 kcal',
                mealName: 'Noodles',
                kcal: '300',
                deductedKcal: 300,
                mealId: 7,
                mealDate: '2026-10-12',
                previousAnalysis: {'is_food': true}),
            const PhotoOutcome(PhotoOutcomeKind.skipped, 'not food'),
            const PhotoOutcome(PhotoOutcomeKind.failed, 'bad photo',
                errorKind: AnalysisErrorKind.badPhoto),
          ]),
          showMealCard: (title, body) async => cards.add((title, body)),
        );
        expect(cards, [(title, body)]);
      });
    }
  });

  // 2026-10-19 (review): the budget admits a photo until 15 s after the
  // scan starts, a second or two into iOS's ~30 s grant. A stalled ImageIO
  // reply held for the app engine's 15 s deadline came back at ~30 s, after
  // iOS had killed the run, and left the photo 'processing'.
  group('the iOS grant and a stalled native decode', () {
    testWidgets('a HEIC offered at the end of the budget, whose ImageIO reply '
        'never comes, is released inside an assumed 30 s grant',
        (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) => Completer<Object?>().future);
      addTearDown(
          () => messenger.setMockMethodCallHandler(imageIOChannel, null));
      isHeadlessEngine = true; // what runHeadlessBackfill sets first
      addTearDown(() => isHeadlessEngine = false);

      // Fake time (testWidgets): the binding's clock moves with pump().
      DateTime now() => tester.binding.clock.now();
      // Engine boot and the settings load spend ~2 s of the grant before
      // the scan, and its budget, start.
      final grantEnds = now().add(const Duration(seconds: 28));
      final settings = await settingsWith(key: 'k');
      final prefs = await SharedPreferences.getInstance();
      final dao = _ReleaseClockDao(now);
      // ftyp/heic: not anything the pure-Dart decoder or the unprocessed
      // fallback will take.
      final heic = IntakePhoto(
          Uint8List.fromList(
              [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]),
          'asset9',
          'IMG_9.HEIC');
      var finished = false;
      unawaited(headlessBackfillWith(
        settings: settings,
        prefs: prefs,
        intake: _LateIntake(heic,
            before: iosBackgroundBudget - const Duration(milliseconds: 100)),
        pipeline: () async => PhotoPipeline(
            dao: dao,
            analyzer: GeminiAnalyzer(settings,
                client: MockClient((_) async {
                  fail('nothing decodable, so nothing may be sent');
                }),
                sleep: (_) async {},
                // Production's chain (platform defaults: headless from the
                // flag above, the real channel). Only the pure-Dart step
                // is stubbed with what it answers for HEIC, null: it runs
                // in an isolate, which fake time cannot drive.
                normalizer: (b) => decodeForUpload(b,
                    pureDart: normalizeForAnalysis,
                    longSidePx: kAnalysisLongSidePx,
                    jpegQuality: kAnalysisJpegQuality,
                    isolate: (_, _) async => null,
                    ios: true)),
            hasher: (b) async => md5.convert(b).toString(),
            deferUndecodable: true),
        showMealCard: (_, _) async {},
        clock: now,
        budget: iosBackgroundBudget,
      ).then((_) => finished = true));
      final giveUp = grantEnds.add(const Duration(seconds: 30));
      while (!finished && now().isBefore(giveUp)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(finished, isTrue);
      expect(dao.releasedAt, isNotNull, reason: 'deferred, so released');
      expect(dao.releasedAt!.isBefore(grantEnds), isTrue,
          reason: 'released at ${dao.releasedAt}, the grant ends at '
              '$grantEnds: past it iOS has killed the run and the row '
              'stays processing');
      expect(dao.ledger, isEmpty,
          reason: 'neither processing nor failed: the next run re-offers it');
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

  group('postHeadlessSummary (the daily summary off switch, 2026-10-10)', () {
    // Friends on the pre-08-16 APKs got a nightly "0 kcal" card they never
    // opted into and could not stop: this heartbeat path posted regardless
    // of every setting. The switch gates delivery here; the job itself
    // stays registered (the group above).
    Future<AppSettings> settingsAt({required bool summary}) async {
      SharedPreferences.setMockInitialValues({
        'settings.summary_enabled': summary,
        'settings.report_time': '21:30',
      });
      return AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
    }

    final pastSlot = DateTime(2026, 10, 10, 22, 0);

    test('off → nothing posted, no database opened, no watermark', () async {
      final settings = await settingsAt(summary: false);
      var opened = 0;
      final posted = <String>[];
      final did = await postHeadlessSummary(
        settings: settings,
        openDao: () async {
          opened++;
          return FakeDao();
        },
        present: (title, body) async => posted.add(title),
        now: () => pastSlot,
      );
      expect(did, isFalse);
      expect(posted, isEmpty);
      expect(opened, 0, reason: 'nothing to say: do not open the database');
      expect(await settings.freshSummaryPostedDate(), '');
    });

    test('on (the default) → the slot that passed is posted once', () async {
      final settings = await settingsAt(summary: true);
      final posted = <String>[];
      final did = await postHeadlessSummary(
        settings: settings,
        openDao: () async => FakeDao(),
        present: (title, body) async => posted.add(title),
        now: () => pastSlot,
      );
      expect(did, isTrue);
      expect(posted, hasLength(1));
      expect(await settings.freshSummaryPostedDate(), '2026-10-10');
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
      // Through foregroundCatchUp: today's photos first, and the coverage
      // moves the background watermark (a bare backfillScan did neither).
      expect(intake.newestDayFirstArgs.last, isTrue);
      expect(intake.checkpointed.last, isTrue);
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
