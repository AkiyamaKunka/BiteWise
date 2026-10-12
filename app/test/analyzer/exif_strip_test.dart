// Privacy: the copy of a photo that is sent to the AI service (and the
// stored history thumbnail) must not carry the original's EXIF — above all
// its GPS location. package:image copies ExifData through bakeOrientation
// and copyResize, and encodeJpg writes it back; the unprocessed fallback
// used to ship the original bytes untouched.
import 'dart:typed_data';

import 'package:calorie_tracker/services/analyzer/normalize.dart';
import 'package:calorie_tracker/services/analyzer/platform_decode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 'Exif\0\0' — the APP1 EXIF signature.
const _exifSig = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

bool _hasExifSig(Uint8List b) {
  for (var i = 0; i + _exifSig.length <= b.length; i++) {
    var hit = true;
    for (var j = 0; j < _exifSig.length; j++) {
      if (b[i + j] != _exifSig[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// A JPEG carrying a GPS position, a camera Make and [orientation].
Uint8List _jpegWithGps({int width = 80, int height = 40, int orientation = 6}) {
  final src = img.Image(width: width, height: height);
  src.exif.imageIfd['Orientation'] = orientation;
  src.exif.imageIfd['Make'] = 'TestCam';
  src.exif.gpsIfd[0x0001] = img.IfdValueAscii('N'); // GPSLatitudeRef
  src.exif.gpsIfd[0x0002] = img.IfdValueRational(43, 1); // GPSLatitude
  src.exif.gpsIfd[0x0003] = img.IfdValueAscii('W'); // GPSLongitudeRef
  src.exif.gpsIfd[0x0004] = img.IfdValueRational(89, 1); // GPSLongitude
  final jpeg = Uint8List.fromList(img.encodeJpg(src));
  // Precondition: the fixture really carries the location.
  final back = img.decodeJpg(jpeg)!;
  expect(back.exif.gpsIfd[0x0002], isNotNull);
  expect(_hasExifSig(jpeg), isTrue);
  return jpeg;
}

/// Index of the first SOS marker (FF DA) in a well-formed JPEG.
int _sosIndex(Uint8List b) {
  var i = 2;
  while (b[i + 1] != 0xDA) {
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return i;
}

void _expectNoMetadata(Uint8List out) {
  expect(_hasExifSig(out), isFalse, reason: 'no APP1 EXIF block');
  final decoded = img.decodeJpg(out)!;
  expect(decoded.exif.gpsIfd.isEmpty, isTrue, reason: 'no GPS IFD');
  expect(decoded.exif.imageIfd['Make'], isNull, reason: 'no camera Make');
}

void main() {
  group('normalizeForAnalysis strips EXIF', () {
    test('Orientation 6: GPS gone, rotation still baked', () {
      final out = normalizeForAnalysis(_jpegWithGps(orientation: 6))!;
      _expectNoMetadata(out);
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (40, 80));
    });

    test('Orientation 1 (nothing to bake): GPS gone, size unchanged', () {
      final out = normalizeForAnalysis(_jpegWithGps(orientation: 1))!;
      _expectNoMetadata(out);
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (80, 40));
    });

    test('downscaled photo: GPS gone too', () {
      final out = normalizeForAnalysis(
          _jpegWithGps(width: 2000, height: 1000, orientation: 1))!;
      _expectNoMetadata(out);
      expect(img.decodeJpg(out)!.width, kAnalysisLongSidePx);
    });
  });

  group('makeMealThumb strips EXIF', () {
    test('Orientation 6: GPS gone, rotation baked', () {
      final out = makeMealThumb(_jpegWithGps(orientation: 6))!;
      _expectNoMetadata(out);
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (40, 80));
    });

    test('Orientation 1, downscaled: GPS gone', () {
      final out = makeMealThumb(
          _jpegWithGps(width: 400, height: 200, orientation: 1))!;
      _expectNoMetadata(out);
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (kThumbLongSidePx, 80));
    });
  });

  group('stripJpegMetadata', () {
    test('drops EXIF/GPS, keeps the pixels byte-for-byte', () {
      final jpeg = _jpegWithGps(orientation: 1);
      final out = stripJpegMetadata(jpeg)!;
      _expectNoMetadata(out);
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (80, 40));
      expect(out.sublist(_sosIndex(out)), jpeg.sublist(_sosIndex(jpeg)),
          reason: 'everything from SOS onward is untouched');
      expect(out.length, lessThan(jpeg.length));
    });

    test('drops an XMP APP1 segment', () {
      final plain = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 8, height: 8)));
      final xmp = 'http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta/>'.codeUnits;
      final seg = [0xFF, 0xE1, (xmp.length + 2) >> 8, (xmp.length + 2) & 0xFF,
          ...xmp];
      final withXmp =
          Uint8List.fromList([...plain.sublist(0, 2), ...seg, ...plain.sublist(2)]);
      expect(stripJpegMetadata(withXmp), plain);
    });

    test('a JPEG without APP1 passes through unchanged', () {
      final plain = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 16, height: 8)));
      expect(_hasExifSig(plain), isFalse);
      expect(stripJpegMetadata(plain), plain);
    });

    test('truncated or garbage input answers null, never throws', () {
      final jpeg = _jpegWithGps(orientation: 1);
      // Cut inside the APP1 segment, before any SOS.
      expect(stripJpegMetadata(Uint8List.sublistView(jpeg, 0, 30)), isNull);
      expect(stripJpegMetadata(Uint8List(0)), isNull);
      expect(stripJpegMetadata(Uint8List.fromList(List.filled(64, 7))),
          isNull);
      // SOI followed by a segment whose length runs past the end.
      expect(stripJpegMetadata(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])),
          isNull);
      // Length below the 2-byte minimum.
      expect(
          stripJpegMetadata(
              Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 0xFF, 0xDA])),
          isNull);
      // No SOS at all.
      expect(stripJpegMetadata(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])),
          isNull);
    });
  });

  group('unprocessedFallback', () {
    test('a small JPEG goes out WITHOUT its GPS', () {
      final jpeg = _jpegWithGps(orientation: 1);
      final out = unprocessedFallback(jpeg, maxBytes: 1 << 20)!;
      _expectNoMetadata(out);
    });

    test('a JPEG whose segments cannot be walked is not sent at all', () {
      final broken = Uint8List.sublistView(_jpegWithGps(orientation: 1), 0, 30);
      expect(looksLikeJpeg(broken), isTrue);
      expect(unprocessedFallback(broken, maxBytes: 1 << 20), isNull);
    });
  });
}
