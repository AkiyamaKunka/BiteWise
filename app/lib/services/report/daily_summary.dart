/// Delivering the daily coach notification (user request 2026-08-06).
///
/// WHY THIS IS NOT JUST A TIMER: ReportNotifier arms an in-process Timer,
/// which dies the moment the OS kills the app — and EMUI-class Androids
/// kill aggressively, so the scheduled summary silently never arrived.
/// The durable path piggybacks the WorkManager heartbeat that already
/// runs every 30 minutes for the photo watcher: on each run, if the
/// report time has passed and today's summary has not been posted yet,
/// compute it from the LOCAL database and post.
///
/// Both paths (live Timer, background catch-up) go through
/// [maybePostDailySummary], and a persisted per-date watermark makes a
/// double-post impossible.
library;

import '../../core/coerce.dart' show safeNumber;
import '../../core/contracts.dart';
// format.dart is pure Dart (intl only, no Flutter) — safe to use from the
// headless WorkManager isolate, and it guarantees the notification's
// numbers are computed exactly like the Today screen's.
import '../../ui/format.dart'
    show dailyCalorieTotals, formatKcal, isFoodMeal, isoDate, typicalDayKcal;
import 'coach_summary.dart';

/// Everything the delivery needs, injected so this stays testable with no
/// platform channels (the headless isolate has no BuildContext either).
class DailySummaryDeps {
  const DailySummaryDeps({
    required this.dao,
    required this.reportTime,
    required this.calorieGoal,
    required this.postedDate,
    required this.markPosted,
    required this.present,
    required this.strings,
    required this.now,
  });

  final MealsDao dao;

  /// "HH:mm" — the slot the user chose in Settings.
  final String reportTime;
  final int calorieGoal;

  /// Last date already summarized ('' when never).
  final String postedDate;
  final Future<void> Function(String isoDate) markPosted;
  final Future<void> Function(String title, String body) present;
  final CoachStrings strings;
  final DateTime Function() now;
}

/// Post today's summary if it is due and unposted. Returns true when a
/// notification was actually presented.
///
/// Deliberately does NOT post for a day that is already over: a catch-up
/// run at 03:00 must summarize nothing rather than shout about yesterday
/// (the watermark advances so the stale day is skipped for good).
Future<bool> maybePostDailySummary(DailySummaryDeps deps) async {
  final now = deps.now();
  final today = isoDate(now);
  if (deps.postedDate == today) return false; // already said it once

  final slot = _parseHhmm(deps.reportTime);
  if (slot == null) return false;
  final due = DateTime(now.year, now.month, now.day, slot.$1, slot.$2);
  if (now.isBefore(due)) return false; // not yet — the day is still open

  final meals = await deps.dao.mealsBetween(today, today);
  final food = meals.where(isFoodMeal).toList();
  num cal = 0, protein = 0;
  for (final m in food) {
    cal += safeNumber(m.analysis['total_calories']);
    protein += safeNumber(m.analysis['total_protein_g']);
  }

  // Typical day = the median of the prior 7 days, the same number Today
  // shows — computed here so the notification can never disagree with the
  // screen.
  final priorFrom = isoDate(now.subtract(const Duration(days: 7)));
  final priorTo = isoDate(now.subtract(const Duration(days: 1)));
  final prior = await deps.dao.mealsBetween(priorFrom, priorTo);
  final typical = typicalDayKcal(dailyCalorieTotals(prior));

  final summary = buildCoachSummary(
    eatenKcal: cal,
    mealCount: food.length,
    proteinG: protein,
    goalKcal: deps.calorieGoal,
    typicalKcal: typical,
    strings: deps.strings,
    formatKcal: formatKcal,
  );

  await deps.present(summary.title, summary.body);
  await deps.markPosted(today);
  return true;
}

(int, int)? _parseHhmm(String raw) {
  final m = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$').firstMatch(raw.trim());
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}
