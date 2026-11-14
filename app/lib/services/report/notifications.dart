/// Local notifications for the report module (spec §5 delivery surface).
///
/// Two ways to deliver the daily summary:
///   * [ReportNotifier.scheduleDailyAt] hands ONE card for the next slot to
///     the OS, built ahead of time — the path on both phones (iOS since
///     2026-09-28, Android since the Play push, 2026-11-13). The OS
///     delivers it with the app dead; callers re-arm whenever the content
///     could have changed (os_summary.dart).
///   * [ReportNotifier.scheduleDaily] arms an in-process Timer and re-arms
///     after each fire. It dies with the process, so it is only the
///     fallback for a host with no OS scheduler (and the tests' seam).
/// Meal cards and the other notices are posted at once ([showMealCard]).
library;

import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// Test seam: replaces the plugin's show() so scheduling logic is testable
/// without platform channels.
typedef NotificationPresenter = Future<void> Function(
    int id, String title, String body);

/// Test seam for [ReportNotifier.scheduleDailyAt]: the OS-side schedule
/// call, so the iOS delivery path is assertable without platform channels.
typedef NotificationScheduler = Future<void> Function(
    int id, String title, String body, DateTime when, String payload);

/// A daily card the OS still holds ([ReportNotifier.pendingDailyCards]):
/// its id in the daily set, its slot, and the day it describes (null for
/// a card armed before payloads named it).
typedef PendingDailyCard = ({int id, DateTime slot, DateTime? day});

class ReportNotifier {
  ReportNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    DateTime Function()? clock,
    NotificationPresenter? presenter,
    NotificationScheduler? scheduler,
    Future<void> Function(int id)? canceller,
    Future<bool?> Function()? enabledProbe,
    Future<List<int>> Function()? pendingIds,
    Future<String?> Function(DateTime slotDate)? dailyBody,
    ({String name, String description}) Function()? channelStrings,
    ({String name, String description}) Function()? mealChannelStrings,
    int? mealCardIdSeed,
    Future<Map<int, String?>> Function()? pendingPayloads,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _clock = clock ?? DateTime.now,
        // ignore: prefer_initializing_formals
        _presenter = presenter,
        // ignore: prefer_initializing_formals
        _scheduler = scheduler,
        // ignore: prefer_initializing_formals
        _canceller = canceller,
        // ignore: prefer_initializing_formals
        _enabledProbe = enabledProbe,
        // ignore: prefer_initializing_formals
        _pendingIds = pendingIds,
        // ignore: prefer_initializing_formals
        _dailyBody = dailyBody,
        // ignore: prefer_initializing_formals
        _channelStrings = channelStrings,
        // ignore: prefer_initializing_formals
        _mealChannelStrings = mealChannelStrings,
        // ignore: prefer_initializing_formals
        _pendingPayloads = pendingPayloads {
    // Each background run constructs a FRESH notifier; a fixed 100-base
    // would make every run overwrite the previous run's unread meal cards.
    // Headless callers pass a time-derived seed so ids keep advancing.
    if (mealCardIdSeed != null) _nextMealCardId = mealCardIdSeed;
  }

  /// Fixed id: re-firing replaces yesterday's report notification instead of
  /// stacking (one canonical daily report, spec §5.5).
  static const int dailyReportNotificationId = 9001;

  /// How many daily cards one arm can hand the OS: the next slot (on
  /// [dailyReportNotificationId]) and, on Android, the 7 after it, on the
  /// ids that follow (os_summary.dart: with no background job, nothing
  /// else would arm the next night's card). The ids stay clear of the
  /// meal cards' (100 up in the app, 10000 up in background runs).
  static const int dailySetSize = 8;

  /// The daily set's ids, the next slot's first.
  static List<int> get dailySetIds =>
      [for (var i = 0; i < dailySetSize; i++) dailyReportNotificationId + i];

  /// Android: a daily card leaves the shade on its own after this long.
  /// Each night's card has its own id now (one id holds one alarm), so a
  /// card no longer replaces the night before's; 20 hours keeps about one
  /// at a time, as before.
  static const Duration dailyCardLifetime = Duration(hours: 20);

  /// The daily summary's Android channel. The id every install has had
  /// since July 2026 ('Reports & meals', which also carried the meal
  /// cards), kept so the user's settings on it — muted, silent, a sound —
  /// survive; only its name changed, to 'Daily summary' (Play push).
  static const String summaryChannelId = 'calorietracker_reports';

  /// Meal cards and the automatic-scan notices, on their own channel since
  /// the Play push: muting them used to mute the summary too.
  static const String mealChannelId = 'chopstats_meal_cards';

  /// The cards' colour on Android (the small icon and app name in the
  /// shade): the app's terracotta accent, AppColors.light.accent
  /// (notifications_test pins the two together).
  static const Color cardColor = Color(0xFFA64B2A);

  /// Android notification small icon (res/drawable/ic_stat_bitewise.xml).
  /// Android draws a small icon from its alpha channel only, so the
  /// full-colour launcher art this used to name rendered as a blank circle
  /// in the status bar and the shade header. Looked up by name at runtime,
  /// so res/raw/keep.xml must keep it through release resource shrinking.
  static const String androidSmallIcon = 'ic_stat_bitewise';

  final FlutterLocalNotificationsPlugin _plugin;
  final DateTime Function() _clock;
  final NotificationPresenter? _presenter;
  final NotificationScheduler? _scheduler;

  /// Test seam for [cancelPendingDaily]: the OS-side cancel by id.
  final Future<void> Function(int id)? _canceller;
  final Future<bool?> Function()? _enabledProbe;

  /// Test seam for [scheduledDailyAt]: the ids the OS still holds pending.
  final Future<List<int>> Function()? _pendingIds;

  /// Test seam for [pendingDailyCards]: what the OS still holds pending,
  /// id → payload.
  final Future<Map<int, String?>> Function()? _pendingPayloads;

  /// Android channel names/descriptions in the app language — the
  /// summary's and the meal cards' — read at post time so a language
  /// switch shows on the very next card. Injected by the ui/ callers
  /// (localizationsFor) so services/ stays free of ui/; null keeps the
  /// English pair for tests and createSettingsStore's bare fallback
  /// notifier.
  final ({String name, String description}) Function()? _channelStrings;
  final ({String name, String description}) Function()? _mealChannelStrings;

  static const ({String name, String description}) _englishChannel = (
    name: 'Daily summary',
    description: 'Your calorie summary, at the time you set',
  );

  static const ({String name, String description}) _englishMealChannel = (
    name: 'Logged meals',
    description: 'A card for each meal logged automatically from your '
        'camera roll',
  );

  static const Importance _importance = Importance.defaultImportance;

  /// The summary channel's name/description in the app language right now.
  ({String name, String description}) _channel() =>
      _channelStrings?.call() ?? _englishChannel;

  ({String name, String description}) _mealChannel() =>
      _mealChannelStrings?.call() ?? _englishMealChannel;

  /// Set when Android would not create the meal-card channel (or could not
  /// say whether the summary's is blocked): meal cards then go on the
  /// summary's channel, as they did before the split, so a user's mute
  /// still holds.
  bool _mealsOnSummaryChannel = false;

  /// Built per post, not const. Android shows the channel name under
  /// 设置 › 应用 › 筷拍 › 通知 and in every card's long-press menu, and it was
  /// a compile-time English constant — the one English line in an
  /// otherwise Chinese install (API 35 zh-CN emulator, 2026-10-11).
  /// channelAction stays createIfNotExists: with `update` the plugin creates
  /// a MISSING channel never, so on a fresh install Android dropped every
  /// card ("No Channel found", API 35 emulator 2026-10-12). Naming and
  /// renaming is [_syncChannel]'s job, not the post's.
  ///
  /// [meal]: a meal card (or an automatic-scan notice), on the meal-card
  /// channel; else the daily summary's.
  NotificationDetails _details({bool meal = false}) {
    final onMeals = meal && !_mealsOnSummaryChannel;
    final channel = onMeals ? _mealChannel() : _channel();
    return NotificationDetails(
      android: AndroidNotificationDetails(
        onMeals ? mealChannelId : summaryChannelId,
        channel.name,
        channelDescription: channel.description,
        icon: androidSmallIcon,
        color: cardColor,
        timeoutAfter: onMeals ? null : dailyCardLifetime.inMilliseconds,
        importance: _importance,
        priority: Priority.defaultPriority,
        channelAction: AndroidNotificationChannelAction.createIfNotExists,
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
    );
  }

  /// Create the Android channels, or rename existing ones to the app
  /// language. Run from init() — which the foreground app and every
  /// headless run both call before posting — and again before each post so
  /// a 语言 switch shows on the very next card. For an existing channel
  /// Android only takes the name/description (an app cannot raise its
  /// importance), so the user's own per-channel settings survive. Never
  /// throws: a no-op off Android.
  ///
  /// The meal-card channel is new with the Play push. A user who had muted
  /// the old shared channel muted the meal cards with it, so when the
  /// summary's channel is blocked (importance none) the meal channel is
  /// CREATED blocked too — Android accepts IMPORTANCE_NONE at creation
  /// (its range check is NONE..MAX). Should it refuse, or should the
  /// channel list be unreadable, meal cards stay on the summary's channel.
  Future<void> _syncChannel() async {
    final AndroidFlutterLocalNotificationsPlugin? android;
    try {
      android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
    } catch (_) {
      return;
    }
    if (android == null) return; // not Android (or tests)
    final summary = _channel();
    try {
      await android.createNotificationChannel(AndroidNotificationChannel(
        summaryChannelId,
        summary.name,
        description: summary.description,
        importance: _importance,
      ));
    } catch (_) {
      // The post's createIfNotExists still creates a missing channel.
    }
    try {
      final existing =
          await android.getNotificationChannels() ?? const <AndroidNotificationChannel>[];
      final mealExists = existing.any((c) => c.id == mealChannelId);
      final summaryBlocked = existing.any((c) =>
          c.id == summaryChannelId && c.importance == Importance.none);
      final meal = _mealChannel();
      await android.createNotificationChannel(AndroidNotificationChannel(
        mealChannelId,
        meal.name,
        description: meal.description,
        // Only at creation: an existing channel keeps whatever it has.
        importance:
            !mealExists && summaryBlocked ? Importance.none : _importance,
      ));
      _mealsOnSummaryChannel = false;
    } catch (_) {
      _mealsOnSummaryChannel = true;
    }
  }

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

  /// The plugin and the Android channel; on iOS also the permission ask
  /// (DarwinInitializationSettings). Android's permission is NOT asked
  /// here: init ran at every start, so a fresh install got the dialog over
  /// setup and again at the second launch, and two denials are permanent.
  /// It is asked once, in context (notification_permission.dart).
  ///
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
      android: AndroidInitializationSettings('@drawable/$androidSmallIcon'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings: settings);
    await _syncChannel();
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

  /// Withdraw the daily card the OS itself holds — the pending iOS one-shot
  /// from [scheduleDailyAt], or an unread card in the Android shade — for
  /// the user switching the summary off. [cancelDaily] only stops this
  /// process's Timer; a card already handed to the OS would still fire
  /// tonight. Never throws: nothing pending is the common case.
  ///
  /// The whole daily set ([dailySetIds]): on Android an arm holds the next
  /// eight nights' cards.
  Future<void> cancelPendingDaily() async {
    if (_dailyTimer == null) _nextDailyFire = null; // nothing armed anywhere
    final cancel = _canceller;
    for (final id in dailySetIds) {
      if (cancel != null) {
        await cancel(id);
        continue;
      }
      try {
        await _plugin.cancel(id: id);
      } catch (_) {
        // No platform plugin (tests) or nothing to withdraw.
      }
    }
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

  /// The payload of the card [scheduleDailyAt] hands the OS: its slot, as
  /// a UTC instant. The OS keeps it with the pending card, so any engine
  /// can later ask which slot the card it holds is for
  /// ([pendingDailySlot]). Nothing reads it on a tap.
  ///
  /// [day]: the calendar day the card describes, kept too — on the night
  /// DST starts a slot can normalise past the night rule's hour, so the
  /// day cannot always be worked out from the slot again.
  static String dailySlotPayload(DateTime when, {DateTime? day}) {
    final slot = 'daily:${when.toUtc().toIso8601String()}';
    if (day == null) return slot;
    final d = '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    return '$slot@$d';
  }

  static ({DateTime slot, DateTime? day})? _parsePayload(String? payload) {
    const prefix = 'daily:';
    if (payload == null || !payload.startsWith(prefix)) return null;
    final rest = payload.substring(prefix.length).split('@');
    final slot = DateTime.tryParse(rest.first)?.toLocal();
    if (slot == null) return null;
    final day = rest.length > 1 ? DateTime.tryParse(rest[1]) : null;
    return (
      slot: slot,
      day: day == null ? null : DateTime(day.year, day.month, day.day)
    );
  }

  /// The slot in a [dailySlotPayload], in local time; null for anything
  /// else (a card armed before payloads, say).
  static DateTime? slotFromPayload(String? payload) =>
      _parsePayload(payload)?.slot;

  /// The daily cards the OS still holds, earliest slot first; empty when
  /// none, or the OS would not say. On Android a pending card whose slot
  /// has passed has not been delivered yet — an inexact alarm runs late —
  /// or never will be (a force stop takes the alarm, not the plugin's
  /// record of it). Never throws.
  Future<List<PendingDailyCard>> pendingDailyCards() async {
    try {
      final Map<int, String?> pending;
      final probe = _pendingPayloads;
      if (probe != null) {
        pending = await probe();
      } else if (_scheduler != null) {
        return const []; // seam-only tests: no OS
      } else {
        pending = {
          for (final p in await _plugin.pendingNotificationRequests())
            p.id: p.payload,
        };
      }
      final ids = dailySetIds;
      final cards = <PendingDailyCard>[
        for (final e in pending.entries)
          if (ids.contains(e.key))
            if (_parsePayload(e.value) case final parsed?)
              (id: e.key, slot: parsed.slot, day: parsed.day),
      ]..sort((a, b) => a.slot.compareTo(b.slot));
      return cards;
    } catch (_) {
      return const []; // no platform plugin (tests), or the OS would not say
    }
  }

  /// Hand the daily summary to the OS to deliver at [when] — the path on
  /// both phones (os_summary.dart).
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
  /// than stacking one per app open. The card carries its slot
  /// ([dailySlotPayload]).
  ///
  /// Android: an INEXACT alarm (no exact-alarm permission, by policy). On
  /// Android 12+ it fires within about an hour after [when], later in Doze
  /// or battery saver; it needs no network, and even the Restricted
  /// standby bucket allows one a day, but the user's own battery
  /// 'Restricted' setting blocks it. The receivers that deliver it and
  /// re-arm it after a reboot or an app update are declared in the
  /// manifest (flutter_local_notifications' README).
  ///
  /// [id]: one of [dailySetIds] — [dailyReportNotificationId] for the next
  /// slot. [day]: the day the card describes, kept in its payload.
  Future<void> scheduleDailyAt({
    required DateTime when,
    required String title,
    required String body,
    int id = dailyReportNotificationId,
    DateTime? day,
  }) async {
    final payload = dailySlotPayload(when, day: day);
    final scheduler = _scheduler;
    if (scheduler != null) {
      await scheduler(id, title, body, when, payload);
      if (id == dailyReportNotificationId) _nextDailyFire = when;
      return;
    }
    await _syncChannel();
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      // UTC on purpose: [when] is an absolute instant, and TZDateTime.from
      // preserves instants across locations, so no tz database and no
      // platform timezone lookup are needed. (A location would only matter
      // for a repeating wall-clock trigger, which this is not.)
      scheduledDate: tz.TZDateTime.from(when, tz.UTC),
      notificationDetails: _details(),
      payload: payload,
      // Ignored on iOS. Inexact: the app holds no SCHEDULE_EXACT_ALARM or
      // USE_EXACT_ALARM permission, and an exact mode would throw for it.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
    if (id == dailyReportNotificationId) _nextDailyFire = when;
  }

  /// Meal card for watcher-logged meals (spec §6 auto intake surfaces its
  /// §5.4 result card as a notification), on the meal-card channel. Ids
  /// increment so multiple auto-logged meals stack instead of overwriting
  /// each other.
  Future<void> showMealCard(String title, String body) =>
      _present(_nextMealCardId++, title, body, meal: true);

  /// The daily coach summary. Shares the daily-report id so a re-post
  /// REPLACES rather than stacks — one summary per day, by construction
  /// (user request 2026-08-06).
  Future<void> showDailySummary(String title, String body) =>
      _present(dailyReportNotificationId, title, body);

  Future<void> _present(int id, String title, String body,
      {bool meal = false}) async {
    final presenter = _presenter;
    if (presenter != null) return presenter(id, title, body);
    await _syncChannel();
    await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: _details(meal: meal));
  }
}
