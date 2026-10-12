/// Tests for ReportNotifier's dependency-free daily scheduling (spec §5):
/// hh:mm parsing, next-occurrence math, the reschedule-after-fire pattern,
/// re-scheduling replacing the old slot, and meal-card presentation.
library;

import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what ReportNotifier hands the real plugin. Everything else
/// (the permission request) hits Fake's throwing noSuchMethod, which init
/// already treats as non-fatal.
class _RecordingPlugin extends Fake implements FlutterLocalNotificationsPlugin {
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
      scheduler: (id, title, body, when) async =>
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
          ? (name: '总结与餐食', description: '每日热量总结和自动记录的餐食卡片')
          : (name: 'Reports & meals', description: 'Daily reports'),
    );
    await notifier.init();
    await notifier.showMealCard('🍽️ 已自动记录一餐', '约 450 千卡');
    final zh = plugin.shown.single!.android!;
    expect(zh.channelName, '总结与餐食');
    expect(zh.channelDescription, '每日热量总结和自动记录的餐食卡片');
    // Friends' installs already hold the English channel, and the plugin
    // leaves an existing channel alone unless told to update it.
    expect(zh.channelAction, AndroidNotificationChannelAction.update);
    expect(zh.channelId, 'calorietracker_reports',
        reason: 'a new id would orphan the old channel and its toggles');
    expect(zh.icon, ReportNotifier.androidSmallIcon);

    // Read at post time: switching 语言 flips the next card, no restart.
    language = 'en';
    await notifier.showDailySummary('Today', '1800 kcal');
    expect(plugin.shown.last!.android!.channelName, 'Reports & meals');
  });

  test('without channel strings the channel keeps its English name',
      () async {
    final plugin = _RecordingPlugin();
    final notifier = ReportNotifier(plugin: plugin);
    await notifier.init();
    await notifier.showMealCard('Meal logged', '~450 kcal');
    final android = plugin.shown.single!.android!;
    expect(android.channelName, 'Reports & meals');
    expect(android.channelDescription,
        'Daily calorie reports and auto-logged meal cards');
  });

  test('scheduledDailyAt answers only while the OS still holds the card',
      () async {
    // The Settings "next summary" row: the armed slot when the OS lists
    // id 9001 as pending, null once it fired or was never accepted.
    var pending = <int>[];
    final notifier = ReportNotifier(
      scheduler: (id, title, body, when) async => pending = [id],
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
  test('cancelPendingDaily withdraws id 9001 from the OS', () async {
    final plugin = _RecordingPlugin();
    final notifier = ReportNotifier(plugin: plugin);
    await notifier.cancelPendingDaily();
    expect(plugin.cancelled, [ReportNotifier.dailyReportNotificationId]);
    expect(await notifier.scheduledDailyAt(), isNull);
  });

  test('cancelPendingDaily after an OS arm leaves nothing armed', () async {
    var pending = <int>[];
    final notifier = ReportNotifier(
      scheduler: (id, title, body, when) async => pending = [id],
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
