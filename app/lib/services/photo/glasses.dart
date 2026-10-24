/// Meta glasses recognition and the capture summary a meal keeps (design
/// G2a, 2026-10-24). Pure: no platform calls, never throws.
///
/// PhotoKit does not say which app created a photo, so a glasses photo the
/// Meta AI app imports is recognized by what it carries:
/// - its original filename ('photo-{id}_singular_display_fullPicture.HEIC'),
/// - membership in an album the Meta app keeps ('Meta AI'; the watcher
///   asks the iOS change channel's albumAssetIds once per scan),
/// - EXIF Make/Model ('Meta AI' / 'Ray-Ban Meta Smart Glasses').
/// The strings are community evidence until the hardware acceptance test
/// (design H1) checks them on a real capture, and EXIF can be written onto
/// any photo — so EXIF alone is only ever [CaptureStrength.medium], and a
/// recognized photo gains nothing a camera photo does not have: a badge,
/// diagnostics, and the stricter intake guards of later stages.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/contracts.dart';
import 'filename_dates.dart' show exifCapture;

/// The one table of recognition strings. Each is compared SQUASHED:
/// lower-cased, with everything but letters and digits removed, so
/// 'Ray-Ban', 'Ray Ban', 'RAYBAN' and 'singular-display' all match.
abstract final class MetaGlassesStrings {
  /// In the original filename of every photo the Meta AI app imports.
  static const filenameMarkers = ['singular_display'];

  /// User albums the Meta apps put imports in (matched case-insensitively
  /// by the native side, PhotoChangesPlugin.swift albumAssetIds). The Meta
  /// app sets the title, so it stays English under a Chinese phone UI.
  static const albumTitles = [
    'Meta AI',
    'Meta View',
    'Ray-Ban Meta',
    'Ray-Ban Stories',
  ];

  /// EXIF Make must contain one of these …
  static const makeTokens = ['meta'];

  /// … AND Model one of these: Make 'Meta' alone also fits an edited
  /// iPhone photo, Model alone a converter's guess.
  static const modelTokens = ['ray-ban', 'oakley', 'glasses'];
}

/// The stored device name (analysis.capture.device).
const String metaGlassesDevice = 'meta_glasses';

String _squash(String? s) =>
    (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool _containsAny(String? text, List<String> tokens) {
  final squashed = _squash(text);
  if (squashed.isEmpty) return false;
  return tokens.any((t) => squashed.contains(_squash(t)));
}

/// What [detectCaptureDevice] decided, and on what evidence.
typedef CaptureDetection = ({
  CaptureDevice device,
  CaptureStrength strength,
  CaptureSignal? signal,
});

const CaptureDetection _unknown = (
  device: CaptureDevice.unknown,
  strength: CaptureStrength.none,
  signal: null,
);

/// Which device took a photo, from its original [fileName], its EXIF
/// [make] and [model], and whether it sits in one of the Meta albums.
/// The strongest evidence names the signal: the filename, then the album
/// (both set by the Meta app itself: strong), then EXIF (medium). Never
/// throws.
CaptureDetection detectCaptureDevice({
  String? fileName,
  String? make,
  String? model,
  bool inMetaAlbum = false,
}) {
  try {
    if (_containsAny(fileName, MetaGlassesStrings.filenameMarkers)) {
      return (
        device: CaptureDevice.metaGlasses,
        strength: CaptureStrength.strong,
        signal: CaptureSignal.filename,
      );
    }
    if (inMetaAlbum) {
      return (
        device: CaptureDevice.metaGlasses,
        strength: CaptureStrength.strong,
        signal: CaptureSignal.album,
      );
    }
    if (_containsAny(make, MetaGlassesStrings.makeTokens) &&
        _containsAny(model, MetaGlassesStrings.modelTokens)) {
      return (
        device: CaptureDevice.metaGlasses,
        strength: CaptureStrength.medium,
        signal: CaptureSignal.exif,
      );
    }
  } catch (_) {}
  return _unknown;
}

/// Everything an intake knows about how [bytes] were taken: their EXIF
/// (header-only, exifCapture) and the device detection. [createDate] is
/// the library asset's creationDate (null for a shared file);
/// [inMetaAlbum] whether the asset is in a Meta album (see
/// [MetaGlassesStrings.albumTitles]). Never throws.
CaptureMeta captureMetaFor(
  Uint8List bytes,
  String fileName, {
  DateTime? createDate,
  bool inMetaAlbum = false,
}) {
  ExifCapture? exif;
  try {
    exif = exifCapture(bytes);
  } catch (_) {
    exif = null;
  }
  final found = detectCaptureDevice(
    fileName: fileName,
    make: exif?.make,
    model: exif?.model,
    inMetaAlbum: inMetaAlbum,
  );
  return CaptureMeta(
    device: found.device,
    strength: found.strength,
    signal: found.signal,
    exif: exif,
    createDate: createDate,
  );
}

/// 16 hex characters of SHA-256 over the shutter's identity —
/// DateTimeOriginal (canonical 'YYYY:MM:DD HH:MM:SS'), SubSecTimeOriginal,
/// Make and Model (trimmed, lower-cased) — joined with '|'. Two files of
/// the same shutter press (the preview and the full-size copy, an edited
/// duplicate) share it; the next stage skips such a second copy. Null
/// without DateTimeOriginal, or with nothing beside it to tell two photos
/// of the same second apart.
String? shutterKey(ExifCapture? exif) {
  final when = exif?.dateTimeOriginal;
  if (exif == null || when == null) return null;
  final subSec = exif.subSec ?? '';
  final make = (exif.make ?? '').trim().toLowerCase();
  final model = (exif.model ?? '').trim().toLowerCase();
  if (subSec.isEmpty && make.isEmpty && model.isEmpty) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${when.year.toString().padLeft(4, '0')}:${two(when.month)}:'
      '${two(when.day)} ${two(when.hour)}:${two(when.minute)}:'
      '${two(when.second)}';
  final digest = sha256.convert(utf8.encode('$stamp|$subSec|$make|$model'));
  return digest.toString().substring(0, 16);
}

/// The instant the GPS fix is compared with: the library's creationDate,
/// else (a shared file) the EXIF shutter clock when its zone is known.
DateTime? _referenceInstant(CaptureMeta capture) {
  final created = capture.createDate;
  if (created != null) return created.toUtc();
  final wall = capture.exif?.dateTimeOriginal;
  final offset = capture.exif?.offsetTimeOriginal;
  if (wall == null || offset == null) return null;
  return DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
  ).subtract(offset);
}

/// A difference no real fix has; anything past it is a broken clock.
const int _maxFixDeltaSeconds = 400 * 24 * 3600;

/// analysis['capture'] for a meal from [capture] (data contract §2):
/// `{device?, signal?, has_gps, gps_acc_m?, gps_fix_delta_s?,
/// shutter_key?}`. No coordinates and no timestamps — the fix time is kept
/// only as its difference from the photo's creation instant (fix minus
/// creation, both as UTC instants), the shutter only as a hash.
Map<String, Object> captureAnalysis(CaptureMeta capture) {
  final exif = capture.exif;
  final out = <String, Object>{};
  if (capture.isMetaGlasses) {
    out['device'] = metaGlassesDevice;
    final signal = capture.signal;
    if (signal != null) out['signal'] = signal.name;
  }
  out['has_gps'] = exif?.gpsPresent ?? false;
  final accuracy = exif?.gpsAccuracyM;
  if (accuracy != null) out['gps_acc_m'] = accuracy.round();
  final fix = exif?.gpsFixUtc;
  final reference = _referenceInstant(capture);
  if (fix != null && reference != null) {
    final delta = fix.difference(reference).inSeconds;
    if (delta.abs() <= _maxFixDeltaSeconds) out['gps_fix_delta_s'] = delta;
  }
  final key = shutterKey(exif);
  if (key != null) out['shutter_key'] = key;
  return out;
}

/// Whether a stored meal analysis says the photo came from Meta glasses
/// (analysis.capture.device). Stored analyses are untrusted: any other
/// shape is a no.
bool isMetaGlassesAnalysis(Map<String, dynamic> analysis) {
  final capture = analysis['capture'];
  return capture is Map && capture['device'] == metaGlassesDevice;
}
