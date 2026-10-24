// exifCapture (design G2a): the capture facts in a photo's own EXIF, read
// from the header of a JPEG or a HEIC — Make/Model, the shutter's wall
// clock with its sub-second and zone, whether a GPS position exists (never
// the position), that fix's accuracy and UTC time, the pixel size. Hostile
// bytes return null; nothing throws.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/filename_dates.dart';
import 'package:calorie_tracker/services/photo/glasses.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A RATIONAL list (package:image does not export its Rational type).
img.IfdValue rationals(List<(int, int)> parts) {
  final v = img.IfdValueRational(parts.first.$1, parts.first.$2);
  for (final p in parts.skip(1)) {
    v.value.add(img.IfdValueRational(p.$1, p.$2).value.single);
  }
  return v;
}

/// The capture tags of a glasses photo, as the community reports them.
void fillCapture(
  img.ExifData exif, {
  String? make = 'Meta AI',
  String? model = 'Ray-Ban Meta Smart Glasses',
  String? original = '2026:10:08 12:29:58',
  String? subSec = '123',
  String? offset = '-05:00',
  bool gps = true,
  img.IfdValue? accuracy,
  String? gpsDate = '2026:10:08',
  img.IfdValue? gpsTime,
  int? pixelW,
  int? pixelH,
}) {
  if (make != null) exif.imageIfd['Make'] = make;
  if (model != null) exif.imageIfd['Model'] = model;
  if (original != null) exif.exifIfd['DateTimeOriginal'] = original;
  if (subSec != null) exif.exifIfd[0x9291] = img.IfdValueAscii(subSec);
  if (offset != null) exif.exifIfd['OffsetTimeOriginal'] = offset;
  if (pixelW != null) exif.exifIfd[0xa002] = img.IfdValueShort(pixelW);
  if (pixelH != null) exif.exifIfd[0xa003] = img.IfdValueShort(pixelH);
  if (gps) {
    exif.gpsIfd[0x0001] = img.IfdValueAscii('N'); // GPSLatitudeRef
    exif.gpsIfd[0x0002] = rationals([(43, 1), (4, 1), (3, 1)]);
    exif.gpsIfd[0x0003] = img.IfdValueAscii('W');
    exif.gpsIfd[0x0004] = rationals([(89, 1), (24, 1), (1, 1)]);
    exif.gpsIfd[0x001f] = accuracy ?? img.IfdValueRational(116, 10);
    if (gpsDate != null) exif.gpsIfd[0x001d] = img.IfdValueAscii(gpsDate);
    exif.gpsIfd[0x0007] = gpsTime ?? rationals([(17, 1), (29, 1), (2050, 100)]);
  }
}

Uint8List jpeg({
  int width = 64,
  int height = 48,
  void Function(img.ExifData exif)? tags,
}) {
  final image = img.Image(width: width, height: height);
  tags?.call(image.exif);
  return Uint8List.fromList(img.encodeJpg(image));
}

Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...payload,
  ]);
}

List<int> _u32(int v) => [
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

Uint8List _ispe(int w, int h) =>
    _box('ispe', [0, 0, 0, 0, ..._u32(w), ..._u32(h)]);

/// A HEIF laid out like an ImageIO original: ftyp; a meta box whose
/// iinf names the 'Exif' item type (a decoy) and whose ipco holds an image
/// extents property for every image item — 512-px grid tiles, the full
/// grid, a thumbnail; then mdat with the Exif item.
Uint8List heic({
  void Function(img.ExifData exif)? tags,
  List<(int, int)> extents = const [(512, 512), (4032, 3024), (320, 240)],
  bool withMeta = true,
}) {
  final exif = img.ExifData();
  tags?.call(exif);
  final out = img.OutputBuffer(bigEndian: true);
  exif.write(out);
  final tiff = out.getBytes();
  final meta = _box('meta', [
    0, 0, 0, 0, // FullBox version/flags
    ..._box('hdlr', [
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      ...'pict'.codeUnits,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]),
    ..._box('iinf', [
      0, 0, 0, 0, 0, 2, // version/flags, entry count
      ..._box('infe', [2, 0, 0, 0, 0, 0x33, 0, 0, ...'Exif'.codeUnits, 0]),
      ..._box('infe', [2, 0, 0, 0, 0, 0x34, 0, 0, ...'grid'.codeUnits, 0]),
    ]),
    ..._box('iprp', [
      ..._box('ipco', [for (final (w, h) in extents) ..._ispe(w, h)]),
    ]),
  ]);
  final b = BytesBuilder()
    ..add(
      _box('ftyp', [...'heic'.codeUnits, 0, 0, 0, 0, ...'mif1heic'.codeUnits]),
    );
  if (withMeta) b.add(meta);
  b.add(
    _box('mdat', [
      ...List.filled(512, 0x5a), // image data before the item
      0, 0, 0, 6, ...'Exif'.codeUnits, 0, 0, ...tiff,
      ...List.filled(512, 0x5a),
    ]),
  );
  return b.toBytes();
}

void main() {
  group('JPEG', () {
    test('every capture field of a glasses photo', () {
      final got = exifCapture(jpeg(tags: (e) => fillCapture(e)))!;
      expect(got.make, 'Meta AI');
      expect(got.model, 'Ray-Ban Meta Smart Glasses');
      expect(got.dateTimeOriginal, DateTime(2026, 10, 8, 12, 29, 58));
      expect(got.subSec, '123');
      expect(got.offsetTimeOriginal, const Duration(hours: -5));
      expect(got.gpsPresent, isTrue);
      expect(got.gpsAccuracyM, closeTo(11.6, 1e-9));
      expect(got.gpsFixUtc, DateTime.utc(2026, 10, 8, 17, 29, 20, 500));
      expect(got.gpsFixUtc!.isUtc, isTrue);
      expect((got.pixelW, got.pixelH), (64, 48));
    });

    test('GPS absent: gpsPresent false, no accuracy, no fix', () {
      final got = exifCapture(jpeg(tags: (e) => fillCapture(e, gps: false)))!;
      expect(got.gpsPresent, isFalse);
      expect(got.gpsAccuracyM, isNull);
      expect(got.gpsFixUtc, isNull);
      expect(got.make, 'Meta AI');
    });

    test('a GPS block with only one of latitude/longitude is no position', () {
      final got = exifCapture(
        jpeg(
          tags: (e) {
            fillCapture(e, gps: false);
            e.gpsIfd[0x0002] = rationals([(43, 1), (4, 1), (3, 1)]);
          },
        ),
      )!;
      expect(got.gpsPresent, isFalse);
    });

    test('HPositioningError: a whole number of metres, a short, junk', () {
      double? acc(img.IfdValue v) => exifCapture(
        jpeg(tags: (e) => fillCapture(e, accuracy: v)),
      )!.gpsAccuracyM;
      expect(acc(img.IfdValueRational(35, 1)), 35);
      expect(acc(img.IfdValueShort(8)), 8);
      expect(
        acc(img.IfdValueRational(5, 0)),
        isNull,
        reason: 'a zero denominator is junk, not perfect accuracy',
      );
      expect(acc(img.IfdValueAscii('12')), isNull);
    });

    test('GPS date and time: both needed, and valid', () {
      DateTime? fix({String? date = '2026:10:08', img.IfdValue? time}) =>
          exifCapture(
            jpeg(
              tags: (e) => fillCapture(e, gpsDate: date, gpsTime: time),
            ),
          )!.gpsFixUtc;
      expect(
        fix(time: rationals([(0, 1), (0, 1), (0, 1)])),
        DateTime.utc(2026, 10, 8),
      );
      expect(fix(date: null), isNull, reason: 'a time without its date');
      expect(fix(date: '2026:13:40'), isNull);
      expect(fix(time: rationals([(24, 1), (0, 1), (0, 1)])), isNull);
      expect(fix(time: rationals([(17, 1), (60, 1), (0, 1)])), isNull);
      expect(
        fix(time: rationals([(17, 1), (29, 0), (0, 1)])),
        isNull,
        reason: 'a zero denominator is junk, not minute 0',
      );
      expect(fix(time: rationals([(17, 1), (29, 1)])), isNull);
      expect(
        fix(time: rationals([(35, 2), (0, 1), (0, 1)])),
        isNull,
        reason: 'half an hour is not an hour',
      );
    });

    test('a camera photo, no glasses tags', () {
      final got = exifCapture(
        jpeg(
          tags: (e) => fillCapture(
            e,
            make: 'Apple',
            model: 'iPhone 18 Pro Max',
            subSec: '042',
            offset: '+08:00',
          ),
        ),
      )!;
      expect(got.make, 'Apple');
      expect(got.subSec, '042');
      expect(got.offsetTimeOriginal, const Duration(hours: 8));
    });

    test('text tags are cleaned: NUL padding, controls, long values', () {
      final got = exifCapture(
        jpeg(
          tags: (e) {
            fillCapture(e, make: 'Meta AI\u0000\u0000', subSec: '07  ');
            e.imageIfd['Model'] = 'X' * 300;
          },
        ),
      )!;
      expect(got.make, 'Meta AI');
      expect(got.subSec, '07');
      expect(got.model, hasLength(64));
    });

    test('the frame header wins over EXIF dimensions (a resized copy can '
        'keep its original\'s)', () {
      final got = exifCapture(
        jpeg(
          width: 40,
          height: 30,
          tags: (e) => fillCapture(e, pixelW: 4032, pixelH: 3024),
        ),
      )!;
      expect((got.pixelW, got.pixelH), (40, 30));
    });

    test('no EXIF at all: the frame size alone', () {
      final got = exifCapture(jpeg(width: 33, height: 21))!;
      expect((got.pixelW, got.pixelH), (33, 21));
      expect(got.make, isNull);
      expect(got.dateTimeOriginal, isNull);
      expect(got.gpsPresent, isFalse);
    });
  });

  group('HEIC', () {
    test('every capture field, past the iinf decoy; the largest extents', () {
      final got = exifCapture(heic(tags: (e) => fillCapture(e)))!;
      expect(got.make, 'Meta AI');
      expect(got.model, 'Ray-Ban Meta Smart Glasses');
      expect(got.dateTimeOriginal, DateTime(2026, 10, 8, 12, 29, 58));
      expect(got.subSec, '123');
      expect(got.offsetTimeOriginal, const Duration(hours: -5));
      expect(got.gpsPresent, isTrue);
      expect(got.gpsAccuracyM, closeTo(11.6, 1e-9));
      expect(got.gpsFixUtc, DateTime.utc(2026, 10, 8, 17, 29, 20, 500));
      expect(
        (got.pixelW, got.pixelH),
        (4032, 3024),
        reason: 'the full grid, not a 512-px tile or the thumbnail',
      );
    });

    test('a preview-size copy reads its own extents', () {
      final got = exifCapture(
        heic(
          tags: (e) => fillCapture(e, pixelW: 4032, pixelH: 3024),
          extents: const [(1080, 1440), (240, 320)],
        ),
      )!;
      expect((got.pixelW, got.pixelH), (1080, 1440));
    });

    test('no meta box: EXIF PixelX/YDimension', () {
      final got = exifCapture(
        heic(
          tags: (e) => fillCapture(e, pixelW: 3024, pixelH: 4032),
          withMeta: false,
        ),
      )!;
      expect((got.pixelW, got.pixelH), (3024, 4032));
    });

    test('GPS absent', () {
      final got = exifCapture(heic(tags: (e) => fillCapture(e, gps: false)))!;
      expect(got.gpsPresent, isFalse);
      expect(got.gpsFixUtc, isNull);
    });
  });

  group('hostile bytes never throw', () {
    test('junk, empty, truncated, a lying box size', () {
      expect(exifCapture(Uint8List(0)), isNull);
      expect(exifCapture(Uint8List.fromList(List.filled(64, 7))), isNull);
      expect(exifCapture(Uint8List.fromList([0xff, 0xd8])), isNull);
      final full = jpeg(tags: (e) => fillCapture(e));
      for (var cut = 0; cut < full.length; cut += 7) {
        expect(
          () => exifCapture(Uint8List.sublistView(full, 0, cut)),
          returnsNormally,
        );
      }
      final h = heic(tags: (e) => fillCapture(e));
      for (var cut = 0; cut < h.length; cut += 11) {
        expect(
          () => exifCapture(Uint8List.sublistView(h, 0, cut)),
          returnsNormally,
        );
      }
      // A box claiming 4 GB, and one claiming less than its own header.
      expect(
        exifCapture(
          Uint8List.fromList([
            0xff,
            0xff,
            0xff,
            0xff,
            ...'meta'.codeUnits,
            0,
            0,
            0,
            0,
          ]),
        ),
        isNull,
      );
      expect(
        exifCapture(Uint8List.fromList([0, 0, 0, 3, ...'meta'.codeUnits])),
        isNull,
      );
    });

    test('captureMetaFor on junk: unknown device, no EXIF', () {
      final got = captureMetaFor(Uint8List.fromList([1, 2, 3]), 'x.jpg');
      expect(got.device, CaptureDevice.unknown);
      expect(got.exif, isNull);
    });
  });

  group('captureMetaFor', () {
    test('EXIF Make/Model feed the detection; the filename outranks them', () {
      final bytes = jpeg(tags: (e) => fillCapture(e));
      final byExif = captureMetaFor(bytes, 'IMG_0042.JPG');
      expect(byExif.device, CaptureDevice.metaGlasses);
      expect(byExif.signal, CaptureSignal.exif);
      expect(byExif.strength, CaptureStrength.medium);
      final byName = captureMetaFor(
        bytes,
        'photo-1_singular_display_fullPicture.JPG',
      );
      expect(byName.signal, CaptureSignal.filename);
      final byAlbum = captureMetaFor(
        jpeg(
          tags: (e) => fillCapture(e, make: 'Apple', model: 'iPhone'),
        ),
        'IMG_0042.JPG',
        inMetaAlbum: true,
      );
      expect(byAlbum.signal, CaptureSignal.album);
      final created = DateTime.utc(2026, 10, 8, 17, 30);
      expect(
        captureMetaFor(bytes, 'a.jpg', createDate: created).createDate,
        created,
      );
    });
  });

  group('no coordinates, structurally', () {
    // The guarantee is that a position CANNOT be carried, not merely that
    // today's code does not: no member of the capture types may be one,
    // and the reader never looks at the latitude/longitude tags' values.
    String withoutComments(String src) => src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .map((l) {
          final c = l.indexOf(' // ');
          return c < 0 ? l : l.substring(0, c);
        })
        .join('\n');

    String classBody(String src, String name) {
      final start = src.indexOf('class $name ');
      expect(start, isNonNegative, reason: name);
      final end = src.indexOf('\n}\n', start);
      return src.substring(start, end);
    }

    final position = RegExp(
      r'(lat|lon|lng|latitude|longitude|coord|location)',
      caseSensitive: false,
    );

    test('ExifCapture and CaptureMeta have no position member', () {
      final src = withoutComments(
        File('lib/core/contracts.dart').readAsStringSync(),
      );
      for (final name in ['ExifCapture', 'CaptureMeta']) {
        final body = classBody(src, name);
        final members = RegExp(
          r'final\s+[\w<>?, ]+\s+(\w+);',
        ).allMatches(body).map((m) => m.group(1)!).toList();
        expect(members, isNotEmpty, reason: name);
        for (final m in members) {
          expect(position.hasMatch(m), isFalse, reason: '$name.$m');
        }
      }
    });

    test('the reader only tests the latitude/longitude tags for presence', () {
      final src = withoutComments(
        File('lib/services/photo/filename_dates.dart').readAsStringSync(),
      );
      expect(src, isNot(contains('GPSLatitude')));
      expect(src, isNot(contains('GPSLongitude')));
      expect(src, isNot(contains('gpsIfd')));
      // Indexing tag 2 or 4 would read the value; containsKey does not.
      expect(RegExp(r'\[0x0*[24]\]').hasMatch(src), isFalse);
      expect(src, contains('containsKey(0x02)'));
      expect(src, contains('containsKey(0x04)'));
    });
  });
}
