// A meal whose analysis has no meal_description used to read 'Meal' on
// every screen, also in the Chinese UI. Screens now say the same
// nlUnnamedMeal the chat path uses (未命名的一餐 / Unnamed meal); stored
// data and the pipeline's English prose keep 'Meal'.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/format.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/widgets/meal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Meal _meal(Map<String, dynamic> analysis) => Meal(
      id: 1,
      date: '2026-10-12',
      time: '12:00 PM',
      timestamp: '2026-10-12T12:00:00.000',
      source: 'app_photo',
      analysis: analysis,
    );

Widget _host(Locale locale, Widget child) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  test('mealDescription keeps its default and takes the localized fallback',
      () {
    expect(mealDescription({'meal_description': '  '}), 'Meal');
    expect(mealDescription({}, fallback: '未命名的一餐'), '未命名的一餐');
    expect(mealDescription({'meal_description': ' Ramen '}, fallback: 'x'),
        'Ramen');
  });

  for (final (locale, unnamed) in [
    (const Locale('zh'), '未命名的一餐'),
    (const Locale('en'), 'Unnamed meal'),
  ]) {
    testWidgets('${locale.languageCode}: a meal card without a description '
        'reads $unnamed', (tester) async {
      await tester.pumpWidget(_host(
          locale,
          MealCard(
              meal: _meal({'is_food': true, 'total_calories': 300}))));
      await tester.pumpAndSettle();
      expect(find.text(unnamed), findsOneWidget);
      expect(find.text('Meal'), findsNothing);
    });
  }

  test('the saved/leftover outcome names an undescribed meal in the app '
      'language, and keeps a real name', () {
    final zh = AppLocalizationsZh(), en = AppLocalizationsEn();
    const unnamed = PhotoOutcome(PhotoOutcomeKind.saved,
        'Meal logged: Meal — ~300 kcal',
        analysis: {'is_food': true, 'total_calories': 300},
        detail: 'Meal — ~300 kcal',
        mealName: 'Meal',
        kcal: '300');
    expect(outcomeBody(zh, unnamed), contains('未命名的一餐'));
    expect(outcomeBody(en, unnamed), contains('Unnamed meal'));
    const leftover = PhotoOutcome(PhotoOutcomeKind.leftoverApplied,
        'Leftovers deducted: Meal — −100 kcal, now ~200 kcal',
        analysis: {'is_food': true, 'meal_description': '', 'total_calories': 200},
        mealName: 'Meal',
        kcal: '200',
        deductedKcal: 100);
    expect(outcomeBody(zh, leftover), contains('未命名的一餐'));
    const named = PhotoOutcome(PhotoOutcomeKind.saved,
        'Meal logged: Ramen — ~600 kcal',
        analysis: {'is_food': true, 'meal_description': 'Ramen'},
        detail: 'Ramen — ~600 kcal',
        mealName: 'Ramen',
        kcal: '600');
    expect(outcomeBody(en, named), named.message);
    expect(outcomeBody(zh, named), contains('Ramen'));
  });
}
