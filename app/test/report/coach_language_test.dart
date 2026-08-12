// The coach notification must speak the app's language (user requirement
// 2026-08-06). It is built in a HEADLESS isolate with no BuildContext, so
// the language selection is its own code path — and therefore its own way
// to silently regress to English.
import 'package:calorie_tracker/services/report/coach_summary.dart';
import 'package:calorie_tracker/ui/coach_strings.dart';
import 'package:flutter_test/flutter_test.dart';

CoachSummary summaryIn(String language,
        {num eaten = 1600, int goal = 2000, int meals = 3}) =>
    buildCoachSummary(
      eatenKcal: eaten,
      mealCount: meals,
      proteinG: 100,
      goalKcal: goal,
      strings: coachStringsFor(language),
      formatKcal: (v) => v.round().toString(),
    );

void main() {
  test('zh renders the whole notification in Chinese', () {
    final s = summaryIn('zh');
    expect(s.title, contains('今天'));
    expect(s.title, contains('千卡'));
    expect(s.body, contains('比目标少'));
    expect(s.body, contains('蛋白质'));
    // No English leaking into a Chinese lock screen.
    expect(s.body, isNot(contains('kcal')));
    expect(s.body, isNot(contains('protein')));
    expect(s.title, isNot(contains('Today')));
  });

  test('en renders in English', () {
    final s = summaryIn('en');
    expect(s.title, contains('Today'));
    expect(s.body, contains('under your goal'));
    expect(s.body, contains('protein'));
  });

  test('every branch is translated in zh — no fallback to English', () {
    // under, on-target, over, empty, and no-reference all get real
    // Chinese, not a half-localized message.
    expect(summaryIn('zh', eaten: 1600).body, contains('比目标少'));
    expect(summaryIn('zh', eaten: 2000).body, contains('达标'));
    expect(summaryIn('zh', eaten: 2600).body, contains('比目标多'));
    expect(summaryIn('zh', meals: 0).body, contains('还没有记录'));
    expect(summaryIn('zh', goal: 0).body, contains('已记录'));
    for (final s in [
      summaryIn('zh', eaten: 1600),
      summaryIn('zh', eaten: 2000),
      summaryIn('zh', eaten: 2600),
      summaryIn('zh', meals: 0),
      summaryIn('zh', goal: 0),
    ]) {
      expect(RegExp(r'[a-zA-Z]{4,}').hasMatch(s.body), isFalse,
          reason: 'no English words should survive in: ${s.body}');
    }
  });

  test('an unknown/system language still produces a usable notification',
      () {
    for (final tag in ['system', '', 'fr']) {
      final s = summaryIn(tag);
      expect(s.title, isNotEmpty);
      expect(s.body, isNotEmpty);
    }
  });
}
