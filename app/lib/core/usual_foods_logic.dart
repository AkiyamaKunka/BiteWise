/// Usual foods — the PURE half (design: usual-foods spec §3-§5).
///
/// Two features are worked out here from the user's own meal log, on the
/// phone, with no model call and nothing sent:
///   * Part 2, "your usual numbers": the numbers the user set for a food
///     (a self-validating `user` mark on the item) are offered on a later
///     photo of the same food, behind a tap.
///   * Part 3, "My usual foods": meals logged on two or more days are
///     listed, and one tap logs one again with its numbers.
///
/// Nothing here does I/O or reads a clock: every rule takes `now`. The
/// service (services/usual/usual_foods.dart) reads the meals, memoizes
/// the index and writes through the DAO's compare-and-set.
///
/// The mark (spec §3.1), on a food item:
///   `user: {set: true, at: <UTC ISO ms>, n: [kcal, p, c, f], qty, ai_name?}`
/// It counts only while the item's four numbers still equal `n`
/// ([usualMarkValid]), so any writer that changes the numbers under a kept
/// mark (a restaurant lookup, a leftover deduction, an older build's edit)
/// voids it without knowing about it.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import 'chain_match.dart' show chainTokens;
import 'coerce.dart';
import 'contracts.dart';
import 'restaurant_assist_logic.dart'
    show assistMeasureRe, assistSingular, assistStampValid, AssistStatus;
import 'restaurant_lookup_contract.dart'
    show chainNameOnly, composeLookupItem, kLookupMerchantMax;

// ─── Name keys (spec §3.2) ─────────────────────────────────────────────

/// Dropped from a name key: English function words and the CJK
/// connectors 的 配 与 及. 和, 加 and 带 stay (和牛, 加州卷, 带鱼);
/// numbers, size words and "side" stay too.
const Set<String> _stopTokens = {
  'a',
  'an',
  'the',
  'and',
  'with',
  'of',
  'on',
  'in',
  '的',
  '配',
  '与',
  '及',
};

/// Names that say nothing about the food: a key equal to one of these
/// sets is no key.
const List<String> _genericNames = [
  'food',
  'meal',
  'snack',
  'dish',
  'item',
  'drink',
  'unknown',
  '食物',
  '餐',
  '菜',
  '零食',
  '小吃',
  '饮料',
  '饮品',
  '东西',
];

bool _isCjkToken(String t) {
  if (t.isEmpty) return false;
  final r = t.runes.first;
  return (r >= 0x3040 && r <= 0x30FF) ||
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0xAC00 && r <= 0xD7AF) ||
      (r >= 0xF900 && r <= 0xFAFF) ||
      (r >= 0x20000 && r <= 0x2FA1F);
}

int _latinLetters(String t) {
  var n = 0;
  for (final r in t.codeUnits) {
    if (r >= 0x61 && r <= 0x7A) n++;
  }
  return n;
}

/// The name's key tokens BEFORE the generic and too-short checks: the
/// string folded ([nfkcLite]), every bracketed part holding a digit
/// ([assistMeasureRe]) cut, tokenized like a chain name ([chainTokens]),
/// stop tokens dropped and Latin tokens singularized ([assistSingular]).
/// Empty for a non-string. The loose "logged it already?" test reads
/// these.
Set<String> usualNameTokens(Object? name) {
  if (name is! String) return const {};
  final cut = nfkcLite(name).replaceAll(assistMeasureRe, ' ');
  return {
    for (final t in chainTokens(cut))
      if (!_stopTokens.contains(t)) _isCjkToken(t) ? t : assistSingular(t),
  };
}

final List<Set<String>> _genericSets = [
  for (final g in _genericNames) usualNameTokens(g),
];

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// The key two names of the same food share (spec §3.2, D29): the sorted
/// set of [usualNameTokens], joined by one space. Matching is set
/// equality only, never a subset: "Oatmeal (~300 g)" and "Blueberry
/// oatmeal (~250 g)" are different foods, "Oatmeal with blueberries" and
/// "Blueberry oatmeal" the same one.
///
/// Null — the name names nothing usable — when no token is left; when no
/// Latin token has 3 or more letters and there is no CJK token ("Pb",
/// "2"); or when the set equals a generic name's ("Snack", 零食).
String? usualNameKey(Object? name) {
  final tokens = usualNameTokens(name);
  if (tokens.isEmpty) return null;
  final anyCjk = tokens.any(_isCjkToken);
  if (!anyCjk && !tokens.any((t) => _latinLetters(t) >= 3)) return null;
  for (final g in _genericSets) {
    if (_sameSet(tokens, g)) return null;
  }
  return (tokens.toList()..sort()).join(' ');
}

/// [name] for a chip or a card line: the bracketed weights and counts
/// cut ([assistMeasureRe]), cleaned and collapsed like any short text,
/// at most 40 characters. "" for a non-string; the cleaned name itself
/// when cutting would leave nothing.
String usualDisplayName(Object? name) {
  if (name is! String) return '';
  final cut =
      cleanShortText(nfkcLite(name).replaceAll(assistMeasureRe, ' '), 40);
  return cut.isNotEmpty ? cut : cleanShortText(name, 40);
}

// ─── Portions (spec §3.2, D30a) ────────────────────────────────────────

enum UsualPortionKind { mass, volume, count }

/// A portion written in a name: a weight (in g), a volume (in ml) or a
/// count.
final class UsualPortion {
  const UsualPortion(this.kind, this.value);
  final UsualPortionKind kind;
  final double value;

  @override
  bool operator ==(Object other) =>
      other is UsualPortion && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'UsualPortion(${kind.name}, $value)';
}

/// Units, longest spelling first so "fl oz" is not read as "oz", "kg" as
/// "g" or "ml" as "l". Latin units must not run on into a word ("300
/// grapes" is no weight).
final RegExp _portionRe = RegExp(
  r'(?<![0-9.])([0-9]+(?:\.[0-9]+)?)\s*'
  r'(?:(千克|公斤|毫升|克|升|个|片|块|只|颗|根|串)'
  r'|(fl\.?\s*oz|kilograms?|kgs?|grams?|g|ounces?|oz|'
  r'millilit(?:er|re)s?|ml|lit(?:er|re)s?|l|'
  r'pieces?|pcs|pc|slices?)(?![a-z]))',
);

const Map<String, (UsualPortionKind, double)> _cjkUnits = {
  '千克': (UsualPortionKind.mass, 1000),
  '公斤': (UsualPortionKind.mass, 1000),
  '克': (UsualPortionKind.mass, 1),
  '毫升': (UsualPortionKind.volume, 1),
  '升': (UsualPortionKind.volume, 1000),
  '个': (UsualPortionKind.count, 1),
  '片': (UsualPortionKind.count, 1),
  '块': (UsualPortionKind.count, 1),
  '只': (UsualPortionKind.count, 1),
  '颗': (UsualPortionKind.count, 1),
  '根': (UsualPortionKind.count, 1),
  '串': (UsualPortionKind.count, 1),
};

(UsualPortionKind, double) _latinUnit(String u) {
  if (u.startsWith('fl')) return (UsualPortionKind.volume, 29.57);
  if (u.startsWith('k')) return (UsualPortionKind.mass, 1000);
  if (u.startsWith('g')) return (UsualPortionKind.mass, 1);
  if (u.startsWith('o')) return (UsualPortionKind.mass, 28.35);
  if (u.startsWith('m')) return (UsualPortionKind.volume, 1);
  if (u.startsWith('l')) return (UsualPortionKind.volume, 1000);
  return (UsualPortionKind.count, 1); // piece(s), pc(s), slice(s)
}

/// The first portion written in [name] ("Oatmeal (~250 g)" → 250 g,
/// "饺子（约6个）" → 6, "Latte 12 fl oz" → 354.84 ml), or null. A
/// leading ~, 约 or "about" is allowed; a zero amount is no portion.
UsualPortion? usualPortion(Object? name) {
  if (name is! String) return null;
  final m = _portionRe.firstMatch(nfkcLite(name).toLowerCase());
  if (m == null) return null;
  final amount = double.tryParse(m.group(1)!);
  if (amount == null || !amount.isFinite || amount <= 0) return null;
  final (kind, factor) = m.group(2) != null
      ? _cjkUnits[m.group(2)!]!
      : _latinUnit(m.group(3)!);
  return UsualPortion(kind, amount * factor);
}

/// Portions more than 30% apart.
const double kUsualPortionTolerance = 1.3;

/// Two portions are compatible unless both exist, are of the same kind
/// and the larger is more than [kUsualPortionTolerance] times the
/// smaller: 300 g vs 250 g is the same bowl, 500 g vs 250 g is not; a
/// weight vs a count, or a side with no portion, says nothing.
bool usualPortionsCompatible(UsualPortion? a, UsualPortion? b) {
  if (a == null || b == null || a.kind != b.kind) return true;
  final hi = a.value > b.value ? a.value : b.value;
  final lo = a.value > b.value ? b.value : a.value;
  return hi / lo <= kUsualPortionTolerance;
}

// ─── Marks (spec §3.1, D23, D27) ───────────────────────────────────────

/// A mark's `at`: UTC ISO 8601 with milliseconds.
String usualStamp(DateTime now) => DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();

bool _finiteNum(Object? v) => v is num && v.isFinite;

/// Calories and the three macros (g), in that order.
typedef UsualNumbers = ({num kcal, num p, num c, num f});

/// The item's four numbers as every reader coerces them (safeNumber).
UsualNumbers usualItemNumbers(Object? item) {
  final m = item is Map ? item : const {};
  return (
    kcal: safeNumber(m['estimated_calories']),
    p: safeNumber(m['protein_g']),
    c: safeNumber(m['carbs_g']),
    f: safeNumber(m['fat_g']),
  );
}

/// True while [item]'s `user` mark vouches for the numbers the item holds
/// now: `set` is true, `at` parses and is no later than [now] + 1 day,
/// `n` is four finite numbers, and the item's kcal is within 0.5 and each
/// macro within 0.05 of them. Any other writer that changed the numbers
/// since made the mark void.
bool usualMarkValid(Object? item, DateTime now) {
  if (item is! Map) return false;
  final user = item['user'];
  if (user is! Map || user['set'] != true) return false;
  final atRaw = user['at'];
  final at = atRaw is String ? DateTime.tryParse(atRaw) : null;
  if (at == null || at.isAfter(now.add(const Duration(days: 1)))) {
    return false;
  }
  final n = user['n'];
  if (n is! List || n.length != 4 || !n.every(_finiteNum)) return false;
  final cur = usualItemNumbers(item);
  if (((n[0] as num) - cur.kcal).abs() > 0.5) return false;
  final macros = [cur.p, cur.c, cur.f];
  for (var i = 0; i < 3; i++) {
    if (((n[i + 1] as num) - macros[i]).abs() > 0.05) return false;
  }
  return true;
}

/// The item's count: the mark's `qty` when it is a number in (0, 20]
/// (the editor's rows drop `qty`, so the mark keeps it), else the item's
/// own `qty` ([coerceQty]).
num usualItemQty(Object? item) {
  final m = item is Map ? item : const {};
  final user = m['user'];
  if (user is Map) {
    final q = user['qty'];
    if (q is num && q.isFinite && q > 0 && q <= kQtyMax) return q;
  }
  return coerceQty(m['qty']);
}

/// Sources whose marks are the user's on this build: hand-typed meals,
/// describe-a-meal saves (the describe prefill is stripped when the editor
/// opens) and meals logged again.
const Set<String> _trustedSources = {
  MealSource.appManual,
  MealSource.appManualPhoto,
  MealSource.manualText,
  MealSource.appRepeat,
};

/// Marks are read only on meals the user curated (spec §3.1, P9): a
/// corrected meal, or a source whose numbers came from the user. A valid
/// mark on an uncorrected photo meal is a model's claim, not the user's.
bool usualMarksTrusted(Meal m) =>
    m.corrected || _trustedSources.contains(m.source);

// ─── Constants (spec §3.3, Appendix B) ─────────────────────────────────

/// The learning window and the My usual foods window, in calendar days,
/// today included.
const int kUsualWindowDays = 90;
const double kUsualRatioMin = 0.4;
const double kUsualRatioMax = 2.5;
const num kUsualMinDiffKcal = 20;
const double kUsualMinDiffShare = 0.10;
const num kUsualMinMacroDiffG = 5;
const num kUsualMinKcal = 10;

/// A record with at least this many kcal and all three macros 0 is
/// kcal-only (P8): blank macros are not the user's 0 g.
const num kUsualKcalOnlyMin = 50;

/// The same rename on this many meals confirms an alias (D24).
const int kUsualAliasMinMeals = 2;

/// Declines on this many different meals mute a food (D21).
const int kUsualMuteDeclines = 2;

/// How long a decline counts.
const int kUsualDeclineDays = 90;

/// The first day of the [kUsualWindowDays] window ending on [now]'s day,
/// as YYYY-MM-DD. Calendar arithmetic, never a Duration: a 23:30 clock
/// the week after DST ended is a day off by Duration(days: 89).
String usualWindowStart(DateTime now, {int days = kUsualWindowDays}) =>
    isoDate(DateTime(now.year, now.month, now.day - (days - 1)));

// ─── Choices snapshot (spec §3.6, §4.7, §5) ────────────────────────────

/// What the choices store keeps instead of a food name: the first 16 hex
/// characters of SHA-256 over a name key or a meal key.
String usualHideId(String key) =>
    sha256.convert(utf8.encode(key)).toString().substring(0, 16);

/// One "Keep AI estimate" on one offered food of one meal.
final class UsualDecline {
  const UsualDecline(
      {required this.mealId, required this.hideId, required this.at});
  final int mealId;
  final String hideId;
  final DateTime at;
}

/// An immutable snapshot of the user's choices (services/usual/
/// usual_choices.dart stores them), for the pure rules below.
final class UsualChoicesView {
  const UsualChoicesView({this.hidden = const {}, this.declined = const []});

  static const UsualChoicesView empty = UsualChoicesView();

  /// [usualHideId]s of the meal keys hidden from My usual foods.
  final Set<String> hidden;

  /// Newest first.
  final List<UsualDecline> declined;

  bool isHidden(String hideId) => hidden.contains(hideId);

  bool _live(UsualDecline d, DateTime now) => !d.at
      .isBefore(now.subtract(const Duration(days: kUsualDeclineDays)));

  /// The user kept the AI estimate on meal [mealId].
  bool mealDeclined(int mealId, {required DateTime now}) =>
      declined.any((d) => d.mealId == mealId && _live(d, now));

  /// The food [key] is muted (D21): declined on [kUsualMuteDeclines]
  /// different meals, every one later than [since] (its record's `at`), so
  /// new numbers lift the mute. Declines older than [kUsualDeclineDays]
  /// days are ignored.
  bool muted(String key, {required DateTime since, required DateTime now}) {
    final h = usualHideId(key);
    final meals = {
      for (final d in declined)
        if (d.hideId == h && d.at.isAfter(since) && _live(d, now)) d.mealId,
    };
    return meals.length >= kUsualMuteDeclines;
  }
}

// ─── Records and the index (spec §3.2) ─────────────────────────────────

/// Numbers the user set for a food: one learned item.
final class UsualRecord {
  const UsualRecord({
    required this.key,
    required this.name,
    required this.aiName,
    required this.mealId,
    required this.itemIndex,
    required this.date,
    required this.time,
    required this.at,
    required this.atRaw,
    required this.numbers,
    required this.kcalOnly,
    required this.portion,
  });

  /// [usualNameKey] of the item's current name.
  final String key;

  /// The item's name, cleaned (at most 80 characters).
  final String name;

  /// The AI's name before the user renamed the row (`user.ai_name`).
  final String? aiName;
  final int mealId;

  /// Position in safeFoodItems of that meal.
  final int itemIndex;
  final String date;
  final String time;

  /// When the numbers were set: the mark's `at`, or the hand-typed meal's
  /// timestamp.
  final DateTime at;

  /// [at] as it was stored, copied unchanged by a re-log.
  final String atRaw;
  final UsualNumbers numbers;
  final bool kcalOnly;

  /// The AI's portion guess ([usualPortion] of [aiName], else [name]):
  /// compared AI name to AI name.
  final UsualPortion? portion;
}

/// [UsualIndex.recordFor]'s answer.
typedef UsualRecordHit = ({UsualRecord record, bool viaAlias});

/// Everything the two features learn from the last [kUsualWindowDays]
/// days of meals, built by [buildUsualIndex].
final class UsualIndex {
  UsualIndex._({
    required this.today,
    required this.records,
    required this.aliases,
    required this.groups,
  });

  /// The local day it was built for (YYYY-MM-DD).
  final String today;

  /// The latest record per name key.
  final Map<String, UsualRecord> records;

  /// Confirmed aliases: the AI's name key → the user's name key (D24).
  final Map<String, String> aliases;

  /// Part 3's meal groups, by meal key ([usualMealKey]).
  final Map<String, UsualGroup> groups;

  /// The record for name [key] that comes from a meal other than
  /// [excludeMealId]: the direct record, else the record its confirmed
  /// alias points to (`viaAlias`), else null. Numbers learned only from the
  /// meal being offered are never offered back to it.
  UsualRecordHit? recordFor(String key, {required int excludeMealId}) {
    final direct = records[key];
    if (direct != null && direct.mealId != excludeMealId) {
      return (record: direct, viaAlias: false);
    }
    final target = aliases[key];
    if (target == null) return null;
    final viaAlias = records[target];
    if (viaAlias == null || viaAlias.mealId == excludeMealId) return null;
    return (record: viaAlias, viaAlias: true);
  }
}

/// Clock minutes of a stored hh:mm AM/PM time, or null.
int? _clockMinutes(String raw) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*([AaPp])\.?[Mm]\.?\s*$')
      .firstMatch(raw);
  if (m == null) return null;
  var h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h < 1 || h > 12 || min > 59) return null;
  final pm = m.group(3)!.toLowerCase() == 'p';
  if (h == 12) h = 0;
  return (pm ? h + 12 : h) * 60 + min;
}

/// Orders two (date, time, id) positions in the log, oldest first.
int _logOrder(String dateA, String timeA, int idA, String dateB,
    String timeB, int idB) {
  final d = dateA.compareTo(dateB);
  if (d != 0) return d;
  final t = (_clockMinutes(timeA) ?? -1).compareTo(_clockMinutes(timeB) ?? -1);
  if (t != 0) return t;
  return idA.compareTo(idB);
}

bool _isLatestOver(UsualRecord a, UsualRecord b) {
  final at = a.at.compareTo(b.at);
  if (at != 0) return at > 0;
  final log = _logOrder(a.date, a.time, a.mealId, b.date, b.time, b.mealId);
  if (log != 0) return log > 0;
  return a.itemIndex > b.itemIndex;
}

bool _foodMeal(Meal m) => isFoodTruthy(m.analysis['is_food']);

bool _hasLeftover(Map analysis) => analysis['leftover'] is Map;

String? _nonEmptyString(Object? v, int max) {
  if (v is! String) return null;
  final c = cleanShortText(v, max);
  return c.isEmpty ? null : c;
}

/// The learned record an item of meal [m] gives, or null (spec §3.1
/// "What counts as yours"): (a) a valid mark on a trusted meal, or (b) an
/// unmarked item of a hand-typed meal; never published, never from a
/// meal with a leftover block (the caller checks), and qty exactly 1.
UsualRecord? _recordOf(Meal m, Map<String, dynamic> item, int index,
    DateTime now) {
  if (item['published'] == true) return null;
  final key = usualNameKey(item['name']);
  if (key == null) return null;
  final name = cleanShortText(item['name'], 80);
  final user = item['user'];
  UsualNumbers numbers;
  DateTime at;
  String atRaw;
  String? aiName;
  num qty;
  if (usualMarkValid(item, now) && usualMarksTrusted(m)) {
    user as Map;
    final n = user['n'] as List;
    numbers = (
      kcal: n[0] as num,
      p: n[1] as num,
      c: n[2] as num,
      f: n[3] as num,
    );
    atRaw = user['at'] as String;
    at = DateTime.parse(atRaw);
    aiName = _nonEmptyString(user['ai_name'], 80);
    qty = usualItemQty(item);
  } else if ((m.source == MealSource.appManual ||
          m.source == MealSource.appManualPhoto) &&
      user is! Map) {
    final parsed = DateTime.tryParse(m.timestamp);
    if (parsed == null) return null;
    numbers = usualItemNumbers(item);
    at = parsed;
    atRaw = m.timestamp;
    qty = coerceQty(item['qty']);
  } else {
    return null;
  }
  if (qty != 1) return null;
  final kcalOnly = numbers.kcal >= kUsualKcalOnlyMin &&
      numbers.p == 0 &&
      numbers.c == 0 &&
      numbers.f == 0;
  return UsualRecord(
    key: key,
    name: name,
    aiName: aiName,
    mealId: m.id,
    itemIndex: index,
    date: m.date,
    time: m.time,
    at: at,
    atRaw: atRaw,
    numbers: numbers,
    kcalOnly: kcalOnly,
    portion: usualPortion(aiName ?? name),
  );
}

/// Builds the index from [meals] (spec §3.2): the food meals dated in the
/// last [kUsualWindowDays] calendar days, today included. Pass 1 learns
/// the records (the latest per key wins: by `at`, then the meal's date
/// and time, then id) and the confirmed aliases; pass 2 groups the meals
/// for My usual foods.
UsualIndex buildUsualIndex(List<Meal> meals, {required DateTime now}) {
  final today = isoDate(now);
  final start = usualWindowStart(now);
  final window = [
    for (final m in meals)
      if (m.date.compareTo(start) >= 0 &&
          m.date.compareTo(today) <= 0 &&
          _foodMeal(m))
        m,
  ];
  final records = <String, UsualRecord>{};
  final renames = <String, Map<String, Set<int>>>{};
  for (final m in window) {
    if (_hasLeftover(m.analysis)) continue;
    final items = safeFoodItems(m.analysis);
    for (var i = 0; i < items.length; i++) {
      final r = _recordOf(m, items[i], i, now);
      if (r == null) continue;
      final held = records[r.key];
      if (held == null || _isLatestOver(r, held)) records[r.key] = r;
      final aiKey = r.aiName == null ? null : usualNameKey(r.aiName);
      if (aiKey != null && aiKey != r.key) {
        renames
            .putIfAbsent(aiKey, () => {})
            .putIfAbsent(r.key, () => {})
            .add(r.mealId);
      }
    }
  }
  final aliases = <String, String>{};
  for (final e in renames.entries) {
    final confirmed = [
      for (final t in e.value.entries)
        if (t.value.length >= kUsualAliasMinMeals) t.key,
    ];
    if (confirmed.length == 1) aliases[e.key] = confirmed.single;
  }
  return UsualIndex._(
    today: today,
    records: records,
    aliases: aliases,
    groups: _groupMeals(window, aliases),
  );
}

// ─── Meal keys and groups (spec §3.2 pass 2, §4.2) ─────────────────────

/// Most items a template may have (the editor's cap).
const int kUsualMaxItems = 40;

String? _canonicalKey(Object? item, Map<String, String> aliases) {
  final m = item is Map ? item : const {};
  final k = usualNameKey(m['name']);
  if (k == null) return null;
  final user = m['user'];
  // A row the user renamed: its name is the user's own, never an alias.
  if (user is Map &&
      user['ai_name'] is String &&
      (user['ai_name'] as String).trim().isNotEmpty) {
    return k;
  }
  return aliases[k] ?? k;
}

/// The key one item counts under in My usual foods: its name key, read
/// through a confirmed alias unless the user renamed the row (its name is
/// then the user's).
String? usualCanonicalKey(Object? item, UsualIndex index) =>
    _canonicalKey(item, index.aliases);

String? _mealKey(Map<String, dynamic> analysis, Map<String, String> aliases) {
  final items = safeFoodItems(analysis);
  if (items.isEmpty) {
    final d = usualNameKey(analysis['meal_description']);
    return d == null ? null : 'd:$d';
  }
  final keys = <String>[];
  for (final it in items) {
    final k = _canonicalKey(it, aliases);
    if (k == null) return null;
    keys.add(k);
  }
  keys.sort();
  return keys.join(' + ');
}

/// The meal's key in My usual foods (spec §4.2): the sorted multiset of
/// its items' [usualCanonicalKey]s, joined by " + "; with no items, "d:"
/// and the description's name key. Null — never listed — when any item
/// (or the description) has no key.
String? usualMealKey(Map<String, dynamic> analysis, UsualIndex index) =>
    _mealKey(analysis, index.aliases);

/// Every food meal in the window with one meal key.
final class UsualGroup {
  const UsualGroup(
      {required this.key, required this.meals, required this.template});
  final String key;

  /// Most recent first.
  final List<Meal> meals;

  /// The most recent meal with no leftover block and at most
  /// [kUsualMaxItems] items: what a re-log copies. Null when there is
  /// none (a deducted meal still counts toward the days).
  final Meal? template;

  String get hideId => usualHideId(key);
}

/// Newest first: date, then clock, then id.
int _newestFirst(Meal a, Meal b) =>
    _logOrder(b.date, b.time, b.id, a.date, a.time, a.id);

Map<String, UsualGroup> _groupMeals(
    List<Meal> window, Map<String, String> aliases) {
  final byKey = <String, List<Meal>>{};
  for (final m in window) {
    final k = _mealKey(m.analysis, aliases);
    if (k != null) byKey.putIfAbsent(k, () => []).add(m);
  }
  return {
    for (final e in byKey.entries)
      e.key: () {
        final meals = e.value..sort(_newestFirst);
        Meal? template;
        for (final m in meals) {
          if (!_hasLeftover(m.analysis) &&
              safeFoodItems(m.analysis).length <= kUsualMaxItems) {
            template = m;
            break;
          }
        }
        return UsualGroup(key: e.key, meals: meals, template: template);
      }(),
  };
}

// ─── Offers (spec §3.3) ────────────────────────────────────────────────

/// One food of a meal the user's numbers are offered for.
final class UsualOfferItem {
  const UsualOfferItem({
    required this.index,
    required this.name,
    required this.key,
    required this.learnedName,
    required this.viaAlias,
    required this.ai,
    required this.mine,
    required this.kcalOnly,
    required this.mineAt,
    required this.fromMealId,
    required this.fromDate,
  });

  /// Position in safeFoodItems(meal.analysis).
  final int index;

  /// This item's name for display ([usualDisplayName]).
  final String name;

  /// This item's name key.
  final String key;

  /// The learned food's name for display: the chip and the card name it.
  final String learnedName;
  final bool viaAlias;

  /// The item's numbers now.
  final UsualNumbers ai;

  /// What Use writes: the user's numbers (for a kcal-only record, the
  /// user's kcal and the AI's macros).
  final UsualNumbers mine;
  final bool kcalOnly;
  final DateTime mineAt;
  final int fromMealId;
  final String fromDate;
}

/// The user's numbers offered for one meal ([usualOfferFor]). Never stored.
final class UsualOffer {
  const UsualOffer({
    required this.mealId,
    required this.items,
    required this.beforeKcal,
    required this.afterKcal,
  });
  final int mealId;
  final List<UsualOfferItem> items;

  /// total_calories now (safeNumber).
  final num beforeKcal;

  /// The total Use writes: [beforeKcal] plus every item's kcal delta,
  /// whole.
  final num afterKcal;
}

/// The meal gates of [usualOfferFor] (spec §3.3, 1-11): cheap, no index.
bool usualOfferCandidate(Meal meal,
    {required DateTime now,
    required bool lookupTakesIt,
    required UsualChoicesView choices}) {
  final a = meal.analysis;
  if (meal.source != MealSource.appPhoto &&
      meal.source != MealSource.appWatch) {
    return false;
  }
  if (meal.date != isoDate(now)) return false;
  if (meal.corrected) return false;
  if (!isFoodTruthy(a['is_food'])) return false;
  if (_hasLeftover(a)) return false;
  final ctx = mealContextFields(a);
  if (ctx.portionState != null && ctx.portionState != PortionState.whole) {
    return false;
  }
  if (ctx.estimateConfidence == EstimateConfidence.high) return false;
  if (lookupTakesIt) return false;
  final block = a['assist'];
  if (block is Map &&
      (block['status'] == AssistStatus.applied ||
          block['status'] == AssistStatus.suggested) &&
      assistStampValid(a)) {
    return false;
  }
  if (chainNameOnly(a['order_merchant'], kLookupMerchantMax).isNotEmpty) {
    return false;
  }
  if (choices.mealDeclined(meal.id, now: now)) return false;
  return true;
}

num _max(num a, num b) => a > b ? a : b;

/// The user's numbers to offer on [meal], or null (spec §3.3). Pure: the
/// meal gates ([usualOfferCandidate]), then per item: a key with a record
/// from another meal, not muted, no chain brand, not published, qty 1,
/// compatible portions, both kcal ≥ [kUsualMinKcal], the ratio within
/// [kUsualRatioMin]-[kUsualRatioMax], and a difference worth a tap.
UsualOffer? usualOfferFor(Meal meal, UsualIndex index,
    {required DateTime now,
    required bool lookupTakesIt,
    required UsualChoicesView choices}) {
  if (!usualOfferCandidate(meal,
      now: now, lookupTakesIt: lookupTakesIt, choices: choices)) {
    return null;
  }
  final items = safeFoodItems(meal.analysis);
  final offered = <UsualOfferItem>[];
  num dk = 0;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final key = usualNameKey(item['name']);
    if (key == null) continue;
    final hit = index.recordFor(key, excludeMealId: meal.id);
    if (hit == null) continue;
    final r = hit.record;
    if (choices.muted(r.key, since: r.at, now: now)) continue;
    if (hit.viaAlias && choices.muted(key, since: r.at, now: now)) continue;
    if ((composeLookupItem(item)['brand'] as String).isNotEmpty) continue;
    if (item['published'] == true) continue;
    if (usualItemQty(item) != 1) continue;
    if (!usualPortionsCompatible(usualPortion(item['name']), r.portion)) {
      continue;
    }
    final ai = usualItemNumbers(item);
    final mine = r.kcalOnly
        ? (kcal: r.numbers.kcal, p: ai.p, c: ai.c, f: ai.f)
        : r.numbers;
    if (ai.kcal < kUsualMinKcal || mine.kcal < kUsualMinKcal) continue;
    final ratio = mine.kcal / ai.kcal;
    if (ratio < kUsualRatioMin || ratio > kUsualRatioMax) continue;
    final kcalDiff = (mine.kcal - ai.kcal).abs() >=
        _max(kUsualMinDiffKcal, kUsualMinDiffShare * ai.kcal);
    final macroDiff = !r.kcalOnly &&
        ((mine.p - ai.p).abs() >= kUsualMinMacroDiffG ||
            (mine.c - ai.c).abs() >= kUsualMinMacroDiffG ||
            (mine.f - ai.f).abs() >= kUsualMinMacroDiffG);
    if (!kcalDiff && !macroDiff) continue;
    offered.add(UsualOfferItem(
      index: i,
      name: usualDisplayName(item['name']),
      key: key,
      learnedName: usualDisplayName(r.name),
      viaAlias: hit.viaAlias,
      ai: ai,
      mine: mine,
      kcalOnly: r.kcalOnly,
      mineAt: r.at,
      fromMealId: r.mealId,
      fromDate: r.date,
    ));
    dk += mine.kcal - ai.kcal;
  }
  if (offered.isEmpty) return null;
  final before = safeNumber(meal.analysis['total_calories']);
  return UsualOffer(
    mealId: meal.id,
    items: offered,
    beforeKcal: before,
    afterKcal: (before + dk).round(),
  );
}

// ─── Use and its undo (spec §3.5) ──────────────────────────────────────

num _round1(num v) => (v * 10).round() / 10;

/// The raw positions of the maps in [raw]: safeFoodItems index → index.
List<int> _mapPositions(List raw) => [
      for (var i = 0; i < raw.length; i++)
        if (raw[i] is Map) i,
    ];

Map<String, dynamic> _copyMap(Map m) => {
      for (final e in m.entries) '${e.key}': e.value,
    };

const List<String> _totalKeys = [
  'total_calories',
  'total_protein_g',
  'total_carbs_g',
  'total_fat_g',
];

const List<String> _itemNumberKeys = [
  'estimated_calories',
  'protein_g',
  'carbs_g',
  'fat_g',
];

/// [out]'s totals moved by the four deltas, as applyAssist moves them:
/// kcal whole, macros to 0.1 g; an absent total with no delta stays
/// absent.
void _moveTotals(Map<String, dynamic> out, List<num> delta) {
  for (var i = 0; i < 4; i++) {
    final total = safeNumberOr(out[_totalKeys[i]], null);
    if (total == null && delta[i].abs() < 1e-9) continue;
    final v = (total ?? 0) + delta[i];
    out[_totalKeys[i]] = i == 0 ? v.round() : _round1(v);
  }
}

/// [analysis] with [offer] used (spec §3.5): every offered item's numbers
/// become `mine` (only kcal for a kcal-only record) and gain `user {set,
/// at: now, n: the written numbers, qty: 1}`, keeping an existing
/// `ai_name`; the totals move by the delta. Names, the description and
/// every other key stay. Null — write nothing — on a meal with a leftover
/// block, or unless every offered item still holds the AI numbers shown.
Map<String, dynamic>? applyUsualOffer(
    Map<String, dynamic> analysis, UsualOffer offer,
    {required DateTime now}) {
  if (_hasLeftover(analysis) || offer.items.isEmpty) return null;
  final raw = analysis['food_items'];
  if (raw is! List) return null;
  final positions = _mapPositions(raw);
  final items = [for (final e in raw) e is Map ? _copyMap(e) : e];
  final seen = <int>{};
  final delta = <num>[0, 0, 0, 0];
  for (final it in offer.items) {
    if (it.index < 0 || it.index >= positions.length || !seen.add(it.index)) {
      return null;
    }
    final item = items[positions[it.index]] as Map<String, dynamic>;
    final cur = usualItemNumbers(item);
    if (cur != it.ai) return null;
    final written = it.kcalOnly
        ? (kcal: it.mine.kcal, p: cur.p, c: cur.c, f: cur.f)
        : it.mine;
    item['estimated_calories'] = written.kcal;
    if (!it.kcalOnly) {
      item['protein_g'] = written.p;
      item['carbs_g'] = written.c;
      item['fat_g'] = written.f;
    }
    final old = item['user'];
    final aiName = old is Map ? old['ai_name'] : null;
    item['user'] = {
      'set': true,
      'at': usualStamp(now),
      'n': [written.kcal, written.p, written.c, written.f],
      'qty': 1,
      if (aiName is String && aiName.trim().isNotEmpty) 'ai_name': aiName,
    };
    delta[0] += written.kcal - cur.kcal;
    delta[1] += written.p - cur.p;
    delta[2] += written.c - cur.c;
    delta[3] += written.f - cur.f;
  }
  final out = _copyMap(analysis)..['food_items'] = items;
  _moveTotals(out, delta);
  return out;
}

/// What [revertUsualOffer] needs to undo one Use: the analysis before and
/// the analysis written, and which items changed.
final class UsualUndo {
  const UsualUndo(
      {required this.before, required this.after, required this.indices});
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;

  /// Positions in safeFoodItems.
  final List<int> indices;
}

bool _deepEq(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !_deepEq(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// [current] with one Use undone (spec §3.5 step 6), or null — write
/// nothing — unless every changed item still holds exactly the numbers
/// and the mark Use wrote. The items get their previous numbers and
/// previous `user` (or none) back; the totals get their previous values
/// back while they still read what Use wrote, else they move back by the
/// delta.
Map<String, dynamic>? revertUsualOffer(
    Map<String, dynamic> current, UsualUndo undo) {
  if (_hasLeftover(current) || undo.indices.isEmpty) return null;
  final raw = current['food_items'];
  if (raw is! List) return null;
  final positions = _mapPositions(raw);
  final beforeItems = safeFoodItems(undo.before);
  final afterItems = safeFoodItems(undo.after);
  final items = [for (final e in raw) e is Map ? _copyMap(e) : e];
  final delta = <num>[0, 0, 0, 0];
  for (final i in undo.indices) {
    if (i < 0 ||
        i >= positions.length ||
        i >= beforeItems.length ||
        i >= afterItems.length) {
      return null;
    }
    final item = items[positions[i]] as Map<String, dynamic>;
    final wrote = afterItems[i];
    if (usualItemNumbers(item) != usualItemNumbers(wrote) ||
        !_deepEq(item['user'], wrote['user'])) {
      return null;
    }
    final prev = beforeItems[i];
    final a = usualItemNumbers(wrote);
    final b = usualItemNumbers(prev);
    delta[0] += b.kcal - a.kcal;
    delta[1] += b.p - a.p;
    delta[2] += b.c - a.c;
    delta[3] += b.f - a.f;
    for (final k in [..._itemNumberKeys, 'user']) {
      if (prev.containsKey(k)) {
        item[k] = prev[k];
      } else {
        item.remove(k);
      }
    }
  }
  final out = _copyMap(current)..['food_items'] = items;
  final totalsAsWritten = _totalKeys.every((k) =>
      _deepEq(safeNumberOr(current[k], null), safeNumberOr(undo.after[k], null)));
  if (totalsAsWritten) {
    for (final k in _totalKeys) {
      if (undo.before.containsKey(k)) {
        out[k] = undo.before[k];
      } else {
        out.remove(k);
      }
    }
  } else {
    _moveTotals(out, delta);
  }
  return out;
}
