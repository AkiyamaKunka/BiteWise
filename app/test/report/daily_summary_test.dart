// DELIVERY of the daily coach notification (user request 2026-08-06).
// The content is pinned in coach_summary_test; this pins WHEN it fires —
// the part that decides whether the user gets nothing, one, or two
// notifications a day.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/report/coach_summary.dart';
import 'package:calorie_tracker/services/report/daily_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_meals_dao.dart';

final strings = CoachStrings(
  title: (k) => 'Today: $k kcal',
  empty: 'Nothing logged today.',
  underGoal: (d) => '$d under goal',
  underTypical: (d) => '$d below usual',
  onTarget: 'On target.',
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
}
