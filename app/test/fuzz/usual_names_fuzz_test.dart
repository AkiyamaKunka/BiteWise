// Fuzz: usual-foods name keys and portions (usual-foods spec §3.2, D29,
// D30a; core/usual_foods_logic.dart).
//
// Seeded-random names from mixed alphabets — Latin words, CJK, digits,
// units, brackets, emoji, combining marks, right-to-left text, full-width
// forms, lone surrogates, very long and empty strings, and things that
// are not strings at all — are thrown at usualNameKey, usualNameTokens,
// usualDisplayName, usualPortion, usualPortionsCompatible and
// usualLooselyShares. A failure prints the seed of its case and the
// input cut down to what still fails.
import 'dart:math';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fuzz_support.dart';

// ─── Alphabets ─────────────────────────────────────────────────────────

const List<String> _latin = [
  'Oatmeal', 'oats', 'blueberries', 'Blueberry', 'latte', 'milk', 'oat', //
  'eggs', 'egg', 'scrambled', 'toast', 'chicken', 'salad', 'Caesar', //
  'sandwich', 'sandwiches', 'fries', 'fry', 'glass', 'glasses', 'boxes', //
  'dishes', 'berry', 'berries', 'pho', 'beef', 'Greek', 'yogurt', 'rice', //
  'side', 'large', 'small', 'Pb', 'x', 'ab', 'JALAPEÑO', 'café', 'crème', //
  'brûlée', 'naïve', 'Müsli', 'smörgåsbord', 'Straße', 'ins', 'ons', //
  'thes', 'snack', 'Snacks', 'food', 'meal', 'drink', 'item', 'unknown', //
  'dish', "farmer's", 'stir-fry', 'half&half', 'PB+J',
];

const List<String> _stops = [
  'a', 'an', 'the', 'The', 'and', 'AND', 'with', 'of', 'on', 'in', '&', //
  '+', '的', '配', '与', '及',
];

const List<String> _cjk = [
  '燕麦粥', '蓝莓', '米饭', '牛肉面', '番茄炒蛋', '小笼包', '和牛', '汉堡', //
  '粥', '茶', '牛奶', '奶牛', '零食', '餐', '菜', '食物', '饮料', '东西', //
  'ラーメン', 'すし', '寿司', '김치', '비빔밥', '加州卷', '带鱼', '𠮷野家',
];

const List<String> _measures = [
  '2', '12', '0', '007', '3.5', '１２', '２', '½', '300 g', '250g', //
  '1.5 kg', '12 oz', '12 fl oz', '12 fl. oz', '350 ml', '1 L', '2 pcs', //
  '3 pieces', '2 slices', '６个', '约300克', '300克', '２００毫升', '1升', //
  '3片', '2块', '5只', '4颗', '2根', '3串', '~250 g', 'about 300 g', //
  '300 grapes', '0 g', '0.0 kg', '1e3 g', '999999999999999999999 g', //
  '1.2.3 g', '.5 g', '5. g', '3 liters', '2 kilograms', '８ ｏｚ',
];

const List<String> _brackets = [
  '(~300 g)', '(2 pcs)', '[2 slices]', '【约200克】', '（约300克）', //
  '（6个）', '(with milk)', '(large)', '[no sugar]', '【辣】', '(1)', //
  '((2))', '(a(1)b)', '[1(2]3)', '(', ')', '[', ']', '【', '】', '（', //
  '）', '()', '[]', '(~300 g', '300 g)', '【1', '2】',
];

const List<String> _emoji = [
  '🍜', '🥗', '🍳', '👩\u{200D}🍳', '🇺🇸', '👍🏽', '🍕🍕', '❤\u{FE0F}', //
  '#\u{FE0F}\u{20E3}', '🧑🏿\u{200D}🤝\u{200D}🧑🏻',
];

const List<String> _combining = [
  'e\u{301}',
  'a\u{308}\u{323}',
  'n\u{303}',
  'o\u{302}\u{301}\u{300}',
  '\u{301}', //
  'z\u{335}\u{321}\u{322}', 'A\u{30A}', '가', 'cafe\u{301}',
];

const List<String> _rtl = [
  'طعام', 'أرز بالدجاج', 'אוכל', 'חומוס', '\u{202E}olleh\u{202C}', //
  '\u{200F}abc', '٣٠٠ غ', '۳۰۰', 'שקשוקה (2)',
];

final List<String> _odd = [
  '\u0000', '\u{FEFF}', '\u{200B}', '\u{AD}', '\u{2028}', '\t', '\n', '\r\n', //
  '\u{3000}', '\u{A0}', '<b>', '&amp;', '%s', '\\', '"', "'", '’', '`', //
  '--', ';', 'NULL', 'null', 'NaN', '°', '85°C',
  String.fromCharCode(0xD800), // a lone high surrogate
  String.fromCharCode(0xDC00), // a lone low surrogate
  String.fromCharCode(0xFFFF),
];

const List<String> _spaces = [
  ' ',
  '\t',
  '\n',
  '\u{3000}',
  '\u{A0}',
  '\u{2003}',
];

const List<(int, int)> _ranges = [
  (0x20, 0x7E), (0xA0, 0xFF), (0x100, 0x17F), (0x300, 0x36F), //
  (0x590, 0x6FF), (0x3040, 0x30FF), (0x4E00, 0x4E80), (0xAC00, 0xAC40), //
  (0xFF00, 0xFFEF), (0xD800, 0xDFFF), (0xE000, 0xE010), (0x1F300, 0x1F9FF), //
  (0x20000, 0x20040), (0x2000, 0x206F),
];

String _randomRunes(Random r, int n) {
  final out = StringBuffer();
  for (var i = 0; i < n; i++) {
    final (lo, hi) = r.pick(_ranges);
    out.writeCharCode(r.between(lo, hi));
  }
  return out.toString();
}

String _long(Random r) {
  final n = r.pick(const [300, 1200, 2000]);
  return switch (r.nextInt(8)) {
    0 => 'a' * n,
    1 => '燕' * n,
    2 => '(1' * n,
    3 => '1' * n,
    4 => '(${'1' * n}',
    5 => 'ab ' * n,
    6 => '🍜' * n,
    _ => 'Oatmeal ${'9' * 400} g ${'x' * n}',
  };
}

/// Any name a model, an import or a keyboard could produce.
String wildName(Random r) {
  switch (r.nextInt(24)) {
    case 0:
      return '';
    case 1:
      return [for (var i = r.between(1, 5); i > 0; i--) r.pick(_spaces)].join();
    case 2:
      return _long(r);
    case 3:
      return _randomRunes(r, r.between(1, 40));
  }
  final atoms = <String>[];
  for (var i = r.between(1, 7); i > 0; i--) {
    atoms.add(switch (r.nextInt(16)) {
      0 || 1 || 2 || 3 || 4 => r.pick(_latin),
      5 || 6 => r.pick(_cjk),
      7 || 8 => r.pick(_measures),
      9 || 10 => r.pick(_brackets),
      11 => r.pick(_stops),
      12 => r.pick(_emoji),
      13 => r.pick(_combining),
      14 => r.pick(_rtl),
      _ => r.pick(_odd),
    });
    atoms.add(r.pick(const ['', ' ', ' ', ' ', '  ', '\t', ', ', '-', '/']));
  }
  return atoms.join();
}

/// A name, or (one time in eight) something that is not a string.
Object? wildValue(Random r) => r.chance(0.125)
    ? r.pick(<Object?>[
        null, 0, 42, -1.5, double.nan, true, false, //
        ['Oatmeal'], {'name': 'Oatmeal'}, #oatmeal, 3.0,
      ])
    : wildName(r);

String _show(Object? v) => v is String ? '"${escaped(v)}"' : '<$v>';

/// Cuts a failing string down, code point by code point.
Object? _shrinkValue(Object? v, bool Function(Object?) fails) {
  if (v is! String) return v;
  final runes = shrinkList(
    v.runes.toList(),
    (rs) => fails(String.fromCharCodes(rs)),
  );
  return String.fromCharCodes(runes);
}

bool _cjkRune(int r) =>
    (r >= 0x3040 && r <= 0x30FF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0xAC00 && r <= 0xD7AF) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0x20000 && r <= 0x2FA1F);

final RegExp _latinToken = RegExp(r'^[a-z0-9]+$');

const Set<String> _stopTokens = {
  'a', 'an', 'the', 'and', 'with', 'of', 'on', 'in', '的', '配', '与', '及', //
};

// ─── Names whose parts can be moved around ─────────────────────────────

const List<String> _cleanWords = [
  'Oatmeal', 'blueberries', 'latte', 'milk', 'oat', 'eggs', 'scrambled', //
  'toast', 'chicken', 'salad', 'sandwich', 'fries', 'pho', 'beef', 'rice', //
  'side', 'large', 'JALAPEÑO', 'café', 'crème', 'brûlée', 'stir-fry', //
  "farmer's", 'Pb', 'x', 'snack', 'food', 'meal', 'Straße', 'thes', 'ins',
];

const List<String> _cleanCjk = [
  '燕麦粥', '蓝莓', '米饭', '牛肉面', '和牛', '汉堡', '粥', '零食', '餐', //
  'ラーメン', '김치',
];

/// Whole bracketed groups: with a digit they are cut from the key, without
/// one their words stay. Each is balanced, so moving it changes nothing.
const List<String> _cleanGroups = [
  '(~300 g)', '(2 pcs)', '[2 slices]', '【约200克】', '（约300克）', //
  '（6个）', '(with milk)', '(large)', '【辣】', '[no sugar]',
];

const List<String> _cleanSeparators = [
  ' ', ' ', '  ', '\t', '\u{3000}', '\u{A0}', ', ', ' / ', '-', '·', '\n', //
  ' \t ',
];

List<String> cleanParts(Random r) => [
  for (var i = r.between(1, 6); i > 0; i--)
    switch (r.nextInt(10)) {
      0 || 1 || 2 || 3 || 4 => r.pick(_cleanWords),
      5 || 6 => r.pick(_cleanCjk),
      7 => r.pick(const ['2', '12', '3']),
      _ => r.pick(_cleanGroups),
    },
];

String _flipCase(Random r, String s) {
  final out = StringBuffer();
  for (final c in s.runes) {
    final upper = c >= 0x41 && c <= 0x5A;
    final lower = c >= 0x61 && c <= 0x7A;
    if ((upper || lower) && r.nextBool()) {
      out.writeCharCode(upper ? c + 32 : c - 32);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// ASCII letters and digits as their full-width forms (ＡＢＣ１２３), which
/// NFKC folds back.
String _fullWidth(Random r, String s) {
  final out = StringBuffer();
  for (final c in s.runes) {
    final alnum =
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A);
    out.writeCharCode(alnum && r.chance(0.5) ? c + 0xFEE0 : c);
  }
  return out.toString();
}

String _join(Random r, List<String> parts) {
  final out = StringBuffer(r.chance(0.3) ? r.pick(_cleanSeparators) : '');
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) out.write(r.pick(_cleanSeparators));
    out.write(parts[i]);
  }
  if (r.chance(0.3)) out.write(r.pick(_cleanSeparators));
  return out.toString();
}

// ─── Portions with a known reading ─────────────────────────────────────

const List<(String, UsualPortionKind, double)> _units = [
  ('g', UsualPortionKind.mass, 1), ('G', UsualPortionKind.mass, 1), //
  ('grams', UsualPortionKind.mass, 1), ('gram', UsualPortionKind.mass, 1), //
  ('kg', UsualPortionKind.mass, 1000), ('Kg', UsualPortionKind.mass, 1000), //
  ('kilograms', UsualPortionKind.mass, 1000), //
  ('oz', UsualPortionKind.mass, 28.35), ('OZ', UsualPortionKind.mass, 28.35), //
  ('ounces', UsualPortionKind.mass, 28.35), //
  ('克', UsualPortionKind.mass, 1), ('千克', UsualPortionKind.mass, 1000), //
  ('公斤', UsualPortionKind.mass, 1000), //
  ('ml', UsualPortionKind.volume, 1), ('ML', UsualPortionKind.volume, 1), //
  ('milliliters', UsualPortionKind.volume, 1), //
  ('l', UsualPortionKind.volume, 1000), ('L', UsualPortionKind.volume, 1000), //
  ('liters', UsualPortionKind.volume, 1000), //
  ('litre', UsualPortionKind.volume, 1000), //
  ('fl oz', UsualPortionKind.volume, 29.57), //
  ('fl. oz', UsualPortionKind.volume, 29.57), //
  ('FL OZ', UsualPortionKind.volume, 29.57), //
  ('毫升', UsualPortionKind.volume, 1), ('升', UsualPortionKind.volume, 1000), //
  ('pc', UsualPortionKind.count, 1), ('pcs', UsualPortionKind.count, 1), //
  ('piece', UsualPortionKind.count, 1),
  ('pieces', UsualPortionKind.count, 1), //
  ('slice', UsualPortionKind.count, 1),
  ('slices', UsualPortionKind.count, 1), //
  ('个', UsualPortionKind.count, 1), ('片', UsualPortionKind.count, 1), //
  ('块', UsualPortionKind.count, 1), ('只', UsualPortionKind.count, 1), //
  ('颗', UsualPortionKind.count, 1), ('根', UsualPortionKind.count, 1), //
  ('串', UsualPortionKind.count, 1),
];

/// Foods with no digit and no unit word of their own.
const List<String> _plainFoods = [
  'Oatmeal',
  'Chicken salad',
  'Latte',
  '米饭',
  '小笼包',
  'Toast',
  'Beef pho',
];

UsualPortion? _anyPortion(Random r) => switch (r.nextInt(8)) {
  0 => null,
  1 => UsualPortion(
    r.pick(UsualPortionKind.values),
    r.pick(const [0.0, -5.0, double.nan, double.infinity, 1e300]),
  ),
  _ => UsualPortion(
    r.pick(UsualPortionKind.values),
    r.pick(const [1.0, 2.0, 6.0, 100.0, 250.0, 300.0, 325.0, 500.0]) *
        r.pick(const [1.0, 1.0, 1.29, 1.31, 2.0, 0.5]),
  ),
};

// ─── Analyses for the loose "logged it already?" test ──────────────────

const List<String> _looseNames = [
  'Oatmeal', 'Steel-cut oats with berries', 'Blueberry oatmeal', //
  'Oat milk latte', 'Latte', '番茄炒蛋', '炒蛋', '蛋', 'Snack', 'Pb', '', //
  '   ', '🍜', 'Scrambled eggs (2 pcs)', 'Egg', '(1)', 'the',
];

Map<String, dynamic> _looseAnalysis(Random r) {
  Object? name() => r.chance(0.75) ? r.pick(_looseNames) : wildValue(r);
  final n = r.pick(const [0, 0, 1, 1, 1, 2, 3]);
  return {
    'meal_description': name(),
    'food_items': r.chance(0.05)
        ? r.pick(<Object?>[null, 'x', 5, <String, dynamic>{}])
        : [
            for (var i = 0; i < n; i++)
              r.chance(0.1)
                  ? r.pick(<Object?>[null, 3, 'str', <Object?>[]])
                  : <String, dynamic>{'name': name()},
          ],
  };
}

/// The token sets usualLooselyShares compares (its documented contract):
/// one per item with any token, or the description's with no items.
List<Set<String>> _looseTokens(Map<String, dynamic> a) {
  final raw = a['food_items'];
  final items = raw is List ? raw.whereType<Map>().toList() : const <Map>[];
  if (items.isEmpty) {
    final d = usualNameTokens(a['meal_description']);
    return d.isEmpty ? const [] : [d];
  }
  return [
    for (final it in items)
      if (usualNameTokens(it['name']).isNotEmpty) usualNameTokens(it['name']),
  ];
}

void main() {
  const seed = 20261109;

  test('nothing throws, and every answer has its documented shape '
      '(4000 names)', () {
    forAll<Object?>(
      seed: seed,
      cases: 4000,
      gen: wildValue,
      show: _show,
      shrink: _shrinkValue,
      check: (x) {
        final tokens = usualNameTokens(x);
        final key = usualNameKey(x);
        final display = usualDisplayName(x);
        final portion = usualPortion(x);
        if (x is! String) {
          expect(tokens, isEmpty);
          expect(key, isNull);
          expect(display, '');
          expect(portion, isNull);
          return;
        }
        for (final t in tokens) {
          final oneCjk = t.runes.length == 1 && _cjkRune(t.runes.first);
          expect(
            oneCjk || _latinToken.hasMatch(t),
            isTrue,
            reason:
                'token "${escaped(t)}" is neither a-z0-9 nor one CJK '
                'character',
          );
        }
        if (key != null) {
          expect(tokens, isNotEmpty);
          expect(
            key,
            (tokens.toList()..sort()).join(' '),
            reason: 'a key is its sorted tokens',
          );
          expect(
            tokens.any(
              (t) =>
                  _cjkRune(t.runes.first) ||
                  t.replaceAll(RegExp('[0-9]'), '').length >= 3,
            ),
            isTrue,
            reason: 'a key needs a CJK token or 3 Latin letters',
          );
        }
        expect(usualNameKey(x), key, reason: 'the same name, the same key');
        expect(usualNameTokens(x), tokens);
        expect(display.runes.length, lessThanOrEqualTo(40));
        expect(display, display.trim());
        expect(
          display.runes.any((c) => c < 0x20 || (c >= 0x7F && c <= 0x9F)),
          isFalse,
          reason: 'a control character on screen',
        );
        if (portion != null) {
          expect(
            portion.value.isFinite && portion.value > 0,
            isTrue,
            reason: '$portion',
          );
        }
      },
    );
  });

  test('a key is stable: asked twice it is the same, and the key of a key '
      'is that key (3000 names)', () {
    var keys = 0;
    var throughStop = 0;
    forAll<Object?>(
      seed: seed + 10000,
      cases: 3000,
      gen: wildName,
      show: _show,
      shrink: _shrinkValue,
      check: (x) {
        final key = usualNameKey(x);
        expect(usualNameKey(x), key);
        if (key == null) return;
        keys++;
        // The one documented way a key is not its own key: a token that
        // singularizes INTO a stop word ("ins" → "in", "thes" → "the";
        // spec §3.2 drops stop words in step 3 and singularizes in step
        // 4). Reading the key again drops it.
        final stop = key.split(' ').any(_stopTokens.contains);
        if (stop) {
          throughStop++;
          final rest = key.split(' ').where((t) => !_stopTokens.contains(t));
          final again = usualNameKey(key);
          if (again != null) expect(again, rest.join(' '));
          return;
        }
        expect(usualNameKey(key), key, reason: 'the key of a key');
        expect(usualNameTokens(key), usualNameTokens(x));
      },
    );
    expect(keys, greaterThan(1500), reason: 'most names must give a key');
    expect(throughStop, lessThan(keys ~/ 10));
  });

  test('order, case, spacing, full-width forms, repeats and stop words do '
      'not change the key (3000 names)', () {
    var keyed = 0;
    forAll<int>(
      seed: seed + 20000,
      cases: 3000,
      gen: (r) => r.nextInt(1 << 31),
      show: (s) {
        final r = Random(s);
        final parts = cleanParts(r);
        return 'parts ${parts.map(escaped).toList()} (sub-seed $s)';
      },
      check: (s) {
        final r = Random(s);
        final parts = cleanParts(r);
        final base = parts.join(' ');
        final key = usualNameKey(base);
        if (key != null) keyed++;
        for (var v = 0; v < 4; v++) {
          var moved = List<String>.of(parts)..shuffle(r);
          if (r.chance(0.4)) moved = [...moved, r.pick(parts)]; // a repeat
          if (r.chance(0.4)) {
            moved.insert(r.nextInt(moved.length + 1), r.pick(_stops));
          }
          var name = _join(r, moved);
          if (r.chance(0.6)) name = _flipCase(r, name);
          if (r.chance(0.3)) name = _fullWidth(r, name);
          expect(
            usualNameKey(name),
            key,
            reason: 'variant "${escaped(name)}" of "${escaped(base)}"',
          );
          expect(usualNameTokens(name), usualNameTokens(base));
        }
      },
    );
    expect(keyed, greaterThan(2000));
  });

  test('a regular plural is the same food', () {
    const pairs = [
      ('egg', 'eggs'), ('fry', 'fries'), ('sandwich', 'sandwiches'), //
      ('box', 'boxes'), ('dish', 'dishes'), ('glass', 'glasses'), //
      ('berry', 'berries'), ('oat', 'oats'), ('noodle', 'noodles'),
    ];
    forAll<int>(
      seed: seed + 30000,
      cases: 300,
      gen: (r) => r.nextInt(1 << 31),
      check: (s) {
        final r = Random(s);
        final (one, many) = r.pick(pairs);
        final others = [
          for (var i = r.nextInt(3); i > 0; i--) r.pick(_cleanCjk),
        ];
        final a = ([...others, 'Fresh', one]..shuffle(r)).join(' ');
        final b = ([...others, 'fresh', many]..shuffle(r)).join(' ');
        expect(usualNameKey(a), isNotNull);
        expect(usualNameKey(a), usualNameKey(b), reason: '"$a" vs "$b"');
      },
    );
  });

  group('a name that names nothing', () {
    final now = DateTime(2026, 11, 7, 12, 30);
    const today = '2026-11-07';
    Map<String, dynamic> row(Object? name, num kcal, {bool marked = false}) => {
      'name': name,
      'estimated_calories': kcal,
      'protein_g': 10,
      'carbs_g': 40,
      'fat_g': 8,
      if (marked)
        'user': {
          'set': true,
          'at': '2026-11-03T08:00:00.000Z',
          'n': [kcal, 10, 40, 8],
          'qty': 1,
        },
    };
    Meal meal(
      int id,
      String date,
      String source,
      Map<String, dynamic> item, {
      bool corrected = false,
    }) => Meal(
      id: id,
      date: date,
      time: '07:40 AM',
      timestamp: '${date}T07:40:00.000',
      source: source,
      corrected: corrected,
      analysis: {
        'is_food': true,
        'meal_description': '',
        'total_calories': item['estimated_calories'],
        'food_items': [item],
      },
    );

    /// The user set 350 for [name] on two days; today's photo says 300.
    ({UsualIndex index, UsualOffer? offer, UsualList list}) scene(
      Object? name,
    ) {
      final meals = [
        meal(
          1,
          '2026-11-03',
          MealSource.appPhoto,
          row(name, 350, marked: true),
          corrected: true,
        ),
        meal(2, '2026-11-05', MealSource.appManual, row(name, 350)),
        meal(3, today, MealSource.appWatch, row(name, 300)),
      ];
      final index = buildUsualIndex(meals, now: now);
      return (
        index: index,
        offer: usualOfferFor(
          meals[2],
          index,
          now: now,
          lookupTakesIt: false,
          choices: UsualChoicesView.empty,
        ),
        list: usualMealList(index, now: now, choices: UsualChoicesView.empty),
      );
    }

    test('the scene works for a real name', () {
      final s = scene('Oatmeal');
      expect(s.index.records.keys, ['oatmeal']);
      expect(s.offer!.items.single.mine.kcal, 350);
      expect(s.list.more.single.key, 'oatmeal');
    });

    test('null, empty, blank, generic and too-short names give no key and '
        'are never learned, offered or listed', () {
      final nameless = <Object?>[
        null,
        '',
        ' ',
        '   ',
        '\t\n',
        '\u{3000}',
        '\u{A0}\u{2003}',
        '\u{200B}', //
        '🍜', '()', '(1)', '（约300克）', '!!!', '&', 'Pb', '2', '12 3', 'a', //
        'the', 'of the', 'Snack', 'snacks', 'FOOD', 'the meal', '零食', //
        '餐', '食物', '东西', 'ｓｎａｃｋ', 42, true, ['Oatmeal'], //
        {'name': 'Oatmeal'},
      ];
      for (final name in nameless) {
        final why = _show(name);
        expect(usualNameKey(name), isNull, reason: why);
        final s = scene(name);
        expect(s.index.records, isEmpty, reason: why);
        expect(s.index.groups, isEmpty, reason: why);
        expect(s.offer, isNull, reason: why);
        expect(s.list.isEmpty, isTrue, reason: why);
      }
    });

    test('names with no token at all never loosely share a food '
        '(2000 pairs)', () {
      const tokenless = <Object?>[
        null, '', '   ', '\t', '\u{3000}', '🍜', '()', '!!!', '&', 'the', //
        'with', '的', 7, true,
      ];
      forAll<int>(
        seed: seed + 40000,
        cases: 2000,
        gen: (r) => r.nextInt(1 << 31),
        check: (s) {
          final r = Random(s);
          final empty = <String, dynamic>{
            'meal_description': r.pick(tokenless),
            'food_items': [
              for (var i = r.nextInt(3); i > 0; i--)
                {'name': r.pick(tokenless)},
            ],
          };
          expect(_looseTokens(empty), isEmpty);
          final other = _looseAnalysis(r);
          expect(
            usualLooselyShares(empty, other),
            isFalse,
            reason: '${dump(empty)} vs ${dump(other)}',
          );
          expect(usualLooselyShares(other, empty), isFalse);
          expect(usualLooselyShares(empty, empty), isFalse);
        },
      );
    });
  });

  test('usualPortion reads a written amount and unit (3000 names)', () {
    forAll<int>(
      seed: seed + 50000,
      cases: 3000,
      gen: (r) => r.nextInt(1 << 31),
      check: (s) {
        final r = Random(s);
        final (unit, kind, factor) = r.pick(_units);
        final amount = r.chance(0.6)
            ? r.between(1, 999).toDouble()
            : r.between(1, 9999) / r.pick(const [4, 10, 100]);
        var text = amount == amount.roundToDouble()
            ? (r.nextBool() ? '${amount.round()}' : '$amount')
            : '$amount';
        if (r.chance(0.2)) text = _fullWidth(r, text);
        final food = r.pick(_plainFoods);
        final gap = r.pick(const ['', ' ', ' ', '  ']);
        final name = switch (r.nextInt(6)) {
          0 => '$food (~$text$gap$unit)',
          1 => '$food $text$gap$unit',
          2 => '$food（约$text$gap$unit）',
          3 => 'about $text$gap$unit $food',
          4 => '$food [$text$gap$unit] extra',
          _ => '$food, $text$gap$unit',
        };
        final p = usualPortion(name);
        expect(p, isNotNull, reason: '"${escaped(name)}"');
        expect(p!.kind, kind, reason: '"${escaped(name)}"');
        expect(
          p.value,
          closeTo(amount * factor, amount * factor * 1e-9),
          reason: '"${escaped(name)}"',
        );
        // The bracketed amount is no part of the key.
        if (name.contains('(') || name.contains('（') || name.contains('[')) {
          expect(
            usualNameKey(name),
            usualNameKey(name.contains('extra') ? '$food extra' : food),
            reason: '"${escaped(name)}"',
          );
        }
      },
    );
  });

  test('usualPortionsCompatible is symmetric, and never throws '
      '(4000 pairs)', () {
    var apart = 0;
    forAll<int>(
      seed: seed + 60000,
      cases: 4000,
      gen: (r) => r.nextInt(1 << 31),
      check: (s) {
        final r = Random(s);
        UsualPortion? one() =>
            r.chance(0.5) ? _anyPortion(r) : usualPortion(wildName(r));
        final a = one();
        final b = one();
        final ab = usualPortionsCompatible(a, b);
        expect(usualPortionsCompatible(b, a), ab, reason: '$a vs $b');
        if (!ab) apart++;
        if (a == null || b == null || a.kind != b.kind) {
          expect(ab, isTrue, reason: 'nothing to compare: $a vs $b');
        }
        if (a != null && a.value.isFinite && a.value > 0) {
          expect(usualPortionsCompatible(a, a), isTrue);
          final near = UsualPortion(a.kind, a.value * 1.25);
          final far = UsualPortion(a.kind, a.value * 1.35);
          expect(usualPortionsCompatible(a, near), isTrue);
          expect(usualPortionsCompatible(near, a), isTrue);
          expect(usualPortionsCompatible(a, far), isFalse);
          expect(usualPortionsCompatible(far, a), isFalse);
        }
      },
    );
    expect(apart, greaterThan(100), reason: 'some pairs must be apart');
  });

  test('usualLooselyShares is symmetric, and never throws (4000 pairs)', () {
    var shared = 0;
    forAll<int>(
      seed: seed + 70000,
      cases: 4000,
      gen: (r) => r.nextInt(1 << 31),
      show: (s) {
        final r = Random(s);
        return '${dump(_looseAnalysis(r))} vs ${dump(_looseAnalysis(r))}';
      },
      check: (s) {
        final r = Random(s);
        final a = _looseAnalysis(r);
        final b = _looseAnalysis(r);
        final ab = usualLooselyShares(a, b);
        expect(usualLooselyShares(b, a), ab);
        if (ab) shared++;
        // A meal with any named food shares it with itself.
        expect(usualLooselyShares(a, a), _looseTokens(a).isNotEmpty);
        // An identical Latin word of 3+ letters, or one item's tokens all
        // in another's, is always a yes.
        final xs = _looseTokens(a);
        final ys = _looseTokens(b);
        final sure = xs.any(
          (x) => ys.any(
            (y) =>
                x.containsAll(y) ||
                y.containsAll(x) ||
                x.any(
                  (t) =>
                      _latinToken.hasMatch(t) &&
                      t.replaceAll(RegExp('[0-9]'), '').length >= 3 &&
                      y.contains(t),
                ),
          ),
        );
        if (sure) expect(ab, isTrue);
        if (xs.isEmpty || ys.isEmpty) expect(ab, isFalse);
      },
    );
    expect(shared, greaterThan(400), reason: 'some pairs must share');
    expect(shared, lessThan(3600), reason: 'and some must not');
  });
}
