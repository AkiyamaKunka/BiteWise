// The photo analysis's MEAL CONTEXT fields (restaurant assist, stage R1):
// estimate_confidence, restaurant_context, portion_state and order_merchant
// on the meal, brand / qty / unit on each item. They are additive and read
// through core/coerce.dart only. What must hold:
//   * a missing or invalid value is UNKNOWN (null / "" / 1), never a
//     default that could trigger something;
//   * free text is cleaned before it can reach a prompt or a screen;
//   * the prompt this app sends asks for exactly the values the coercers
//     accept;
//   * the recent-meal, leftover and chat whitelists never forward the new
//     keys (nor the later assist / capture blocks);
//   * 'confidence' stays the leftover verdict's key.
import 'dart:convert';

import 'package:calorie_tracker/core/coerce.dart';
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/leftover_logic.dart';
import 'package:calorie_tracker/core/prompts.dart';
import 'package:calorie_tracker/core/shared_generated.dart';
import 'package:calorie_tracker/services/nl/executor.dart' show buildMealsList;
import 'package:calorie_tracker/ui/meal_edit_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('coerceEstimateConfidence', () {
    final table = <Object?, EstimateConfidence?>{
      'low': EstimateConfidence.low,
      'medium': EstimateConfidence.medium,
      'high': EstimateConfidence.high,
      ' HIGH ': EstimateConfidence.high,
      'Medium': EstimateConfidence.medium,
      '低': EstimateConfidence.low,
      '中': EstimateConfidence.medium,
      '高': EstimateConfidence.high,
      0: EstimateConfidence.low,
      0.2: EstimateConfidence.low,
      0.5: EstimateConfidence.medium,
      0.7: EstimateConfidence.high,
      1: EstimateConfidence.high,
      1.0: EstimateConfidence.high,
      // Unknown — never a guess.
      null: null,
      '': null,
      'unknown': null,
      'moderate': null,
      'med': null,
      'very low': null,
      '0.2': null, // a numeric STRING is not a number
      -0.1: null,
      1.01: null,
      7: null,
      double.nan: null,
      double.infinity: null,
      true: null,
      false: null,
    };
    table.forEach((input, expected) {
      test('$input → $expected', () {
        expect(coerceEstimateConfidence(input), expected);
      });
    });

    test('lists and maps are unknown', () {
      expect(coerceEstimateConfidence(['low']), isNull);
      expect(coerceEstimateConfidence({'v': 'low'}), isNull);
    });
  });

  test('coerceRestaurantContext: listed values only; "unknown" is null', () {
    expect(coerceRestaurantContext('restaurant'), RestaurantContext.restaurant);
    expect(coerceRestaurantContext(' Takeout '), RestaurantContext.takeout);
    expect(coerceRestaurantContext('PACKAGED'), RestaurantContext.packaged);
    expect(coerceRestaurantContext('home'), RestaurantContext.home);
    for (final bad in <Object?>[
      'unknown',
      null,
      '',
      'take-out',
      'delivery',
      '餐厅',
      1,
      true,
      ['restaurant'],
    ]) {
      expect(coerceRestaurantContext(bad), isNull, reason: '$bad');
    }
  });

  test('coercePortionState: listed values only', () {
    expect(coercePortionState('whole'), PortionState.whole);
    expect(coercePortionState('Partial'), PortionState.partial);
    expect(coercePortionState(' shared'), PortionState.shared);
    expect(coercePortionState('BUFFET'), PortionState.buffet);
    for (final bad in <Object?>['half', '', null, 0.5, false, 'unknown']) {
      expect(coercePortionState(bad), isNull, reason: '$bad');
    }
  });

  group('cleanBrand / cleanOrderMerchant / cleanUnit', () {
    test('compatibility forms fold like NFKC', () {
      // Expected values are Python unicodedata.normalize('NFKC', s).
      expect(cleanBrand('\uFF2B\uFF26\uFF23'), 'KFC');
      expect(
          cleanBrand('\uFF33\uFF54\uFF41\uFF52\uFF42\uFF55\uFF43\uFF4B\uFF53'
              '\u3000\uFF23\uFF4F\uFF46\uFF46\uFF45\uFF45'),
          'Starbucks Coffee');
      expect(cleanBrand('\uFB01ve \uFB02avors'), 'five flavors');
      expect(cleanBrand('Brand\u2122'), 'BrandTM');
      expect(cleanBrand('Serv\u2120'), 'ServSM');
      expect(cleanBrand('Wait\u2026'), 'Wait...');
      expect(cleanBrand('a\u00A0b\u202Fc'), 'a b c');
      // Unmapped characters pass through untouched.
      expect(cleanBrand('Café Rio'), 'Café Rio');
      expect(cleanBrand('McDonald\u2019s'), 'McDonald\u2019s');
      expect(cleanBrand('蜜雪冰城'), '蜜雪冰城');
    });

    test('nfkcLite agrees with NFKC on every character it maps', () {
      expect(nfkcLite('\uFF2B\uFF26\uFF23'), 'KFC');
      expect(nfkcLite('\uFE64b\uFE65'), '<b>');
      expect(nfkcLite('\uFB03\uFB04\uFB05\uFB06'), 'ffifflstst');
      expect(nfkcLite('\u2024\u2025'), '...');
      // The fullwidth range's two ends: U+FF01 is '!', U+FF5E is '~'.
      expect(nfkcLite('\uFF01\uFF5E'), '!~');
    });

    test('controls, invisible and bidi characters and < > are removed', () {
      expect(cleanBrand('Chi\u0000pot\u007Fle\u0085'), 'Chipotle');
      expect(cleanBrand('Star\u200Bbucks\uFEFF'), 'Starbucks');
      expect(cleanBrand('\u202EeltopihC\u202C'), 'eltopihC');
      expect(cleanBrand('\u2066Wendy\u2019s\u2069'), 'Wendy\u2019s');
      expect(cleanBrand('<script>Chipotle</script>'), 'scriptChipotle/script');
      // An unpaired surrogate (broken UTF-16 from a model reply) is dropped.
      expect(cleanBrand('Taco${String.fromCharCode(0xD800)} Bell'), 'Taco Bell');
      // Fullwidth and small angle brackets fold first, then go too.
      expect(cleanBrand('\uFF1Cb\uFF1E\uFE64i\uFE65'), 'bi');
    });

    test('whitespace collapses and trims; separators become spaces', () {
      expect(cleanBrand('  Tim\nHortons\t '), 'Tim Hortons');
      expect(cleanBrand('Panda\u001FExpress'), 'Panda Express');
      expect(cleanBrand('\u2028Five  Guys\u2029'), 'Five Guys');
      expect(cleanBrand(' \u3000 '), '');
    });

    test('length caps count code points and never split a surrogate pair',
        () {
      expect(cleanBrand('x' * 80), 'x' * kBrandMaxChars);
      expect(cleanOrderMerchant('y' * 61), 'y' * kBrandMaxChars);
      expect(cleanUnit('z' * 25), 'z' * kUnitMaxChars);
      final emoji = '🍔' * 70; // 2 UTF-16 units each
      final cut = cleanBrand(emoji);
      expect(cut.runes.length, kBrandMaxChars);
      expect(cut, '🍔' * kBrandMaxChars);
      // A cut that lands on a space does not leave it dangling.
      expect(cleanUnit('${'a' * 19} b'), 'a' * 19);
    });

    test('non-strings are empty', () {
      for (final v in <Object?>[null, 7, 1.5, true, ['KFC'], {'b': 'KFC'}]) {
        expect(cleanBrand(v), '', reason: '$v');
        expect(cleanOrderMerchant(v), '', reason: '$v');
        expect(cleanUnit(v), '', reason: '$v');
      }
    });
  });

  test('coerceQty: a finite count in (0, 20], else 1', () {
    expect(coerceQty(1), 1);
    expect(coerceQty(2), 2);
    expect(coerceQty(0.5), 0.5);
    expect(coerceQty(20), 20);
    for (final bad in <Object?>[
      null,
      0,
      -1,
      20.5,
      21,
      double.nan,
      double.infinity,
      '2',
      true,
      [2],
    ]) {
      expect(coerceQty(bad), 1, reason: '$bad');
    }
  });

  group('missing means unknown', () {
    test('an analysis from an old server or before this change', () {
      final f = mealContextFields(const {
        'is_food': true,
        'total_calories': 450,
        'food_items': [
          {'name': 'Rice', 'estimated_calories': 200}
        ],
      });
      expect(f.estimateConfidence, isNull);
      expect(f.restaurantContext, isNull);
      expect(f.portionState, isNull);
      expect(f.orderMerchant, '');
      final i = itemContextFields(const {'name': 'Rice'});
      expect(i.brand, '');
      expect(i.qty, 1);
      expect(i.unit, '');
    });

    test('hostile shapes degrade to unknown, never throw', () {
      for (final a in <Object?>[null, 'x', 3, <Object>[], <String, Object>{}]) {
        final f = mealContextFields(a);
        expect(f.estimateConfidence, isNull);
        expect(f.restaurantContext, isNull);
        expect(f.portionState, isNull);
        expect(f.orderMerchant, '');
        final i = itemContextFields(a);
        expect((i.brand, i.qty, i.unit), ('', 1, ''));
      }
    });

    test('a full reply reads back', () {
      final f = mealContextFields(const {
        'estimate_confidence': 'low',
        'restaurant_context': 'takeout',
        'portion_state': 'partial',
        'order_merchant': ' Panda  Express ',
      });
      expect(f.estimateConfidence, EstimateConfidence.low);
      expect(f.restaurantContext, RestaurantContext.takeout);
      expect(f.portionState, PortionState.partial);
      expect(f.orderMerchant, 'Panda Express');
      final i = itemContextFields(
          const {'brand': '\uFF2B\uFF26\uFF23', 'qty': 3, 'unit': 'piece'});
      expect((i.brand, i.qty, i.unit), ('KFC', 3, 'piece'));
    });
  });

  group('the prompt this app sends', () {
    final flat = foodDetectionPrompt.split(RegExp(r'\s+')).join(' ');

    test('asks for every field, with exactly the values the coercers accept',
        () {
      for (final key in const [
        'estimate_confidence',
        'restaurant_context',
        'portion_state',
        'order_merchant',
        'brand',
        'qty',
        'unit',
      ]) {
        expect(foodDetectionPrompt, contains('"$key"'), reason: key);
      }
      for (final v in [
        ...EstimateConfidence.values.map((e) => e.name),
        ...kRestaurantContextWireValues,
        ...PortionState.values.map((e) => e.name),
      ]) {
        expect(foodDetectionPrompt, contains('"$v"'), reason: v);
      }
      // Every enum member is a wire value (and "unknown" is the only wire
      // value without a member).
      expect(
          kRestaurantContextWireValues.toSet()
            ..removeAll(RestaurantContext.values.map((e) => e.name)),
          {'unknown'});
      expect(flat.toLowerCase(), contains("only on that item's own packaging"));
      expect(flat.toLowerCase(), contains('never guess'));
    });

    test('the example reply coerces to known values and no brand', () {
      const marker =
          'If the image DOES contain food, respond with a JSON object like '
          'this:\n';
      final start = foodDetectionPrompt.indexOf(marker) + marker.length;
      final end = foodDetectionPrompt.indexOf('\n}\n', start) + 2;
      final ex =
          jsonDecode(foodDetectionPrompt.substring(start, end)) as Map;
      final f = mealContextFields(ex);
      expect(f.estimateConfidence, isNotNull);
      expect(f.portionState, isNotNull);
      for (final item in ex['food_items'] as List) {
        expect(itemContextFields(item).brand, '');
      }
      expect(ex.containsKey('confidence'), isFalse,
          reason: "'confidence' stays leftover-only");
    });

    test('the zh directive keeps the enums English and copies printed names',
        () {
      const d = SharedConstants.replyLanguageDirectiveZh;
      expect(d, contains('estimate_confidence'));
      expect(d, contains('restaurant_context'));
      expect(d, contains('portion_state'));
      expect(d, contains('brand and order_merchant are copied exactly as '
          'printed'));
    });

    test('the leftover and text-intent prompts are unchanged by R1', () {
      for (final p in [
        sharedLeftoverTemplate,
        sharedTextHandlerTemplate,
      ]) {
        expect(p, isNot(contains('estimate_confidence')));
        expect(p, isNot(contains('order_merchant')));
      }
    });
  });

  group('whitelists never forward the new keys', () {
    const rich = <String, dynamic>{
      'is_food': true,
      'meal_description': 'Burrito bowl',
      'total_calories': 900,
      'total_protein_g': 40,
      'total_carbs_g': 90,
      'total_fat_g': 35,
      'estimate_confidence': 'low',
      'restaurant_context': 'restaurant',
      'portion_state': 'whole',
      'order_merchant': 'Chipotle',
      'assist': {'v': 2, 'status': 'applied', 'chain_key': 'chipotle'},
      'capture': {'device': 'meta_glasses', 'has_gps': true},
      'food_items': [
        {
          'name': 'Burrito bowl (~600 g)',
          'estimated_calories': 900,
          'brand': 'Chipotle',
          'qty': 1,
          'unit': 'bowl',
          'published': true,
        }
      ],
    };
    const forbidden = [
      'estimate_confidence',
      'restaurant_context',
      'portion_state',
      'order_merchant',
      'brand',
      'qty',
      'unit',
      'assist',
      'capture',
      'published',
      'Chipotle',
      'chipotle',
      'meta_glasses',
    ];
    void expectClean(String text) {
      for (final w in forbidden) {
        expect(text, isNot(contains(w)), reason: w);
      }
    }

    test('recentMealCompact and the RECENT MEALS block', () {
      final c = recentMealCompact(time: '12:30 PM', analysis: rich);
      expect(c['meal_description'], 'Burrito bowl');
      expectClean(jsonEncode(c));
      expectClean(formatRecentMealsBlock([c]));
    });

    test('compactOriginalAnalysis (the leftover prompt)', () {
      final out = compactOriginalAnalysis(rich);
      expect(out, contains('Burrito bowl'));
      expectClean(out);
    });

    test('buildMealsList (the chat prompt)', () {
      final out = buildMealsList(const [
        Meal(
            id: 1,
            date: '2026-10-23',
            time: '12:30 PM',
            timestamp: '2026-10-23T12:30:00',
            source: 'photo',
            analysis: rich),
      ]);
      expect(out, contains('Burrito bowl'));
      expectClean(out);
    });
  });

  test('an editor save keeps the meal-level fields (unknown-key merge)', () {
    // Data contract: the extra keys a new server sends are stored, and the
    // editor's base merge preserves them. Item rows are rebuilt from what
    // the editor shows, so an edited item does not carry the model's
    // brand/qty/unit forward (a user-curated row makes no printed-brand
    // claim) — R6a decides any finer rule.
    final draft = MealDraft.fromMeal(const Meal(
        id: 1,
        date: '2026-10-23',
        time: '12:30 PM',
        timestamp: '2026-10-23T12:30:00',
        source: 'photo',
        analysis: {
          'is_food': true,
          'meal_description': 'Burrito bowl',
          'total_calories': 900,
          'estimate_confidence': 'low',
          'restaurant_context': 'restaurant',
          'portion_state': 'whole',
          'order_merchant': 'Chipotle',
          'food_items': [
            {
              'name': 'Burrito bowl',
              'estimated_calories': 900,
              'brand': 'Chipotle',
              'qty': 1,
              'unit': 'bowl',
            }
          ],
        }));
    draft.calories = '850';
    final saved = draft.toAnalysis();
    final f = mealContextFields(saved);
    expect(f.estimateConfidence, EstimateConfidence.low);
    expect(f.restaurantContext, RestaurantContext.restaurant);
    expect(f.portionState, PortionState.whole);
    expect(f.orderMerchant, 'Chipotle');
    expect(saved['total_calories'], 850);
    expect((saved['food_items'] as List).single['name'], 'Burrito bowl');
  });

  test("the leftover gate never reads estimate_confidence as 'confidence'",
      () {
    // A high estimate_confidence on a reply that names a candidate but has
    // no leftover confidence is NOT a leftover verdict.
    final reply = <String, dynamic>{
      'is_food': true,
      'leftover_of': 0,
      'estimate_confidence': 'high',
      'leftover_fraction': 0.3,
    };
    expect(autoLeftoverIndex(reply, candidateCount: 1), isNull);
    reply['confidence'] = 0.95;
    expect(autoLeftoverIndex(reply, candidateCount: 1), 0);
  });
}
