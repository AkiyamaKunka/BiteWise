/// armOsDailySummary — the delivery on both phones (the OS holds ONE card
/// for the next slot) — against the daily summary off switch (2026-10-10):
/// off arms nothing and withdraws whatever the OS still holds; on is
/// unchanged. And Android's inexact alarm (2026-11-13): a card still
/// pending past its slot is posted before the next slot replaces it.
library;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/os_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppSettings> settingsAt(
      {required bool summary, String reportTime = '21:30'}) async {
    SharedPreferences.setMockInitialValues({
      'settings.summary_enabled': summary,
      'settings.report_time': reportTime,
      'settings.app_language': 'en',
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

  group('Android: a card still pending past its slot', () {
    late _FakeOs os;
    late ReportNotifier notifier;
    late FakeDao dao;

    setUp(() {
      os = _FakeOs();
      notifier = os.notifier();
      dao = FakeDao();
    });

    Future<void> arm(DateTime at,
            {bool deliverOverdue = true, String reportTime = '21:30'}) async =>
        armOsDailySummary(
          dao: dao,
          settings: await settingsAt(summary: true, reportTime: reportTime),
          notifier: notifier,
          now: () => at,
          deliverOverdue: deliverOverdue,
        );

    test('is posted now, with the day as it stands, before the next slot '
        'is armed', () async {
      await arm(DateTime(2026, 11, 13, 19, 0));
      expect(os.pendingWhen, DateTime(2026, 11, 13, 21, 30));
      // Dinner logged at 21:40; the inexact alarm has not fired yet.
      dao.seed(_meal('2026-11-13', 650));
      await arm(DateTime(2026, 11, 13, 21, 40));
      expect(os.shown, hasLength(1),
          reason: 'the 21:30 card would otherwise be replaced unseen');
      expect(os.shown.single.id, ReportNotifier.dailyReportNotificationId);
      expect(os.shown.single.title, 'Today: 650 kcal');
      expect(os.pendingWhen, DateTime(2026, 11, 14, 21, 30));
    });

    test('a card the OS already delivered is not posted again', () async {
      await arm(DateTime(2026, 11, 13, 19, 0));
      os.fire(); // the alarm went off at 21:30-something
      await arm(DateTime(2026, 11, 13, 22, 5));
      expect(os.shown, isEmpty);
      expect(os.delivered, hasLength(1));
      expect(os.pendingWhen, DateTime(2026, 11, 14, 21, 30));
    });

    test('a card still ahead of its slot is just re-armed', () async {
      await arm(DateTime(2026, 11, 13, 19, 0));
      await arm(DateTime(2026, 11, 13, 20, 0));
      expect(os.shown, isEmpty);
      expect(os.pendingWhen, DateTime(2026, 11, 13, 21, 30));
    });

    test('after midnight it is yesterday\'s card, and says so', () async {
      await arm(DateTime(2026, 11, 13, 19, 0));
      dao.seed(_meal('2026-11-13', 1800));
      await arm(DateTime(2026, 11, 14, 0, 40));
      expect(os.shown.single.title, 'Yesterday: 1,800 kcal');
      expect(os.pendingWhen, DateTime(2026, 11, 14, 21, 30));
    });

    test('past the grace window it is dropped, and the next slot armed',
        () async {
      // A force stop at 20:00 took the alarm; the plugin still lists it.
      await arm(DateTime(2026, 11, 13, 19, 0));
      await arm(DateTime(2026, 11, 14, 9, 0));
      expect(os.shown, isEmpty, reason: 'eleven and a half hours late');
      expect(os.pendingWhen, DateTime(2026, 11, 14, 21, 30));
    });

    test('iOS (deliverOverdue false) never posts one', () async {
      await arm(DateTime(2026, 11, 13, 19, 0), deliverOverdue: false);
      await arm(DateTime(2026, 11, 13, 21, 40), deliverOverdue: false);
      expect(os.shown, isEmpty);
      expect(os.pendingWhen, DateTime(2026, 11, 14, 21, 30));
    });

    test('no in-process Timer is armed: the OS card is the only delivery',
        () async {
      // A Timer left over (an older wiring, a host fallback) is stopped.
      await notifier.scheduleDaily('21:30');
      await arm(DateTime(2026, 11, 13, 19, 0));
      expect(notifier.nextDailyFire, DateTime(2026, 11, 13, 21, 30));
      expect(await notifier.scheduledDailyAt(), DateTime(2026, 11, 13, 21, 30),
          reason: 'answered from the OS card, not a Timer');
      os.pending = null;
      expect(await notifier.scheduledDailyAt(), isNull,
          reason: 'with no Timer, nothing pending means nothing armed');
    });
  });
}

/// The OS side of the daily card: one pending card per id, delivered when
/// the test fires it.
class _FakeOs {
  ({int id, String title, String body, DateTime when})? pending;
  final shown = <({int id, String title, String body})>[];
  final delivered = <({int id, String title, String body, DateTime when})>[];

  DateTime? get pendingWhen => pending?.when;

  ReportNotifier notifier() => ReportNotifier(
        presenter: (id, title, body) async =>
            shown.add((id: id, title: title, body: body)),
        scheduler: (id, title, body, when) async =>
            pending = (id: id, title: title, body: body, when: when),
        canceller: (id) async {
          if (pending?.id == id) pending = null;
        },
        pendingIds: () async => [?pending?.id],
        pendingDailyPayload: () async {
          final p = pending;
          return p == null ? null : ReportNotifier.dailySlotPayload(p.when);
        },
      );

  void fire() {
    final p = pending;
    if (p == null) return;
    delivered.add(p);
    pending = null;
  }
}

Meal _meal(String date, num kcal) => Meal(
      id: 1,
      date: date,
      time: '7:00 PM',
      timestamp: '${date}T19:00:00',
      source: 'app_photo',
      imageHash: '',
      analysis: {
        'is_food': true,
        'total_calories': kcal,
        'total_protein_g': 30,
        'meal_description': 'Dinner',
      },
    );
