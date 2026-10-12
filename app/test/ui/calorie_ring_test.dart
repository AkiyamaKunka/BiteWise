// The Today hero ring. Since 2026-08-06 the center reports what you ATE,
// never what is left (owner decision): a tracker reports intake, and a
// countdown-to-zero frames every meal as spending a budget. The arc still
// carries progress against typical + burn, so these pin BOTH — the number
// is always the eaten total, and the sweep still reflects the budget.
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/widgets/calorie_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child,
      {double textScale = 1.0}) =>
      tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  textScaler: TextScaler.linear(textScale)),
              child: Scaffold(body: Center(child: child)))));

  String center(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('ringCenterValue'))).data!;

  testWidgets('under typical: center = what was EATEN', (tester) async {
    await pump(tester,
        const CalorieRing(eatenKcal: 1240, typicalKcal: 2020));
    expect(center(tester), '1,240');
    expect(find.text('kcal today'), findsOneWidget);
    expect(find.text('780'), findsNothing,
        reason: 'the remaining number must not appear anywhere');
  });

  testWidgets('burn still extends the budget (the arc), but never the '
      'center number', (tester) async {
    await pump(
        tester,
        const CalorieRing(
            eatenKcal: 1240, typicalKcal: 2020, burnKcal: 88));
    expect(center(tester), '1,240',
        reason: 'eaten is eaten — burn moves the sweep, not the hero');
    expect(find.text('kcal today'), findsOneWidget);
  });

  testWidgets('over typical: still the eaten total, no shame state',
      (tester) async {
    await pump(tester,
        const CalorieRing(eatenKcal: 3340, typicalKcal: 1760));
    expect(center(tester), '3,340');
    expect(find.text('kcal today'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing,
        reason: 'no over-budget accusation in the hero');
  });

  testWidgets('rounding: the eaten total rounds once, consistently',
      (tester) async {
    await pump(tester,
        const CalorieRing(eatenKcal: 2000.3, typicalKcal: 2000));
    expect(center(tester), '2,000');
  });

  testWidgets('no typical yet: center = eaten, labeled plainly',
      (tester) async {
    await pump(tester, const CalorieRing(eatenKcal: 345, typicalKcal: null));
    expect(center(tester), '345');
    expect(find.text('kcal today'), findsOneWidget);
  });

  testWidgets('2x font scale: no overflow, text shrinks to fit the ring',
      (tester) async {
    await pump(
        tester,
        const CalorieRing(eatenKcal: 11240, typicalKcal: 22020),
        textScale: 2.0);
    expect(tester.takeException(), isNull,
        reason: 'FittedBox must absorb the scale; clipped hero text is the '
            'a11y must-fix this pins');
    expect(center(tester), '11,240');
  });

  String ringLabel(WidgetTester tester) => tester
      .getSemantics(find.byKey(const Key('ringCenterValue')))
      .label;

  testWidgets('the spoken sentence: eaten, the typical day, and a neutral '
      'above-typical note', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const CalorieRing(eatenKcal: 1240, typicalKcal: 2020));
    expect(ringLabel(tester),
        '1,240 kcal eaten today, of a 2,020 kcal typical day');
    await pump(tester, const CalorieRing(eatenKcal: 3340, typicalKcal: 1760));
    expect(ringLabel(tester),
        '3,340 kcal eaten today, of a 1,760 kcal typical day (above typical)');
    await pump(tester, const CalorieRing(eatenKcal: 345, typicalKcal: null));
    expect(ringLabel(tester), '345 kcal eaten today');
    handle.dispose();
  });

  testWidgets('zh: the ring speaks Chinese, like its visible labels',
      (tester) async {
    // The sentence was an English literal, so a zh VoiceOver user heard
    // 'kcal eaten today' under a '千卡' ring.
    final handle = tester.ensureSemantics();
    Future<void> pumpZh(Widget ring) async {
      await tester.pumpWidget(MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Center(child: ring))));
      await tester.pumpAndSettle();
    }

    await pumpZh(const CalorieRing(eatenKcal: 1240, typicalKcal: 2020));
    expect(ringLabel(tester), contains('千卡'));
    expect(ringLabel(tester), isNot(contains('kcal')));
    await pumpZh(const CalorieRing(eatenKcal: 3340, typicalKcal: 1760));
    expect(ringLabel(tester), contains('高于日常'));
    expect(ringLabel(tester), isNot(contains('超标')),
        reason: 'no shame state, spoken or drawn');
    await pumpZh(const CalorieRing(eatenKcal: 345, typicalKcal: null));
    expect(ringLabel(tester), contains('345 千卡'));
    handle.dispose();
  });

  testWidgets('macro trio fills by CALORIE share (Atwater), matching the '
      'detail chart', (tester) async {
    await pump(
        tester,
        const MacroTrio(
            proteinG: 50,
            carbsG: 100,
            fatG: 0,
            proteinColor: Colors.blue,
            carbsColor: Colors.orange,
            fatColor: Colors.green));
    expect(find.byKey(const Key('macroTrio')), findsOneWidget);
    expect(find.text('P 50g'), findsOneWidget);
    expect(find.text('C 100g'), findsOneWidget);
    expect(find.text('F 0g'), findsOneWidget);
  });

  testWidgets('macro trio labels follow the app language (zh 蛋/碳/脂, as '
      'the meal-card chips below it)', (tester) async {
    // The bars said a literal 'P'/'C'/'F' in every language, so the zh
    // Today screen read 'P 120g' in the hero and '蛋' on the cards.
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
            body: Center(
                child: MacroTrio(
                    proteinG: 50,
                    carbsG: 100,
                    fatG: 0,
                    proteinColor: Colors.blue,
                    carbsColor: Colors.orange,
                    fatColor: Colors.green)))));
    await tester.pumpAndSettle();
    expect(find.text('蛋 50g'), findsOneWidget);
    expect(find.text('碳 100g'), findsOneWidget);
    expect(find.text('脂 0g'), findsOneWidget);
    expect(find.text('P 50g'), findsNothing);
  });
}
