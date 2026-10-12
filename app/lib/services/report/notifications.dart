/// Local notifications for the report module (spec §5 delivery surface).
///
/// scheduleDaily takes the dependency-free route the port spec allows: the
/// timezone package is NOT a pubspec dependency, so instead of
/// zonedSchedule the notifier computes the next wall-clock occurrence with
/// plain DateTime, arms a Timer, and re-arms after each fire
/// (reschedule-after-fire pattern). Constraint: an in-process Timer does
/// not survive process death — the integrator re-calls scheduleDaily on app
/// launch with the persisted hh:mm setting. Exact delivery while the app is
/// dead would need zonedSchedule + the timezone dep, or platform alarms.
library;

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// Test seam: replaces the plugin's show() so scheduling logic is testable
/// without platform channels.
typedef NotificationPresenter = Future<void> Function(
    int id, String title, String body);

/// Test seam for [ReportNotifier.scheduleDailyAt]: the OS-side schedule
/// call, so the iOS delivery path is assertable without platform channels.
typedef NotificationScheduler = Future<void> Function(
    int id, String title, String body, DateTime when);

class ReportNotifier {
  ReportNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    DateTime Function()? clock,
    NotificationPresenter? presenter,
    NotificationScheduler? scheduler,
    Future<bool?> Function()? enabledProbe,
    Future<List<int>> Function()? pendingIds,
    Future<String?> Function(DateTime slotDate)? dailyBody,
    int? mealCardIdSeed,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _clock = clock ?? DateTime.now,
        // ignore: prefer_initializing_formals
        _presenter = presenter,
        // ignore: prefer_initializing_formals
        _scheduler = scheduler,
        // ignore: prefer_initializing_formals
        _enabledProbe = enabledProbe,
        // ignore: prefer_initializing_formals
        _pendingIds = pendingIds,
        // ignore: prefer_initializing_formals
        _dailyBody = dailyBody {
    // Each background run constructs a FRESH notifier; a fixed 100-base
    // would make every run overwrite the previous run's unread meal cards.
    // Headless callers pass a time-derived seed so ids keep advancing.
    if (mealCardIdSeed != null) _nextMealCardId = mealCardIdSeed;
  }

  /// Fixed id: re-firing replaces yesterday's report notification instead of
  /// stacking (one canonical daily report, spec §5.5).
  static const int dailyReportNotificationId = 9001;

  static const String _channelId = 'calorietracker_reports';

  final FlutterLocalNotificationsPlugin _plugin;
  final DateTime Function() _clock;
  final NotificationPresenter? _presenter;
  final NotificationScheduler? _scheduler;
  final Future<bool?> Function()? _enabledProbe;

  /// Test seam for [scheduledDailyAt]: the ids the OS still holds pending.
  final Future<List<int>> Function()? _pendingIds;

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      'Reports & meals',
      channelDescription: 'Daily calorie reports and auto-logged meal cards',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );

  /// Body provider for the scheduled notification, given the DATE the slot
  /// was armed for — a Timer that fires late (overnight iOS suspension
  /// delivers it at next resume) must report the intended day, not
  /// whatever partial day it happens to fire in. A throwing provider
  /// degrades to a generic body, never a missed notification.
  /// Returns the body to present, or NULL when the provider already
  /// presented its own notification and this one must stay silent.
  final Future<String?> Function(DateTime slotDate)? _dailyBody;

  Timer? _dailyTimer;
  ({int hour, int minute})? _dailyTime;
  int _nextMealCardId = 100; // distinct ids: meal cards stack, reports don't
  bool _initialized = false;

  DateTime? _nextDailyFire;

  /// The armed daily slot (for UI display and tests); null when unscheduled.
  DateTime? get nextDailyFire => _nextDailyFire;

  Future<void>? _initInFlight;

  /// Single-flight: on iOS the first call blocks on the permission dialog,
  /// and every lifecycle transition the dialog itself causes re-arms the
  /// summary through here — one initialize, everyone awaits it.
  Future<void> init() {
    if (_presenter != null || _initialized) return Future.value();
    return _initInFlight ??= _init().whenComplete(() => _initInFlight = null);
  }

  Future<void> _init() async {
    // DarwinInitializationSettings defaults request alert/badge/sound
    // permission during initialize on iOS/macOS.
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings: settings);
    try {
      // Android 13+ runtime grant; a denial means silent no-shows, so a
      // failure here is non-fatal.
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Older plugin/platform combinations: proceed without the grant.
    }
    _initialized = true;
  }

  /// Parse a 24-hour "HH:mm" string. Throws [ArgumentError] on anything else.
  static ({int hour, int minute}) parseHhmm(String hhmm) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
    if (match != null) {
      final hour = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);
      if (hour <= 23 && minute <= 59) return (hour: hour, minute: minute);
    }
    throw ArgumentError.value(hhmm, 'hhmm', 'expected 24h "HH:mm"');
  }

  /// Next wall-clock occurrence of [time] strictly after [now]; a slot equal
  /// to now schedules tomorrow. The component constructor normalizes day
  /// overflow, keeping DST days correct at wall-clock level.
  static DateTime nextDailyOccurrence(
      ({int hour, int minute}) time, DateTime now) {
    var candidate =
        DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (!candidate.isAfter(now)) {
      candidate =
          DateTime(now.year, now.month, now.day + 1, time.hour, time.minute);
    }
    return candidate;
  }

  /// Arm (or re-arm, replacing any previous schedule) the daily report
  /// notification at [hhmm] local wall-clock time.
  Future<void> scheduleDaily(String hhmm) async {
    // parseHhmm throws before any state changes: an invalid hh:mm leaves an
    // existing schedule running.
    _dailyTime = parseHhmm(hhmm);
    _armDailyTimer();
  }

  void cancelDaily() {
    _dailyTimer?.cancel();
    _dailyTimer = null;
    _dailyTime = null;
    _nextDailyFire = null;
  }

  void _armDailyTimer() {
    final time = _dailyTime;
    if (time == null) return;
    _dailyTimer?.cancel();
    final now = _clock();
    final next = nextDailyOccurrence(time, now);
    _nextDailyFire = next;
    _dailyTimer = Timer(next.difference(now), () {
      // Reschedule-after-fire: re-arm BEFORE presenting so a throwing body
      // can never kill tomorrow's schedule.
      final slotDate = next;
      _armDailyTimer();
      unawaited(_fireDaily(slotDate));
    });
  }

  Future<void> _fireDaily(DateTime slotDate) async {
    var body = 'Your daily calorie report is ready.';
    final provider = _dailyBody;
    if (provider != null) {
      try {
        final produced = await provider(slotDate);
        // NULL means "I already presented the notification myself — do not
        // present another one". The coach summary posts through
        // showDailySummary, which shares dailyReportNotificationId; without
        // this the _present below REPLACED that summary with this generic
        // English title and whatever body the provider returned. It
        // returned '', so the user got "📊 Daily Calorie Report" and a
        // blank line instead of their Chinese summary — every single time
        // the notification fired (found on-device 2026-08-16 at 23:55).
        if (produced == null) return;
        body = produced;
      } catch (_) {
        // Keep the fallback body; the schedule already re-armed.
      }
    }
    await _present(dailyReportNotificationId, '📊 Daily Calorie Report', body);
  }

  /// Whether the OS will show this app's notifications at all. Null when
  /// the platform cannot say. On iOS a declined permission makes every
  /// scheduled summary vanish silently — Settings uses this to say so
  /// instead of letting the user wonder (2026-09-28).
  Future<bool?> notificationsEnabled() async {
    final probe = _enabledProbe;
    if (probe != null) return probe();
    try {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return (await ios.checkPermissions())?.isEnabled;
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // await: a returned-but-unawaited Future would escape the catch below
      // (unawaited_return_in_try_block on newer Dart; CI caught it).
      if (android != null) return await android.areNotificationsEnabled();
    } catch (_) {
      // A probe failure must never break Settings; "unknown" hides the hint.
    }
    return null;
  }

  /// The slot the daily summary is armed for, as far as this process can
  /// tell: the live Timer's next fire (Android), or — on the OS path — the
  /// last armed slot IF the OS still lists the card as pending. Null means
  /// nothing is armed, which Settings shows as "not scheduled" so a silent
  /// no-show has a visible cause instead of a shrug (2026-09-30).
  Future<DateTime?> scheduledDailyAt() async {
    if (_dailyTimer != null) return _nextDailyFire;
    final next = _nextDailyFire;
    if (next == null) return null;
    final probe = _pendingIds;
    if (probe == null && _scheduler != null) return next; // seam-only tests
    try {
      final ids = probe != null
          ? await probe()
          : (await _plugin.pendingNotificationRequests())
              .map((p) => p.id)
              .toList();
      return ids.contains(dailyReportNotificationId) ? next : null;
    } catch (_) {
      return next; // the OS would not say: trust what was armed
    }
  }

  /// Hand the daily summary to the OS to deliver at [when] — the iOS path.
  ///
  /// iOS suspends the process seconds after backgrounding and this app has
  /// no background execution there (spec §6: share/picker only, no
  /// WorkManager), so [scheduleDaily]'s in-process Timer only ever fires if
  /// the app happens to be open at the slot. The OS scheduler fires with
  /// the app dead. The trade: content must exist at ARM time, so callers
  /// re-arm whenever it could have changed (launch, lifecycle, slot edits).
  ///
  /// ONE-SHOT, deliberately. A repeating trigger (matchDateTimeComponents)
  /// would re-fire the same card tomorrow — yesterday's numbers under a
  /// "today" title. If the app is never opened again, silence beats a lie.
  ///
  /// Same id as the live path, so a re-arm REPLACES the pending card rather
  /// than stacking one per app open.
  Future<void> scheduleDailyAt({
    required DateTime when,
    required String title,
    required String body,
  }) async {
    final scheduler = _scheduler;
    if (scheduler != null) {
      await scheduler(dailyReportNotificationId, title, body, when);
      _nextDailyFire = when;
      return;
    }
    await _plugin.zonedSchedule(
      id: dailyReportNotificationId,
      title: title,
      body: body,
      // UTC on purpose: [when] is an absolute instant, and TZDateTime.from
      // preserves instants across locations, so no tz database and no
      // platform timezone lookup are needed. (A location would only matter
      // for a repeating wall-clock trigger, which this is not.)
      scheduledDate: tz.TZDateTime.from(when, tz.UTC),
      notificationDetails: _details,
      // Ignored on iOS. Inexact so that if Android ever opts in this cannot
      // throw for a missing SCHEDULE_EXACT_ALARM grant.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
    _nextDailyFire = when;
  }

  /// Meal card for watcher-logged meals (spec §6 auto intake surfaces its
  /// §5.4 result card as a notification). Ids increment so multiple
  /// auto-logged meals stack instead of overwriting each other.
  Future<void> showMealCard(String title, String body) =>
      _present(_nextMealCardId++, title, body);

  /// The daily coach summary. Shares the daily-report id so a re-post
  /// REPLACES rather than stacks — one summary per day, by construction
  /// (user request 2026-08-06).
  Future<void> showDailySummary(String title, String body) =>
      _present(dailyReportNotificationId, title, body);

  Future<void> _present(int id, String title, String body) async {
    final presenter = _presenter;
    if (presenter != null) return presenter(id, title, body);
    await _plugin.show(
        id: id, title: title, body: body, notificationDetails: _details);
  }
}
