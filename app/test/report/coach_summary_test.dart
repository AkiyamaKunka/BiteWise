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
  emptyYesterday: 'Nothing logged yesterday.',
  underGoal: (d) => '$d kcal under your goal',
  underTypical: (d) => '$d kcal below your usual day',
  partialGoal: (d) => '$d kcal under your goal — missed a meal?',
  partialTypical: (d) => '$d kcal below your usual day — missed a meal?',
  onTarget: 'Right on target today.',
  onTypical: 'Right around your usual day.',
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

  test('an in-band day with NO goal never claims a target was hit', () {
    // A user who left the goal empty is measured against their usual day;
    // "on target" would credit them with a target they never set.
    for (final eaten in [1950, 2000, 2080]) {
      final s = build(eaten: eaten, typical: 2000);
      expect(s.reference, CoachReference.typical);
      expect(s.body, contains('Right around your usual day'));
      expect(s.body.toLowerCase(), isNot(contains('target')));
    }
    // With a goal the same day still reads as on target.
    expect(build(eaten: 1950, goal: 2000, typical: 2000).body,
        contains('Right on target'));
  });

  test('a day with no meals says so and never invents a deficit', () {
    final s = build(eaten: 0, meals: 0, goal: 2000);
    expect(s.body, 'Nothing logged today.');
    expect(s.deltaKcal, 0,
        reason: 'an unlogged day is not a 2,000 kcal cut');
  });

  test('a mostly-unlogged day is not praised as a cut', () {
    // One 180 kcal snack against a 2,000 goal used to read "1,820 kcal
    // under your goal — that's a real cut": the very day the empty branch
    // refuses to invent a deficit for. Far under the reference is far
    // more likely missing meals, so the line asks instead of praising.
    final snack = build(eaten: 180, meals: 1, goal: 2000);
    expect(snack.body,
        contains('1,820 kcal under your goal — missed a meal?'));
    expect(snack.deltaKcal, -1820, reason: 'the number itself is honest');
    // Meals logged with no calorie estimate total 0 kcal.
    final unknown = build(eaten: 0, meals: 2, goal: 2000);
    expect(unknown.body,
        contains('2,000 kcal under your goal — missed a meal?'));
    expect(build(eaten: 400, typical: 2000).body,
        contains('1,600 kcal below your usual day — missed a meal?'));
    // A real cut above half the reference keeps the normal line.
    expect(build(eaten: 1100, goal: 2000).body,
        allOf(contains('900 kcal under your goal'),
            isNot(contains('missed a meal'))));
    expect(build(eaten: 1600, goal: 2000).body,
        allOf(contains('400 kcal under your goal'),
            isNot(contains('missed a meal'))));
    // Exactly half is not "far under".
    expect(build(eaten: 1000, goal: 2000).body,
        isNot(contains('missed a meal')));
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

  test('a catch-up empty day says YESTERDAY in the body too', () {
    // Field bug 2026-08-18: the real catch-up notification read
    // "昨天：0 千卡" over a body that still said "nothing logged TODAY".
    final s = buildCoachSummary(
      eatenKcal: 0,
      mealCount: 0,
      proteinG: 0,
      goalKcal: 2000,
      strings: strings,
      formatKcal: _fmt,
      forYesterday: true,
    );
    expect(s.title, 'Yesterday: 0 kcal');
    expect(s.body, 'Nothing logged yesterday.');
    expect(s.body, isNot(contains('today')));
  });

  test('the detail line reports meals and protein', () {
    final s = build(eaten: 2000, meals: 4, protein: 118, goal: 2000);
    expect(s.body, contains('4 meals · 118 g protein'));
  });
}
