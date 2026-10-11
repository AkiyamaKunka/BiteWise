/// armOsDailySummary — the iOS delivery (the OS holds ONE card for the next
/// slot) — against the daily summary off switch (2026-10-10): off arms
/// nothing and withdraws whatever the OS still holds; on is unchanged.
library;

import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/os_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppSettings> settingsAt({required bool summary}) async {
    SharedPreferences.setMockInitialValues({
      'settings.summary_enabled': summary,
      'settings.report_time': '21:30',
    });
    return AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: MemoryKeyStore());
  }

  final noon = DateTime(2026, 10, 10, 12, 0);

  test('on (the default): arms the OS card for the next slot', () async {
    var pending = <int>[];
    final notifier = ReportNotifier(
      presenter: (_, _, _) async {},
      scheduler: (id, _, _, _) async => pending = [id],
      canceller: (id) async => pending.remove(id),
      pendingIds: () async => pending,
    );
    await armOsDailySummary(
      dao: FakeDao(),
      settings: await settingsAt(summary: true),
      notifier: notifier,
      now: () => noon,
    );
    expect(pending, [ReportNotifier.dailyReportNotificationId]);
    expect(await notifier.scheduledDailyAt(), DateTime(2026, 10, 10, 21, 30));
  });

  test('off: arms nothing and withdraws the card the OS still holds',
      () async {
    // Armed before the user flipped the switch — every lifecycle
    // transition lands here, so the next one must take it back.
    var pending = <int>[ReportNotifier.dailyReportNotificationId];
    final scheduled = <DateTime>[];
    final notifier = ReportNotifier(
      presenter: (_, _, _) async {},
      scheduler: (_, _, _, when) async => scheduled.add(when),
      canceller: (id) async => pending.remove(id),
      pendingIds: () async => pending,
    );
    await armOsDailySummary(
      dao: FakeDao(),
      settings: await settingsAt(summary: false),
      notifier: notifier,
      now: () => noon,
    );
    expect(scheduled, isEmpty);
    expect(pending, isEmpty, reason: 'the pre-switch card is withdrawn');
    expect(await notifier.scheduledDailyAt(), isNull);
  });
}
