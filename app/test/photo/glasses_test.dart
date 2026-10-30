// Meta glasses recognition and the capture summary a meal keeps (design
// G2a). The strings are community evidence until the glasses arrive (H1):
// 'photo-{id}_singular_display_fullPicture.HEIC', the 'Meta AI' album, TIFF
// Make 'Meta AI' / Model 'Ray-Ban Meta Smart Glasses'. EXIF can be written
// onto any photo, so it only ever counts as medium evidence.
import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/leftover_logic.dart';
import 'package:calorie_tracker/services/nl/executor.dart' show buildMealsList;
import 'package:calorie_tracker/services/photo/glasses.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectCaptureDevice', () {
    final strongFilenames = [
      'photo-1234567890_singular_display_fullPicture.HEIC',
      'photo-42_singular_display_fullPicture.heic',
      'PHOTO-42_SINGULAR_DISPLAY_FULLPICTURE.JPG',
      'photo-42_singular-display_fullPicture.HEIC', // re-saved, dash
      'photo-42 singular display.HEIC', // spaces
      'photo-42_singular_display_fullPicture (1).HEIC', // a Files copy
    ];
    for (final name in strongFilenames) {
      test('filename "$name" → glasses, strong, filename', () {
        final got = detectCaptureDevice(fileName: name);
        expect(got.device, CaptureDevice.metaGlasses);
        expect(got.strength, CaptureStrength.strong);
        expect(got.signal, CaptureSignal.filename);
      });
    }

    test('album membership → glasses, strong, album', () {
      final got = detectCaptureDevice(
        fileName: 'IMG_0042.HEIC',
        inMetaAlbum: true,
      );
      expect(got.device, CaptureDevice.metaGlasses);
      expect(got.strength, CaptureStrength.strong);
      expect(got.signal, CaptureSignal.album);
    });

    test('the filename outranks the album and EXIF as the signal', () {
      final got = detectCaptureDevice(
        fileName: 'photo-1_singular_display_fullPicture.HEIC',
        make: 'Meta AI',
        model: 'Ray-Ban Meta Smart Glasses',
        inMetaAlbum: true,
      );
      expect(got.signal, CaptureSignal.filename);
      final album = detectCaptureDevice(
        fileName: 'IMG_1.HEIC',
        make: 'Meta AI',
        model: 'Ray-Ban Meta Smart Glasses',
        inMetaAlbum: true,
      );
      expect(album.signal, CaptureSignal.album);
    });

    final exifPairs = [
      ('Meta AI', 'Ray-Ban Meta Smart Glasses'),
      ('Meta AI', 'Ray-Ban Meta Smart Glasses 2'), // Gen 2, per a converter
      ('Meta', 'Oakley Meta HSTN'),
      ('META AI', 'RAY-BAN META'),
      ('  meta   ai ', 'ray ban meta smart glasses'), // spacing
      ('Meta', 'RayBan Meta'),
      ('Meta Platforms', 'Smart Glasses'),
    ];
    for (final (make, model) in exifPairs) {
      test('EXIF "$make" / "$model" → glasses, medium, exif', () {
        final got = detectCaptureDevice(
          fileName: 'IMG_0042.HEIC',
          make: make,
          model: model,
        );
        expect(got.device, CaptureDevice.metaGlasses);
        expect(got.strength, CaptureStrength.medium);
        expect(got.signal, CaptureSignal.exif);
      });
    }

    test('spoof: Meta glasses EXIF written onto an iPhone-named photo is '
        'medium only — never strong', () {
      final got = detectCaptureDevice(
        fileName: 'IMG_20261008_123000.jpg',
        make: 'Meta AI',
        model: 'Ray-Ban Meta Smart Glasses',
      );
      expect(got.strength, CaptureStrength.medium);
      expect(got.signal, CaptureSignal.exif);
    });

    final negatives = <String, CaptureDetection Function()>{
      'iPhone': () => detectCaptureDevice(
        fileName: 'IMG_0042.HEIC',
        make: 'Apple',
        model: 'iPhone 18 Pro Max',
      ),
      'Pixel': () => detectCaptureDevice(
        fileName: 'PXL_20261008_123000123.jpg',
        make: 'Google',
        model: 'Pixel 9',
      ),
      'WeChat save (no EXIF)': () =>
          detectCaptureDevice(fileName: 'mmexport1729000000000.jpg'),
      'Make "Meta" with an iPhone model (an edited photo)': () =>
          detectCaptureDevice(
            fileName: 'IMG_0042.HEIC',
            make: 'Meta',
            model: 'iPhone 15 Pro',
          ),
      'Model alone (a converter guess)': () => detectCaptureDevice(
        fileName: 'IMG_0042.HEIC',
        model: 'Ray-Ban Meta Smart Glasses',
      ),
      'Make alone': () =>
          detectCaptureDevice(fileName: 'IMG_0042.HEIC', make: 'Meta AI'),
      'a sunglasses brand on an Apple photo': () => detectCaptureDevice(
        fileName: 'IMG_0042.HEIC',
        make: 'Apple',
        model: 'Ray-Ban',
      ),
      'a filename that only mentions "display"': () =>
          detectCaptureDevice(fileName: 'display_singular.png'),
      'nothing at all': () => detectCaptureDevice(),
      'empty strings': () =>
          detectCaptureDevice(fileName: '', make: '', model: ''),
    };
    negatives.forEach((label, run) {
      test('negative: $label → unknown', () {
        final got = run();
        expect(got.device, CaptureDevice.unknown);
        expect(got.strength, CaptureStrength.none);
        expect(got.signal, isNull);
      });
    });

    test('the album titles the watcher asks about are the table', () {
      expect(MetaGlassesStrings.albumTitles, [
        'Meta AI',
        'Meta View',
        'Ray-Ban Meta',
        'Ray-Ban Stories',
      ]);
    });
  });

  group('captureAnalysis (analysis.capture, data contract §2)', () {
    final created = DateTime.utc(2026, 10, 8, 17, 30, 0);
    final exif = ExifCapture(
      make: 'Meta AI',
      model: 'Ray-Ban Meta Smart Glasses',
      dateTimeOriginal: DateTime(2026, 10, 8, 12, 29, 58),
      subSec: '123',
      offsetTimeOriginal: const Duration(hours: -5),
      gpsPresent: true,
      gpsAccuracyM: 11.6,
      gpsFixUtc: DateTime.utc(2026, 10, 8, 17, 29, 20),
      pixelW: 3024,
      pixelH: 4032,
    );

    test('a glasses photo: every field, nothing else', () {
      final got = captureAnalysis(
        CaptureMeta(
          device: CaptureDevice.metaGlasses,
          strength: CaptureStrength.strong,
          signal: CaptureSignal.filename,
          exif: exif,
          createDate: created,
        ),
      );
      expect(got, {
        'device': 'meta_glasses',
        'signal': 'filename',
        'has_gps': true,
        'gps_acc_m': 12,
        'gps_fix_delta_s': -40, // the fix came 40 s before the creation
        'shutter_key': shutterKey(exif),
      });
      expect(got['shutter_key'], matches(RegExp(r'^[0-9a-f]{16}$')));
      // Stored and exported as JSON as is.
      expect(jsonDecode(jsonEncode(got)), got);
    });

    test('a camera photo: no device, no signal; the rest still kept', () {
      final got = captureAnalysis(CaptureMeta(exif: exif, createDate: created));
      expect(got.containsKey('device'), isFalse);
      expect(got.containsKey('signal'), isFalse);
      expect(got['has_gps'], isTrue);
      expect(got['gps_fix_delta_s'], -40);
    });

    test('no EXIF: has_gps false and nothing more', () {
      expect(captureAnalysis(const CaptureMeta()), {'has_gps': false});
      expect(
        captureAnalysis(
          const CaptureMeta(
            device: CaptureDevice.metaGlasses,
            strength: CaptureStrength.strong,
            signal: CaptureSignal.album,
          ),
        ),
        {'device': 'meta_glasses', 'signal': 'album', 'has_gps': false},
      );
    });

    test('the fix difference compares UTC instants, in any local zone', () {
      // A creation instant handed back as LOCAL time is the same instant.
      final local = DateTime.fromMillisecondsSinceEpoch(
        created.millisecondsSinceEpoch,
      );
      final got = captureAnalysis(CaptureMeta(exif: exif, createDate: local));
      expect(got['gps_fix_delta_s'], -40);
    });

    test('a shared file (no creation date) compares with the EXIF shutter '
        'instant when its zone is known, else keeps no difference', () {
      // 12:29:58 at −05:00 = 17:29:58Z; the fix is 17:29:20Z.
      expect(captureAnalysis(CaptureMeta(exif: exif))['gps_fix_delta_s'], -38);
      final noZone = ExifCapture(
        dateTimeOriginal: DateTime(2026, 10, 8, 12, 29, 58),
        gpsPresent: true,
        gpsFixUtc: DateTime.utc(2026, 10, 8, 17, 29, 20),
      );
      expect(
        captureAnalysis(
          CaptureMeta(exif: noZone),
        ).containsKey('gps_fix_delta_s'),
        isFalse,
      );
    });

    test('a broken GPS clock (over 400 days off) keeps no difference', () {
      final broken = ExifCapture(
        gpsPresent: true,
        gpsFixUtc: DateTime.utc(2019, 1, 1),
      );
      expect(
        captureAnalysis(
          CaptureMeta(exif: broken, createDate: created),
        ).containsKey('gps_fix_delta_s'),
        isFalse,
      );
    });

    test('never a coordinate or a timestamp: only the contract keys, and '
        'no value is a date', () {
      final got = captureAnalysis(
        CaptureMeta(
          device: CaptureDevice.metaGlasses,
          signal: CaptureSignal.exif,
          exif: exif,
          createDate: created,
        ),
      );
      expect(
        got.keys.toSet().difference({
          'device',
          'signal',
          'has_gps',
          'gps_acc_m',
          'gps_fix_delta_s',
          'shutter_key',
        }),
        isEmpty,
      );
      final text = jsonEncode(got);
      expect(text, isNot(contains('2026')));
      expect(text.toLowerCase(), isNot(contains('lat')));
      expect(text.toLowerCase(), isNot(contains('lon')));
    });
  });

  group('shutterKey', () {
    final base = ExifCapture(
      make: 'Meta AI',
      model: 'Ray-Ban Meta Smart Glasses',
      dateTimeOriginal: DateTime(2026, 10, 8, 12, 29, 58),
      subSec: '123',
    );

    test('the preview and the full-size copy of one press share it', () {
      final preview = ExifCapture(
        make: ' meta ai ',
        model: 'RAY-BAN META SMART GLASSES',
        dateTimeOriginal: DateTime(2026, 10, 8, 12, 29, 58),
        subSec: '123',
        pixelW: 1080,
        pixelH: 1440,
      );
      expect(shutterKey(preview), shutterKey(base));
    });

    test('a different second, sub-second, Make or Model changes it', () {
      final key = shutterKey(base);
      for (final other in [
        ExifCapture(
          make: base.make,
          model: base.model,
          dateTimeOriginal: DateTime(2026, 10, 8, 12, 29, 59),
          subSec: '123',
        ),
        ExifCapture(
          make: base.make,
          model: base.model,
          dateTimeOriginal: base.dateTimeOriginal,
          subSec: '124',
        ),
        ExifCapture(
          make: 'Apple',
          model: base.model,
          dateTimeOriginal: base.dateTimeOriginal,
          subSec: '123',
        ),
        ExifCapture(
          make: base.make,
          model: 'iPhone 18 Pro Max',
          dateTimeOriginal: base.dateTimeOriginal,
          subSec: '123',
        ),
      ]) {
        expect(shutterKey(other), isNot(key));
      }
    });

    test('it is the documented hash: SHA-256 of the joined identity', () {
      // sha256('2026:10:08 12:29:58|123|meta ai|ray-ban meta smart glasses')
      expect(shutterKey(base), hasLength(16));
      expect(
        shutterKey(base),
        // Pinned: G2b matches stored keys against new photos across app
        // versions, so the recipe must never drift.
        '5c6a4ac555be9558',
      );
    });

    test('none without DateTimeOriginal, or with nothing beside it', () {
      expect(shutterKey(null), isNull);
      expect(shutterKey(const ExifCapture(make: 'Apple', subSec: '1')), isNull);
      expect(
        shutterKey(ExifCapture(dateTimeOriginal: DateTime(2026, 10, 8))),
        isNull,
        reason:
            'two photos of one second from a camera that writes '
            'nothing else would look like one',
      );
    });
  });

  group('isMetaGlassesAnalysis', () {
    test('only capture.device == meta_glasses', () {
      expect(
        isMetaGlassesAnalysis({
          'capture': {'device': 'meta_glasses', 'has_gps': false},
        }),
        isTrue,
      );
      for (final hostile in <Map<String, dynamic>>[
        {},
        {'capture': null},
        {'capture': 'meta_glasses'},
        {
          'capture': ['meta_glasses'],
        },
        {
          'capture': {'device': 'Meta_Glasses'},
        },
        {
          'capture': {'device': 1},
        },
        {'device': 'meta_glasses'},
      ]) {
        expect(isMetaGlassesAnalysis(hostile), isFalse, reason: '$hostile');
      }
    });
  });

  group('whitelists never forward capture', () {
    final analysis = <String, dynamic>{
      'is_food': true,
      'meal_description': 'Burrito bowl',
      'total_calories': 720,
      'capture': {
        'device': 'meta_glasses',
        'signal': 'filename',
        'has_gps': true,
        'gps_acc_m': 12,
        'gps_fix_delta_s': -40,
        'shutter_key': '0123456789abcdef',
      },
      'food_items': [
        {
          'name': 'Burrito bowl',
          'estimated_calories': 720,
          'capture': {'device': 'meta_glasses'},
        },
      ],
    };

    void expectClean(String text) {
      for (final leak in [
        'capture',
        'meta_glasses',
        'shutter_key',
        '0123456789abcdef',
        'gps',
      ]) {
        expect(text, isNot(contains(leak)), reason: leak);
      }
    }

    test('recentMealCompact (the automatic leftover check payload)', () {
      final compact = recentMealCompact(time: '12:30 PM', analysis: analysis);
      expectClean(jsonEncode(compact));
      expectClean(formatRecentMealsBlock([compact]));
    });

    test('compactOriginalAnalysis (the manual leftover payload)', () {
      expectClean(compactOriginalAnalysis(analysis));
    });

    test('buildMealsList (the chat prompt)', () {
      expectClean(
        buildMealsList([
          Meal(
            id: 1,
            date: '2026-10-08',
            time: '12:30 PM',
            timestamp: '2026-10-08T12:31:00',
            source: MealSource.appWatch,
            analysis: analysis,
          ),
        ]),
      );
    });
  });
}
