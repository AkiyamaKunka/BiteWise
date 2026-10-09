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
