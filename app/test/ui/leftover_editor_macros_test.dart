/// RC 1.6.0: the meal editor after a leftover photo.
///
/// applyLeftover (core/leftover_logic.dart) scaled every item's kcal and
/// the meal's four totals, but left the items' protein / carbs / fat as
/// they were. The editor derives all four totals from the item rows the
/// moment any item number changes (_recomputeTotalsFromItems), so fixing
/// one item's kcal on a half-eaten meal wrote the WHOLE plate's macros
/// back: protein, carbs and fat doubled, on the meal and on Today. The
/// same for Add item and for a removed row. Meals 1.5.0 stored that way
/// (rows unscaled, a block without the new stamp) are scaled when the
/// editor loads them.
library;

import 'dart:convert';

import 'package:calorie_tracker/core/leftover_logic.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../e2e/harness.dart';

/// A photo of fried rice 600 kcal (P20 C80 F20) and orange chicken 400 kcal
/// (P20 C40 F20); the leftover reply [reply] is written the way the manual
/// flow writes it (applyLeftover on the stored meal, compare-and-set). The
/// meal's id.
Future<int> _halvedMeal(Phone phone, WidgetTester tester,
    Map<String, dynamic> reply) async {
  final id = await phone.photo(aiSays([
    foodItem('Fried rice', 600, p: 20, c: 80, f: 20),
    foodItem('Orange chicken', 400, p: 20, c: 40, f: 20),
  ], description: 'Fried rice and orange chicken'));
  await tester.pumpAndSettle();
  final snap = (await phone.dao.mealSnapshot(id))!;
  final result = applyLeftover(snap.meal.analysis, reply,
      leftoverPhotoMd5: 'a' * 32, appliedAtIso: phone.now.toIso8601String())!;
  expect(
      await phone.dao.updateMealAnalysisIfUnchanged(id,
          expectedRaw: snap.rawAnalysis, analysis: result.adjusted),
      isTrue);
  return id;
}

const _half = {'leftover_fraction': 0.5, 'same_meal': true, 'confidence': 0.9};

List<Object?> _macros(Map<String, dynamic> a) =>
    [a['total_protein_g'], a['total_carbs_g'], a['total_fat_g']];

Future<void> _open(WidgetTester tester, Phone phone, int id) async {
  final meal = (await phone.dao.mealSnapshot(id))!.meal;
  await pushFromLog(
      tester, MealEditorScreen(dao: phone.dao, meal: meal, now: phone.clock));
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('saveMealButton')));
  await tester.pumpAndSettle();
  expect(find.byType(MealEditorScreen), findsNothing);
}

String _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

void main() {
  useInProcessSqlite();

  testWidgets('a meal halved by a leftover photo: changing one item\'s kcal '
      'in the editor keeps the halved macros', (tester) async {
    final phone = await Phone.boot(DateTime(2026, 11, 10, 12, 0));
    addTearDown(phone.shutDown);
    await pumpApp(tester, phone);
    final id = await _halvedMeal(phone, tester, _half);
    var a = await phone.analysis(id);
    expect(a['total_calories'], 500);
    expect(_macros(a), [20, 60, 20]);

    await _open(tester, phone, id);
    expect(_field(tester, 'itemCal0'), '300');
    expect(_field(tester, 'itemPro0'), '10',
        reason: 'the row shows the eaten part, as its kcal does');
    await tester.enterText(find.byKey(const Key('itemCal0')), '310');
    await tester.pumpAndSettle();
    await _save(tester);

    a = await phone.analysis(id);
    expect(a['total_calories'], 510);
    expect(_macros(a), [20, 60, 20],
        reason: 'one kcal fix must not put the uneaten half\'s macros back');
  });

  testWidgets('Add item alone, or a removed row, keeps the eaten macros',
      (tester) async {
    final phone = await Phone.boot(DateTime(2026, 11, 10, 12, 0));
    addTearDown(phone.shutDown);
    await pumpApp(tester, phone);
    final id = await _halvedMeal(phone, tester, _half);

    await _open(tester, phone, id);
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pumpAndSettle();
    expect([_field(tester, 'editorProtein'), _field(tester, 'editorCarbs')],
        ['20', '60']);
    await _save(tester);
    expect(_macros(await phone.analysis(id)), [20, 60, 20]);

    await _open(tester, phone, id);
    await tester.tap(find.byKey(const Key('removeItem1')));
    await tester.pumpAndSettle();
    await _save(tester);
    final a = await phone.analysis(id);
    expect(a['total_calories'], 300);
    expect(_macros(a), [10, 40, 10],
        reason: 'the half of the rice that was eaten, nothing more');
  });

  testWidgets('per-item fractions: the totals agree with the rows, so an '
      'edit moves nothing it did not touch', (tester) async {
    final phone = await Phone.boot(DateTime(2026, 11, 10, 12, 0));
    addTearDown(phone.shutDown);
    await pumpApp(tester, phone);
    // All the rice is left, the chicken is eaten.
    final id = await _halvedMeal(phone, tester, {
      'same_meal': true,
      'confidence': 0.9,
      'items': [
        {'name': 'Fried rice', 'left_fraction': 1.0},
        {'name': 'Orange chicken', 'left_fraction': 0.0},
      ],
    });
    var a = await phone.analysis(id);
    expect(a['total_calories'], 400);
    expect(_macros(a), [20, 40, 20],
        reason: 'the macros of the chicken, not 40% of the plate\'s');

    await _open(tester, phone, id);
    await tester.enterText(find.byKey(const Key('itemCal1')), '410');
    await tester.pumpAndSettle();
    await _save(tester);
    a = await phone.analysis(id);
    expect(a['total_calories'], 410);
    expect(_macros(a), [20, 40, 20]);
  });

  testWidgets('a leftover meal 1.5.0 stored (rows kept the whole plate\'s '
      'macros): the editor shows and saves the eaten part, once',
      (tester) async {
    final phone = await Phone.boot(DateTime(2026, 11, 10, 12, 0));
    addTearDown(phone.shutDown);
    await pumpApp(tester, phone);
    final id = await _halvedMeal(phone, tester, _half);
    // Rewrite the meal as 1.5.0 stored it: whole-plate row macros, and a
    // leftover block with no stamp.
    final legacy = await phone.analysis(id);
    final items = [
      for (final (i, it) in (legacy['food_items'] as List).indexed)
        {
          ...(it as Map).cast<String, dynamic>(),
          'protein_g': 20,
          'carbs_g': [80, 40][i],
          'fat_g': 20,
        },
    ];
    legacy['food_items'] = items;
    (legacy['leftover'] as Map).remove(kLeftoverItemMacrosScaled);
    await phone.db.update('meals', {'analysis': jsonEncode(legacy)},
        where: 'id = ?', whereArgs: [id]);

    // A date-only save: the rows are untouched.
    await _open(tester, phone, id);
    expect(_field(tester, 'itemPro0'), '10');
    expect(_field(tester, 'itemCarb0'), '40');
    await _save(tester);
    var a = await phone.analysis(id);
    expect(_macros(a), [20, 60, 20]);
    expect((a['food_items'] as List)[0]['carbs_g'], 40,
        reason: 'the eaten part is stored on the row now');
    expect((a['leftover'] as Map)[kLeftoverItemMacrosScaled], isTrue);

    // Opened again: not halved a second time.
    await _open(tester, phone, id);
    expect(_field(tester, 'itemCarb0'), '40');
    await tester.enterText(find.byKey(const Key('itemCal0')), '310');
    await tester.pumpAndSettle();
    await _save(tester);
    a = await phone.analysis(id);
    expect(a['total_calories'], 510);
    expect(_macros(a), [20, 60, 20]);
    expect((a['food_items'] as List)[0]['user'], isNotNull,
        reason: 'the kcal the user typed is theirs');
    expect(((a['food_items'] as List)[1] as Map).containsKey('user'), isFalse,
        reason: 'an untouched row sets no number of the user\'s');
  });
}
