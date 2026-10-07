/// The iOS daily-summary delivery, shared by the app shell and the
/// background refresh run.
///
/// iOS suspends the process seconds after backgrounding, so the in-process
/// Timer path never fires there; instead the OS is handed ONE card for the
/// next slot carrying the summary as it stands NOW
/// ([ReportNotifier.scheduleDailyAt]). Everything that can change the
/// content re-arms: launch, every lifecycle transition, a meal saved, a
/// slot edit (di.dart / app.dart) — and, since 2026-09-30, the background
/// photo scan (background_glue.dart), so a meal logged with the app closed
/// is in the card the OS delivers.
library;

import '../core/contracts.dart';
import '../services/report/daily_summary.dart';
import '../services/report/notifications.dart';
import '../services/settings/app_settings.dart';
import 'coach_strings.dart';

Future<void> armOsDailySummary({
  required MealsDao dao,
  required AppSettings settings,
  required ReportNotifier notifier,
  DateTime Function() now = DateTime.now,
}) async {
  // init() is idempotent and, on a first launch, resolves only once the
  // permission dialog is answered — arming before that is a card the OS
  // drops silently.
  await notifier.init();
  final when = ReportNotifier.nextDailyOccurrence(
      ReportNotifier.parseHhmm(settings.reportTime), now());
  // The day the card DESCRIBES is the day it fires on — after tonight's
  // slot that is tomorrow, whose honest content is the empty-day line
  // until something is logged and this re-runs.
  final s = await summaryForDay(
    dao: dao,
    day: when,
    calorieGoal: settings.calorieGoal,
    strings: coachStringsFor(settings.appLanguage),
  );
  // Belt and braces: a live in-process Timer must never coexist with the
  // OS card (it would re-post the same slot at the next resume).
  notifier.cancelDaily();
  await notifier.scheduleDailyAt(when: when, title: s.title, body: s.body);
}
