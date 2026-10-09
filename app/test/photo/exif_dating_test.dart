// EXIF shutter-time dating (§9 app-only, 2026-07-31). The user's ask,
// verbatim: "read the data of the photo of creation to make sure we are
// matching the food to the date exactly."
//
// Why this exists: share-sheet photos have NO library asset, and when the
// filename carries no timestamp (WeChat saves, downloads, UUID names) the
// §6.3 chain came up empty and the meal was silently dated at INTAKE time.
// The JPEG's own EXIF DateTimeOriginal is the camera's shutter stamp — the
// most exact record of when the food was actually in front of the lens.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/filename_dates.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../ui/fakes.dart';

/// A real 1x1 JPEG carrying real EXIF, built with the same package the
/// reader uses — no hand-crafted byte fixtures to rot.
Uint8List jpegWithExif(
    {String? dateTimeOriginal, String? ifd0DateTime, String? offset}) {
  final image = img.Image(width: 1, height: 1);
  if (dateTimeOriginal != null) {
    image.exif.exifIfd['DateTimeOriginal'] = dateTimeOriginal;
  }
  if (ifd0DateTime != null) {
    image.exif.imageIfd['DateTime'] = ifd0DateTime;
  }
  if (offset != null) image.exif.exifIfd['OffsetTimeOriginal'] = offset;
  return Uint8List.fromList(img.encodeJpg(image));
}

/// A HEIF-shaped buffer laid out like an ImageIO (iPhone) original: ftyp,
/// then an iinf entry naming the 'Exif' item type (a DECOY: 'Exif\0' is
/// followed by the next box header, not a TIFF header), then the mdat
/// payload: a 4-byte tiff-header offset, 'Exif\0\0', and the TIFF block.
Uint8List heifWithExif(
    {required String dateTimeOriginal, required String offset}) {
  final exif = img.ExifData();
  exif.exifIfd['DateTimeOriginal'] = dateTimeOriginal;
  exif.exifIfd['OffsetTimeOriginal'] = offset;
  final out = img.OutputBuffer(bigEndian: true);
  exif.write(out);
  final tiff = out.getBytes();
  final b = BytesBuilder()
    ..add([0, 0, 0, 0x18])
    ..add('ftypheic'.codeUnits)
    ..add([0, 0, 0, 0])
    ..add('mif1heic'.codeUnits)
    // infe v2: version/flags, item_ID, protection index, type 'Exif',
    // empty name '\0' — then the next infe's size: 'Exif\0\0\0\0\x15'.
    ..add([0, 0, 0, 0x15])
    ..add('infe'.codeUnits)
    ..add([2, 0, 0, 0, 0, 0x33, 0, 0])
    ..add('Exif'.codeUnits)
    ..add([0])
    ..add([0, 0, 0, 0x15])
    ..add('infe'.codeUnits)
    ..add([2, 0, 0, 0, 0, 0x34, 0, 0])
    ..add('hvc1'.codeUnits)
    ..add([0])
    ..add([0, 0, 0x10, 0])
    ..add('mdat'.codeUnits)
    ..add(List.filled(512, 0x5a)) // stand-in image data before the item
    ..add([0, 0, 0, 6])
    ..add('Exif'.codeUnits)
    ..add([0, 0])
    ..add(tiff)
    ..add(List.filled(512, 0x5a));
  return b.toBytes();
}

/// The instant photo_manager hands back for an iOS asset: an epoch value
/// shown in the CURRENT zone (DateTime.fromMillisecondsSinceEpoch).
DateTime assetInstant(DateTime utc) =>
    DateTime.fromMillisecondsSinceEpoch(utc.millisecondsSinceEpoch);

void main() {
  group('exifCapturedAt', () {
    test('reads DateTimeOriginal (the shutter stamp)', () {
      final bytes = jpegWithExif(dateTimeOriginal: '2026:07:28 19:35:07');
      expect(exifCapturedAt(bytes), DateTime(2026, 7, 28, 19, 35, 7));
    });

    test('falls back to IFD0 DateTime when the sub-IFD tag is absent', () {
      final bytes = jpegWithExif(ifd0DateTime: '2026:07:27 08:05:00');
      expect(exifCapturedAt(bytes), DateTime(2026, 7, 27, 8, 5, 0));
    });

    test('DateTimeOriginal outranks IFD0 DateTime', () {
      final bytes = jpegWithExif(
          dateTimeOriginal: '2026:07:28 19:35:07',
          ifd0DateTime: '2026:07:29 09:00:00');
      expect(exifCapturedAt(bytes), DateTime(2026, 7, 28, 19, 35, 7));
    });

    test('no EXIF, junk bytes, and junk tag values all return null', () {
      expect(exifCapturedAt(Uint8List.fromList(List.filled(64, 7))), isNull);
      expect(exifCapturedAt(jpegWithExif()), isNull);
      expect(
          exifCapturedAt(jpegWithExif(dateTimeOriginal: 'not a date')),
          isNull);
      expect(
          exifCapturedAt(jpegWithExif(dateTimeOriginal: '2026:13:45 99:00:00')),
          isNull,
          reason: 'DateTime() would silently normalize the overflow');
    });

    test('the §6.3 validation window still applies downstream', () {
      final tooOld = jpegWithExif(dateTimeOriginal: '2020:01:01 12:00:00');
      expect(
          validateCapturedAt(exifCapturedAt(tooOld), now: DateTime.now()),
          isNull,
          reason: 'a 6-year-old EXIF date must not backdate a meal');
    });
  });

  // Travel (2026-10-08): an iPhone photo's capturedAt is the asset's
  // createDateTime — an INSTANT shown in the phone's CURRENT zone. A dinner
  // shot at 19:10 in Chicago and first scanned after landing in Shanghai
  // was dated 08:10 the next morning. These pass in ANY TZ; run them under
  // TZ=Asia/Shanghai to see the travel case.
  group('zone of capture', () {
    // 12:30 in Chicago (CDT, −05:00) on Oct 8 is 17:30Z.
    final lunch = DateTime.utc(2026, 10, 8, 17, 30);
    final chicagoExif = (
      wall: DateTime(2026, 10, 8, 12, 30),
      offset: const Duration(hours: -5),
    );

    test('the camera wall clock wins when its offset names the same instant',
        () {
      final got = captureWallClock(assetInstant(lunch), chicagoExif);
      expect(got, DateTime(2026, 10, 8, 12, 30));
      expect(got.isUtc, isFalse,
          reason: 'local components, which isoDate and the clock format read');
    });

    test('a different instant keeps capturedAt (a filename wall clock read '
        'in another zone is never re-dated)', () {
      final captured = assetInstant(lunch.add(const Duration(hours: 1)));
      expect(captureWallClock(captured, chicagoExif), same(captured));
      expect(captureWallClock(captured, null), same(captured));
    });

    test('reads DateTimeOriginal + OffsetTimeOriginal from a JPEG', () {
      final got = exifWallAndOffset(jpegWithExif(
          dateTimeOriginal: '2026:10:08 12:30:00', offset: '-05:00'));
      expect(got?.wall, DateTime(2026, 10, 8, 12, 30));
      expect(got?.offset, const Duration(hours: -5));
      expect(
          exifWallAndOffset(jpegWithExif(
                  dateTimeOriginal: '2026:10:09 08:10:00', offset: '+08:00'))
              ?.offset,
          const Duration(hours: 8));
    });

    test('reads them from a HEIC past the iinf decoy', () {
      final got = exifWallAndOffset(heifWithExif(
          dateTimeOriginal: '2026:10:08 12:30:00', offset: '-05:00'));
      expect(got?.wall, DateTime(2026, 10, 8, 12, 30));
      expect(got?.offset, const Duration(hours: -5));
    });

    test('no offset, junk offset, or junk bytes → null (never throws)', () {
      expect(
          exifWallAndOffset(
              jpegWithExif(dateTimeOriginal: '2026:10:08 12:30:00')),
          isNull,
          reason: 'EXIF without a zone cannot be matched to an instant');
      expect(
          exifWallAndOffset(jpegWithExif(
              dateTimeOriginal: '2026:10:08 12:30:00', offset: 'Z')),
          isNull);
      expect(exifWallAndOffset(Uint8List.fromList(List.filled(64, 7))),
          isNull);
      expect(exifWallAndOffset(Uint8List(0)), isNull);
      final truncated = heifWithExif(
          dateTimeOriginal: '2026:10:08 12:30:00', offset: '-05:00');
      expect(
          exifWallAndOffset(Uint8List.sublistView(truncated, 0, 620)), isNull);
    });
  });

  group('pipeline dating', () {
    Future<Meal> savedMealFor(IntakePhoto photo) async {
      final dao = FakeDao();
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: FakeAnalyzer()
            ..nextPhotoOutcome = const AnalysisOutcome(
                analysis: {'is_food': true, 'total_calories': 500},
                isFood: true,
                wall: Duration.zero));
      final outcome = await pipeline.process(photo);
      expect(outcome.kind, PhotoOutcomeKind.saved, reason: outcome.message);
      return dao.meals.single;
    }

    test('a shared photo with NO capturedAt and no filename date is dated '
        'by its EXIF — the 23:50-shared-after-midnight case', () async {
      final lastNight = DateTime.now().subtract(const Duration(days: 1));
      final stamp = '${lastNight.year}:'
          '${lastNight.month.toString().padLeft(2, '0')}:'
          '${lastNight.day.toString().padLeft(2, '0')} 23:50:00';
      final meal = await savedMealFor(IntakePhoto(
          jpegWithExif(dateTimeOriginal: stamp),
          'shared-1',
          'wx_camera_88f3.jpg', // no timestamp in the name
          deliberate: true));
      expect(meal.date,
          '${lastNight.year}-${lastNight.month.toString().padLeft(2, '0')}-'
          '${lastNight.day.toString().padLeft(2, '0')}',
          reason: 'the meal belongs to the day it was EATEN');
      expect(meal.time, '11:50 PM');
    });

    test('an ANCIENT EXIF date is refused by the pipeline — the meal lands '
        'today, not in 2015', () async {
      // The §6.3 validation window must wrap the EXIF read INSIDE the
      // pipeline, not only in the unit-tested helper: a stock photo or a
      // camera with a dead clock would otherwise write a meal into a
      // random month of the log where the user will never find it.
      // (This test exists because that wrapper was silently dropped once.)
      final meal = await savedMealFor(IntakePhoto(
          jpegWithExif(dateTimeOriginal: '2015:03:04 09:00:00'),
          'old-1',
          'download.jpg',
          deliberate: true));
      final today = DateTime.now();
      expect(meal.date,
          '${today.year}-${today.month.toString().padLeft(2, '0')}-'
          '${today.day.toString().padLeft(2, '0')}');
    });

    test('a FUTURE EXIF date is refused too', () async {
      final ahead = DateTime.now().add(const Duration(days: 3));
      final stamp = '${ahead.year}:'
          '${ahead.month.toString().padLeft(2, '0')}:'
          '${ahead.day.toString().padLeft(2, '0')} 12:00:00';
      final meal = await savedMealFor(IntakePhoto(
          jpegWithExif(dateTimeOriginal: stamp), 'fut-1', 'x.jpg',
          deliberate: true));
      final today = DateTime.now();
      expect(meal.date,
          '${today.year}-${today.month.toString().padLeft(2, '0')}-'
          '${today.day.toString().padLeft(2, '0')}');
    });

    test('an intake-derived capturedAt still outranks EXIF (§6.3 order '
        'unchanged)', () async {
      final assetDate = DateTime.now().subtract(const Duration(hours: 3));
      final meal = await savedMealFor(IntakePhoto(
          jpegWithExif(dateTimeOriginal: '2026:07:01 01:01:01'),
          'asset-1',
          'IMG_1.jpg',
          capturedAt: assetDate,
          deliberate: true));
      expect(meal.time, isNot('01:01 AM'));
    });

    test('an iPhone photo scanned after a flight is dated by the clock where '
        'it was TAKEN, not the destination\'s', () async {
      // 12:30 CDT lunch on Oct 8 = 17:30Z; under TZ=Asia/Shanghai the raw
      // createDateTime reads Oct 9 01:30 AM.
      final meal = await savedMealFor(IntakePhoto(
          jpegWithExif(
              dateTimeOriginal: '2026:10:08 12:30:00', offset: '-05:00'),
          'asset-2',
          'IMG_1234.HEIC',
          capturedAt: assetInstant(DateTime.utc(2026, 10, 8, 17, 30))));
      expect(meal.date, '2026-10-08');
      expect(meal.time, '12:30 PM');
    });
  });
}
