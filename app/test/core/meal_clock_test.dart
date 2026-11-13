// The stored meal clock (meals.time) and its one codec in core/coerce.dart:
// formatClock writes it on every save path (photo, editor, typed meal, a
// usual-foods log) and parseClock reads it everywhere (display, ordering,
// the leftover window, "Around this time"). Until 2026-11-13 there were
// three writers and two readers; the photo path wrote with intl's
// DateFormat('hh:mm a'), which follows Intl.defaultLocale.
import 'package:calorie_tracker/core/coerce.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  test('formats and parses the stored 12-hour format', () {
    expect(formatClock(DateTime(2026, 7, 24, 13, 5)), '01:05 PM');
    expect(formatClock(DateTime(2026, 7, 24, 0, 30)), '12:30 AM');
    expect(formatClock(DateTime(2026, 7, 24, 12, 0)), '12:00 PM');
    expect(parseClock('01:05 PM'), (hour: 13, minute: 5));
    expect(parseClock('12:30 AM'), (hour: 0, minute: 30));
    expect(parseClock('12:00 PM'), (hour: 12, minute: 0));
  });

  test('every minute writes what the photo path stored, and reads back', () {
    for (var minute = 0; minute < 24 * 60; minute++) {
      final t = DateTime(2026, 11, 13, minute ~/ 60, minute % 60);
      final s = formatClock(t);
      expect(s, DateFormat('hh:mm a', 'en_US').format(t));
      expect(parseClock(s), (hour: t.hour, minute: t.minute), reason: s);
    }
  });

  test('the written clock ignores the ambient intl locale', () {
    final previous = Intl.defaultLocale;
    addTearDown(() => Intl.defaultLocale = previous);
    Intl.defaultLocale = 'zh';
    expect(formatClock(DateTime(2026, 11, 13, 13, 5)), '01:05 PM');
  });

  test('reads loose spellings and rejects junk', () {
    expect(parseClock(' 1:05 pm '), (hour: 13, minute: 5));
    expect(parseClock('1:05 p.m.'), (hour: 13, minute: 5));
    for (final s in [
      '',
      '25:00 PM',
      '13:00 PM',
      '07:60 AM',
      '00:30 AM',
      'noon',
      '7pm',
      '13:00',
      '下午1:05',
    ]) {
      expect(parseClock(s), isNull, reason: s);
    }
  });
}
