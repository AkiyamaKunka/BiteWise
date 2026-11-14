/// The daily-summary delivery on both phones, shared by the app shell and
/// the background run.
///
/// The OS is handed the card for the next slot carrying the summary as it
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
///
/// Android, besides ([armOsDailySummary]'s `android`):
///   * the 7 nights after the next one are armed too, on their own ids,
///     with the empty-day text — with Watch Camera Roll off there is no
///     background job, and a day the app is not opened would otherwise
///     have no summary (main posted one every night). Any arm rebuilds
///     the whole set; switching the summary off withdraws it;
///   * titles name the day ('Thu: 1,850 kcal'), since a card can come late;
///   * a card still pending past its slot (a late inexact alarm, or one a
///     force stop took) is posted before the set replaces it — once, by
///     whichever engine gets there first;
///   * the first arm after the update posts today's summary if its slot
///     passed and the old scheme had not posted it.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/coerce.dart' show addCalendarDays;
import '../core/contracts.dart';
import '../services/report/coach_summary.dart' show CoachStrings, CoachSummary;
import '../services/report/daily_summary.dart';
import '../services/report/notifications.dart';
import '../services/settings/app_settings.dart';
import 'coach_strings.dart';
import 'format.dart' show isoDate;

/// The slot (UTC instant) of the last daily card the app posted itself —
/// an overdue one, or the update day's. Both engines read it fresh before
/// posting and write it first, so the two never post the same slot.
const String summaryLastPostedSlotPrefsKey = 'summary.last_posted_slot';

/// Set by the first Android arm of this scheme; until then the update-day
/// catch-up may run ([armOsDailySummary]).
const String summaryOsSchemePrefsKey = 'summary.os_android_scheme';

/// One arm at a time per notifier: every lifecycle transition, launch,
/// meal saved and background run arms, and a resume alone sends three
/// (hidden, inactive, resumed). Arms overlapping each read the same
/// overdue card and each posted it (review: three posts). One runs; the
/// arms asked for meanwhile become ONE more, run after it with the latest
/// request.
final Expando<_ArmSerial> _arms = Expando<_ArmSerial>('summary arms');

class _ArmSerial {
  bool _busy = false;
  Future<void> Function()? _next;
  Completer<void>? _nextDone;

  Future<void> run(Future<void> Function() job) {
    if (!_busy) return _drive(job);
    _next = job;
    return (_nextDone ??= Completer<void>()).future;
  }

  Future<void> _drive(Future<void> Function() job) async {
    _busy = true;
    try {
      await job();
    } finally {
      final next = _next, done = _nextDone;
      _next = null;
      _nextDone = null;
      _busy = false;
      if (next != null) {
        unawaited(
          _drive(next).then(
            (_) => done!.complete(),
            onError: (Object e, StackTrace st) => done!.completeError(e, st),
          ),
        );
      }
    }
  }
}

/// Arm the daily summary for the next slot — on Android the next eight
/// slots — and withdraw it when the summary is off. See the library docs.
///
/// [android]: the Android extras (the week armed ahead, day-named titles,
/// the overdue post, the update-day post). iOS passes false and arms one
/// card, as before.
Future<void> armOsDailySummary({
  required MealsDao dao,
  required AppSettings settings,
  required ReportNotifier notifier,
  DateTime Function() now = DateTime.now,
  bool android = false,
  Future<SharedPreferences> Function()? prefs,
}) => (_arms[notifier] ??= _ArmSerial()).run(
  () => _armOnce(
    dao: dao,
    settings: settings,
    notifier: notifier,
    now: now,
    android: android,
    prefs: prefs ?? SharedPreferences.getInstance,
  ),
);

Future<void> _armOnce({
  required MealsDao dao,
  required AppSettings settings,
  required ReportNotifier notifier,
  required DateTime Function() now,
  required bool android,
  required Future<SharedPreferences> Function() prefs,
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
  final naming = android ? summaryDayNamingFor(settings.appLanguage) : null;
  final time = ReportNotifier.parseHhmm(settings.reportTime);
  final at = now();

  // 1. A card for a slot that has passed, to post: the update day's, or
  //    one the OS still holds past its time. Built, not posted yet.
  ({DateTime slot, PendingDailyCard? pending, CoachSummary card})? toPost;
  if (android) {
    final p = await _freshPrefs(prefs);
    if (p != null && !(p.getBool(summaryOsSchemePrefsKey) ?? false)) {
      toPost = await _updateDayCard(dao, settings, strings, naming!, time, at);
    }
    toPost ??= await _overdueCard(
      dao,
      settings,
      notifier,
      strings,
      naming!,
      time,
      at,
      p,
    );
  }

  // 2. The cards to arm: the next slot with the day as it stands, and on
  //    Android the 7 after it with the empty-day text (no meal can be in a
  //    day that has not started; logging re-arms and rebuilds them).
  final first = ReportNotifier.nextDailyOccurrence(time, at);
  final slots = [
    for (var k = 0; k < (android ? ReportNotifier.dailySetSize : 1); k++)
      k == 0
          ? first
          : (() {
              final d = addCalendarDays(first, k);
              return DateTime(d.year, d.month, d.day, time.hour, time.minute);
            })(),
  ];
  final cards = <({DateTime slot, DateTime day, CoachSummary card})>[];
  for (final (k, slot) in slots.indexed) {
    // The day the card DESCRIBES is the day it fires on, or for a slot
    // before 04:00 the day that just ended (C16/C40).
    final day = summaryDayFor(slot, slotHour: time.hour);
    final card = k == 0
        ? await summaryForDay(
            dao: dao,
            day: day,
            calorieGoal: settings.calorieGoal,
            strings: strings,
            forYesterday: summaryIsAboutYesterday(day, slot),
            onDay: naming,
          )
        : emptyDaySummary(
            day: day,
            calorieGoal: settings.calorieGoal,
            strings: strings,
            onDay: naming,
          );
    cards.add((slot: slot, day: day, card: card));
  }

  // 3. A pending card that fired while the cards were built has been
  //    delivered by the OS: posting it as well would be a second alert.
  final pendingPost = toPost?.pending;
  if (pendingPost != null) {
    final still = await notifier.pendingDailyCards();
    if (!still.any(
      (c) => c.id == pendingPost.id && c.slot == pendingPost.slot,
    )) {
      toPost = null;
    }
  }

  // 4. Arm the set BEFORE posting: it replaces the overdue card's alarm,
  //    so the OS cannot deliver it after the app has.
  // Belt and braces: a live in-process Timer must never coexist with the
  // OS card (it would re-post the same slot at the next resume).
  notifier.cancelDaily();
  for (final (k, c) in cards.indexed) {
    await notifier.scheduleDailyAt(
      id: ReportNotifier.dailyReportNotificationId + k,
      when: c.slot,
      title: c.card.title,
      body: c.card.body,
      day: c.day,
    );
  }

  // 5. Post (claimed in step 1, so once across both engines).
  final post = toPost;
  if (post != null) {
    await notifier.showDailySummary(post.card.title, post.card.body);
  }
  if (android) {
    try {
      await (await prefs()).setBool(summaryOsSchemePrefsKey, true);
    } catch (_) {}
  }
}

Future<SharedPreferences?> _freshPrefs(
  Future<SharedPreferences> Function() prefs,
) async {
  try {
    final p = await prefs();
    await p.reload();
    return p;
  } catch (_) {
    return null;
  }
}

/// The latest card the OS still holds past its slot, within the grace
/// window and not already posted by either engine, with its content built
/// now. Older ones are dropped: their alarms are replaced by the arm.
Future<({DateTime slot, PendingDailyCard? pending, CoachSummary card})?>
_overdueCard(
  MealsDao dao,
  AppSettings settings,
  ReportNotifier notifier,
  CoachStrings strings,
  SummaryDayNaming naming,
  ({int hour, int minute}) time,
  DateTime at,
  SharedPreferences? p,
) async {
  final due = [
    for (final c in await notifier.pendingDailyCards())
      if (!c.slot.isAfter(at) && at.difference(c.slot) <= kSummaryGraceWindow)
        c,
  ];
  if (due.isEmpty) return null;
  final card = due.last; // the most recent slot
  if (!await _claim(p, card.slot)) return null;
  final day = card.day ?? summaryDayFor(card.slot, slotHour: time.hour);
  return (
    slot: card.slot,
    pending: card,
    card: await summaryForDay(
      dao: dao,
      day: day,
      calorieGoal: settings.calorieGoal,
      strings: strings,
      onDay: naming,
    ),
  );
}

/// The first Android arm after the update: if today's slot (or last
/// night's, within the grace window) passed and the old scheme's watermark
/// does not have it, its card — the old scheme posted from a Timer or the
/// background job, and nothing of the new one is armed yet. Only for an
/// install the old scheme had already posted on: a fresh install says
/// nothing until its first slot.
Future<({DateTime slot, PendingDailyCard? pending, CoachSummary card})?>
_updateDayCard(
  MealsDao dao,
  AppSettings settings,
  CoachStrings strings,
  SummaryDayNaming naming,
  ({int hour, int minute}) time,
  DateTime at,
) async {
  final String posted;
  try {
    posted = await settings.freshSummaryPostedDate();
  } catch (_) {
    return null;
  }
  if (posted.isEmpty) return null;
  final slot = lastSlotWithinGrace(time.hour, time.minute, at);
  if (slot == null) return null;
  final day = summaryDayFor(slot, slotHour: time.hour);
  if (isoDate(day) == posted) return null;
  final p = await _freshPrefs(SharedPreferences.getInstance);
  if (!await _claim(p, slot)) return null;
  try {
    await settings.markSummaryPosted(isoDate(day));
  } catch (_) {}
  return (
    slot: slot,
    pending: null,
    card: await summaryForDay(
      dao: dao,
      day: day,
      calorieGoal: settings.calorieGoal,
      strings: strings,
      onDay: naming,
    ),
  );
}

/// Claims [slot] for this engine's post: false when either engine already
/// has. Read fresh and written in one step, as soon as the post is
/// decided, so the other engine's window is the store's own round trip
/// (a claimed post later dropped — the OS fired it meanwhile — loses
/// nothing: the OS delivered it). Without a store, true.
Future<bool> _claim(SharedPreferences? p, DateTime slot) async {
  if (p == null) return true;
  final mark = slot.toUtc().toIso8601String();
  try {
    await p.reload();
  } catch (_) {}
  if (p.getString(summaryLastPostedSlotPrefsKey) == mark) return false;
  try {
    await p.setString(summaryLastPostedSlotPrefsKey, mark);
  } catch (_) {}
  return true;
}
