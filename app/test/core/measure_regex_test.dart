// assistMeasureRe (restaurant_assist_logic.dart): the bracketed weight or
// count cut from a food name for the lookup cache keys and the usual-foods
// keys. It was rewritten to match in one pass (2026-11-09: a fuzz run
// measured 20 s for one key of a 96 KB name with an unclosed bracket).
// These tests pin that the rewrite matches exactly what the first pattern
// matched, and that a huge broken name no longer stalls a key.
import 'dart:math';

import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pattern as first written: "anything, a digit, anything" in a
/// bracket pair.
final RegExp _first = RegExp(
  r'\([^()]*[0-9][^()]*\)|\[[^\[\]]*[0-9][^\[\]]*\]|【[^【】]*[0-9][^【】]*】',
);

void main() {
  test('the one-pass pattern cuts exactly what the first pattern cut', () {
    const alphabet = ['(', ')', '[', ']', '【', '】', '1', '7', 'a', 'g', ' ',
        '克', '约'];
    for (var seed = 0; seed < 4000; seed++) {
      final r = Random(20261109 + seed);
      final s = [
        for (var i = r.nextInt(24); i > 0; i--)
          alphabet[r.nextInt(alphabet.length)],
      ].join();
      expect(s.replaceAll(assistMeasureRe, '|'), s.replaceAll(_first, '|'),
          reason: 'seed $seed: "$s"');
    }
    for (final s in [
      'Big Mac (220 g)',
      'Fries (约117克)',
      'Nuggets [6 pc]',
      '米饭【2份】',
      'Oatmeal (with berries)',
      'x (a (3) b) y',
      '(1)(2)',
      '( 12',
    ]) {
      expect(s.replaceAll(assistMeasureRe, '|'), s.replaceAll(_first, '|'),
          reason: s);
    }
  });

  test('a 96 KB name with an unclosed bracket still gets its key at once',
      () {
    for (final open in ['(', '[', '【']) {
      final name = '$open${'a1 ' * 32000}';
      final watch = Stopwatch()..start();
      usualNameKey(name);
      usualDisplayName(name);
      // One pass takes milliseconds; the first pattern took about 20 s
      // here. The bound leaves a slow machine a wide margin.
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'bracket $open');
    }
  });
}
