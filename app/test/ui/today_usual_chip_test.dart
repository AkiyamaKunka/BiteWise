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

/// UsualFoods whose offers arrive when the test completes [replies], one
/// per call, in order.
class _HeldUsual extends UsualFoods {
  _HeldUsual(BaseFakeDao dao, UsualChoices choices)
      : super(
          dao: dao,
          choices: choices,
          mealsChanged: ValueNotifier<int>(0),
          onMealsChanged: () {},
          lookupTakesIt: (_) => false,
        );

  final List<Completer<Map<int, UsualOffer>>> replies = [];

  @override
  Future<Map<int, UsualOffer>> offersFor(List<Meal> meals) {
    final c = Completer<Map<int, UsualOffer>>();
    replies.add(c);
    return c.future;
  }
}

/// The oatmeal offer for meal 1, as offersFor would work it out.
UsualOffer oatmealOffer() => UsualOffer(
      mealId: 1,
      items: [
        UsualOfferItem(
          index: 0,
          name: 'Oatmeal',
          key: 'oatmeal',
          learnedName: 'Oatmeal',
          viaAlias: false,
          ai: (kcal: 300, p: 10, c: 45, f: 8),
          mine: (kcal: 350, p: 12, c: 50, f: 14),
          kcalOnly: false,
          mineAt: DateTime(2026, 11, 5),
          fromMealId: 2,
          fromDate: '2026-11-05',
        ),
      ],
      beforeKcal: 300,
      afterKcal: 350,
    );

void main() {
  Future<void> pump(
    WidgetTester tester,
    FakeDao dao, {
    UsualFoods? usual,
    Locale? locale,
    DateTime Function()? now,
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
          now: now,
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

  testWidgets('an offer on the macros alone names the macros, and its '
      'snackbar does not read the same kcal twice', (tester) async {
    final dao = FakeDao()
      // The user's own oatmeal, typed by hand: the same kcal, more
      // protein.
      ..seed(foodMeal(
          id: 2,
          date: daysAgo(2),
          source: MealSource.appManual,
          items: [foodItem('Oatmeal (~250 g)', 350, p: 25, c: 40, f: 10)]))
      ..seed(photo([foodItem('Oatmeal (~260 g)', 350, p: 10, c: 50, f: 14)]));
    final usual = await makeUsualFoods(dao, clock: DateTime.now);
    await pump(tester, dao, usual: usual);
    expect(
        find.text('Oatmeal: AI P 10g · C 50g · F 14g → your usual '
            'P 25g · C 40g · F 10g'),
        findsOneWidget);
    expect(find.text('Oatmeal: AI 350 → your usual 350 kcal'), findsNothing);
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect(find.text('Used your usual numbers.'), findsOneWidget);
    expect(find.text('Used your usual numbers: 350 → 350 kcal'), findsNothing);
    final item = (dao.byId(1).analysis['food_items'] as List).single as Map;
    expect(item['protein_g'], 25, reason: 'Use wrote the macros');
    expect(item['estimated_calories'], 350);
  });

  testWidgets('a kcal change under the threshold names the macros too, and '
      'the snackbar then says the totals', (tester) async {
    final dao = FakeDao()
      ..seed(foodMeal(
          id: 2,
          date: daysAgo(2),
          source: MealSource.appManual,
          items: [foodItem('Oatmeal (~250 g)', 360, p: 25, c: 40, f: 10)]))
      ..seed(photo([foodItem('Oatmeal (~260 g)', 350, p: 10, c: 50, f: 14)]));
    final usual = await makeUsualFoods(dao, clock: DateTime.now);
    await pump(tester, dao, usual: usual);
    expect(
        find.text('Oatmeal: AI P 10g · C 50g · F 14g → your usual '
            'P 25g · C 40g · F 10g'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect(find.text('Used your usual numbers: 350 → 360 kcal'),
        findsOneWidget);
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

  testWidgets('past midnight, Use on a chip still shown drops it quietly: '
      'Today reloads, no message, nothing written', (tester) async {
    var now = DateTime(2026, 11, 7, 23, 50);
    final dao = FakeDao()
      ..seed(foodMeal(
          id: 2,
          date: '2026-11-05',
          source: MealSource.appManual,
          items: [foodItem('Oatmeal (~250 g)', 350, p: 12, c: 50, f: 14)]))
      ..seed(foodMeal(
          id: 1,
          date: '2026-11-07',
          source: MealSource.appWatch,
          items: [aiOatmeal()]));
    final usual = await makeUsualFoods(dao, clock: () => now);
    await pump(tester, dao, usual: usual, now: () => now);
    expect(find.byKey(const Key('usualChip')), findsOneWidget);
    // The app stays open past midnight; Today was not reloaded.
    now = DateTime(2026, 11, 8, 0, 5);
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect(find.text('This meal was just updated — please review.'),
        findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(const Key('usualChip')), findsNothing);
    expect(find.byKey(const Key('meal1')), findsNothing,
        reason: 'Today shows the new day');
    expect(dao.updates, isEmpty);
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

  group('a reply that comes late', () {
    Future<_HeldUsual> held() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      return _HeldUsual(FakeDao(), UsualChoices(prefs));
    }

    TodayScreenState today(WidgetTester tester) =>
        tester.state<TodayScreenState>(find.byType(TodayScreen));

    testWidgets('an older reload\'s reply never replaces a newer one',
        (tester) async {
      final dao = FakeDao()..seed(photo([aiOatmeal()]));
      final usual = await held();
      await pump(tester, dao, usual: usual);
      expect(usual.replies, hasLength(1));
      // A second reload before the first reply: the newer one answers
      // first (nothing to offer), then the older one arrives.
      final again = today(tester).reload();
      await tester.pump();
      await again;
      expect(usual.replies, hasLength(2));
      usual.replies[1].complete(const {});
      await tester.pump();
      usual.replies[0].complete({1: oatmealOffer()});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('meal1')), findsOneWidget);
      expect(find.byKey(const Key('usualChip')), findsNothing);
    });

    testWidgets('a reply that arrives after midnight is dropped',
        (tester) async {
      var now = DateTime(2026, 11, 7, 23, 50);
      final dao = FakeDao()
        ..seed(foodMeal(
            id: 1,
            date: '2026-11-07',
            source: MealSource.appWatch,
            items: [aiOatmeal()]));
      final usual = await held();
      await pump(tester, dao, usual: usual, now: () => now);
      expect(find.byKey(const Key('meal1')), findsOneWidget);
      now = DateTime(2026, 11, 8, 0, 5);
      usual.replies.single.complete({1: oatmealOffer()});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('meal1')), findsOneWidget,
          reason: 'Today was not reloaded');
      expect(find.byKey(const Key('usualChip')), findsNothing,
          reason: 'yesterday\'s meal is offered nothing');
    });

    testWidgets('a meal that became the user\'s loses its chip at the '
        'reload, before the new reply', (tester) async {
      final dao = FakeDao()..seed(photo([aiOatmeal()]));
      final usual = await held();
      await pump(tester, dao, usual: usual);
      usual.replies.single.complete({1: oatmealOffer()});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualChip')), findsOneWidget);
      // The user fixed it elsewhere (corrected); the reload's own reply
      // has not come yet.
      dao.meals[dao.meals.indexWhere((m) => m.id == 1)] = foodMeal(
          id: 1,
          date: daysAgo(0),
          source: MealSource.appWatch,
          corrected: true,
          items: [aiOatmeal()]);
      final again = today(tester).reload();
      await tester.pump();
      await again;
      await tester.pump();
      expect(usual.replies, hasLength(2));
      expect(find.byKey(const Key('meal1')), findsOneWidget);
      expect(find.byKey(const Key('usualChip')), findsNothing);
    });
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
