// Usual foods, the pure half (usual-foods spec §3-§4): name keys,
// portions, the self-validating mark, the index, offers, Use and its
// undo, the My usual foods list and the re-log whitelist.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart'
    show assistStampValid, kAssistVersion;
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── Fixtures ──────────────────────────────────────────────────────────

/// Local noon on the fixtures' "today".
final DateTime now = DateTime(2026, 11, 7, 12, 30);
const String today = '2026-11-07';

Map<String, dynamic> item(String name, num kcal,
        {num p = 10,
        num c = 54,
        num f = 6,
        Map<String, dynamic>? user,
        Object? qty,
        Map<String, dynamic> extra = const {}}) =>
    {
      'name': name,
      'estimated_calories': kcal,
      'protein_g': p,
      'carbs_g': c,
      'fat_g': f,
      'qty': ?qty,
      'user': ?user,
      ...extra,
    };

/// A mark that vouches for [n].
Map<String, dynamic> mark(List<num> n,
        {String at = '2026-11-03T08:00:00.000Z',
        num qty = 1,
        String? aiName}) =>
    {
      'set': true,
      'at': at,
      'n': n,
      'qty': qty,
      'ai_name': ?aiName,
    };

/// An item the user set to [n], with the mark.
Map<String, dynamic> mine(String name, List<num> n,
        {String at = '2026-11-03T08:00:00.000Z',
        num qty = 1,
        String? aiName}) =>
    item(name, n[0],
        p: n[1],
        c: n[2],
        f: n[3],
        user: mark(n, at: at, qty: qty, aiName: aiName));

Meal meal(int id, List<Map<String, dynamic>> items,
    {String date = today,
    String time = '07:40 AM',
    String source = MealSource.appWatch,
    bool corrected = false,
    num? total,
    String? description,
    Map<String, dynamic> extra = const {}}) {
  num sum = 0;
  for (final i in items) {
    sum += i['estimated_calories'] as num;
  }
  return Meal(
    id: id,
    date: date,
    time: time,
    timestamp: '${date}T08:00:00.000',
    source: source,
    corrected: corrected,
    analysis: {
      'is_food': true,
      'meal_description': description ?? 'Breakfast',
      'total_calories': total ?? sum,
      'total_protein_g': 10,
      'total_carbs_g': 54,
      'total_fat_g': 6,
      'estimate_confidence': 'medium',
      'restaurant_context': 'home',
      'portion_state': 'whole',
      'food_items': items,
      ...extra,
    },
  );
}

/// The user fixed the AI's oatmeal to 350 on Nov 3 (a corrected photo
/// meal).
Meal learned({int id = 1, Map<String, dynamic>? it}) => meal(
    id, [it ?? mine('Oatmeal (~250 g)', [350, 12, 50, 14])],
    date: '2026-11-03', source: MealSource.appPhoto, corrected: true);

/// Today's watcher photo of the same food, AI 300.
Meal photo({int id = 2, Map<String, dynamic>? it, Map<String, dynamic>? extra}) =>
    meal(id, [it ?? item('Oatmeal (~260 g)', 300)], extra: extra ?? const {});

UsualOffer? offer(List<Meal> meals, Meal m,
        {bool lookupTakesIt = false,
        UsualChoicesView choices = UsualChoicesView.empty,
        DateTime? at}) =>
    usualOfferFor(m, buildUsualIndex(meals, now: at ?? now),
        now: at ?? now, lookupTakesIt: lookupTakesIt, choices: choices);

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
  group('buildUsualIndex (T28)', () {
    UsualRecord? rec(List<Meal> meals, String name, {DateTime? at}) =>
        buildUsualIndex(meals, now: at ?? now).records[usualNameKey(name)];

    test('the latest by user.at wins, not the latest meal', () {
      final older = meal(1, [
        mine('Oatmeal', [380, 12, 50, 14], at: '2026-11-05T08:00:00.000Z')
      ], date: '2026-11-02', corrected: true);
      final newer = meal(2, [
        mine('Oatmeal', [340, 12, 50, 14], at: '2026-11-01T08:00:00.000Z')
      ], date: '2026-11-06', corrected: true);
      final r = rec([newer, older], 'Oatmeal')!;
      expect(r.mealId, 1);
      expect(r.numbers.kcal, 380);
      expect(r.at, DateTime.utc(2026, 11, 5, 8));
    });

    test('day 90 is in and day 91 is out (calendar days, DST-safe)', () {
      // 23:30 on Nov 2 2026, the day after US DST ended: under
      // TZ=America/Chicago, Duration(days: 89) lands on Aug 6 and drops
      // day 90 (Aug 5). The window is counted in calendar days.
      final late = DateTime(2026, 11, 2, 23, 30);
      expect(usualWindowStart(late), '2026-08-05');
      Meal on(int id, String date, String name) => meal(
          id, [mine(name, [350, 12, 50, 14], at: '${date}T08:00:00.000Z')],
          date: date, corrected: true);
      final index = buildUsualIndex(
          [on(1, '2026-08-05', 'Oatmeal'), on(2, '2026-08-04', 'Granola')],
          now: late);
      expect(index.records.containsKey('oatmeal'), isTrue);
      expect(index.records.containsKey('granola'), isFalse);
      expect(usualWindowStart(now), '2026-08-10');
    });

    test('not sources: published items, leftover meals, untrusted marks, '
        'void marks, qty-2 rows', () {
      final published = meal(1, [
        {...mine('Burrito bowl', [1050, 50, 110, 40]), 'published': true}
      ], date: '2026-11-03', corrected: true);
      final leftover = meal(2, [mine('Fried rice', [600, 12, 80, 20])],
          date: '2026-11-03', corrected: true,
          extra: {'leftover': {'original': {}}});
      // P9: a valid mark on an uncorrected photo meal is a model's claim.
      final untrusted = meal(3, [mine('Latte', [190, 8, 18, 9])],
          date: '2026-11-03', source: MealSource.appWatch);
      // P7: the numbers moved under the mark (a lookup, a deduction).
      final voided = meal(4, [
        item('Bagel', 290, p: 11, c: 56, f: 2, user: mark([250, 9, 48, 1]))
      ], date: '2026-11-03', corrected: true);
      // P1: a qty-2 correction says nothing about one.
      final twice = meal(5, [mine('Taco', [340, 14, 30, 18], qty: 2)],
          date: '2026-11-03', corrected: true);
      final index = buildUsualIndex(
          [published, leftover, untrusted, voided, twice],
          now: now);
      expect(index.records, isEmpty);
    });

    test('sources: hand-typed unmarked items, and describe-preview marks', () {
      final manual = meal(1, [item('Toast with jam', 210, p: 5, c: 38, f: 4)],
          date: '2026-11-04', source: MealSource.appManual);
      final manualPhoto = meal(2, [item('Dal', 320, p: 16, c: 40, f: 9)],
          date: '2026-11-04', source: MealSource.appManualPhoto);
      final described = meal(3, [mine('Green tea latte', [180, 6, 26, 5])],
          date: '2026-11-04', source: MealSource.manualText);
      // An unmarked item of a model's meal is not the user's.
      final model = meal(4, [item('Pho', 450)],
          date: '2026-11-04', source: MealSource.manualText);
      final index = buildUsualIndex(
          [manual, manualPhoto, described, model],
          now: now);
      expect(index.records.keys.toSet(),
          {'jam toast', 'dal', 'green latte tea'});
      final t = index.records['jam toast']!;
      expect(t.numbers, (kcal: 210, p: 5, c: 38, f: 4));
      expect(t.at, DateTime.parse('2026-11-04T08:00:00.000'),
          reason: 'an unmarked hand-typed row dates from the meal');
    });

    test('a hand-typed meal fixed by chat teaches only its marked rows', () {
      // A chat fix keeps the source and drops every mark, and the text
      // model re-estimated every item: its unmarked rows are not yours.
      final chatFixed = meal(1, [
        item('Oatmeal', 520, p: 18, c: 80, f: 16),
        item('Banana', 105, p: 1, c: 27, f: 0),
      ], date: '2026-11-04', source: MealSource.appManual, corrected: true);
      final chatFixedPhoto = meal(2, [item('Dal', 320, p: 16, c: 40, f: 9)],
          date: '2026-11-04',
          source: MealSource.appManualPhoto,
          corrected: true);
      // An editor save of such a meal marks the rows the user set.
      final edited = meal(3, [mine('Toast with jam', [210, 5, 38, 4])],
          date: '2026-11-04', source: MealSource.appManual, corrected: true);
      final index =
          buildUsualIndex([chatFixed, chatFixedPhoto, edited], now: now);
      expect(index.records.keys.toSet(), {'jam toast'});
    });

    test('a row under 10 kcal is no record, so it never shadows or re-logs',
        () {
      // A blank row on a new hand-typed meal is stored unmarked as 0/0/0/0;
      // a marked 5 kcal row is under the offer minimum too.
      final blank = meal(1, [item('Toast', 0, p: 0, c: 0, f: 0)],
          date: '2026-11-04', source: MealSource.appManual);
      final tiny = meal(2, [mine('Black coffee', [5, 0, 1, 0])],
          date: '2026-11-04', corrected: true);
      expect(buildUsualIndex([blank, tiny], now: now).records, isEmpty);
      // The user's real toast from earlier still stands behind the blank.
      final real = meal(3, [mine('Toast', [120, 4, 20, 2])],
          date: '2026-11-02', corrected: true);
      final r = buildUsualIndex([real, blank], now: now).records['toast']!;
      expect((r.mealId, r.numbers.kcal), (3, 120));
    });

    test('kcal-only at kcal >= 50 with zero macros (P8)', () {
      final index = buildUsualIndex([
        meal(1, [item('Cola', 140, p: 0, c: 0, f: 0)],
            date: '2026-11-04', source: MealSource.appManual),
        meal(2, [item('Gum', 49, p: 0, c: 0, f: 0)],
            date: '2026-11-04', source: MealSource.appManual),
        meal(3, [item('Juice', 120, p: 0, c: 28, f: 0)],
            date: '2026-11-04', source: MealSource.appManual),
      ], now: now);
      expect(index.records['cola']!.kcalOnly, isTrue);
      expect(index.records['gum']!.kcalOnly, isFalse);
      expect(index.records['juice']!.kcalOnly, isFalse);
    });

    test('the record portion is the AI name\'s guess', () {
      final r = rec([
        learned(
            it: mine('Overnight oats', [350, 12, 50, 14],
                aiName: 'Oatmeal (~250 g)'))
      ], 'Overnight oats')!;
      expect(r.portion, const UsualPortion(UsualPortionKind.mass, 250));
      expect(r.aiName, 'Oatmeal (~250 g)');
    });
  });

  group('aliases (T28b)', () {
    Map<String, dynamic> renamed() => mine('Overnight oats', [350, 12, 50, 14],
        aiName: 'Oatmeal (~250 g)');

    test('one rename gives no match through ai_name', () {
      expect(offer([learned(it: renamed()), photo()], photo()), isNull);
    });

    test('the same rename on 2 meals gives a match flagged viaAlias', () {
      final a = learned(id: 1, it: renamed());
      final b = meal(3, [renamed()],
          date: '2026-11-04', source: MealSource.appPhoto, corrected: true);
      final o = offer([a, b, photo()], photo())!;
      expect(o.items.single.viaAlias, isTrue);
      expect(o.items.single.learnedName, 'Overnight oats');
      expect(o.items.single.name, 'Oatmeal');
      expect(o.items.single.mine, (kcal: 350, p: 12, c: 50, f: 14));
      expect(buildUsualIndex([a, b], now: now).aliases,
          {'oatmeal': 'oat overnight'});
    });

    test('the newer of the direct record and the alias target wins', () {
      final a = learned(id: 1, it: renamed());
      final b = meal(3, [renamed()],
          date: '2026-11-04', source: MealSource.appPhoto, corrected: true);
      // This morning's Use through the alias wrote the user's 350 on an
      // AI-named row: a direct record under "oatmeal".
      final used = meal(4, [
        mine('Oatmeal (~260 g)', [350, 12, 50, 14],
            at: '2026-11-07T13:00:00.000Z')
      ], time: '07:00 AM', source: MealSource.appWatch, corrected: true);
      // Later today the user sets new numbers for their overnight oats.
      final newer = meal(5, [
        mine('Overnight oats', [420, 14, 60, 16],
            at: '2026-11-07T19:30:00.000Z', aiName: 'Oatmeal (~250 g)')
      ], time: '01:30 PM', source: MealSource.appPhoto, corrected: true);
      final p = photo(id: 6);
      final o = offer([a, b, used, newer, p], p)!;
      expect(
          (
            mine: o.items.single.mine.kcal,
            learned: o.items.single.learnedName,
            viaAlias: o.items.single.viaAlias,
          ),
          (mine: 420, learned: 'Overnight oats', viaAlias: true));
      // And a direct record newer than the alias target still wins.
      final usedLater = meal(4, [
        mine('Oatmeal (~260 g)', [380, 12, 50, 14],
            at: '2026-11-07T20:00:00.000Z')
      ], time: '07:00 AM', source: MealSource.appWatch, corrected: true);
      final o2 = offer([a, b, usedLater, newer, p], p)!;
      expect((o2.items.single.mine.kcal, o2.items.single.viaAlias),
          (380, false));
    });

    test('one rename plus its re-log confirms no alias', () {
      // P4/D24: a re-log copies the rename it was logged from; it is not a
      // second rename.
      final typed = meal(1, [item('Overnight oats', 350, p: 12, c: 50, f: 14)],
          date: '2026-11-02', source: MealSource.appManual);
      final renamedOnce = meal(2, [renamed()],
          date: '2026-11-03', source: MealSource.appPhoto, corrected: true);
      final index = buildUsualIndex([typed, renamedOnce], now: now);
      final row = usualMealList(index,
              now: now, choices: UsualChoicesView.empty)
          .more
          .single;
      expect(row.template.id, 2);
      final relog = Meal(
          id: 3,
          date: today,
          time: '12:30 PM',
          timestamp: '${today}T12:30:00.000',
          source: MealSource.appRepeat,
          analysis: usualLogAnalysis(row, index, now: now));
      expect(
          ((relog.analysis['food_items'] as List).single as Map)['user']
              ['ai_name'],
          'Oatmeal (~250 g)',
          reason: 'the re-log carries the rename');
      expect(buildUsualIndex([typed, renamedOnce, relog], now: now).aliases,
          isEmpty);
      expect(offer([typed, renamedOnce, relog, photo()], photo()), isNull,
          reason: 'no alias, so the AI-named photo gets nothing');
    });

    test('an AI name renamed to two foods twice each gives no alias', () {
      Meal m(int id, String name, String date) => meal(
          id,
          [mine(name, [350, 12, 50, 14], aiName: 'Oatmeal (~250 g)')],
          date: date,
          source: MealSource.appPhoto,
          corrected: true);
      final meals = [
        m(1, 'Overnight oats', '2026-11-01'),
        m(3, 'Overnight oats', '2026-11-02'),
        m(4, 'Porridge', '2026-11-03'),
        m(5, 'Porridge', '2026-11-04'),
      ];
      expect(buildUsualIndex(meals, now: now).aliases, isEmpty);
      expect(offer([...meals, photo()], photo()), isNull);
    });
  });

  group('usualOfferFor (T29)', () {
    test('the base fixture gets an offer', () {
      final o = offer([learned(), photo()], photo())!;
      expect(o.mealId, 2);
      final it = o.items.single;
      expect(it.index, 0);
      expect(it.key, 'oatmeal');
      expect(it.ai, (kcal: 300, p: 10, c: 54, f: 6));
      expect(it.mine, (kcal: 350, p: 12, c: 50, f: 14));
      expect(it.kcalOnly, isFalse);
      expect(it.viaAlias, isFalse);
      expect(it.fromMealId, 1);
      expect(it.fromDate, '2026-11-03');
      expect(it.mineAt, DateTime.utc(2026, 11, 3, 8));
      expect(o.beforeKcal, 300);
      expect(o.afterKcal, 350);
    });

    group('meal gates', () {
      UsualOffer? flipped(Meal m,
              {bool lookupTakesIt = false,
              UsualChoicesView choices = UsualChoicesView.empty}) =>
          offer([learned(), m], m,
              lookupTakesIt: lookupTakesIt, choices: choices);
      Meal with_(Map<String, dynamic> a, {String? source, String? date,
              bool corrected = false}) =>
          Meal(
              id: 2,
              date: date ?? today,
              time: '07:40 AM',
              timestamp: '${today}T07:40:00.000',
              source: source ?? MealSource.appWatch,
              corrected: corrected,
              analysis: {...photo().analysis, ...a});

      test('1. a photo source (app_photo or app_watch)', () {
        expect(flipped(with_({}, source: MealSource.appPhoto)), isNotNull);
        for (final s in [
          MealSource.appManual,
          MealSource.appManualPhoto,
          MealSource.manualText,
          MealSource.appRepeat,
        ]) {
          expect(flipped(with_({}, source: s)), isNull, reason: s);
        }
      });
      test('2. dated today', () {
        expect(flipped(with_({}, date: '2026-11-06')), isNull);
      });
      test('3. not corrected', () {
        expect(flipped(with_({}, corrected: true)), isNull);
      });
      test('4. a food meal', () {
        expect(flipped(with_({'is_food': false})), isNull);
      });
      test('5. no leftover block', () {
        expect(flipped(with_({'leftover': {'original': {}}})), isNull);
      });
      test('6. a whole plate (or no portion state)', () {
        expect(flipped(with_({'portion_state': 'partial'})), isNull);
        expect(flipped(with_({'portion_state': 'shared'})), isNull);
        expect(flipped(with_({'portion_state': null})), isNotNull);
      });
      test('7. not a high-confidence estimate', () {
        expect(flipped(with_({'estimate_confidence': 'high'})), isNull);
        expect(flipped(with_({'estimate_confidence': 'low'})), isNotNull);
      });
      test('8. not a meal the restaurant lookup takes', () {
        expect(flipped(photo(), lookupTakesIt: true), isNull);
      });
      test('9. no live applied or suggested assist block', () {
        final block = {
          'v': kAssistVersion,
          'status': 'suggested',
          'matches': [
            {
              'item_index': 0,
              'before': {
                'estimated_calories': 300,
                'protein_g': 10,
                'carbs_g': 54,
                'fat_g': 6,
              },
            }
          ],
        };
        final live = with_({'assist': block});
        expect(assistStampValid(live.analysis), isTrue);
        expect(flipped(live), isNull);
        // A stale block (the numbers moved since) does not hold the meal.
        final stale = with_({
          'assist': {
            ...block,
            'matches': [
              {
                'item_index': 0,
                'before': {'estimated_calories': 280},
              }
            ],
          }
        });
        expect(assistStampValid(stale.analysis), isFalse);
        expect(flipped(stale), isNotNull);
      });
      test('10. no chain merchant', () {
        expect(flipped(with_({'order_merchant': 'Chipotle'})), isNull);
        expect(flipped(with_({'order_merchant': 'Joe\'s Diner'})), isNotNull);
      });
      test('11. not declined', () {
        final declined = UsualChoicesView(declined: [
          UsualDecline(
              mealId: 2, hideId: usualHideId('oatmeal'), at: now),
        ]);
        expect(flipped(photo(), choices: declined), isNull);
        final other = UsualChoicesView(declined: [
          UsualDecline(
              mealId: 9, hideId: usualHideId('oatmeal'), at: now),
        ]);
        expect(flipped(photo(), choices: other), isNotNull);
      });
    });

    group('item gates', () {
      test('1. a key with a record from another meal', () {
        expect(offer([learned(), photo(it: item('Snack', 300))],
            photo(it: item('Snack', 300))), isNull);
        expect(offer([learned(), photo(it: item('Granola', 300))],
            photo(it: item('Granola', 300))), isNull);
        // Numbers learned only from this same meal are never offered back.
        final self = learned(id: 2);
        expect(
            usualOfferFor(photo(), buildUsualIndex([self], now: now),
                now: now,
                lookupTakesIt: false,
                choices: UsualChoicesView.empty),
            isNull);
      });
      test('2. not muted', () {
        UsualDecline d(int m, DateTime at) =>
            UsualDecline(mealId: m, hideId: usualHideId('oatmeal'), at: at);
        final after = DateTime.utc(2026, 11, 4);
        expect(
            offer([learned(), photo()], photo(),
                choices: UsualChoicesView(declined: [d(5, after), d(6, after)])),
            isNull);
        expect(
            offer([learned(), photo()], photo(),
                choices: UsualChoicesView(declined: [d(5, after)])),
            isNotNull,
            reason: 'one decline does not mute');
      });
      test('3. no chain brand on the item', () {
        final branded =
            photo(it: item('Oatmeal (~260 g)', 300, extra: {'brand': 'Starbucks'}));
        expect(offer([learned(), branded], branded), isNull);
        final local = photo(
            it: item('Oatmeal (~260 g)', 300, extra: {'brand': 'Mom\'s'}));
        expect(offer([learned(), local], local), isNotNull);
      });
      test('4. not published', () {
        final p = photo(
            it: item('Oatmeal (~260 g)', 300, extra: {'published': true}));
        expect(offer([learned(), p], p), isNull);
      });
      test('5. qty 1', () {
        final two = photo(it: item('Oatmeal (~260 g)', 300, qty: 2));
        expect(offer([learned(), two], two), isNull);
      });
      test('6. compatible portions: a 250 g record, a 500 g photo', () {
        final big = photo(it: item('Oatmeal (~500 g)', 300));
        expect(offer([learned(), big], big), isNull);
      });
      test('7. both kcal at least 10', () {
        // Isolated from the other gates: a 6 g protein difference.
        Meal rec(List<num> n) => learned(it: mine('Black coffee', n));
        final cup = photo(it: item('Black coffee', 9, p: 0, c: 0, f: 0));
        expect(offer([rec([9, 6, 0, 0]), cup], cup), isNull);
        final cup12 = photo(it: item('Black coffee', 12, p: 0, c: 0, f: 0));
        expect(offer([rec([8, 6, 0, 0]), cup12], cup12), isNull);
        expect(offer([rec([12, 6, 0, 0]), cup12], cup12), isNotNull);
      });
      test('8. the ratio within 0.4-2.5', () {
        Meal rec(num k) => learned(it: mine('Oatmeal (~250 g)', [k, 12, 50, 14]));
        expect(offer([rec(760), photo()], photo()), isNull);
        expect(offer([rec(740), photo()], photo()), isNotNull);
        expect(offer([rec(110), photo()], photo()), isNull);
        expect(offer([rec(130), photo()], photo()), isNotNull);
      });
      test('9. a difference worth a tap', () {
        Meal rec(List<num> n) => learned(it: mine('Oatmeal (~250 g)', n));
        // max(20, 10% of 300) = 30 kcal.
        expect(offer([rec([329, 10, 54, 6]), photo()], photo()), isNull);
        expect(offer([rec([330, 10, 54, 6]), photo()], photo()), isNotNull);
        // Or a 5 g macro.
        expect(offer([rec([300, 14.9, 54, 6]), photo()], photo()), isNull);
        expect(offer([rec([300, 15, 54, 6]), photo()], photo()), isNotNull);
      });
    });

    test('a qty-2 corrected row gives no offer on a qty-1 photo (P1)', () {
      final two = learned(it: mine('Oatmeal (~250 g)', [700, 24, 100, 28], qty: 2));
      expect(offer([two, photo()], photo()), isNull);
    });

    test('a kcal-only record keeps the AI macros and ignores a 25 g carb '
        'difference (P8)', () {
      final cola = learned(it: mine('Oatmeal (~250 g)', [350, 0, 0, 0]));
      final o = offer([cola, photo()], photo())!;
      expect(o.items.single.kcalOnly, isTrue);
      expect(o.items.single.mine, (kcal: 350, p: 10, c: 54, f: 6));
      final close = learned(it: mine('Oatmeal (~250 g)', [310, 0, 0, 0]));
      final carbs = photo(it: item('Oatmeal (~260 g)', 300, c: 25));
      expect(offer([close, carbs], carbs), isNull,
          reason: 'a 10 kcal difference, and the macro trigger is off');
    });

    test('macroOnly: offered on a macro difference alone, kcal under the '
        'threshold', () {
      // 305 vs 300 kcal is under max(20, 10 %); protein 25 vs 10 g is not.
      final macro = offer([
        learned(it: mine('Oatmeal (~250 g)', [305, 25, 30, 6])),
        photo(),
      ], photo())!;
      expect(macro.items.single.macroOnly, isTrue);
      expect(offer([learned(), photo()], photo())!.items.single.macroOnly,
          isFalse);
      // The kcal threshold is the gate's own: 30 kcal on a 300 kcal item.
      final edge = offer([
        learned(it: mine('Oatmeal (~250 g)', [330, 25, 30, 6])),
        photo(),
      ], photo())!;
      expect(edge.items.single.macroOnly, isFalse);
      final under = offer([
        learned(it: mine('Oatmeal (~250 g)', [329, 25, 30, 6])),
        photo(),
      ], photo())!;
      expect(under.items.single.macroOnly, isTrue);
    });

    test('several items are offered together, indices from safeFoodItems', () {
      final both = meal(1, [
        mine('Oatmeal (~250 g)', [350, 12, 50, 14]),
        mine('Latte', [190, 8, 18, 9]),
      ], date: '2026-11-03', source: MealSource.appPhoto, corrected: true);
      final p = Meal(
          id: 2,
          date: today,
          time: '07:40 AM',
          timestamp: '${today}T07:40:00.000',
          source: MealSource.appWatch,
          analysis: {
            ...photo().analysis,
            'total_calories': 450,
            'food_items': [
              'not a map',
              item('Latte', 150, p: 8, c: 18, f: 9),
              item('Toast', 100),
              item('Oatmeal (~260 g)', 300),
            ],
          });
      final o = offer([both, p], p)!;
      expect([for (final i in o.items) i.index], [0, 2]);
      expect(o.afterKcal, 450 + 40 + 50);
    });
  });

  group('applyUsualOffer and revertUsualOffer (T30)', () {
    final at = DateTime.utc(2026, 11, 7, 18, 30, 1, 250);
    Meal mismatched() => Meal(
        id: 2,
        date: today,
        time: '07:40 AM',
        timestamp: '${today}T07:40:00.000',
        source: MealSource.appWatch,
        analysis: {
          ...photo().analysis,
          'total_calories': 420, // the items sum to 400
          'total_protein_g': 15.04,
          'food_items': [
            item('Oatmeal (~260 g)', 300,
                user: {'ai_name': 'Porridge', 'qty': 1}),
            item('Banana', 100, p: 1, c: 27, f: 0, extra: {'brand': ''}),
          ],
          'notes': 'kept',
        });

    test('afterKcal is the stored total plus the deltas', () {
      final o = offer([learned(), mismatched()], mismatched())!;
      expect(o.beforeKcal, 420);
      expect(o.afterKcal, 470);
    });

    test('Use writes the numbers, the mark and the moved totals', () {
      final m = mismatched();
      final o = offer([learned(), m], m)!;
      final out = applyUsualOffer(m.analysis, o, now: at)!;
      final items = out['food_items'] as List;
      expect(items[0], {
        'name': 'Oatmeal (~260 g)',
        'estimated_calories': 350,
        'protein_g': 12,
        'carbs_g': 50,
        'fat_g': 14,
        'user': {
          'set': true,
          'at': '2026-11-07T18:30:01.250Z',
          'n': [350, 12, 50, 14],
          'qty': 1,
          'ai_name': 'Porridge',
        },
      });
      expect(items[1], (m.analysis['food_items'] as List)[1]);
      expect(out['total_calories'], o.afterKcal);
      expect(out['total_protein_g'], 17);
      expect(out['total_carbs_g'], 50);
      expect(out['total_fat_g'], 14);
      expect(out['notes'], 'kept');
      expect(out['meal_description'], 'Breakfast');
      expect(usualMarkValid(items[0], at), isTrue);
      expect((m.analysis['food_items'] as List)[0]['estimated_calories'], 300,
          reason: 'the input is never edited in place');
    });

    test('a kcal-only record changes only kcal, and writes no set mark', () {
      // Updated on purpose (fix D2): a set mark here vouched for the AI's
      // macros as the user's, so the next record was no longer kcal-only
      // and those macros were offered later. Like the kcal-only re-log,
      // Use keeps only what vouches for no number.
      final m = photo();
      final o = offer([learned(it: mine('Oatmeal (~250 g)', [350, 0, 0, 0])), m],
          m)!;
      final out = applyUsualOffer(m.analysis, o, now: at)!;
      final it = (out['food_items'] as List).single as Map;
      expect(it['estimated_calories'], 350);
      expect([it['protein_g'], it['carbs_g'], it['fat_g']], [10, 54, 6]);
      expect(it.containsKey('user'), isFalse);
      expect(out['total_protein_g'], 10);
      final undo = UsualUndo(before: m.analysis, after: out, indices: [0]);
      expect(revertUsualOffer(out, undo), m.analysis);
    });

    test('a kcal-only Use keeps the AI\'s old name, with no set', () {
      final m = mismatched();
      final o = offer([learned(it: mine('Oatmeal (~250 g)', [350, 0, 0, 0])), m],
          m)!;
      expect(o.items.single.kcalOnly, isTrue);
      final out = applyUsualOffer(m.analysis, o, now: at)!;
      final it = (out['food_items'] as List)[0] as Map;
      expect(it['estimated_calories'], 350);
      expect(it['user'], {'qty': 1, 'ai_name': 'Porridge'});
      expect(usualMarkValid(it, at), isFalse);
    });

    test('null on a leftover meal, or once the shown AI numbers moved', () {
      final m = photo();
      final o = offer([learned(), m], m)!;
      expect(
          applyUsualOffer({...m.analysis, 'leftover': {'original': {}}}, o,
              now: at),
          isNull);
      final moved = {
        ...m.analysis,
        'food_items': [item('Oatmeal (~260 g)', 310)],
      };
      expect(applyUsualOffer(moved, o, now: at), isNull);
    });

    test('revert restores exactly, and is null once an item changed', () {
      final m = mismatched();
      final o = offer([learned(), m], m)!;
      final after = applyUsualOffer(m.analysis, o, now: at)!;
      final undo = UsualUndo(
          before: m.analysis, after: after, indices: [0]);
      final back = revertUsualOffer(after, undo)!;
      expect(back, m.analysis);

      final edited = {
        ...after,
        'food_items': [
          {...(after['food_items'] as List)[0] as Map, 'estimated_calories': 360},
          (after['food_items'] as List)[1],
        ],
      };
      expect(revertUsualOffer(edited, undo), isNull);
      final remarked = {
        ...after,
        'food_items': [
          {
            ...(after['food_items'] as List)[0] as Map,
            'user': mark([350, 12, 50, 14], at: '2026-11-07T19:00:00.000Z'),
          },
          (after['food_items'] as List)[1],
        ],
      };
      expect(revertUsualOffer(remarked, undo), isNull,
          reason: 'a newer mark is a newer edit');
    });

    test('revert moves the totals back by the delta once they changed', () {
      final m = mismatched();
      final o = offer([learned(), m], m)!;
      final after = applyUsualOffer(m.analysis, o, now: at)!;
      final undo = UsualUndo(before: m.analysis, after: after, indices: [0]);
      final back = revertUsualOffer({...after, 'total_calories': 500}, undo)!;
      expect(back['total_calories'], 450);
      expect((back['food_items'] as List)[0],
          (m.analysis['food_items'] as List)[0]);
    });
  });
  group('My usual foods: keys and ranking (T37)', () {
    Meal logged(int id, String title, String food, String date, String time,
            {String source = MealSource.appWatch}) =>
        meal(id, [item(food, 300)],
            date: date, time: time, description: title, source: source);

    test('usualMealKey: the sorted multiset of item keys', () {
      final index = buildUsualIndex(const [], now: now);
      Map<String, dynamic> a(List<Map<String, dynamic>> items,
              {String desc = 'Breakfast'}) =>
          {'is_food': true, 'meal_description': desc, 'food_items': items};
      expect(usualMealKey(a([item('Latte', 1), item('Toast', 1)]), index),
          usualMealKey(a([item('Toast', 1), item('Latte', 1)]), index));
      expect(usualMealKey(a([item('Egg', 1), item('Egg', 1)]), index),
          'egg + egg');
      expect(usualMealKey(a([item('Egg', 1)]), index), 'egg');
      expect(usualMealKey(a([], desc: 'Green smoothie'), index),
          'd:green smoothie');
      expect(usualMealKey(a([item('Latte', 1), item('Snack', 1)]), index),
          isNull,
          reason: 'any item without a key: never listed');
      expect(usualMealKey(a([], desc: 'Meal'), index), isNull);
    });

    test('listed on 2 distinct days, not 2 meals; [燕麦粥, 茶] is listed', () {
      final meals = [
        logged(1, 'Pancakes', 'Pancakes', '2026-11-06', '08:00 AM'),
        logged(2, 'Pancakes', 'Pancakes', '2026-11-06', '10:00 AM'),
        meal(3, [item('燕麦粥', 200), item('茶', 5)],
            date: '2026-11-01', description: '早餐'),
        meal(4, [item('茶', 5), item('燕麦粥（约300克）', 200)],
            date: '2026-11-02', description: '早餐'),
      ];
      final list = usualMealList(buildUsualIndex(meals, now: now),
          now: now, choices: UsualChoicesView.empty);
      final rows = [...list.around, ...list.more];
      expect([for (final r in rows) r.title], ['早餐']);
      expect(rows.single.days90, 2);
      expect(rows.single.template.id, 4, reason: 'the most recent');
    });

    test('Around this time first (circular clock), then More by days in 30, '
        'days in 90, recency and title', () {
      final at = DateTime(2026, 11, 7, 0, 15);
      var id = 0;
      List<Meal> on(String title, String food, List<String> dates,
              String time) =>
          [for (final d in dates) logged(++id, title, food, d, time)];
      final meals = [
        ...on('Midnight noodles', 'Instant noodles',
            ['2026-11-06', '2026-11-05', '2026-11-04'], '12:00 AM'),
        // 23:30 is 45 minutes from 00:15 across midnight (M13).
        ...on('Snack mix', 'Trail mix', ['2026-11-05', '2026-11-03'],
            '11:30 PM'),
        ...on('Late tea', 'Chamomile tea', ['2026-11-01', '2026-10-30'],
            '01:00 AM'),
        logged(++id, 'Hot cocoa', 'Hot cocoa', '2026-11-06', '11:45 PM'),
        logged(++id, 'Hot cocoa', 'Hot cocoa', '2026-11-02', '08:00 AM'),
        ...on('Oatmeal', 'Oatmeal', ['2026-11-06', '2026-11-05', '2026-11-04'],
            '07:40 AM'),
        ...on('Bagel', 'Bagel', ['2026-10-20', '2026-10-21'], '08:00 AM'),
        ...on('Latte', 'Latte', ['2026-10-20', '2026-09-01', '2026-08-20'],
            '03:10 PM'),
        ...on('Rice', 'Rice', ['2026-11-06', '2026-09-30'], '12:00 PM'),
        ...on('Soup', 'Soup', ['2026-10-30', '2026-09-29'], '12:00 PM'),
        ...on('Banana', 'Banana', ['2026-10-25', '2026-08-15'], '10:00 AM'),
        ...on('Apple', 'Apple', ['2026-10-25', '2026-08-15'], '10:00 AM'),
        // Aug 9 is day 91: one day in the window, not listed.
        ...on('Kale', 'Kale', ['2026-08-09', '2026-11-01'], '06:00 PM'),
      ];
      final list = usualMealList(buildUsualIndex(meals, now: at),
          now: at, choices: UsualChoicesView.empty);
      expect([for (final r in list.around) r.title],
          ['Midnight noodles', 'Snack mix', 'Late tea']);
      expect([for (final r in list.more) r.title], [
        'Oatmeal',
        'Hot cocoa',
        'Bagel',
        'Latte',
        'Rice',
        'Soup',
        'Apple',
        'Banana',
      ]);
      final cocoa = list.more[1];
      expect((cocoa.days30, cocoa.days90, cocoa.aroundDays), (2, 2, 1));
      expect((cocoa.lastDate, cocoa.lastTime), ('2026-11-06', '11:45 PM'));
      expect(cocoa.loggedTodayTime, isNull);
    });

    test('at most 20 rows; hidden keys are left out and counted', () {
      final meals = [
        for (var i = 0; i < 25; i++) ...[
          logged(2 * i + 1, 'Granola $i', 'Granola $i', '2026-11-05',
              '09:00 AM'),
          logged(2 * i + 2, 'Granola $i', 'Granola $i', '2026-11-06',
              '09:00 AM'),
        ],
      ];
      final index = buildUsualIndex(meals, now: now);
      final all = usualMealList(index,
          now: now, choices: UsualChoicesView.empty);
      expect(all.around.length + all.more.length, kUsualListMax);
      expect(all.hiddenCount, 0);
      final hide = all.more.first;
      final choices = UsualChoicesView(hidden: {hide.hideId});
      final some = usualMealList(index, now: now, choices: choices);
      final titles = [for (final r in [...some.around, ...some.more]) r.title];
      expect(titles, isNot(contains(hide.title)));
      expect(titles, hasLength(kUsualListMax));
      expect(some.hiddenCount, 1);
      expect([for (final m in usualHiddenMeals(index, now: now, choices: choices))
        m.title], [hide.title]);
      expect(hide.hideId, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('a hidden meal stays hidden when an alias is confirmed later', () {
      Meal oats(int id, String date) => meal(
          id, [item('Oatmeal (~260 g)', 300)],
          date: date, description: 'Oatmeal');
      Meal renamed(int id, String date) => meal(
          id,
          [
            mine('Overnight oats', [350, 12, 50, 14],
                at: '${date}T14:00:00.000Z', aiName: 'Oatmeal (~250 g)')
          ],
          date: date,
          time: '08:00 AM',
          source: MealSource.appPhoto,
          corrected: true,
          description: 'Overnight oats');
      final before = [oats(1, '2026-11-01'), oats(2, '2026-11-05')];
      final i1 = buildUsualIndex(before, now: now);
      final row = usualMealList(i1, now: now, choices: UsualChoicesView.empty)
          .more
          .single;
      final hidden = UsualChoicesView(hidden: {row.hideId});
      expect(usualMealList(i1, now: now, choices: hidden).isEmpty, isTrue);
      // Later the same rename on two meals confirms oatmeal -> overnight
      // oats, and the hidden group merges into a new meal key.
      final after = [
        ...before,
        renamed(3, '2026-11-02'),
        renamed(4, '2026-11-03'),
      ];
      final i2 = buildUsualIndex(after, now: now);
      expect(i2.aliases, {'oatmeal': 'oat overnight'});
      final list = usualMealList(i2, now: now, choices: hidden);
      final sheet = usualHiddenMeals(i2, now: now, choices: hidden);
      expect([for (final m in [...list.around, ...list.more]) m.title],
          isEmpty,
          reason: 'the hidden Oatmeal row came back under a new key');
      expect((hiddenCount: list.hiddenCount, sheet: sheet.length),
          (hiddenCount: 1, sheet: 1),
          reason: 'the count and the Hidden foods sheet agree');
      expect(sheet.single.mergedHideIds, {row.hideId});
      // With no alias a row merges nothing.
      expect(row.mergedHideIds, isEmpty);
    });

    test('"Logged today at" comes from today\'s latest log', () {
      final meals = [
        logged(1, 'Latte', 'Latte', '2026-11-05', '08:00 AM'),
        logged(2, 'Latte', 'Latte', today, '07:15 AM'),
        logged(3, 'Latte', 'Latte', today, '09:05 AM'),
      ];
      final row = usualMealList(buildUsualIndex(meals, now: now),
              now: now, choices: UsualChoicesView.empty)
          .more
          .single;
      expect(row.loggedTodayTime, '09:05 AM');
      expect(row.days90, 2);
    });

    test('realistic AI name drift across 10 days (a measurement)', () {
      // Ten watcher photos of the same breakfast, named as models do.
      // Listing rate on this fixture: 5 of the 10 breakfasts share the
      // one listed row ("blueberry oatmeal"); the other five each name a
      // set of their own (fresh / bowl / topped / honey / oats) and are
      // logged once, so they are not listed. A miss is safe: the row is
      // still offered, on 5 days instead of 10.
      const names = [
        'Oatmeal with blueberries (~300 g)',
        'Blueberry oatmeal (~250 g)',
        'Oatmeal with fresh blueberries',
        'Bowl of oatmeal with blueberries',
        'Oatmeal with blueberries',
        'Blueberry oatmeal',
        'Oatmeal topped with blueberries (~280 g)',
        'Oatmeal with blueberries and honey',
        'Blueberry oatmeal (~300 g)',
        'Oats with blueberries',
      ];
      final meals = [
        for (var i = 0; i < names.length; i++)
          meal(i + 1, [item(names[i], 320)],
              date: '2026-10-${(20 + i).toString().padLeft(2, '0')}',
              description: names[i]),
      ];
      final list = usualMealList(buildUsualIndex(meals, now: now),
          now: now, choices: UsualChoicesView.empty);
      final rows = [...list.around, ...list.more];
      expect(rows, hasLength(1));
      expect(rows.single.key, 'blueberry oatmeal');
      expect(rows.single.days90, 5);
    });
  });

  group('usualLogAnalysis: numbers and marks (T38)', () {
    UsualMeal rowOf(List<Meal> meals, {DateTime? at}) {
      final list = usualMealList(buildUsualIndex(meals, now: at ?? now),
          now: at ?? now, choices: UsualChoicesView.empty);
      return [...list.around, ...list.more].single;
    }

    Map<String, dynamic> logOf(List<Meal> meals, {DateTime? at}) =>
        usualLogAnalysis(rowOf(meals, at: at),
            buildUsualIndex(meals, now: at ?? now), now: at ?? now);

    test('the template is the most recent meal without a leftover block', () {
      final meals = [
        meal(1, [item('Fried rice', 600)], date: '2026-11-04'),
        meal(2, [item('Fried rice', 650)],
            date: '2026-11-05',
            extra: {'leftover': {'original': {}}}),
      ];
      final row = rowOf(meals);
      expect(row.template.id, 1);
      expect(row.days90, 2, reason: 'a deducted meal still counts');
      expect(row.lastDate, '2026-11-05');
      expect(row.numbers.kcal, 600);
    });

    test('learned numbers and the mark (original at) replace a qty-1 item '
        'with compatible portions', () {
      final meals = [
        learned(),
        meal(5, [item('Oatmeal (~260 g)', 300)], date: '2026-11-04'),
        meal(6, [item('Oatmeal (~260 g)', 300)], date: '2026-11-05'),
      ];
      final out = logOf(meals);
      expect((out['food_items'] as List).single, {
        'name': 'Oatmeal (~260 g)',
        'estimated_calories': 350,
        'protein_g': 12,
        'carbs_g': 50,
        'fat_g': 14,
        'user': {
          'set': true,
          'at': '2026-11-03T08:00:00.000Z',
          'n': [350, 12, 50, 14],
          'qty': 1,
        },
      });
      expect(out['total_calories'], 350);
      final row = rowOf(meals);
      expect(row.numbers, (kcal: 350, p: 12, c: 50, f: 14),
          reason: 'the row shows what a log writes');
    });

    test('no replacement for a qty-2 item or an incompatible portion', () {
      final two = logOf([
        learned(),
        meal(5, [item('Oatmeal', 600, qty: 2)], date: '2026-11-04'),
        meal(6, [item('Oatmeal', 600, qty: 2)], date: '2026-11-05'),
      ]);
      final it = (two['food_items'] as List).single as Map;
      expect(it['estimated_calories'], 600);
      expect(it['qty'], 2);
      final big = logOf([
        learned(),
        meal(5, [item('Oatmeal (~500 g)', 520)], date: '2026-11-04'),
        meal(6, [item('Oatmeal (~500 g)', 520)], date: '2026-11-05'),
      ]);
      expect((big['food_items'] as List).single['estimated_calories'], 520);
    });

    test('a qty-2 item round-trips through two re-logs unchanged', () {
      // The user set a count-2 row by hand (its qty lives in the mark).
      final set2 = {
        'name': 'Tacos',
        'estimated_calories': 680,
        'protein_g': 28,
        'carbs_g': 60,
        'fat_g': 36,
        'unit': 'piece',
        'user': mark([680, 28, 60, 36], qty: 2),
      };
      var meals = <Meal>[
        meal(1, [set2], date: '2026-11-04', corrected: true),
        meal(2, [set2], date: '2026-11-05', corrected: true),
      ];
      Map<String, dynamic>? first;
      for (var round = 0; round < 2; round++) {
        final at = DateTime(2026, 11, 7, 12, round);
        final out = logOf(meals, at: at);
        first ??= out;
        final it = (out['food_items'] as List).single as Map;
        expect(it['estimated_calories'], 680);
        expect(it['qty'], 2);
        expect(it['unit'], 'piece');
        expect(usualItemQty(it), 2);
        expect((it['user'] as Map)['at'], '2026-11-03T08:00:00.000Z',
            reason: 'the original at');
        meals = [
          ...meals,
          Meal(
              id: 10 + round,
              date: today,
              time: '12:0$round PM',
              timestamp: at.toIso8601String(),
              source: MealSource.appRepeat,
              analysis: out),
        ];
      }
      expect(usualMealKey(first!, buildUsualIndex(meals, now: now)), 'taco');
    });

    test('a mark from an untrusted template is not copied', () {
      final forged = item('Latte', 190, p: 8, c: 18, f: 9,
          user: mark([190, 8, 18, 9], aiName: 'Coffee'));
      final out = logOf([
        meal(1, [forged], date: '2026-11-04'),
        meal(2, [forged], date: '2026-11-05'),
      ]);
      final it = (out['food_items'] as List).single as Map;
      expect(it['user'], {'ai_name': 'Coffee'},
          reason: 'a photo meal never edited: only the no-number parts');
      expect(it['estimated_calories'], 190);
    });

    test('a kcal-only substitution writes no set', () {
      final out = logOf([
        meal(1, [mine('Cola', [140, 0, 0, 0])],
            date: '2026-11-03', corrected: true),
        meal(5, [item('Cola', 150, p: 0, c: 39, f: 0)], date: '2026-11-04'),
        meal(6, [item('Cola', 150, p: 0, c: 39, f: 0)], date: '2026-11-05'),
      ]);
      final it = (out['food_items'] as List).single as Map;
      expect(it['estimated_calories'], 140);
      expect(it['carbs_g'], 39, reason: "the template's macros");
      expect(it.containsKey('user'), isFalse);
    });

    test('an AI-named row matched through an alias keeps its group key', () {
      Meal renamed(int id, String date) => meal(id, [
            mine('Overnight oats', [350, 12, 50, 14],
                aiName: 'Oatmeal (~250 g)')
          ], date: date, source: MealSource.appPhoto, corrected: true);
      final meals = [
        renamed(1, '2026-11-01'),
        renamed(2, '2026-11-02'),
        meal(5, [item('Oatmeal (~260 g)', 300)], date: '2026-11-05'),
      ];
      final index = buildUsualIndex(meals, now: now);
      final row = usualMealList(index,
              now: now, choices: UsualChoicesView.empty)
          .more
          .single;
      expect(row.key, 'oat overnight');
      expect(row.days90, 3);
      final out = usualLogAnalysis(row, index, now: now);
      expect(usualMealKey(out, index), row.key);
    });
  });

  group('usualLogAnalysis: the whitelist (T39)', () {
    UsualMeal rowFor(Meal template) => UsualMeal(
        key: 'k',
        title: 't',
        template: template,
        days90: 2,
        days30: 2,
        aroundDays: 0,
        lastDate: template.date,
        lastTime: template.time,
        loggedTodayTime: null,
        numbers: (kcal: 0, p: 0, c: 0, f: 0));
    final empty = buildUsualIndex(const [], now: now);

    test('exactly the listed keys; everything else is left behind', () {
      final template = Meal(
          id: 1,
          date: '2026-11-05',
          time: '12:00 PM',
          timestamp: '2026-11-05T12:00:00.000',
          source: MealSource.appPhoto,
          imageHash: 'a' * 32,
          fileId: 'asset-1',
          analysis: {
            'is_food': 'yes',
            'meal_description': 'Burrito bowl',
            'total_calories': 9999,
            'capture': {'shutter_key': 'b' * 16},
            'assist': {'v': kAssistVersion, 'status': 'applied'},
            'leftover': {'original': {}},
            'image_hash': 'c' * 32,
            'restaurant_context': 'restaurant',
            'estimate_confidence': 'low',
            'portion_state': 'whole',
            'order_merchant': 'Chipotle',
            'confidence_note': 'n',
            'food_items': [
              {
                'name': 'Burrito bowl',
                'estimated_calories': 25000,
                'protein_g': 2500,
                'carbs_g': -5,
                'fat_g': '40',
                'qty': 2,
                'unit': ' bowl ',
                'brand': 'Chipotle',
                'published': true,
                'leftover_left_fraction': 0.5,
                'is_drink': false,
              },
              {'name': 'Chips', 'estimated_calories': 100.4, 'unit': ''},
            ],
          });
      final out = usualLogAnalysis(rowFor(template), empty,
          now: DateTime.utc(2026, 11, 7, 18, 0, 1, 5));
      expect(out.keys.toSet(), {
        'is_food',
        'meal_description',
        'food_items',
        'total_calories',
        'total_protein_g',
        'total_carbs_g',
        'total_fat_g',
        'logged_again',
      });
      expect(out['is_food'], isTrue);
      expect(out['logged_again'], '2026-11-07T18:00:01.005Z');
      final items = out['food_items'] as List;
      expect(items[0], {
        'name': 'Burrito bowl',
        'estimated_calories': 20000,
        'protein_g': 2000,
        'carbs_g': 0,
        'fat_g': 0,
        'qty': 2,
        'unit': 'bowl',
      });
      expect(items[1], {
        'name': 'Chips',
        'estimated_calories': 100.4,
        'protein_g': 0,
        'carbs_g': 0,
        'fat_g': 0,
      });
      expect(out['total_calories'], 20100, reason: 'the item sums, whole');
      expect(out['total_protein_g'], 2000);
      final text = out.toString();
      for (final gone in ['capture', 'assist', 'published', 'leftover',
          'brand', 'image_hash', 'Chipotle', 'restaurant_context']) {
        expect(text.contains(gone), isFalse, reason: gone);
      }
    });

    test('at most 40 items; no items keeps the template totals', () {
      Meal t(List<Map<String, dynamic>> items, {num total = 500}) => Meal(
          id: 1,
          date: '2026-11-05',
          time: '12:00 PM',
          timestamp: '2026-11-05T12:00:00.000',
          source: MealSource.appManual,
          analysis: {
            'is_food': true,
            'meal_description': 'Tapas',
            'total_calories': total,
            'total_protein_g': 21.26,
            'food_items': items,
          });
      final many = usualLogAnalysis(
          rowFor(t([for (var i = 0; i < 45; i++) item('Olive $i', 10)])),
          empty,
          now: now);
      expect(many['food_items'], hasLength(40));
      expect(many['total_calories'], 400);
      final none = usualLogAnalysis(rowFor(t(const [])), empty, now: now);
      expect(none['food_items'], isEmpty);
      expect(none['total_calories'], 500);
      expect(none['total_protein_g'], 21.3);
      expect(none['total_carbs_g'], 0);
    });
  });

  group('usualLooselyShares (P12)', () {
    Map<String, dynamic> a(List<String> names, {String desc = 'x'}) => {
          'meal_description': desc,
          'food_items': [for (final n in names) item(n, 100)],
        };
    test('reworded pairs meet', () {
      expect(
          usualLooselyShares(a(['Steel-cut oats with berries (~250 g)']),
              a(['Blueberry oatmeal'])),
          isTrue);
      expect(usualLooselyShares(a(['2 eggs']), a(['Eggs'])), isTrue);
      expect(usualLooselyShares(a(['燕麦粥']), a(['蓝莓燕麦片'])), isTrue);
      expect(usualLooselyShares(a(['粥']), a(['皮蛋瘦肉粥'])), isTrue,
          reason: 'one token set inside the other');
      expect(usualLooselyShares(a(['Pb']), a(['Pb and j'])), isTrue);
      expect(usualLooselyShares(a([], desc: 'Green smoothie'),
          a(['Smoothie bowl'])), isTrue);
    });
    test('different foods do not', () {
      expect(usualLooselyShares(a(['Steak']), a(['Iced tea'])), isFalse);
      expect(usualLooselyShares(a(['牛肉面']), a(['鸡蛋'])), isFalse);
      expect(usualLooselyShares(a(['Ham']), a(['Banana'])), isFalse);
      expect(usualLooselyShares(a(['燕麦粥']), a(['白粥'])), isFalse,
          reason: 'one shared CJK character is not enough');
    });
  });
}
