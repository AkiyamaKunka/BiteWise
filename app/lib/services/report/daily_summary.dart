/// Delivering the daily coach notification (user request 2026-08-06).
///
/// On both phones the summary is a card handed to the OS ahead of time
/// (ui/os_summary.dart), built by [summaryForDay]. [maybePostDailySummary]
/// is the POST-at-the-slot path: Android's delivery from August 2026 to the
/// Play push (an in-process Timer plus the 30-minute WorkManager job, which
/// came late or never), kept for a host with no OS scheduler.
///
/// It is guarded by a persisted per-date watermark that each caller reads
/// FRESH (two isolates' SharedPreferences caches never see each other's
/// writes), so two posters cannot both say the same day.
library;

import '../../core/coerce.dart'
    show addCalendarDays, calendarDaysBetween, safeNumber;
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

/// Summary slots before this hour describe the day that just ended — the
/// app's previous-night rule (a photo taken before 04:00 may also be a
/// leftover from the night before, photo_pipeline.dart).
const int kSummaryNightEndsHour = 4;

/// The calendar day a summary for [slot] describes (C16/C40): the slot's
/// own day, or for a slot from 00:00 to 03:59 the day before — a 00:30
/// summary is about the day that just ended, not the half hour since
/// midnight, which always read 'Today: 0 kcal'. Calendar arithmetic
/// (addCalendarDays), never 24 h, so a DST day is still one day.
///
/// [slotHour]: the hour the user set. Pass it: on the night DST starts
/// where clocks jump at 03:00 (Europe/Athens) a 03:30 slot does not exist
/// and [slot] normalises to 04:30, whose own hour would say 'not a night
/// slot' (review, 2026-11-13). Without it, [slot]'s hour.
DateTime summaryDayFor(DateTime slot, {int? slotHour}) =>
    (slotHour ?? slot.hour) < kSummaryNightEndsHour
        ? addCalendarDays(slot, -1)
        : DateTime(slot.year, slot.month, slot.day);

/// Whether a summary about [day], said at [at], is about yesterday (or
/// earlier) and must be worded so.
bool summaryIsAboutYesterday(DateTime day, DateTime at) =>
    calendarDaysBetween(day, at) >= 1;

/// The slot at [hour]:[minute] that most recently passed at [now], if it
/// passed within [kSummaryGraceWindow]: today's once it has come, else
/// yesterday's (calendar arithmetic: on the fall-back night a 24 h step
/// from 23:30 lands on the SAME date). Null when the last one is older.
DateTime? lastSlotWithinGrace(int hour, int minute, DateTime now) {
  DateTime slotOn(DateTime day) =>
      DateTime(day.year, day.month, day.day, hour, minute);
  final today = slotOn(now);
  if (!now.isBefore(today)) return today;
  final yesterday = slotOn(addCalendarDays(now, -1));
  if (now.difference(yesterday) > kSummaryGraceWindow) return null;
  return yesterday;
}

/// Android's card titles name the day ('Thu: 1,850 kcal', '周四：…')
/// instead of 'Today' / 'Yesterday': an inexact alarm can come after
/// midnight, and a card the boot receiver re-fires can come the next
/// morning, so 'Today' could name the wrong day (review, 2026-11-13). The
/// empty-day line says 'that day' for the same reason.
class SummaryDayNaming {
  const SummaryDayNaming(
      {required this.dayName, required this.title, required this.empty});

  /// 'Thu' / '周四' for [day].
  final String Function(DateTime day) dayName;
  final String Function(String day, String kcal) title;
  final String empty;
}

/// Post the pending summary if one is due and unposted. Returns true when a
/// notification was actually presented.
///
/// Covers the day whose slot most recently passed — normally today, but
/// after midnight it may still be YESTERDAY, because a throttled background
/// run is often the first chance the app gets. That late run used to be
/// dropped (today's slot hasn't arrived, so nothing matched) and the day was
/// lost for good; it is now caught up within [kSummaryGraceWindow] and
/// titled "Yesterday" so it never names the wrong day. A slot before 04:00
/// covers the day before it ([summaryDayFor]), titled "Yesterday" too.
Future<bool> maybePostDailySummary(DailySummaryDeps deps) async {
  final now = deps.now();
  final slot = _parseHhmm(deps.reportTime);
  if (slot == null) return false;

  // Which slot most recently passed? Yesterday's may have been missed by
  // a throttled heartbeat — caught up while it is still worth saying.
  final passed = lastSlotWithinGrace(slot.$1, slot.$2, now);
  if (passed == null) return false;

  // The day it describes, which the watermark names.
  final coveredDay = summaryDayFor(passed, slotHour: slot.$1);
  final covered = isoDate(coveredDay);
  if (deps.postedDate == covered) return false; // already said it once

  final summary = await summaryForDay(
    dao: deps.dao,
    day: coveredDay,
    calorieGoal: deps.calorieGoal,
    strings: deps.strings,
    forYesterday: summaryIsAboutYesterday(coveredDay, now),
  );
  await deps.present(summary.title, summary.body);
  await deps.markPosted(covered);
  return true;
}

/// The coach summary for [day], exactly as [maybePostDailySummary] would
/// post it — but with no watermark and no presenting.
///
/// Split out for iOS (2026-09-28): there the OS delivers the notification
/// (no background execution exists to compute it at the slot), so the
/// content has to be built AHEAD of time and handed over. Sharing this one
/// builder is what keeps the pre-armed card and the live card identical.
///
/// [day] is the day DESCRIBED ([summaryDayFor] of the slot). It may be
/// tomorrow: after tonight's slot has passed, the next card describes a day
/// with nothing logged yet, and the empty-day line is the honest content
/// until the user logs something and the card is re-armed.
///
/// [onDay]: Android's day-named wording ([SummaryDayNaming]).
Future<CoachSummary> summaryForDay({
  required MealsDao dao,
  required DateTime day,
  required int calorieGoal,
  required CoachStrings strings,
  bool forYesterday = false,
  SummaryDayNaming? onDay,
}) async {
  final date = isoDate(day);
  final meals = await dao.mealsBetween(date, date);
  final food = meals.where(isFoodMeal).toList();
  num cal = 0, protein = 0;
  for (final m in food) {
    cal += safeNumber(m.analysis['total_calories']);
    protein += safeNumber(m.analysis['total_protein_g']);
  }

  // Typical day = the median of the prior 7 days, the same number Today
  // shows — anchored to the day being REPORTED, never to the clock, or the
  // covered day lands inside its own baseline.
  // Calendar days (DateTime normalises day underflow), not 24 h steps,
  // which a 25 h DST day would leave on the covered date itself.
  final priorFrom = isoDate(DateTime(day.year, day.month, day.day - 7));
  final priorTo = isoDate(DateTime(day.year, day.month, day.day - 1));
  final prior = await dao.mealsBetween(priorFrom, priorTo);
  final typical = typicalDayKcal(dailyCalorieTotals(prior));

  final summary = buildCoachSummary(
    eatenKcal: cal,
    mealCount: food.length,
    proteinG: protein,
    goalKcal: calorieGoal,
    typicalKcal: typical,
    strings: strings,
    formatKcal: formatKcal,
    forYesterday: forYesterday,
  );
  return onDay == null
      ? summary
      : _namedFor(summary, day, onDay, empty: food.isEmpty);
}

/// The card for a day nothing is logged on yet — a night armed ahead
/// (os_summary.dart) — built without the database: the empty-day line.
CoachSummary emptyDaySummary({
  required DateTime day,
  required int calorieGoal,
  required CoachStrings strings,
  SummaryDayNaming? onDay,
}) {
  final summary = buildCoachSummary(
    eatenKcal: 0,
    mealCount: 0,
    proteinG: 0,
    goalKcal: calorieGoal,
    strings: strings,
    formatKcal: formatKcal,
  );
  return onDay == null
      ? summary
      : _namedFor(summary, day, onDay, empty: true);
}

CoachSummary _namedFor(CoachSummary s, DateTime day, SummaryDayNaming onDay,
        {required bool empty}) =>
    CoachSummary(
      title: onDay.title(onDay.dayName(day), formatKcal(s.eaten)),
      body: empty ? onDay.empty : s.body,
      eaten: s.eaten,
      deltaKcal: s.deltaKcal,
      reference: s.reference,
    );

(int, int)? _parseHhmm(String raw) {
  final m = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$').firstMatch(raw.trim());
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}
