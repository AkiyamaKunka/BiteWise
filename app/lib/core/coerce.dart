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

/// Lowercased, hex-normalized image hash (port of _normalize_image_hash).
String normalizeImageHash(String? hash) => (hash ?? '').trim().toLowerCase();
