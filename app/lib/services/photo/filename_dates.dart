/// captured_at derivation + validation (spec §6.3).
///
/// Ports upload_photo.py `_captured_at_from_filename` and telegram_bot.py
/// `_parse_captured_at` (the validation window). Pinned by the Python tests
/// test_captured_at_survives_hash_prefixed_queue_name,
/// test_parse_captured_at_future_boundary_inclusive_at_plus_1h and
/// test_parse_captured_at_age_boundary_inclusive_at_max_age.
library;

import 'dart:typed_data';

import 'package:image/image.dart'
    show ExifData, IfdDirectory, IfdValue, IfdValueType, InputBuffer,
        decodeJpgExif;

import '../../core/contracts.dart' show ExifCapture;
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
    final offset =
        _parseExifOffset(exif.exifIfd['OffsetTimeOriginal']?.toString());
    if (wall == null || offset == null) return null;
    return (wall: wall, offset: offset);
  } catch (_) {
    return null;
  }
}

/// An EXIF '±HH:MM' zone offset, or null when missing or malformed.
Duration? _parseExifOffset(String? raw) {
  if (raw == null) return null;
  final m = _exifOffsetRe.firstMatch(raw.trim());
  if (m == null) return null;
  final hours = int.parse(m.group(2)!);
  final minutes = int.parse(m.group(3)!);
  if (hours > 14 || minutes > 59) return null; // no such zone
  final sign = m.group(1) == '-' ? -1 : 1;
  return Duration(minutes: sign * (hours * 60 + minutes));
}

/// Make / Model: at most this many characters are kept.
const int _exifTextMax = 64;

/// A pixel dimension no camera writes past.
const int _maxPixelDimension = 100000;

/// The capture facts in a JPEG or HEIC/HEIF original's own EXIF (design
/// G2a, 2026-10-24): Make and Model, the shutter's wall clock with its
/// fraction of a second and its zone, whether the GPS block names a
/// position — never the position: its tags are only tested for presence —
/// with that fix's accuracy and UTC time, and the image's pixel size.
///
/// Header-only: the JPEG's APP1 block and frame header, the HEIF's Exif
/// item ([_embeddedExif]) and image extents. The pixel size comes from the
/// frame header or the extents first — what the file really holds; a
/// resized copy can carry its original's EXIF dimensions — then from EXIF.
/// Null when none of it is there. Never throws: hostile bytes return null.
ExifCapture? exifCapture(Uint8List bytes) {
  try {
    final isJpeg = bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
    ExifData? exif;
    try {
      exif = isJpeg ? decodeJpgExif(bytes) : _embeddedExif(bytes);
    } catch (_) {
      exif = null; // a broken EXIF block still leaves the frame size
    }
    // Read-only lookups: ExifData's own getters create the directories
    // they are asked for.
    final ifd0 = exif?.directories['ifd0'];
    IfdDirectory? sub(String name) =>
        (ifd0 != null && ifd0.sub.containsKey(name)) ? ifd0.sub[name] : null;
    final exifIfd = sub('exif');
    final gps = sub('gps');

    var size = isJpeg ? _jpegFrameSize(bytes) : _heifImageSize(bytes);
    size ??= _dimensions(exifIfd?[0xa002], exifIfd?[0xa003]); // PixelX/Y
    size ??= _dimensions(ifd0?[0x100], ifd0?[0x101]); // ImageWidth/Length

    final subSecText = _exifText(exifIfd?[0x9291]); // SubSecTimeOriginal
    final capture = ExifCapture(
      make: _exifText(ifd0?[0x10f]),
      model: _exifText(ifd0?[0x110]),
      dateTimeOriginal: _parseExifDateTime(_exifText(exifIfd?[0x9003])),
      subSec: subSecText == null
          ? null
          : RegExp(r'^\d{1,9}').firstMatch(subSecText)?.group(0),
      offsetTimeOriginal: _parseExifOffset(_exifText(exifIfd?[0x9011])),
      // GPSLatitude (2) and GPSLongitude (4): present or not, nothing more.
      gpsPresent: gps != null && gps.containsKey(0x02) && gps.containsKey(0x04),
      gpsAccuracyM: _gpsAccuracy(gps?[0x1f]), // GPSHPositioningError
      gpsFixUtc: _gpsFixUtc(gps?[0x1d], gps?[0x07]), // GPSDateStamp, TimeStamp
      pixelW: size?.$1,
      pixelH: size?.$2,
    );
    final empty = capture.make == null &&
        capture.model == null &&
        capture.dateTimeOriginal == null &&
        capture.subSec == null &&
        capture.offsetTimeOriginal == null &&
        !capture.gpsPresent &&
        capture.gpsAccuracyM == null &&
        capture.gpsFixUtc == null &&
        size == null;
    return empty ? null : capture;
  } catch (_) {
    return null;
  }
}

/// A text tag's value: control characters and NUL padding out, runs of
/// whitespace collapsed, at most [max] characters; null when empty or not
/// text.
String? _exifText(IfdValue? value, {int max = _exifTextMax}) {
  if (value == null) return null;
  final String raw;
  switch (value.type) {
    case IfdValueType.ascii:
      raw = value.toString();
    case IfdValueType.undefined || IfdValueType.byte:
      raw = String.fromCharCodes(value.toData());
    default:
      return null;
  }
  final cleaned = raw
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length > max ? cleaned.substring(0, max) : cleaned;
}

/// An integer dimension tag pair as (width, height), when both are sane.
(int, int)? _dimensions(IfdValue? width, IfdValue? height) {
  int? dim(IfdValue? v) {
    if (v == null || v.length < 1) return null;
    final ok = v.type == IfdValueType.short ||
        v.type == IfdValueType.long ||
        v.type == IfdValueType.sShort ||
        v.type == IfdValueType.sLong;
    if (!ok) return null;
    final n = v.toInt();
    return n >= 1 && n <= _maxPixelDimension ? n : null;
  }

  final w = dim(width), h = dim(height);
  return (w == null || h == null) ? null : (w, h);
}

/// GPSHPositioningError in metres, when it is a sane number.
double? _gpsAccuracy(IfdValue? value) {
  if (value == null || value.length < 1) return null;
  final double metres;
  switch (value.type) {
    case IfdValueType.rational:
      final r = value.toRational();
      if (r.denominator == 0) return null; // package:image would say 0.0
      metres = r.numerator / r.denominator;
    case IfdValueType.short ||
          IfdValueType.long ||
          IfdValueType.sShort ||
          IfdValueType.sLong:
      metres = value.toInt().toDouble();
    default:
      return null;
  }
  return metres.isFinite && metres >= 0 && metres <= 1e6 ? metres : null;
}

final RegExp _gpsDateRe = RegExp(r'^(\d{4})[:-](\d{2})[:-](\d{2})');

/// GPSDateStamp ('YYYY:MM:DD', UTC) + GPSTimeStamp (hours, minutes,
/// seconds as rationals, UTC) as one UTC instant; null unless both are
/// there and valid — a time without its date says nothing.
DateTime? _gpsFixUtc(IfdValue? date, IfdValue? time) {
  final d = _gpsDateRe.firstMatch(_exifText(date) ?? '');
  if (d == null || time == null || time.length < 3) return null;
  if (time.type != IfdValueType.rational) return null;
  final parts = [for (var k = 0; k < 3; k++) time.toRational(k)];
  // A zero denominator is junk, not midnight (package:image says 0.0).
  if (parts.any((r) => r.denominator == 0)) return null;
  final year = int.parse(d.group(1)!);
  final month = int.parse(d.group(2)!);
  final day = int.parse(d.group(3)!);
  final hour = parts[0].numerator / parts[0].denominator;
  final minute = parts[1].numerator / parts[1].denominator;
  final second = parts[2].numerator / parts[2].denominator;
  if (hour < 0 || hour >= 24 || hour != hour.truncateToDouble()) return null;
  if (minute < 0 || minute >= 60 || minute != minute.truncateToDouble()) {
    return null;
  }
  if (second < 0 || second >= 61) return null;
  if (year < 1990 || year > 2200) return null;
  final whole = second.floor();
  final fix = DateTime.utc(year, month, day, hour.toInt(), minute.toInt(),
      whole, ((second - whole) * 1000).floor());
  // DateTime normalizes overflow (month 13, Feb 31): that was junk.
  if (fix.year != year || fix.month != month || fix.day != day) return null;
  return fix;
}

/// The JPEG frame header's (width, height): the first SOFn segment, met
/// by walking the segments from the start (an EXIF thumbnail's own frame
/// sits inside APP1 and is skipped with it). Null at the first scan or
/// anything malformed.
(int, int)? _jpegFrameSize(Uint8List b) {
  var i = 2;
  while (i + 3 < b.length) {
    if (b[i] != 0xff) return null;
    final marker = b[i + 1];
    if (marker == 0xff) {
      i++; // fill byte
      continue;
    }
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      i += 2; // standalone markers carry no length
      continue;
    }
    if (marker == 0xd9 || marker == 0xda) return null; // EOI / SOS first
    final length = (b[i + 2] << 8) | b[i + 3];
    if (length < 2) return null;
    final frame = marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 && // DHT
        marker != 0xc8 && // JPG extension
        marker != 0xcc; // DAC
    if (frame) {
      if (i + 8 >= b.length || length < 7) return null;
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return (w >= 1 && h >= 1) ? (w, h) : null;
    }
    i += 2 + length;
  }
  return null;
}

int _u32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

bool _fourCc(Uint8List b, int i, String type) =>
    i + 4 <= b.length &&
    b[i] == type.codeUnitAt(0) &&
    b[i + 1] == type.codeUnitAt(1) &&
    b[i + 2] == type.codeUnitAt(2) &&
    b[i + 3] == type.codeUnitAt(3);

/// A HEIF's full image size: the largest 'ispe' (image spatial extents)
/// property inside its top-level 'meta' box. Every image item has one —
/// the 512-px grid tiles and the thumbnail too — and the full image is the
/// largest. Null without a well-formed meta box.
(int, int)? _heifImageSize(Uint8List b) {
  var i = 0;
  while (i + 8 <= b.length) {
    var size = _u32(b, i);
    var header = 8;
    if (size == 1) {
      if (i + 16 > b.length || _u32(b, i + 8) != 0) return null;
      size = _u32(b, i + 12);
      header = 16;
    } else if (size == 0) {
      size = b.length - i;
    }
    if (size < header) return null;
    if (_fourCc(b, i + 4, 'meta')) {
      final end = i + size < b.length ? i + size : b.length;
      (int, int)? best;
      for (var j = i + header + 4; j + 16 <= end; j++) {
        // size 20 = header 8 + version/flags 4 + width 4 + height 4.
        if (!_fourCc(b, j, 'ispe') || _u32(b, j - 4) != 20) continue;
        final w = _u32(b, j + 8), h = _u32(b, j + 12);
        if (w < 1 || h < 1) continue;
        if (w > _maxPixelDimension || h > _maxPixelDimension) continue;
        if (best == null || w * h > best.$1 * best.$2) best = (w, h);
      }
      return best;
    }
    i += size;
  }
  return null;
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
