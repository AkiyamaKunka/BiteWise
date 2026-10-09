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
import '../data/meals_dao_impl.dart';
import '../services/analyzer/provider_analyzers.dart';
import '../services/photo/background.dart';
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
/// (2026-10-07).
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
  const BackfillDrain(this.outcomes,
      {required this.scanCompleted, this.frontier, this.cutShort = false});
}

/// Run one backfill through the pipeline with FULL backpressure: the
/// intake awaits each photo's processing before reading the next photo's
/// bytes (one photo resident at a time — a 200-photo backlog must not hold
/// ~1 GB while the first Gemini call is in flight). When [onOutcome] is
/// set it runs per photo BEFORE the next one starts, so progress
/// (notifications, watermark checkpoints) survives a WorkManager
/// hard-stop mid-batch. Past [deadline] (iOS's ~30 s grant) no further
/// photo is processed: each is released back to the intake unprocessed,
/// which halts the frontier in front of it.
Future<BackfillDrain> drainBackfill(PhotoIntake intake, PhotoPipeline pipeline,
    {int lookbackDays = 0,
    DateTime? since,
    DateTime? deadline,
    DateTime Function() clock = DateTime.now,
    Future<void> Function(
            IntakePhoto photo, PhotoOutcome outcome, DateTime? safeFrontier)?
        onOutcome}) async {
  final outcomes = <PhotoOutcome>[];
  var cutShort = false;
  intake.attachSink((p, safeFrontier) async {
    if (deadline != null && !clock().isBefore(deadline)) {
      cutShort = true;
      return false; // released, not burned: the next run re-offers it
    }
    final o = await pipeline.process(p);
    outcomes.add(o);
    if (onOutcome != null) await onOutcome(p, o, safeFrontier);
    return !o.retryable;
  });
  var scanCompleted = false;
  DateTime? frontier;
  try {
    frontier = await intake.backfillScan(
        lookbackDays: lookbackDays, since: since);
    scanCompleted = true;
  } catch (_) {
    // Library query died / window truncated. Photos delivered before the
    // throw are already fully processed (sink is awaited inline); the
    // false flag tells the caller the window was NOT fully covered.
  } finally {
    intake.attachSink(null);
  }
  return BackfillDrain(outcomes,
      scanCompleted: scanCompleted, frontier: frontier, cutShort: cutShort);
}

/// The headless scan body, dependency-injected so tests can drive it with
/// fakes. Returns WorkManager success (true) in every recoverable state —
/// background.dart's no-retry-storm rule.
@visibleForTesting
Future<bool> headlessBackfillWith({
  required AppSettings settings,
  required SharedPreferences prefs,
  required PhotoIntake intake,
  required Future<PhotoPipeline> Function() pipeline,
  required Future<void> Function(String title, String body) showMealCard,
  DateTime Function() clock = DateTime.now,
  Duration? budget,
}) async {
  // First, unconditionally: "the OS ran us" is what Settings reports,
  // whatever the guards below decide.
  await prefs.setString(
      backgroundLastRunPrefsKey, clock().toUtc().toIso8601String());
  // Belt and braces: disabling the watcher cancels the job, but a stale
  // chain must never scan against the user's setting.
  if (!settings.watcherEnabled) return true;
  // No key yet / quota latch armed: analyses cannot succeed, so don't even
  // read photo bytes. The watermark stays put — those photos are scanned
  // once the blocker clears (release-not-burn keeps them eligible).
  if (!settings.canAnalyze) return true;

  final scanStart = clock();
  final since = readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));

  Future<void> checkpoint(DateTime mark) async {
    // Monotonic forward only, never past this scan's start.
    final capped = mark.isAfter(scanStart) ? scanStart : mark;
    final cur = readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));
    if (cur == null || capped.isAfter(cur)) {
      await prefs.setString(
          backgroundWatermarkPrefsKey, capped.toUtc().toIso8601String());
    }
  }

  // The pipeline (and its database handle) is built ONLY past the guards:
  // most runs guard out or find nothing, and every needless cross-isolate
  // open is a shot at the shared-handle transaction races.
  final drain = await drainBackfill(
    intake,
    await pipeline(),
    since: since?.subtract(backgroundScanOverlap),
    deadline: budget == null ? null : scanStart.add(budget),
    clock: clock,
    onOutcome: (photo, o, safeFrontier) async {
      // Per photo, BEFORE the next one: a WorkManager hard-stop mid-batch
      // must not lose the notification for an already-saved meal, nor the
      // progress the run already made.
      if (o.kind == PhotoOutcomeKind.saved) {
        // In the app language, like the coach summary (headless, so via
        // the saved preference rather than a BuildContext).
        final l = localizationsFor(settings.appLanguage);
        await showMealCard(l.mealCardAutoTitle, outcomeBody(l, o));
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
  return true;
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
Future<bool> runHeadlessBackfill({bool? isIOS}) async {
  final ios = isIOS ?? Platform.isIOS;
  final settings = await AppSettings.load();
  final prefs = await SharedPreferences.getInstance();
  // Time-derived id seed: cards from successive runs stack instead of
  // overwriting each other. Base 10000 keeps the whole range clear of the
  // fixed daily-report id 9001 (a colliding meal card would silently
  // REPLACE an unread daily report).
  final notifier = ReportNotifier(
      mealCardIdSeed: 10000 +
          (DateTime.now().millisecondsSinceEpoch ~/ 10000) % 8640000);
  // The DURABLE daily-summary path. ReportNotifier's in-process Timer
  // dies with the app, and EMUI kills aggressively — so the notification
  // the user asked for is delivered by this 30-minute heartbeat instead,
  // guarded by a freshly read per-date watermark so the live Timer does
  // not double-post (user request 2026-08-06).
  if (!ios) {
    try {
      await maybePostDailySummary(DailySummaryDeps(
      dao: await createMealsDao(),
      reportTime: settings.reportTime,
      calorieGoal: settings.calorieGoal,
      postedDate: await settings.freshSummaryPostedDate(),
      markPosted: settings.markSummaryPosted,
      present: (title, body) async {
        await notifier.init();
        await notifier.showDailySummary(title, body);
      },
        strings: coachStringsFor(settings.appLanguage),
        now: DateTime.now,
      ));
    } catch (_) {
      // A summary must never take the photo scan down with it.
    }
  }
  final ok = await headlessBackfillWith(
    settings: settings,
    prefs: prefs,
    intake: createPhotoIntake(settings),
    pipeline: () async => PhotoPipeline(
        dao: await createMealsDao(),
        analyzer: createMultiProviderAnalyzer(settings)),
    showMealCard: (title, body) async {
      await notifier.init(); // idempotent; deferred until a card exists
      await notifier.showMealCard(title, body);
    },
    budget: ios ? iosBackgroundBudget : null,
  );
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
