/// What counts as a published number in a restaurant lookup: a whole kcal
/// in 0..kAssistMaxPublishedKcal, grams in 0..kAssistMaxPublishedGrams,
/// and a kcal range of two such values, low first. It is a grounding rule,
/// so every reader must agree on it: the one implementation
/// (publishedKcal, publishedGrams, publishedKcalRange), lane B's options
/// (pickOption), the lookup adapter's typed view (LookupOption,
/// LookupComponent) and the stored block's view (AssistView: a match's
/// numbers, its range and its sizes). One table runs through all of them.
library;

import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/ui/assist_view.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/assist_fixtures.dart';

/// (raw value, the published kcal it is)
final List<(Object?, int?)> kcalCases = [
  (590, 590),
  (590.0, 590),
  (0, 0),
  (-0.0, 0),
  (6000, 6000),
  (6000.0, 6000),
  (590.5, null),
  (6000.5, null),
  (6001, null),
  (-1, null),
  (double.nan, null),
  (double.infinity, null),
  (double.negativeInfinity, null),
  (1e300, null),
  (true, null),
  (false, null),
  ('590', null),
  (null, null),
  ([590], null),
  ({'value': 590}, null),
];

/// (raw value, the published grams it is)
final List<(Object?, num?)> gramsCases = [
  (25, 25),
  (25.5, 25.5),
  (0, 0),
  (1000, 1000),
  (1000.0, 1000.0),
  (1000.5, null),
  (-0.5, null),
  (double.nan, null),
  (double.infinity, null),
  (true, null),
  ('25', null),
  (null, null),
];

/// (raw value, the published range it is)
final List<(Object?, List<int>?)> rangeCases = [
  ([250, 290], [250, 290]),
  ([290, 290], [290, 290]),
  ([250.0, 290.0], [250, 290]),
  ([0, 6000], [0, 6000]),
  ([290, 250], null),
  ([250], null),
  ([250, 290, 330], null),
  (<Object?>[], null),
  ([250.5, 290], null),
  ([250, 6001], null),
  ([-10, 290], null),
  (['250', 290], null),
  ([true, 290], null),
  ([null, 290], null),
  ([250, double.nan], null),
  ('250-290', null),
  ({'0': 250, '1': 290}, null),
  (null, null),
];

/// A photographed item lane B compares the options with.
const Map<String, Object?> _item = {'estimated_calories': 500, 'qty': 1};

/// The stored view of an applied block whose one match is [match].
AssistItemView _viewed(Map<String, Object?> match) {
  final a = appliedBigMac();
  final block = Map<String, dynamic>.from(a['assist'] as Map)
    ..['matches'] = [
      {'menu_item': 'Big Mac', ...match},
    ];
  return AssistView.of(Map<String, dynamic>.from(a)..['assist'] = block)
      .items
      .single;
}

/// The second of two stored sizes, or null when the view dropped it (a
/// view lists sizes only when at least two are usable).
AssistSize? _secondSize(Map<String, Object?> size) {
  final sizes = _viewed({
    'sizes': [
      {'label': 'Small', 'calories': 230},
      {'label': 'Large', ...size},
    ],
  }).sizes;
  return sizes.length == 2 ? sizes[1] : null;
}

void main() {
  test('a published calorie value reads the same everywhere', () {
    for (final (raw, want) in kcalCases) {
      final why = '$raw';
      expect(publishedKcal(raw), want, reason: 'publishedKcal, $why');
      expect(
        pickOption(_item, [
          {'calories': raw},
        ])?.published.calories,
        want,
        reason: 'lane B option, $why',
      );
      expect(
        LookupOption.parse({'calories': raw})?.calories,
        want,
        reason: 'adapter option, $why',
      );
      expect(
        LookupComponent.parse({'calories': raw})!.calories,
        want,
        reason: 'adapter component, $why',
      );
      expect(
        _viewed({
          'published': {'calories': raw},
        }).calories,
        want,
        reason: 'stored match, $why',
      );
      expect(
        _secondSize({'calories': raw})?.calories,
        want,
        reason: 'stored size, $why',
      );
    }
  });

  test('published grams read the same everywhere', () {
    for (final (raw, want) in gramsCases) {
      final why = '$raw';
      expect(publishedGrams(raw), want, reason: 'publishedGrams, $why');
      final macros = {'protein_g': raw, 'carbs_g': raw, 'fat_g': raw};
      final pick = pickOption(_item, [
        {'calories': 500, ...macros},
      ])!.published;
      final option = LookupOption.parse({'calories': 500, ...macros})!;
      final component = LookupComponent.parse(macros)!;
      final viewed = _viewed({'published': macros});
      for (final (where, values) in [
        ('lane B option', [pick.proteinG, pick.carbsG, pick.fatG]),
        ('adapter option', [option.proteinG, option.carbsG, option.fatG]),
        (
          'adapter component',
          [component.proteinG, component.carbsG, component.fatG],
        ),
        ('stored match', [viewed.proteinG, viewed.carbsG, viewed.fatG]),
      ]) {
        expect(values, [want, want, want], reason: '$where, $why');
      }
    }
  });

  test('a published calorie range reads the same everywhere', () {
    for (final (raw, want) in rangeCases) {
      final why = '$raw';
      expect(publishedKcalRange(raw), want, reason: 'publishedKcalRange, $why');
      expect(
        pickOption(_item, [
          {'calories_range': raw},
        ])?.caloriesRange,
        want,
        reason: 'lane B option, $why',
      );
      expect(
        LookupOption.parse({'calories_range': raw})?.caloriesRange,
        want,
        reason: 'adapter option, $why',
      );
      expect(
        _viewed({'calories_range': raw}).caloriesRange,
        want,
        reason: 'stored match, $why',
      );
      expect(
        _secondSize({'calories_range': raw})?.caloriesRange,
        want,
        reason: 'stored size, $why',
      );

      // An option giving a value next to a range breaks the contract: lane
      // B and the adapter keep a usable range and drop the value (a range
      // never applies), else they keep the value.
      final both = {'calories': 500, 'calories_range': raw};
      final pick = pickOption(_item, [both])!;
      final option = LookupOption.parse(both)!;
      for (final (where, range, calories) in [
        ('lane B option', pick.caloriesRange, pick.published.calories),
        ('adapter option', option.caloriesRange, option.calories),
      ]) {
        expect(range, want, reason: '$where, value and $why');
        expect(calories, want == null ? 500 : null,
            reason: '$where, value and $why');
      }
      // The stored size keeps both, as the block stored them.
      final size = _secondSize(both)!;
      expect(size.caloriesRange, want, reason: 'stored size, value and $why');
      expect(size.calories, 500, reason: 'stored size, value and $why');
    }
  });
}
