// The thumbnail cleaner for backup and export files (1.7.0): an allowlist
// of JPEG segments, so EXIF, XMP, MPF, comments and anything appended after
// the image never leave the phone inside a file the user can copy anywhere.
import 'dart:typed_data';

import 'package:calorie_tracker/services/backup/jpeg_strip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

bool _contains(Uint8List b, List<int> needle) {
  for (var i = 0; i + needle.length <= b.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

List<int> _ascii(String s) => s.codeUnits;

/// A segment: FF [marker] [len hi] [len lo] payload.
List<int> _segment(int marker, List<int> payload) {
  final len = payload.length + 2;
  return [0xFF, marker, len >> 8, len & 0xFF, ...payload];
}

/// A real JPEG carrying EXIF (camera make + a GPS latitude).
Uint8List _jpegWithExif() {
  final src = img.Image(width: 24, height: 16);
  img.fill(src, color: img.ColorRgb8(200, 120, 40));
  src.exif.imageIfd['Make'] = 'TestCam';
  src.exif.gpsIfd[0x0002] = img.IfdValueRational(43, 1);
  final jpeg = Uint8List.fromList(img.encodeJpg(src));
  expect(_contains(jpeg, _ascii('Exif')), isTrue, reason: 'fixture');
  return jpeg;
}

/// [jpeg] with extra segments put right after SOI, and [trailer] after EOI.
Uint8List _withSegments(Uint8List jpeg, List<List<int>> segments,
    {List<int> trailer = const []}) {
  return Uint8List.fromList([
    0xFF, 0xD8, //
    for (final s in segments) ...s,
    ...jpeg.sublist(2),
    ...trailer,
  ]);
}

void main() {
  test('EXIF, XMP, MPF, COM and other APPn go; the picture still decodes',
      () {
    final base = _jpegWithExif();
    final dirty = _withSegments(base, [
      _segment(0xE1, [..._ascii('http://ns.adobe.com/xap/1.0/\x00'), 1, 2]),
      _segment(0xE2, [..._ascii('MPF\x00'), 0, 0, 0, 0]),
      _segment(0xE2, [..._ascii('ICC_PROFILE\x00'), 1, 1, 9, 9]),
      _segment(0xE0, [..._ascii('JFXX\x00'), 0x10, 1, 2]),
      _segment(0xED, [..._ascii('Photoshop 3.0\x00'), 1]),
      _segment(0xEF, [1, 2, 3]),
      _segment(0xFE, _ascii('taken at home')),
    ], trailer: [
      0xFF, 0xD8, 0xFF, 0xE1, ..._ascii('Exif second image'), 0xFF, 0xD9 //
    ]);
    final clean = stripThumbnailJpeg(dirty)!;
    expect(_contains(clean, _ascii('Exif')), isFalse);
    expect(_contains(clean, _ascii('TestCam')), isFalse);
    expect(_contains(clean, _ascii('ns.adobe.com')), isFalse);
    expect(_contains(clean, _ascii('MPF')), isFalse);
    expect(_contains(clean, _ascii('JFXX')), isFalse);
    expect(_contains(clean, _ascii('Photoshop')), isFalse);
    expect(_contains(clean, _ascii('taken at home')), isFalse);
    expect(_contains(clean, _ascii('second image')), isFalse);
    // The ICC profile and the JFIF header stay; the image ends at its EOI.
    expect(_contains(clean, _ascii('ICC_PROFILE')), isTrue);
    expect(_contains(clean, _ascii('JFIF')), isTrue);
    expect(clean.sublist(clean.length - 2), [0xFF, 0xD9]);
    final decoded = img.decodeJpg(clean)!;
    expect(decoded.width, 24);
    expect(decoded.height, 16);
    expect(decoded.exif.isEmpty, isTrue);
  });

  test('a clean thumbnail comes back byte for byte', () {
    final src = img.Image(width: 8, height: 8);
    final plain = Uint8List.fromList(img.encodeJpg(src));
    expect(_contains(plain, _ascii('Exif')), isFalse);
    expect(stripThumbnailJpeg(plain), plain);
  });

  test('a progressive-style file with tables between two scans keeps both',
      () {
    final base = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));
    // Duplicate the scan: ... SOS data, DHT, SOS data, EOI.
    final sos = _indexOf(base, [0xFF, 0xDA]);
    final eoi = base.length - 2;
    final dht = _indexOf(base, [0xFF, 0xC4]);
    final dhtLen = (base[dht + 2] << 8) | base[dht + 3];
    final twice = Uint8List.fromList([
      ...base.sublist(0, eoi),
      ...base.sublist(dht, dht + 2 + dhtLen),
      ...base.sublist(sos, eoi),
      0xFF, 0xD9,
    ]);
    final clean = stripThumbnailJpeg(twice)!;
    expect(clean, twice);
  });

  test('what cannot be walked is refused, never passed through', () {
    final good = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));
    expect(stripThumbnailJpeg(Uint8List(0)), isNull);
    expect(stripThumbnailJpeg(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
        isNull, reason: 'a PNG');
    expect(stripThumbnailJpeg(good.sublist(0, good.length ~/ 2)), isNull,
        reason: 'truncated: no EOI');
    expect(
        stripThumbnailJpeg(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])),
        isNull,
        reason: 'no frame and no scan');
    expect(
        stripThumbnailJpeg(Uint8List.fromList(
            [0xFF, 0xD8, 0xFF, 0xE1, 0x7F, 0xFF, 1, 2, 3])),
        isNull,
        reason: 'a segment longer than the file');
  });
}

int _indexOf(Uint8List b, List<int> needle) {
  for (var i = 0; i + needle.length <= b.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}
