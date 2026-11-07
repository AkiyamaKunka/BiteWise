// Usual foods, the pure half (usual-foods spec §3-§4): name keys,
// portions, the self-validating mark, the index, offers, Use and its
// undo, the My usual foods list and the re-log whitelist.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('usualNameKey (spec §3.2 key table)', () {
    // Each row of the table; the comment names the mutation it catches.
    test('a weight in brackets goes; the words match as a set', () {
      expect(usualNameKey('Oatmeal with blueberries (~300 g)'),
          'blueberry oatmeal');
      expect(usualNameKey('Blueberry oatmeal (~250 g)'), 'blueberry oatmeal');
    });

    test('matching is set equality, never a subset', () {
      expect(usualNameKey('Oatmeal (~300 g)'), 'oatmeal');
      expect(
          usualNameKey('Oatmeal (~300 g)') ==
              usualNameKey('Blueberry oatmeal (~250 g)'),
          isFalse);
    });

    test('a bracket with no digit stays: "(with milk)" is a different food',
        () {
      // Mutation: deleting every bracket would make this "oatmeal".
      expect(usualNameKey('Oatmeal (with milk)'), 'milk oatmeal');
      expect(usualNameKey('Oatmeal (with milk)'), isNot(usualNameKey('Oatmeal')));
    });

    test('numbers stay: "2 eggs" is not "Eggs"', () {
      // Mutation: dropping numbers.
      expect(usualNameKey('2 eggs'), '2 egg');
      expect(usualNameKey('Eggs'), 'egg');
    });

    test('"side" stays: a side salad is not a salad', () {
      expect(usualNameKey('Side salad'), 'salad side');
      expect(usualNameKey('Salad'), 'salad');
    });

    test('size words stay', () {
      expect(usualNameKey('Large latte'), 'large latte');
      expect(usualNameKey('Latte'), 'latte');
    });

    test('CJK: one token per character, 配 dropped, fullwidth brackets cut',
        () {
      // Mutation: keeping CJK runs whole (蓝莓燕麦粥 would not equal
      // 燕麦粥 + 蓝莓).
      final a = usualNameKey('燕麦粥配蓝莓（约300克）');
      final b = usualNameKey('蓝莓燕麦粥（约250克）');
      expect(a, isNotNull);
      expect(a, b);
      expect(a!.split(' ').toSet(), {'燕', '麦', '粥', '蓝', '莓'});
    });

    test('和 stays: 和牛汉堡 is not 牛肉汉堡', () {
      // Mutation: dropping 和 as a connector.
      expect(usualNameKey('和牛汉堡')!.split(' '), contains('和'));
      expect(usualNameKey('和牛汉堡'), isNot(usualNameKey('牛肉汉堡')));
      expect(usualNameKey('加州卷')!.split(' '), contains('加'));
    });

    test('one CJK character is a key (M12)', () {
      // Mutation: requiring 2 CJK tokens.
      expect(usualNameKey('粥'), '粥');
      expect(usualNameKey('茶'), '茶');
      expect(usualNameKey('粥'), isNot(usualNameKey('茶')));
    });

    test('牛奶 and 奶牛 collide (a known, harmless collision)', () {
      expect(usualNameKey('牛奶'), usualNameKey('奶牛'));
    });

    test('generic or too-short names have no key', () {
      // Mutation: no generic list ("Snack" would key as "snack").
      expect(usualNameKey('Snack'), isNull);
      expect(usualNameKey('Snacks'), isNull);
      expect(usualNameKey('零食'), isNull);
      expect(usualNameKey('餐'), isNull);
      expect(usualNameKey('Food'), isNull);
      expect(usualNameKey('Pb'), isNull);
      expect(usualNameKey('2'), isNull);
      expect(usualNameKey(''), isNull);
      expect(usualNameKey('(300 g)'), isNull);
      expect(usualNameKey(null), isNull);
      expect(usualNameKey(42), isNull);
    });

    test('stop words go, plurals fold, order does not matter', () {
      expect(usualNameKey('The toast with jam'), usualNameKey('Jam toast'));
      expect(usualNameKey('Fries'), usualNameKey('fry'));
      expect(usualNameKey('ＫＦＣ chicken'), 'chicken kfc');
    });
  });

  group('usualDisplayName', () {
    test('cuts measures, collapses spaces, caps at 40', () {
      expect(usualDisplayName('Oatmeal  (~250 g)'), 'Oatmeal');
      expect(usualDisplayName('燕麦粥（约300克）'), '燕麦粥');
      expect(usualDisplayName('Oatmeal (with milk)'), 'Oatmeal (with milk)');
      expect(usualDisplayName('x' * 60).length, 40);
      expect(usualDisplayName(null), '');
      expect(usualDisplayName('(300 g)'), '(300 g)');
    });
  });

  group('usualPortion (T24b)', () {
    test('weights, volumes and counts are read and normalized', () {
      expect(usualPortion('Oatmeal (~250 g)'),
          const UsualPortion(UsualPortionKind.mass, 250));
      expect(usualPortion('燕麦粥（约300克）'),
          const UsualPortion(UsualPortionKind.mass, 300));
      expect(usualPortion('Steak (8 oz)')!.value, closeTo(226.8, 0.01));
      expect(usualPortion('Rice 1.5 kg')!.value, 1500);
      expect(usualPortion('Latte (12 fl oz)'),
          const UsualPortion(UsualPortionKind.volume, 12 * 29.57));
      expect(usualPortion('Milk 500 ml'),
          const UsualPortion(UsualPortionKind.volume, 500));
      expect(usualPortion('Juice (about 1 l)'),
          const UsualPortion(UsualPortionKind.volume, 1000));
      expect(usualPortion('Dumplings (6 pcs)'),
          const UsualPortion(UsualPortionKind.count, 6));
      expect(usualPortion('Pizza 2 slices'),
          const UsualPortion(UsualPortionKind.count, 2));
      expect(usualPortion('饺子（约10个）'),
          const UsualPortion(UsualPortionKind.count, 10));
    });

    test('no portion: no unit, a word that only starts like one, zero', () {
      expect(usualPortion('2 eggs'), isNull);
      expect(usualPortion('300 grapes'), isNull);
      expect(usualPortion('Oatmeal'), isNull);
      expect(usualPortion('Water (0 ml)'), isNull);
      expect(usualPortion(null), isNull);
    });

    test('compatibility', () {
      bool ok(String a, String b) =>
          usualPortionsCompatible(usualPortion(a), usualPortion(b));
      expect(ok('Oatmeal (~250 g)', 'Oatmeal (~500 g)'), isFalse);
      expect(ok('燕麦粥（约300克）', 'Oatmeal (~250 g)'), isTrue);
      expect(ok('Dumplings (6 pcs)', 'Dumplings (10 pcs)'), isFalse);
      expect(ok('Dumplings (300 g)', 'Dumplings (10 pcs)'), isTrue,
          reason: 'mass vs count says nothing');
      expect(ok('Oatmeal (~250 g)', 'Oatmeal'), isTrue,
          reason: 'one side missing');
      expect(ok('Oatmeal (~250 g)', 'Oatmeal (~325 g)'), isTrue,
          reason: '1.3x is the edge, still compatible');
    });
  });

  group('marks', () {
    final now = DateTime.utc(2026, 11, 6, 13, 40, 12, 345);
    Map<String, dynamic> marked(
            {num kcal = 350,
            num p = 12,
            num c = 50,
            num f = 14,
            Object? n,
            Object? at,
            Object? set = true}) =>
        {
          'name': 'Overnight oats',
          'estimated_calories': kcal,
          'protein_g': p,
          'carbs_g': c,
          'fat_g': f,
          'user': {
            'set': set,
            'at': at ?? '2026-11-06T13:40:12.345Z',
            'n': n ?? [350, 12, 50, 14],
            'qty': 1,
          },
        };

    test('usualStamp is UTC ISO with milliseconds', () {
      expect(usualStamp(now), '2026-11-06T13:40:12.345Z');
      expect(usualStamp(DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7)),
          '2026-01-02T03:04:05.006Z');
    });

    test('valid only while the numbers equal n', () {
      expect(usualMarkValid(marked(), now), isTrue);
      expect(usualMarkValid(marked(kcal: 350.4), now), isTrue);
      expect(usualMarkValid(marked(kcal: 351), now), isFalse);
      expect(usualMarkValid(marked(p: 12.04), now), isTrue);
      expect(usualMarkValid(marked(p: 12.1), now), isFalse);
      expect(usualMarkValid(marked(f: 0), now), isFalse);
    });

    test('a malformed mark is void', () {
      expect(usualMarkValid(marked(set: 'true'), now), isFalse);
      expect(usualMarkValid(marked(n: [350, 12, 50]), now), isFalse);
      expect(usualMarkValid(marked(n: [350, 12, 50, '14']), now), isFalse);
      expect(usualMarkValid(marked(n: 'x'), now), isFalse);
      expect(usualMarkValid(marked(at: 'yesterday'), now), isFalse);
      expect(usualMarkValid(marked(at: '2026-11-08T13:40:12.345Z'), now),
          isFalse,
          reason: 'more than a day in the future');
      expect(usualMarkValid(marked(at: '2026-11-07T13:00:00.000Z'), now),
          isTrue);
      expect(usualMarkValid({'name': 'x', 'user': 'set'}, now), isFalse);
      expect(usualMarkValid(null, now), isFalse);
    });

    test('usualItemQty reads the mark, then the item', () {
      expect(usualItemQty({'qty': 2}), 2);
      expect(
          usualItemQty({
            'qty': 1,
            'user': {'qty': 2}
          }),
          2);
      expect(
          usualItemQty({
            'qty': 3,
            'user': {'qty': 25}
          }),
          3);
      expect(usualItemQty({'qty': '2'}), 1);
      expect(usualItemQty({}), 1);
    });

    test('usualMarksTrusted: corrected meals and the hand-typed sources', () {
      Meal m(String source, {bool corrected = false}) => Meal(
          id: 1,
          date: '2026-11-06',
          time: '07:40 AM',
          timestamp: '2026-11-06T07:40:00.000',
          source: source,
          analysis: const {},
          corrected: corrected);
      expect(usualMarksTrusted(m(MealSource.appPhoto)), isFalse);
      expect(usualMarksTrusted(m(MealSource.appWatch)), isFalse);
      expect(usualMarksTrusted(m(MealSource.appWatch, corrected: true)),
          isTrue);
      for (final s in [
        MealSource.appManual,
        MealSource.appManualPhoto,
        MealSource.manualText,
        MealSource.appRepeat,
      ]) {
        expect(usualMarksTrusted(m(s)), isTrue, reason: s);
      }
    });
  });
}
