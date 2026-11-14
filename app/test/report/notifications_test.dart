/// Tests for ReportNotifier's dependency-free daily scheduling (spec §5):
/// hh:mm parsing, next-occurrence math, the reschedule-after-fire pattern,
/// re-scheduling replacing the old slot, and meal-card presentation.
library;

import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart' show AppColors;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' show TZDateTime;

/// Records what ReportNotifier hands the real plugin. Everything else
/// (the permission request) hits Fake's throwing noSuchMethod, which init
/// already treats as non-fatal.
class _RecordingPlugin extends Fake implements FlutterLocalNotificationsPlugin {
  _RecordingPlugin({this.android});

  /// When set, plays the Android implementation the notifier resolves to
  /// create its channel; null keeps the old non-Android behaviour.
  final _FakeAndroid? android;
  InitializationSettings? settings;
  final shown = <NotificationDetails?>[];
  final cancelled = <int>[];

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelled.add(id);

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async {
    this.settings = settings;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async =>
      shown.add(notificationDetails);

  /// What zonedSchedule was handed, and the pending list it builds (the
  /// plugin's own record, as Android keeps it until the alarm fires).
  final zoned = <({int id, TZDateTime when, String? payload,
      AndroidScheduleMode mode})>[];
  final pending = <PendingNotificationRequest>[];
  final zonedDetails = <NotificationDetails?>[];

  @override
  Future<void> zonedSchedule({
    required int id,
    required TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    zoned.add((
      id: id,
      when: scheduledDate,
      payload: payload,
      mode: androidScheduleMode
    ));
    zonedDetails.add(notificationDetails);
    pending
      ..removeWhere((p) => p.id == id)
      ..add(PendingNotificationRequest(id, title, body, payload));
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async =>
      List.of(pending);

  @override
  T? resolvePlatformSpecificImplementation<
          T extends FlutterLocalNotificationsPlatform>() =>
      android is T ? android as T : null;
}

/// The Android side: records the channels created and permission asks,
/// and keeps the channel list as Android would (an existing channel keeps
/// its importance; only its name and description follow a create).
class _FakeAndroid extends Fake
    implements AndroidFlutterLocalNotificationsPlugin {
  _FakeAndroid(
      {List<AndroidNotificationChannel> existing = const [], this.refuse})
      : live = {for (final c in existing) c.id: c};

  final channels = <AndroidNotificationChannel>[];
  final Map<String, AndroidNotificationChannel> live;
  int permissionRequests = 0;

  /// A channel id whose creation throws, as Android would for one it
  /// refuses.
  final String? refuse;

  @override
  Future<void> createNotificationChannel(
      AndroidNotificationChannel notificationChannel) async {
    if (notificationChannel.id == refuse) {
      throw PlatformException(code: 'refused');
    }
    channels.add(notificationChannel);
    final old = live[notificationChannel.id];
    live[notificationChannel.id] = AndroidNotificationChannel(
        notificationChannel.id, notificationChannel.name,
        description: notificationChannel.description,
        importance: old?.importance ?? notificationChannel.importance);
  }

  @override
  Future<List<AndroidNotificationChannel>?> getNotificationChannels() async =>
      live.values.toList();

  @override
  Future<bool?> requestNotificationsPermission() async {
    permissionRequests++;
    return true;
  }
}

void main() {
  group('parseHhmm', () {
    test('accepts 24h HH:mm', () {
      expect(ReportNotifier.parseHhmm('08:00'), (hour: 8, minute: 0));
      expect(ReportNotifier.parseHhmm('23:59'), (hour: 23, minute: 59));
      expect(ReportNotifier.parseHhmm('7:05'), (hour: 7, minute: 5));
      expect(ReportNotifier.parseHhmm(' 09:30 '), (hour: 9, minute: 30));
    });

    test('rejects out-of-range and malformed input', () {
      for (final bad in ['24:00', '12:60', '8am', '', '08:0', '08-00', '8:5']) {
        expect(() => ReportNotifier.parseHhmm(bad), throwsArgumentError,
            reason: bad);
      }
    });
  });

  group('nextDailyOccurrence', () {
    final now = DateTime(2026, 7, 17, 8, 0);

    test('later today when the slot is still ahead', () {
      expect(
          ReportNotifier.nextDailyOccurrence((hour: 9, minute: 30), now),
          DateTime(2026, 7, 17, 9, 30));
    });

    test('tomorrow when the slot equals now (strictly-after rule)', () {
      expect(
          ReportNotifier.nextDailyOccurrence((hour: 8, minute: 0), now),
          DateTime(2026, 7, 18, 8, 0));
    });

    test('tomorrow when the slot already passed, across month ends', () {
      expect(
          ReportNotifier.nextDailyOccurrence(
              (hour: 6, minute: 0), DateTime(2026, 7, 31, 7, 0)),
          DateTime(2026, 8, 1, 6, 0));
    });
  });

  testWidgets('scheduleDaily fires at the slot and re-arms for the next day',
      (tester) async {
    var now = DateTime(2026, 7, 17, 7, 0);
    final fired = <(int, String, String)>[];
    final notifier = ReportNotifier(
      clock: () => now,
      presenter: (id, title, body) async => fired.add((id, title, body)),
      dailyBody: (slotDate) async => 'report body for $slotDate',
    );

    await notifier.scheduleDaily('08:00');
    expect(notifier.nextDailyFire, DateTime(2026, 7, 17, 8, 0));

    await tester.pump(const Duration(minutes: 59));
    expect(fired, isEmpty);

    now = DateTime(2026, 7, 17, 8, 0);
    await tester.pump(const Duration(minutes: 1));
    expect(fired.length, 1);
    expect(fired.single.$1, ReportNotifier.dailyReportNotificationId);
    expect(fired.single.$2, '📊 Daily Calorie Report');
    // The body is built FOR THE ARMED SLOT's date — a late fire (overnight
    // suspension) must report the intended day, not the fresh morning.
    expect(fired.single.$3, 'report body for ${DateTime(2026, 7, 17, 8, 0)}');
    // Reschedule-after-fire: the next slot is armed without a new call.
    expect(notifier.nextDailyFire, DateTime(2026, 7, 18, 8, 0));

    now = DateTime(2026, 7, 18, 8, 0);
    await tester.pump(const Duration(hours: 24));
    expect(fired.length, 2);

    notifier.cancelDaily();
    expect(notifier.nextDailyFire, isNull);
    await tester.pump(const Duration(hours: 48));
    expect(fired.length, 2);
  });

  testWidgets(
      'a null dailyBody presents NOTHING — the provider already posted',
      (tester) async {
    // Regression, found on-device 2026-08-16 23:55. The coach summary posts
    // itself through showDailySummary on dailyReportNotificationId; the
    // scheduled fire then presented AGAIN on that same id, replacing the
    // user's Chinese summary with "📊 Daily Calorie Report" and an empty
    // body. The provider now returns null to claim the slot.
    var now = DateTime(2026, 7, 17, 7, 0);
    final fired = <(int, String, String)>[];
    var providerCalls = 0;
    final notifier = ReportNotifier(
      clock: () => now,
      presenter: (id, title, body) async => fired.add((id, title, body)),
      dailyBody: (slotDate) async {
        providerCalls++;
        return null; // "handled — do not present over me"
      },
    );

    await notifier.scheduleDaily('08:00');
    now = DateTime(2026, 7, 17, 8, 0);
    await tester.pump(const Duration(hours: 1));

    expect(providerCalls, 1, reason: 'the slot still fires');
    expect(fired, isEmpty,
        reason: 'but nothing is presented over the provider\'s own card');
    // Tomorrow is still armed: claiming the slot must not break the chain.
    expect(notifier.nextDailyFire, DateTime(2026, 7, 18, 8, 0));
    notifier.cancelDaily();
  });

  test('scheduleDailyAt hands the OS ONE card for the slot, by the live id',
      () async {
    // The iOS path (2026-09-28): no background execution exists to build
    // the summary at the slot, so it is built ahead of time and handed to
    // the OS. Pinned here: the id is the SAME as the live path's, so every
    // re-arm replaces the pending card instead of stacking one per launch.
    final scheduled = <(int, String, String, DateTime)>[];
    final notifier = ReportNotifier(
      scheduler: (id, title, body, when, _) async =>
          scheduled.add((id, title, body, when)),
    );
    final when = DateTime(2026, 9, 28, 23, 55);
    await notifier.scheduleDailyAt(
        when: when, title: '今天：1,800 千卡', body: '比目标少 200 千卡');
    expect(scheduled, hasLength(1));
    expect(scheduled.single.$1, ReportNotifier.dailyReportNotificationId);
    expect(scheduled.single.$4, when);

    // Re-arm after a meal is logged: same id, fresher content.
    await notifier.scheduleDailyAt(
        when: when, title: '今天：2,100 千卡', body: '比目标多 100 千卡');
    expect(scheduled.last.$1, ReportNotifier.dailyReportNotificationId);
    expect(scheduled.last.$2, '今天：2,100 千卡');
    expect(notifier.nextDailyFire, when,
        reason: 'the Settings "next summary" row reads the armed slot');
  });

  testWidgets('re-scheduling replaces the previous slot', (tester) async {
    var now = DateTime(2026, 7, 17, 7, 0);
    final fired = <(int, String, String)>[];
    final notifier = ReportNotifier(
      clock: () => now,
      presenter: (id, title, body) async => fired.add((id, title, body)),
    );

    await notifier.scheduleDaily('08:00');
    await notifier.scheduleDaily('09:00');
    expect(notifier.nextDailyFire, DateTime(2026, 7, 17, 9, 0));

    now = DateTime(2026, 7, 17, 8, 30);
    await tester.pump(const Duration(minutes: 90));
    expect(fired, isEmpty, reason: 'the 08:00 timer must be cancelled');

    now = DateTime(2026, 7, 17, 9, 0);
    await tester.pump(const Duration(minutes: 30));
    expect(fired.length, 1);

    notifier.cancelDaily();
  });

  testWidgets('an invalid reschedule leaves the running schedule intact',
      (tester) async {
    var now = DateTime(2026, 7, 17, 7, 0);
    final fired = <(int, String, String)>[];
    final notifier = ReportNotifier(
      clock: () => now,
      presenter: (id, title, body) async => fired.add((id, title, body)),
    );

    await notifier.scheduleDaily('08:00');
    await expectLater(notifier.scheduleDaily('25:99'), throwsArgumentError);
    expect(notifier.nextDailyFire, DateTime(2026, 7, 17, 8, 0));

    now = DateTime(2026, 7, 17, 8, 0);
    await tester.pump(const Duration(hours: 1));
    expect(fired.length, 1);

    notifier.cancelDaily();
  });

  testWidgets('a throwing dailyBody degrades to the fallback body and re-arms',
      (tester) async {
    var now = DateTime(2026, 7, 17, 7, 0);
    final fired = <(int, String, String)>[];
    final notifier = ReportNotifier(
      clock: () => now,
      presenter: (id, title, body) async => fired.add((id, title, body)),
      dailyBody: (_) async => throw StateError('builder broke'),
    );

    await notifier.scheduleDaily('08:00');
    now = DateTime(2026, 7, 17, 8, 0);
    await tester.pump(const Duration(hours: 1));
    expect(fired.length, 1);
    expect(fired.single.$3, 'Your daily calorie report is ready.');
    expect(notifier.nextDailyFire, DateTime(2026, 7, 18, 8, 0));

    notifier.cancelDaily();
  });

  test('showMealCard presents with distinct stacking ids', () async {
    final fired = <(int, String, String)>[];
    final notifier = ReportNotifier(
      presenter: (id, title, body) async => fired.add((id, title, body)),
    );
    await notifier.init(); // presenter mode: must not touch the plugin
    await notifier.showMealCard('Meal logged', '~450 kcal');
    await notifier.showMealCard('Meal logged', '~620 kcal');
    expect(fired.length, 2);
    expect(fired[0].$2, 'Meal logged');
    expect(fired[0].$3, '~450 kcal');
    expect(fired[1].$3, '~620 kcal');
    expect(fired[0].$1, isNot(fired[1].$1));
    expect(fired.map((f) => f.$1),
        isNot(contains(ReportNotifier.dailyReportNotificationId)));
  });

  // Android draws the small icon from its alpha channel only: the
  // full-colour launcher art ('@mipmap/ic_launcher') came out as a blank
  // circle in the status bar and the shade header. Both the plugin default
  // and every card name the white-on-transparent mark instead.
  test('Android notifications use the monochrome mark, not the launcher art',
      () async {
    final plugin = _RecordingPlugin();
    final notifier = ReportNotifier(plugin: plugin);
    await notifier.init();
    expect(plugin.settings!.android!.defaultIcon,
        '@drawable/${ReportNotifier.androidSmallIcon}');
    await notifier.showMealCard('Meal logged', '~450 kcal');
    await notifier.showDailySummary('Today', '1800 kcal');
    expect(plugin.shown, hasLength(2));
    for (final details in plugin.shown) {
      expect(details!.android!.icon, ReportNotifier.androidSmallIcon);
    }
  });

  // Android shows the channel name under 设置 › 应用 › 筷拍 › 通知 and in a
  // card's long-press menu; it was a compile-time English constant, the one
  // English line in a Chinese install (API 35 zh-CN emulator, 2026-10-11).
  test('the Android channel is named in the app language on every post',
      () async {
    final plugin = _RecordingPlugin();
    var language = 'zh';
    final notifier = ReportNotifier(
      plugin: plugin,
      channelStrings: () => language == 'zh'
          ? (name: '每日总结', description: '在你设定的时间发送当天的热量总结')
          : (name: 'Daily summary', description: 'Your summary'),
      mealChannelStrings: () => language == 'zh'
          ? (name: '自动记录的餐食', description: '从相册自动记录每一餐时发送的卡片')
          : (name: 'Logged meals', description: 'A card per meal'),
    );
    await notifier.init();
    await notifier.showMealCard('🍽️ 已自动记录一餐', '约 450 千卡');
    final zh = plugin.shown.single!.android!;
    expect(zh.channelName, '自动记录的餐食');
    expect(zh.channelDescription, '从相册自动记录每一餐时发送的卡片');
    // `update` never creates a MISSING channel: on a fresh install every
    // card was dropped. Renaming is the channel sync's job (below).
    expect(zh.channelAction,
        AndroidNotificationChannelAction.createIfNotExists);
    expect(zh.channelId, ReportNotifier.mealChannelId);
    expect(zh.icon, ReportNotifier.androidSmallIcon);

    // Read at post time: switching 语言 flips the next card, no restart.
    language = 'en';
    await notifier.showDailySummary('Today', '1800 kcal');
    final summary = plugin.shown.last!.android!;
    expect(summary.channelName, 'Daily summary');
    expect(summary.channelId, 'calorietracker_reports',
        reason: 'a new id would orphan the old channel and its toggles');
  });

  // A fresh Android install has no channel, and a post naming
  // channelAction.update never creates one: Android dropped every meal card,
  // daily summary and pause notice ("No Channel found", API 35 emulator,
  // 2026-10-12). init — run by the foreground app and every headless run —
  // creates it, and each post re-syncs the name for a language switch.
  test('init creates the Android channel, named in the app language',
      () async {
    final android = _FakeAndroid();
    final plugin = _RecordingPlugin(android: android);
    var language = 'zh';
    final notifier = ReportNotifier(
      plugin: plugin,
      channelStrings: () => language == 'zh'
          ? (name: '每日总结', description: '在你设定的时间发送当天的热量总结')
          : (name: 'Daily summary', description: 'Your summary'),
      mealChannelStrings: () => language == 'zh'
          ? (name: '自动记录的餐食', description: '从相册自动记录每一餐时发送的卡片')
          : (name: 'Logged meals', description: 'A card per meal'),
    );
    await notifier.init();
    expect(android.channels.map((c) => c.id),
        ['calorietracker_reports', ReportNotifier.mealChannelId]);
    final summary = android.channels.first, meals = android.channels.last;
    expect(summary.name, '每日总结');
    expect(meals.name, '自动记录的餐食');
    expect(meals.description, '从相册自动记录每一餐时发送的卡片');
    for (final c in android.channels) {
      expect(c.importance, Importance.defaultImportance);
    }

    await notifier.showMealCard('🍽️ 已自动记录一餐', '约 450 千卡');
    final posted = plugin.shown.single!.android!;
    expect(posted.channelId, meals.id,
        reason: 'a card on another id would land on a missing channel');
    expect(posted.importance, meals.importance);

    language = 'en';
    await notifier.showDailySummary('Today', '1800 kcal');
    expect(plugin.shown.last!.android!.channelId, summary.id);
    expect(android.live[summary.id]!.name, 'Daily summary',
        reason: 'an existing channel is renamed on the next post');
    expect(android.live[meals.id]!.name, 'Logged meals');
  });

  // The Play push (2026-11-13): one channel carried everything, so muting
  // meal cards muted the summary. The summary keeps the old id (and the
  // user's settings on it); meal cards get their own.
  group('the meal-card channel', () {
    test('a user who had muted the old channel finds the new one muted too',
        () async {
      final android = _FakeAndroid(existing: [
        const AndroidNotificationChannel(
            'calorietracker_reports', 'Reports & meals',
            importance: Importance.none),
      ]);
      final notifier =
          ReportNotifier(plugin: _RecordingPlugin(android: android));
      await notifier.init();
      expect(android.live[ReportNotifier.mealChannelId]!.importance,
          Importance.none);
      expect(android.live['calorietracker_reports']!.importance,
          Importance.none,
          reason: 'untouched');
      expect(android.live['calorietracker_reports']!.name, 'Daily summary');
    });

    // Review (finding 9): 'Silent' on the old shared channel (importance
    // low) muted the meal cards' sound too; the new channel keeps it.
    test('the new channel takes the old one\'s importance when lower than '
        'default, never higher', () async {
      for (final (old, expected) in const [
        (Importance.low, Importance.low), // Silent
        (Importance.min, Importance.min),
        (Importance.high, Importance.defaultImportance),
        (Importance.defaultImportance, Importance.defaultImportance),
        (Importance.unspecified, Importance.defaultImportance),
      ]) {
        final android = _FakeAndroid(existing: [
          AndroidNotificationChannel('calorietracker_reports', 'Reports & meals',
              importance: old),
        ]);
        await ReportNotifier(plugin: _RecordingPlugin(android: android))
            .init();
        expect(android.live[ReportNotifier.mealChannelId]!.importance,
            expected,
            reason: '$old');
      }
    });

    test('created only once: later syncs never ask for importance none',
        () async {
      final android = _FakeAndroid(existing: [
        const AndroidNotificationChannel('calorietracker_reports', 'x',
            importance: Importance.none),
        const AndroidNotificationChannel(
            ReportNotifier.mealChannelId, 'Logged meals',
            importance: Importance.defaultImportance),
      ]);
      final notifier =
          ReportNotifier(plugin: _RecordingPlugin(android: android));
      await notifier.init();
      await notifier.showMealCard('t', 'b');
      final mealCreates = android.channels
          .where((c) => c.id == ReportNotifier.mealChannelId);
      expect(mealCreates, isNotEmpty);
      for (final c in mealCreates) {
        expect(c.importance, Importance.defaultImportance,
            reason: 'Android lets an app LOWER an unedited channel');
      }
    });

    test('if Android refuses it, meal cards stay on the summary\'s channel',
        () async {
      final android = _FakeAndroid(refuse: ReportNotifier.mealChannelId);
      final plugin = _RecordingPlugin(android: android);
      final notifier = ReportNotifier(plugin: plugin);
      await notifier.init();
      await notifier.showMealCard('🍽️ Meal logged automatically', 'Pasta');
      expect(
          plugin.shown.single!.android!.channelId, 'calorietracker_reports');
      expect(plugin.shown.single!.android!.channelName, 'Daily summary');
    });

    test('the summary and the OS card stay on the old id, both coloured '
        'with the accent', () async {
      final android = _FakeAndroid();
      final plugin = _RecordingPlugin(android: android);
      final notifier = ReportNotifier(plugin: plugin);
      await notifier.showDailySummary('Today: 1,800 kcal', 'On target.');
      await notifier.showMealCard('🍽️ Meal logged automatically', 'Pasta');
      await notifier.scheduleDailyAt(
          when: DateTime(2026, 11, 13, 21, 30), title: 't', body: 'b');
      expect(plugin.shown.map((d) => d!.android!.channelId),
          ['calorietracker_reports', ReportNotifier.mealChannelId]);
      for (final d in plugin.shown) {
        expect(d!.android!.color, ReportNotifier.cardColor);
      }
      expect(plugin.zonedDetails.single!.android!.channelId,
          'calorietracker_reports');
      expect(ReportNotifier.cardColor, AppColors.light.accent,
          reason: 'the app\'s accent, written out for the services layer');
    });
  });

  // The Play push (2026-11-13): init runs at every start, in the app and
  // in each background run; asking there put the dialog over setup, again
  // at the second launch, and two denials are permanent. It is asked in
  // context now (notification_permission.dart).
  test('init never asks for Android\'s notification permission', () async {
    final android = _FakeAndroid();
    final notifier = ReportNotifier(plugin: _RecordingPlugin(android: android));
    await notifier.init();
    expect(android.channels, isNotEmpty, reason: 'it did initialize');
    expect(android.permissionRequests, 0);
  });

  test('without channel strings the channels keep their English names',
      () async {
    final plugin = _RecordingPlugin();
    final notifier = ReportNotifier(plugin: plugin);
    await notifier.init();
    await notifier.showMealCard('Meal logged', '~450 kcal');
    await notifier.showDailySummary('Today', '1800 kcal');
    final meal = plugin.shown.first!.android!;
    expect(meal.channelName, 'Logged meals');
    expect(meal.channelDescription,
        'A card for each meal logged automatically from your camera roll');
    final summary = plugin.shown.last!.android!;
    expect(summary.channelName, 'Daily summary');
    expect(summary.channelDescription,
        'Your calorie summary, at the time you set');
  });

  // The Android OS card (Play push, 2026-11-13): the alarm is inexact, and
  // the card says which slot it is for, so a re-arm after the slot can
  // tell a card still waiting for its alarm from one delivered.
  test('the OS cards are inexact and carry their slot and day, which read '
      'back while the OS holds them', () async {
    final plugin = _RecordingPlugin(android: _FakeAndroid());
    final notifier = ReportNotifier(plugin: plugin);
    expect(await notifier.pendingDailyCards(), isEmpty);
    final when = DateTime(2026, 11, 13, 21, 30);
    final later = DateTime(2026, 11, 14, 0, 30);
    await notifier.scheduleDailyAt(
        when: when, title: 't', body: 'b', day: DateTime(2026, 11, 13));
    await notifier.scheduleDailyAt(
        id: ReportNotifier.dailyReportNotificationId + 1,
        when: later,
        title: 't',
        body: 'b',
        day: DateTime(2026, 11, 13));
    final z = plugin.zoned.first;
    expect(z.id, ReportNotifier.dailyReportNotificationId);
    expect(z.mode, AndroidScheduleMode.inexactAllowWhileIdle,
        reason: 'no exact-alarm permission is declared, by policy');
    expect(z.when.isAtSameMomentAs(when), isTrue);
    expect(z.payload,
        ReportNotifier.dailySlotPayload(when, day: DateTime(2026, 11, 13)));
    expect(await notifier.pendingDailyCards(), [
      (
        id: ReportNotifier.dailyReportNotificationId,
        slot: when,
        day: DateTime(2026, 11, 13)
      ),
      (
        id: ReportNotifier.dailyReportNotificationId + 1,
        slot: later,
        day: DateTime(2026, 11, 13)
      ),
    ]);
    expect(await notifier.scheduledDailyAt(), when,
        reason: 'the next slot is the first id\'s');
    plugin.pending.removeWhere(
        (p) => p.id == ReportNotifier.dailyReportNotificationId); // fired
    expect((await notifier.pendingDailyCards()).map((c) => c.id),
        [ReportNotifier.dailyReportNotificationId + 1]);
  });

  test('a meal card or another app id is never read as a daily card',
      () async {
    final notifier = ReportNotifier(
      scheduler: (_, _, _, _, _) async {},
      pendingPayloads: () async => {
        100: ReportNotifier.dailySlotPayload(DateTime(2026, 11, 13, 21)),
        ReportNotifier.dailyReportNotificationId: 'junk',
        ReportNotifier.dailyReportNotificationId + 2:
            ReportNotifier.dailySlotPayload(DateTime(2026, 11, 15, 21)),
      },
    );
    expect((await notifier.pendingDailyCards()).map((c) => c.id),
        [ReportNotifier.dailyReportNotificationId + 2]);
  });

  test('the summary cards leave the shade on their own; meal cards stay',
      () async {
    final plugin = _RecordingPlugin(android: _FakeAndroid());
    final notifier = ReportNotifier(plugin: plugin);
    await notifier.showDailySummary('Fri: 1,850 kcal', 'On target.');
    await notifier.showMealCard('🍽️ Meal logged automatically', 'Pasta');
    expect(plugin.shown.first!.android!.timeoutAfter,
        ReportNotifier.dailyCardLifetime.inMilliseconds);
    expect(plugin.shown.last!.android!.timeoutAfter, isNull);
  });

  test('a pending card without a slot payload reads as no slot', () async {
    expect(ReportNotifier.slotFromPayload(null), isNull);
    expect(ReportNotifier.slotFromPayload(''), isNull);
    expect(ReportNotifier.slotFromPayload('daily:junk'), isNull);
    expect(ReportNotifier.slotFromPayload('meal:2026-11-13T03:30:00.000Z'),
        isNull);
    final when = DateTime(2026, 3, 8, 2, 30); // any local wall time
    expect(ReportNotifier.slotFromPayload(ReportNotifier.dailySlotPayload(when)),
        when);
    final notifier = ReportNotifier(plugin: _BarePlugin());
    await expectLater(notifier.pendingDailyCards(), completion(isEmpty),
        reason: 'no platform plugin: never throws');
  });

  test('scheduledDailyAt answers only while the OS still holds the card',
      () async {
    // The Settings "next summary" row: the armed slot when the OS lists
    // id 9001 as pending, null once it fired or was never accepted.
    var pending = <int>[];
    final notifier = ReportNotifier(
      scheduler: (id, title, body, when, _) async => pending = [id],
      pendingIds: () async => pending,
    );
    expect(await notifier.scheduledDailyAt(), isNull);
    final when = DateTime(2026, 9, 30, 21, 30);
    await notifier.scheduleDailyAt(when: when, title: 't', body: 'b');
    expect(await notifier.scheduledDailyAt(), when);
    pending = []; // delivered (or dropped): nothing pending any more
    expect(await notifier.scheduledDailyAt(), isNull);
  });

  // The daily summary off switch (2026-10-10): cancelDaily only stops this
  // process's Timer; the card already handed to the OS (iOS one-shot, or
  // an unread Android card) has to be withdrawn by id.
  test('cancelPendingDaily withdraws the whole daily set from the OS',
      () async {
    final plugin = _RecordingPlugin();
    final notifier = ReportNotifier(plugin: plugin);
    await notifier.cancelPendingDaily();
    expect(plugin.cancelled, ReportNotifier.dailySetIds);
    expect(plugin.cancelled.first, ReportNotifier.dailyReportNotificationId);
    expect(await notifier.scheduledDailyAt(), isNull);
  });

  test('cancelPendingDaily after an OS arm leaves nothing armed', () async {
    var pending = <int>[];
    final notifier = ReportNotifier(
      scheduler: (id, title, body, when, _) async => pending = [id],
      canceller: (id) async => pending.remove(id),
      pendingIds: () async => pending,
    );
    await notifier.scheduleDailyAt(
        when: DateTime(2026, 10, 10, 21, 30), title: 't', body: 'b');
    expect(await notifier.scheduledDailyAt(), isNotNull);
    await notifier.cancelPendingDaily();
    expect(pending, isEmpty);
    expect(await notifier.scheduledDailyAt(), isNull);
  });

  test('cancelPendingDaily never throws without a platform plugin', () async {
    final notifier = ReportNotifier(plugin: _BarePlugin());
    await expectLater(notifier.cancelPendingDaily(), completes);
  });
}

/// Every call hits Fake's throwing noSuchMethod — a plugin with no
/// platform behind it.
class _BarePlugin extends Fake implements FlutterLocalNotificationsPlugin {}
