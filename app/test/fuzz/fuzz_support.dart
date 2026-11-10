// Helpers shared by the fuzz tests in this folder. Not a test file.
//
// Every property runs over cases drawn from a seeded Random: case i of a
// property uses Random(seed + i), so one failing case replays alone from
// the seed its message prints. A failing input is cut down (shrinkList)
// before it is printed.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

extension FuzzRandom on Random {
  T pick<T>(List<T> xs) => xs[nextInt(xs.length)];

  bool chance(double p) => nextDouble() < p;

  /// [lo]..[hi], both included.
  int between(int lo, int hi) => lo + nextInt(hi - lo + 1);
}

/// A sub-list of [xs] for which [fails] still holds, found by removing
/// ever smaller chunks (delta debugging) within [budget] tries.
List<T> shrinkList<T>(
  List<T> xs,
  bool Function(List<T>) fails, {
  int budget = 300,
}) {
  var cur = List<T>.of(xs);
  var chunk = max(1, cur.length ~/ 2);
  var tries = 0;
  while (tries < budget && cur.isNotEmpty) {
    var removed = false;
    var start = 0;
    while (start < cur.length && tries < budget) {
      final end = min(start + chunk, cur.length);
      final next = [...cur.sublist(0, start), ...cur.sublist(end)];
      tries++;
      if (fails(next)) {
        cur = next;
        removed = true;
      } else {
        start = end;
      }
    }
    if (!removed) {
      if (chunk == 1) break;
      chunk = max(1, chunk ~/ 2);
    }
  }
  return cur;
}

/// [shrinkList] for a check that awaits.
Future<List<T>> shrinkListAsync<T>(
  List<T> xs,
  Future<bool> Function(List<T>) fails, {
  int budget = 120,
}) async {
  var cur = List<T>.of(xs);
  var chunk = max(1, cur.length ~/ 2);
  var tries = 0;
  while (tries < budget && cur.isNotEmpty) {
    var removed = false;
    var start = 0;
    while (start < cur.length && tries < budget) {
      final end = min(start + chunk, cur.length);
      final next = [...cur.sublist(0, start), ...cur.sublist(end)];
      tries++;
      if (await fails(next)) {
        cur = next;
        removed = true;
      } else {
        start = end;
      }
    }
    if (!removed) {
      if (chunk == 1) break;
      chunk = max(1, chunk ~/ 2);
    }
  }
  return cur;
}

/// What [body] threw, as text (with the top of the stack for anything but
/// a failed expectation), or null.
String? failureOf(void Function() body) {
  try {
    body();
    return null;
  } on TestFailure catch (e) {
    return '${e.message}';
  } catch (e, st) {
    return 'THREW ${e.runtimeType}: $e\n${_top(st)}';
  }
}

Future<String?> failureOfAsync(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } on TestFailure catch (e) {
    return '${e.message}';
  } catch (e, st) {
    return 'THREW ${e.runtimeType}: $e\n${_top(st)}';
  }
}

String _top(StackTrace st) => st.toString().split('\n').take(8).join('\n');

/// Runs [check] on [cases] inputs, input i drawn by [gen] from
/// Random([seed] + i). The first failure fails the test with its seed, the
/// input after [shrink] and what went wrong.
void forAll<T>({
  required int seed,
  required int cases,
  required T Function(Random r) gen,
  required void Function(T x) check,
  T Function(T x, bool Function(T) fails)? shrink,
  String Function(T x)? show,
}) {
  for (var i = 0; i < cases; i++) {
    final x = gen(Random(seed + i));
    var error = failureOf(() => check(x));
    if (error == null) continue;
    var small = x;
    if (shrink != null) {
      small = shrink(x, (y) => failureOf(() => check(y)) != null);
      error = failureOf(() => check(small)) ?? error;
    }
    fail(
      'seed ${seed + i} (case $i of $cases)\n'
      'input: ${(show ?? dump)(small)}\n'
      '$error',
    );
  }
}

/// A string with everything outside printable ASCII spelled as \u{hex},
/// so a failing name can be pasted back into a test.
String escaped(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x20 && r < 0x7F && r != 0x5C) {
      out.writeCharCode(r);
    } else {
      out.write('\\u{${r.toRadixString(16)}}');
    }
  }
  return out.toString();
}

/// [v] as text for a failure message: JSON where it can be, with
/// non-finite numbers and anything JSON cannot hold spelled out.
String dump(Object? v) => jsonEncode(_plain(v));

Object? _plain(Object? v) {
  if (v is double && !v.isFinite) return '<$v>';
  if (v == null || v is num || v is bool || v is String) return v;
  if (v is Map) {
    return {for (final e in v.entries) '${e.key}': _plain(e.value)};
  }
  if (v is Iterable) return [for (final e in v) _plain(e)];
  return '<${v.runtimeType}: $v>';
}

/// Equal as stored JSON would be, byte for byte: the same keys in the
/// same order, and 350 is not 350.0.
bool sameBytes(Object? a, Object? b) => dump(a) == dump(b);

/// Equal in value: maps compared without their key order, numbers by
/// value (350 equals 350.0, NaN equals NaN).
bool sameValue(Object? a, Object? b) {
  if (a is num && b is num) {
    return a == b || (a.isNaN && b.isNaN);
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !sameValue(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!sameValue(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// A deep copy of JSON-like data (maps, lists, scalars).
Object? deepCopy(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) '${e.key}': deepCopy(e.value),
    };
  }
  if (v is List) return [for (final e in v) deepCopy(e)];
  return v;
}

// ─── Calendar days without a clock ─────────────────────────────────────
//
// The oracles count calendar days with integer arithmetic only, so they
// share no DateTime or Duration step (and no daylight-saving drift) with
// the code under test.

int daysFromCivil(int y, int m, int d) {
  final yy = m <= 2 ? y - 1 : y;
  final era = yy ~/ 400;
  final yoe = yy - era * 400;
  final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468;
}

(int, int, int) civilFromDays(int days) {
  final z = days + 719468;
  final era = z ~/ 146097;
  final doe = z - era * 146097;
  final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
  final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
  final mp = (5 * doy + 2) ~/ 153;
  final d = doy - (153 * mp + 2) ~/ 5 + 1;
  final m = mp + (mp < 10 ? 3 : -9);
  final y = yoe + era * 400 + (m <= 2 ? 1 : 0);
  return (y, m, d);
}

String isoOf(int y, int m, int d) =>
    '${y.toString().padLeft(4, '0')}-'
    '${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

/// The calendar day [delta] days from [now]'s local day, as YYYY-MM-DD.
String dayIso(DateTime now, int delta) {
  final (y, m, d) = civilFromDays(
    daysFromCivil(now.year, now.month, now.day) + delta,
  );
  return isoOf(y, m, d);
}
