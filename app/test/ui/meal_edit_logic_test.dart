// Editor rules (spec §9 app-only divergence: hand-edited meals). Field
// parsing/bounds, item sums, and the analysis merge that decides what is
// persisted — the merge is where a bug silently corrupts a meal row.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/ui/meal_edit_logic.dart';
import 'package:flutter_test/flutter_test.dart';

Meal mealWith(Map<String, dynamic> analysis,
        {String date = '2026-07-24', String time = '01:30 PM'}) =>
    Meal(
      id: 7,
      date: date,
      time: time,
      timestamp: '2026-07-24T13:30:00.000',
      source: 'app_photo',
      imageHash: 'a' * 32,
      analysis: analysis,
    );

void main() {
  group('parseNumberField', () {
    test('blank is null with no error (caller treats as 0)', () {
      final p = parseNumberField('  ', label: 'Calories', max: 100);
      expect(p.value, isNull);
      expect(p.ok, isTrue);
    });

    test('accepts integers and decimals', () {
      expect(parseNumberField('450', label: 'x', max: 1000).value, 450);
      expect(parseNumberField(' 12.5 ', label: 'x', max: 1000).value, 12.5);
    });

    test('rejects text, negatives, and over-max with a named message', () {
      expect(parseNumberField('abc', label: 'Protein', max: 100).error,
          contains('Protein'));
      expect(parseNumberField('-1', label: 'Protein', max: 100).error,
          contains('negative'));
      expect(parseNumberField('101', label: 'Protein', max: 100).error,
          contains('too large'));
    });

    // RC 1.6.0: the decimal pad types the phone region's separator and
    // digits; "12,5" and "٣٥٠" were "not a number", so in a comma region
    // no decimal could be typed and with native digits no number at all.
    test('reads a decimal comma and native digits as the decimal pad types '
        'them', () {
      num? v(String s) =>
          parseNumberField(s, label: 'x', max: maxMealCalories).value;
      expect(v('12,5'), 12.5);
      expect(v('0,25'), 0.25);
      expect(v('12,'), 12);
      expect(v('٣٥٠'), 350); // Arabic-Indic
      expect(v('۳۵۰'), 350); // Extended Arabic-Indic (Persian)
      expect(v('३५०'), 350); // Devanagari
      expect(v('৩৫০'), 350); // Bengali
      expect(v('３５０'), 350); // full-width
      expect(v('١٢٫٥'), 12.5); // Arabic decimal separator
      expect(v('١٢,٥'), 12.5);
    });

    test('a comma that may be a thousands separator stays an error', () {
      for (final s in ['1,200', '1,234,567', '1.2,5', '1,2,3', '١,٢٠٠']) {
        final p = parseNumberField(s, label: 'Calories', max: maxMealCalories);
        expect(p.ok, isFalse, reason: '$s must never be read as a decimal');
        expect(p.error, contains('number'));
      }
    });

    test('a decimal comma is saved as the number it reads as', () {
      final d = MealDraft.fromMeal(mealWith({
        'meal_description': 'Lunch',
        'total_calories': 300,
        'food_items': [
          {'name': 'Rice', 'estimated_calories': 300},
        ],
      }))
        ..protein = '12,5';
      d.items[0].protein = '٢,٥';
      expect(d.validate(), isEmpty);
      final a = d.toAnalysis(now: DateTime.utc(2026, 7, 24));
      expect(a['total_protein_g'], 12.5);
      expect(((a['food_items'] as List)[0] as Map)['protein_g'], 2.5);
    });

    test('rejects NaN/Infinity spellings', () {
      for (final s in ['NaN', 'Infinity', '-Infinity']) {
        expect(parseNumberField(s, label: 'x', max: 1e6).ok, isFalse,
            reason: '$s must not reach the coercion layer');
      }
    });
  });

  group('clock round-trip', () {
    test('formats and parses the stored 12-hour format', () {
      expect(formatClock(DateTime(2026, 7, 24, 13, 5)), '01:05 PM');
      expect(formatClock(DateTime(2026, 7, 24, 0, 30)), '12:30 AM');
      expect(formatClock(DateTime(2026, 7, 24, 12, 0)), '12:00 PM');
      expect(parseClock('01:05 PM'), (hour: 13, minute: 5));
      expect(parseClock('12:30 AM'), (hour: 0, minute: 30));
      expect(parseClock('12:00 PM'), (hour: 12, minute: 0));
    });

    test('rejects junk', () {
      for (final s in ['', '25:00 PM', '13:00 PM', '07:60 AM', 'noon']) {
        expect(parseClock(s), isNull, reason: s);
      }
    });
  });

  group('MealDraft.fromMeal', () {
    test('loads totals, items and leaves an unset description blank', () {
      final draft = MealDraft.fromMeal(mealWith({
        'is_food': true,
        'total_calories': 450,
        'total_protein_g': 50,
        'total_carbs_g': 12,
        'total_fat_g': 22.5,
        'food_items': [
          {'name': 'Chicken', 'estimated_calories': 280, 'protein_g': 43},
        ],
      }));
      expect(draft.description, ''); // NOT the display fallback 'Meal'
      expect(draft.calories, '450');
      expect(draft.fat, '22.5');
      expect(draft.items.single.name, 'Chicken');
      expect(draft.items.single.carbs, ''); // absent → blank, not '0'
    });

    test('survives hostile analysis shapes', () {
      final draft = MealDraft.fromMeal(mealWith({
        'total_calories': 'lots',
        'total_protein_g': double.infinity,
        'food_items': 'not a list',
        'meal_description': 42,
      }));
      expect(draft.calories, '');
      expect(draft.protein, '');
      expect(draft.items, isEmpty);
      expect(draft.description, '');
    });
  });

  group('validate', () {
    MealDraft good() => MealDraft(
          description: 'Lunch',
          dateIso: '2026-07-24',
          time: '01:30 PM',
          calories: '500',
          protein: '30',
          carbs: '40',
          fat: '10',
          items: [],
        );

    test('a clean draft has no errors', () {
      expect(good().validate(), isEmpty);
    });

    test('catches bad dates, times, and fields', () {
      final d = good()
        ..dateIso = '2026-13-40'
        ..time = '99:99'
        ..calories = '-5';
      final errors = d.validate();
      expect(errors.any((e) => e.contains('Date')), isTrue);
      expect(errors.any((e) => e.contains('Time')), isTrue);
      expect(errors.any((e) => e.contains('Calories')), isTrue);
    });

    test('rejects dates that do not exist (Dart parse rolls them over)', () {
      for (final bad in ['2026-13-40', '2026-02-30', '2026-00-10', '26-07-24']) {
        expect((good()..dateIso = bad).validate(), isNotEmpty, reason: bad);
      }
      expect((good()..dateIso = '2024-02-29').validate(), isEmpty,
          reason: 'a real leap day must be accepted');
    });

    test('blank item rows are ignored, filled ones are validated', () {
      final d = good()
        ..items = [
          MealItemDraft(), // untouched row the user added and left alone
          MealItemDraft(name: 'Rice', calories: 'abc'),
        ];
      final errors = d.validate();
      expect(errors, hasLength(1));
      // Numbered by the ROW the user sees (the blank row counts), so the
      // message points at the right field.
      expect(errors.single, contains('Item 2 calories'));
    });
  });

  group('toAnalysis', () {
    test('preserves unknown keys and forces is_food true', () {
      final draft = MealDraft.fromMeal(mealWith({
        'is_food': false, // e.g. a mis-detected photo the user is fixing
        'analyzed_by': 'claude',
        'total_calories': 0,
      }))
        ..description = 'Congee'
        ..calories = '320'
        ..protein = '9';
      final out = draft.toAnalysis();
      expect(out['analyzed_by'], 'claude'); // untouched passenger key
      expect(out['is_food'], isTrue); // else every read path hides the meal
      expect(out['meal_description'], 'Congee');
      expect(out['total_calories'], 320);
      expect(out['total_protein_g'], 9);
      expect(out['total_carbs_g'], 0); // blank means zero for a curated meal
      expect(out['food_items'], isEmpty);
    });

    test('empty description falls back to the display default', () {
      final out = (MealDraft.blank(DateTime(2026, 7, 24))..calories = '10')
          .toAnalysis();
      expect(out['meal_description'], 'Meal');
    });

    test('items are normalized with numeric fields', () {
      // Usual-foods spec §3.1: an added row's numbers are the user's, so it
      // carries the mark (updated on purpose for that change).
      final out = (MealDraft.blank(DateTime(2026, 7, 24))
            ..items = [
              MealItemDraft(name: ' Toast ', calories: '90', fat: '2'),
              MealItemDraft(), // dropped
            ])
          .toAnalysis(now: DateTime.utc(2026, 7, 24, 12));
      final items = out['food_items'] as List;
      expect(items, hasLength(1));
      expect(items.single, {
        'name': 'Toast',
        'estimated_calories': 90,
        'protein_g': 0,
        'carbs_g': 0,
        'fat_g': 2,
        'user': {
          'set': true,
          'at': '2026-07-24T12:00:00.000Z',
          'n': [90, 0, 0, 2],
          'qty': 1,
        },
      });
    });
  });

  test('numeric STRING totals load into the fields (no silent zeroing)', () {
    // The analyzer stores model output raw, so "450" is a real stored shape.
    // Loading it as blank made a no-op save persist 0 and wipe the meal.
    final draft = MealDraft.fromMeal(mealWith({
      'is_food': true,
      'total_calories': '450',
      'total_protein_g': '50.5',
      'food_items': [
        {'name': 'Chicken', 'estimated_calories': '280'},
      ],
    }));
    expect(draft.calories, '450');
    expect(draft.protein, '50.5');
    expect(draft.items.single.calories, '280');
    // And a save round-trips the numbers instead of zeroing them.
    final out = draft.toAnalysis();
    expect(out['total_calories'], 450);
    expect(out['total_protein_g'], 50.5);
  });

  test('item sums are tidied, not float garbage', () {
    final d = MealDraft.blank(DateTime(2026, 7, 24))
      ..items = [
        MealItemDraft(name: 'A', fat: '0.1'),
        MealItemDraft(name: 'B', fat: '0.2'),
      ];
    expect(d.itemTotals().fat, 0.3); // not 0.30000000000000004
  });

  test('itemTotals sums only filled rows', () {
    final d = MealDraft.blank(DateTime(2026, 7, 24))
      ..items = [
        MealItemDraft(name: 'A', calories: '100', protein: '10'),
        MealItemDraft(name: 'B', calories: '50.5', fat: '3'),
        MealItemDraft(),
      ];
    final t = d.itemTotals();
    expect(t.calories, 150.5);
    expect(t.protein, 10);
    expect(t.fat, 3);
    expect(t.carbs, 0);
  });

  group('addItem', () {
    test('the first row inherits the hand-typed totals, later rows are blank',
        () {
      // Found 2026-10-07: with no rows the totals are the only source of
      // truth; deriving them from one empty row zeroed a 450 kcal meal the
      // moment "Add item" was tapped.
      final d = MealDraft.blank(DateTime(2026, 7, 24))
        ..calories = '450'
        ..protein = '50'
        ..carbs = '12'
        ..fat = '22';
      final first = d.addItem();
      expect(d.items, [same(first)]);
      expect(first.name, '');
      expect(first.calories, '450');
      expect(first.protein, '50');
      expect(first.carbs, '12');
      expect(first.fat, '22');
      // Re-deriving the totals from the rows gives back what was typed.
      final t = d.itemTotals();
      expect(t.calories, 450);
      expect(t.protein, 50);
      expect(t.carbs, 12);
      expect(t.fat, 22);

      final second = d.addItem();
      expect(d.items, hasLength(2));
      expect(second.isBlank, isTrue,
          reason: 'seeding again would double the totals');
      expect(d.itemTotals().calories, 450);
    });

    test('with blank totals the first row is blank too', () {
      final d = MealDraft.blank(DateTime(2026, 7, 24));
      expect(d.addItem().isBlank, isTrue);
      expect(d.itemTotals().calories, 0);
    });
  });

  // Design R6a (and the R1 note "R6a decides any finer rule"): an item row
  // the user did not touch keeps what it says about itself.
  group('untouched item rows', () {
    final stored = <String, dynamic>{
      'is_food': true,
      'meal_description': 'Burrito bowl',
      'total_calories': 1150,
      'food_items': [
        {
          'name': 'Burrito bowl',
          'estimated_calories': 1050,
          'protein_g': 50,
          'carbs_g': 110,
          'fat_g': 40,
          'brand': 'Chipotle',
          'qty': 1,
          'unit': 'bowl',
          'published': true,
        },
        {
          'name': 'Chips',
          'estimated_calories': '100', // a raw model string
          'brand': 'Chipotle',
          'leftover_left_fraction': 0.5,
        },
      ],
      'assist': {'v': 2, 'status': 'applied', 'chain_key': 'chipotle'},
    };

    test('keep every stored key when only the date or name changed', () {
      final d = MealDraft.fromMeal(mealWith(stored))
        ..dateIso = '2026-07-23'
        ..description = 'Lunch bowl';
      final items = d.toAnalysis()['food_items'] as List;
      expect(items[0], {
        'name': 'Burrito bowl',
        'estimated_calories': 1050,
        'protein_g': 50,
        'carbs_g': 110,
        'fat_g': 40,
        'brand': 'Chipotle',
        'qty': 1,
        'unit': 'bowl',
        'published': true,
      });
      expect(items[1]['brand'], 'Chipotle');
      expect(items[1]['leftover_left_fraction'], 0.5);
      expect(items[1]['estimated_calories'], 100,
          reason: 'the numbers are still normalized as the row read them');
      expect(items[1]['protein_g'], 0);
    });

    test('a row the user changed is rebuilt from what the editor shows', () {
      final d = MealDraft.fromMeal(mealWith(stored));
      d.items[0].calories = '980';
      d.items[1].name = 'Tortilla chips';
      final items =
          d.toAnalysis(now: DateTime.utc(2026, 7, 24, 13, 30))['food_items']
              as List;
      // Updated on purpose for the usual-foods mark (spec §3.1): the user's
      // new numbers are marked as theirs.
      expect(items[0], {
        'name': 'Burrito bowl',
        'estimated_calories': 980,
        'protein_g': 50,
        'carbs_g': 110,
        'fat_g': 40,
        'user': {
          'set': true,
          'at': '2026-07-24T13:30:00.000Z',
          'n': [980, 50, 110, 40],
          'qty': 1,
        },
      }, reason: 'no longer the published numbers, nor a printed-brand claim');
      expect((items[1] as Map).containsKey('brand'), isFalse);
      expect((items[1] as Map).containsKey('leftover_left_fraction'), isFalse);
      expect(items[1]['user'], {'qty': 1, 'ai_name': 'Chips'},
          reason: 'a rename alone marks no numbers, only the old name');
    });

    test('a row typed back to its loaded text counts as untouched; added '
        'rows carry nothing', () {
      final d = MealDraft.fromMeal(mealWith(stored));
      d.items[0].calories = '980';
      d.items[0].calories = '1050';
      d.addItem()
        ..name = 'Salsa'
        ..calories = '25';
      final items =
          d.toAnalysis(now: DateTime.utc(2026, 7, 24, 13, 30))['food_items']
              as List;
      expect(items[0]['published'], isTrue);
      expect((items[0] as Map).containsKey('user'), isFalse);
      // Updated on purpose (usual-foods spec §3.1): an added row's numbers
      // are the user's.
      expect(items[2], {
        'name': 'Salsa',
        'estimated_calories': 25,
        'protein_g': 0,
        'carbs_g': 0,
        'fat_g': 0,
        'user': {
          'set': true,
          'at': '2026-07-24T13:30:00.000Z',
          'n': [25, 0, 0, 0],
          'qty': 1,
        },
      });
    });

    test('a stored draft starts with no compare-and-set basis', () {
      // The editor sets expectedRaw once the stored row confirmed it.
      expect(MealDraft.fromMeal(mealWith(stored)).expectedRaw, isNull);
      expect(MealDraft.blank(DateTime(2026, 7, 24)).expectedRaw, isNull);
    });
  });
  // Usual-foods spec §3.1 (T25): the editor's save is the one writer that
  // knows which numbers are the user's.
  group('usual-foods marks', () {
    final now = DateTime.utc(2026, 11, 6, 13, 40, 12, 345);
    const stamp = '2026-11-06T13:40:12.345Z';
    Map<String, dynamic> aiRow({Object? qty, Object? kcal = 300}) => {
          'name': 'Oatmeal (~250 g)',
          'estimated_calories': kcal,
          'protein_g': 10,
          'carbs_g': 54,
          'fat_g': 6,
          'qty': ?qty,
        };
    Map<String, dynamic> analysisOf(List<Map<String, dynamic>> items) => {
          'is_food': true,
          'meal_description': 'Breakfast',
          'total_calories': 300,
          'food_items': items,
        };
    Map<String, dynamic> saveRow(Map<String, dynamic> row,
        void Function(MealItemDraft it) edit,
        {DateTime? at}) {
      final d = MealDraft.fromMeal(mealWith(analysisOf([row])));
      edit(d.items.single);
      return (d.toAnalysis(now: at ?? now)['food_items'] as List).single
          as Map<String, dynamic>;
    }

    test('changed numbers give set, at, n, and qty from the stored row', () {
      final out = saveRow(aiRow(qty: 2), (it) => it.calories = '350');
      expect(out['user'], {
        'set': true,
        'at': stamp,
        'n': [350, 10, 54, 6],
        'qty': 2,
      });
      expect(out.containsKey('qty'), isFalse,
          reason: 'toMap drops qty; the mark keeps it');
      expect(usualMarkValid(out, now), isTrue);
    });

    test('at is the injected clock, in UTC with milliseconds', () {
      final out = saveRow(aiRow(), (it) => it.fat = '8',
          at: DateTime.utc(2026, 1, 2, 3, 4, 5, 6));
      expect((out['user'] as Map)['at'], '2026-01-02T03:04:05.006Z');
    });

    test('"450" saved as 450 is no change', () {
      final out = saveRow(aiRow(kcal: '450'), (it) {
        it.calories = '451';
        it.calories = '450.0';
      });
      expect(out['estimated_calories'], 450);
      expect(out.containsKey('user'), isFalse,
          reason: 'the same number, so nothing is the user\'s yet');
    });

    test('a name-only edit of an AI row gives ai_name only', () {
      final out = saveRow(aiRow(), (it) => it.name = 'Overnight oats');
      expect(out['name'], 'Overnight oats');
      expect(out['user'], {'qty': 1, 'ai_name': 'Oatmeal (~250 g)'});
    });

    test('a name-only edit of a validly set row keeps set, at and n', () {
      final row = {
        ...aiRow(kcal: 350),
        'user': {
          'set': true,
          'at': '2026-11-01T08:00:00.000Z',
          'n': [350, 10, 54, 6],
          'qty': 1,
        },
      };
      final out = saveRow(row, (it) => it.name = 'Overnight oats');
      expect(out['user'], {
        'set': true,
        'at': '2026-11-01T08:00:00.000Z',
        'n': [350, 10, 54, 6],
        'qty': 1,
        'ai_name': 'Oatmeal (~250 g)',
      });
    });

    test('a touched row whose stored mark is void gets no set', () {
      // The numbers moved under the mark (a lookup or a deduction).
      final row = {
        ...aiRow(kcal: 590),
        'user': {
          'set': true,
          'at': '2026-11-01T08:00:00.000Z',
          'n': [350, 10, 54, 6],
          'qty': 1,
          'ai_name': 'Oatmeal',
        },
      };
      final out = saveRow(row, (it) => it.name = 'Porridge');
      expect(out['user'], {'qty': 1, 'ai_name': 'Oatmeal'},
          reason: 'the stored ai_name wins over the stored name');
    });

    test('an untouched row keeps user byte for byte', () {
      final user = {
        'set': true,
        'at': '2020-01-01T00:00:00Z',
        'n': [1, 2, 3, 4],
        'qty': 1,
        'extra': 'kept',
      };
      final d = MealDraft.fromMeal(mealWith(analysisOf([
        {...aiRow(), 'user': user},
      ])))
        ..description = 'Renamed meal';
      final out =
          (d.toAnalysis(now: now)['food_items'] as List).single as Map;
      expect(out['user'], user);
    });

    test('an added row gives set with qty 1', () {
      // Updated on purpose: this row was a 5 kcal coffee, and a row under
      // the 10 kcal minimum is no longer marked (the test below).
      final d = MealDraft.fromMeal(mealWith(analysisOf([aiRow()])));
      d.addItem()
        ..name = 'Latte'
        ..calories = '190';
      final out = (d.toAnalysis(now: now)['food_items'] as List)[1] as Map;
      expect(out['user'], {
        'set': true,
        'at': stamp,
        'n': [190, 0, 0, 0],
        'qty': 1,
      });
    });

    test('an added row left blank, or under 10 kcal, gets no mark', () {
      final d = MealDraft.fromMeal(mealWith(analysisOf([aiRow()])));
      d.addItem().name = 'Toast';
      d.addItem()
        ..name = 'Black coffee'
        ..calories = '5';
      d.addItem()
        ..name = 'Mints'
        ..calories = '9.9'
        ..carbs = '2';
      final rows = (d.toAnalysis(now: now)['food_items'] as List).skip(1);
      expect([for (final r in rows) (r as Map).containsKey('user')],
          [false, false, false]);
      expect([for (final r in rows) (r as Map)['estimated_calories']],
          [0, 5, 9.9]);
    });

    test('a blank row added to a lunch is never re-logged as 0 kcal', () {
      // Toast and eggs on two mornings (listed in My usual foods).
      Meal breakfast(int id, String date) => Meal(
            id: id,
            date: date,
            time: '08:00 AM',
            timestamp: '${date}T08:00:00.000',
            source: MealSource.appWatch,
            analysis: {
              'is_food': true,
              'meal_description': 'Toast and eggs',
              'total_calories': 320,
              'food_items': [
                {
                  'name': 'Toast',
                  'estimated_calories': 120,
                  'protein_g': 4,
                  'carbs_g': 20,
                  'fat_g': 2,
                },
                {
                  'name': 'Scrambled eggs',
                  'estimated_calories': 200,
                  'protein_g': 12,
                  'carbs_g': 2,
                  'fat_g': 15,
                },
              ],
            },
          );
      // Today's lunch photo: the user adds a "Toast" row by name only.
      final lunch = MealDraft.fromMeal(mealWith(analysisOf([aiRow()]),
          date: '2026-11-07', time: '12:00 PM'))
        ..items.add(MealItemDraft(name: 'Toast'));
      expect(lunch.validate(), isEmpty, reason: 'blank numbers are allowed');
      final saved = Meal(
          id: 12,
          date: '2026-11-07',
          time: '12:00 PM',
          timestamp: '2026-11-07T12:00:00.000',
          source: MealSource.appPhoto,
          corrected: true,
          analysis: lunch.toAnalysis(now: now));
      final at = DateTime(2026, 11, 7, 12, 30);
      final index = buildUsualIndex(
          [breakfast(10, '2026-11-03'), breakfast(11, '2026-11-05'), saved],
          now: at);
      expect(index.records['toast'], isNull);
      final list =
          usualMealList(index, now: at, choices: UsualChoicesView.empty);
      final row = [...list.around, ...list.more]
          .firstWhere((m) => m.title == 'Toast and eggs');
      final relog = usualLogAnalysis(row, index, now: at);
      expect((relog['food_items'] as List).first['estimated_calories'], 120);
      expect(relog['total_calories'], 320);
    });

    group('the first row "Add item" seeds from the totals', () {
      // A photo meal the AI gave totals only (no rows).
      Meal pho() => mealWith({
            'is_food': true,
            'meal_description': 'Beef pho',
            'total_calories': 640,
            'total_protein_g': 30,
            'total_carbs_g': 70,
            'total_fat_g': 25,
          });

      test('on a stored meal it is not yours while it holds the meal\'s '
          'totals', () {
        final d = MealDraft.fromMeal(pho());
        d.addItem().name = 'Pho';
        final saved = d.toAnalysis(now: now);
        final row = (saved['food_items'] as List).single as Map;
        expect(row['estimated_calories'], 640);
        expect(row.containsKey('user'), isFalse,
            reason: 'the AI\'s 640 was seeded, never typed: ${row['user']}');
        final edited = Meal(
            id: 7,
            date: '2026-11-06',
            time: '12:10 PM',
            timestamp: '2026-11-06T12:10:00.000',
            source: MealSource.appPhoto,
            corrected: true,
            analysis: saved);
        expect(
            buildUsualIndex([edited], now: DateTime(2026, 11, 7, 12))
                .records['pho'],
            isNull);
      });

      test('on a stored meal it is yours once one of its numbers differs',
          () {
        final d = MealDraft.fromMeal(pho());
        d.addItem()
          ..name = 'Pho'
          ..fat = '20';
        final row = (d.toAnalysis(now: now)['food_items'] as List).single;
        expect(row['user'], {
          'set': true,
          'at': stamp,
          'n': [640, 30, 70, 20],
          'qty': 1,
        });
        // Totals the user typed before the tap differ from the meal's too.
        final typed = MealDraft.fromMeal(pho())..calories = '700';
        typed.addItem().name = 'Pho';
        final row2 =
            (typed.toAnalysis(now: now)['food_items'] as List).single as Map;
        expect((row2['user'] as Map)['n'], [700, 30, 70, 25]);
      });

      test('on a new hand-typed meal it is yours', () {
        final d = MealDraft.blank(DateTime(2026, 11, 6, 12))
          ..calories = '450'
          ..protein = '20'
          ..carbs = '50'
          ..fat = '18';
        d.addItem().name = 'Toast and eggs';
        final row = (d.toAnalysis(now: now)['food_items'] as List).single;
        expect(row['user'], {
          'set': true,
          'at': stamp,
          'n': [450, 20, 50, 18],
          'qty': 1,
        });
      });
    });

    test('a stored qty-2 row edited twice keeps qty: 2', () {
      final once = saveRow(aiRow(qty: 2), (it) => it.calories = '400');
      final twice = saveRow(once, (it) => it.calories = '420',
          at: DateTime.utc(2026, 11, 7));
      expect(twice['user'], {
        'set': true,
        'at': '2026-11-07T00:00:00.000Z',
        'n': [420, 10, 54, 6],
        'qty': 2,
      });
      expect(usualItemQty(twice), 2);
    });

    test('a qty-only row says its count, a qty-1 row with nothing says '
        'nothing', () {
      // '300.0' touches the row without changing its number.
      final counted = saveRow(aiRow(qty: 3), (it) => it.calories = '300.0');
      expect(counted['user'], {'qty': 3});
      final plain = saveRow(aiRow(qty: 1), (it) => it.calories = '300.0');
      expect(plain.containsKey('user'), isFalse);
    });
  });

  // RC 1.6.0: a meal typed by hand on 1.5.0 has no marks and taught only
  // while never corrected; the editor's save sets corrected, so a save
  // with the numbers as typed made the meal forget them.
  group('a meal typed by hand before 1.6.0', () {
    Meal typed({
      String source = 'app_manual',
      bool corrected = false,
      int id = 7,
      String timestamp = '2026-07-24T08:00:00.000Z',
      List<Map<String, dynamic>>? items,
      Map<String, dynamic>? extra,
    }) =>
        Meal(
          id: id,
          date: '2026-07-24',
          time: '08:00 AM',
          timestamp: timestamp,
          source: source,
          corrected: corrected,
          analysis: {
            'is_food': true,
            'meal_description': 'Breakfast',
            'total_calories': 355,
            'food_items': items ??
                [
                  {
                    'name': 'Oatmeal',
                    'estimated_calories': 350,
                    'protein_g': 12,
                    'carbs_g': 55,
                    'fat_g': 8,
                  },
                  {'name': 'Salt', 'estimated_calories': 5},
                ],
            ...?extra,
          },
        );
    final now = DateTime.utc(2026, 7, 25, 9);

    List<Map<String, dynamic>> save(MealDraft d) => [
          for (final it in d.toAnalysis(now: now)['food_items'] as List)
            (it as Map).cast<String, dynamic>()
        ];

    test('saved unchanged: each row it taught gains the mark at the meal\'s '
        'own moment', () {
      final d = MealDraft.fromMeal(typed())..description = 'Oats';
      final items = save(d);
      expect(items[0]['user'], {
        'set': true,
        'at': '2026-07-24T08:00:00.000Z',
        'n': [350, 12, 55, 8],
        'qty': 1,
      });
      expect(usualMarkValid(items[0], now), isTrue);
      expect(items[1].containsKey('user'), isFalse,
          reason: 'under the usual-foods minimum it taught nothing');
    });

    test('a rename keeps the numbers the user\'s, and the old name', () {
      final d = MealDraft.fromMeal(typed());
      d.items[0].name = 'Porridge';
      final user = save(d)[0]['user'] as Map;
      expect(user['set'], isTrue);
      expect(user['at'], '2026-07-24T08:00:00.000Z');
      expect(user['ai_name'], 'Oatmeal');
    });

    test('a changed number is stamped now, as on any meal', () {
      final d = MealDraft.fromMeal(typed());
      d.items[0].calories = '360';
      expect((save(d)[0]['user'] as Map)['at'], usualStamp(now));
    });

    test('no mark where it taught nothing before', () {
      for (final m in [
        typed(corrected: true), // fixed by chat: re-estimated by a model
        typed(source: 'app_photo'),
        typed(source: 'manual_text'),
        typed(id: 0), // the describe preview's synthetic row
        typed(timestamp: 'not a time'),
        typed(timestamp: '2026-07-27T08:00:00.000Z'), // days ahead
        typed(extra: {'leftover': {}}),
        typed(items: [
          {'name': 'Eggs', 'estimated_calories': 140, 'qty': 2},
          {'name': 'Fries', 'estimated_calories': 320, 'published': true},
        ]),
      ]) {
        final items = save(MealDraft.fromMeal(m));
        for (final it in items) {
          final user = it['user'];
          expect(user is Map && user['set'] == true, isFalse,
              reason: '${m.source} corrected=${m.corrected} id=${m.id} '
                  '${m.timestamp}: ${it['name']}');
        }
      }
    });

    test('a row that already has a mark keeps it byte for byte', () {
      final mark = {
        'set': true,
        'at': '2026-07-24T08:01:00.000Z',
        'n': [350, 12, 55, 8],
        'qty': 1,
      };
      final d = MealDraft.fromMeal(typed(items: [
        {
          'name': 'Oatmeal',
          'estimated_calories': 350,
          'protein_g': 12,
          'carbs_g': 55,
          'fat_g': 8,
          'user': mark,
        },
      ]));
      expect(save(d)[0]['user'], mark);
    });
  });
}
