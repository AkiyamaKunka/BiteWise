/// armOsDailySummary — the delivery on both phones (the OS holds the card
/// for the next slot) — against the daily summary off switch (2026-10-10),
/// and Android's extras (the Play push and its review, 2026-11-13): the
/// week armed ahead, day-named titles, a card still pending past its slot
/// posted once (arms serialized, the set armed before the post, a card the
/// OS fires mid-arm not posted again, both engines agreeing), and the
/// update day. Behaviour against a fake OS, not source pins.
library;


import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/os_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

const _id = ReportNotifier.dailyReportNotificationId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeOs os;
  late ReportNotifier notifier;
  late _HookDao dao;

  Future<AppSettings> settingsAt({
    bool summary = true,
    String reportTime = '21:30',
    String language = 'en',
    String? postedDate,
  }) async {
    SharedPreferences.setMockInitialValues({
      'settings.summary_enabled': summary,
      'settings.report_time': reportTime,
      'settings.app_language': language,
      'settings.summary_posted_date': ?postedDate,
    });
    return AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: MemoryKeyStore());
  }

  setUp(() {
    os = _FakeOs();
    notifier = os.notifier();
    dao = _HookDao();
  });

  // 2026-11-13 is a Friday.
  final fri19 = DateTime(2026, 11, 13, 19, 0);

  group('iOS (android: false): one card, as before', () {
    test('on: arms the OS card for the next slot', () async {
      await armOsDailySummary(
          dao: dao,
          settings: await settingsAt(),
          notifier: notifier,
          now: () => DateTime(2026, 10, 10, 12, 0));
      expect(os.pending.keys, [_id]);
      expect(os.pending[_id]!.title, 'Today: 0 kcal');
      expect(await notifier.scheduledDailyAt(), DateTime(2026, 10, 10, 21, 30));
    });

    test('off: arms nothing and withdraws the card the OS still holds',
        () async {
      os.pending[_id] = os.card('t', 'b', DateTime(2026, 10, 10, 21, 30));
      await armOsDailySummary(
          dao: dao,
          settings: await settingsAt(summary: false),
          notifier: notifier,
          now: () => DateTime(2026, 10, 10, 12, 0));
      expect(os.pending, isEmpty, reason: 'the pre-switch card is withdrawn');
      expect(await notifier.scheduledDailyAt(), isNull);
    });

    test('a card past its slot is never posted; a 00:30 card says Yesterday',
        () async {
      final s = await settingsAt(reportTime: '00:30');
      dao.seed(_meal('2026-11-13', 650));
      await armOsDailySummary(
          dao: dao, settings: s, notifier: notifier, now: () => fri19);
      expect(os.pending[_id]!.title, 'Yesterday: 650 kcal');
      await armOsDailySummary(
          dao: dao,
          settings: s,
          notifier: notifier,
          now: () => DateTime(2026, 11, 14, 0, 50));
      expect(os.shown, isEmpty);
    });
  });

  group('Android', () {
    Future<void> arm(AppSettings s, DateTime at, {ReportNotifier? via}) =>
        armOsDailySummary(
            dao: dao,
            settings: s,
            notifier: via ?? notifier,
            now: () => at,
            android: true);

    group('the week armed ahead (no background job needed)', () {
      test('one arm holds the next 8 nights: the next with the day, the '
          'rest with the empty-day text, each titled with its day', () async {
        dao.seed(_meal('2026-11-13', 650));
        await arm(await settingsAt(), fri19);
        expect(os.pending.keys, ReportNotifier.dailySetIds);
        final byDay = [
          for (final id in ReportNotifier.dailySetIds) os.pending[id]!
        ];
        expect(byDay.first.when, DateTime(2026, 11, 13, 21, 30));
        expect(byDay.first.title, 'Fri: 650 kcal');
        expect(byDay.last.when, DateTime(2026, 11, 20, 21, 30));
        expect(byDay.map((c) => c.title).skip(1).toList(), [
          'Sat: 0 kcal',
          'Sun: 0 kcal',
          'Mon: 0 kcal',
          'Tue: 0 kcal',
          'Wed: 0 kcal',
          'Thu: 0 kcal',
          'Fri: 0 kcal',
        ]);
        expect(byDay[1].body, startsWith('Nothing logged that day.'));
      });

      test('7 days with the app never opened: 7 cards', () async {
        await arm(await settingsAt(), fri19);
        os.deliverDue(DateTime(2026, 11, 19, 23, 0)); // through Thursday
        expect(os.delivered.map((c) => c.title), [
          'Fri: 0 kcal',
          'Sat: 0 kcal',
          'Sun: 0 kcal',
          'Mon: 0 kcal',
          'Tue: 0 kcal',
          'Wed: 0 kcal',
          'Thu: 0 kcal',
        ]);
      });

      test('a meal logged on day 3 rebuilds the set from that day', () async {
        final s = await settingsAt();
        await arm(s, fri19);
        os.deliverDue(DateTime(2026, 11, 15, 23, 0)); // Fri, Sat, Sun came
        dao.seed(_meal('2026-11-16', 700));
        await arm(s, DateTime(2026, 11, 16, 12, 0)); // Monday, a meal saved
        expect(os.pending.keys.toList()..sort(), ReportNotifier.dailySetIds);
        expect(os.pending[_id]!.when, DateTime(2026, 11, 16, 21, 30));
        expect(os.pending[_id]!.title, 'Mon: 700 kcal');
        expect(os.pending[_id + 7]!.when, DateTime(2026, 11, 23, 21, 30));
        os.deliverDue(DateTime(2026, 11, 17, 23, 0));
        expect(os.delivered.map((c) => c.title).skip(3),
            ['Mon: 700 kcal', 'Tue: 0 kcal']);
      });

      test('switching the summary off withdraws the whole set', () async {
        await arm(await settingsAt(), fri19);
        await arm(await settingsAt(summary: false), fri19);
        expect(os.pending, isEmpty);
        os.deliverDue(DateTime(2026, 12, 31));
        expect(os.delivered, isEmpty);
      });

      test('a new time moves the whole set', () async {
        await arm(await settingsAt(), fri19);
        await arm(await settingsAt(reportTime: '20:00'), fri19);
        expect(os.pending.keys, ReportNotifier.dailySetIds);
        for (final c in os.pending.values) {
          expect((c.when.hour, c.when.minute), (20, 0));
        }
      });
    });

    group('day-named titles (a late card names the right day)', () {
      test('a 23:45 card that comes after midnight still says Friday',
          () async {
        dao.seed(_meal('2026-11-13', 1850));
        await arm(await settingsAt(reportTime: '23:45'), fri19);
        // The inexact alarm comes at 00:40; the title names the day.
        os.deliverDue(DateTime(2026, 11, 14, 0, 40));
        expect(os.delivered.single.title, 'Fri: 1,850 kcal');
      });

      test('in Chinese', () async {
        dao.seed(_meal('2026-11-13', 1850));
        await arm(await settingsAt(language: 'zh'), fri19);
        expect(os.pending[_id]!.title, '周五：1,850 千卡');
        expect(os.pending[_id + 1]!.title, '周六：0 千卡');
        expect(os.pending[_id + 1]!.body, startsWith('当天没有记录。'));
      });

      test('a 00:30 card names the day that ended; 04:00 its own', () async {
        dao.seed(_meal('2026-11-13', 650));
        await arm(await settingsAt(reportTime: '00:30'), fri19);
        expect(os.pending[_id]!.when, DateTime(2026, 11, 14, 0, 30));
        expect(os.pending[_id]!.title, 'Fri: 650 kcal');
        await arm(await settingsAt(reportTime: '04:00'), fri19);
        expect(os.pending[_id]!.title, 'Sat: 0 kcal');
      });
    });

    group('a card still pending past its slot', () {
      test('is posted with the day as it stands — after the set is armed',
          () async {
        final s = await settingsAt();
        await arm(s, fri19);
        dao.seed(_meal('2026-11-13', 650)); // dinner at 21:40, alarm late
        os.log.clear();
        await arm(s, DateTime(2026, 11, 13, 21, 40));
        expect(os.shown.single.title, 'Fri: 650 kcal');
        expect(os.pending[_id]!.when, DateTime(2026, 11, 14, 21, 30));
        expect(os.log.last, 'show:$_id',
            reason: 'every card is re-armed first: ${os.log}');
        expect(os.log.where((e) => e.startsWith('schedule')),
            hasLength(ReportNotifier.dailySetSize));
      });

      test('a card the OS delivered is not posted again', () async {
        final s = await settingsAt();
        await arm(s, fri19);
        os.deliverDue(DateTime(2026, 11, 13, 21, 50));
        await arm(s, DateTime(2026, 11, 13, 22, 5));
        expect(os.shown, isEmpty);
      });

      test('a card the OS fires mid-arm is not posted as well', () async {
        final s = await settingsAt();
        await arm(s, fri19);
        // The alarm goes off while the arm reads the day's meals.
        dao.onRead = () => os.deliverDue(DateTime(2026, 11, 13, 21, 41));
        await arm(s, DateTime(2026, 11, 13, 21, 40));
        expect(os.delivered, hasLength(1), reason: 'the OS card');
        expect(os.shown, isEmpty, reason: 'one alert, not two');
      });

      test('three arms at once (a resume: hidden, inactive, resumed) post '
          'it once', () async {
        final s = await settingsAt();
        await arm(s, fri19);
        final at = DateTime(2026, 11, 13, 21, 40);
        await Future.wait([arm(s, at), arm(s, at), arm(s, at)]);
        expect(os.shown, hasLength(1));
        expect(os.pending.keys, ReportNotifier.dailySetIds);
      });

      // Across engines (separate isolates) the record of the slot posted
      // is what both read: a background run that finds the plugin still
      // listing a card the app already posted — force-stopped alarms stay
      // in the plugin's list — does not post it again.
      test('a background run after the app posted it does not post it again',
          () async {
        final s = await settingsAt();
        await arm(s, fri19);
        await arm(s, DateTime(2026, 11, 13, 21, 40)); // the app posts it
        expect(os.shown, hasLength(1));
        os.pending[_id + 5] =
            os.card('t', 'b', DateTime(2026, 11, 13, 21, 30)); // still listed
        final background = os.notifier(); // another engine, same OS
        await arm(s, DateTime(2026, 11, 13, 21, 45), via: background);
        expect(os.shown, hasLength(1));
        expect(os.pending.keys.toList()..sort(), ReportNotifier.dailySetIds,
            reason: 'the stale entry is replaced by the set');
      });

      test('past the grace window it is dropped, and the set armed',
          () async {
        final s = await settingsAt();
        await arm(s, fri19);
        // A force stop at 20:00 took the alarms; the plugin still lists them.
        await arm(s, DateTime(2026, 11, 14, 9, 0));
        expect(os.shown, isEmpty, reason: 'eleven and a half hours late');
        expect(os.pending[_id]!.when, DateTime(2026, 11, 14, 21, 30));
      });

      test('no in-process Timer: the OS card is the only delivery', () async {
        await notifier.scheduleDaily('21:30');
        await arm(await settingsAt(), fri19);
        expect(await notifier.scheduledDailyAt(),
            DateTime(2026, 11, 13, 21, 30));
        os.pending.clear();
        expect(await notifier.scheduledDailyAt(), isNull,
            reason: 'with no Timer, nothing pending means nothing armed');
      });
    });

    group('the update day', () {
      test('today\'s slot passed and the old scheme had not posted it: '
          'posted once', () async {
        final s = await settingsAt(postedDate: '2026-11-12');
        dao.seed(_meal('2026-11-13', 900));
        await arm(s, DateTime(2026, 11, 13, 22, 0));
        expect(os.shown.single.title, 'Fri: 900 kcal');
        expect(await s.freshSummaryPostedDate(), '2026-11-13');
        await arm(s, DateTime(2026, 11, 13, 22, 30));
        expect(os.shown, hasLength(1));
      });

      test('already posted today by the old scheme, or a fresh install: '
          'nothing', () async {
        await arm(await settingsAt(postedDate: '2026-11-13'),
            DateTime(2026, 11, 13, 22, 0));
        expect(os.shown, isEmpty);
        await arm(await settingsAt(), DateTime(2026, 11, 13, 22, 0));
        expect(os.shown, isEmpty, reason: 'never posted: a new install');
      });

      test('only on the first arm of this scheme', () async {
        final s = await settingsAt(postedDate: '2026-11-11');
        await arm(s, fri19); // before the slot: nothing to catch up
        os.deliverDue(DateTime(2026, 11, 13, 21, 35)); // the OS card came
        await arm(s, DateTime(2026, 11, 13, 22, 0));
        expect(os.shown, isEmpty,
            reason: 'the 21:30 card was armed by the first arm');
        expect(os.delivered.single.title, 'Fri: 0 kcal');
      });

      test('two engines\' first arms post it once', () async {
        final s = await settingsAt(postedDate: '2026-11-12');
        await arm(s, DateTime(2026, 11, 13, 22, 0));
        await arm(s, DateTime(2026, 11, 13, 22, 1), via: os.notifier());
        expect(os.shown, hasLength(1));
      });
    });
  });
}

typedef _Card = ({String title, String body, DateTime when, String payload});

/// The OS side: the pending cards by id, what was posted and delivered,
/// and the order of the calls.
class _FakeOs {
  final pending = <int, _Card>{};
  final shown = <({int id, String title, String body})>[];
  final delivered = <_Card>[];
  final log = <String>[];

  _Card card(String title, String body, DateTime when) => (
        title: title,
        body: body,
        when: when,
        payload: ReportNotifier.dailySlotPayload(when)
      );

  ReportNotifier notifier() => ReportNotifier(
        presenter: (id, title, body) async {
          log.add('show:$id');
          shown.add((id: id, title: title, body: body));
        },
        scheduler: (id, title, body, when, payload) async {
          log.add('schedule:$id');
          pending[id] =
              (title: title, body: body, when: when, payload: payload);
        },
        canceller: (id) async {
          log.add('cancel:$id');
          pending.remove(id);
        },
        pendingIds: () async => pending.keys.toList(),
        pendingPayloads: () async =>
            {for (final e in pending.entries) e.key: e.value.payload},
      );

  /// Delivers every card due by [at], earliest first, as the OS would.
  void deliverDue(DateTime at) {
    final due = pending.entries.where((e) => !e.value.when.isAfter(at)).toList()
      ..sort((a, b) => a.value.when.compareTo(b.value.when));
    for (final e in due) {
      delivered.add(e.value);
      pending.remove(e.key);
    }
  }
}

class _HookDao extends FakeDao {
  void Function()? onRead;

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) {
    final hook = onRead;
    onRead = null;
    hook?.call();
    return super.mealsBetween(startDate, endDate);
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
