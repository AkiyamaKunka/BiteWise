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

import 'chain_match.dart' show chainTokens;
import 'coerce.dart';
import 'contracts.dart';
import 'restaurant_assist_logic.dart' show assistMeasureRe, assistSingular;

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

/// The item's four numbers as every reader coerces them (safeNumber).
({num kcal, num p, num c, num f}) usualItemNumbers(Object? item) {
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
