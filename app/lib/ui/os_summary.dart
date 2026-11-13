/// The daily-summary delivery on both phones, shared by the app shell and
/// the background run.
///
/// The OS is handed ONE card for the next slot carrying the summary as it
/// stands NOW ([ReportNotifier.scheduleDailyAt]), and delivers it with the
/// app dead. Everything that can change the content re-arms: launch, every
/// lifecycle transition, a meal saved, a slot edit (di.dart / app.dart) —
/// and the background photo scan (background_glue.dart), so a meal logged
/// with the app closed is in the card the OS delivers.
///
/// iOS since 2026-09-28: the process is suspended seconds after
/// backgrounding, so an in-process Timer never fired there. Android since
/// the Play push (2026-11-13): it used to post from a Timer or from the
/// 30-minute, network-constrained photo job, so the card came late, or
/// never offline or in the Rare and Restricted standby buckets. The
/// Android card is an inexact alarm (notifications.dart): within about an
/// hour of the slot on Android 12+ — later in Doze or battery saver — with
/// no network needed; the user's battery 'Restricted' setting blocks it.
library;

import '../core/contracts.dart';
import '../services/report/daily_summary.dart';
import '../services/report/notifications.dart';
import '../services/settings/app_settings.dart';
import 'format.dart' show isoDate;
import 'coach_strings.dart';

/// [deliverOverdue] (Android): before arming the next slot, post the card
/// the OS still holds for a slot that has passed. An inexact alarm fires
/// up to an hour late (more in Doze), and a force stop takes the alarm but
/// not the plugin's record of the card; re-arming for the next slot
/// replaces that card, so a meal saved or an app opened at 21:40 used to
/// cost the 21:30 summary. Within [kSummaryGraceWindow] of its slot it is
/// posted now, with the day's numbers as they stand; later it is dropped.
/// iOS fires on time and passes false.
Future<void> armOsDailySummary({
  required MealsDao dao,
  required AppSettings settings,
  required ReportNotifier notifier,
  DateTime Function() now = DateTime.now,
  bool deliverOverdue = false,
}) async {
  if (!settings.summaryEnabled) {
    // Switched off in Settings: nothing may fire. Withdraw whatever is
    // still armed — every lifecycle transition lands here, so a card that
    // outlived the toggle's own cancel is caught on the next one.
    notifier.cancelDaily();
    await notifier.cancelPendingDaily();
    return;
  }
  // init() is idempotent and, on a first iOS launch, resolves only once the
  // permission dialog is answered — arming before that is a card the OS
  // drops silently.
  await notifier.init();
  final strings = coachStringsFor(settings.appLanguage);
  final at = now();
  if (deliverOverdue) {
    final overdue = await notifier.pendingDailySlot();
    if (overdue != null &&
        !overdue.isAfter(at) &&
        at.difference(overdue) <= kSummaryGraceWindow) {
      final day = overdue;
      final s = await summaryForDay(
        dao: dao,
        day: day,
        calorieGoal: settings.calorieGoal,
        strings: strings,
        // Said after midnight, it is about yesterday — and says so.
        forYesterday: isoDate(day) != isoDate(at),
      );
      // Same id as the pending card: the arm below replaces its alarm, so
      // this is the one card the slot gets.
      await notifier.showDailySummary(s.title, s.body);
    }
  }
  final when = ReportNotifier.nextDailyOccurrence(
      ReportNotifier.parseHhmm(settings.reportTime), at);
  // The day the card DESCRIBES is the day it fires on — after tonight's
  // slot that is tomorrow, whose honest content is the empty-day line
  // until something is logged and this re-runs.
  final s = await summaryForDay(
    dao: dao,
    day: when,
    calorieGoal: settings.calorieGoal,
    strings: strings,
  );
  // Belt and braces: a live in-process Timer must never coexist with the
  // OS card (it would re-post the same slot at the next resume).
  notifier.cancelDaily();
  await notifier.scheduleDailyAt(when: when, title: s.title, body: s.body);
}
