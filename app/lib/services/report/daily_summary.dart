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

/// How long after a missed slot the summary may still be delivered.
///
/// MEASURED, not guessed: on the user's Honor device the "30-minute"
/// WorkManager job actually ran at 1–6 hour intervals, and last night
/// nothing ran between ~20:00 and 00:52. A 23:34 slot therefore had a
/// 26-minute window against a heartbeat that was hours wide, so the summary
/// was missed and then discarded — every night (2026-08-16 diagnosis).
///
/// Eight hours covers the observed gap while keeping the catch-up honest:
/// a summary that arrives the next morning still describes a day the user
/// remembers. Beyond that it is stale, and silence is better.
const Duration kSummaryGraceWindow = Duration(hours: 8);

/// Post the pending summary if one is due and unposted. Returns true when a
/// notification was actually presented.
///
/// Covers the day whose slot most recently passed — normally today, but
/// after midnight it may still be YESTERDAY, because a throttled background
/// run is often the first chance the app gets. That late run used to be
/// dropped (today's slot hasn't arrived, so nothing matched) and the day was
/// lost for good; it is now caught up within [kSummaryGraceWindow] and
/// titled "Yesterday" so it never names the wrong day.
Future<bool> maybePostDailySummary(DailySummaryDeps deps) async {
  final now = deps.now();
  final slot = _parseHhmm(deps.reportTime);
  if (slot == null) return false;

  DateTime slotOn(DateTime day) =>
      DateTime(day.year, day.month, day.day, slot.$1, slot.$2);

  // Which day is this run reporting on?
  final DateTime coveredDay;
  final bool late;
  if (!now.isBefore(slotOn(now))) {
    coveredDay = now; // today's slot has passed
    late = false;
  } else {
    // Today's slot is still ahead. Yesterday's may have been missed by a
    // throttled heartbeat — catch it up while it is still worth saying.
    final yesterday = now.subtract(const Duration(days: 1));
    if (now.difference(slotOn(yesterday)) > kSummaryGraceWindow) return false;
    coveredDay = yesterday;
    late = true;
  }

  final today = isoDate(coveredDay);
  if (deps.postedDate == today) return false; // already said it once

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
  // Relative to the day being REPORTED, not to the clock: a catch-up run at
  // 00:52 must compare yesterday against the seven days before IT, or the
  // covered day silently lands inside its own baseline.
  final priorFrom = isoDate(coveredDay.subtract(const Duration(days: 7)));
  final priorTo = isoDate(coveredDay.subtract(const Duration(days: 1)));
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
    forYesterday: late,
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
