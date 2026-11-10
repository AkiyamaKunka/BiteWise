// Log › My usual foods (usual-foods spec §4, T42): the rows and their
// lines, one tap logs once with Undo, "Log it again?" only when a similar
// meal was logged in the last 3 h, hiding with Undo and Show again, the
// four screen states, and no AI anywhere on the way.
import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/l10n.dart';
import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:calorie_tracker/ui/widgets/usual_offer_card.dart'
    show kUsualUndoSnackDuration;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Saturday 2026-11-07, 12:30 PM.
DateTime clock() => DateTime(2026, 11, 7, 12, 30);

/// A save waits for [gate] while it is set.
class _GatedDao extends FakeDao {
  Completer<void>? gate;

  @override
  Future<MealSaveResult> saveMealWithOutcome(Meal meal,
      {IngestionStatus? markStatus, String? ownerStamp}) async {
    final g = gate;
    if (g != null) await g.future;
    return super.saveMealWithOutcome(meal,
        markStatus: markStatus, ownerStamp: ownerStamp);
  }
}

/// Oatmeal on two mornings (More), a chicken salad on two lunches and
/// again today at 11:50 AM (Around this time).
FakeDao usualDao() {
  final dao = _GatedDao();
  var id = 10;
  void meal(String date, String time, String desc, Map<String, dynamic> it) =>
      dao.seed(foodMeal(
          id: id++, date: date, time: time, description: desc, items: [it]));
  Map<String, dynamic> oatmeal() =>
      foodItem('Oatmeal with blueberries (~300 g)', 320, p: 10, c: 55, f: 6);
  Map<String, dynamic> salad() =>
      foodItem('Chicken salad', 450, p: 40, c: 12, f: 22);
  meal('2026-11-03', '07:40 AM', 'Oatmeal with blueberries', oatmeal());
  meal('2026-11-05', '07:45 AM', 'Oatmeal with blueberries', oatmeal());
  meal('2026-11-04', '12:15 PM', 'Chicken salad', salad());
  meal('2026-11-06', '12:40 PM', 'Chicken salad', salad());
  meal('2026-11-07', '11:50 AM', 'Chicken salad', salad());
  return dao;
}

/// frequentMeals answered by [list] (a Completer that never completes, a
/// throw) instead of the index.
class _ScriptedUsual extends UsualFoods {
  _ScriptedUsual(BaseFakeDao dao, UsualChoices choices, this.list)
      : super(
          dao: dao,
          choices: choices,
          mealsChanged: ValueNotifier<int>(0),
          onMealsChanged: () {},
          lookupTakesIt: (_) => false,
          clock: clock,
        );

  Future<UsualList> Function() list;
  int listCalls = 0;

  @override
  Future<UsualList> frequentMeals() {
    listCalls++;
    return list();
  }
}

void main() {
  Future<void> pump(WidgetTester tester, UsualFoods usual) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: UsualFoodsScreen(key: UniqueKey(), usual: usual, now: clock),
    ));
    await tester.pumpAndSettle();
  }

  /// [day] as the screen's own context.friendlyDay writes it.
  String friendly(WidgetTester tester, String day) => tester
      .element(find.byType(UsualFoodsScreen))
      .friendlyDay(day, now: clock());

  Finder row(String title) => find.ancestor(
      of: find.text(title), matching: find.byType(InkWell)).first;

  List<Meal> relogs(FakeDao dao) =>
      [for (final m in dao.meals) if (m.source == MealSource.appRepeat) m];

  testWidgets('rows: the title, the numbers a log writes, how often and '
      'when; Around this time first; logged today says so', (tester) async {
    final dao = usualDao();
    await pump(tester, await makeUsualFoods(dao, clock: clock));
    expect(find.text('My usual foods'), findsOneWidget);
    expect(find.text('Around this time'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Chicken salad')).dy,
      lessThan(tester.getTopLeft(find.text('Oatmeal with blueberries')).dy),
    );
    expect(find.text('450 kcal · P: 40g · C: 12g · F: 22g'), findsOneWidget);
    expect(find.text('Logged today at 11:50 AM'), findsOneWidget);
    expect(find.text('320 kcal · P: 10g · C: 55g · F: 6g'), findsOneWidget);
    expect(
      find.text('2 of the last 90 days · last logged '
          '${friendly(tester, '2026-11-05')}'),
      findsOneWidget,
    );
    expect(friendly(tester, '2026-11-05'), 'Thursday, Nov 05');
    expect(
      find.text('Tap a food to log it now with these numbers. No photo, no '
          'AI.'),
      findsOneWidget,
    );
    expect(find.byTooltip('More actions'), findsNWidgets(2));
    expect(find.byKey(const Key('usualHiddenRow')), findsNothing);
  });

  testWidgets('the list is worked out fresh on every open: a meal the '
      'background run saved (no signal) shows', (tester) async {
    final dao = usualDao();
    final usual = await makeUsualFoods(dao, clock: clock);
    // The list was read once (an earlier open) ...
    final first = await usual.frequentMeals();
    expect([...first.around, ...first.more].map((m) => m.title),
        isNot(contains('Greek yogurt')));
    // ... then the background run saved two yogurts, bumping no signal.
    dao
      ..seed(foodMeal(
          id: 40,
          date: '2026-11-04',
          time: '03:10 PM',
          description: 'Greek yogurt',
          items: [foodItem('Greek yogurt', 150, p: 15, c: 8, f: 5)]))
      ..seed(foodMeal(
          id: 41,
          date: '2026-11-06',
          time: '03:20 PM',
          description: 'Greek yogurt',
          items: [foodItem('Greek yogurt', 150, p: 15, c: 8, f: 5)]));
    await pump(tester, usual);
    expect(find.text('Greek yogurt'), findsOneWidget);
  });

  testWidgets('one tap logs the meal now, once, with Undo', (tester) async {
    final dao = usualDao();
    await pump(tester, await makeUsualFoods(dao, clock: clock));
    final before = dao.meals.length;
    // A double tap: the second lands while the first is saving.
    final gate = (dao as _GatedDao).gate = Completer<void>();
    await tester.tap(row('Oatmeal with blueberries'));
    await tester.tap(row('Oatmeal with blueberries'), warnIfMissed: false);
    await tester.pump();
    gate.complete();
    dao.gate = null;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualAgainDialog')), findsNothing,
        reason: 'no oatmeal in the last 3 h');
    final logged = relogs(dao);
    expect(logged, hasLength(1));
    expect(dao.meals, hasLength(before + 1));
    final m = logged.single;
    expect(m.date, '2026-11-07');
    expect(m.time, '12:30 PM');
    expect(m.imageHash, '');
    expect(m.fileId, '');
    expect(m.corrected, isFalse);
    expect(m.analysis['total_calories'], 320);
    expect(find.text('Logged Oatmeal with blueberries · 320 kcal'),
        findsOneWidget);
    expect(find.byKey(const Key('usualLoggedCheck')), findsOneWidget);
    expect(find.byType(UsualFoodsScreen), findsOneWidget,
        reason: 'the screen stays open');
    // A screen reader hears the check too.
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
        tester.widget<Icon>(find.byKey(const Key('usualLoggedCheck')))
            .semanticLabel,
        'Logged');
    expect(
        tester.getSemantics(find.byKey(const Key('usualLoggedCheck'))).label,
        contains('Logged'));
    semantics.dispose();
    // A tap once that one is in: it asks first.
    await tester.tap(row('Oatmeal with blueberries'));
    await tester.pumpAndSettle();
    expect(find.text('You logged Oatmeal with blueberries at 12:30 PM.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(relogs(dao), hasLength(1));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(relogs(dao), isEmpty);
    expect(dao.meals, hasLength(before));
    expect(find.byKey(const Key('usualLoggedCheck')), findsNothing);
  });

  testWidgets('the newest result is the snackbar on screen, with its own '
      'Undo, and it leaves by itself', (tester) async {
    final dao = usualDao();
    await pump(tester, await makeUsualFoods(dao, clock: clock));
    Future<void> hideSalad() async {
      await tester.tap(find.descendant(
          of: row('Chicken salad'),
          matching: find.byTooltip('More actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide from this list'));
      await tester.pumpAndSettle();
    }

    await tester.tap(row('Oatmeal with blueberries'));
    await tester.pumpAndSettle();
    const logged = 'Logged Oatmeal with blueberries · 320 kcal';
    expect(find.text(logged), findsOneWidget);
    // A second action while that snackbar is still up: its own snackbar
    // shows now. Queued behind the first (which never timed out), it was
    // never seen, and the Undo on screen undid the older action.
    await hideSalad();
    expect(find.text('Hidden from My usual foods.'), findsOneWidget);
    expect(find.text(logged), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Chicken salad'), findsOneWidget,
        reason: 'Undo is the hide\'s');
    expect(relogs(dao), hasLength(1), reason: 'the logged meal stays');

    // Left alone, a snackbar with Undo goes after a few seconds.
    await hideSalad();
    expect(find.byKey(const Key('usualHiddenSnack')), findsOneWidget);
    await tester.pump(kUsualUndoSnackDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualHiddenSnack')), findsNothing);
    expect(find.text('Chicken salad'), findsNothing, reason: 'still hidden');
  });

  testWidgets('with a screen reader on, a snackbar with Undo waits for the '
      'user: the logged one and the hidden one', (tester) async {
    // VoiceOver / TalkBack: reaching Undo takes longer than a few seconds.
    // The framework no longer holds an action snackbar there by itself, so
    // a flat `persist: false` took Undo away after the duration.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final dao = usualDao();
    await pump(tester, await makeUsualFoods(dao, clock: clock));

    await tester.tap(row('Oatmeal with blueberries'));
    await tester.pumpAndSettle();
    await tester.pump(kUsualUndoSnackDuration * 3);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualLoggedSnack')), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(relogs(dao), isEmpty, reason: 'Undo still undoes the log');
    expect(find.byKey(const Key('usualLoggedSnack')), findsNothing);

    await tester.tap(find.descendant(
        of: row('Chicken salad'), matching: find.byTooltip('More actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide from this list'));
    await tester.pumpAndSettle();
    await tester.pump(kUsualUndoSnackDuration * 3);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualHiddenSnack')), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Chicken salad'), findsOneWidget,
        reason: 'Undo still undoes the hide');
    expect(find.byKey(const Key('usualHiddenSnack')), findsNothing);
  });

  testWidgets('"Log it again?" only when a similar meal was logged in the '
      'last 3 h; Cancel logs nothing', (tester) async {
    final dao = usualDao();
    await pump(tester, await makeUsualFoods(dao, clock: clock));
    await tester.tap(row('Chicken salad'));
    await tester.pumpAndSettle();
    expect(find.text('Log it again?'), findsOneWidget);
    expect(find.text('You logged Chicken salad at 11:50 AM.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(relogs(dao), isEmpty);

    await tester.tap(row('Chicken salad'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log again'));
    await tester.pumpAndSettle();
    expect(relogs(dao), hasLength(1));
    expect(find.text('Logged Chicken salad · 450 kcal'), findsOneWidget);
  });

  testWidgets('the "Log it again?" check reads the meals at the tap: a '
      'photo saved after the screen opened is found', (tester) async {
    final dao = usualDao();
    await pump(tester, await makeUsualFoods(dao, clock: clock));
    // The watcher saves an oatmeal photo while the list is open (no
    // signal).
    dao.seed(foodMeal(
      id: 99,
      date: '2026-11-07',
      time: '11:15 AM',
      description: 'Blueberry oatmeal',
      items: [foodItem('Blueberry oatmeal', 300)],
    ));
    await tester.tap(row('Oatmeal with blueberries'));
    await tester.pumpAndSettle();
    expect(find.text('You logged Blueberry oatmeal at 11:15 AM.'),
        findsOneWidget);
  });

  testWidgets('Hide from this list, with Undo; Hidden foods (1) shows it '
      'again', (tester) async {
    final dao = usualDao();
    await pump(tester, await makeUsualFoods(dao, clock: clock));
    Future<void> hideOatmeal() async {
      await tester.tap(find.descendant(
          of: row('Oatmeal with blueberries'),
          matching: find.byTooltip('More actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide from this list'));
      await tester.pumpAndSettle();
    }

    await hideOatmeal();
    expect(find.text('Oatmeal with blueberries'), findsNothing);
    expect(find.text('Hidden from My usual foods.'), findsOneWidget);
    expect(find.text('Hidden foods (1)'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Oatmeal with blueberries'), findsOneWidget);
    expect(find.byKey(const Key('usualHiddenRow')), findsNothing);

    await hideOatmeal();
    ScaffoldMessenger.of(tester.element(find.byType(UsualFoodsScreen)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden foods (1)'));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const Key('usualHiddenSheet'));
    expect(
        find.descendant(
            of: sheet, matching: find.text('Oatmeal with blueberries')),
        findsOneWidget);
    await tester.tap(find.text('Show again'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing, reason: 'the last one shown again');
    expect(find.text('Oatmeal with blueberries'), findsOneWidget);
    expect(find.byKey(const Key('usualHiddenRow')), findsNothing);
  });

  testWidgets('the four states: loading, failed with Retry, empty, all '
      'hidden', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final choices = UsualChoices(await SharedPreferences.getInstance());

    // Loading.
    final waiting = Completer<UsualList>();
    final usual = _ScriptedUsual(FakeDao(), choices, () => waiting.future);
    await tester.pumpWidget(
        MaterialApp(home: UsualFoodsScreen(key: UniqueKey(), usual: usual)));
    await tester.pump();
    expect(find.byKey(const Key('usualLoading')), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);

    // Failed, then Retry.
    usual.list = () async => throw StateError('db');
    await tester.pumpWidget(
        MaterialApp(home: UsualFoodsScreen(key: UniqueKey(), usual: usual)));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load your usual foods."), findsOneWidget);
    usual.list = () async => UsualList.empty;
    final calls = usual.listCalls;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(usual.listCalls, calls + 1);
    expect(find.text("Couldn't load your usual foods."), findsNothing);

    // Empty, nothing hidden.
    expect(
      find.text('Foods you log on at least 2 of the last 90 days show up '
          'here. Keep logging as usual.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('usualHiddenRow')), findsNothing);

    // Everything hidden.
    final dao = usualDao();
    final real = await makeUsualFoods(dao, clock: clock);
    final list = await real.frequentMeals();
    for (final m in [...list.around, ...list.more]) {
      await real.hide(m);
    }
    await pump(tester, real);
    expect(find.text('All your usual foods are hidden.'), findsOneWidget);
    expect(find.text('Hidden foods (2)'), findsOneWidget);
    expect(find.text('Around this time'), findsNothing);
  });

  testWidgets('from the Log sheet: no AI consent is asked, and neither the '
      'analyzer nor the text model is called', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = usualDao();
    // Never asked for any recipient: a send would need the dialog.
    final settings = FakeSettings()..aiConsent = {};
    final analyzer = FakeAnalyzer();
    var analyzed = 0;
    analyzer.onAnalyze = () async => analyzed++;
    final executor = FakeExecutor();
    await tester.pumpWidget(CalorieTrackerApp(
      services: makeServices(
        dao: dao,
        settings: settings,
        analyzer: analyzer,
        executor: executor,
        usualFoods: await makeUsualFoods(dao, clock: clock),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addMealFab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addUsual')));
    await tester.pumpAndSettle();
    expect(find.byType(UsualFoodsScreen), findsOneWidget);
    await tester.tap(row('Oatmeal with blueberries'));
    await tester.pumpAndSettle();
    expect(relogs(dao), hasLength(1));
    expect(find.byKey(const Key('aiConsentDialog')), findsNothing);
    expect(settings.aiConsentWrites, isEmpty);
    expect(analyzed, 0);
    expect(analyzer.lastRecentMeals, isNull);
    expect(executor.handledTexts, isEmpty);
    expect(executor.describedTexts, isEmpty);
  });
}
