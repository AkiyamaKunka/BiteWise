part of 'executor.dart';

const double _lbToKg = 0.45359237; // nutrition.py _LB_TO_KG

// nutrition.py:416-427. The (?<![\w.]) lookbehind stops the number from
// starting mid-token ("1e72" cannot have its exponent read as 72 kg); the
// (?![a-z]) lookahead stops the unit matching mid-token ("kilometers" cannot
// be read as kilograms; the regex is case-insensitive so A-Z is covered too).
final RegExp _weightUnitRe = RegExp(
  r'(?<![\w.])(\d+(?:\.\d+)?)\s*(kgs?|kilograms?|kilos?|lbs?|pounds?)(?![a-z])',
  caseSensitive: false,
);
// Bare number guarded by an explicit weigh(ed/s/t) keyword, read as kg.
// The (?<![a-z]) boundary keeps the 'weight' inside 'overweight'/
// 'underweight' from matching — without it "overweight, ate 200 calories"
// logged a 200 kg weigh-in (pressure-test find, 2026-08-03; nutrition.py
// carries the same guard).
final RegExp _weightKeywordRe = RegExp(
  r'(?<![a-z])weigh(?:ed|s|t)?\D{0,12}?(?<![\w.])(\d+(?:\.\d+)?)',
  caseSensitive: false,
);

const Set<String> _handlerIntents = {
  'correction',
  'delete',
  'new_meal',
  'log_weight',
  'log_activity',
};

/// Python truthiness (spec §3.5 isFoodTruthy): false, 0, 0.0, '', [], {},
/// null → false; everything else → true. Consumers use raw truthiness on
/// is_food/reason, never `== true` (telegram_bot.py:842).
bool isTruthy(dynamic v) {
  if (v == null || v == false) return false;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is Iterable) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// Python `a or b`: [v] when truthy, else [fallback] (label/card formatting
/// uses `analysis.get(...) or 0` semantics — spec §4.5, §5.4).
dynamic _orElse(dynamic v, dynamic fallback) => isTruthy(v) ? v : fallback;

/// _coerce_meal_index (spec §4.3, telegram_bot.py:3953-3971): bool → null;
/// int → itself; float → int only when integral; string → trimmed int parse;
/// anything else null. A hallucinated index is "no match", never a crash.
int? coerceMealIndex(dynamic value) {
  if (value is bool) return null;
  if (value is int) return value;
  if (value is double) {
    if (!value.isFinite || value != value.truncateToDouble()) return null;
    return value.toInt();
  }
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// _normalize_nl_actions (spec §4.1, telegram_bot.py:4184-4237): coerce any
/// parsed model response — single object, {"intent":"multi","actions":[...]},
/// or the bare JSON ARRAY that crash-looped production on 2026-07-16 — into
/// an ordered list of action maps. Unusable input yields [], never a throw.
List<Map> normalizeActions(dynamic result) {
  List<dynamic> items;
  if (result is Map) {
    final actions = result['actions'];
    // Only honor "actions" when the wrapper is the designed multi shape or
    // has no recognized single intent of its own — a real single intent
    // carrying a hallucinated decomposition list must win. The `is String`
    // check is the unhashable-intent guard: a list/dict-valued intent reads
    // as "not recognized", it must not throw (spec §4.1 rule 1).
    final intent = result['intent'];
    final recognized = intent is String && _handlerIntents.contains(intent);
    final useActions = actions is List &&
        actions.isNotEmpty &&
        (intent == 'multi' || !recognized);
    items = useActions ? actions : <dynamic>[result];
  } else if (result is List) {
    items = result; // the bare-array production shape (spec §4.1 rule 2)
  } else {
    return const [];
  }

  // Rule 3: drop non-map items. Rule 4: cap at NL_MAX_ACTIONS, keep first 5.
  var usable = items.whereType<Map>().toList();
  if (usable.length > nlMaxActions) usable = usable.sublist(0, nlMaxActions);

  // Rule 5: duplicate-delete merging — there is ONE pending delete-
  // confirmation slot, so all list-typed meal_indices concatenate into the
  // FIRST delete action and the rest are dropped (telegram_bot.py:4224-4236).
  final deletes = usable.where((a) => a['intent'] == 'delete').toList();
  if (deletes.length > 1) {
    final merged = <dynamic>[];
    for (final a in deletes) {
      final indices = a['meal_indices'];
      if (indices is List) {
        merged.addAll(indices);
      } else if (indices is num && indices is! bool) {
        // Honor a bare integer, same as the single-delete path — dropping
        // it deleted FEWER meals than asked (pressure-test find,
        // 2026-08-03; telegram_bot.py fixed identically).
        merged.add(indices);
      }
    }
    deletes.first['meal_indices'] = merged;
    usable = usable
        .where((a) => a['intent'] != 'delete' || identical(a, deletes.first))
        .toList();
  }
  return usable;
}

/// parse_weight_kg (spec §4.7, nutrition.py:433-460): explicit kg/lb units
/// (lb × 0.45359237) or a bare number guarded by a weigh-keyword; rounded to
/// 1 decimal; only accepted within [30, 300] kg.
double? parseWeightKg(dynamic input) {
  if (input is! String) return null;
  // Chinese-IME normalization: fullwidth digits (７２．５) become ASCII
  // before the regexes run — Python's float() understood them natively,
  // and the phone is where a Chinese keyboard actually types now
  // (nutrition.py normalizes identically for exact parity).
  final text = input.replaceAllMapped(
      RegExp('[０-９．]'),
      (m) => m.group(0)! == '．'
          ? '.'
          : String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xff10 + 0x30));
  for (final m in _weightUnitRe.allMatches(text)) {
    final value = double.tryParse(m.group(1)!);
    if (value == null) continue;
    final unit = m.group(2)!.toLowerCase();
    final raw =
        (unit.startsWith('lb') || unit.startsWith('pound')) ? value * _lbToKg : value;
    final kg = _round1(raw);
    if (kg >= minWeightKg && kg <= maxWeightKg) return kg;
  }
  final m = _weightKeywordRe.firstMatch(text);
  if (m != null) {
    final kg = _round1(double.parse(m.group(1)!));
    if (kg >= minWeightKg && kg <= maxWeightKg) return kg;
  }
  return null;
}

/// Single-meal result card, meal-local portion of format_food_result
/// (spec §5.4, telegram_bot.py:2875-2919) rendered as plain text. The
/// running daily-totals block is the reports module's concern; the UI
/// appends it separately. [unnamed] stands in for a missing
/// meal_description; the executor passes its localized string so the
/// fallback is not the one English word in a Chinese reply.
String formatFoodResult(Map<String, dynamic> analysis,
    {String unnamed = 'Unknown meal'}) {
  if (!isTruthy(analysis['is_food'])) return '🚫 No food detected in this photo.';
  final lines = <String>['🍽️ ${analysis['meal_description'] ?? unnamed}\n'];
  for (final item in safeFoodItems(analysis)) {
    dynamic cals =
        item.containsKey('estimated_calories') ? item['estimated_calories'] : '?';
    // safe_number for numerics (JSON Infinity/NaN must never render as
    // 'Infinity kcal'; Python bools are ints there, so bool → 0); a
    // non-numeric string still displays raw (spec §3.5 display fallback).
    if (cals is bool) {
      cals = 0;
    } else if (cals is num) {
      cals = safeNumber(cals);
    }
    lines.add('  • ${item['name'] ?? '?'}: ~$cals kcal');
    lines.add('    P:${safeNumber(item['protein_g'])}g | '
        'C:${safeNumber(item['carbs_g'])}g | F:${safeNumber(item['fat_g'])}g');
  }
  final total = _orElse(analysis['total_calories'], '?'); // raw `or "?"`
  lines.add('\n📊 This meal: ~$total kcal');
  lines.add('🥩 P: ${_orElse(analysis['total_protein_g'], 0)}g | '
      '🍞 C: ${_orElse(analysis['total_carbs_g'], 0)}g | '
      '🧈 F: ${_orElse(analysis['total_fat_g'], 0)}g');
  final itemSum = mealCalorieMismatch(analysis);
  if (itemSum != null) {
    lines.add('⚠️ Item calories sum to ~$itemSum kcal but the meal total is '
        '~$total kcal — reply with a correction if this looks wrong.');
  }
  return lines.join('\n');
}

/// meals_list prompt lines in the server format (spec §1.2,
/// telegram_bot.py:4265-4281) plus the stored meal clock (spec §9): photo
/// meals are backdated and editor moves keep their timestamp, so "this
/// morning's" / "breakfast" can only be resolved from the Time field. The
/// raw stored hh:mm AM/PM goes in, never displayClock — the prompt must not
/// depend on the UI locale. Stored analyses are untrusted: safeFoodItems
/// plus stringification mean one poison row cannot break prompt building.
String buildMealsList(List<Meal> meals) {
  if (meals.isEmpty) return 'No meals logged recently.';
  final lines = <String>[];
  for (var i = 0; i < meals.length; i++) {
    final a = meals[i].analysis;
    final desc = a['meal_description'] ?? 'Unknown';
    final cal = a['total_calories'] ?? 0;
    final items =
        safeFoodItems(a).map((it) => '${it['name'] ?? '?'}').join(', ');
    lines.add(
        '[$i] Date: ${meals[i].date} | Time: ${meals[i].time} | '
        'Meal: $desc (~$cal kcal) — Items: $items');
  }
  return lines.join('\n');
}

/// The quota-pause refusal (spec §3.3/§4, telegram_bot.py:951-966 wording,
/// 4253-4261 framing) as plain text.
String _quotaPauseMessage(DateTime until) {
  final remainingSeconds =
      math.max(0, until.difference(DateTime.now()).inSeconds);
  final String remaining;
  if (remainingSeconds < 60) {
    remaining = '${remainingSeconds}s';
  } else if (remainingSeconds < 3600) {
    remaining = '${remainingSeconds ~/ 60}m';
  } else {
    remaining = '${remainingSeconds ~/ 3600}h'
        '${((remainingSeconds % 3600) ~/ 60).toString().padLeft(2, '0')}m';
  }
  final untilStr = '${isoDate(until)}T'
      '${until.hour.toString().padLeft(2, '0')}:'
      '${until.minute.toString().padLeft(2, '0')}';
  return '⏸️ Gemini is paused right now.\n\n'
      'Gemini daily free-tier quota is paused until $untilStr '
      '(about $remaining remaining).\n\n'
      'Text corrections and manual meal parsing need Gemini too, '
      'so I did not send this request.';
}

const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// strftime("%I:%M %p") parity: 12-hour, zero-padded, space, AM/PM (spec §2.2).
String _time12(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final ampm = t.hour < 12 ? 'AM' : 'PM';
  return '${h.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')} $ampm';
}

/// Python round(x, 1) equivalent for weight display/storage.
/// Python's `round(x, 1)`, not Dart's `.round()`.
///
/// The server stores weights with `round(kg, 1)`, which is round-half-to-
/// EVEN on the exact binary value; Dart's `.round()` is half-away-from-zero.
/// Measured divergence before this fix, for the same sentence typed into
/// Telegram vs the app: 72.25kg → 72.2 vs 72.3, 72.35kg → 72.3 vs 72.4, and
/// 29.95kg → rejected (29.9 is below the 30 kg floor) vs accepted as 30.0.
/// One body-weight log, two different numbers, depending on which client the
/// user happened to use. Pinned by shared/vectors/weight.json.
double _round1(num v) {
  final d = v.toDouble();
  // A TRUE tie exists only when the double is an exact multiple of 0.25
  // (i.e. .25/.5/.75 are binary-exact); then Python rounds half to EVEN.
  // Everything else — .05/.15/.35/.95 and friends — is stored slightly off
  // the tie, and Python simply rounds the exact value. Multiplying by 10
  // first would MANUFACTURE ties: 72.35 is stored as 72.34999…, but
  // 72.34999… * 10 rounds to exactly 723.5, which is how the naive version
  // answered 72.4 where the server says 72.3.
  final quarters = d * 4;
  final scaled = d * 10;
  if (quarters == quarters.truncateToDouble() &&
      scaled == scaled.truncateToDouble() + 0.5) {
    final floor = scaled.floorToDouble();
    return (floor % 2 == 0 ? floor : floor + 1) / 10;
  }
  // Correct rounding of the exact binary value, matching Python's decimal
  // rounding for every non-tie case.
  return double.parse(d.toStringAsFixed(1));
}

num _clamp(num v, num lo, num hi) => v < lo ? lo : (v > hi ? hi : v);

/// Python %g: shortest repr — integral doubles drop the ".0".
String _g(num v) {
  if (v is double && v.isFinite && v == v.truncateToDouble()) {
    return v.toInt().toString();
  }
  return v.toString();
}

/// Python f"{n:,}" thousands separators.
String _comma(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
