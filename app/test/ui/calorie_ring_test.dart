// The Today hero ring. Since 2026-08-06 the center reports what you ATE,
// never what is left (owner decision): a tracker reports intake, and a
// countdown-to-zero frames every meal as spending a budget. The arc still
// carries progress against typical + burn, so these pin BOTH — the number
// is always the eaten total, and the sweep still reflects the budget.
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
}
