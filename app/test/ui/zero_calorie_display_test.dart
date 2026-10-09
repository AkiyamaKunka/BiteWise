// A meal saved with a blank calories field is stored as total_calories 0 —
// blank means ZERO for a curated meal (meal_edit_logic.dart; pinned in
// meal_edit_logic_test.dart). Found 2026-10-08 in the Chinese UI: the day
// header summed that 0 and read "~0 千卡" while the meal's own row read
// "~? 千卡", because displayTotalCalories ported Python's `0 or "?"` and
// treated a recorded zero as unknown. A numeric 0 now renders as 0 on every
// card surface; a value that is genuinely absent still renders '?'.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/format.dart';
import 'package:calorie_tracker/ui/meal_edit_logic.dart';
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/widgets/meal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Widget _zhHost(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

/// What the editor persists for "description typed, every number blank".
Map<String, dynamic> _blankCaloriesAnalysis() => (MealDraft.blank(
  DateTime(2026, 10, 8, 12, 30),
)..description = '白粥').toAnalysis();

Meal _meal(Map<String, dynamic> analysis, {bool corrected = true}) => Meal(
  id: 0,
  date: '2026-10-08',
  time: '12:30 PM',
  timestamp: '2026-10-08T12:30:00.000',
  source: 'app_manual',
  analysis: analysis,
  corrected: corrected,
);

void main() {
  group('displayTotalCalories', () {
    test('a numeric zero is a recorded value, not unknown', () {
      expect(displayTotalCalories({'total_calories': 0}), '0');
      expect(displayTotalCalories({'total_calories': 0.0}), '0');
    });

    test('a missing value still renders "?" (spec §3.5 fallback)', () {
      expect(displayTotalCalories(<String, dynamic>{}), '?');
      for (final v in [null, '', false, <dynamic>[], <String, dynamic>{}]) {
        expect(
          displayTotalCalories({'total_calories': v}),
          '?',
          reason: '$v has no calorie value to show',
        );
      }
    });

    test('other values stay raw', () {
      expect(displayTotalCalories({'total_calories': 450}), '450');
      expect(displayTotalCalories({'total_calories': 450.5}), '450.5');
      expect(displayTotalCalories({'total_calories': '0'}), '0');
      expect(displayTotalCalories({'total_calories': 'NaN'}), 'NaN');
    });

    test('card and day total agree for an editor-saved blank-calorie meal', () {
      final a = _blankCaloriesAnalysis();
      expect(a['total_calories'], 0); // the documented editor contract
      final totals = todayTotals([_meal(a)]);
      expect(displayTotalCalories(a), formatKcal(totals.cal));
    });
  });

  testWidgets('zh day detail: header and the meal row both read ~0 千卡', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao()..seed(_meal(_blankCaloriesAnalysis()));

    await tester.pumpWidget(
      _zhHost(
        DayDetailScreen(
          dao: dao,
          date: '2026-10-08',
          now: () => DateTime(2026, 10, 8, 20),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('dayTotalKcal'))).data,
      '~0 千卡',
    );
    expect(
      find.text('~0 千卡'),
      findsNWidgets(2),
      reason: 'the header and the meal row show the same zero',
    );
    expect(find.textContaining('~?'), findsNothing);
  });

  testWidgets('zh meal card (Today) shows ~0 千卡 for a blank-calorie meal', (
    tester,
  ) async {
    await tester.pumpWidget(
      _zhHost(
        Scaffold(
          body: MealCard(
            meal: _meal(_blankCaloriesAnalysis(), corrected: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('~0 千卡'), findsOneWidget);
    expect(find.textContaining('~?'), findsNothing);
  });

  testWidgets('a meal with NO calorie value still shows ~? on its card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _zhHost(
        Scaffold(
          body: MealCard(
            meal: _meal({
              'is_food': true,
              'meal_description': '汤',
            }, corrected: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('~? 千卡'), findsOneWidget);
  });
}
