// The meals a screen is working on (design R6a, MealInUseRegistry): the
// restaurant assist (R6b) skips a meal while its editor is open, while a
// leftover flow has it selected, and while a fix-meal request is pending.
// These pin the registry's counting and every hold — including that the
// app shell really hands the registry to the screens that open the editor
// (an unwired screen would hold nothing, silently).
import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/meal_in_use.dart';
import 'package:calorie_tracker/ui/screens/fix_meal_screen.dart';
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Meal _meal(int id, String desc, {String? date}) => Meal(
      id: id,
      date: date ?? isoDate(DateTime.now()),
      time: '12:30 PM',
      timestamp: DateTime.now().toIso8601String(),
      source: 'app_watch',
      imageHash: 'h$id',
      analysis: {
        'is_food': true,
        'meal_description': desc,
        'total_calories': 500,
      },
    );

/// handleText waits for [gate]: a fix request that is still pending.
class _GatedExecutor extends FakeExecutor {
  final Completer<void> gate = Completer<void>();

  @override
  Future<List<NlReply>> handleText(String userText) async {
    handledTexts.add(userText);
    await gate.future;
    return const [NlReply('ok')];
  }
}

void main() {
  group('MealInUseRegistry', () {
    test('a hold claims its meal until released', () {
      final r = MealInUseRegistry();
      expect(r.isInUse(1), isFalse);
      final h = r.acquire(1);
      expect(r.isInUse(1), isTrue);
      expect(r.isInUse(2), isFalse);
      r.release(h);
      expect(r.isInUse(1), isFalse);
      expect(h.released, isTrue);
    });

    test('holds are counted: both holders must let go', () {
      final r = MealInUseRegistry();
      final a = r.acquire(7);
      final b = r.acquire(7);
      a.release();
      expect(r.isInUse(7), isTrue, reason: 'b still holds it');
      b.release();
      expect(r.isInUse(7), isFalse);
    });

    test('releasing twice is harmless and never frees another hold', () {
      final r = MealInUseRegistry();
      final a = r.acquire(3);
      final b = r.acquire(3);
      r.release(a);
      r.release(a); // a screen's dispose after an explicit release
      a.release();
      expect(r.isInUse(3), isTrue, reason: "b's hold survives a's repeats");
      b.release();
      expect(r.isInUse(3), isFalse);
    });

    test('acquireAll claims every meal; a foreign hold is ignored', () {
      final r = MealInUseRegistry();
      final other = MealInUseRegistry();
      final all = r.acquireAll();
      expect(r.isInUse(1), isTrue);
      expect(r.isInUse(999), isTrue);
      final foreign = other.acquire(1);
      r.release(foreign);
      expect(foreign.released, isFalse);
      expect(other.isInUse(1), isTrue);
      all.release();
      expect(r.isInUse(1), isFalse);
      expect(r.isInUse(999), isFalse);
    });
  });

  group('holds', () {
    testWidgets('the editor holds its meal while open, and lets go on close',
        (tester) async {
      final registry = MealInUseRegistry();
      final dao = FakeDao()..seed(_meal(1, 'Soup'));
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => MealEditorScreen(
                    dao: dao, meal: dao.meals.first, inUse: registry))),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isFalse);
    });

    testWidgets('a NEW meal in the editor holds nothing', (tester) async {
      final registry = MealInUseRegistry();
      await tester.pumpWidget(MaterialApp(
          home: MealEditorScreen(dao: FakeDao(), inUse: registry)));
      await tester.pumpAndSettle();
      expect(registry.isInUse(0), isFalse);
    });

    testWidgets('the app shell wires Today and History → day → editor',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final registry = MealInUseRegistry();
      final dao = FakeDao()..seed(_meal(1, 'Soymilk'));
      await tester.pumpWidget(CalorieTrackerApp(
          services: makeServices(dao: dao, mealInUse: registry)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Soymilk'));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsOneWidget);
      expect(registry.isInUse(1), isTrue, reason: 'Today → editor');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isFalse);

      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('History')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('historyDay${isoDate(DateTime.now())}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mealRow1')));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsOneWidget);
      expect(registry.isInUse(1), isTrue, reason: 'History → day → editor');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isFalse);
    });

    testWidgets('a leftover selection holds its meal; Change and leaving '
        'let go', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final registry = MealInUseRegistry();
      final dao = FakeDao()
        ..seed(_meal(1, 'Tray'))
        ..seed(_meal(2, 'Noodles'));
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LeftoverScreen(
                    services:
                        makeServices(dao: dao, mealInUse: registry)))),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isFalse, reason: 'nothing picked yet');

      await tester.tap(find.byKey(const Key('leftoverMeal-1')));
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isTrue);

      await tester.tap(find.byKey(const Key('leftoverChangeMeal')));
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isFalse);

      await tester.tap(find.byKey(const Key('leftoverMeal-2')));
      await tester.pumpAndSettle();
      expect(registry.isInUse(2), isTrue);
      expect(registry.isInUse(1), isFalse);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(registry.isInUse(2), isFalse);
    });

    testWidgets('a pending fix-meal request holds every meal until it lands',
        (tester) async {
      final registry = MealInUseRegistry();
      final executor = _GatedExecutor();
      await tester.pumpWidget(MaterialApp(
          home: FixMealScreen(executor: executor, inUse: registry)));
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'the soup was 300');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pump();
      expect(executor.handledTexts, ['the soup was 300']);
      expect(registry.isInUse(1), isTrue);
      expect(registry.isInUse(42), isTrue,
          reason: 'the model picks the meal: every meal waits');

      executor.gate.complete();
      await tester.pumpAndSettle();
      expect(registry.isInUse(1), isFalse);
      expect(registry.isInUse(42), isFalse);
    });
  });
}
