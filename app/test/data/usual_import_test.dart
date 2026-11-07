// Two re-logs in the same minute survive export and import (usual-foods
// spec §4.4, T40). A photoless meal's import identity is date + time +
// analysis text (meals_dao_impl.dart _importRowExists), and a re-log
// copies the same numbers into the same hh:mm: without the per-log
// `logged_again` stamp the second latte of a minute would be dropped as
// "already here" when the owner moves to a new phone.
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database dbA;
  late Database dbB;
  late Database dbC;
  late DateTime clock;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_usual_import');
    dbA = await openAppDatabase(path: '${tmp.path}/a.db');
    dbB = await openAppDatabase(path: '${tmp.path}/b.db');
    dbC = await openAppDatabase(path: '${tmp.path}/c.db');
    clock = DateTime(2026, 11, 7, 15, 10, 4, 321);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await dbC.close();
    await tmp.delete(recursive: true);
  });

  test('two re-logs in the same minute come back as two meals', () async {
    final daoA = SqfliteMealsDao(dbA, clock: () => clock);
    final signal = ValueNotifier<int>(0);
    final usual = UsualFoods(
      dao: daoA,
      choices: UsualChoices(await SharedPreferences.getInstance()),
      mealsChanged: signal,
      onMealsChanged: () => signal.value++,
      lookupTakesIt: (_) => false,
      clock: () => clock,
    );
    for (final date in ['2026-11-05', '2026-11-06']) {
      await daoA.saveMeal(Meal(
        id: 0,
        date: date,
        time: '03:10 PM',
        timestamp: '${date}T15:10:00.000',
        source: MealSource.appManual,
        analysis: {
          'is_food': true,
          'meal_description': 'Oat milk latte',
          'total_calories': 190,
          'food_items': [
            {
              'name': 'Oat milk latte',
              'estimated_calories': 190,
              'protein_g': 6,
              'carbs_g': 24,
              'fat_g': 7,
            },
          ],
        },
      ));
    }
    final list = await usual.frequentMeals();
    final latte = list.around.single; // 3:10 PM, logged at 3:10 PM
    final first = (await usual.logAgain(latte))!;
    clock = DateTime(2026, 11, 7, 15, 10, 41, 7); // the same hh:mm
    final second = (await usual.logAgain(latte))!;
    final a = (await daoA.mealSnapshot(first.mealId))!;
    final b = (await daoA.mealSnapshot(second.mealId))!;
    expect((a.meal.date, a.meal.time), (b.meal.date, b.meal.time));
    expect(a.rawAnalysis, isNot(b.rawAnalysis));

    final export = await daoA.exportJson();
    final summary =
        await SqfliteMealsDao(dbB, clock: () => clock).importJson(export);
    expect(summary.added['meals'], 4);
    final moved = await SqfliteMealsDao(dbB).mealsBetween(
        '2026-11-01', '2026-11-30');
    expect(moved.where((m) => m.source == MealSource.appRepeat), hasLength(2));

    // The stamp is what keeps them apart: the same export without it
    // imports one re-log, not two.
    final envelope = jsonDecode(export) as Map<String, dynamic>;
    final rows = (envelope['tables'] as Map)['meals'] as List;
    for (final row in rows.cast<Map>()) {
      final analysis = jsonDecode(row['analysis'] as String) as Map;
      analysis.remove('logged_again');
      row['analysis'] = jsonEncode(analysis);
    }
    final stripped =
        await SqfliteMealsDao(dbC).importJson(jsonEncode(envelope));
    expect(stripped.added['meals'], 3);
    expect(stripped.skipped['meals'], 1);
  });
}
