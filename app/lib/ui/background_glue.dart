/// Integrator wiring for the photo module's background half (spec §6.4) —
/// the composition-root counterpart that services/photo/background.dart's
/// library docs demand. Nothing here was wired before 2026-07-23, which is
/// why "automatic" intake only worked while the app was open and unfrozen.
///
/// Three layers of catch-up keep the watcher honest on aggressive OEMs
/// (Honor/EMUI freezes backgrounded apps within minutes):
///   1. Foreground change-notify watcher (di.dart) — instant while open.
///   2. Periodic WorkManager job (this file) — while the app is closed.
///   3. Launch/resume backfill over the FULL lookback window (di.dart +
///      app.dart) — the correctness backstop when 1–2 were killed.
///
/// The periodic job runs in a FRESH isolate each time (empty session
/// dedup), so it scans from a persisted watermark instead of the whole
/// window — otherwise every run would re-read the original bytes of every
/// window photo just to rediscover them in the md5 ledger.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../core/contracts.dart';
import '../core/outcome_kind.dart';
import '../data/meals_dao_impl.dart';
import '../services/analyzer/platform_decode.dart' show isHeadlessEngine;
import '../services/analyzer/provider_analyzers.dart';
import '../services/photo/background.dart';
import '../services/photo/background_runs.dart';
import '../services/photo/deferred_assets.dart';
import '../services/photo/photo_library.dart' show photoLibraryAccess;
import '../services/photo/watcher.dart';
import '../services/report/notifications.dart';
import '../services/report/daily_summary.dart';
import 'coach_strings.dart';
import '../services/settings/app_settings.dart';
import 'photo_pipeline.dart';
import 'os_summary.dart';
import 'outcome_text.dart';

/// Persisted watermark: start time of the last completed background scan.
/// Stored as a UTC instant (see [readStoredInstant]).
const String backgroundWatermarkPrefsKey = 'background.last_scan_iso';

/// When the OS last LAUNCHED a background run (before any guard) — the
/// Settings "background scan" row. On iOS this is the only visible proof
/// that BGAppRefresh fires on a given phone; the OS decides the cadence
/// and no debugger is needed to read this (2026-09-30).
const String backgroundLastRunPrefsKey = 'background.last_run_iso';

/// Reads an instant stored by this file. Both keys are WRITTEN as UTC
/// ('…Z'): a zone-less local string is read back in whatever zone the
/// phone is in NOW, so a Shanghai → Chicago flight moved the watermark
/// 13 hours into the future and the scan skipped every photo taken in
/// between — the airport and in-flight meals (2026-10-08). Read back as
/// local, because Settings formats `.hour` directly. A pre-fix zone-less
/// value still parses as local, exactly as before, and the next forward
/// checkpoint rewrites it as UTC.
@visibleForTesting
DateTime? readStoredInstant(String? stored) =>
    DateTime.tryParse(stored ?? '')?.toLocal();

/// Re-scan overlap behind the watermark, absorbing camera write latency and
/// photos created while the previous scan was running.
const Duration backgroundScanOverlap = Duration(hours: 1);

/// Periodic cadence. WorkManager's floor is 15 min; 30 keeps EMUI battery
/// stats friendly while the watermark keeps each run nearly free when
/// nothing new was shot.
const Duration backgroundScanFrequency = Duration(minutes: 30);

/// iOS BGAppRefreshTask wall budget. The OS grants roughly 30 s and then
/// runs the expiration handler, which cancels the run outright — a photo
/// mid-analysis would leave a 'processing' reservation until the next
/// launch reclaims it. Stop OFFERING photos after this much, so the last
/// server analysis (3–10 s typical) still lands inside the grant. When the
/// grant expires mid-analysis anyway, that orphaned row answers later runs
/// as [PhotoReservation.inFlight] — a retryable outcome — so the frontier
/// below waits in front of the photo instead of passing over it
/// (2026-10-07). Counted from the run's entry into Dart, not from the scan
/// start (2026-10-19): the settings load and the database open come out of
/// the same grant.
const Duration iosBackgroundBudget = Duration(seconds: 15);

/// Result of one drained backfill: what happened to each photo, whether
/// the SCAN itself completed (a scan abort means unseen photos remain),
/// and the intake's coverage frontier (never advance a watermark past it).
class BackfillDrain {
  final List<PhotoOutcome> outcomes;
  final bool scanCompleted;
  final DateTime? frontier;

  /// True when the [drainBackfill] deadline passed with photos still
  /// unoffered — they were RELEASED (not burned), so the next run
  /// re-offers them; the watermark stops short of them by construction.
  final bool cutShort;

  /// How many photos the deadline released unprocessed.
  final int deadlineReleases;

  /// What aborted the scan when [scanCompleted] is false (its class is all
  /// the diagnostics record keeps).
  final Object? scanError;
  const BackfillDrain(this.outcomes,
      {required this.scanCompleted,
      this.frontier,
      this.cutShort = false,
      this.deadlineReleases = 0,
      this.scanError});
}

/// Run one backfill through the pipeline with FULL backpressure: the
/// intake awaits each photo's processing before reading the next photo's
/// bytes (one photo resident at a time — a 200-photo backlog must not hold
/// ~1 GB while the first Gemini call is in flight). When [onOutcome] is
/// set it runs per photo BEFORE the next one starts, so progress
/// (notifications, watermark checkpoints) survives a WorkManager
/// hard-stop mid-batch. Past [deadline] (iOS's ~30 s grant) no further
/// photo is processed — nor even read: the intake asks before each
/// original's bytes, and a photo read just before the deadline is released
/// at the sink. Both halt the frontier in front of the photo.
Future<BackfillDrain> drainBackfill(PhotoIntake intake, PhotoPipeline pipeline,
    {int lookbackDays = 0,
    DateTime? since,
    DateTime? deadline,
    DateTime Function() clock = DateTime.now,
    Future<void> Function(IntakePhoto photo)? onOffer,
    Future<void> Function(
            IntakePhoto photo, PhotoOutcome outcome, DateTime? safeFrontier)?
        onOutcome}) async {
  final outcomes = <PhotoOutcome>[];
  var cutShort = false;
  var deadlineReleases = 0;
  // Once past the deadline, past it for good (a clock step backwards must
  // not reopen the run), and every photo turned away is counted.
  bool budgetLeft() {
    if (deadline == null) return true;
    if (!cutShort && clock().isBefore(deadline)) return true;
    cutShort = true;
    deadlineReleases++;
    return false;
  }

  intake.attachSink((p, safeFrontier) async {
    if (!budgetLeft()) {
      return false; // released, not burned: the next run re-offers it
    }
    if (onOffer != null) await onOffer(p);
    final o = await pipeline.process(p);
    outcomes.add(o);
    if (onOutcome != null) await onOutcome(p, o, safeFrontier);
    return !o.retryable;
  });
  var scanCompleted = false;
  DateTime? frontier;
  Object? scanError;
  try {
    frontier = await intake.backfillScan(
        lookbackDays: lookbackDays,
        since: since,
        shouldContinue: deadline == null ? null : budgetLeft);
    scanCompleted = true;
  } catch (e) {
    // Library query died / window truncated. Photos delivered before the
    // throw are already fully processed (sink is awaited inline); the
    // false flag tells the caller the window was NOT fully covered.
    scanError = e;
  } finally {
    intake.attachSink(null);
  }
  return BackfillDrain(outcomes,
      scanCompleted: scanCompleted,
      frontier: frontier,
      cutShort: cutShort,
      deadlineReleases: deadlineReleases,
      scanError: scanError);
}

/// The pipeline's view of [AppSettings]' automatic-analysis latch — one
/// adapter for the foreground pipeline (di.dart) and the background run.
AutoScanLatch autoScanLatchFor(AppSettings settings) => AutoScanLatch(
      blockedKind: () => switch (settings.analysisBlockedKind) {
        'rejectedKey' => AnalysisErrorKind.rejectedKey,
        'regionBlocked' => AnalysisErrorKind.regionBlocked,
        _ => null,
      },
      revision: () => settings.credentialRevision,
      block: (kind, revision) =>
          settings.blockAutomaticAnalysis(kind.name, revision: revision),
      clear: settings.clearAnalysisBlock,
      refresh: settings.reloadAnalysisBlock,
    );

/// Moves the background watermark forward to [mark], never past [cap] and
/// never back; returns the value written, or null when it did not move.
///
/// Both engines write it (2026-10-19): the background run as it scans,
/// and the app's launch/resume catch-ups ([foregroundCatchUp]), each
/// through its own preferences cache — so the stored value is re-read
/// first, and a stale cache can never carry it backwards over the other
/// engine's progress. (Two writers interleaving between the read and the
/// write can at worst leave the EARLIER mark: a re-scan, never a skip.)
/// Written as UTC (see [readStoredInstant]).
Future<DateTime?> advanceBackgroundWatermark(
    SharedPreferences prefs, DateTime mark,
    {required DateTime cap}) async {
  final capped = mark.isAfter(cap) ? cap : mark;
  try {
    await prefs.reload();
  } catch (_) {
    // Unreadable store: compare against this engine's own copy.
  }
  final cur = readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));
  if (cur != null && !capped.isAfter(cur)) return null;
  await prefs.setString(
      backgroundWatermarkPrefsKey, capped.toUtc().toIso8601String());
  return capped;
}

/// The app's launch/resume catch-up over the full lookback window — the
/// pipeline [PhotoPipeline.bind] attached processes each photo — which
/// also moves the BACKGROUND watermark over what it covered. It used to
/// leave it days behind: the next background run then spent its grant
/// re-reading and re-hashing every photo the app had just logged before
/// it reached a new one (2026-10-19).
///
/// The newest day's photos go first, so a quick open logs today's meal
/// before the rest of the week (PhotoIntake.backfillScan newestDayFirst);
/// the background run keeps strict oldest-first from its watermark.
///
/// Only the intake's safeFrontier is persisted — per photo as it
/// terminates (the app may be suspended mid-scan), then the final
/// frontier — never past this scan's start. A truncated window reports
/// none and throws [BackfillWindowTruncated], which propagates. A
/// preferences failure never stops the scan.
Future<DateTime?> foregroundCatchUp(PhotoIntake intake,
    {DateTime Function() clock = DateTime.now,
    Future<SharedPreferences> Function()? loadPrefs}) async {
  final scanStart = clock();
  Future<void> checkpoint(DateTime mark) async {
    try {
      final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
      await advanceBackgroundWatermark(prefs, mark, cap: scanStart);
    } catch (_) {}
  }

  final frontier =
      await intake.backfillScan(onCovered: checkpoint, newestDayFirst: true);
  if (frontier != null) await checkpoint(frontier);
  return frontier;
}

/// Stamps "the OS launched a background run" for the Settings 后台扫描 row.
/// Written as UTC (see [readStoredInstant]).
Future<void> recordBackgroundLaunch(
        SharedPreferences prefs, DateTime Function() clock) =>
    prefs.setString(
        backgroundLastRunPrefsKey, clock().toUtc().toIso8601String());

/// The headless scan body, dependency-injected so tests can drive it with
/// fakes. Returns WorkManager success (true) in every recoverable state —
/// background.dart's no-retry-storm rule.
///
/// [recorder] (begun by the caller) gets every step of this run, as it
/// happens (background_runs.dart); [photoAccess] tells a run that found no
/// photos because it may not read any.
///
/// [deferred] notes each photo this run defers and forgets each one it
/// gives a verdict (deferred_assets.dart); the run's intake was built to
/// pass over the ones deferred too often.
///
/// [budget] counts from [startedAt] — the moment the OS-launched run
/// entered Dart ([runHeadlessBackfill]) — so the keychain read, the
/// settings load and the database open spend it too; it used to start at
/// the scan, a second or more into iOS's grant. Null: from the scan start.
@visibleForTesting
Future<bool> headlessBackfillWith({
  required AppSettings settings,
  required SharedPreferences prefs,
  required PhotoIntake intake,
  required Future<PhotoPipeline> Function() pipeline,
  required Future<void> Function(String title, String body) showMealCard,
  DateTime Function() clock = DateTime.now,
  Duration? budget,
  DateTime? startedAt,
  DeferredAssets? deferred,
  bool launchRecorded = false,
  BackgroundRunRecorder? recorder,
  Future<bool?> Function()? photoAccess,
}) async {
  // First, unconditionally: "the OS ran us" is what Settings reports,
  // whatever the guards below decide. Skipped when [runHeadlessBackfill]
  // already wrote it before loading the settings — one launch, one stamp.
  if (!launchRecorded) await recordBackgroundLaunch(prefs, clock);
  await recorder?.stage(BackgroundRunStage.settings);
  // Belt and braces: disabling the watcher cancels the job, but a stale
  // chain must never scan against the user's setting.
  if (!settings.watcherEnabled) {
    await recorder?.finish(BackgroundStop.watcherOff);
    return true;
  }
  // No key yet / quota latch armed / an earlier automatic photo came back
  // 'key rejected' or 'region blocked' (the automatic-analysis latch):
  // analyses cannot succeed, so don't even read photo bytes — every 30
  // minutes this used to re-upload the whole window. The watermark stays
  // put — those photos are scanned once the blocker clears
  // (release-not-burn keeps them eligible).
  if (!settings.canAutoAnalyze) {
    await recorder?.finish((settings.activeApiKey ?? '').trim().isEmpty
        ? BackgroundStop.noKey
        : BackgroundStop.paused);
    return true;
  }

  final scanStart = clock();
  final since = readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));
  await recorder?.stage(BackgroundRunStage.scan);

  Future<void> checkpoint(DateTime mark) async {
    // Monotonic forward only, never past this scan's start.
    final moved = await advanceBackgroundWatermark(prefs, mark, cap: scanStart);
    if (moved != null) await recorder?.checkpoint(moved);
  }

  // The pipeline (and its database handle) is built ONLY past the guards:
  // most runs guard out or find nothing, and every needless cross-isolate
  // open is a shot at the shared-handle transaction races.
  final drain = await drainBackfill(
    intake,
    await pipeline(),
    since: since?.subtract(backgroundScanOverlap),
    deadline: budget == null ? null : (startedAt ?? scanStart).add(budget),
    clock: clock,
    onOffer: recorder == null ? null : (_) => recorder.offered(),
    onOutcome: (photo, o, safeFrontier) async {
      await recorder?.processed(
          saved: o.kind == PhotoOutcomeKind.saved ||
              o.kind == PhotoOutcomeKind.leftoverApplied,
          released: o.retryable);
      // A photo this engine could not decode (deferUndecodable) is counted;
      // twice, and later runs pass it over instead of halting on it again.
      if (o.retryable && o.errorKind == AnalysisErrorKind.badPhoto) {
        await deferred?.deferred(photo.assetId);
      } else if (!o.retryable) {
        await deferred?.settled(photo.assetId);
      }
      // Per photo, BEFORE the next one: a WorkManager hard-stop mid-batch
      // must not lose the notification for an already-saved meal, nor the
      // progress the run already made.
      // A leftover deduction CUTS an already-logged meal's calories, so
      // an unattended one needs a card as much as a new meal does — it
      // used to be silent here (the foreground snackbar was its only
      // announcement, and the headless path has no snackbar).
      if (o.kind == PhotoOutcomeKind.saved ||
          o.kind == PhotoOutcomeKind.leftoverApplied) {
        // In the app language, like the coach summary (headless, so via
        // the saved preference rather than a BuildContext).
        final l = localizationsFor(settings.appLanguage);
        await showMealCard(
            o.kind == PhotoOutcomeKind.saved
                ? l.mealCardAutoTitle
                : l.mealCardLeftoverTitle,
            outcomeBody(l, o));
      }
      // The intake's safeFrontier is the ONLY persistable value: it is
      // createDate-based (the watermark's timebase), halts at transient
      // failures, and is null for truncated windows. Deriving it from the
      // photo (filename dates) skipped photos permanently.
      if (!o.retryable && safeFrontier != null) {
        await checkpoint(safeFrontier);
      }
    },
  );
  // Final watermark: ONLY the intake's frontier — no scanStart fast path.
  // Outcomes can't see photos whose byte read failed (they never reach the
  // sink), so "no retryable outcomes" does NOT mean full coverage; the
  // frontier is the single honest source. Cost: the next run re-offers at
  // most the newest covered photo (ledger absorbs it without a model call).
  if (drain.frontier != null) await checkpoint(drain.frontier!);
  await recorder?.releasedUnprocessed(drain.deadlineReleases);
  // This run ARMED the automatic-scan pause (it started unpaused — see the
  // guard above): the background has no snackbar, and without a word the
  // scan just stops for up to a day. One notice per arm: every later run
  // is guarded out above until the pause lifts. Re-read from disk first:
  // a key edited in the foreground during this run has already lifted the
  // pause there, and a notice about it would be stale.
  await settings.reloadAnalysisBlock();
  final pausedUntil = settings.analysisBlockedUntil;
  if (pausedUntil != null) {
    final l = localizationsFor(settings.appLanguage);
    final line = autoScanPausedLine(l,
        kind: settings.analysisBlockedKind,
        until: pausedUntil,
        provider: settings.provider.name,
        serverBackend: settings.serverBackend);
    if (line != null) {
      try {
        await showMealCard(l.autoScanPausedTitle, line);
      } catch (_) {}
    }
  }
  if (recorder != null) {
    await recorder.finish(
        await _stopReason(drain,
            pausedNow: pausedUntil != null,
            listedNothing: recorder.current?.enumerated == 0,
            photoAccess: photoAccess),
        watermarkAfter:
            readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey)));
  }
  return true;
}

/// How a scan that ran to the end of [headlessBackfillWith] stopped, for
/// the diagnostics record. The budget first (photos are waiting), then a
/// pause this run armed (the rest were released), then a scan that died or
/// listed nothing because the app may not read the library.
Future<String> _stopReason(BackfillDrain drain,
    {required bool pausedNow,
    required bool listedNothing,
    Future<bool?> Function()? photoAccess}) async {
  if (drain.cutShort) return BackgroundStop.budget;
  if (pausedNow) return BackgroundStop.paused;
  if (!drain.scanCompleted || listedNothing) {
    bool? access;
    try {
      access = await photoAccess?.call();
    } catch (_) {}
    if (access == false) return BackgroundStop.noPermission;
  }
  final error = drain.scanError;
  if (!drain.scanCompleted && error != null) return BackgroundStop.error(error);
  return BackgroundStop.done;
}

/// The Android heartbeat's half of the daily summary: post it when the
/// slot has passed, that day's is unposted, and the user has not switched
/// the summary off in Settings. Returns whether a card was presented.
///
/// The off switch gates DELIVERY, not the heartbeat: the job stays
/// registered (see [syncBackgroundScan]) and the photo scan after this
/// runs regardless. Off opens no database either — a run that has
/// nothing to say should not take a shot at the shared-handle races.
/// Before the switch (2026-10-10) this path fired for every install,
/// every night, watcher and key or not: friends who upgraded from the
/// Timer-only APKs got a "0 kcal" card they never opted into.
@visibleForTesting
Future<bool> postHeadlessSummary({
  required AppSettings settings,
  required Future<MealsDao> Function() openDao,
  required Future<void> Function(String title, String body) present,
  DateTime Function() now = DateTime.now,
}) async {
  if (!settings.summaryEnabled) return false;
  return maybePostDailySummary(DailySummaryDeps(
    dao: await openDao(),
    reportTime: settings.reportTime,
    calorieGoal: settings.calorieGoal,
    postedDate: await settings.freshSummaryPostedDate(),
    markPosted: settings.markSummaryPosted,
    present: present,
    strings: coachStringsFor(settings.appLanguage),
    now: now,
  ));
}

/// Production assembly for one background run. Mirrors di.dart's startup
/// EXCEPT reclaimStaleProcessing: that launch sweep assumes it owns the
/// only pipeline, and the foreground app may be mid-analysis right now —
/// reclaiming its 'processing' reservation here could double-log a meal.
///
/// Platform split for the daily summary: Android POSTS it from this
/// heartbeat (the durable path there); iOS instead RE-ARMS the OS card
/// after the scan, so a meal logged while the app was closed is in the
/// card the OS delivers at the slot — posting here too would put a second
/// alert under the same id minutes after the OS one.
///
/// The launch marker is written BEFORE the settings load, and a failed load
/// ends the run as a success. Loading reads every key from the keychain;
/// on a locked iPhone that read threw (keys were stored under a class
/// readable only while unlocked), the run died silently, and the 后台扫描
/// row read as if iOS had never run the task (2026-10-09). The keystore
/// now survives a locked phone (MigratingKeyStore), and should a load
/// still fail — say before the first unlock after a reboot — the row
/// shows that iOS did run the task. The seams exist for that test.
Future<bool> runHeadlessBackfill({
  bool? isIOS,
  Future<AppSettings> Function()? loadSettings,
  Future<SharedPreferences> Function()? loadPrefs,
  DateTime Function() clock = DateTime.now,
}) async {
  // FIRST, before anything can decode a photo: this isolate is the
  // headless engine. On iOS its GPU is off for the whole run and a dart:ui
  // decode never finishes, so platform_decode must skip that step here
  // (2026-10-18).
  isHeadlessEngine = true;
  // iOS's grant is already running: the time budget counts from here.
  final startedAt = clock();
  final ios = isIOS ?? Platform.isIOS;
  final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
  await recordBackgroundLaunch(prefs, clock);
  // This run's diagnostics entry, rewritten at every step so a run iOS
  // kills still shows how far it got (background_runs.dart).
  final recorder = BackgroundRunRecorder(prefs,
      platform: ios ? 'ios' : 'android', clock: clock);
  await recorder.begin(
      watermarkBefore:
          readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey)));
  final inFlight = RunInFlight();
  final run = _runAfterLaunch(
      ios: ios,
      prefs: prefs,
      recorder: recorder,
      startedAt: startedAt,
      inFlight: inFlight,
      loadSettings: loadSettings);
  // iOS: the whole run ends inside the grant, whatever it is stuck on.
  if (!ios) return run;
  return finishWithinGrant(run,
      left: startedAt.add(iosRunDeadline).difference(clock()),
      recorder: recorder,
      abandon: inFlight.abandon);
}

/// What the iOS deadline needs from a run still going: its pipeline once
/// built, and its deferral notes once loaded.
@visibleForTesting
class RunInFlight {
  PhotoPipeline? pipeline;
  DeferredAssets? deferred;

  /// Releases the photo in flight ([PhotoPipeline.abandon]) and notes it
  /// as deferred: a photo the deadline cuts off twice — too slow for what
  /// a run has left — is then passed over like an undecodable one, so it
  /// no longer holds the watermark, and the app's catch-up logs it.
  Future<void> abandon() async {
    final assetId = await pipeline?.abandon();
    if (assetId != null && assetId.isNotEmpty) {
      await deferred?.deferred(assetId);
    }
  }
}

/// [runHeadlessBackfill] past the launch stamp: settings, the Android
/// summary, the scan, the iOS summary card.
Future<bool> _runAfterLaunch({
  required bool ios,
  required SharedPreferences prefs,
  required BackgroundRunRecorder recorder,
  required DateTime startedAt,
  required RunInFlight inFlight,
  Future<AppSettings> Function()? loadSettings,
}) async {
  final AppSettings settings;
  try {
    // Read-only key store: only the UI engine moves keys between keychain
    // classes, so the two engines can never race on the one-time move.
    settings = await (loadSettings ??
        () => AppSettings.load(keyStore: platformKeyStore(migrate: false)))();
  } catch (e) {
    await recorder.finish(BackgroundStop.error(e));
    // Success, not a retry: the next scheduled run tries again, and a
    // WorkManager retry storm helps nobody (background.dart's rule).
    return true;
  }
  await recorder.stage(BackgroundRunStage.settings);
  final deferred = inFlight.deferred = await DeferredAssets.load(prefs);
  // Time-derived id seed: cards from successive runs stack instead of
  // overwriting each other. Base 10000 keeps the whole range clear of the
  // fixed daily-report id 9001 (a colliding meal card would silently
  // REPLACE an unread daily report).
  final notifier = ReportNotifier(
      channelStrings: () => notificationChannelFor(settings.appLanguage),
      mealCardIdSeed: 10000 +
          (DateTime.now().millisecondsSinceEpoch ~/ 10000) % 8640000);
  // The DURABLE daily-summary path. ReportNotifier's in-process Timer
  // dies with the app, and EMUI kills aggressively — so the notification
  // the user asked for is delivered by this 30-minute heartbeat instead,
  // guarded by a freshly read per-date watermark so the live Timer does
  // not double-post (user request 2026-08-06).
  if (!ios) {
    try {
      await postHeadlessSummary(
        settings: settings,
        openDao: createMealsDao,
        present: (title, body) async {
          await notifier.init();
          await notifier.showDailySummary(title, body);
        },
      );
    } catch (_) {
      // A summary must never take the photo scan down with it.
    }
  }
  final bool ok;
  try {
    ok = await headlessBackfillWith(
      settings: settings,
      prefs: prefs,
      intake: createPhotoIntake(settings,
          onBackfillListed: recorder.listed, passOver: deferred.passOver),
      pipeline: () async => inFlight.pipeline = PhotoPipeline(
          dao: await createMealsDao(),
          analyzer: createMultiProviderAnalyzer(settings),
          latch: autoScanLatchFor(settings),
          // iOS only: there dart:ui cannot decode (platform_decode.dart).
          deferUndecodable: ios),
      showMealCard: (title, body) async {
        await notifier.init(); // idempotent; deferred until a card exists
        await notifier.showMealCard(title, body);
      },
      budget: ios ? iosBackgroundBudget : null,
      startedAt: startedAt,
      deferred: deferred,
      launchRecorded: true,
      recorder: recorder,
      photoAccess: photoLibraryAccess,
    );
  } catch (e) {
    // A throw the scan did not contain (the database would not open, say):
    // the entry names its class, and WorkManager still sees the failure.
    await recorder.finish(BackgroundStop.error(e));
    rethrow;
  }
  if (ios) {
    try {
      await armOsDailySummary(
          dao: await createMealsDao(), settings: settings, notifier: notifier);
    } catch (_) {
      // The scan's work is saved either way; the card refreshes next open.
    }
  }
  return ok;
}

/// The whole iOS background run, from its entry into Dart, ends within
/// this (2026-10-19). iOS expires a BGAppRefresh grant about 30 s after
/// launching it, and the engine boot comes before Dart's clock starts; a
/// run still going then is killed, the task never completes, and its photo
/// stays reserved. The offer budget ([iosBackgroundBudget]) stops new
/// photos at 15 s, but nothing bounded the photo already in flight (a slow
/// upload, a stalled decode) or the steps around the scan. What is left
/// after this — the engine teardown and the completion — fits in the
/// remaining seconds.
const Duration iosRunDeadline = Duration(seconds: 25);

/// [run] or, once [left] has passed, an end to the run anyway: the
/// diagnostics entry says 'budget' and the result is success, so
/// workmanager completes the BGTask (its executeTask reply is what calls
/// setTaskCompleted; workmanager_apple 0.9.1+2 BackgroundWorker.swift)
/// instead of iOS killing the process at expiry.
///
/// The reply destroys the engine (cleanupFlutterResources →
/// destroyContext), so the abandoned run never gets to finish anything —
/// a photo in flight would keep its 'processing' row, and that row would
/// refuse every later run and the open app for appProcessingStaleAge
/// (simulator, 2026-10-19). So before replying, [abandon] releases that
/// reservation and stops the pipeline from writing anything more
/// ([PhotoPipeline.abandon]), waiting at most [abandonLimit]. The offer
/// budget has passed by then, so the run starts no new photo either. Its
/// diagnostics entry is frozen once finished.
@visibleForTesting
Future<bool> finishWithinGrant(Future<bool> run,
    {required Duration left,
    required BackgroundRunRecorder recorder,
    Future<void> Function()? abandon,
    Duration abandonLimit = const Duration(milliseconds: 1500)}) {
  final done = Completer<bool>();
  final timer = Timer(left.isNegative ? Duration.zero : left, () {
    if (done.isCompleted) return;
    done.complete(() async {
      if (abandon != null) {
        try {
          await abandon().timeout(abandonLimit);
        } catch (_) {
          // Out of time for it: the reply matters more.
        }
      }
      await recorder.finish(BackgroundStop.budget);
      return true;
    }());
  });
  run.then((ok) {
    timer.cancel();
    if (!done.isCompleted) done.complete(ok);
  }, onError: (Object e, StackTrace st) {
    timer.cancel();
    if (!done.isCompleted) done.completeError(e, st);
  });
  return done.future;
}

/// WorkManager background entrypoint. Must stay top-level with the
/// vm:entry-point pragma or AOT tree-shaking removes it and every
/// background run dies before Dart (background.dart library docs).
@pragma('vm:entry-point')
void appBackgroundDispatcher() {
  Workmanager().executeTask((task, input) {
    // The registered inputData lookback is ignored on purpose: the runner
    // loads live settings, so slider edits apply without re-registration.
    headlessBackfill = (_) => runHeadlessBackfill();
    return handleBackgroundTask(task, input);
  });
}

/// Reconcile the periodic job with the current settings — call at startup
/// and whenever watcherEnabled/lookbackDays change. Android WorkManager
/// or iOS BGAppRefresh inside (enableBackgroundScan picks).
///
/// ALWAYS registered, deliberately. The job carries TWO passengers: the
/// photo backfill and the daily coach summary. Passing watcherEnabled here
/// cancelled the whole job when the watcher was off, which silently killed
/// the notification while its own setting still looked enabled — the user
/// had no way to see why nothing arrived (2026-08-16). The scan half is
/// already self-guarding (headlessBackfillWith returns early when the
/// watcher is off), so an always-on job scans nothing extra; it only keeps
/// the summary's delivery path alive.
Future<void> syncBackgroundScan(AppSettings settings) =>
    enableBackgroundScan(true,
        lookbackDays: settings.lookbackDays,
        frequency: backgroundScanFrequency,
        dispatcher: appBackgroundDispatcher);

/// The last background launch, read FRESH: the run wrote it from another
/// isolate, and this isolate's SharedPreferences cache would not know.
Future<DateTime?> lastBackgroundRun() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return readStoredInstant(prefs.getString(backgroundLastRunPrefsKey));
}
