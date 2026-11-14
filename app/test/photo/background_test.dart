// Background backfill wiring (spec §6.4): task-handler behavior, lookback
// input clamping (§8: 1–30, default 2), scheduling floor (>=15 min), and the
// iOS no-op delta (§6).
import 'package:calorie_tracker/services/photo/background.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workmanager/workmanager.dart';

class FakeScheduler implements BackgroundScheduler {
  final List<String> calls = [];
  Function? initializedDispatcher;
  Duration? registeredFrequency;
  Map<String, dynamic>? registeredInput;
  String? registeredUniqueName;
  String? registeredTaskName;
  ExistingPeriodicWorkPolicy? registeredPolicy;

  @override
  Future<void> initialize(Function dispatcher) async {
    calls.add('initialize');
    initializedDispatcher = dispatcher;
  }

  @override
  Future<void> registerPeriodic(String uniqueName, String taskName,
      {required Duration frequency,
      Map<String, dynamic>? inputData,
      ExistingPeriodicWorkPolicy? existingWorkPolicy}) async {
    calls.add('register');
    registeredPolicy = existingWorkPolicy;
    registeredUniqueName = uniqueName;
    registeredTaskName = taskName;
    registeredFrequency = frequency;
    registeredInput = inputData;
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    calls.add('cancel:$uniqueName');
  }
}

void main() {
  tearDown(() {
    headlessBackfill = null;
    debugSchedulerOverride = null;
    debugIsAndroidOverride = null;
    debugIsIOSOverride = null;
  });

  group('lookbackDaysFromInput', () {
    test('numeric values clamp to 1–30', () {
      expect(lookbackDaysFromInput(2), 2);
      expect(lookbackDaysFromInput(0), 1);
      expect(lookbackDaysFromInput(99), 30);
      expect(lookbackDaysFromInput(7.9), 7);
    });
    test('junk falls back to the default 2', () {
      expect(lookbackDaysFromInput(null), 2);
      expect(lookbackDaysFromInput('yesterday'), 2);
      expect(lookbackDaysFromInput(double.nan), 2);
    });
  });

  group('handleBackgroundTask', () {
    test('runs the wired backfill with the clamped lookback', () async {
      final seen = <int>[];
      headlessBackfill = (days) async {
        seen.add(days);
        return true;
      };
      final ok = await handleBackgroundTask(
          photoBackfillTaskName, {'lookbackDays': 99});
      expect(ok, isTrue);
      expect(seen, [30]);
    });

    test('missing input uses the default window', () async {
      final seen = <int>[];
      headlessBackfill = (days) async {
        seen.add(days);
        return true;
      };
      await handleBackgroundTask(photoBackfillTaskName, null);
      expect(seen, [2]);
    });

    test('iOS hands back the IDENTIFIER (unique name) or the legacy fetch '
        'name — both are ours', () async {
      var runs = 0;
      headlessBackfill = (_) async {
        runs++;
        return true;
      };
      expect(await handleBackgroundTask(photoBackfillUniqueName, null), isTrue);
      expect(await handleBackgroundTask(Workmanager.iOSBackgroundTask, null),
          isTrue);
      expect(runs, 2);
      expect(isPhotoBackfillTask('somebody.else'), isFalse);
    });

    test('unknown task name: success without invoking the runner', () async {
      var ran = false;
      headlessBackfill = (_) async {
        ran = true;
        return true;
      };
      expect(await handleBackgroundTask('someOtherTask', null), isTrue);
      expect(ran, isFalse);
    });

    test('unwired runner: success (never a retry-storm)', () async {
      expect(await handleBackgroundTask(photoBackfillTaskName, null), isTrue);
    });

    test('runner exception is contained and reported as success (§6.5: '
        'ledger keeps failed rows)', () async {
      headlessBackfill = (_) async => throw StateError('scan blew up');
      expect(await handleBackgroundTask(photoBackfillTaskName, null), isTrue);
    });
  });

  group('enableBackgroundScan', () {
    test('registers one periodic task with clamped frequency and lookback',
        () async {
      final scheduler = FakeScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = true;

      await enableBackgroundScan(true,
          lookbackDays: 99, frequency: const Duration(minutes: 1));

      // No cancel first (review 171, C7): cancelling stops a RUNNING
      // worker, and workmanager's onStopped destroys its engine mid-upload
      // — every app open did that. UPDATE keeps one chain, lets a running
      // worker finish and keeps the chain's timing.
      expect(scheduler.calls, ['initialize', 'register']);
      expect(scheduler.registeredPolicy, ExistingPeriodicWorkPolicy.update);
      expect(scheduler.registeredUniqueName, photoBackfillUniqueName);
      expect(scheduler.registeredTaskName, photoBackfillTaskName);
      expect(scheduler.registeredFrequency,
          minBackgroundFrequency); // WorkManager >=15 min floor
      expect(scheduler.registeredInput, {'lookbackDays': 30}); // §8 clamp
    });

    test('Android: registering again never cancels, so a run in progress '
        'is not stopped', () async {
      final scheduler = FakeScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = true;

      // Every app start, a lookback edit and a watcher edit re-register.
      await enableBackgroundScan(true);
      await enableBackgroundScan(true, lookbackDays: 7);
      await enableBackgroundScan(true);
      expect(scheduler.calls.where((c) => c.startsWith('cancel')), isEmpty);
      expect(scheduler.calls.where((c) => c == 'register'), hasLength(3));
      expect(scheduler.registeredPolicy, ExistingPeriodicWorkPolicy.update);
    });

    test('frequency above the floor is kept as-is', () async {
      final scheduler = FakeScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = true;

      await enableBackgroundScan(true, frequency: const Duration(hours: 6));
      expect(scheduler.registeredFrequency, const Duration(hours: 6));
      expect(scheduler.registeredInput, {'lookbackDays': 2});
    });

    test('off cancels the unique task and registers nothing', () async {
      final scheduler = FakeScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = true;

      await enableBackgroundScan(false);
      expect(scheduler.calls, ['cancel:$photoBackfillUniqueName']);
    });

    test('neither Android nor iOS (desktop host): complete no-op', () async {
      final scheduler = FakeScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = false;
      debugIsIOSOverride = false;

      await enableBackgroundScan(true);
      await enableBackgroundScan(false);
      expect(scheduler.calls, isEmpty);
    });

    test('iOS registers the SAME unique name the native side declares',
        () async {
      // 2026-09-30: iOS joins via BGAppRefreshTask. The identifier iOS
      // hands back is the unique name, and AppDelegate.swift + Info.plist
      // must spell it identically — pinned here against drift.
      final scheduler = FakeScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = false;
      debugIsIOSOverride = true;

      await enableBackgroundScan(true, frequency: const Duration(minutes: 30));
      // iOS unchanged: cancel-then-register, no work policy (WorkManager's
      // policies mean nothing to BGTaskScheduler).
      expect(scheduler.calls,
          ['initialize', 'cancel:$photoBackfillUniqueName', 'register']);
      expect(scheduler.registeredPolicy, isNull);
      expect(scheduler.registeredUniqueName, photoBackfillUniqueName);
      expect(scheduler.registeredTaskName, photoBackfillTaskName);
      expect(photoBackfillUniqueName, 'calorietracker.photo.backfill.periodic');
      await enableBackgroundScan(false);
      expect(scheduler.calls.last, 'cancel:$photoBackfillUniqueName');
    });

    test('a custom dispatcher is what gets initialized (integrator wiring)',
        () async {
      final scheduler = FakeScheduler();
      debugSchedulerOverride = scheduler;
      debugIsAndroidOverride = true;
      void myDispatcher() {}

      await enableBackgroundScan(true, dispatcher: myDispatcher);
      expect(scheduler.initializedDispatcher, same(myDispatcher));
    });
  });
}
