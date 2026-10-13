// Privacy: the copy of a photo that is sent to the AI service (and the
// stored history thumbnail) must not carry the original's EXIF — above all
// its GPS location. package:image copies ExifData through bakeOrientation
// and copyResize, and encodeJpg writes it back; the unprocessed fallback
// used to ship the original bytes untouched.
import 'dart:convert';
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

/// 48x32, carries a GPS EXIF block, made with Python PIL (package:image
/// cannot encode either): a progressive JPEG — ten scans with a DHT between
/// most of them — and a baseline one with a restart marker every MCU.
final _progressiveWithGps = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QCcRXhpZgAATU0AKgAAAAgAAgEPAAIAAAAIAAAA'
    'JoglAAQAAAABAAAALgAAAABUZXN0Q2FtAAAEAAEAAgAAAAJOAAAAAAIABQAAAAMAAABk'
    'AAMAAgAAAAJXAAAAAAQABQAAAAMAAAB8AAAAAAAAACsAAAABAAAAAAAAAAEAAAAAAAAA'
    'AQAAAFkAAAABAAAAAAAAAAEAAAAAAAAAAf/bAEMABgQFBgUEBgYFBgcHBggKEAoKCQkK'
    'FA4PDBAXFBgYFxQWFhodJR8aGyMcFhYgLCAjJicpKikZHy0wLSgwJSgpKP/bAEMBBwcH'
    'CggKEwoKEygaFhooKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo'
    'KCgoKCgoKCgoKP/CABEIACAAMAMBIgACEQEDEQH/xAAWAAEBAQAAAAAAAAAAAAAAAAAE'
    'BQf/xAAXAQEBAQEAAAAAAAAAAAAAAAAEBQMH/9oADAMBAAIQAxAAAAHPkOQ/AKHIPXCh'
    'yD15qHIy5sFDkHrhQ5B6/wD/xAAWEAADAAAAAAAAAAAAAAAAAAAAAQL/2gAIAQEAAQUC'
    'UCgUCgUCgUCgUCgUCgUCgUCgUCgUCgUCgUCg/8QAFREBAQAAAAAAAAAAAAAAAAAAAwD/'
    '2gAIAQMBAT8BF4XheF4Xhe//xAAWEQADAAAAAAAAAAAAAAAAAAAAAgP/2gAIAQIBAT8B'
    'aw1hrDWGsNY//8QAFBABAAAAAAAAAAAAAAAAAAAAQP/aAAgBAQAGPwJH/8QAFBABAAAA'
    'AAAAAAAAAAAAAAAAQP/aAAgBAQABPyFH/wD/AP8A/wD/AP8A/9oADAMBAAIAAwAAABDG'
    'MIEEP//EABYRAAMAAAAAAAAAAAAAAAAAAAAhMf/aAAgBAwEBPxCbJsmybJsmz//EABQR'
    'AQAAAAAAAAAAAAAAAAAAACD/2gAIAQIBAT8QQAH/xAAXEAEBAQEAAAAAAAAAAAAAAAAA'
    'YSEx/9oACAEBAAE/EJppppppppppppppueJueOeJueJueJv/2Q==');
final _restartsWithGps = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QCcRXhpZgAATU0AKgAAAAgAAgEPAAIAAAAIAAAA'
    'JoglAAQAAAABAAAALgAAAABUZXN0Q2FtAAAEAAEAAgAAAAJOAAAAAAIABQAAAAMAAABk'
    'AAMAAgAAAAJXAAAAAAQABQAAAAMAAAB8AAAAAAAAACsAAAABAAAAAAAAAAEAAAAAAAAA'
    'AQAAAFkAAAABAAAAAAAAAAEAAAAAAAAAAf/bAEMABgQFBgUEBgYFBgcHBggKEAoKCQkK'
    'FA4PDBAXFBgYFxQWFhodJR8aGyMcFhYgLCAjJicpKikZHy0wLSgwJSgpKP/bAEMBBwcH'
    'CggKEwoKEygaFhooKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo'
    'KCgoKCgoKCgoKP/AABEIACAAMAMBIgACEQEDEQH/xAAfAAABBQEBAQEBAQAAAAAAAAAA'
    'AQIDBAUGBwgJCgv/xAC1EAACAQMDAgQDBQUEBAAAAX0BAgMABBEFEiExQQYTUWEHInEU'
    'MoGRoQgjQrHBFVLR8CQzYnKCCQoWFxgZGiUmJygpKjQ1Njc4OTpDREVGR0hJSlNUVVZX'
    'WFlaY2RlZmdoaWpzdHV2d3h5eoOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3'
    'uLm6wsPExcbHyMnK0tPU1dbX2Nna4eLj5OXm5+jp6vHy8/T19vf4+fr/xAAfAQADAQEB'
    'AQEBAQEBAAAAAAAAAQIDBAUGBwgJCgv/xAC1EQACAQIEBAMEBwUEBAABAncAAQIDEQQF'
    'ITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6'
    'Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqi'
    'o6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4'
    '+fr/3QAEAAH/2gAMAwEAAhEDEQA/APn6Cw9q0ILD2rbgsPatCCw9q96pjDiwWP21P//Q'
    '8egsPar8Fh7VuQWHtWhBYe1d9TGH0OCx+2p//9Hz2Cw9q0ILD2rcgsPatCCw9qVTGH6d'
    'gsftqf/S5WCw9q0ILD2rcgsOnFaEFh7Vx1MYfnmCx+2p/9OrBYe1aEFh04rcgsOnFaEF'
    'h7V4dTGHlYLH7an/1NaCw9q0ILDpxW5BYdOK0ILD2r5SpjD2cFj9tT//2Q==');

/// Every (offset, marker, length) segment from SOI to the first SOS; the SOS
/// entry runs to the end of [b].
List<(int, int, int)> _segments(Uint8List b) {
  final r = <(int, int, int)>[];
  var i = 2;
  while (i < b.length) {
    var m = i + 1;
    while (b[m] == 0xFF) {
      m++;
    }
    final mk = b[m];
    if (mk == 0xDA) {
      r.add((i, mk, b.length - i));
      break;
    }
    final len = (b[m + 1] << 8) | b[m + 2];
    r.add((i, mk, m + 1 + len - i));
    i = m + 1 + len;
  }
  return r;
}

bool _hasSeq(Uint8List b, List<int> s) {
  for (var i = 0; i + s.length <= b.length; i++) {
    var hit = true;
    for (var j = 0; j < s.length; j++) {
      if (b[i + j] != s[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

int _count(Uint8List b, List<int> s) {
  var n = 0;
  for (var i = 0; i + s.length <= b.length; i++) {
    var hit = true;
    for (var j = 0; j < s.length; j++) {
      if (b[i + j] != s[j]) {
        hit = false;
        break;
      }
    }
    if (hit) n++;
  }
  return n;
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

  group('stripJpegMetadata cuts at the primary EOI', () {
    test('an MPF-style secondary image with its own GPS is not sent', () {
      final primary = _jpegWithGps(width: 80, height: 40, orientation: 1);
      final secondary = _jpegWithGps(width: 16, height: 8, orientation: 1);
      final out = stripJpegMetadata(
          Uint8List.fromList([...primary, ...secondary]))!;
      expect(_hasExifSig(out), isFalse, reason: 'no EXIF anywhere');
      expect(out, stripJpegMetadata(primary), reason: 'ends at primary EOI');
      expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (80, 40));
    });

    test('a vendor trailer (Motion Photo video) is not sent', () {
      final primary = _jpegWithGps(width: 32, height: 16, orientation: 1);
      final trailer = [
        0, 0, 0, 0x18, ...'ftypmp42'.codeUnits, // an MP4 box
        ...'Exif'.codeUnits, 0, 0, ...'MM'.codeUnits, 0xFF, 0xD9, 0xFF, 0xE1,
      ];
      final out =
          stripJpegMetadata(Uint8List.fromList([...primary, ...trailer]))!;
      expect(out, stripJpegMetadata(primary));
      expect(_hasExifSig(out), isFalse);
    });

    test('a progressive JPEG: every scan kept, still decodes, no GPS', () {
      final jpeg = _progressiveWithGps;
      expect(_hasExifSig(jpeg), isTrue);
      expect(_count(jpeg, [0xFF, 0xDA]), greaterThan(2),
          reason: 'fixture really is multi-scan');
      final out = stripJpegMetadata(jpeg)!;
      _expectNoMetadata(out);
      expect(_count(out, [0xFF, 0xDA]), _count(jpeg, [0xFF, 0xDA]));
      expect(_count(out, [0xFF, 0xC4]), _count(jpeg, [0xFF, 0xC4]));
      final a = img.decodeJpg(jpeg)!, b = img.decodeJpg(out)!;
      expect((b.width, b.height), (48, 32));
      for (final (x, y) in [(0, 0), (20, 10), (47, 31)]) {
        expect(b.getPixel(x, y), a.getPixel(x, y));
      }
      // With a secondary image appended, still cut at the primary EOI.
      expect(
          stripJpegMetadata(Uint8List.fromList(
              [...jpeg, ..._jpegWithGps(width: 8, height: 8, orientation: 1)])),
          out);
    });

    test('restart markers inside the scan do not end it early', () {
      final jpeg = _restartsWithGps;
      final rsts = [for (var c = 0xD0; c <= 0xD7; c++) _count(jpeg, [0xFF, c])]
          .reduce((a, b) => a + b);
      expect(rsts, greaterThan(1), reason: 'fixture really has RSTn');
      final out = stripJpegMetadata(jpeg)!;
      _expectNoMetadata(out);
      expect(out.sublist(_sosIndex(out)), jpeg.sublist(_sosIndex(jpeg)));
      final a = img.decodeJpg(jpeg)!, b = img.decodeJpg(out)!;
      expect((b.width, b.height), (48, 32));
      expect(b.getPixel(40, 30), a.getPixel(40, 30));
    });

    test('a scan with no EOI (truncated) is not sent', () {
      final jpeg = _jpegWithGps(orientation: 1);
      expect(stripJpegMetadata(Uint8List.sublistView(jpeg, 0, jpeg.length - 2)),
          isNull);
      expect(
          stripJpegMetadata(Uint8List.sublistView(jpeg, 0, _sosIndex(jpeg) + 20)),
          isNull);
    });

    test('fill bytes before every marker', () {
      final orig = _jpegWithGps(orientation: 1);
      final bb = BytesBuilder()..add([0xFF, 0xD8]);
      for (final (off, _, len) in _segments(orig)) {
        bb.add([0xFF, 0xFF, 0xFF]);
        bb.add(orig.sublist(off, off + len));
      }
      final padded = bb.toBytes();
      expect(img.decodeJpg(padded), isNotNull);
      final out = stripJpegMetadata(padded)!;
      expect(_hasExifSig(out), isFalse);
      expect(img.decodeJpg(out)!.getPixel(10, 10),
          img.decodeJpg(orig)!.getPixel(10, 10));
    });

    test('APP1 after DQT, odd-length APP2, COM and extended XMP', () {
      final orig = _jpegWithGps(orientation: 1);
      final segs = _segments(orig);
      final app1 = segs.firstWhere((x) => x.$2 == 0xE1);
      final bb = BytesBuilder()..add([0xFF, 0xD8]);
      var placed = false;
      for (final (off, mk, len) in segs.where((x) => x.$2 != 0xE1)) {
        bb.add(orig.sublist(off, off + len));
        if (mk == 0xDB && !placed) {
          placed = true;
          bb.add(orig.sublist(app1.$1, app1.$1 + app1.$3));
          bb.add([0xFF, 0xE2, 0x00, 0x05, 0x41, 0x42, 0x43]); // odd APP2
          bb.add([0xFF, 0xFE, 0x00, 0x04, 0x68, 0x69]); // COM
          final x = 'http://ns.adobe.com/xmp/extension/\x00'.codeUnits;
          bb.add([0xFF, 0xE1, 0x00, x.length + 2, ...x]);
        }
      }
      final out = stripJpegMetadata(bb.toBytes())!;
      expect(_hasExifSig(out), isFalse);
      expect(_hasSeq(out, 'ns.adobe.com/xmp/extension'.codeUnits), isFalse);
      expect(_hasSeq(out, [0x41, 0x42, 0x43]), isTrue, reason: 'APP2 kept');
      expect(_hasSeq(out, [0xFF, 0xFE]), isFalse, reason: 'COM dropped');
      expect(img.decodeJpg(out)!.getPixel(30, 20),
          img.decodeJpg(orig)!.getPixel(30, 20));
    });

    test('APP11 C2PA/JUMBF (its own GPS assertion) and every other APPn go; '
        'APP0, ICC APP2 and Adobe APP14 stay', () {
      final orig = _jpegWithGps(orientation: 1);
      List<int> seg(int marker, List<int> body) =>
          [0xFF, marker, (body.length + 2) >> 8, (body.length + 2) & 0xFF,
              ...body];
      // A fake JUMBF superbox: CI + En + box len + 'jumb' + a c2pa label and
      // a stds.exif assertion naming a place.
      final jumbf = seg(0xEB, [
        ...'JP'.codeUnits, 0x00, 0x01, 0, 0, 0, 1, 0, 0, 0, 0x40,
        ...'jumb'.codeUnits, ...'c2pa'.codeUnits, 0,
        ...'stds.exif'.codeUnits, 0,
        ...'exif:GPSLatitude=43,4.4N'.codeUnits,
      ]);
      final icc = seg(0xE2, [...'ICC_PROFILE'.codeUnits, 0, 1, 1, 7, 7, 7]);
      // A real Adobe APP14 (DCTEncodeVersion 100, flags 0, transform 1).
      final adobe = seg(0xEE, [...'Adobe'.codeUnits, 0, 100, 0, 0, 0, 0, 1]);
      final app3 = seg(0xE3, 'JPS stereo'.codeUnits);
      final app15 = seg(0xEF, 'vendor'.codeUnits);
      final bb = BytesBuilder()..add([0xFF, 0xD8]);
      for (final (off, mk, len) in _segments(orig)) {
        bb.add(orig.sublist(off, off + len));
        if (mk == 0xE0) bb..add(icc)..add(jumbf)..add(adobe)..add(app3)..add(app15);
      }
      final withAll = bb.toBytes();
      expect(img.decodeJpg(withAll), isNotNull, reason: 'fixture decodes');
      final out = stripJpegMetadata(withAll)!;
      _expectNoMetadata(out);
      expect(_hasSeq(out, 'jumb'.codeUnits), isFalse, reason: 'APP11 gone');
      expect(_hasSeq(out, 'GPSLatitude'.codeUnits), isFalse);
      expect(_hasSeq(out, 'JPS stereo'.codeUnits), isFalse, reason: 'APP3');
      expect(_hasSeq(out, 'vendor'.codeUnits), isFalse, reason: 'APP15');
      expect(_hasSeq(out, icc), isTrue, reason: 'ICC APP2 kept');
      expect(_hasSeq(out, adobe), isTrue, reason: 'Adobe APP14 kept');
      expect(_segments(out).first.$2, 0xE0, reason: 'JFIF APP0 kept first');
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (80, 40));
      expect(decoded.getPixel(30, 20), img.decodeJpg(orig)!.getPixel(30, 20));
      expect(out.sublist(_sosIndex(out)), orig.sublist(_sosIndex(orig)));
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
