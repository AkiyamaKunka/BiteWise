// The daily coach notification's WORDS (user request 2026-08-06). These
// run on a lock screen where the user cannot tap "undo", so every branch
// is pinned: which reference is used, when a day counts as on-target, and
// that a high day is never shaming.
import 'package:calorie_tracker/services/report/coach_summary.dart';
import 'package:flutter_test/flutter_test.dart';

String _fmt(num v) {
  final s = v.round().toString();
  return s.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
}

final strings = CoachStrings(
  title: (k) => 'Today: $k kcal',
  titleYesterday: (k) => 'Yesterday: $k kcal',
  empty: 'Nothing logged today.',
  underGoal: (d) => '$d kcal under your goal',
  underTypical: (d) => '$d kcal below your usual day',
  onTarget: 'Right on target today.',
  overGoal: (d) => '$d kcal over your goal today',
  overTypical: (d) => '$d kcal above your usual today',
  noReference: 'Logged and counted.',
  detail: (m, p) => '$m meals · $p g protein',
);

CoachSummary build({
  num eaten = 2000,
  int meals = 3,
  num protein = 100,
  int? goal,
  int? typical,
}) =>
    buildCoachSummary(
      eatenKcal: eaten,
      mealCount: meals,
      proteinG: protein,
      goalKcal: goal,
      typicalKcal: typical,
      strings: strings,
      formatKcal: _fmt,
    );

void main() {
  test('the GOAL wins when set, even with a median available', () {
    final s = build(eaten: 1600, goal: 2000, typical: 2600);
    expect(s.reference, CoachReference.goal);
    expect(s.deltaKcal, -400);
    expect(s.body, contains('400 kcal under your goal'));
    expect(s.body, isNot(contains('usual')));
  });

  test('no goal falls back to the typical-day median', () {
    final s = build(eaten: 1600, typical: 2000);
    expect(s.reference, CoachReference.typical);
    expect(s.body, contains('400 kcal below your usual day'));
  });

  test('an over day informs without shaming', () {
    final s = build(eaten: 2600, typical: 2000);
    expect(s.deltaKcal, 600);
    expect(s.body, contains('600 kcal above your usual today'));
    // The tone contract: no failure language on a high day.
    for (final word in ['fail', 'bad', 'too much', 'over-eat', 'guilty']) {
      expect(s.body.toLowerCase(), isNot(contains(word)));
    }
  });

  test('near the reference reads as on-target, not a fake deficit', () {
    // 60 kcal is inside the band — an estimate's noise floor.
    expect(build(eaten: 1940, goal: 2000).body,
        contains('Right on target'));
    expect(build(eaten: 2060, goal: 2000).body,
        contains('Right on target'));
    // Just outside it is a real difference again.
    expect(build(eaten: 1850, goal: 2000).body, contains('under your goal'));
  });

  test('a day with no meals says so and never invents a deficit', () {
    final s = build(eaten: 0, meals: 0, goal: 2000);
    expect(s.body, 'Nothing logged today.');
    expect(s.deltaKcal, 0,
        reason: 'an unlogged day is not a 2,000 kcal cut');
  });

  test('no goal and no median yet: honest, still useful', () {
    final s = build(eaten: 1800, meals: 2);
    expect(s.reference, CoachReference.none);
    expect(s.body, contains('Logged and counted.'));
    expect(s.body, contains('2 meals'));
  });

  test('a zero/negative goal counts as unset', () {
    expect(build(eaten: 1600, goal: 0, typical: 2000).reference,
        CoachReference.typical);
    expect(build(eaten: 1600, goal: -500, typical: 2000).reference,
        CoachReference.typical);
  });

  test('the title carries the intake, formatted', () {
    expect(build(eaten: 2180).title, 'Today: 2,180 kcal');
  });

  test('hostile numbers never reach the lock screen', () {
    final s = build(eaten: double.nan, protein: double.infinity, goal: 2000);
    expect(s.eaten, 0);
    expect(s.title, 'Today: 0 kcal');
    expect(s.body, isNot(contains('NaN')));
    expect(s.body, isNot(contains('Infinity')));
  });

  test('the detail line reports meals and protein', () {
    final s = build(eaten: 2000, meals: 4, protein: 118, goal: 2000);
    expect(s.body, contains('4 meals · 118 g protein'));
  });
}
