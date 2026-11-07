// The usual-foods index over real SQLite (usual-foods spec §5, T46).
//
// A MEASUREMENT, not a speed guard: it times UsualFoods.index() — the
// 90-day read (mealsBetween decodes every analysis on the calling
// isolate) plus buildUsualIndex — over 400 realistic meals on
// sqflite_common_ffi, and prints it for the PR. A desktop VM under-reads
// phone cost, and a loaded machine over-reads it (one run took 76 s for
// the cold read at load average 73), so nothing here asserts a time:
// the assertions are about size. The spec moves the decode into
// compute() above 50 ms on a phone.
//
// The GUARD is the single flight: three concurrent callers read the
// meals table once per (day, meals signal, epoch).
import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart'
    show buildUsualIndex, usualWindowStart;
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CountingDao extends SqfliteMealsDao {
  _CountingDao(super.db, {super.clock});
  int betweenCalls = 0;

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) {
    betweenCalls++;
    return super.mealsBetween(startDate, endDate);
  }
}

const List<String> _foods = [
  'Oatmeal with blueberries (~300 g)',
  'Oat milk latte (~350 ml)',
  'Scrambled eggs (2 pcs)',
  'Whole wheat toast',
  'Chicken Caesar salad',
  'Turkey sandwich',
  'Beef pho',
  'Greek yogurt with honey',
  'Banana',
  'Salmon with rice (~400 g)',
  '番茄炒蛋',
  '米饭（约200克）',
  '牛肉面',
  '小笼包（6个）',
  'Apple',
  'Protein bar',
  'Pad thai',
  'Burrito bowl',
  'Iced americano',
  'Dark chocolate (20 g)',
];

/// Meal [i] of 400, spread over the last 90 days: 1-4 items each, a
/// quarter of them corrected with the user's marks, the rest as the
/// watcher saved them, with the context fields a photo carries.
Meal _meal(int i, DateTime now) {
  final day = DateTime(now.year, now.month, now.day - (i * 89 ~/ 399));
  final date =
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  final hour = 7 + (i * 5) % 14;
  final time =
      '${(hour % 12 == 0 ? 12 : hour % 12).toString().padLeft(2, '0')}:${(i * 7 % 60).toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
  final marked = i % 4 == 0;
  final items = [
    for (var k = 0; k < 1 + i % 4; k++)
      () {
        final kcal = 120 + (i * 37 + k * 53) % 600;
        final n = [kcal, 5 + k * 3, 20 + k * 7, 4 + k * 2];
        return {
          'name': _foods[(i + k * 3) % _foods.length],
          'estimated_calories': n[0],
          'protein_g': n[1],
          'carbs_g': n[2],
          'fat_g': n[3],
          if (k == 0) 'qty': 1,
          if (k == 1) 'unit': 'bowl',
          if (marked)
            'user': {
              'set': true,
              'at': '${date}T15:00:00.000Z',
              'n': n,
              'qty': 1,
            },
        };
      }(),
  ];
  num total = 0;
  for (final it in items) {
    total += it['estimated_calories'] as num;
  }
  return Meal(
    id: 0,
    date: date,
    time: time,
    timestamp: '${date}T12:00:00.000',
    source: i % 3 == 0 ? MealSource.appManual : MealSource.appWatch,
    imageHash: i % 3 == 0 ? '' : i.toRadixString(16).padLeft(32, '0'),
    analysis: {
      'is_food': true,
      'meal_description': 'Meal $i: ${items.first['name']}',
      'total_calories': total,
      'total_protein_g': 20,
      'total_carbs_g': 60,
      'total_fat_g': 15,
      'estimate_confidence': 'medium',
      'restaurant_context': i % 5 == 0 ? 'restaurant' : 'home',
      'portion_state': 'whole',
      'analyzed_by': 'claude',
      'confidence_note':
          'Portion sizes estimated from the plate; sauces may add calories.',
      'food_items': items,
    },
    corrected: marked,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  final now = DateTime(2026, 11, 7, 12, 30);
  // Seeding 400 meals is 400 transactions: allow a loaded machine.
  const slow = Timeout(Duration(minutes: 5));

  setUp(() async {
    db = await openAppDatabase(path: inMemoryDatabasePath);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async => db.close());

  Future<(_CountingDao, UsualFoods, ValueNotifier<int>)> seeded() async {
    final dao = _CountingDao(db, clock: () => now);
    var bytes = 0;
    for (var i = 0; i < 400; i++) {
      final m = _meal(i, now);
      bytes += jsonEncode(m.analysis).length;
      await dao.saveMeal(m);
    }
    debugPrint('usual index fixture: 400 meals, ${bytes ~/ 1024} KB of '
        'analysis JSON');
    final signal = ValueNotifier<int>(0);
    final usual = UsualFoods(
      dao: dao,
      choices: UsualChoices(await SharedPreferences.getInstance()),
      mealsChanged: signal,
      onMealsChanged: () => signal.value++,
      lookupTakesIt: (_) => false,
      clock: () => now,
    );
    return (dao, usual, signal);
  }

  test('measurement: index() over 400 meals on sqflite ffi', () async {
    final (dao, usual, signal) = await seeded();
    final cold = Stopwatch()..start();
    final index = await usual.index();
    cold.stop();
    final warm = <int>[];
    for (var r = 0; r < 5; r++) {
      signal.value++;
      final sw = Stopwatch()..start();
      await usual.index();
      warm.add(sw.elapsedMicroseconds);
    }
    warm.sort();
    // The two halves: the DAO's read and decode, then the pure build.
    final reads = <int>[];
    final builds = <int>[];
    for (var r = 0; r < 5; r++) {
      final sw = Stopwatch()..start();
      final meals = await dao.mealsBetween(usualWindowStart(now), '2026-11-07');
      reads.add(sw.elapsedMicroseconds);
      sw.reset();
      buildUsualIndex(meals, now: now);
      builds.add(sw.elapsedMicroseconds);
    }
    reads.sort();
    builds.sort();
    debugPrint('usual index: cold ${cold.elapsedMilliseconds} ms, warm '
        'median ${warm[2] ~/ 1000} ms = read+decode ${reads[2] ~/ 1000} ms '
        '+ build ${builds[2] ~/ 1000} ms (desktop VM; a phone is slower); '
        '${index.records.length} records, ${index.groups.length} meal '
        'groups');
    // Size, not speed: every meal was read and grouped.
    expect(dao.betweenCalls, 11);
    expect(index.groups.values.fold<int>(0, (n, g) => n + g.meals.length),
        lessThanOrEqualTo(400));
    expect(index.records, isNotEmpty);
    expect(index.groups, isNotEmpty);
  }, timeout: slow);

  test('single flight: 3 concurrent callers read the meals table once per '
      '(day, signal, epoch)', () async {
    final (dao, usual, signal) = await seeded();
    final three = await Future.wait([usual.index(), usual.index(), usual.index()]);
    expect(dao.betweenCalls, 1);
    expect(identical(three[0], three[1]) && identical(three[1], three[2]),
        isTrue);
    await Future.wait([usual.index(), usual.frequentMeals(), usual.index()]);
    expect(dao.betweenCalls, 1, reason: 'the memo still holds');
    signal.value++;
    await Future.wait([usual.index(), usual.index(), usual.frequentMeals()]);
    expect(dao.betweenCalls, 2);
    usual.invalidate();
    await Future.wait([usual.index(), usual.index(), usual.index()]);
    expect(dao.betweenCalls, 3);
  }, timeout: slow);
}
