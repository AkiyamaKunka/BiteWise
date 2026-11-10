// The card's macro grams (format.dart displayMacro): a stored whole double
// prints as a whole number. Use, a re-log and an applied lookup round the
// totals to 0.1 g, and a model reply can say 12.0 too; the card showed
// "12.0g" beside "9g" (seen in the simulator, 2026-11-09).
import 'package:calorie_tracker/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String grams(Object? v) =>
      displayMacro({'total_protein_g': v}, 'total_protein_g');

  test('a whole macro prints without ".0"; a fraction keeps its digit', () {
    expect(grams(12), '12');
    expect(grams(12.0), '12');
    expect(grams(12.5), '12.5');
    expect(grams(0.3), '0.3');
  });

  test('nothing, zero and a missing key still print 0', () {
    expect(grams(null), '0');
    expect(grams(0), '0');
    expect(grams(0.0), '0');
    expect(displayMacro(const {}, 'total_protein_g'), '0');
  });
}
