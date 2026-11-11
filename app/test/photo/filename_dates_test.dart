// Ports the Python captured_at pinning tests (spec §6.3):
// tests/test_upload_photo.py::test_captured_at_survives_hash_prefixed_queue_name
// tests/test_telegram_bot.py::test_parse_captured_at_future_boundary_inclusive_at_plus_1h
// tests/test_telegram_bot.py::test_parse_captured_at_age_boundary_inclusive_at_max_age
import 'package:calorie_tracker/services/photo/filename_dates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Same frozen clock as the Python boundary tests.
  final frozenNow = DateTime(2026, 7, 15, 12, 0, 0);

  group('capturedAtFromFilename', () {
    test('plain camera filename parses as local wall time', () {
      expect(capturedAtFromFilename('IMG_20260716_193042.jpg'),
          DateTime(2026, 7, 16, 19, 30, 42));
    });

    test('hash-prefixed queue names survive (Python pin)', () {
      expect(capturedAtFromFilename('a3f9c2d81b04__IMG_20260715_193042.jpg'),
          DateTime(2026, 7, 15, 19, 30, 42));
      // Worst case: all-digit hash prefix directly before the date.
      expect(capturedAtFromFilename('123456789012__20260715_193042.jpg'),
          DateTime(2026, 7, 15, 19, 30, 42));
    });

    test('filename starting with the date parses (start-of-string boundary)',
        () {
      expect(capturedAtFromFilename('20260715_193042.jpg'),
          DateTime(2026, 7, 15, 19, 30, 42));
    });

    test('digit run flowing into the date yields no phantom date', () {
      // 9 digits before '_': no non-digit boundary anywhere → no match.
      expect(capturedAtFromFilename('920260715_193042.jpg'), isNull);
    });

    test('junk names return null', () {
      expect(capturedAtFromFilename(null), isNull);
      expect(capturedAtFromFilename(''), isNull);
      expect(capturedAtFromFilename('meal.jpg'), isNull);
      expect(capturedAtFromFilename('IMG_2026_0716.jpg'), isNull);
      expect(capturedAtFromFilename('IMG_20260716-193042.jpg'), isNull);
      expect(capturedAtFromFilename('IMG_2026071_193042.jpg'), isNull);
    });

    test('invalid datetimes rejected (strptime parity, no Dart rollover)', () {
      expect(capturedAtFromFilename('IMG_20261332_120000.jpg'), isNull); // m 13
      expect(capturedAtFromFilename('IMG_20260231_120000.jpg'), isNull); // Feb 31
      expect(capturedAtFromFilename('IMG_20260716_250000.jpg'), isNull); // h 25
      expect(capturedAtFromFilename('IMG_20260716_196042.jpg'), isNull); // min 60
      // Leap-day sanity: 2024-02-29 valid, 2026-02-29 not.
      expect(capturedAtFromFilename('IMG_20240229_080000.jpg'),
          DateTime(2024, 2, 29, 8, 0, 0));
      expect(capturedAtFromFilename('IMG_20260229_080000.jpg'), isNull);
    });
  });

  group('validateCapturedAt window (§6.3: <=45d old, <=+1h future)', () {
    test('future boundary inclusive at exactly +1h, rejects +1h1s', () {
      final atEdge = frozenNow.add(const Duration(hours: 1));
      expect(validateCapturedAt(atEdge, now: frozenNow), atEdge);
      expect(
          validateCapturedAt(atEdge.add(const Duration(seconds: 1)),
              now: frozenNow),
          isNull);
    });

    test('age boundary inclusive at exactly 45 days, rejects 45d1s', () {
      final atEdge = frozenNow.subtract(const Duration(days: 45));
      expect(validateCapturedAt(atEdge, now: frozenNow), atEdge);
      expect(
          validateCapturedAt(atEdge.subtract(const Duration(seconds: 1)),
              now: frozenNow),
          isNull);
    });

    test('null passes through as null', () {
      expect(validateCapturedAt(null, now: frozenNow), isNull);
    });

    test('maxAgeDays clamps to 1..365 (§8 knob range)', () {
      final twoDaysOld = frozenNow.subtract(const Duration(days: 2));
      // 0 clamps to 1 → 2-day-old value rejected.
      expect(validateCapturedAt(twoDaysOld, now: frozenNow, maxAgeDays: 0),
          isNull);
      final old400 = frozenNow.subtract(const Duration(days: 400));
      // 9999 clamps to 365 → 400-day-old value still rejected.
      expect(validateCapturedAt(old400, now: frozenNow, maxAgeDays: 9999),
          isNull);
    });
  });

  group('deriveCapturedAt priority (§6.3: filename, then asset date)', () {
    test('valid filename timestamp beats the asset create date', () {
      final assetDate = DateTime(2026, 7, 10, 9, 0, 0);
      expect(
          deriveCapturedAt(
              fileName: 'IMG_20260714_193042.jpg',
              assetCreateDate: assetDate,
              now: frozenNow),
          DateTime(2026, 7, 14, 19, 30, 42));
    });

    test('junk filename falls back to the asset create date', () {
      final assetDate = DateTime(2026, 7, 10, 9, 0, 0);
      expect(
          deriveCapturedAt(
              fileName: 'meal.jpg', assetCreateDate: assetDate, now: frozenNow),
          assetDate);
    });

    test('stale filename timestamp falls back to a valid asset date', () {
      final assetDate = DateTime(2026, 7, 10, 9, 0, 0);
      expect(
          deriveCapturedAt(
              fileName: 'IMG_20250101_120000.jpg', // > 45 days old
              assetCreateDate: assetDate,
              now: frozenNow),
          assetDate);
    });

    test('asset date is validated under the same window', () {
      final stale = frozenNow.subtract(const Duration(days: 46));
      expect(
          deriveCapturedAt(
              fileName: 'meal.jpg', assetCreateDate: stale, now: frozenNow),
          isNull);
      final future = frozenNow.add(const Duration(hours: 2));
      expect(
          deriveCapturedAt(
              fileName: 'meal.jpg', assetCreateDate: future, now: frozenNow),
          isNull);
    });

    test('nothing valid → null (fallback = intake-time dating downstream)',
        () {
      expect(deriveCapturedAt(fileName: 'meal.jpg', now: frozenNow), isNull);
    });
  });

  // RC 1.6.0 (older than 1.6.0): Google Camera stamps PXL_ names by the
  // UTC clock, and the stamp was read as the local wall clock: a 19:30
  // dinner in UTC+8 was logged at 11:30, one in Chicago scanned the next
  // morning at 01:30 the next day. TZ=UTC cannot see it; run this file
  // under another zone too, e.g. TZ=America/Chicago and TZ=Asia/Shanghai.
  group('a Pixel name (PXL_, a UTC stamp)', () {
    String two(int n) => n.toString().padLeft(2, '0');
    String stamp(DateTime local) {
      final u = local.toUtc();
      return '${u.year}${two(u.month)}${two(u.day)}_'
          '${two(u.hour)}${two(u.minute)}${two(u.second)}';
    }

    final dinner = DateTime(2026, 7, 14, 19, 30, 42);
    final breakfast = DateTime(2026, 7, 15, 7, 30, 42);

    test('is that UTC instant, shown in the local zone', () {
      expect(filenameCaptureInstant('PXL_20260714_193042123.jpg'),
          DateTime.utc(2026, 7, 14, 19, 30, 42).toLocal());
      expect(filenameCaptureInstant('a3f9c2d81b04__PXL_20260714_193042123.jpg'),
          DateTime.utc(2026, 7, 14, 19, 30, 42).toLocal(),
          reason: 'behind a queue prefix too');
      expect(filenameCaptureInstant('PXL_20260714_193042123~2.jpg'),
          DateTime.utc(2026, 7, 14, 19, 30, 42).toLocal(),
          reason: 'an edited copy keeps the stamp');
      expect(filenameCaptureInstant('PXL_20260231_120000000.jpg'), isNull,
          reason: 'Feb 31 is no instant either');
      // Every other name is the camera's local wall clock, as before.
      expect(filenameCaptureInstant('IMG_20260714_193042.jpg'),
          DateTime(2026, 7, 14, 19, 30, 42));
      expect(filenameCaptureInstant('20260714_193042.jpg'),
          DateTime(2026, 7, 14, 19, 30, 42));
      // The parity port still reads every stamp as local
      // (shared/vectors/captured_at.json).
      expect(capturedAtFromFilename('PXL_20260714_193042123.jpg'),
          DateTime(2026, 7, 14, 19, 30, 42));
    });

    test('dates the meal by when it was taken, scanned at once or the next '
        'day, with or without the library date', () {
      for (final taken in [dinner, breakfast]) {
        final name = 'PXL_${stamp(taken)}123.jpg';
        for (final later in [
          const Duration(minutes: 1),
          const Duration(hours: 14),
        ]) {
          final scannedAt = taken.add(later);
          for (final assetDate in [taken, null]) {
            final got = deriveCapturedAt(
                fileName: name, assetCreateDate: assetDate, now: scannedAt);
            expect(got, taken,
                reason: '$name taken $taken (${taken.timeZoneName}), scanned '
                    '$later later, asset date $assetDate: got $got');
            // What PhotoPipeline._mealClock then does with the photo's EXIF
            // (DateTimeOriginal + OffsetTimeOriginal, which a Pixel writes).
            expect(
                captureWallClock(
                    got!, (wall: taken, offset: taken.timeZoneOffset)),
                taken);
          }
        }
      }
    });
  });
}
