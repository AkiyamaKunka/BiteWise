// DELIVERY of the daily coach notification (user request 2026-08-06).
// The content is pinned in coach_summary_test; this pins WHEN it fires —
// the part that decides whether the user gets nothing, one, or two
// notifications a day.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/report/coach_summary.dart';
import 'package:calorie_tracker/services/report/daily_summary.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_meals_dao.dart';

final strings = CoachStrings(
  title: (k) => 'Today: $k kcal',
  titleYesterday: (k) => 'Yesterday: $k kcal',
  empty: 'Nothing logged today.',
  emptyYesterday: 'Nothing logged yesterday.',
  underGoal: (d) => '$d under goal',
  underTypical: (d) => '$d below usual',
  partialGoal: (d) => '$d under goal, meals missing?',
  partialTypical: (d) => '$d below usual, meals missing?',
  onTarget: 'On target.',
  onTypical: 'About usual.',
  overGoal: (d) => '$d over goal',
  overTypical: (d) => '$d above usual',
  noReference: 'Logged.',
  detail: (m, p) => '$m meals · $p g protein',
);

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Meal meal(String date, num kcal, {int id = 1}) => Meal(
      id: id,
      date: date,
      time: '12:00 PM',
      timestamp: '${date}T12:00:00',
      source: 'app_photo',
      imageHash: '',
      analysis: {
        'is_food': true,
        'total_calories': kcal,
        'total_protein_g': 30,
        'meal_description': 'Lunch',
      },
    );

void main() {
  late BaseFakeDao dao;
  late List<(String, String)> posted;
  late List<String> marks;

  setUp(() {
    dao = BaseFakeDao();
    posted = [];
    marks = [];
  });

  DailySummaryDeps deps({
    required DateTime now,
    String reportTime = '21:30',
    int goal = 0,
    String postedDate = '',
  }) =>
      DailySummaryDeps(
        dao: dao,
        reportTime: reportTime,
        calorieGoal: goal,
        postedDate: postedDate,
        markPosted: (d) async => marks.add(d),
        present: (t, b) async => posted.add((t, b)),
        strings: strings,
        now: () => now,
      );

  test('before the slot, nothing fires — the day is still open', () async {
    final now = DateTime(2026, 8, 6, 20, 00);
    dao.put(meal(iso(now), 1800));
    expect(await maybePostDailySummary(deps(now: now)), isFalse);
    expect(posted, isEmpty);
  });

  test('at/after the slot it posts once and records the watermark',
      () async {
    final now = DateTime(2026, 8, 6, 21, 31);
    dao.put(meal(iso(now), 1800));
    expect(await maybePostDailySummary(deps(now: now)), isTrue);
    expect(posted, hasLength(1));
    expect(posted.single.$1, contains('1,800'));
    expect(marks, [iso(now)]);
  });

  test('the watermark makes a second run a no-op — the Timer and the '
      'background heartbeat cannot double-notify', () async {
    final now = DateTime(2026, 8, 6, 21, 31);
    dao.put(meal(iso(now), 1800));
    final already = deps(now: now, postedDate: iso(now));
    expect(await maybePostDailySummary(already), isFalse);
    expect(posted, isEmpty);
  });

  test('yesterday posted does NOT block today', () async {
    final now = DateTime(2026, 8, 6, 22, 00);
    dao.put(meal(iso(now), 1800));
    final d = deps(now: now, postedDate: '2026-08-05');
    expect(await maybePostDailySummary(d), isTrue);
  });

  test('the goal beats the median, and the median is the same 7-day '
      'window Today uses', () async {
    final now = DateTime(2026, 8, 6, 21, 31);
    dao.put(meal(iso(now), 1600, id: 1));
    // Two prior days → a median exists (2,000).
    dao.put(meal(iso(now.subtract(const Duration(days: 1))), 2000, id: 2));
    dao.put(meal(iso(now.subtract(const Duration(days: 2))), 2000, id: 3));

    await maybePostDailySummary(deps(now: now));
    expect(posted.single.$2, contains('400 below usual'));

    posted.clear();
    await maybePostDailySummary(deps(now: now, goal: 1200));
    expect(posted.single.$2, contains('400 over goal'),
        reason: 'a set goal must win over the median');
    expect(posted.single.$2, isNot(contains('usual')));
  });

  test('an empty day still reports, without inventing a deficit', () async {
    final now = DateTime(2026, 8, 6, 21, 31);
    expect(await maybePostDailySummary(deps(now: now, goal: 2000)), isTrue);
    expect(posted.single.$2, 'Nothing logged today.');
  });

  test('a malformed report time posts nothing rather than guessing',
      () async {
    final now = DateTime(2026, 8, 6, 23, 59);
    dao.put(meal(iso(now), 1800));
    expect(
        await maybePostDailySummary(deps(now: now, reportTime: 'not a time')),
        isFalse);
    expect(posted, isEmpty);
  });

  test('non-food rows never count toward the day', () async {
    final now = DateTime(2026, 8, 6, 21, 31);
    dao.put(meal(iso(now), 1800, id: 1));
    dao.put(Meal(
      id: 2,
      date: iso(now),
      time: '1:00 PM',
      timestamp: '${iso(now)}T13:00:00',
      source: 'app_photo',
      imageHash: '',
      analysis: {'is_food': false, 'total_calories': 9999},
    ));
    await maybePostDailySummary(deps(now: now));
    expect(posted.single.$1, contains('1,800'));
    expect(posted.single.$2, contains('1 meals'));
  });

  test('summaryForDay is byte-identical to what the live path posts',
      () async {
    // iOS pre-arms this content hours before the slot; Android posts it
    // live. One builder, so the two can never disagree.
    final now = DateTime(2026, 8, 6, 21, 31);
    dao.put(meal(iso(now), 1800, id: 1));
    dao.put(meal(iso(now.subtract(const Duration(days: 1))), 2000, id: 2));
    dao.put(meal(iso(now.subtract(const Duration(days: 2))), 2000, id: 3));
    await maybePostDailySummary(deps(now: now, goal: 2000));
    final s = await summaryForDay(
        dao: dao, day: now, calorieGoal: 2000, strings: strings);
    expect((s.title, s.body), posted.single);
  });

  test('a card armed for TOMORROW describes tomorrow, not today', () async {
    // After tonight's slot passes, the next OS card fires tomorrow. Today's
    // meals must not leak into it: the honest content for a day with
    // nothing logged is the empty line, until something is logged and the
    // card is re-armed.
    dao.put(meal('2026-08-06', 1800));
    final tomorrowSlot = DateTime(2026, 8, 7, 23, 55);
    final s = await summaryForDay(
        dao: dao, day: tomorrowSlot, calorieGoal: 2000, strings: strings);
    expect(s.title, 'Today: 0 kcal');
    expect(s.body, 'Nothing logged today.');
  });

  // ---------------------------------------------------------------------
  // The 2026-08-16 field bug. On the user's Honor device the "30-minute"
  // WorkManager heartbeat actually ran at 1–6 hour intervals: last night
  // nothing ran between ~20:00 and 00:52, so a 23:34 slot was first seen
  // AFTER midnight. Today's slot had not arrived, nothing matched, and the
  // day's summary was discarded — silently, every night.
  // ---------------------------------------------------------------------

  test('a late run after midnight still delivers the slot it missed',
      () async {
    final slotDay = DateTime(2026, 8, 15);
    dao.put(meal(iso(slotDay), 1800));
    // 00:52 the next morning — the exact time the device's first post-slot
    // job actually ran.
    final now = DateTime(2026, 8, 16, 0, 52);
    expect(await maybePostDailySummary(deps(now: now, reportTime: '23:34')),
        isTrue);
    expect(posted.single.$1, contains('1,800'));
    expect(posted.single.$1, startsWith('Yesterday:'),
        reason: 'after midnight it must not claim to be today');
    expect(marks, [iso(slotDay)],
        reason: 'the watermark belongs to the day covered, not the clock');
  });

  test('the catch-up still fires only once', () async {
    final slotDay = DateTime(2026, 8, 15);
    dao.put(meal(iso(slotDay), 1800));
    final now = DateTime(2026, 8, 16, 0, 52);
    final d = deps(
        now: now, reportTime: '23:34', postedDate: iso(slotDay));
    expect(await maybePostDailySummary(d), isFalse);
    expect(posted, isEmpty);
  });

  test('past the grace window the stale day stays silent', () async {
    dao.put(meal(iso(DateTime(2026, 8, 15)), 1800));
    // 23:34 + 8h = 07:34; 09:00 is too late to still be news.
    final now = DateTime(2026, 8, 16, 9, 00);
    expect(await maybePostDailySummary(deps(now: now, reportTime: '23:34')),
        isFalse);
    expect(posted, isEmpty);
  });

  test('a catch-up compares against the days before the day it covers',
      () async {
    final slotDay = DateTime(2026, 8, 15);
    dao.put(meal(iso(slotDay), 1600, id: 1));
    dao.put(meal(iso(slotDay.subtract(const Duration(days: 1))), 2000, id: 2));
    dao.put(meal(iso(slotDay.subtract(const Duration(days: 2))), 2000, id: 3));
    final now = DateTime(2026, 8, 16, 0, 52);
    await maybePostDailySummary(deps(now: now, reportTime: '23:34'));
    // 1600 vs a 2000 median. If the window were anchored to the CLOCK the
    // covered day would sit inside its own baseline and skew the median.
    expect(posted.single.$2, contains('400 below usual'));
  });

  test('an early-morning run with no missed slot stays silent', () async {
    // Slot 21:30 yesterday was already posted; 02:00 must not re-report it
    // and must not pre-empt today.
    dao.put(meal(iso(DateTime(2026, 8, 15)), 1800));
    final now = DateTime(2026, 8, 16, 2, 00);
    final d = deps(now: now, postedDate: iso(DateTime(2026, 8, 15)));
    expect(await maybePostDailySummary(d), isFalse);
    expect(posted, isEmpty);
  });

  // ---------------------------------------------------------------------
  // US fall-back night (2026-11-01, a 25-hour day in the owner's Central
  // time). A 24 h step back from 23:30 lands on Nov 1 itself, so the old
  // code posted a premature "Yesterday" card with TODAY's partial numbers
  // and watermarked the day, suppressing the real 23:55 post; the 23:55
  // card's baseline also included the covered day. Only reproducible on
  // the old code under a DST zone:
  //   TZ=America/Chicago flutter test test/report/daily_summary_test.dart
  // With calendar arithmetic these pass in every zone.
  // ---------------------------------------------------------------------

  test('on the 25-hour fall-back day, a run before the slot does not post '
      'today as "Yesterday"', () async {
    dao.put(meal('2026-11-01', 900));
    final now = DateTime(2026, 11, 1, 23, 30);
    final d = deps(now: now, reportTime: '23:55', postedDate: '2026-10-31');
    expect(await maybePostDailySummary(d), isFalse);
    expect(posted, isEmpty);
    expect(marks, isEmpty,
        reason: 'watermarking Nov 1 now would swallow the real 23:55 post');
  });

  // ---------------------------------------------------------------------
  // The two posters live in DIFFERENT isolates: the live Timer in the app's
  // engine, the heartbeat in the WorkManager's own engine in the same
  // process. Each has its own SharedPreferences cache, so the watermark
  // the heartbeat writes never reaches the Timer's cache. On Android the
  // freezer can hold an overdue Timer until the heartbeat thaws the
  // process; the Timer then fired right after the heartbeat posted and,
  // reading its stale cache, posted again — a second alert for one card.
  // ---------------------------------------------------------------------

  test('a Timer firing after the heartbeat posted does not post again, '
      'though its isolate\'s prefs cache never saw the watermark', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final now = DateTime(2026, 8, 6, 21, 31);
    dao.put(meal(iso(now), 1800));

    // The app isolate: settings loaded at launch, prefs cache warm.
    SharedPreferences.setMockInitialValues({});
    final appPrefs = await SharedPreferences.getInstance();
    final live =
        await AppSettings.load(prefs: appPrefs, keyStore: _NoKeys());

    // The heartbeat isolate posts and writes the watermark to the native
    // store — behind the app isolate's cache, as a separate engine does.
    final heartbeat = DailySummaryDeps(
      dao: dao,
      reportTime: '21:30',
      calorieGoal: 0,
      postedDate: '',
      markPosted: (d) async => SharedPreferences.setMockInitialValues(
          {'settings.summary_posted_date': d}),
      present: (t, b) async => posted.add((t, b)),
      strings: strings,
      now: () => now,
    );
    expect(await maybePostDailySummary(heartbeat), isTrue);
    expect(appPrefs.getString('settings.summary_posted_date'), isNull,
        reason: 'precondition: the app isolate\'s cache is stale');

    // The thawed Timer fires: postSummary in di.dart reads the watermark
    // through freshSummaryPostedDate().
    final timer =
        deps(now: now, postedDate: await live.freshSummaryPostedDate());
    expect(await maybePostDailySummary(timer), isFalse);
    expect(posted, hasLength(1), reason: 'one summary, one alert');
  });

  test('the fall-back day\'s baseline is the 7 calendar days before it',
      () async {
    final recording = _RangeRecordingDao();
    await summaryForDay(
        dao: recording,
        day: DateTime(2026, 11, 1, 23, 55),
        calorieGoal: 0,
        strings: strings);
    expect(recording.ranges, [
      ('2026-11-01', '2026-11-01'),
      ('2026-10-25', '2026-10-31'),
    ]);
  });

  // ---------------------------------------------------------------------
  // C16/C40: a summary time after midnight. The covered day was the day
  // the slot fell on, so a 00:30 card always said 'Today: 0 kcal' and the
  // day that had just ended was never summarised. Slots from 00:00 to
  // 03:59 now describe the previous calendar day (the app's previous-night
  // rule), as 'Yesterday'. Run under several zones, DST ones included:
  //   for z in UTC America/Chicago Asia/Shanghai Pacific/Auckland; do
  //     TZ=$z flutter test test/report/daily_summary_test.dart; done
  // ---------------------------------------------------------------------
  group('a slot before 04:00 describes the day that just ended', () {
    test('summaryDayFor: 00:00, 00:30 and 03:59 are the day before; 04:00 '
        'is its own day', () {
      expect(summaryDayFor(DateTime(2026, 8, 16, 0, 0)), DateTime(2026, 8, 15));
      expect(summaryDayFor(DateTime(2026, 8, 16, 0, 30)), DateTime(2026, 8, 15));
      expect(summaryDayFor(DateTime(2026, 8, 16, 3, 59)), DateTime(2026, 8, 15));
      expect(summaryDayFor(DateTime(2026, 8, 16, 4, 0)), DateTime(2026, 8, 16));
      expect(summaryDayFor(DateTime(2026, 8, 16, 21, 30)), DateTime(2026, 8, 16));
      // Across a month and a year.
      expect(summaryDayFor(DateTime(2026, 9, 1, 0, 30)), DateTime(2026, 8, 31));
      expect(summaryDayFor(DateTime(2027, 1, 1, 0, 30)), DateTime(2026, 12, 31));
    });

    // Review: on the day DST starts where clocks jump at 03:00 (Europe/
    // Athens, 2026-03-29, 03:00 → 04:00) a 03:30 slot does not exist and
    // normalises to 04:30; the hour of the normalised time read as 'not a
    // night slot' and the card said 'Today: 0 kcal'. The CONFIGURED hour
    // decides. Meaningful under TZ=Europe/Athens; true everywhere.
    test('the configured hour decides, not the normalised one', () {
      final normalised = DateTime(2026, 3, 29, 3, 30); // 04:30 in Athens
      expect(iso(summaryDayFor(normalised, slotHour: 3)), '2026-03-28');
      expect(iso(summaryDayFor(DateTime(2026, 3, 29, 4, 30), slotHour: 4)),
          '2026-03-29');
    });

    test('a 03:30 slot on the DST-start night posts the day that ended',
        () async {
      dao.put(meal('2026-03-28', 1800));
      final now = DateTime(2026, 3, 29, 4, 45);
      expect(await maybePostDailySummary(deps(now: now, reportTime: '03:30')),
          isTrue);
      expect(posted.single.$1, 'Yesterday: 1,800 kcal');
      expect(marks, ['2026-03-28']);
    });

    test('the day after a DST change is still one calendar day back', () {
      // US: Mar 8 (23 h) and Nov 1 (25 h); New Zealand: Apr 5 and Sep 27.
      for (final (slot, day) in [
        (DateTime(2026, 3, 9, 0, 30), '2026-03-08'),
        (DateTime(2026, 11, 2, 0, 30), '2026-11-01'),
        (DateTime(2026, 4, 6, 0, 30), '2026-04-05'),
        (DateTime(2026, 9, 28, 0, 30), '2026-09-27'),
        (DateTime(2026, 3, 9, 3, 59), '2026-03-08'),
        (DateTime(2026, 11, 2, 3, 59), '2026-11-01'),
      ]) {
        expect(iso(summaryDayFor(slot)), day, reason: '$slot');
      }
      // The DST days themselves, at a slot that exists everywhere.
      expect(iso(summaryDayFor(DateTime(2026, 3, 8, 23, 30))), '2026-03-08');
      expect(iso(summaryDayFor(DateTime(2026, 11, 1, 0, 30))), '2026-10-31');
    });

    for (final reportTime in ['00:00', '00:30', '03:59']) {
      test('$reportTime: posts the day that ended, as Yesterday, and '
          'watermarks that day', () async {
        dao.put(meal('2026-08-15', 1800));
        final parts = reportTime.split(':').map(int.parse).toList();
        final now = DateTime(2026, 8, 16, parts[0], parts[1] + 1);
        expect(
            await maybePostDailySummary(
                deps(now: now, reportTime: reportTime)),
            isTrue);
        expect(posted.single.$1, 'Yesterday: 1,800 kcal');
        expect(marks, ['2026-08-15']);
      });
    }

    test('04:00: posts today, as before', () async {
      dao.put(meal('2026-08-15', 1800));
      dao.put(meal('2026-08-16', 300, id: 2));
      final now = DateTime(2026, 8, 16, 4, 1);
      expect(await maybePostDailySummary(deps(now: now, reportTime: '04:00')),
          isTrue);
      expect(posted.single.$1, 'Today: 300 kcal');
      expect(marks, ['2026-08-16']);
    });

    test('the night slot posts once, and not again before the next night',
        () async {
      dao.put(meal('2026-08-15', 1800));
      final at = DateTime(2026, 8, 16, 0, 31);
      await maybePostDailySummary(deps(now: at, reportTime: '00:30'));
      expect(marks, ['2026-08-15']);
      // Later that day: the slot that passed is still 00:30, covering Aug 15.
      expect(
          await maybePostDailySummary(deps(
              now: DateTime(2026, 8, 16, 22, 0),
              reportTime: '00:30',
              postedDate: '2026-08-15')),
          isFalse);
      // Before 00:30 the next night, yesterday's 00:30 is 23.5 h old.
      expect(
          await maybePostDailySummary(deps(
              now: DateTime(2026, 8, 17, 0, 10),
              reportTime: '00:30',
              postedDate: '2026-08-15')),
          isFalse);
      expect(posted, hasLength(1));
    });

    test('its baseline is the 7 days before the day it describes, across '
        'the fall-back night', () async {
      final recording = _RangeRecordingDao();
      final d = DailySummaryDeps(
        dao: recording,
        reportTime: '00:30',
        calorieGoal: 0,
        postedDate: '',
        markPosted: (d) async => marks.add(d),
        present: (t, b) async => posted.add((t, b)),
        strings: strings,
        now: () => DateTime(2026, 11, 2, 0, 31),
      );
      expect(await maybePostDailySummary(d), isTrue);
      expect(recording.ranges, [
        ('2026-11-01', '2026-11-01'),
        ('2026-10-25', '2026-10-31'),
      ]);
      expect(marks, ['2026-11-01']);
      expect(posted.single.$1, startsWith('Yesterday:'));
    });
  });
}

class _RangeRecordingDao extends BaseFakeDao {
  final List<(String, String)> ranges = [];

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) {
    ranges.add((startDate, endDate));
    return super.mealsBetween(startDate, endDate);
  }
}

class _NoKeys implements SecureKeyStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
