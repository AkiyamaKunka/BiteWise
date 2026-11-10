// Calendar-day arithmetic (2026-11-06): addCalendarDays and
// calendarDaysBetween replace `now.subtract(Duration(days: n))` and
// `difference().inDays` wherever the app means a DATE. Those are elapsed
// time, and across a DST change they named the neighbouring day in the hour
// next to midnight (found at 23:01, four days after DST ended).
//
// These cases have TEETH only where the machine's zone has DST: in UTC (CI)
// every one passes trivially. Under a US or EU zone the dates below sit on
// the 23- and 25-hour days, where the forms they replace are wrong.
import 'package:calorie_tracker/core/coerce.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('addCalendarDays', () {
    test('steps through month, year and leap-day edges', () {
      String step(DateTime d, int n) => isoDate(addCalendarDays(d, n));
      expect(step(DateTime(2026, 3, 1), -1), '2026-02-28');
      expect(step(DateTime(2024, 3, 1), -1), '2024-02-29');
      expect(step(DateTime(2026, 1, 1), -1), '2025-12-31');
      expect(step(DateTime(2026, 12, 31, 23, 59), 1), '2027-01-01');
      expect(step(DateTime(2026, 7, 17, 15), -29), '2026-06-18');
      expect(step(DateTime(2026, 7, 17, 15), 0), '2026-07-17');
      expect(step(DateTime(2026, 7, 17), -365), '2025-07-17');
    });

    test('answers a local day, never a UTC one', () {
      final d = addCalendarDays(DateTime(2026, 7, 17, 23, 59, 59), -1);
      expect(d.isUtc, isFalse);
      expect([d.year, d.month, d.day], [2026, 7, 16]);
    });

    test('the hour next to midnight around a DST change (US and EU dates)',
        () {
      for (final (now, back, want) in [
        // 23:xx from the day DST ENDS: n x 24 h back is one day short.
        (DateTime(2026, 11, 1, 23, 30), 1, '2026-10-31'), // US, the day
        (DateTime(2026, 11, 5, 23, 1), 6, '2026-10-30'), // the night found
        (DateTime(2026, 11, 5, 23, 1), 28, '2026-10-08'),
        (DateTime(2026, 11, 28, 23, 59), 29, '2026-10-30'),
        (DateTime(2026, 10, 25, 23, 30), 1, '2026-10-24'), // EU, the day
        // 00:xx after the day DST STARTS: n x 24 h back is one day over.
        (DateTime(2026, 3, 9, 0, 30), 1, '2026-03-08'), // US
        (DateTime(2026, 3, 30, 0, 30), 1, '2026-03-29'), // EU
        (DateTime(2027, 3, 20, 0, 30), 6, '2027-03-14'),
      ]) {
        expect(isoDate(addCalendarDays(now, -back)), want,
            reason: '$back days before $now');
      }
      // Ahead: 00:xx on the day DST ends, 23:xx on the eve of its start.
      expect(isoDate(addCalendarDays(DateTime(2026, 11, 1, 0, 30), 1)),
          '2026-11-02');
      expect(isoDate(addCalendarDays(DateTime(2027, 3, 13, 23, 30), 1)),
          '2027-03-14');
    });

    test('agrees with UTC-date arithmetic at every half hour of two years',
        () {
      // Whatever zone this runs in: every local wall-clock half hour of
      // 2026-2027, both sides of each of its DST changes included.
      final wrong = <String>[];
      final end = DateTime.utc(2028);
      for (var t = DateTime.utc(2026);
          t.isBefore(end);
          t = t.add(const Duration(minutes: 30))) {
        final now = t.toLocal();
        final day = DateTime.utc(now.year, now.month, now.day);
        for (final n in const [-3, -1, 1, 2, 6, 29, 30, 365]) {
          final want = isoDate(day.subtract(Duration(days: n)));
          final got = isoDate(addCalendarDays(now, -n));
          if (got != want && wrong.length < 5) wrong.add('$now -$n: $got');
        }
      }
      expect(wrong, isEmpty);
    });
  });

  group('calendarDaysBetween', () {
    test('counts calendar days in either direction, at any time of day', () {
      int days(DateTime a, DateTime b) => calendarDaysBetween(a, b);
      expect(days(DateTime(2026, 7, 17, 23, 59), DateTime(2026, 7, 18, 0, 1)),
          1,
          reason: 'two minutes apart, but tomorrow');
      expect(days(DateTime(2026, 7, 17, 0, 1), DateTime(2026, 7, 17, 23, 59)),
          0);
      expect(days(DateTime(2026, 7, 18), DateTime(2026, 7, 17, 23)), -1);
      expect(days(DateTime(2026, 2, 28), DateTime(2026, 3, 1)), 1);
      expect(days(DateTime(2024, 2, 28), DateTime(2024, 3, 1)), 2);
      expect(days(DateTime(2025, 12, 31), DateTime(2026, 1, 1)), 1);
      expect(days(DateTime(2026, 1, 1), DateTime(2027, 1, 1)), 365);
    });

    test('across the 23- and 25-hour days (US and EU dates)', () {
      int days(DateTime a, DateTime b) => calendarDaysBetween(a, b);
      // The day DST starts is 23 hours long, and `inDays` of 23 h is 0.
      expect(days(DateTime(2026, 3, 8, 12), DateTime(2026, 3, 9, 21, 30)), 1);
      expect(days(DateTime(2026, 3, 9, 12), DateTime(2026, 3, 8, 14, 2)), -1);
      expect(days(DateTime(2026, 3, 29, 12), DateTime(2026, 3, 30, 7)), 1);
      expect(days(DateTime(2026, 3, 30, 12), DateTime(2026, 3, 29, 7)), -1);
      // The 25-hour day.
      expect(days(DateTime(2026, 11, 1, 12), DateTime(2026, 11, 2, 7)), 1);
      expect(days(DateTime(2026, 11, 2, 12), DateTime(2026, 11, 1, 7)), -1);
      expect(days(DateTime(2026, 10, 25, 12), DateTime(2026, 10, 26, 7)), 1);
    });

    test('tomorrow is 1 and yesterday is -1 on every day of two years', () {
      final wrong = <String>[];
      for (var d = DateTime(2026);
          d.year < 2028;
          d = addCalendarDays(d, 1)) {
        final noon = DateTime(d.year, d.month, d.day, 12);
        final ahead = calendarDaysBetween(noon, addCalendarDays(noon, 1));
        final back = calendarDaysBetween(noon, addCalendarDays(noon, -1));
        if ((ahead != 1 || back != -1) && wrong.length < 5) {
          wrong.add('${isoDate(d)}: $ahead / $back');
        }
      }
      expect(wrong, isEmpty);
    });
  });
}
