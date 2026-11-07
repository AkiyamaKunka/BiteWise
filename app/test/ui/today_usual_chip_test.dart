// Today's "your usual numbers" chip (usual-foods spec §3.4-§3.5, T35):
// one food → Use, written only on that tap, with the meal totals and Undo
// on the snackbar; two or more → Review, which opens the editor's card;
// the restaurant assist's chip always wins the slot; and the list never
// waits for the offers.
import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/l10n.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/widgets/meal_card.dart';
import 'package:calorie_tracker/ui/widgets/usual_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/assist_fixtures.dart';
import 'fakes.dart';

/// Calendar days before today (computed: a pinned date is a time bomb).
String daysAgo(int n) {
  final now = DateTime.now();
  return isoDate(DateTime(now.year, now.month, now.day - n));
}

/// The user's own oatmeal and latte, typed by hand two days ago.
Meal learned() => foodMeal(
      id: 2,
      date: daysAgo(2),
      source: MealSource.appManual,
      items: [
        foodItem('Oatmeal (~250 g)', 350, p: 12, c: 50, f: 14),
        foodItem('Oat milk latte', 190, p: 4, c: 24, f: 8),
      ],
    );

/// Today's photo of [items] (the watcher saved it).
Meal photo(List<Map<String, dynamic>> items, {int id = 1}) => foodMeal(
      id: id,
      date: daysAgo(0),
      source: MealSource.appWatch,
      items: items,
    );

Map<String, dynamic> aiOatmeal() =>
    foodItem('Oatmeal (~260 g)', 300, p: 10, c: 45, f: 8);

Map<String, dynamic> aiLatte() =>
    foodItem('Oat milk latte', 150, p: 3, c: 18, f: 6);

/// UsualFoods whose offers never arrive.
class _HangingUsual extends UsualFoods {
  _HangingUsual(BaseFakeDao dao, UsualChoices choices)
      : super(
          dao: dao,
          choices: choices,
          mealsChanged: ValueNotifier<int>(0),
          onMealsChanged: () {},
          lookupTakesIt: (_) => false,
        );

  int calls = 0;

  @override
  Future<Map<int, UsualOffer>> offersFor(List<Meal> meals) {
    calls++;
    return Completer<Map<int, UsualOffer>>().future;
  }
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    FakeDao dao, {
    UsualFoods? usual,
    Locale? locale,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates:
          locale == null ? null : AppLocalizations.localizationsDelegates,
      supportedLocales: locale == null
          ? const [Locale('en', 'US')]
          : AppLocalizations.supportedLocales,
      home: Scaffold(
        body: TodayScreen(
          key: UniqueKey(),
          dao: dao,
          executor: FakeExecutor(),
          usual: usual,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  num kcalOf(Meal m, int i) =>
      (m.analysis['food_items'] as List)[i]['estimated_calories'] as num;

  testWidgets('one food: the chip names it, AI → yours, and Use writes it '
      'with the meal totals and Undo', (tester) async {
    final dao = FakeDao()
      ..seed(learned())
      ..seed(photo([aiOatmeal(), foodItem('Toast', 120)]));
    final usual = await makeUsualFoods(dao, clock: DateTime.now);
    await pump(tester, dao, usual: usual);

    final chip = find.byKey(const Key('usualChip'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(
          of: chip,
          matching: find.text('Oatmeal: AI 300 → your usual 350 kcal')),
      findsOneWidget,
    );
    expect(find.descendant(of: chip, matching: find.text('Use')),
        findsOneWidget);
    expect(find.bySemanticsLabel('Use your usual numbers for Oatmeal'),
        findsOneWidget);
    expect(find.byKey(const Key('usualChipReview')), findsNothing);
    expect(dao.byId(1).corrected, isFalse, reason: 'nothing without a tap');

    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    final m = dao.byId(1);
    expect(kcalOf(m, 0), 350);
    expect(kcalOf(m, 1), 120, reason: 'only the offered food');
    expect(m.analysis['total_calories'], 470);
    expect(m.corrected, isTrue);
    // Meal totals, as assistAppliedSnack says them.
    expect(find.text('Used your usual numbers: 420 → 470 kcal'),
        findsOneWidget);
    expect(find.byKey(const Key('usualChip')), findsNothing);
    expect(find.text('~470 kcal'), findsOneWidget, reason: 'the card reloads');

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(kcalOf(dao.byId(1), 0), 300);
    expect(dao.byId(1).analysis['total_calories'], 420);
    expect(find.text('~420 kcal'), findsOneWidget);
    // Corrected stays (as the leftover undo): never offered again.
    expect(find.byKey(const Key('usualChip')), findsNothing);
  });

  testWidgets('Use on a meal changed since the chip showed writes nothing '
      'and says so', (tester) async {
    final dao = FakeDao()
      ..seed(learned())
      ..seed(photo([aiOatmeal()]));
    final usual = await makeUsualFoods(dao, clock: DateTime.now);
    await pump(tester, dao, usual: usual);
    // The meal changes after Today showed the chip (a background save, no
    // reload yet).
    dao.meals[dao.meals.indexWhere((m) => m.id == 1)] =
        photo([foodItem('Oatmeal (~260 g)', 280, p: 10, c: 45, f: 8)]);
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect(find.text('This meal was just updated — please review.'),
        findsOneWidget);
    expect(kcalOf(dao.byId(1), 0), 280);
    expect(dao.byId(1).corrected, isFalse);
  });

  testWidgets('two foods: "for 2 items" and Review, which opens the '
      "editor's card", (tester) async {
    final dao = FakeDao()
      ..seed(learned())
      ..seed(photo([aiOatmeal(), aiLatte()]));
    final usual = await makeUsualFoods(dao, clock: DateTime.now);
    await pump(tester, dao, usual: usual);
    final chip = find.byKey(const Key('usualChip'));
    expect(
      find.descendant(
          of: chip, matching: find.text('Your usual numbers for 2 items')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('usualChipUse')), findsNothing);
    await tester.tap(find.byKey(const Key('usualChipReview')));
    await tester.pumpAndSettle();
    expect(find.byType(MealEditorScreen), findsOneWidget);
    expect(find.byKey(const Key('usualOfferCard')), findsOneWidget);
    expect(find.text('Oat milk latte: AI 150 → your usual 190 kcal'),
        findsOneWidget);
    expect(dao.byId(1).corrected, isFalse, reason: 'Review writes nothing');
  });

  testWidgets('no service, no chip', (tester) async {
    final dao = FakeDao()
      ..seed(learned())
      ..seed(photo([aiOatmeal()]));
    await pump(tester, dao);
    expect(find.byKey(const Key('meal1')), findsOneWidget);
    expect(find.byKey(const Key('usualChip')), findsNothing);
  });

  testWidgets('offers that never arrive: the list still shows', (
    tester,
  ) async {
    final dao = FakeDao()
      ..seed(learned())
      ..seed(photo([aiOatmeal()]));
    SharedPreferences.setMockInitialValues({});
    final usual = _HangingUsual(
        dao, UsualChoices(await SharedPreferences.getInstance()));
    await pump(tester, dao, usual: usual);
    expect(usual.calls, 1);
    expect(find.byKey(const Key('meal1')), findsOneWidget);
    expect(find.text('~300 kcal'), findsOneWidget);
    expect(find.byKey(const Key('usualChip')), findsNothing);
  });

  testWidgets("the restaurant assist's chip wins the slot", (tester) async {
    final offer = UsualOffer(
      mealId: 1,
      items: [
        UsualOfferItem(
          index: 0,
          name: 'Big Mac',
          key: 'big mac',
          learnedName: 'Big Mac',
          viaAlias: false,
          ai: (kcal: 540, p: 24, c: 44, f: 30),
          mine: (kcal: 600, p: 24, c: 44, f: 30),
          kcalOnly: false,
          mineAt: DateTime(2026, 10, 20),
          fromMealId: 2,
          fromDate: '2026-10-20',
        ),
      ],
      beforeKcal: 590,
      afterKcal: 650,
    );
    Future<void> card(Map<String, dynamic> analysis) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            MealCard(
              key: UniqueKey(),
              meal: assistMeal(analysis),
              usualChip: UsualChip(offer: offer, onUse: () {}),
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
    }

    await card(appliedBigMac());
    expect(find.byKey(const Key('assistChip')), findsOneWidget);
    expect(find.byKey(const Key('usualChip')), findsNothing);
    await card(bigMacAnalysis());
    expect(find.byKey(const Key('assistChip')), findsNothing);
    expect(find.byKey(const Key('usualChip')), findsOneWidget);
  });

  testWidgets('Chinese: the chip, its buttons and the snackbar read in '
      'Chinese', (tester) async {
    final dao = FakeDao()
      ..seed(learned())
      ..seed(photo([aiOatmeal()]))
      ..seed(photo([aiOatmeal(), aiLatte()], id: 3));
    final usual = await makeUsualFoods(dao, clock: DateTime.now);
    await pump(tester, dao, usual: usual, locale: const Locale('zh'));
    expect(find.text('Oatmeal：AI 300 → 你平时的 350 千卡'), findsOneWidget);
    expect(find.text('采用'), findsOneWidget);
    expect(find.text('2 项可用你平时的数值'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
    expect(find.bySemanticsLabel('「Oatmeal」采用你平时的数值'), findsOneWidget);
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect(find.text('已采用你平时的数值：300 → 350 千卡'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
  });
}
