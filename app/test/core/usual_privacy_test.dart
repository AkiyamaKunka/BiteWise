// Nothing new leaves the phone (usual-foods spec §7, T34). The usual-foods
// mark (`user`), the re-log stamp (`logged_again`) and a saved answer's
// `fetched_on` live inside a meal's own analysis, and every outbound
// composer whitelists what it reads. So with or without them, every
// outbound text is byte for byte the same: the photo prompt's and the own
// server's recent meals, the chat meals list, the restaurant lookup
// request, and the leftover flow's compact original (also when the marks
// sit inside `leftover.original`).
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/leftover_logic.dart';
import 'package:calorie_tracker/core/restaurant_lookup_contract.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart'
    show composeAssistRequest;
import 'package:calorie_tracker/services/nl/executor.dart' show buildMealsList;
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Two meals as the phone stores them.
Map<String, dynamic> _plain() => {
      'is_food': true,
      'meal_description': 'Breakfast bowl',
      'total_calories': 540,
      'total_protein_g': 20,
      'total_carbs_g': 70,
      'total_fat_g': 18,
      'order_merchant': 'Chipotle',
      'food_items': [
        {
          'name': 'Overnight oats',
          'estimated_calories': 350,
          'protein_g': 12,
          'carbs_g': 50,
          'fat_g': 14,
          'qty': 1,
          'unit': 'bowl',
        },
        {
          'name': 'Latte',
          'estimated_calories': 190,
          'protein_g': 8,
          'carbs_g': 20,
          'fat_g': 4,
          'brand': 'Starbucks',
        },
      ],
      'assist': {'v': 2, 'status': 'applied', 'chain_key': 'starbucks'},
    };

/// The same meals carrying everything this PR stores.
Map<String, dynamic> _marked(Map<String, dynamic> a) {
  final items = [
    for (final it in a['food_items'] as List)
      {
        ...it as Map<String, dynamic>,
        'user': {
          'set': true,
          'at': '2026-11-06T13:40:12.345Z',
          'n': [it['estimated_calories'], it['protein_g'], it['carbs_g'],
              it['fat_g']],
          'qty': 1,
          'ai_name': 'Oatmeal (~250 g) — a name the user replaced',
        },
      },
  ];
  return {
    ...a,
    'food_items': items,
    'logged_again': '2026-11-07T15:10:04.321Z',
    'assist': {...a['assist'] as Map, 'fetched_on': '2026-03-02'},
  };
}

/// A leftover-deducted meal whose ORIGINAL (what the leftover flow
/// compacts) carries the marks.
Map<String, dynamic> _withLeftover(Map<String, dynamic> original) => {
      ..._plain(),
      'total_calories': 270,
      'leftover': {'original': original, 'applied_total': 270},
    };

Meal _meal(int id, Map<String, dynamic> analysis) => Meal(
      id: id,
      date: '2026-11-07',
      time: '07:40 AM',
      timestamp: '2026-11-07T07:40:00.000',
      source: MealSource.appRepeat,
      analysis: analysis,
    );

void main() {
  final plain = _plain();
  final marked = _marked(plain);

  test('the fixture really carries what this PR stores', () {
    expect(jsonEncode(marked), contains('"user"'));
    expect(jsonEncode(marked), contains('logged_again'));
    expect(jsonEncode(marked), contains('fetched_on'));
    expect(jsonEncode(marked), isNot(jsonEncode(plain)));
  });

  test('recentMealCompact (the photo prompt and the server payload)', () {
    expect(
        jsonEncode(recentMealCompact(time: '07:40 AM', analysis: marked)),
        jsonEncode(recentMealCompact(time: '07:40 AM', analysis: plain)));
    expect(
        formatRecentMealsBlock([
          recentMealCompact(time: '07:40 AM', analysis: marked),
        ]),
        formatRecentMealsBlock([
          recentMealCompact(time: '07:40 AM', analysis: plain),
        ]));
  });

  test('buildMealsList (the chat prompt)', () {
    expect(buildMealsList([_meal(1, marked), _meal(2, _withLeftover(marked))]),
        buildMealsList([_meal(1, plain), _meal(2, _withLeftover(plain))]));
  });

  test('composeLookupRequest (the restaurant lookup)', () {
    Map<String, Object?> raw(Map<String, dynamic> a) => {
          'items': a['food_items'],
          'order_merchant': a['order_merchant'],
          'chains': ['chipotle'],
          'country': 'US',
          'lang': 'zh',
        };
    expect(canonicalLookupJson(composeLookupRequest(raw(marked))),
        canonicalLookupJson(composeLookupRequest(raw(plain))));
    expect(composeLookupPrompt(raw(marked)), composeLookupPrompt(raw(plain)));
    expect(
        composeAssistRequest(marked, country: 'US', chains: ['chipotle'])
            .toJson(),
        composeAssistRequest(plain, country: 'US', chains: ['chipotle'])
            .toJson());
  });

  test('compactOriginalAnalysis (the leftover flow), marks inside '
      'leftover.original too', () {
    expect(compactOriginalAnalysis(marked), compactOriginalAnalysis(plain));
    final deducted = compactOriginalAnalysis(_withLeftover(marked));
    expect(deducted, compactOriginalAnalysis(_withLeftover(plain)));
    expect(deducted, contains('540'),
        reason: 'the original was read, not the deducted meal');
  });

  test("the own server's recent_meals payload", () async {
    Future<String> bodyFor(Map<String, dynamic> analysis) async {
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: _MemoryKeys());
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://10.0.0.5');
      await s.setServerApiKey('upload-key');
      final bodies = <String>[];
      final analyzer = ServerAnalyzer(
        s,
        normalizer: (b) async => b,
        client: MockClient((req) async {
          bodies.add(req.body);
          return http.Response(
              jsonEncode({
                'ok': true,
                'analysis': {'is_food': true, 'total_calories': 1},
                'analyzed_by': 'claude',
              }),
              200);
        }),
      );
      await analyzer.analyzePhoto(Uint8List.fromList([1, 2, 3, 4]),
          recentMeals: [
            recentMealCompact(time: '07:40 AM', analysis: analysis),
            recentMealCompact(
                time: '12:10 PM', analysis: _withLeftover(analysis)),
          ]);
      return bodies.single;
    }

    final withMarks = await bodyFor(marked);
    expect(withMarks, contains('recent_meals'));
    expect(withMarks, await bodyFor(plain));
  });
}
