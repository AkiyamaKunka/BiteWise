/// captured_at derivation + validation (spec §6.3).
///
/// Ports upload_photo.py `_captured_at_from_filename` and telegram_bot.py
/// `_parse_captured_at` (the validation window). Pinned by the Python tests
/// test_captured_at_survives_hash_prefixed_queue_name,
/// test_parse_captured_at_future_boundary_inclusive_at_plus_1h and
/// test_parse_captured_at_age_boundary_inclusive_at_max_age.
library;

import 'dart:typed_data';

import 'package:image/image.dart' show ExifData, InputBuffer, decodeJpgExif;

import '../../core/shared_generated.dart';

/// Port of `_FILENAME_TS_RE` (upload_photo.py): 8 digits, '_', 6 digits,
/// preceded by start-of-string or a NON-digit. The boundary rule means a
/// digit run like "920260715_193042" yields no phantom date, while a queue
/// name "123456789012__IMG_20260715_193042.jpg" still parses (spec §6.3).
final RegExp _filenameTsRe = RegExp(r'(?:^|[^0-9])(\d{8})_(\d{6})');

/// Device-local wall-clock capture time from a camera filename
/// (IMG_YYYYMMDD_HHMMSS...), or null when absent/invalid. UNVALIDATED —
/// callers apply [validateCapturedAt] before trusting it.
DateTime? capturedAtFromFilename(String? name) {
  final match = _filenameTsRe.firstMatch(name ?? '');
  if (match == null) return null;
  final d = match.group(1)!;
  final t = match.group(2)!;
  final year = int.parse(d.substring(0, 4));
  final month = int.parse(d.substring(4, 6));
  final day = int.parse(d.substring(6, 8));
  final hour = int.parse(t.substring(0, 2));
  final minute = int.parse(t.substring(2, 4));
  final second = int.parse(t.substring(4, 6));
  final parsed = DateTime(year, month, day, hour, minute, second);
  // strptime parity: Python rejects out-of-range components (month 13,
  // Feb 31); Dart's DateTime silently rolls them over, so require an exact
  // component round-trip instead.
  final valid = parsed.year == year &&
      parsed.month == month &&
      parsed.day == day &&
      parsed.hour == hour &&
      parsed.minute == minute &&
      parsed.second == second;
  return valid ? parsed : null;
}

/// Port of the string half of telegram_bot.py `_parse_captured_at`: strict
/// `YYYY-MM-DD HH:MM:SS` (strptime "%Y-%m-%d %H:%M:%S" — surrounding
/// whitespace tolerated, ISO "T" separators / date-only / missing seconds
/// are NOT), else null. Pinned by shared/vectors/captured_at.json — a lenient
/// DateTime.parse here would accept shapes the server rejects.
final RegExp _capturedAtStrRe =
    RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2}):(\d{1,2}):(\d{1,2})$');

DateTime? parseCapturedAtString(String? raw) {
  final m = _capturedAtStrRe.firstMatch((raw ?? '').trim());
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final hour = int.parse(m.group(4)!);
  final minute = int.parse(m.group(5)!);
  final second = int.parse(m.group(6)!);
  final parsed = DateTime(year, month, day, hour, minute, second);
  // strptime parity: reject out-of-range components (month 13, Feb 31) that
  // Dart's DateTime would silently roll over.
  final valid = parsed.year == year &&
      parsed.month == month &&
      parsed.day == day &&
      parsed.hour == hour &&
      parsed.minute == minute &&
      parsed.second == second;
  return valid ? parsed : null;
}

/// Full `_parse_captured_at` parity: strict string parse + validation window.
DateTime? parseCapturedAt(String? raw,
        {required DateTime now,
        int maxAgeDays = SharedConstants.capturedAtMaxAgeDaysDefault}) =>
    validateCapturedAt(parseCapturedAtString(raw),
        now: now, maxAgeDays: maxAgeDays);

/// Validation window (spec §6.3): reject values more than 1 hour in the
/// future of local [now] or older than [maxAgeDays] (CAPTURED_AT_MAX_AGE_DAYS
/// = 45, clamp 1–365). Comparisons are strict '>' / '<': exactly now+1h and
/// exactly now−maxAgeDays are ACCEPTED (both boundary tests pin inclusive).
DateTime? validateCapturedAt(DateTime? captured,
    {required DateTime now,
    int maxAgeDays = SharedConstants.capturedAtMaxAgeDaysDefault}) {
  if (captured == null) return null;
  final ageDays = maxAgeDays < 1 ? 1 : (maxAgeDays > 365 ? 365 : maxAgeDays);
  if (captured.isAfter(now.add(
      const Duration(seconds: SharedConstants.capturedAtMaxFutureSeconds)))) {
    return null;
  }
  if (captured.isBefore(now.subtract(Duration(days: ageDays)))) return null;
  return captured;
}

/// Spec §6.3 priority order: (1) filename timestamp, (2) the library asset's
/// own createDateTime — each under the same validation window — else null
/// (callers then date the meal at intake time, the §6.3 fallback).
DateTime? deriveCapturedAt(
    {required String fileName,
    DateTime? assetCreateDate,
    DateTime? now,
    int maxAgeDays = SharedConstants.capturedAtMaxAgeDaysDefault}) {
  final clock = now ?? DateTime.now();
  return validateCapturedAt(capturedAtFromFilename(fileName),
          now: clock, maxAgeDays: maxAgeDays) ??
      validateCapturedAt(assetCreateDate, now: clock, maxAgeDays: maxAgeDays);
}

/// EXIF 'YYYY:MM:DD HH:MM:SS' — colons in the DATE part, per spec. A
/// tolerant tail (some cameras write 'T' or sub-seconds) but a strict head.
final RegExp _exifDateTimeRe =
    RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})');

/// The camera's own shutter timestamp from the JPEG's EXIF block
/// (DateTimeOriginal, else the IFD0 DateTime), or null. App-only §9
/// addition (2026-07-31): the LAST dating resort before intake-time — it
/// is the only truth left for share-sheet photos whose filename carries no
/// timestamp and which have no library asset (WeChat saves, downloads).
/// EXIF carries no timezone; the value is the camera's local wall clock,
/// which is exactly what meal dating wants. UNVALIDATED — callers apply
/// [validateCapturedAt]. Never throws: hostile bytes return null.
DateTime? exifCapturedAt(Uint8List jpegBytes) {
  try {
    final exif = decodeJpgExif(jpegBytes);
    if (exif == null) return null;
    return _parseExifDateTime(
        (exif.exifIfd['DateTimeOriginal'] ?? exif.imageIfd['DateTime'])
            ?.toString());
  } catch (_) {
    return null;
  }
}

/// An EXIF 'YYYY:MM:DD HH:MM:SS' as a local-component wall clock, or null.
DateTime? _parseExifDateTime(String? raw) {
  if (raw == null) return null;
  final m = _exifDateTimeRe.firstMatch(raw.trim());
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  final dt =
      DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  // DateTime() normalizes overflow (month 13 → next year); a normalized
  // value means the EXIF was junk, not a date.
  if (dt.month != parts[1] || dt.day != parts[2] || dt.hour != parts[3]) {
    return null;
  }
  return dt;
}

/// EXIF OffsetTimeOriginal (tag 0x9011, written by iPhones): '±HH:MM'.
final RegExp _exifOffsetRe = RegExp(r'^([+-])(\d{2}):(\d{2})');

/// The shutter's wall clock AND the zone it was in: EXIF DateTimeOriginal
/// plus OffsetTimeOriginal, from a JPEG or a HEIC/HEIF original. Null when
/// either tag is missing or malformed. Never throws: hostile bytes return
/// null.
({DateTime wall, Duration offset})? exifWallAndOffset(Uint8List bytes) {
  try {
    final isJpeg = bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
    final exif = isJpeg ? decodeJpgExif(bytes) : _embeddedExif(bytes);
    if (exif == null) return null;
    final wall =
        _parseExifDateTime(exif.exifIfd['DateTimeOriginal']?.toString());
    final rawOffset = exif.exifIfd['OffsetTimeOriginal']?.toString();
    if (wall == null || rawOffset == null) return null;
    final m = _exifOffsetRe.firstMatch(rawOffset.trim());
    if (m == null) return null;
    final hours = int.parse(m.group(2)!);
    final minutes = int.parse(m.group(3)!);
    if (hours > 14 || minutes > 59) return null; // no such zone
    final sign = m.group(1) == '-' ? -1 : 1;
    return (
      wall: wall,
      offset: Duration(minutes: sign * (hours * 60 + minutes)),
    );
  } catch (_) {
    return null;
  }
}

/// The EXIF block of a non-JPEG original (HEIC/HEIF): decodeJpgExif
/// refuses anything without a JPEG SOI. A HEIF Exif item's payload is
/// 'Exif\0\0' followed by a TIFF header ('MM\0*' or 'II*\0'); requiring the
/// TIFF header skips the iinf box's 'Exif' item-type name, which is followed
/// by the next box header instead. The whole buffer is scanned: where the
/// writer puts the Exif item inside mdat is not fixed, and a few MB is
/// cheap.
ExifData? _embeddedExif(Uint8List b) {
  for (var i = 0; i + 10 <= b.length; i++) {
    if (b[i] != 0x45 || // E
        b[i + 1] != 0x78 || // x
        b[i + 2] != 0x69 || // i
        b[i + 3] != 0x66 || // f
        b[i + 4] != 0 ||
        b[i + 5] != 0) {
      continue;
    }
    final t = i + 6;
    final bigEndianTiff =
        b[t] == 0x4d && b[t + 1] == 0x4d && b[t + 2] == 0 && b[t + 3] == 0x2a;
    final littleEndianTiff =
        b[t] == 0x49 && b[t + 1] == 0x49 && b[t + 2] == 0x2a && b[t + 3] == 0;
    if (!bigEndianTiff && !littleEndianTiff) continue;
    return ExifData.fromInputBuffer(
        InputBuffer(Uint8List.sublistView(b, t), bigEndian: true));
  }
  return null;
}

/// The meal-dating clock for a photo whose [capturedAt] is an INSTANT shown
/// in the phone's CURRENT zone (iOS: the asset's createDateTime — the
/// filename carries no timestamp). A photo taken in Chicago and first
/// scanned after landing in Shanghai was dated by Shanghai's clock: a 19:10
/// dinner became 08:10 the next morning (2026-10-08). When the EXIF shutter
/// stamp minus its own zone offset is the SAME instant (±2 min), the
/// camera's wall clock in the zone where the photo was taken wins — the
/// clock the meal was eaten by, and what Android's filename timestamps
/// already give. Otherwise [capturedAt] is returned unchanged: a filename
/// wall clock read in a different zone, or EXIF without an offset, never
/// re-dates a meal.
DateTime captureWallClock(
    DateTime capturedAt, ({DateTime wall, Duration offset})? exif) {
  if (exif == null) return capturedAt;
  final w = exif.wall;
  final shutter =
      DateTime.utc(w.year, w.month, w.day, w.hour, w.minute, w.second)
          .subtract(exif.offset);
  final drift = shutter.difference(capturedAt.toUtc()).abs();
  return drift <= const Duration(minutes: 2) ? w : capturedAt;
}
