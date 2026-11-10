// Random meal histories and independent oracles for the usual-foods fuzz
// tests. Not a test file.
//
// The generator draws everything from one seeded Random: meals of all six
// sources over up to 120 days, corrected or not, items named from a small
// vocabulary (so their keys collide), numbers that include 0, negatives,
// strings, nulls, NaN and huge values, counts, and `user` marks that are
// valid, stale, forged (on a meal nobody curated), in the future or
// malformed, plus leftover blocks, assist blocks and published rows.
//
// The oracles restate the spec (§3.1-§3.3, §4.2) in their own words: what
// a valid mark is, which rows teach, which renames are confirmed. They
// share no helper with core/usual_foods_logic.dart except the name key,
// which usual_names_fuzz_test.dart tests on its own.
import 'dart:math';

import 'package:calorie_tracker/core/coerce.dart'
    show EstimateConfidence, PortionState, cleanShortText, mealContextFields;
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart'
    show assistStampValid, kAssistVersion;
import 'package:calorie_tracker/core/restaurant_lookup_contract.dart'
    show chainNameOnly, composeLookupItem, kLookupMerchantMax;
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/ui/meal_edit_logic.dart' show parseClock;

import 'fuzz_support.dart';

// ─── Vocabulary ────────────────────────────────────────────────────────

/// Foods, each as names that share ONE name key (a test pins this).
const List<List<String>> kFoods = [
  [
    'Oatmeal', 'Oatmeal (~250 g)', 'oatmeal (~300 g)', 'OATMEAL (~600 g)', //
    'Oatmeal (1 bowl)',
  ],
  [
    'Blueberry oatmeal (~250 g)', 'Oatmeal with blueberries (~300 g)', //
    'Blueberries & oatmeal',
  ],
  [
    'Oat milk latte', 'Oat milk latte (~350 ml)', //
    'Latte with oat milk (12 fl oz)', 'Oat milk latte (~800 ml)',
  ],
  ['Scrambled eggs', 'Scrambled eggs (2 pcs)', 'Scrambled egg (5 pcs)'],
  ['Toast', 'Toast (2 slices)', 'Toast (1 slice)'],
  ['Chicken salad', 'Chicken salad (~350 g)', 'Salad with chicken'],
  ['Banana', 'Bananas', 'Banana (1 pc)'],
  ['Greek yogurt', 'Greek yogurt (~170 g)'],
  ['米饭', '米饭（约200克）', '米饭（约500克）'],
  ['番茄炒蛋', '番茄炒蛋（约300克）'],
  ['小笼包', '小笼包（6个）', '小笼包（8个）'],
  ['粥'],
  ['Turkey sandwich', 'Turkey sandwiches'],
  ['Beef pho'],
  ['Protein bar'],
  ['Apple'],
  ['Pad thai'],
  ['Burrito bowl'],
  ['Iced americano'],
  ['Dark chocolate (20 g)', 'Dark chocolate'],
  ['Salmon with rice (~400 g)'],
  ['牛肉面'],
  ['Overnight oats'],
  ['Flat white'],
  ['Granola'],
  ['Peanut butter toast'],
  ['Miso soup'],
  ['Fried rice'],
  ['Cheese pizza (2 slices)', 'Cheese pizza'],
  ['Tofu stir fry'],
];

/// Names with no key, and things that are not names.
const List<Object?> kJunkNames = [
  'Snack', '零食', 'Meal', 'Pb', '', '   ', 'food', '2', '🍜', null, 42, //
  ['Oatmeal'],
];

const List<String> kSources = [
  MealSource.appWatch, MealSource.appWatch, MealSource.appWatch, //
  MealSource.appPhoto, MealSource.appPhoto, //
  MealSource.appManual, MealSource.appManual, MealSource.appManual, //
  MealSource.appManualPhoto, //
  MealSource.manualText, MealSource.manualText, //
  MealSource.appRepeat, MealSource.appRepeat, //
  'telegram', '',
];

/// Local clocks to build "now" from: plain days, both US daylight-saving
/// changes and the days after them, the EU ones, a year end, a leap day.
const List<(int, int, int)> kDays = [
  (2026, 11, 7), (2026, 11, 7), (2026, 11, 1), (2026, 11, 2), //
  (2027, 3, 14), (2027, 3, 15), (2027, 1, 1), (2026, 3, 1), //
  (2028, 2, 29), (2026, 12, 31), (2026, 10, 25), (2026, 3, 29),
];

DateTime anyNow(Random r) {
  final (y, m, d) = r.pick(kDays);
  final (h, mi) = r.chance(0.3)
      ? r.pick(const [(0, 0), (0, 5), (1, 30), (2, 30), (23, 55), (12, 0)])
      : (r.nextInt(24), r.nextInt(60));
  return DateTime(y, m, d, h, mi, r.nextInt(60), r.nextInt(1000));
}

String anyClock(Random r) {
  final h = r.between(1, 12);
  final m = r.nextInt(60);
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} '
      '${r.nextBool() ? 'AM' : 'PM'}';
}

// ─── The oracle's readings ─────────────────────────────────────────────

/// A stored number as every reader takes it: a finite number under 1e9 in
/// size, else 0.
num oNum(Object? v) {
  if (v is! num) return 0;
  if (v.isNaN || v.isInfinite) return 0;
  if (v <= -1e9 || v >= 1e9) return 0;
  return v;
}

typedef ONumbers = ({num kcal, num p, num c, num f});

ONumbers oNumbers(Object? item) {
  final m = item is Map ? item : const {};
  return (
    kcal: oNum(m['estimated_calories']),
    p: oNum(m['protein_g']),
    c: oNum(m['carbs_g']),
    f: oNum(m['fat_g']),
  );
}

/// Python truthiness, as is_food is read.
bool oTruthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// A count: a finite number in (0, 20], else 1.
num oCount(Object? v) {
  if (v is! num || v.isNaN || v.isInfinite || v <= 0 || v > 20) return 1;
  return v;
}

/// The item's count: the mark's when it is a count, else the row's.
num oQty(Object? item) {
  final m = item is Map ? item : const {};
  final user = m['user'];
  if (user is Map) {
    final q = user['qty'];
    if (q is num && !q.isNaN && !q.isInfinite && q > 0 && q <= 20) return q;
  }
  return oCount(m['qty']);
}

/// Spec §3.1 "Validity": `user` is a map with set == true, an `at` that
/// parses and is no later than now + 1 day, and `n` four finite numbers
/// within 0.5 kcal and 0.05 g of the item's numbers.
bool oMarkValid(Object? item, DateTime now) {
  if (item is! Map) return false;
  final user = item['user'];
  if (user is! Map) return false;
  if (user['set'] is! bool || user['set'] != true) return false;
  final at = user['at'];
  if (at is! String) return false;
  final when = DateTime.tryParse(at);
  if (when == null) return false;
  if (when.isAfter(now.add(const Duration(days: 1)))) return false;
  final n = user['n'];
  if (n is! List || n.length != 4) return false;
  for (final v in n) {
    if (v is! num || v.isNaN || v.isInfinite) return false;
  }
  final cur = oNumbers(item);
  if (((n[0] as num) - cur.kcal).abs() > 0.5) return false;
  if (((n[1] as num) - cur.p).abs() > 0.05) return false;
  if (((n[2] as num) - cur.c).abs() > 0.05) return false;
  if (((n[3] as num) - cur.f).abs() > 0.05) return false;
  return true;
}

const Set<String> _trustedSources = {
  'app_manual', 'app_manual_photo', 'manual_text', 'app_repeat', //
};

/// Spec §3.1 "Trusted meals".
bool oTrusted(Meal m) => m.corrected || _trustedSources.contains(m.source);

bool oPhoto(Meal m) => m.source == 'app_photo' || m.source == 'app_watch';

List<Map> oItems(Map analysis) {
  final raw = analysis['food_items'];
  return raw is List ? raw.whereType<Map>().toList() : const [];
}

int oClock(String time) {
  final c = parseClock(time);
  return c == null ? -1 : c.hour * 60 + c.minute;
}

/// One row that teaches the user's numbers (spec §3.1 "What counts as
/// yours").
final class Teach {
  Teach({
    required this.key,
    required this.name,
    required this.aiName,
    required this.meal,
    required this.itemIndex,
    required this.at,
    required this.atRaw,
    required this.numbers,
  });
  final String key;
  final String name;
  final String? aiName;
  final Meal meal;
  final int itemIndex;
  final DateTime at;

  /// [at] as stored: the mark's `at`, or the meal's timestamp.
  final String atRaw;
  final ONumbers numbers;

  bool get kcalOnly =>
      numbers.kcal >= 50 && numbers.p == 0 && numbers.c == 0 && numbers.f == 0;

  /// Later than [o]: by when the numbers were set, then the meal's place
  /// in the log, then the row.
  bool laterThan(Teach o) {
    var c = at.compareTo(o.at);
    if (c == 0) c = meal.date.compareTo(o.meal.date);
    if (c == 0) c = oClock(meal.time).compareTo(oClock(o.meal.time));
    if (c == 0) c = meal.id.compareTo(o.meal.id);
    if (c == 0) c = itemIndex.compareTo(o.itemIndex);
    return c > 0;
  }

  @override
  String toString() =>
      'Teach($key, meal ${meal.id}#$itemIndex, $numbers, '
      'at $at)';
}

/// Whether [m] is a food meal dated in the last 90 calendar days, today
/// included.
bool oInWindow(Meal m, DateTime now, {int days = 90}) =>
    m.date.compareTo(dayIso(now, -(days - 1))) >= 0 &&
    m.date.compareTo(dayIso(now, 0)) <= 0 &&
    oTruthy(m.analysis['is_food']);

/// Every row of [meals] that teaches, by the spec: on a food meal in the
/// window with no leftover block, not published, with a name key, and
/// either (a) a valid mark on a trusted meal or (b) no `user` map at all
/// on a hand-typed meal never corrected since, stamped no more than a day
/// ahead of the clock; count exactly 1 and at least 10 kcal.
List<Teach> oTeaching(List<Meal> meals, DateTime now) {
  final out = <Teach>[];
  for (final m in meals) {
    if (!oInWindow(m, now)) continue;
    if (m.analysis['leftover'] is Map) continue;
    final items = oItems(m.analysis);
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item['published'] == true) continue;
      final key = usualNameKey(item['name']);
      if (key == null) continue;
      final user = item['user'];
      ONumbers numbers;
      DateTime at;
      String atRaw;
      String? aiName;
      num qty;
      if (oMarkValid(item, now) && oTrusted(m)) {
        final n = (user as Map)['n'] as List;
        numbers = (
          kcal: n[0] as num,
          p: n[1] as num,
          c: n[2] as num,
          f: n[3] as num,
        );
        atRaw = user['at'] as String;
        at = DateTime.parse(atRaw);
        final raw = user['ai_name'];
        final clean = raw is String ? cleanShortText(raw, 80) : '';
        aiName = clean.isEmpty ? null : clean;
        qty = oQty(item);
      } else if ((m.source == 'app_manual' || m.source == 'app_manual_photo') &&
          !m.corrected &&
          user is! Map) {
        final stamp = DateTime.tryParse(m.timestamp);
        if (stamp == null) continue;
        // Like a mark's `at`: a timestamp more than a day ahead of the
        // clock teaches nothing yet.
        if (stamp.isAfter(now.add(const Duration(days: 1)))) continue;
        numbers = oNumbers(item);
        at = stamp;
        atRaw = m.timestamp;
        qty = oCount(item['qty']);
      } else {
        continue;
      }
      if (qty != 1) continue;
      if (numbers.kcal < 10) continue;
      out.add(
        Teach(
          key: key,
          name: cleanShortText(item['name'], 80),
          aiName: aiName,
          meal: m,
          itemIndex: i,
          at: at,
          atRaw: atRaw,
          numbers: numbers,
        ),
      );
    }
  }
  return out;
}

/// The latest teaching row per key.
Map<String, Teach> oLatest(List<Teach> rows) {
  final out = <String, Teach>{};
  for (final t in rows) {
    final held = out[t.key];
    if (held == null || t.laterThan(held)) out[t.key] = t;
  }
  return out;
}

/// Spec D24: the AI's name key → the user's name key, once the same
/// rename was made on 2 or more meals (re-logs do not count) and the AI's
/// name has no second target with 2 or more.
Map<String, String> oAliases(List<Teach> rows) {
  final renames = <String, Map<String, Set<int>>>{};
  for (final t in rows) {
    if (t.aiName == null || t.meal.source == 'app_repeat') continue;
    final aiKey = usualNameKey(t.aiName);
    if (aiKey == null || aiKey == t.key) continue;
    ((renames[aiKey] ??= {})[t.key] ??= {}).add(t.meal.id);
  }
  final out = <String, String>{};
  renames.forEach((aiKey, targets) {
    final confirmed = [
      for (final e in targets.entries)
        if (e.value.length >= 2) e.key,
    ];
    if (confirmed.length == 1) out[aiKey] = confirmed.single;
  });
  return out;
}

/// Spec §3.2 pass 2: an item's key in My usual foods — its own when the
/// user renamed the row, else read through a confirmed alias.
String? oCanonical(Object? item, Map<String, String> aliases) {
  final m = item is Map ? item : const {};
  final k = usualNameKey(m['name']);
  if (k == null) return null;
  final user = m['user'];
  final aiName = user is Map ? user['ai_name'] : null;
  if (aiName is String && aiName.trim().isNotEmpty) return k;
  return aliases[k] ?? k;
}

/// Spec §4.2 "Meal key".
String? oMealKey(Map analysis, Map<String, String> aliases) {
  final items = oItems(analysis);
  if (items.isEmpty) {
    final d = usualNameKey(analysis['meal_description']);
    return d == null ? null : 'd:$d';
  }
  final keys = <String>[];
  for (final it in items) {
    final k = oCanonical(it, aliases);
    if (k == null) return null;
    keys.add(k);
  }
  keys.sort();
  return keys.join(' + ');
}

// ─── Offers: the oracle (spec §3.3) ────────────────────────────────────

bool oLiveDecline(UsualDecline d, DateTime now) =>
    !d.at.isBefore(now.subtract(const Duration(days: 90)));

/// Spec D21: declined on 2 different meals, each later than the numbers.
bool oMuted(History h, String key, DateTime since) =>
    {
      for (final d in h.choices.declined)
        if (d.hideId == usualHideId(key) &&
            d.at.isAfter(since) &&
            oLiveDecline(d, h.now))
          d.mealId,
    }.length >=
    2;

/// Spec §3.3, meal gates 1-11.
bool oMealGates(History h, Meal meal) {
  final a = meal.analysis;
  if (!oPhoto(meal)) return false;
  if (meal.date != h.today) return false;
  if (meal.corrected) return false;
  if (!oTruthy(a['is_food'])) return false;
  if (a['leftover'] is Map) return false;
  final ctx = mealContextFields(a);
  if (ctx.portionState != null && ctx.portionState != PortionState.whole) {
    return false;
  }
  if (ctx.estimateConfidence == EstimateConfidence.high) return false;
  if (h.takes.contains(meal.id)) return false;
  final block = a['assist'];
  if (block is Map &&
      (block['status'] == 'applied' || block['status'] == 'suggested') &&
      assistStampValid(a)) {
    return false;
  }
  if (chainNameOnly(a['order_merchant'], kLookupMerchantMax).isNotEmpty) {
    return false;
  }
  if (h.choices.declined.any(
    (d) => d.mealId == meal.id && oLiveDecline(d, h.now),
  )) {
    return false;
  }
  return true;
}

typedef OPick = ({Teach row, bool viaAlias, ONumbers ai, ONumbers mine});

/// Spec §3.3, item gates 1-9: the row whose numbers item [item] of [meal]
/// is offered, or null.
OPick? oItemPick(
  History h,
  Map item,
  Map<String, Teach> latest,
  Map<String, String> aliases,
) {
  final key = usualNameKey(item['name']);
  if (key == null) return null;
  final direct = latest[key];
  final target = aliases[key];
  final via = target == null ? null : latest[target];
  Teach? row = direct;
  var viaAlias = false;
  if (via != null && (direct == null || via.laterThan(direct))) {
    row = via;
    viaAlias = true;
  }
  if (row == null) return null;
  if (oMuted(h, row.key, row.at)) return null;
  if (viaAlias && oMuted(h, key, row.at)) return null;
  if ((composeLookupItem(item)['brand'] as String).isNotEmpty) return null;
  if (item['published'] == true) return null;
  if (oQty(item) != 1) return null;
  if (!usualPortionsCompatible(
    usualPortion(item['name']),
    usualPortion(row.aiName ?? row.name),
  )) {
    return null;
  }
  final ai = oNumbers(item);
  final ONumbers mine = row.kcalOnly
      ? (kcal: row.numbers.kcal, p: ai.p, c: ai.c, f: ai.f)
      : row.numbers;
  if (ai.kcal < 10 || mine.kcal < 10) return null;
  final ratio = mine.kcal / ai.kcal;
  if (ratio < 0.4 || ratio > 2.5) return null;
  final kcalDiff = (mine.kcal - ai.kcal).abs() >= max(20, 0.10 * ai.kcal);
  final macroDiff =
      !row.kcalOnly &&
      ((mine.p - ai.p).abs() >= 5 ||
          (mine.c - ai.c).abs() >= 5 ||
          (mine.f - ai.f).abs() >= 5);
  if (!kcalDiff && !macroDiff) return null;
  return (row: row, viaAlias: viaAlias, ai: ai, mine: mine);
}

// ─── My usual foods: the oracle (spec §4.2) ────────────────────────────

/// Every food meal of the window under one meal key (spec §4.2), with
/// what a row of My usual foods says about it.
final class OGroup {
  OGroup(this.key);
  final String key;
  final List<Meal> meals = [];
  late final Set<String> dates;
  late final Set<String> dates30;
  late final Set<String> around;
  late final Meal newest;
  late final Meal? template;
  late final bool hidden;
  late final String title;

  bool get listable => dates.length >= 2 && template != null;
}

/// Later in the log: by date, clock, then id.
int oNewer(Meal a, Meal b) {
  var c = a.date.compareTo(b.date);
  if (c == 0) c = oClock(a.time).compareTo(oClock(b.time));
  if (c == 0) c = a.id.compareTo(b.id);
  return c;
}

/// The groups of [h]'s meals, by meal key; [hidden] holds the hide ids
/// the user hid (a group is hidden by its own, or by the one of a key an
/// alias merged into it).
Map<String, OGroup> oGroups(
  History h,
  Map<String, String> aliases,
  Set<String> hidden,
) {
  final now = h.now;
  final start30 = dayIso(now, -29);
  final clock = now.hour * 60 + now.minute;
  final groups = <String, OGroup>{};
  for (final m in h.meals) {
    if (!oInWindow(m, now)) continue;
    final k = oMealKey(m.analysis, aliases);
    if (k != null) (groups[k] ??= OGroup(k)).meals.add(m);
  }
  for (final g in groups.values) {
    g.dates = {for (final m in g.meals) m.date};
    g.dates30 = {
      for (final m in g.meals)
        if (m.date.compareTo(start30) >= 0) m.date,
    };
    g.around = {};
    for (final m in g.meals) {
      if (m.date.compareTo(start30) < 0) continue;
      final at = oClock(m.time);
      if (at < 0) continue;
      final d = (at - clock).abs();
      if (min(d, 1440 - d) <= 120) g.around.add(m.date);
    }
    g.newest = g.meals.reduce((a, b) => oNewer(a, b) >= 0 ? a : b);
    final usable = [
      for (final m in g.meals)
        if (m.analysis['leftover'] is! Map && oItems(m.analysis).length <= 40)
          m,
    ];
    g.template = usable.isEmpty
        ? null
        : usable.reduce((a, b) => oNewer(a, b) >= 0 ? a : b);
    g.title = g.template == null ? '' : usualMealTitle(g.template!.analysis);
    g.hidden =
        hidden.contains(usualHideId(g.key)) ||
        g.meals.any((m) {
          final own = oMealKey(m.analysis, const {});
          return own != null && hidden.contains(usualHideId(own));
        });
  }
  return groups;
}

// ─── The generator ─────────────────────────────────────────────────────

Map<String, dynamic> mealJson(Meal m) => {
  'id': m.id,
  'date': m.date,
  'time': m.time,
  'timestamp': m.timestamp,
  'source': m.source,
  'corrected': m.corrected,
  'analysis': m.analysis,
};

Meal mealWith(Meal m, {Map<String, dynamic>? analysis, bool? corrected}) =>
    Meal(
      id: m.id,
      date: m.date,
      time: m.time,
      timestamp: m.timestamp,
      source: m.source,
      imageHash: m.imageHash,
      fileId: m.fileId,
      analysis: analysis ?? m.analysis,
      corrected: corrected ?? m.corrected,
    );

/// One generated case: the meals, the clock, the user's declines and the
/// meals the restaurant lookup takes.
final class History {
  History(this.now, this.meals, this.choices, this.takes, {this.salt = 0});
  final DateTime now;
  final List<Meal> meals;
  final UsualChoicesView choices;
  final Set<int> takes;

  /// Picks which meal keys a test hides (so the choice survives shrinking).
  final int salt;

  String get today => dayIso(now, 0);

  History withMeals(List<Meal> kept) =>
      History(now, kept, choices, takes, salt: salt);

  Map<String, dynamic> toJson() => {
    'now': now.toIso8601String(),
    'salt': salt,
    'meals': [for (final m in meals) mealJson(m)],
    'declined': [
      for (final d in choices.declined)
        {'m': d.mealId, 'h': d.hideId, 'at': d.at.toIso8601String()},
    ],
    'hidden': choices.hidden.toList(),
    'takes': takes.toList(),
  };
}

class HistoryGen {
  HistoryGen(this.r, {DateTime? now, double? wild, int? count, int? vocab})
    : now = now ?? anyNow(r),
      wild = wild ?? r.pick<double>(const [0.0, 0.0, 0.05, 0.15, 0.3]),
      count = count ?? r.pick<int>(const [0, 1, 3, 10, 30, 60, 120]),
      span = r.pick(const [0, 1, 7, 30, 60, 89, 90, 91, 120]) {
    final n = vocab ?? r.pick<int>(const [2, 4, 8, 30]);
    final all = List<int>.generate(kFoods.length, (i) => i)..shuffle(r);
    foods = all.take(n).toList();
  }

  final Random r;
  final DateTime now;

  /// How often a field is malformed.
  final double wild;
  final int count;

  /// Meals are dated up to this many days back.
  final int span;
  late final List<int> foods;
  int _nextId = 1;

  String get today => dayIso(now, 0);

  num baseKcal(int food) => 150 + (food * 53) % 500;

  Object? wildNumber() => switch (r.nextInt(16)) {
    0 => null,
    1 => 0,
    2 => -r.between(1, 300),
    3 => '${r.nextInt(900)}',
    4 => 'NaN',
    5 => 'abc',
    6 => double.nan,
    7 => double.infinity,
    8 => 1e12,
    9 => 25000 + r.nextInt(5000),
    10 => true,
    11 => [1],
    12 => r.between(1, 9),
    13 => double.negativeInfinity,
    14 => -0.0,
    _ => -1e12,
  };

  num grams() => r.chance(0.6) ? r.nextInt(80) : r.nextInt(800) / 10;

  String nameOf(int food) => r.pick(kFoods[food]);

  /// A mark's `at`: some moment of [date], in UTC.
  String stampOn(String date) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
    final base = m == null
        ? DateTime.utc(now.year, now.month, now.day)
        : DateTime.utc(
            int.parse(m.group(1)!),
            int.parse(m.group(2)!),
            int.parse(m.group(3)!),
          );
    return base
        .add(
          Duration(
            hours: r.nextInt(24),
            minutes: r.nextInt(60),
            milliseconds: 7,
          ),
        )
        .toIso8601String();
  }

  Object? aiName() => r.chance(0.85)
      ? nameOf(r.pick(foods))
      : r.pick(const <Object?>['', '   ', 'Snack', 7, null, 'Latte']);

  /// A `user` value for [item]: valid, inside the tolerance, stale, in the
  /// future, malformed, or one that sets nothing.
  Object? mark(Map<String, dynamic> item, String date) {
    final n = oNumbers(item);
    Map<String, dynamic> valid() => {
      'set': true,
      'at': stampOn(date),
      'n': <Object?>[n.kcal, n.p, n.c, n.f],
      'qty': 1,
    };
    final kind = r.nextInt(100);
    Map<String, dynamic> m;
    if (kind < 55) {
      m = valid();
    } else if (kind < 60) {
      m = valid()..['n'] = [n.kcal + 0.3, n.p + 0.03, n.c - 0.03, n.f];
    } else if (kind < 70) {
      m = valid()
        ..['n'] = [
          n.kcal + r.pick(const [1, -1, 25, -40]),
          n.p,
          n.c + r.pick(const [0, 0.1, 6]),
          n.f,
        ];
    } else if (kind < 75) {
      m = valid()
        ..['at'] = now
            .add(Duration(days: r.between(2, 400)))
            .toUtc()
            .toIso8601String();
    } else if (kind < 80) {
      m = valid()
        ..['at'] = now
            .add(Duration(hours: r.between(1, 23)))
            .toUtc()
            .toIso8601String();
    } else if (kind < 88) {
      final v = valid();
      return r.pick(<Object?>[
        'yes', 7, <Object?>[], <String, dynamic>{}, true, //
        {...v, 'set': 'true'},
        {...v, 'set': 1},
        {...v, 'at': 5},
        {...v, 'at': 'yesterday'},
        {...v}..remove('at'),
        {...v}..remove('n'),
        {...v}..remove('set'),
        {...v, 'n': 'x'},
        {
          ...v,
          'n': <Object?>[n.kcal, n.p, n.c],
        },
        {
          ...v,
          'n': <Object?>[n.kcal, n.p, n.c, '${n.f}'],
        },
        {
          ...v,
          'n': <Object?>[n.kcal, n.p, n.c, double.nan],
        },
        {
          ...v,
          'n': <Object?>[n.kcal, n.p, n.c, double.infinity],
        },
        {
          ...v,
          'n': <Object?>[n.kcal, n.p, n.c, n.f, 0],
        },
        {
          ...v,
          'n': {'0': n.kcal},
        },
      ]);
    } else {
      return r.pick(<Object?>[
        {'qty': 2},
        {'ai_name': aiName()},
        {'qty': 1, 'ai_name': aiName()},
        {'qty': 0.5, 'ai_name': ''},
        {
          'note': 'x',
          'assist': {'status': 'applied'},
          'published': true,
        },
        {'set': false, 'qty': 3, 'fetched_on': '2026-01-01'},
      ]);
    }
    if (r.chance(0.25)) m['ai_name'] = aiName();
    if (r.chance(0.12)) {
      m['qty'] = r.pick(const <Object?>[
        2,
        0.5,
        20,
        21,
        0,
        -3,
        '1',
        null,
        1.0,
        double.nan,
      ]);
    }
    if (r.chance(0.03)) m.remove('qty');
    if (r.chance(wild)) m['x_model'] = {'published': true, 'leftover': {}};
    return m;
  }

  /// One food item. [marked]: how often it carries a `user` value.
  Map<String, dynamic> item(
    String date, {
    required double marked,
    bool manual = false,
    int? food,
    bool? clean,
  }) {
    final w = clean == true ? 0.0 : wild;
    final f = food ?? r.pick<int>(foods);
    Object? name = nameOf(f);
    if (clean != true && r.chance(0.05)) name = r.pick<Object?>(kJunkNames);
    final factor = r.chance(0.1)
        ? r.pick(const [0.2, 0.3, 3.0, 5.0])
        : 0.6 + r.nextDouble();
    final kcal = baseKcal(f) * factor;
    final m = <String, dynamic>{
      'name': name,
      'estimated_calories': r.chance(0.75)
          ? kcal.round()
          : (kcal * 10).round() / 10,
      'protein_g': grams(),
      'carbs_g': grams(),
      'fat_g': grams(),
    };
    if (r.chance(manual ? 0.25 : 0.05)) {
      m['protein_g'] = 0;
      m['carbs_g'] = 0;
      m['fat_g'] = r.chance(0.5) ? 0 : 0.0;
    }
    for (final k in const [
      'estimated_calories',
      'protein_g',
      'carbs_g',
      'fat_g',
    ]) {
      if (r.chance(w * 0.5)) m[k] = wildNumber();
    }
    if (r.chance(w * 0.3)) {
      m.remove(r.pick(const ['protein_g', 'carbs_g', 'fat_g', 'name']));
    }
    if (r.chance(0.12)) {
      m['qty'] = r.pick(const <Object?>[
        1, 2, 0.5, 3, 1.0, 20, 21, 0, -1, '2', true, null, double.nan, //
      ]);
    }
    if (r.chance(0.1)) {
      m['unit'] = r.pick(const <Object?>['bowl', ' slice ', '', 5, 'cup']);
    }
    if (r.chance(0.05)) {
      m['brand'] = r.pick(const <Object?>[
        'Chipotle',
        'Homemade',
        '',
        "McDonald's",
        7,
      ]);
    }
    if (r.chance(0.05)) {
      m['published'] = r.pick(const <Object?>[true, true, false, 'true', 1]);
    }
    if (r.chance(0.04)) m['leftover_left_fraction'] = 0.5;
    if (r.chance(marked)) m['user'] = mark(m, date);
    // A key after `user`, so a row whose `user` came back last is seen.
    if (r.chance(0.3)) m['is_drink'] = false;
    return m;
  }

  Map<String, dynamic> analysisOf(List<Object?> items, {bool? clean}) {
    final w = clean == true ? 0.0 : wild;
    num k = 0, p = 0, c = 0, f = 0;
    for (final it in items.whereType<Map>()) {
      final n = oNumbers(it);
      k += n.kcal;
      p += n.p;
      c += n.c;
      f += n.f;
    }
    final a = <String, dynamic>{
      'is_food': r.chance(0.92) || clean == true
          ? true
          : r.pick(const <Object?>[
              false, 0, '', 'yes', 1, null, <Object?>[], 'false', 0.0, //
            ]),
      'meal_description': r.pick(const <Object?>[
        'Breakfast', 'Lunch', 'Dinner', '', 'Meal', 'Oatmeal', '米饭', //
        'Greek yogurt',
      ]),
      'total_calories': k.round(),
      'total_protein_g': (p * 10).round() / 10,
      'total_carbs_g': (c * 10).round() / 10,
      'total_fat_g': (f * 10).round() / 10,
      'food_items': items,
    };
    if (r.chance(0.15 + w)) {
      final key = r.pick(const [
        'total_calories',
        'total_protein_g',
        'total_carbs_g',
        'total_fat_g',
      ]);
      switch (r.nextInt(5)) {
        case 0:
          a.remove(key);
        case 1:
          a[key] = '${r.nextInt(900)}';
        case 2:
          a[key] = r.nextInt(2000) + 0.37;
        case 3:
          a[key] = wildNumber();
        default:
          a[key] = oNum(a[key]) + r.pick(const [-150, 40, 300]);
      }
    }
    final conf = r.nextInt(20);
    if (conf < 6) {
      a['estimate_confidence'] = 'medium';
    } else if (conf < 11) {
      a['estimate_confidence'] = 'low';
    } else if (conf < 13) {
      a['estimate_confidence'] = r.pick(const <Object?>['high', 'HIGH', '高']);
    } else if (conf < 14) {
      a['estimate_confidence'] = r.pick(const <Object?>[0.9, 3, 'sure', true]);
    }
    if (r.chance(0.3)) {
      a['portion_state'] = r.chance(0.6)
          ? 'whole'
          : r.pick(const <Object?>['partial', 'shared', 'buffet', 'Whole', 5]);
    }
    if (r.chance(0.5)) {
      a['restaurant_context'] = r.pick(const [
        'home',
        'restaurant',
        'takeout',
        'packaged',
      ]);
    }
    if (r.chance(0.08)) {
      a['order_merchant'] = r.pick(const <Object?>[
        'Chipotle',
        "Joe's Diner",
        '',
        'Starbucks',
        9,
      ]);
    }
    if (clean != true && r.chance(0.07)) {
      a['leftover'] = r.chance(0.85)
          ? {
              'original': {'total_calories': 500},
              'left_fraction': 0.5,
            }
          : r.pick(const <Object?>['yes', true, 3]);
    }
    if (clean != true && r.chance(0.07)) a['assist'] = _assistBlock(items);
    if (r.chance(0.1)) a['capture'] = {'shutter_key': 'ab' * 8};
    if (r.chance(w * 0.3)) {
      a['food_items'] = r.pick(const <Object?>[null, 'none', 5, {}]);
    }
    return a;
  }

  /// An assist block: live (its stamp matches the items) or not.
  Object? _assistBlock(List<Object?> items) {
    final at = [
      for (var i = 0; i < items.length; i++)
        if (items[i] is Map) i,
    ];
    final status = r.pick(const [
      'suggested', 'suggested', 'applied', 'context_only', 'declined', //
      'reverted', 'not_published',
    ]);
    if (at.isEmpty || r.chance(0.2)) {
      return r.pick(<Object?>[
        {'v': kAssistVersion, 'status': status},
        'applied',
        {'status': 'suggested', 'matches': 'all'},
      ]);
    }
    final i = r.pick(at);
    final n = oNumbers(items[i]);
    return {
      'v': kAssistVersion,
      'status': status,
      'fetched_on': '2026-10-01',
      'matches': [
        {
          'item_index': i,
          'before': {
            'estimated_calories': n.kcal + (r.chance(0.3) ? 20 : 0),
            'protein_g': n.p,
            'carbs_g': n.c,
            'fat_g': n.f,
          },
        },
      ],
    };
  }

  Meal mealOf(
    List<Object?> items, {
    required String date,
    required String source,
    required bool corrected,
    String? time,
    bool? clean,
  }) => Meal(
    id: _nextId++,
    date: date,
    time:
        time ??
        (clean != true && r.chance(wild * 0.3)
            ? r.pick(const ['', '25:99 AM', '7pm', '13:00'])
            : anyClock(r)),
    timestamp: clean != true && r.chance(wild * 0.3)
        ? r.pick(const ['', 'garbage', '2026-11-07'])
        : '${RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ? date : today}'
              'T${r.nextInt(24).toString().padLeft(2, '0')}:'
              '${r.nextInt(60).toString().padLeft(2, '0')}:00.000',
    source: source,
    corrected: corrected,
    imageHash: '',
    analysis: analysisOf(items, clean: clean),
  );

  /// Any meal at all.
  Meal anyMeal() {
    final back = r.chance(0.25) || span == 0 ? 0 : r.nextInt(span + 1);
    var date = dayIso(now, -back);
    if (r.chance(0.02)) date = dayIso(now, r.between(1, 3));
    if (r.chance(wild * 0.15)) {
      date = r.pick(const ['', 'yesterday', '2026-13-40', '2026-1-5']);
    }
    final source = r.pick(kSources);
    final photo =
        source == MealSource.appPhoto || source == MealSource.appWatch;
    final manual =
        source == MealSource.appManual || source == MealSource.appManualPhoto;
    final corrected = r.chance(
      photo || source == MealSource.manualText ? 0.4 : 0.15,
    );
    final curated = corrected || !photo;
    var n = r.pick(const [1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 0, 4, 6]);
    if (r.chance(0.004)) n = 45;
    final items = <Object?>[];
    for (var i = 0; i < n; i++) {
      if (r.chance(wild * 0.3)) {
        items.add(r.pick(const <Object?>[null, 'Toast', 7, <Object?>[], true]));
      }
      items.add(
        item(
          date,
          marked: curated ? (manual ? 0.35 : 0.6) : 0.08,
          manual: manual,
        ),
      );
    }
    return mealOf(items, date: date, source: source, corrected: corrected);
  }

  /// A food the user set numbers for, and a photo of it today: the plain
  /// way to an offer.
  List<Meal> plantOffer() {
    final food = r.pick(foods);
    final date = dayIso(now, -r.pick(const [0, 1, 2, 5, 30, 88, 89, 90, 95]));
    final kcalOnly = r.chance(0.25);
    // One in twelve is a few kcal only: both sides of the 10 kcal minimum.
    final tiny = r.chance(0.08);
    final mine = <String, dynamic>{
      'name': nameOf(food),
      'estimated_calories': tiny
          ? r.between(8, 24)
          : (baseKcal(food) * (0.7 + r.nextDouble() * 0.8)).round(),
      'protein_g': kcalOnly ? 0 : grams(),
      'carbs_g': kcalOnly ? 0 : grams(),
      'fat_g': kcalOnly ? 0 : grams(),
    };
    final typed = r.chance(0.3);
    if (!typed || r.chance(0.3)) mine['user'] = mark(mine, date);
    final learned = mealOf(
      [mine],
      date: date,
      source: typed
          ? r.pick(const [MealSource.appManual, MealSource.appManualPhoto])
          : r.pick(const [
              MealSource.appPhoto,
              MealSource.appWatch,
              MealSource.manualText,
              MealSource.appRepeat,
            ]),
      corrected: typed ? r.chance(0.1) : r.chance(0.9),
      clean: true,
    );
    final shot = item(today, marked: 0.02, food: food, clean: true);
    if (tiny || r.chance(0.3)) {
      // The AI's numbers close to the user's: both sides of the 20 kcal /
      // 10 % threshold and of the 5 g one.
      final n = oNumbers(mine);
      num near(num v, int by) {
        final x = v + r.between(-by, by) + (r.chance(0.3) ? 0.5 : 0);
        return x < 0 ? 0 : x;
      }

      shot['estimated_calories'] = tiny ? r.between(4, 14) : near(n.kcal, 30);
      shot['protein_g'] = near(n.p, 7);
      shot['carbs_g'] = near(n.c, 7);
      shot['fat_g'] = near(n.f, 7);
    }
    final others = [
      for (var i = r.pick(const [0, 0, 0, 1, 2]); i > 0; i--)
        item(today, marked: 0.02),
    ];
    final photo = mealOf(
      ([shot, ...others]..shuffle(r)),
      date: today,
      source: r.pick(const [MealSource.appPhoto, MealSource.appWatch]),
      corrected: r.chance(0.05),
      clean: r.chance(0.8),
    );
    return [learned, photo];
  }

  /// The same rename on one to three meals (two confirm an alias), maybe
  /// a re-log of it, maybe a second target, and a photo of the AI's name
  /// today.
  List<Meal> plantAlias() {
    if (foods.length < 2) return const [];
    final ai = foods[0];
    final mineFood = foods[1];
    final out = <Meal>[];
    Meal renamed(int target, String source) {
      final date = dayIso(now, -r.between(0, 60));
      final it = <String, dynamic>{
        'name': nameOf(target),
        'estimated_calories': (baseKcal(ai) * (0.7 + r.nextDouble() * 0.8))
            .round(),
        'protein_g': grams(),
        'carbs_g': grams(),
        'fat_g': grams(),
      };
      it['user'] = {
        'set': true,
        'at': stampOn(date),
        'n': [
          it['estimated_calories'],
          it['protein_g'],
          it['carbs_g'],
          it['fat_g'],
        ],
        'qty': 1,
        'ai_name': nameOf(ai),
      };
      return mealOf(
        [it],
        date: date,
        source: source,
        corrected: true,
        clean: true,
      );
    }

    for (var i = r.pick(const [1, 2, 2, 3]); i > 0; i--) {
      out.add(
        renamed(
          mineFood,
          r.pick(const [
            MealSource.appPhoto, MealSource.appWatch, MealSource.manualText, //
          ]),
        ),
      );
    }
    if (r.chance(0.3)) out.add(renamed(mineFood, MealSource.appRepeat));
    if (r.chance(0.2) && foods.length > 2) {
      out
        ..add(renamed(foods[2], MealSource.appPhoto))
        ..add(renamed(foods[2], MealSource.appWatch));
    }
    for (var i = r.pick(const [1, 1, 2]); i > 0; i--) {
      out.add(
        mealOf(
          [item(today, marked: 0.0, food: ai, clean: true)],
          date: today,
          source: MealSource.appWatch,
          corrected: false,
          clean: true,
        ),
      );
    }
    return out;
  }

  /// One meal on several days, so My usual foods has rows.
  List<Meal> plantRepeats({List<int> sizes = const [1, 2, 4, 40]}) {
    final out = <Meal>[];
    final groups = r.pick(sizes);
    // Many groups draw on every food, so the list can pass its 20 rows.
    final pool = groups > 4
        ? List<int>.generate(kFoods.length, (i) => i)
        : foods;
    for (var g = 0; g < groups; g++) {
      final combo = [
        for (var i = r.pick(const [1, 1, 2]); i > 0; i--) r.pick(pool),
      ];
      final clock = anyClock(r);
      for (var d = r.pick(const [2, 2, 3, 5]); d > 0; d--) {
        final date = dayIso(now, -r.pick(const [0, 1, 2, 7, 29, 30, 31, 89]));
        final source = r.pick(kSources);
        out.add(
          mealOf(
            [for (final f in combo) item(date, marked: 0.3, food: f)],
            date: date,
            source: source,
            corrected: r.chance(0.4),
            time: r.chance(0.7) ? clock : null,
          ),
        );
      }
    }
    return out;
  }

  UsualChoicesView choicesFor(List<Meal> meals) {
    final declined = <UsualDecline>[];
    for (var i = r.pick(const [0, 0, 1, 3, 8]); i > 0; i--) {
      final mealId = meals.isEmpty ? 1 : r.pick(meals).id;
      final key = usualNameKey(nameOf(r.pick(foods))) ?? 'x';
      final ago = Duration(
        hours: r.pick(const [0, 1, 30, 24 * 40, 24 * 89, 24 * 91, 24 * 200]),
        minutes: r.nextInt(60),
      );
      declined.add(
        UsualDecline(
          mealId: mealId,
          hideId: usualHideId(key),
          at: r.chance(0.05) ? now.add(ago) : now.subtract(ago),
        ),
      );
    }
    declined.sort((a, b) => b.at.compareTo(a.at));
    return UsualChoicesView(declined: declined);
  }

  History history() {
    final meals = <Meal>[for (var i = 0; i < count; i++) anyMeal()];
    for (var i = r.pick(const [0, 1, 1, 2, 4]); i > 0; i--) {
      meals.addAll(plantOffer());
    }
    if (r.chance(0.35)) meals.addAll(plantAlias());
    if (r.chance(0.5)) meals.addAll(plantRepeats());
    meals.shuffle(r);
    final takes = {
      for (final m in meals)
        if (r.chance(0.04)) m.id,
    };
    return History(now, meals, choicesFor(meals), takes, salt: r.nextInt(97));
  }
}
