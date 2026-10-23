/// Coercion helpers for untrusted AI-model output.
///
/// Direct ports of utils.safe_number / safe_food_items / parse_boolish /
/// parse_ai_json from the Python codebase (see docs/APP_PORT_SPEC.md §3.5).
/// A model's JSON mode guarantees syntax, not schema — and these now sit
/// behind Gemini, OpenAI, Anthropic and a Claude-CLI round-trip, any of
/// which can answer with the wrong shape. Every field read from a model
/// response goes through here, never trusted raw.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'shared_generated.dart';

/// Bounded numeric coercion with a NULLABLE fallback — full parity with
/// Python `safe_number(value, default)` where default may be None. Returns
/// [fallback] for non-numerics, bools, NaN/Infinity, and absurd magnitudes
/// (|x| >= 1e9) so accumulations can never throw or poison a total.
num? safeNumberOr(dynamic value, num? fallback) {
  if (value is bool || value is! num) return fallback;
  final d = value.toDouble();
  if (d.isNaN || d.isInfinite) return fallback;
  if (d <= -1e9 || d >= 1e9) return fallback;
  return value;
}

/// [safeNumberOr] with the common non-null default (Python default=0 call
/// shape) — the result is always usable in arithmetic.
num safeNumber(dynamic value, {num fallback = 0}) =>
    safeNumberOr(value, fallback)!;

/// The analysis's food_items as a list of maps, tolerating any shape:
/// scalars, string entries, and non-list values all degrade to [] / skipped
/// entries rather than a crash.
List<Map<String, dynamic>> safeFoodItems(dynamic analysis) {
  if (analysis is! Map) return const [];
  final items = analysis['food_items'];
  if (items is! List) return const [];
  return items.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
}

/// meal_calorie_mismatch (spec §3.5, utils.py:75-97): item sum when it
/// contradicts the stored total by more than max(100, 20%), else null.
/// Missing/non-numeric data is treated as consistent. The one copy for chat
/// (services/nl/executor.dart) and daily reports (services/report/builders.dart).
int? mealCalorieMismatch(dynamic analysis) {
  num itemSum = 0;
  var counted = 0;
  for (final item in safeFoodItems(analysis)) {
    final cal = safeNumberOr(item['estimated_calories'], null);
    if (cal != null) {
      itemSum += cal;
      counted++;
    }
  }
  final total =
      analysis is Map ? safeNumberOr(analysis['total_calories'], null) : null;
  if (counted == 0 || itemSum <= 0 || total == null) return null;
  if ((total - itemSum).abs() >
      math.max(
          SharedConstants.mealMismatchMinKcal,
          SharedConstants.mealMismatchPct * math.max(total, itemSum))) {
    return itemSum.toInt(); // Python int(): truncation toward zero
  }
  return null;
}

/// Truthy/falsy string-or-bool coercion ("false"/"no"/"0"/"off" are false).
/// Returns null when the value is not boolean-like — callers must treat
/// null as "reject", never as false.
bool? parseBoolish(dynamic value) {
  if (value is bool) return value;
  if (value is num) {
    // Python parity (pinned by shared/vectors/coerce.json): only INTEGER 1/0
    // coerce — a float 1.0 is not boolean-like and must read as "reject".
    if (value is int) {
      if (value == 1) return true;
      if (value == 0) return false;
    }
    return null;
  }
  if (value is String) {
    // Python parity: str.strip() also removes the C0 separators U+001C–
    // U+001F (they satisfy isspace()), which Dart's Unicode-White_Space
    // trim() does not — without this a '\x1cyes\x1c' coerced true on the
    // server and null here (pressure-test find, 2026-08-03).
    final v = value
        .replaceFirst(RegExp(r'^[\s\x1c-\x1f]+'), '')
        .replaceFirst(RegExp(r'[\s\x1c-\x1f]+$'), '')
        .toLowerCase();
    if (const {'true', 'yes', 'y', '1', 'on'}.contains(v)) return true;
    if (const {'false', 'no', 'n', '0', 'off'}.contains(v)) return false;
  }
  return null;
}

/// Deep-copy [analysis] with every non-finite double (NaN/Infinity —
/// jsonDecode produces them for literals like 1e400) replaced by 0, the
/// same fallback [safeNumber] uses. jsonEncode THROWS on non-finite
/// doubles, so without this a model reply carrying one made every save
/// path fail — the meal was silently dropped with a generic "try again"
/// (pressure-test find, 2026-08-03). Structure and all other values are
/// preserved raw (spec §3.5: coercion happens on READ).
Map<String, dynamic> finiteAnalysis(Map analysis) {
  dynamic walk(dynamic v) {
    if (v is double && !v.isFinite) return 0;
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries) '${e.key}': walk(e.value)
      };
    }
    if (v is List) return [for (final e in v) walk(e)];
    return v;
  }

  return walk(analysis) as Map<String, dynamic>;
}

/// Parse JSON out of a model reply, tolerating markdown fences and prose
/// around the payload (port of utils.parse_ai_json). Throws [FormatException]
/// on unusable input — callers decide the fallback.
dynamic parseAiJson(String? text) {
  var content = (text ?? '').trim();
  if (content.startsWith('```')) {
    content = content.replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    content = content.replaceFirst(RegExp(r'\s*```$'), '');
  }
  try {
    return jsonDecode(content);
  } on FormatException {
    final starts = <int>[];
    final brace = content.indexOf('{');
    final bracket = content.indexOf('[');
    if (brace != -1) starts.add(brace);
    if (bracket != -1) starts.add(bracket);
    if (starts.isEmpty) rethrow;
    final start = starts.reduce((a, b) => a < b ? a : b);
    final endBrace = content.lastIndexOf('}');
    final endBracket = content.lastIndexOf(']');
    final end = endBrace > endBracket ? endBrace : endBracket;
    if (end <= start) rethrow;
    return jsonDecode(content.substring(start, end + 1));
  }
}

/// is_food coercion exactly as claude_analyzer/telegram_bot apply it:
/// a non-bool is_food is coerced via parseBoolish; uncoercible → null
/// (meaning: reject the whole analysis).
bool? coerceIsFood(dynamic analysis) {
  if (analysis is! Map || !analysis.containsKey('is_food')) return null;
  final raw = analysis['is_food'];
  if (raw is bool) return raw;
  return parseBoolish(raw);
}

/// Spec §3.5: Python truthiness for is_food — false, 0, 0.0, '', [], {},
/// null → false; anything else (including non-empty strings, 1, NaN) → true.
/// Consumers filter with raw truthiness, never `== true` (database.py:453-461
/// spells the same table out in SQL).
bool isFoodTruthy(dynamic value) {
  if (value == null) return false;
  if (value is bool) return value;
  // NaN != 0 is true, matching Python where NaN is truthy.
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is List) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// User-local calendar day as ISO YYYY-MM-DD (spec §2.2 clock simplification:
/// the device clock is the only clock) — the one formatter for every layer.
/// This value is WRITTEN to meals.date and compared with string ranges in
/// SQL, so it must be Gregorian with ASCII digits regardless of the device
/// locale. `DateFormat('yyyy-MM-dd')` is locale-sensitive (Buddhist-era
/// years, Eastern-Arabic digits), which on the photo/editor write paths
/// would persist dates that no query could match.
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Lowercased, hex-normalized image hash (port of _normalize_image_hash).
String normalizeImageHash(String? hash) => (hash ?? '').trim().toLowerCase();

// ---------------------------------------------------------------------------
// Meal-context fields of a photo analysis (restaurant assist, stage R1).
//
// The photo prompt (shared/prompts/food_detection_prompt.txt, MEAL CONTEXT)
// asks for estimate_confidence, restaurant_context, portion_state and
// order_merchant on the meal and brand/qty/unit on each item. All of them are
// ADDITIVE and OPTIONAL: an old server, an analysis stored before this
// change, or a model that skipped a field reads as null / "" / 1 here — and
// an unknown value never triggers anything downstream. Analyses are stored
// raw (spec §3.5: coercion happens on READ), so these are the one place a
// consumer reads the fields from.
//
// The key 'confidence' is NOT one of them: it stays reserved for the
// leftover verdict (core/leftover_logic.dart).
// ---------------------------------------------------------------------------

/// How well the photo supports the model's calorie numbers.
enum EstimateConfidence { low, medium, high }

/// Where the meal came from. The wire value "unknown" has no member: it
/// reads as null, exactly like a missing or invalid value.
enum RestaurantContext { restaurant, takeout, packaged, home }

/// How much of a serving the photo shows.
enum PortionState { whole, partial, shared, buffet }

/// Every wire value the prompt allows for restaurant_context, "unknown"
/// included (it coerces to null).
const List<String> kRestaurantContextWireValues = [
  'restaurant',
  'takeout',
  'packaged',
  'home',
  'unknown',
];

/// Longest kept brand / order_merchant, in Unicode code points.
const int kBrandMaxChars = 60;

/// Longest kept unit, in Unicode code points.
const int kUnitMaxChars = 20;

/// Largest believable item count; anything outside (0, kQtyMax] reads as 1.
const num kQtyMax = 20;

/// Case-insensitive English values, the Chinese 低/中/高 (a zh reply that
/// translated the enum despite the directive), or a number in 0..1 bucketed
/// into thirds. Anything else — a bool, NaN, a number outside 0..1, a
/// numeric STRING, free text — is null (unknown).
EstimateConfidence? coerceEstimateConfidence(dynamic value) {
  if (value is bool) return null;
  if (value is num) {
    final d = value.toDouble();
    if (!d.isFinite || d < 0 || d > 1) return null;
    if (d < 1 / 3) return EstimateConfidence.low;
    if (d < 2 / 3) return EstimateConfidence.medium;
    return EstimateConfidence.high;
  }
  if (value is! String) return null;
  return switch (value.trim().toLowerCase()) {
    'low' || '低' => EstimateConfidence.low,
    'medium' || '中' => EstimateConfidence.medium,
    'high' || '高' => EstimateConfidence.high,
    _ => null,
  };
}

/// One of the listed values, case-insensitive; "unknown", a missing or an
/// invalid value is null.
RestaurantContext? coerceRestaurantContext(dynamic value) =>
    _enumByName(RestaurantContext.values, value);

/// One of the listed values, case-insensitive; anything else is null.
PortionState? coercePortionState(dynamic value) =>
    _enumByName(PortionState.values, value);

T? _enumByName<T extends Enum>(List<T> values, dynamic value) {
  if (value is! String) return null;
  final v = value.trim().toLowerCase();
  for (final e in values) {
    if (e.name == v) return e;
  }
  return null;
}

/// An item's printed brand, cleaned for storage, display and (later) a
/// lookup request: compatibility-folded ([nfkcLite]), control, invisible and
/// bidi-override characters and every `<` `>` removed, whitespace collapsed,
/// at most [kBrandMaxChars] code points. Non-strings are "".
String cleanBrand(dynamic value) => _cleanShortText(value, kBrandMaxChars);

/// order_merchant, cleaned exactly like [cleanBrand].
String cleanOrderMerchant(dynamic value) =>
    _cleanShortText(value, kBrandMaxChars);

/// An item's unit ("cup", "slice"), cleaned like [cleanBrand] but at most
/// [kUnitMaxChars] code points.
String cleanUnit(dynamic value) => _cleanShortText(value, kUnitMaxChars);

/// An item's count: a finite number in (0, [kQtyMax]], else 1 (the
/// prompt's default). Bools and numeric strings are not counts.
num coerceQty(dynamic value) {
  if (value is bool || value is! num) return 1;
  final d = value.toDouble();
  if (!d.isFinite || d <= 0 || d > kQtyMax) return 1;
  return value;
}

/// The meal-level context fields of [analysis], coerced. A non-map analysis
/// reads as all-unknown.
({
  EstimateConfidence? estimateConfidence,
  RestaurantContext? restaurantContext,
  PortionState? portionState,
  String orderMerchant,
}) mealContextFields(dynamic analysis) {
  final a = analysis is Map ? analysis : const {};
  return (
    estimateConfidence: coerceEstimateConfidence(a['estimate_confidence']),
    restaurantContext: coerceRestaurantContext(a['restaurant_context']),
    portionState: coercePortionState(a['portion_state']),
    orderMerchant: cleanOrderMerchant(a['order_merchant']),
  );
}

/// The item-level context fields of one food item, coerced. A non-map item
/// reads as no brand, one unit, no unit name.
({String brand, num qty, String unit}) itemContextFields(dynamic item) {
  final m = item is Map ? item : const {};
  return (
    brand: cleanBrand(m['brand']),
    qty: coerceQty(m['qty']),
    unit: cleanUnit(m['unit']),
  );
}

String _cleanShortText(dynamic value, int maxChars) {
  if (value is! String) return '';
  final out = StringBuffer();
  var pendingSpace = false;
  for (final rune in nfkcLite(value).runes) {
    if (_isSpaceRune(rune)) {
      pendingSpace = out.isNotEmpty;
      continue;
    }
    if (_isStrippedRune(rune)) continue;
    if (pendingSpace) {
      out.write(' ');
      pendingSpace = false;
    }
    out.writeCharCode(rune);
  }
  final runes = out.toString().runes;
  if (runes.length <= maxChars) return out.toString();
  return String.fromCharCodes(runes.take(maxChars)).trimRight();
}

/// Whitespace, including the C0 separators U+001C–U+001F that Python's
/// str.split() also treats as whitespace (see [parseBoolish]).
bool _isSpaceRune(int r) =>
    r == 0x20 ||
    (r >= 0x09 && r <= 0x0D) ||
    (r >= 0x1C && r <= 0x1F) ||
    r == 0x85 ||
    r == 0xA0 ||
    r == 0x1680 ||
    (r >= 0x2000 && r <= 0x200A) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0x202F ||
    r == 0x205F ||
    r == 0x3000;

/// Dropped outright: the remaining C0/C1 controls, zero-width and bidi
/// control characters (a reversed or invisible brand must not reach a
/// prompt or a screen), unpaired surrogates (String.runes yields them as-is),
/// and the angle brackets.
bool _isStrippedRune(int r) =>
    r < 0x20 ||
    (r >= 0x7F && r <= 0x9F) ||
    (r >= 0xD800 && r <= 0xDFFF) ||
    r == 0x3C || // <
    r == 0x3E || // >
    r == 0x061C ||
    (r >= 0x200B && r <= 0x200F) ||
    (r >= 0x202A && r <= 0x202E) ||
    (r >= 0x2060 && r <= 0x2064) ||
    (r >= 0x2066 && r <= 0x2069) ||
    r == 0xFEFF;

/// The NFKC compatibility mappings that actually show up in brand and
/// merchant text, applied code point by code point. Dart has no Unicode
/// normalizer and the app takes no package for one, so this is a DELIBERATE
/// SUBSET of Python's unicodedata.normalize('NFKC'): on every character it
/// maps, the result is identical to NFKC; characters it does not list pass
/// through unchanged (no canonical composition, no other compatibility
/// forms). Covered: fullwidth ASCII (U+FF01–U+FF5E, the usual Chinese-IME
/// "ＫＦＣ"), the ideographic and other compatibility spaces, the Latin
/// ligatures U+FB00–U+FB06, ™ and ℠, the small < > (U+FE64/U+FE65) and the
/// dot leaders U+2024–U+2026.
String nfkcLite(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      out.writeCharCode(r - 0xFEE0);
      continue;
    }
    final mapped = _nfkcLiteTable[r];
    if (mapped != null) {
      out.write(mapped);
    } else {
      out.writeCharCode(r);
    }
  }
  return out.toString();
}

const Map<int, String> _nfkcLiteTable = {
  0x00A0: ' ',
  0x2000: ' ',
  0x2001: ' ',
  0x2002: ' ',
  0x2003: ' ',
  0x2004: ' ',
  0x2005: ' ',
  0x2006: ' ',
  0x2007: ' ',
  0x2008: ' ',
  0x2009: ' ',
  0x200A: ' ',
  0x202F: ' ',
  0x205F: ' ',
  0x3000: ' ',
  0xFB00: 'ff',
  0xFB01: 'fi',
  0xFB02: 'fl',
  0xFB03: 'ffi',
  0xFB04: 'ffl',
  0xFB05: 'st',
  0xFB06: 'st',
  0x2122: 'TM',
  0x2120: 'SM',
  0xFE64: '<',
  0xFE65: '>',
  0x2024: '.',
  0x2025: '..',
  0x2026: '...',
};
