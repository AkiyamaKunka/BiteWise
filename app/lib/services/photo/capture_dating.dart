/// The glasses dating guard (design G2b, decision 'Dating guard v2',
/// 2026-10-24). Pure: no platform calls, never throws.
///
/// A photo's meal is dated by the library's creationDate (watcher.dart
/// deriveCapturedAt). When an app imports a file, PhotoKit takes that from
/// the file's EXIF (simulator probe 2026-10-23: a HEIC whose EXIF said three
/// days ago got creationDate = that instant, addedDate = the import), so a
/// glasses photo the Meta AI app copies in hours later is still dated by its
/// shutter. If an import ever stamps the import time instead, the meal lands
/// then — the next morning, for a late dinner. This guard dates such a photo
/// by its EXIF DateTimeOriginal instead, and only when ALL of these hold:
///
/// - it is a Meta glasses photo (glasses.dart);
/// - the EXIF time is valid: inside the 45-day window and at most 1 h ahead
///   (validateCapturedAt), compared as an instant when OffsetTimeOriginal
///   names its zone;
/// - createDate looks like the import time: within 2 min of the library's
///   addedDate when the library says (iOS 26+); otherwise the late-import
///   pass offered the photo, with createDate at most 10 min before that pass
///   ran;
/// - the two times differ by more than 2 min;
/// - without OffsetTimeOriginal, the difference is not shaped like a time
///   zone: within 2 min of a non-zero multiple of 15 min (and no more than
///   two zones can differ, 26 h) it is a glasses clock kept in another zone
///   — UTC, most likely — and createDate stays. A glasses clock in UTC would
///   otherwise push an evening meal in Chicago 5 h, onto the next day. With
///   the offset tag the two are compared as instants, and no such doubt
///   remains.
///
/// Every other photo — a camera photo, a shared one, a glasses photo
/// without that evidence — is dated exactly as before (photo_pipeline.dart).
library;

import '../../core/contracts.dart';
import '../../core/shared_generated.dart';
import 'filename_dates.dart' show validateCapturedAt;

/// Two times this close are the same moment; also how close createDate and
/// addedDate must be, and how near a multiple of 15 min a difference must
/// fall to look like a time zone.
const Duration captureDatingTolerance = Duration(minutes: 2);

/// Without addedDate: how long before the late-import pass that offered the
/// photo its createDate may lie and still look like the import time.
const Duration lateImportDatingWindow = Duration(minutes: 10);

/// No two time zones are further apart (UTC−12 to UTC+14): a larger
/// difference is never a zone.
const Duration _maxZoneDifference = Duration(hours: 26);

/// [d]'s wall-clock components read as UTC: differences between wall
/// clocks without the local zone's DST rules in the way.
DateTime _wallAsUtc(DateTime d) => DateTime.utc(
    d.year, d.month, d.day, d.hour, d.minute, d.second, d.millisecond,
    d.microsecond);

/// [d]'s wall-clock components as a local DateTime.
DateTime _wallAsLocal(DateTime d) => DateTime(d.year, d.month, d.day, d.hour,
    d.minute, d.second, d.millisecond, d.microsecond);

/// Whether a wall-clock [difference] is what two time zones would make:
/// within [captureDatingTolerance] of a non-zero multiple of 15 min, and no
/// more than [_maxZoneDifference].
bool zoneShapedDifference(Duration difference) {
  final seconds = difference.inSeconds.abs();
  final slack = captureDatingTolerance.inSeconds;
  if (seconds > _maxZoneDifference.inSeconds + slack) return false;
  final quarters = (seconds / 900).round();
  if (quarters == 0) return false;
  return (seconds - quarters * 900).abs() <= slack;
}

/// The time a glasses photo would be dated by if its createDate turned out
/// to be the import time: its EXIF DateTimeOriginal (the camera's wall
/// clock, as a local DateTime), when every condition of the guard but the
/// import-time evidence holds; null when the guard can never apply to it.
/// The watcher looks for the evidence of Meta glasses photos only (it also
/// gives the Glasses check card its import lag, design G3), so nearly every
/// photo costs no lookup. Never throws.
DateTime? glassesExifRedate(CaptureMeta? capture,
    {required DateTime now,
    int maxAgeDays = SharedConstants.capturedAtMaxAgeDaysDefault}) {
  try {
    if (capture == null || !capture.isMetaGlasses) return null;
    final s = _exifShutter(capture);
    if (s == null) return null;
    if (validateCapturedAt(s.shutter, now: now, maxAgeDays: maxAgeDays) ==
        null) {
      return null;
    }
    if (s.difference.abs() <= captureDatingTolerance) return null; // agree
    if (!s.zoned && zoneShapedDifference(s.difference)) return null;
    return s.wall;
  } catch (_) {
    return null;
  }
}

/// [capture]'s EXIF shutter against its createDate: the camera's wall clock
/// (as a local DateTime), the shutter as the instant validated against now,
/// whether OffsetTimeOriginal named its zone, and createDate minus the
/// shutter — as instants with the zone, else as wall clocks (the camera's
/// read as the phone's). Null without both times.
({DateTime wall, DateTime shutter, bool zoned, Duration difference})?
    _exifShutter(CaptureMeta capture) {
  final created = capture.createDate;
  final exifWall = capture.exif?.dateTimeOriginal;
  if (created == null || exifWall == null) return null;
  final wall = _wallAsLocal(exifWall);
  final offset = capture.exif?.offsetTimeOriginal;
  if (offset != null) {
    final instant = _wallAsUtc(exifWall).subtract(offset);
    return (
      wall: wall,
      shutter: instant.toLocal(),
      zoned: true,
      difference: created.toUtc().difference(instant),
    );
  }
  // No zone: the camera's wall clock, read as the phone's.
  return (
    wall: wall,
    shutter: wall,
    zoned: false,
    difference:
        _wallAsUtc(created.toLocal()).difference(_wallAsUtc(exifWall)),
  );
}

/// How long after its shutter [capture] joined the library: the library's
/// addedDate minus the moment its meal is dated by — the createDate, or,
/// where the guard ([glassesCapturedAt]) dates the photo by its EXIF
/// shutter because createDate is only the import time, that shutter (so a
/// photo imported a day late reads a day, not 0 s). For the Glasses check
/// card (design G3). Null when addedDate or createDate is unknown. Never
/// throws.
Duration? glassesImportLag(CaptureMeta? capture,
    {required DateTime now,
    int maxAgeDays = SharedConstants.capturedAtMaxAgeDaysDefault}) {
  try {
    final created = capture?.createDate, added = capture?.addedDate;
    if (capture == null || created == null || added == null) return null;
    final sinceCreated = added.difference(created);
    if (glassesCapturedAt(capture, now: now, maxAgeDays: maxAgeDays) ==
        null) {
      return sinceCreated;
    }
    final s = _exifShutter(capture);
    return s == null ? sinceCreated : sinceCreated + s.difference;
  } catch (_) {
    return null;
  }
}

/// Whether [capture]'s createDate looks like the moment the photo was
/// imported, from the evidence the intake found: the library's addedDate
/// when known (iOS 26+) — and then only it — else the late-import pass that
/// offered the photo. No evidence is a no. Never throws.
bool createDateLooksImported(CaptureMeta capture) {
  try {
    final created = capture.createDate;
    if (created == null) return false;
    final added = capture.addedDate;
    if (added != null) {
      return created.difference(added).abs() <= captureDatingTolerance;
    }
    final pass = capture.importPassAt;
    if (pass == null) return false;
    final lead = pass.difference(created); // how long before the pass
    return lead <= lateImportDatingWindow && lead >= -captureDatingTolerance;
  } catch (_) {
    return false;
  }
}

/// The guard: the EXIF wall clock to date a glasses photo's meal by, or
/// null to date it exactly as before. Never throws.
DateTime? glassesCapturedAt(CaptureMeta? capture,
    {required DateTime now,
    int maxAgeDays = SharedConstants.capturedAtMaxAgeDaysDefault}) {
  final redate =
      glassesExifRedate(capture, now: now, maxAgeDays: maxAgeDays);
  if (redate == null) return null;
  return createDateLooksImported(capture!) ? redate : null;
}
