/// Photo pipeline glue (spec §2.3/§3.5/§6): reservation policies, status
/// transitions, food_items sanitization, and per-photo error containment.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/analyzer/gemini_analyzer.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/services/photo/deferred_assets.dart'
    show holdGlassesPreview;
import 'package:calorie_tracker/services/photo/food_prefilter.dart';
import 'package:calorie_tracker/services/photo/glasses.dart' show shutterKey;
import 'package:calorie_tracker/services/photo/glasses_check.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';

import 'fakes.dart';

class _MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// A REAL analyzer whose normalizer can read nothing — what the iOS
/// background engine answered for every HEIC once dart:ui was ruled out —
/// and whose HTTP client fails the test if a request is ever made.
Future<AnalyzerService> _analyzerThatCannotDecode() async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(),
      keyStore: _MemoryKeyStore());
  await settings.setGeminiApiKey('test-key');
  return GeminiAnalyzer(settings,
      client: MockClient((_) async {
        fail('nothing decodable, so nothing may be sent');
      }),
      sleep: (_) async {},
      normalizer: (_) async => null);
}

IntakePhoto _photo({bool deliberate = false}) => IntakePhoto(
    Uint8List.fromList([1, 2, 3]), 'asset1', 'IMG_20260716_193042.jpg',
    deliberate: deliberate);

String get _hash =>
    md5.convert(Uint8List.fromList([1, 2, 3])).toString().toLowerCase();

Map<String, dynamic> _foodAnalysis() => {
      'is_food': true,
      'meal_description': 'Ramen',
      'total_calories': 600,
      'food_items': [
        {'name': 'Ramen', 'estimated_calories': 600},
        'junk-entry',
        42,
      ],
    };

void main() {
  test('enqueue() serializes with the bound-stream FIFO — never concurrent',
      () async {
    final dao = FakeDao();
    var active = 0, maxActive = 0;
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true}, isFood: true, wall: Duration.zero)
      ..onAnalyze = () async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 8));
        active--;
      };
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final stream = StreamController<IntakePhoto>();
    pipeline.bindStream(stream.stream);

    IntakePhoto photo(int n, String id) => IntakePhoto(
        Uint8List.fromList([n]), id, 'IMG_$n.jpg', deliberate: true);

    // Interleave stream photos (the watcher path) with direct enqueues
    // (the coverage screen's Log all): the whole point of enqueue over
    // process is that these NEVER overlap an analyzer call.
    stream.add(photo(1, 's1'));
    stream.add(photo(2, 's2'));
    final e1 = pipeline.enqueue(photo(3, 'e1'));
    stream.add(photo(4, 's3'));
    final e2 = pipeline.enqueue(photo(5, 'e2'));
    await Future.wait([e1, e2]);
    await stream.close();
    // Polled, not a fixed 60 ms: each photo hashes on a compute() isolate,
    // and a loaded machine overran the fixed wait (flaky, 2026-10-12).
    await _until(() => dao.meals.length == 5);

    expect(maxActive, 1,
        reason: 'a second concurrent analyzer call is the free-tier RPM '
            '429 self-inflict the FIFO exists to prevent');
    expect(dao.meals, hasLength(5));
  });

  // Design R6b: the restaurant assist starts a lookup only while the
  // pipeline is idle.
  test('isIdle: false while a photo is queued, in flight or a reservation '
      'is held; true once the queue drains', () async {
    final dao = FakeDao();
    final gate = Completer<void>();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true}, isFood: true, wall: Duration.zero)
      ..onAnalyze = () => gate.future;
    final pipeline = PhotoPipeline(
        dao: dao, analyzer: analyzer, hasher: (b) async => 'h${b.first}');
    expect(pipeline.isIdle, isTrue);

    IntakePhoto photo(int n) =>
        IntakePhoto(Uint8List.fromList([n]), 'a$n', 'IMG_$n.jpg',
            deliberate: true);
    final first = pipeline.enqueue(photo(1));
    final second = pipeline.enqueue(photo(2));
    expect(pipeline.isIdle, isFalse, reason: 'queued');
    await _until(() => dao.ledger['h1'] == IngestionStatus.processing);
    expect(pipeline.isIdle, isFalse, reason: 'reserved, analyzing');
    gate.complete();
    await first;
    expect(pipeline.isIdle, isFalse, reason: 'the second is still queued');
    await second;
    expect(pipeline.isIdle, isTrue);
    expect(dao.meals, hasLength(2));

    // A direct process() call (no tail) counts too.
    final hold = Completer<void>();
    analyzer.onAnalyze = () => hold.future;
    final direct = pipeline.process(photo(3));
    expect(pipeline.isIdle, isFalse);
    hold.complete();
    await direct;
    expect(pipeline.isIdle, isTrue);
  });

  test('a saved photo meal gets a stored thumbnail (spec §9)', () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true, 'total_calories': 100},
          isFood: true,
          wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    // Real 1x1 JPEG so the thumbnailer can decode it.
    final jpeg = base64Decode(
        '/9j/4AAQSkZJRgABAQEAAAAAAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLD'
        'BkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2w'
        'BDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjI'
        'yMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAA'
        'AQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAA'
        'AF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGR'
        'olJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXq'
        'DhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT'
        '1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAA'
        'AAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBh'
        'JBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg'
        '5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOU'
        'lZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5'
        'ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==');
    final outcome = await pipeline.process(
        IntakePhoto(jpeg, 'a1', 'IMG_1.jpg', deliberate: true));
    expect(outcome.kind, PhotoOutcomeKind.saved);
    final mealId = dao.meals.single.id;
    expect(dao.thumbs[mealId], isNotNull,
        reason: 'the pipeline persists a thumbnail at save time');
    expect(dao.thumbs[mealId]!.length, lessThan(jpeg.length + 4096),
        reason: 'thumb stays small');
  });

  test('a throwing thumb save never un-saves the meal', () async {
    final dao = _ThumbThrowingDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true},
          isFood: true,
          wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final outcome = await pipeline.process(IntakePhoto(
        Uint8List.fromList([1, 2, 3]), 'a1', 'x.jpg',
        deliberate: true));
    expect(outcome.kind, PhotoOutcomeKind.saved);
    expect(dao.meals, hasLength(1));
  });


  test('food photo → reserved, saved meal, ledger saved, sanitized items',
      () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final notes = <PhotoOutcome>[];
    final pipeline =
        PhotoPipeline(dao: dao, analyzer: analyzer, notify: notes.add);

    final out = await pipeline.process(_photo());

    expect(out.kind, PhotoOutcomeKind.saved);
    expect(dao.meals, hasLength(1));
    expect(dao.meals.single.imageHash, _hash); // md5 of ORIGINAL bytes §6.2
    expect(dao.meals.single.source, 'app_watch');
    // Hostile entries dropped before persisting (spec §3.5).
    expect(dao.meals.single.analysis['food_items'], [
      {'name': 'Ramen', 'estimated_calories': 600}
    ]);
    expect(dao.ledger[_hash], IngestionStatus.saved);
    expect(notes, hasLength(1)); // notification-style snackbar on save
    // The snackbar gets the OUTCOME (worded in the app language by
    // di.dart), the very one process() returns.
    expect(notes.single, same(out));
  });

  // Design G2a: how the photo was taken — the intake's reading of its own
  // bytes — lands in analysis.capture before the save; never a coordinate,
  // never the model's word for it.
  group('analysis.capture', () {
    final glasses = CaptureMeta(
        device: CaptureDevice.metaGlasses,
        strength: CaptureStrength.strong,
        signal: CaptureSignal.filename,
        exif: ExifCapture(
            make: 'Meta AI',
            model: 'Ray-Ban Meta Smart Glasses',
            dateTimeOriginal: DateTime(2026, 10, 8, 12, 29, 58),
            subSec: '123',
            gpsPresent: true,
            gpsAccuracyM: 11.6,
            gpsFixUtc: DateTime.utc(2026, 10, 8, 17, 29, 20)),
        createDate: DateTime.utc(2026, 10, 8, 17, 30));

    Future<Map<String, dynamic>> savedAnalysis(CaptureMeta? capture,
        {Map<String, dynamic>? reply, bool deliberate = false}) async {
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: reply ?? _foodAnalysis(),
            isFood: true,
            wall: Duration.zero);
      final out = await PhotoPipeline(dao: dao, analyzer: analyzer).process(
          IntakePhoto(Uint8List.fromList([1, 2, 3]), 'asset1',
              'photo-1_singular_display_fullPicture.HEIC',
              deliberate: deliberate, capture: capture));
      expect(out.kind, PhotoOutcomeKind.saved, reason: out.message);
      expect(out.analysis, same(dao.meals.single.analysis));
      return dao.meals.single.analysis;
    }

    test('a glasses photo: the device, its signal and the GPS facts', () async {
      final a = await savedAnalysis(glasses);
      expect(a['capture'], {
        'device': 'meta_glasses',
        'signal': 'filename',
        'has_gps': true,
        'gps_acc_m': 12,
        'gps_fix_delta_s': -40,
        'shutter_key': shutterKey(glasses.exif),
      });
      expect(a['meal_description'], 'Ramen', reason: 'the meal is unchanged');
    });

    test('a camera photo: no device — only what it really is', () async {
      final a = await savedAnalysis(CaptureMeta(
          exif: const ExifCapture(make: 'Apple', gpsPresent: false),
          createDate: DateTime.utc(2026, 10, 8)));
      expect(a['capture'], {'has_gps': false});
    });

    test('a deliberate add keeps it too (the badge on a picked photo)',
        () async {
      final a = await savedAnalysis(glasses, deliberate: true);
      expect((a['capture'] as Map)['device'], 'meta_glasses');
    });

    test("a model reply's own 'capture' is never stored", () async {
      final forged = {
        ..._foodAnalysis(),
        'capture': {
          'device': 'meta_glasses',
          'lat': 43.07,
          'lon': -89.4,
          'shutter_key': 'ffffffffffffffff'
        },
      };
      final none = await savedAnalysis(null, reply: forged);
      expect(none.containsKey('capture'), isFalse,
          reason: 'no reading by the intake, nothing stored');
      final camera = await savedAnalysis(const CaptureMeta(), reply: forged);
      expect(camera['capture'], {'has_gps': false},
          reason: "the intake's reading replaces the model's");
    });

    // Design R6a: only a verified restaurant lookup writes an assist block
    // or a published flag — a reply carrying them claims nothing.
    test("a model reply's own assist block and published flags are never "
        'stored', () async {
      final forged = {
        ..._foodAnalysis(),
        'assist': {
          'v': 2,
          'status': 'applied',
          'chain_key': 'chipotle',
          'brand_name': 'Chipotle',
        },
        'food_items': [
          {'name': 'Ramen', 'estimated_calories': 650, 'published': true},
        ],
      };
      final a = await savedAnalysis(null, reply: forged);
      expect(a.containsKey('assist'), isFalse);
      expect((a['food_items'] as List).single, {
        'name': 'Ramen',
        'estimated_calories': 650,
      });
    });
  });

  // Design G2b: what the automatic intake does with a Meta glasses photo
  // before any model sees it — a second file of a shutter press already
  // logged is skipped, a preview copy waits once for its full-size one, and
  // a creation date that is only the import time gives way to the shutter.
  group('glasses guards (G2b)', () {
    final taken = DateTime(2026, 10, 8, 12, 29, 58);
    ExifCapture shot({int? w, int? h}) => ExifCapture(
        make: 'Meta AI',
        model: 'Ray-Ban Meta Smart Glasses',
        dateTimeOriginal: taken,
        subSec: '123',
        pixelW: w,
        pixelH: h);
    CaptureMeta capture(
            {int? w,
            int? h,
            CaptureDevice device = CaptureDevice.metaGlasses}) =>
        CaptureMeta(
            device: device,
            strength: device == CaptureDevice.metaGlasses
                ? CaptureStrength.strong
                : CaptureStrength.none,
            signal: device == CaptureDevice.metaGlasses
                ? CaptureSignal.filename
                : null,
            exif: shot(w: w, h: h),
            createDate: DateTime(2026, 10, 8, 12, 30));
    final key = shutterKey(shot())!;
    IntakePhoto photo(List<int> bytes, String id,
            {bool deliberate = false, CaptureMeta? meta, DateTime? at}) =>
        IntakePhoto(Uint8List.fromList(bytes), id,
            'photo-${id}_singular_display_fullPicture.HEIC',
            capturedAt: at ?? DateTime(2026, 10, 8, 12, 30),
            deliberate: deliberate,
            capture: meta ?? capture(w: 3024, h: 4032));
    String hashOf(List<int> bytes) =>
        md5.convert(Uint8List.fromList(bytes)).toString().toLowerCase();

    late FakeDao dao;
    late FakeAnalyzer analyzer;
    late int analyses;
    late int hashes;
    PhotoPipeline pipeline({Future<bool> Function(String id)? hold}) =>
        PhotoPipeline(
            dao: dao,
            analyzer: analyzer,
            previewHold: hold,
            hasher: (bytes) async {
              hashes++;
              return md5.convert(bytes).toString();
            });

    setUp(() {
      dao = FakeDao();
      analyses = 0;
      hashes = 0;
      analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _foodAnalysis(), isFood: true, wall: Duration.zero)
        ..onAnalyze = () async => analyses++;
    });

    /// A meal of this shutter press, dated [date].
    void seedShot(String date) => dao.seed(Meal(
        id: 0,
        date: date,
        time: '12:30 PM',
        timestamp: '${date}T12:30:00.000',
        source: MealSource.appWatch,
        imageHash: 'f' * 32,
        fileId: 'full',
        analysis: {
          'is_food': true,
          'total_calories': 500,
          'capture': {'device': 'meta_glasses', 'shutter_key': key},
        }));

    group('the same shutter press twice', () {
      test('automatic: the second file is skipped without the model; '
          'deliberate: both are kept', () async {
        final p = pipeline();
        final first = await p.process(photo([1, 2, 3], 'full'));
        expect(first.kind, PhotoOutcomeKind.saved);
        expect((dao.meals.single.analysis['capture'] as Map)['shutter_key'],
            key);
        final second = await p.process(photo([4, 5, 6], 'preview'));
        expect(second.kind, PhotoOutcomeKind.skipped);
        expect(second.reason, duplicateCaptureReason);
        expect(second.retryable, isFalse, reason: 'a verdict: settled');
        expect(dao.ledger[hashOf([4, 5, 6])], IngestionStatus.skipped,
            reason: 'tombstoned, so no later scan offers it again');
        expect(dao.meals, hasLength(1));
        expect(analyses, 1, reason: 'the model saw the first file only');
        expect(dao.shutterKeyCalls.last, (key, '2026-10-06', '2026-10-10'));

        // The user picks it on purpose: theirs to log (and it reclaims
        // the skipped row).
        final picked =
            await p.process(photo([4, 5, 6], 'preview', deliberate: true));
        expect(picked.kind, PhotoOutcomeKind.saved);
        expect(dao.meals, hasLength(2));
      });

      test('a photo offered again after its own meal is still "already '
          'logged", never re-tombstoned', () async {
        final p = pipeline();
        await p.process(photo([1, 2, 3], 'full'));
        final again = await p.process(photo([1, 2, 3], 'full'));
        expect(again.kind, PhotoOutcomeKind.alreadyTracked);
        expect(dao.ledger[hashOf([1, 2, 3])], IngestionStatus.saved);
      });

      for (final (date, skipped) in [
        ('2026-10-06', true),
        ('2026-10-05', false),
        ('2026-10-10', true),
        ('2026-10-11', false),
      ]) {
        test('a meal of that press dated $date → '
            '${skipped ? 'skipped' : 'logged'} (±2 days)', () async {
          seedShot(date);
          final out = await pipeline().process(photo([4, 5, 6], 'preview'));
          expect(out.kind,
              skipped ? PhotoOutcomeKind.skipped : PhotoOutcomeKind.saved);
          expect(dao.meals, hasLength(skipped ? 1 : 2));
        });
      }

      test('camera photos are never looked up: two files of one press are '
          'two meals, as before', () async {
        seedShot('2026-10-08');
        final out = await pipeline().process(photo([4, 5, 6], 'camera',
            meta: capture(w: 3024, h: 4032, device: CaptureDevice.unknown)));
        expect(out.kind, PhotoOutcomeKind.saved);
        expect(dao.shutterKeyCalls, isEmpty);
      });

      test('a store that cannot answer lets the photo through', () async {
        seedShot('2026-10-08');
        dao.shutterKeyError = StateError('database is locked');
        final out = await pipeline().process(photo([4, 5, 6], 'preview'));
        expect(out.kind, PhotoOutcomeKind.saved);
      });
    });

    group('a preview copy (< 2 MP)', () {
      late DateTime t;
      late Future<bool> Function(String id) hold;
      setUp(() {
        SharedPreferences.setMockInitialValues({});
        t = DateTime.utc(2026, 10, 8, 18);
        hold = (id) => holdGlassesPreview(id, clock: () => t);
      });

      test('1.9 MP: held once for 10 minutes, untouched; then processed',
          () async {
        final p = pipeline(hold: hold);
        final preview = photo([4, 5, 6], 'preview',
            meta: capture(w: 1600, h: 1187)); // 1,899,200 px
        final first = await p.process(preview);
        expect(first.kind, PhotoOutcomeKind.failed);
        expect(first.retryable, isTrue,
            reason: 'released: a later scan offers it again');
        expect(first.reason, glassesPreviewReason);
        expect(first.errorKind, isNot(AnalysisErrorKind.badPhoto),
            reason: 'never counted as a photo the run cannot decode');
        expect(hashes, 0, reason: 'not even hashed');
        expect(dao.ledger, isEmpty);
        t = t.add(const Duration(minutes: 9, seconds: 59));
        expect((await p.process(preview)).reason, glassesPreviewReason);
        t = t.add(const Duration(seconds: 1));
        final later = await p.process(preview);
        expect(later.kind, PhotoOutcomeKind.saved);
        expect(analyses, 1);
      });

      test('its full-size copy already logged: skipped at once, not held',
          () async {
        final p = pipeline(hold: (id) async => fail('never asked'));
        await p.process(photo([1, 2, 3], 'full'));
        final out = await p.process(
            photo([4, 5, 6], 'preview', meta: capture(w: 1600, h: 1187)));
        expect(out.reason, duplicateCaptureReason);
      });

      test('12 MP, a camera photo, a deliberate add and an unknown size are '
          'never held', () async {
        var asked = 0;
        Future<bool> counting(String id) async {
          asked++;
          return true;
        }

        for (final (i, candidate) in [
          photo([1], 'full', meta: capture(w: 4032, h: 3024)),
          photo([2], 'camera',
              meta: capture(w: 1600, h: 1187, device: CaptureDevice.unknown)),
          photo([3], 'picked',
              deliberate: true, meta: capture(w: 1600, h: 1187)),
          photo([4], 'unknown', meta: capture()),
        ].indexed) {
          // Each on its own log: they are one shutter press.
          dao = FakeDao();
          final out = await pipeline(hold: counting).process(candidate);
          expect(out.kind, PhotoOutcomeKind.saved, reason: '#$i');
        }
        expect(asked, 0);
      });

      test('a hold that throws lets the photo through', () async {
        final out = await pipeline(hold: (id) async => throw StateError('x'))
            .process(
                photo([4, 5, 6], 'preview', meta: capture(w: 1600, h: 1187)));
        expect(out.kind, PhotoOutcomeKind.saved);
      });
    });

    group('dating (the import-time guard)', () {
      // Relative to today: the guard validates the shutter against now.
      final day = DateTime.now().subtract(const Duration(days: 1));
      final imported = DateTime(day.year, day.month, day.day, 22, 0);
      final lunch = DateTime(day.year, day.month, day.day, 12, 37);
      String isoDay(DateTime d) => '${d.year}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      CaptureMeta lateCopy(
              {CaptureDevice device = CaptureDevice.metaGlasses,
              DateTime? added}) =>
          CaptureMeta(
              device: device,
              strength: CaptureStrength.strong,
              signal: CaptureSignal.filename,
              exif: ExifCapture(
                  make: 'Meta AI',
                  model: 'Ray-Ban Meta Smart Glasses',
                  dateTimeOriginal: lunch,
                  subSec: '5'),
              // Stamped with the import time, as the guard fears.
              createDate: imported,
              addedDate: added);

      Future<Meal> saved(CaptureMeta meta) async {
        final out = await pipeline()
            .process(photo([7, 8, 9], 'late', meta: meta, at: imported));
        expect(out.kind, PhotoOutcomeKind.saved, reason: out.message);
        return dao.meals.single;
      }

      test('a glasses photo created when it was imported is dated by its '
          'shutter', () async {
        final meal = await saved(
            lateCopy(added: imported.add(const Duration(seconds: 20))));
        expect(meal.date, isoDay(lunch));
        expect(meal.time, '12:37 PM');
      });

      test('without the evidence, or for a camera photo, nothing changes',
          () async {
        final meal = await saved(lateCopy());
        expect(meal.time, '10:00 PM');
        dao = FakeDao();
        final camera = await saved(lateCopy(
            device: CaptureDevice.unknown,
            added: imported.add(const Duration(seconds: 20))));
        expect(camera.time, '10:00 PM');
      });
    });
  });

  // Design G3: the include switch, the on-device food check and the
  // per-scan allowance — automatic Meta glasses photos only.
  group('glasses intake controls (G3)', () {
    final glasses = CaptureMeta(
        device: CaptureDevice.metaGlasses,
        strength: CaptureStrength.strong,
        signal: CaptureSignal.filename,
        exif: ExifCapture(
            make: 'Meta AI',
            model: 'Ray-Ban Meta Smart Glasses',
            gpsPresent: true,
            pixelW: 3024,
            pixelH: 4032),
        createDate: DateTime(2026, 10, 8, 12, 30),
        addedDate: DateTime(2026, 10, 8, 13, 2));
    const camera = CaptureMeta(
        exif: ExifCapture(make: 'Apple', pixelW: 4032, pixelH: 3024));
    IntakePhoto photo(List<int> bytes, String id,
            {bool deliberate = false,
            CaptureMeta? meta,
            GlassesQuota? quota}) =>
        IntakePhoto(Uint8List.fromList(bytes), id,
            'photo-${id}_singular_display_fullPicture.HEIC',
            capturedAt: DateTime(2026, 10, 8, 12, 30),
            deliberate: deliberate,
            capture: meta ?? glasses,
            glassesQuota: quota);
    String hashOf(List<int> bytes) =>
        md5.convert(Uint8List.fromList(bytes)).toString().toLowerCase();

    late FakeDao dao;
    late FakeAnalyzer analyzer;
    late int analyses;
    late int hashes;
    late List<Uint8List> checked;
    late List<GlassesCheckEntry> recorded;
    late bool include;
    late FoodCheck Function(Uint8List bytes) answer;

    PhotoPipeline pipeline(
            {bool withCheck = true,
            Future<FoodCheck> Function(Uint8List bytes)? check}) =>
        PhotoPipeline(
            dao: dao,
            analyzer: analyzer,
            includeGlasses: () => include,
            foodCheck: withCheck
                ? (check ??
                    (bytes) async {
                      checked.add(bytes);
                      return answer(bytes);
                    })
                : null,
            glassesCheckLog: (e) async => recorded.add(e),
            clock: () => DateTime(2026, 10, 8, 13, 5),
            hasher: (bytes) async {
              hashes++;
              return md5.convert(bytes).toString();
            });

    FoodCheck ok(double score) => FoodCheck(FoodCheckStatus.ok,
        score: score, top: [FoodClass('food', score)]);

    setUp(() {
      dao = FakeDao();
      analyses = 0;
      hashes = 0;
      checked = [];
      recorded = [];
      include = true;
      answer = (_) => ok(0.63);
      analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _foodAnalysis(), isFood: true, wall: Duration.zero)
        ..onAnalyze = () async => analyses++;
    });

    group('the on-device food check', () {
      test('below the threshold: skipped and tombstoned without the model',
          () async {
        answer = (_) => ok(kFoodThreshold - 0.01);
        final out = await pipeline().process(photo([1, 2, 3], 'g1'));
        expect(out.kind, PhotoOutcomeKind.skipped);
        expect(out.reason, notFoodLocalReason);
        expect(out.retryable, isFalse);
        expect(dao.ledger[hashOf([1, 2, 3])], IngestionStatus.skipped,
            reason: 'a verdict: no scan offers it again');
        expect(analyses, 0, reason: 'never uploaded');
        expect(dao.meals, isEmpty);
        expect(checked.single, [1, 2, 3], reason: 'the original bytes');
      });

      test('at the threshold and above: on to the model, as before',
          () async {
        answer = (_) => ok(kFoodThreshold);
        final out = await pipeline().process(photo([1, 2, 3], 'g1'));
        expect(out.kind, PhotoOutcomeKind.saved);
        expect(analyses, 1);
      });

      for (final (name, check) in <(String, Future<FoodCheck> Function(Uint8List))>[
        ('error', (_) async => FoodCheck.error),
        ('unsupported', (_) async => FoodCheck.unsupported),
        ('a throw', (_) async => throw StateError('channel gone')),
        ('an ok without a score',
            (_) async => const FoodCheck(FoodCheckStatus.ok)),
      ]) {
        test('$name fails open: the photo goes on to the model', () async {
          final out =
              await pipeline(check: check).process(photo([1, 2, 3], 'g1'));
          expect(out.kind, PhotoOutcomeKind.saved);
          expect(analyses, 1);
        });
      }

      test('deferred_gpu: released for the foreground, counted with the '
          'decodes the background run cannot do', () async {
        answer = (_) => const FoodCheck(FoodCheckStatus.deferredGpu);
        final out = await pipeline().process(photo([1, 2, 3], 'g1'));
        expect(out.kind, PhotoOutcomeKind.failed);
        expect(out.retryable, isTrue);
        expect(out.errorKind, AnalysisErrorKind.badPhoto,
            reason: 'deferred_assets counts it, and passes it over later');
        expect(out.reason, foodCheckDeferredReason);
        expect(dao.ledger.containsKey(hashOf([1, 2, 3])), isFalse,
            reason: 'released, so the next run offers it again');
        expect(analyses, 0);
      });

      test('camera photos are never classified', () async {
        final out =
            await pipeline().process(photo([1, 2, 3], 'c1', meta: camera));
        expect(out.kind, PhotoOutcomeKind.saved);
        expect(checked, isEmpty);
        final none = await pipeline()
            .process(IntakePhoto(Uint8List.fromList([4, 5, 6]), 'c2', 'x.jpg'));
        expect(none.kind, PhotoOutcomeKind.saved);
        expect(checked, isEmpty, reason: 'no capture read: not glasses');
      });

      test('deliberate adds are never filtered', () async {
        answer = (_) => ok(0.0);
        final out = await pipeline()
            .process(photo([1, 2, 3], 'g1', deliberate: true));
        expect(out.kind, PhotoOutcomeKind.saved);
        expect(checked, isEmpty);
      });

      test('an already logged photo pays for no check', () async {
        final p = pipeline();
        await p.process(photo([1, 2, 3], 'g1'));
        expect(checked, hasLength(1));
        final again = await p.process(photo([1, 2, 3], 'g1'));
        expect(again.kind, PhotoOutcomeKind.alreadyTracked);
        expect(checked, hasLength(1),
            reason: 'the check runs only once the reservation is ours');
      });

      test('no foodCheck (Android, the add flow): nothing is classified',
          () async {
        answer = (_) => ok(0.0);
        final out = await pipeline(withCheck: false)
            .process(photo([1, 2, 3], 'g1'));
        expect(out.kind, PhotoOutcomeKind.saved);
      });
    });

    group('the Meta glasses photos switch', () {
      test('off: an automatic glasses photo is not offered — no hash, no '
          'ledger row, no check, no model — with a terminal verdict',
          () async {
        include = false;
        final out = await pipeline().process(photo([1, 2, 3], 'g1'));
        expect(out.kind, PhotoOutcomeKind.skipped);
        expect(out.reason, glassesExcludedReason);
        expect(out.retryable, isFalse,
            reason: 'the carry drops it and the frontier passes it');
        expect(hashes, 0);
        expect(dao.ledger, isEmpty, reason: 'no reservation');
        expect(checked, isEmpty);
        expect(analyses, 0);
      });

      test('off: camera photos and deliberate glasses adds go on as before',
          () async {
        include = false;
        final p = pipeline();
        expect((await p.process(photo([1, 2, 3], 'c1', meta: camera))).kind,
            PhotoOutcomeKind.saved);
        expect(
            (await p.process(photo([4, 5, 6], 'g1', deliberate: true))).kind,
            PhotoOutcomeKind.saved);
        expect(analyses, 2);
      });

      test('a throwing switch includes the photo', () async {
        final p = PhotoPipeline(
            dao: dao,
            analyzer: analyzer,
            includeGlasses: () => throw StateError('prefs gone'));
        expect((await p.process(photo([1, 2, 3], 'g1'))).kind,
            PhotoOutcomeKind.saved);
      });

      test('on again: the next scan offers the photo, which was never '
          'recorded in the ledger', () async {
        include = false;
        final p = pipeline();
        await p.process(photo([1, 2, 3], 'g1'));
        include = true;
        expect((await p.process(photo([1, 2, 3], 'g1'))).kind,
            PhotoOutcomeKind.saved);
      });
    });

    group('the per-scan allowance (GlassesQuota)', () {
      test('past the limit a glasses photo is released untouched and the '
          'scan remembers it; camera photos never count', () async {
        final quota = GlassesQuota(limit: 2);
        final p = pipeline();
        final outs = [
          for (final (bytes, id) in [
            ([1], 'g1'),
            ([2], 'g2'),
            ([3], 'c1'),
            ([4], 'g3'),
          ])
            await p.process(photo(bytes, id,
                quota: quota, meta: id.startsWith('c') ? camera : null)),
        ];
        expect([for (final o in outs) o.kind], [
          PhotoOutcomeKind.saved,
          PhotoOutcomeKind.saved,
          PhotoOutcomeKind.saved,
          PhotoOutcomeKind.failed,
        ]);
        final capped = outs.last;
        expect(capped.retryable, isTrue);
        expect(capped.reason, glassesCappedReason);
        expect(capped.errorKind, isNot(AnalysisErrorKind.badPhoto),
            reason: 'not a deferral the background run would count');
        expect(dao.ledger.containsKey(hashOf([4])), isFalse,
            reason: 'released');
        expect(quota.turnedAway('g3'), isTrue);
        expect(quota.turnedAway('g1'), isFalse);
        expect(analyses, 3);
      });

      test('only photos headed for the model take a slot: not food, '
          'switched off and deliberate adds are free', () async {
        final quota = GlassesQuota(limit: 1);
        answer = (bytes) => ok(bytes.first == 9 ? 0.01 : 0.7);
        final p = pipeline();
        expect((await p.process(photo([9], 'nf', quota: quota))).reason,
            notFoodLocalReason);
        expect(
            (await p.process(photo([8], 'd1', quota: quota, deliberate: true)))
                .kind,
            PhotoOutcomeKind.saved);
        include = false;
        expect((await p.process(photo([5], 'x1', quota: quota))).reason,
            glassesExcludedReason);
        include = true;
        expect(quota.taken, 0);
        expect((await p.process(photo([7], 'g1', quota: quota))).kind,
            PhotoOutcomeKind.saved);
        expect(quota.taken, 1);
        expect((await p.process(photo([6], 'g2', quota: quota))).reason,
            glassesCappedReason);
      });

      test('a photo already logged takes no slot', () async {
        final quota = GlassesQuota(limit: 1);
        final p = pipeline();
        await p.process(photo([1], 'g1'));
        expect((await p.process(photo([1], 'g1', quota: quota))).kind,
            PhotoOutcomeKind.alreadyTracked);
        expect(quota.taken, 0);
      });
    });

    group('the Glasses check record', () {
      test('each glasses verdict is recorded with its food score; camera '
          'photos and "already logged" never are', () async {
        final p = pipeline();
        await p.process(photo([1, 2, 3], 'g1'));
        await p.process(photo([4, 5, 6], 'c1', meta: camera));
        await p.process(photo([1, 2, 3], 'g1')); // already logged
        answer = (_) => ok(0.02);
        await p.process(photo([7, 8, 9], 'g2'));
        expect([for (final e in recorded) (e.assetId, e.outcome)], [
          ('g1', GlassesCheckOutcome.logged),
          ('g2', GlassesCheckOutcome.notFood),
        ]);
        final first = recorded.first;
        expect(first.foodScore, 0.63);
        expect(first.signal, 'filename');
        expect(first.make, 'Meta AI');
        expect(first.model, 'Ray-Ban Meta Smart Glasses');
        expect(first.lagSeconds, 32 * 60);
        expect(first.hasGps, isTrue);
        expect(first.at, DateTime(2026, 10, 8, 13, 5));
        expect(recorded.last.foodScore, 0.02);
      });

      test('a deliberate glasses add is recorded without a score; an '
          'excluded one says so', () async {
        final p = pipeline();
        await p.process(photo([1], 'd1', deliberate: true));
        include = false;
        await p.process(photo([2], 'g1'));
        expect([for (final e in recorded) (e.outcome, e.foodScore)], [
          (GlassesCheckOutcome.logged, null),
          (GlassesCheckOutcome.excluded, null),
        ]);
      });

      test('an abandoned run records nothing', () async {
        final p = pipeline();
        await p.abandon();
        final out = await p.process(photo([1, 2, 3], 'g1'));
        expect(out.retryable, isTrue);
        expect(recorded, isEmpty);
      });

      test('a throwing or stuck record never holds the verdict', () async {
        for (final log in <Future<void> Function(GlassesCheckEntry)>[
          (_) async => throw StateError('disk full'),
          (_) => Completer<void>().future,
        ]) {
          final p = PhotoPipeline(
              dao: FakeDao(), analyzer: analyzer, glassesCheckLog: log);
          final out = await p
              .process(photo([1, 2, 3], 'g1'))
              .timeout(PhotoPipeline.glassesCheckLimit +
                  const Duration(seconds: 2));
          expect(out.kind, PhotoOutcomeKind.saved);
        }
      });
    });

    test('glassesCheckOutcome names every verdict the card can show', () {
      PhotoOutcome o(PhotoOutcomeKind k, {String? reason, bool r = false}) =>
          PhotoOutcome(k, '', reason: reason, retryable: r);
      expect(glassesCheckOutcome(o(PhotoOutcomeKind.saved)), 'logged');
      expect(
          glassesCheckOutcome(o(PhotoOutcomeKind.leftoverApplied)), 'logged');
      expect(glassesCheckOutcome(o(PhotoOutcomeKind.skipped)), 'not_food_ai');
      expect(
          glassesCheckOutcome(
              o(PhotoOutcomeKind.skipped, reason: notFoodLocalReason)),
          'not_food');
      expect(
          glassesCheckOutcome(
              o(PhotoOutcomeKind.skipped, reason: duplicateCaptureReason)),
          'duplicate');
      expect(
          glassesCheckOutcome(
              o(PhotoOutcomeKind.skipped, reason: glassesExcludedReason)),
          'excluded');
      expect(
          glassesCheckOutcome(o(PhotoOutcomeKind.failed,
              reason: glassesPreviewReason, r: true)),
          'preview_wait');
      expect(
          glassesCheckOutcome(o(PhotoOutcomeKind.failed,
              reason: foodCheckDeferredReason, r: true)),
          'app_wait');
      expect(
          glassesCheckOutcome(o(PhotoOutcomeKind.failed,
              reason: glassesCappedReason, r: true)),
          'queued');
      expect(glassesCheckOutcome(o(PhotoOutcomeKind.failed, r: true)),
          'retry');
      expect(glassesCheckOutcome(o(PhotoOutcomeKind.failed)), 'failed');
      for (final k in [
        PhotoOutcomeKind.alreadyTracked,
        PhotoOutcomeKind.inFlight,
        PhotoOutcomeKind.duplicate,
      ]) {
        expect(glassesCheckOutcome(o(k)), isNull, reason: '$k');
      }
    });
  });

  test('non-food photo → skipped tombstone, no meal', () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': false}, isFood: false, wall: Duration.zero);
    final out =
        await PhotoPipeline(dao: dao, analyzer: analyzer).process(_photo());
    expect(out.kind, PhotoOutcomeKind.skipped);
    expect(out.message, 'No food detected in this photo.'); // spec §5.4 copy
    expect(dao.meals, isEmpty);
    expect(dao.ledger[_hash], IngestionStatus.skipped);
  });

  test('PERMANENT failed analysis → ledger failed, kept for retry', () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome =
          const AnalysisOutcome(error: 'bad key', wall: Duration.zero);
    final out =
        await PhotoPipeline(dao: dao, analyzer: analyzer).process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed);
    expect(dao.ledger[_hash], IngestionStatus.failed);
    expect(dao.meals, isEmpty);
  });

  test('a throwing snackbar on a PERMANENT failure keeps the real verdict',
      () async {
    // The failure notify used to sit outside any shield: a throw fell into
    // the outer catch and the user read "Photo intake failed: …" instead of
    // why the analysis failed.
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome =
          const AnalysisOutcome(error: 'bad key', wall: Duration.zero);
    final seen = <PhotoOutcome>[];
    final out = await PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        notify: (o) {
          seen.add(o);
          throw StateError('snackbar died');
        }).process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed);
    expect(out.message, 'bad key');
    expect(seen.single, same(out));
    expect(dao.ledger[_hash], IngestionStatus.failed);
  });

  test('RETRYABLE failed analysis → reservation released, not burned',
      () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          error: 'rate limit', retryable: true, wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final out = await pipeline.process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed);
    // Released: NO ledger row — the next scan re-offers the photo instead
    // of dropping it forever (automated intake never reclaims 'failed').
    expect(dao.ledger.containsKey(_hash), isFalse);

    // And a later scan CAN save it once the transient trouble clears.
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final retry = await pipeline.process(_photo());
    expect(retry.kind, PhotoOutcomeKind.saved);
    expect(dao.ledger[_hash], IngestionStatus.saved);
  });

  // 2026-10-18: the iOS background engine cannot decode HEIC through
  // dart:ui (its GPU is off), and burning such a photo to 'failed' lost it
  // for good — watch intake never reclaims a failure.
  group('the iOS background engine (deferUndecodable)', () {
    test('a photo the analyzer could not decode is DEFERRED: released, '
        'retryable, no failed row, no request, no notice', () async {
      final dao = FakeDao();
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: await _analyzerThatCannotDecode(),
          notify: notes.add,
          deferUndecodable: true);
      final out = await pipeline.process(_photo()); // [1,2,3]: not a JPEG
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(out.retryable, isTrue,
          reason: 'the frontier waits and the next run re-offers it');
      expect(out.errorKind, AnalysisErrorKind.badPhoto);
      expect(dao.ledger.containsKey(_hash), isFalse,
          reason: 'released — not failed, not left processing');
      expect(dao.meals, isEmpty);
      expect(notes, isEmpty);
    });

    test("the app's own run keeps the permanent verdict for the same photo",
        () async {
      final dao = FakeDao();
      final out = await PhotoPipeline(
              dao: dao, analyzer: await _analyzerThatCannotDecode())
          .process(_photo());
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(out.retryable, isFalse);
      expect(dao.ledger[_hash], IngestionStatus.failed);
    });

    test('the deferral is for undecodable photos only: other permanent '
        'failures still burn', () async {
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome =
            const AnalysisOutcome(error: 'bad key', wall: Duration.zero);
      final out = await PhotoPipeline(
              dao: dao, analyzer: analyzer, deferUndecodable: true)
          .process(_photo());
      expect(out.retryable, isFalse);
      expect(dao.ledger[_hash], IngestionStatus.failed);
    });

    test('a deferred photo is saved once a run can decode it', () async {
      final dao = FakeDao();
      await PhotoPipeline(
              dao: dao,
              analyzer: await _analyzerThatCannotDecode(),
              deferUndecodable: true)
          .process(_photo());
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      final out =
          await PhotoPipeline(dao: dao, analyzer: analyzer).process(_photo());
      expect(out.kind, PhotoOutcomeKind.saved);
      expect(dao.ledger[_hash], IngestionStatus.saved);
    });
  });

  group('the thumbnail after a save', () {
    AnalyzerService food() => FakeAnalyzer()
      ..nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);

    test('a throwing thumbnailer → saved, without a thumb', () async {
      final dao = FakeDao();
      final out = await PhotoPipeline(
              dao: dao,
              analyzer: food(),
              thumbnailer: (_) async => throw StateError('decoder died'))
          .process(_photo());
      expect(out.kind, PhotoOutcomeKind.saved);
      expect(dao.meals, hasLength(1));
      expect(dao.thumbs, isEmpty);
    });

    testWidgets('iOS background run: a thumbnail that never comes does not '
        'hold the verdict past thumbnailTimeout', (tester) async {
      // Fake time (testWidgets). The meal is committed first, but in the
      // iOS background run its card and watermark checkpoint wait for
      // process() to return.
      final dao = FakeDao();
      PhotoOutcome? out;
      PhotoPipeline(
              dao: dao,
              analyzer: food(),
              hasher: (b) async => md5.convert(b).toString(),
              thumbnailer: (_) => Completer<Uint8List?>().future,
              deferUndecodable: true)
          .process(_photo())
          .then((o) => out = o);
      await tester.pump(
          PhotoPipeline.thumbnailTimeout - const Duration(milliseconds: 1));
      expect(dao.meals, hasLength(1), reason: 'saved before the thumb');
      expect(out, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(out?.kind, PhotoOutcomeKind.saved);
      expect(dao.thumbs, isEmpty);
    });

    testWidgets('every other run waits for a slow thumbnail: an abandoned '
        'decode would run beside the next photo', (tester) async {
      final dao = FakeDao();
      final thumb = Completer<Uint8List?>();
      PhotoOutcome? out;
      PhotoPipeline(
              dao: dao,
              analyzer: food(),
              hasher: (b) async => md5.convert(b).toString(),
              thumbnailer: (_) => thumb.future)
          .process(_photo())
          .then((o) => out = o);
      await tester.pump(PhotoPipeline.thumbnailTimeout * 3);
      expect(dao.meals, hasLength(1));
      expect(out, isNull, reason: 'still waiting for the thumb');
      thumb.complete(Uint8List.fromList([0xFF, 0xD8, 0xFF]));
      await tester.pump();
      expect(out?.kind, PhotoOutcomeKind.saved);
      expect(dao.thumbs, hasLength(1));
    });
  });

  // 2026-10-19: the iOS run's deadline replies to workmanager, which
  // destroys the engine — the photo in flight never finished, and its
  // 'processing' row refused every later run and the app for 30 minutes.
  group('abandon() (the iOS run deadline)', () {
    Future<String> syncMd5(Uint8List b) async =>
        md5.convert(b).toString().toLowerCase();

    test('mid-analysis: the reservation is released at once, and the late '
        'reply writes nothing', () async {
      final dao = FakeDao();
      final reply = Completer<void>();
      final analyzer = FakeAnalyzer()
        ..onAnalyze = (() => reply.future)
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      final pipeline =
          PhotoPipeline(dao: dao, analyzer: analyzer, hasher: syncMd5);
      final pending = pipeline.process(_photo());
      await _until(() => dao.ledger[_hash] == IngestionStatus.processing);
      expect(await pipeline.abandon(), 'asset1');
      expect(dao.ledger.containsKey(_hash), isFalse,
          reason: 'released with its stamp: no orphan processing row');
      reply.complete();
      final out = await pending;
      expect(out.retryable, isTrue, reason: 'offered again by a later scan');
      expect(dao.meals, isEmpty);
      expect(dao.ledger.containsKey(_hash), isFalse);
    });

    // The test above passes even without the post-analysis guard: the
    // released row makes the save lose its reservation. Here the release
    // fails (a busy store, or abandon's 1 s limit), the row is still ours,
    // and only the guard keeps the late reply from saving.
    test('mid-analysis, the release failing: the late reply still saves '
        'nothing', () async {
      final dao = _FailingReleaseDao();
      final reply = Completer<void>();
      final analyzer = FakeAnalyzer()
        ..onAnalyze = (() => reply.future)
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      final pipeline =
          PhotoPipeline(dao: dao, analyzer: analyzer, hasher: syncMd5);
      final pending = pipeline.process(_photo());
      await _until(() => dao.ledger[_hash] == IngestionStatus.processing);
      expect(await pipeline.abandon(), 'asset1');
      expect(dao.ledger[_hash], IngestionStatus.processing,
          reason: 'the release failed: the row is still this run\'s');
      reply.complete();
      final out = await pending;
      expect(out.retryable, isTrue);
      expect(dao.meals, isEmpty);
      expect(dao.ledger[_hash], IngestionStatus.processing,
          reason: 'not saved; the stale reclaim frees it in time');
    });

    test('nothing in flight: null, and later photos are not even hashed',
        () async {
      final dao = FakeDao();
      var hashed = 0;
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: FakeAnalyzer(),
          hasher: (b) async {
            hashed++;
            return syncMd5(b);
          });
      expect(await pipeline.abandon(), isNull);
      final out = await pipeline.process(_photo());
      expect(out.retryable, isTrue);
      expect(hashed, 0);
      expect(dao.ledger, isEmpty);
    });

    test('during the reservation itself: the pipeline releases what it got '
        'and uploads nothing', () async {
      final gate = Completer<void>();
      final dao = _SlowReserveDao(gate.future);
      var uploads = 0;
      final analyzer = FakeAnalyzer()..onAnalyze = () async => uploads++;
      final pipeline =
          PhotoPipeline(dao: dao, analyzer: analyzer, hasher: syncMd5);
      final pending = pipeline.process(_photo());
      await _until(() => dao.reserving);
      expect(await pipeline.abandon(), isNull,
          reason: 'not yet reserved when the deadline hit');
      gate.complete();
      final out = await pending;
      expect(out.retryable, isTrue);
      expect(uploads, 0);
      expect(dao.ledger.containsKey(_hash), isFalse);
    });

    test('a meal already saved stays saved; no thumbnail is started after',
        () async {
      final dao = FakeDao();
      final thumbStarted = Completer<void>();
      final thumbDone = Completer<Uint8List?>();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          hasher: syncMd5,
          thumbnailer: (_) {
            thumbStarted.complete();
            return thumbDone.future;
          });
      final pending = pipeline.process(_photo());
      await thumbStarted.future;
      expect(await pipeline.abandon(), isNull,
          reason: 'the row is saved, not a reservation');
      thumbDone.complete(null);
      expect((await pending).kind, PhotoOutcomeKind.saved);
      expect(dao.ledger[_hash], IngestionStatus.saved);
    });
  });

  group('a rejected key on the automatic scan', () {
    // A 401/403 (xAI's 400 'Incorrect API key', Gemini auth) used to burn
    // EVERY scanned photo to 'failed' — watch intake never reclaims, so the
    // backlog was gone for good once the key was fixed — and stacked one
    // snackbar per photo (2026-10-12).
    const rejected = AnalysisOutcome(
        error: 'The provider rejected the API key. Check Settings.',
        wall: Duration.zero);

    test('5 photos → no failed rows, all released, ONE notice', () async {
      final dao = FakeDao();
      final notes = <PhotoOutcome>[];
      var now = DateTime(2026, 10, 12, 9, 0);
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = rejected;
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          notify: notes.add,
          clock: () => now);
      final intake = _SinkCapturingIntake();
      pipeline.bind(intake);
      final photos = [
        for (var i = 1; i <= 5; i++)
          IntakePhoto(Uint8List.fromList([i, i]), 'a$i', 'IMG_$i.jpg'),
      ];
      for (final p in photos) {
        expect(await intake.sink!(p, null), isFalse,
            reason: 'released to the intake: a later scan re-offers it');
        now = now.add(const Duration(seconds: 30));
      }
      expect(dao.ledger.values, isNot(contains(IngestionStatus.failed)));
      expect(dao.ledger, isEmpty, reason: 'every hash free to re-offer');
      expect(notes, hasLength(1));
      expect(notes.single.errorKind, AnalysisErrorKind.rejectedKey);
      expect(notes.single.retryable, isTrue);

      // Throttled per process, not silenced: ten minutes on, it says it
      // again — and once the key works, the same photo saves.
      now = now.add(PhotoPipeline.rejectedKeyNoticeInterval);
      final again = await pipeline.process(photos.first);
      expect(again.retryable, isTrue);
      expect(notes, hasLength(2));

      analyzer.nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      expect((await pipeline.process(photos.first)).kind,
          PhotoOutcomeKind.saved);
    });

    test('a deliberate add keeps the permanent verdict and its dialog text',
        () async {
      final dao = FakeDao();
      final notes = <PhotoOutcome>[];
      final out = await PhotoPipeline(
              dao: dao,
              analyzer: FakeAnalyzer()..nextPhotoOutcome = rejected,
              notify: notes.add)
          .process(_photo(deliberate: true));
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(out.retryable, isFalse);
      expect(dao.ledger[_hash], IngestionStatus.failed);
      expect(notes.single, same(out));
      final zh = AppLocalizationsZh();
      expect(outcomeBody(zh, out), zh.errRejectedKey);
    });
  });

  group('the automatic-analysis latch', () {
    // After a rejected key every scan re-uploaded the whole lookback window
    // (Android every 30 min, each launch/resume, iOS refresh): the photos
    // were released and nothing remembered why (review 2026-10-12).
    const rejected = AnalysisOutcome(
        error: 'The provider rejected the API key. Check Settings.',
        wall: Duration.zero);
    const region = AnalysisOutcome(
        error: 'Gemini is not available from your current network region '
            '(check the VPN).',
        retryable: true,
        wall: Duration.zero);

    ({AutoScanLatch latch, List<String> log, void Function() bump}) memLatch() {
      AnalysisErrorKind? armed;
      var rev = 0;
      final log = <String>[];
      return (
        latch: AutoScanLatch(
          blockedKind: () => armed,
          revision: () => rev,
          block: (k, r) async {
            log.add('block:${k.name}@$r');
            if (r == rev) armed = k;
          },
          clear: () async {
            log.add('clear');
            armed = null;
          },
        ),
        log: log,
        bump: () {
          rev++;
          armed = null; // what every AppSettings credential setter does
        },
      );
    }

    test('after one rejected key, later watch photos are released WITHOUT '
        'an analyzer call; a deliberate add still calls it', () async {
      final dao = FakeDao();
      var calls = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = rejected
        ..onAnalyze = () async => calls++;
      final m = memLatch();
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: dao, analyzer: analyzer, notify: notes.add, latch: m.latch);
      final intake = _SinkCapturingIntake();
      pipeline.bind(intake);
      for (var i = 1; i <= 4; i++) {
        expect(
            await intake.sink!(
                IntakePhoto(Uint8List.fromList([i, i]), 'a$i', 'IMG_$i.jpg'),
                null),
            isFalse,
            reason: 'released: the scan after the fix re-offers it');
      }
      expect(calls, 1, reason: 'photos 2..4 never reached the analyzer');
      expect(m.log, ['block:rejectedKey@0']);
      expect(dao.ledger, isEmpty, reason: 'latched photos are not reserved');
      expect(notes, hasLength(1));

      final latched = await pipeline
          .process(IntakePhoto(Uint8List.fromList([9]), 'a9', 'IMG_9.jpg'));
      expect(latched.kind, PhotoOutcomeKind.failed);
      expect(latched.retryable, isTrue);
      expect(latched.errorKind, AnalysisErrorKind.rejectedKey);

      // The user picks a photo by hand: it bypasses the latch.
      await pipeline.process(_photo(deliberate: true));
      expect(calls, 2);
    });

    test('a success — a deliberate add after the fix — lifts it', () async {
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = rejected;
      final m = memLatch();
      final pipeline =
          PhotoPipeline(dao: FakeDao(), analyzer: analyzer, latch: m.latch);
      await pipeline.process(_photo());
      expect(m.latch.blockedKind(), AnalysisErrorKind.rejectedKey);

      analyzer.nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      expect((await pipeline.process(_photo(deliberate: true))).kind,
          PhotoOutcomeKind.saved);
      expect(m.latch.blockedKind(), isNull);
      // …and the automatic scan reaches the analyzer again.
      var calls = 0;
      analyzer.onAnalyze = () async => calls++;
      await pipeline.process(
          IntakePhoto(Uint8List.fromList([7]), 'a7', 'IMG_7.jpg'));
      expect(calls, 1);
    });

    test('a refusal of a key the user has since replaced does not latch',
        () async {
      final m = memLatch();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = rejected;
      // The key is edited WHILE the photo is at the provider.
      analyzer.onAnalyze = () async => m.bump();
      await PhotoPipeline(dao: FakeDao(), analyzer: analyzer, latch: m.latch)
          .process(_photo());
      expect(m.log, ['block:rejectedKey@0']);
      expect(m.latch.blockedKind(), isNull);
    });

    test('a blocked region on the automatic scan latches and says so ONCE',
        () async {
      // regionBlocked used to be released silently on every photo of
      // every scan: no notice at all, and the whole window re-uploaded.
      var now = DateTime(2026, 10, 12, 9, 0);
      var calls = 0;
      final m = memLatch();
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()
            ..nextPhotoOutcome = region
            ..onAnalyze = () async => calls++,
          notify: notes.add,
          latch: m.latch,
          clock: () => now);
      for (var i = 1; i <= 3; i++) {
        final out = await pipeline.process(
            IntakePhoto(Uint8List.fromList([i]), 'a$i', 'IMG_$i.jpg'));
        expect(out.retryable, isTrue);
        now = now.add(const Duration(seconds: 30));
      }
      expect(calls, 1);
      expect(m.log, ['block:regionBlocked@0']);
      expect(notes, hasLength(1));
      expect(notes.single.errorKind, AnalysisErrorKind.regionBlocked);
      final zh = AppLocalizationsZh();
      expect(outcomeSnackbar(zh, notes.single), contains('VPN'));
    });

    test('a deliberate refusal never arms it', () async {
      final m = memLatch();
      await PhotoPipeline(
              dao: FakeDao(),
              analyzer: FakeAnalyzer()..nextPhotoOutcome = rejected,
              latch: m.latch)
          .process(_photo(deliberate: true));
      expect(m.log, isEmpty);
    });
  });

  test('bound streams process photos ONE at a time (no Gemini burst)',
      () async {
    final dao = FakeDao();
    var active = 0, maxActive = 0, calls = 0;
    final analyzer = FakeAnalyzer();
    analyzer.onAnalyze = () async {
      active++;
      calls++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
    };
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final controller = StreamController<IntakePhoto>.broadcast();
    pipeline.bindStream(controller.stream);
    for (var i = 0; i < 4; i++) {
      controller.add(IntakePhoto(
          Uint8List.fromList([i, i, i]), 'a$i', 'IMG_$i.jpg'));
    }
    while (calls < 4) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(maxActive, 1); // FIFO: a backfill batch must never fan out
  });

  test('watch intake never reclaims a skipped hash; deliberate add does',
      () async {
    final dao = FakeDao();
    dao.ledger[_hash] = IngestionStatus.skipped;
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);

    // Automated intake: strict, no reclaim (spec §2.3 caller policies).
    final auto = await pipeline.process(_photo());
    expect(auto.kind, PhotoOutcomeKind.alreadyTracked);
    expect(dao.meals, isEmpty);

    // Deliberate re-add reclaims failed/skipped/deleted (spec §2.3).
    final deliberate = await pipeline.process(_photo(deliberate: true));
    expect(deliberate.kind, PhotoOutcomeKind.saved);
    expect(dao.meals.single.source, 'app_photo');
  });

  test('a photo another run is still analyzing is IN FLIGHT — retryable, '
      'untouched, not "already logged"', () async {
    // iOS expires the ~30 s background grant mid-analysis; that run's
    // 'processing' row survives until the launch sweep releases it (up to
    // 15 min). Both paths used to read the refused reservation as
    // alreadyTracked (terminal), so the watermark and the watcher's
    // seen-set passed over a photo nobody had analyzed (2026-10-07).
    final dao = FakeDao();
    dao.ledger[_hash] = IngestionStatus.processing;
    var analyzerCalls = 0;
    final analyzer = FakeAnalyzer()
      ..onAnalyze = () async {
        analyzerCalls++;
      };
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);

    final auto = await pipeline.process(_photo());
    expect(auto.kind, PhotoOutcomeKind.inFlight);
    expect(auto.retryable, isTrue,
        reason: 'the frontier must halt in front of it and the watcher '
            'must forget it was seen');
    expect(auto.message,
        'This photo is still being analyzed — check back in a moment.');
    expect(auto.errorKind, AnalysisErrorKind.none);

    // The deliberate path: same answer, and it must NOT steal the analysis
    // (reclaim covers failed/skipped/deleted only — unchanged).
    final deliberate = await pipeline.process(_photo(deliberate: true));
    expect(deliberate.kind, PhotoOutcomeKind.inFlight,
        reason: 'the add flow must not say "already logged" about a photo '
            'that is still being analyzed');
    expect(deliberate.retryable, isTrue);

    expect(analyzerCalls, 0);
    expect(dao.ledger[_hash], IngestionStatus.processing,
        reason: 'the other run\'s row is left alone for it (or the launch '
            'sweep) to finish');
    expect(dao.meals, isEmpty);
  });

  test('bind(): an in-flight photo is RELEASED to the intake (sink false), '
      'a claimed one is terminal', () async {
    final dao = FakeDao();
    dao.ledger[_hash] = IngestionStatus.processing;
    final pipeline = PhotoPipeline(dao: dao, analyzer: FakeAnalyzer());
    final intake = _SinkCapturingIntake();
    pipeline.bind(intake);
    expect(await intake.sink!(_photo(), null), isFalse,
        reason: 'false = the watcher drops its seen entry and halts the '
            'frontier; a later scan re-offers the photo');

    dao.ledger[_hash] = IngestionStatus.saved;
    expect(await intake.sink!(_photo(), null), isTrue,
        reason: 'a real verdict stays terminal — coverage may pass it');
  });

  test('onOutcome hears every verdict once, and a throwing one is contained',
      () async {
    final heard = <(String, PhotoOutcomeKind)>[];
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': false}, isFood: false, wall: Duration.zero);
    final pipeline = PhotoPipeline(
        dao: FakeDao(),
        analyzer: analyzer,
        onOutcome: (p, o) {
          heard.add((p.assetId, o.kind));
          throw StateError('listener died');
        });
    final first = await pipeline.process(_photo());
    final again = await pipeline.process(_photo());
    expect(first.kind, PhotoOutcomeKind.skipped);
    expect(again.kind, PhotoOutcomeKind.alreadyTracked);
    expect(heard, [
      ('asset1', PhotoOutcomeKind.skipped),
      ('asset1', PhotoOutcomeKind.alreadyTracked),
    ]);
  });

  test('deliberate add inside the 5-minute duplicate window is refused',
      () async {
    final dao = FakeDao()..duplicatePhoto = true;
    final pipeline = PhotoPipeline(dao: dao, analyzer: FakeAnalyzer());
    final out = await pipeline.process(_photo(deliberate: true));
    expect(out.kind, PhotoOutcomeKind.duplicate);
    expect(dao.ledger, isEmpty); // refused before reservation (spec §2.3)
  });

  test('a throwing DAO is contained and the hash marked failed', () async {
    final dao = _ThrowingSaveDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final out =
        await PhotoPipeline(dao: dao, analyzer: analyzer).process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed); // contained, no throw (spec §6)
    expect(dao.ledger[_hash], IngestionStatus.failed);
  });

  group('bindStream (share sheet) announces the verdicts nobody awaits', () {
    // A shared photo has no awaiting caller — the add flow awaits enqueue()
    // and shows a dialog, the watcher is meant to stay quiet — so a share
    // that ended not-food / duplicate / already logged / still analyzing
    // gave NO feedback at all, indistinguishable from a share that silently
    // failed (simulator, 2026-10-10).
    const notFood = AnalysisOutcome(
        analysis: {'is_food': false}, isFood: false, wall: Duration.zero);

    /// Shares [photos] through a bound stream and returns what notify saw
    /// once [done] holds (plus a beat, to catch a late second snackbar).
    Future<List<PhotoOutcome>> share(FakeDao dao, FakeAnalyzer analyzer,
        List<IntakePhoto> photos, bool Function(FakeDao dao) done,
        {void Function(PhotoOutcome)? onNotify}) async {
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          notify: (o) {
            notes.add(o);
            onNotify?.call(o);
          });
      final stream = StreamController<IntakePhoto>();
      pipeline.bindStream(stream.stream);
      photos.forEach(stream.add);
      await stream.close();
      await _until(() => done(dao));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await pipeline.dispose();
      return notes;
    }

    test('not food → exactly one snackbar, kind skipped', () async {
      final dao = FakeDao();
      final notes = await share(
          dao,
          FakeAnalyzer()..nextPhotoOutcome = notFood,
          [_photo(deliberate: true)],
          (d) => d.ledger[_hash] == IngestionStatus.skipped);
      expect(notes.map((o) => o.kind), [PhotoOutcomeKind.skipped]);
    });

    for (final (what, dao, kind) in [
      (
        'a duplicate inside the 5-minute window',
        FakeDao()..duplicatePhoto = true,
        PhotoOutcomeKind.duplicate
      ),
      (
        'an already logged photo',
        FakeDao()..ledger[_hash] = IngestionStatus.saved,
        PhotoOutcomeKind.alreadyTracked
      ),
      (
        'a photo another run is still analyzing',
        FakeDao()..ledger[_hash] = IngestionStatus.processing,
        PhotoOutcomeKind.inFlight
      ),
    ]) {
      test('$what → exactly one snackbar, kind ${kind.name}', () async {
        final seen = <PhotoOutcome>[];
        final notes = await share(dao, FakeAnalyzer(), [_photo(deliberate: true)],
            (_) => seen.isNotEmpty,
            onNotify: seen.add);
        expect(notes.map((o) => o.kind), [kind]);
        expect(dao.meals, isEmpty);
      });
    }

    test('a save and a permanent failure are still said ONCE (by process)',
        () async {
      final saved = await share(
          FakeDao(),
          FakeAnalyzer()
            ..nextPhotoOutcome = AnalysisOutcome(
                analysis: _foodAnalysis(), isFood: true, wall: Duration.zero),
          [_photo(deliberate: true)],
          (d) => d.ledger[_hash] == IngestionStatus.saved);
      expect(saved.map((o) => o.kind), [PhotoOutcomeKind.saved]);

      final failed = await share(
          FakeDao(),
          FakeAnalyzer()
            ..nextPhotoOutcome =
                const AnalysisOutcome(error: 'bad key', wall: Duration.zero),
          [_photo(deliberate: true)],
          (d) => d.ledger[_hash] == IngestionStatus.failed);
      expect(failed.map((o) => o.kind), [PhotoOutcomeKind.failed]);
    });

    test('a transient failure is said ONCE and asks for a re-share: the '
        'share copy is gone, so silence read as success', () async {
      var analyzed = false;
      final dao = FakeDao();
      final notes = await share(
          dao,
          FakeAnalyzer()
            ..nextPhotoOutcome = const AnalysisOutcome(
                error: 'rate limit', retryable: true, wall: Duration.zero)
            ..onAnalyze = () async => analyzed = true,
          [_photo(deliberate: true)],
          (_) => analyzed);
      expect(dao.ledger, isEmpty); // released, no row (spec §2.3)
      expect(notes, hasLength(1));
      final o = notes.single;
      expect(o.kind, PhotoOutcomeKind.failed);
      expect(o.shared, isTrue);
      final zh = AppLocalizationsZh();
      expect(outcomeSnackbar(zh, o), zh.outcomeShareRetryMsg('服务正在限流'));
      expect(outcomeSnackbar(zh, o), isNot(contains('已保留')));
    });

    test('enqueue() (the add flow) is NOT told — it renders its own dialog',
        () async {
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()..nextPhotoOutcome = notFood,
          notify: notes.add);
      final out = await pipeline.enqueue(_photo(deliberate: true));
      expect(out.kind, PhotoOutcomeKind.skipped);
      expect(notes, isEmpty,
          reason: 'a second snackbar behind the add flow\'s dialog');
    });

    test('bind() (the automatic watcher) stays quiet about a skipped photo',
        () async {
      // Every screenshot the automatic scan sees is "not food"; announcing
      // that with the app open would be a toast per screenshot.
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()..nextPhotoOutcome = notFood,
          notify: notes.add);
      final intake = _SinkCapturingIntake();
      pipeline.bind(intake);
      expect(await intake.sink!(_photo(), null), isTrue);
      expect(notes, isEmpty);
    });

    test('a throwing snackbar never poisons the shared FIFO', () async {
      // bindStream's notify runs ON the tail every path chains onto: an
      // unshielded throw would reject it and no later photo (watcher,
      // share, coverage Log/Retry) would process until an app restart.
      final second = Uint8List.fromList([4, 5, 6]);
      final secondHash = md5.convert(second).toString().toLowerCase();
      final dao = FakeDao();
      final notes = await share(
          dao,
          FakeAnalyzer()..nextPhotoOutcome = notFood,
          [
            _photo(deliberate: true),
            IntakePhoto(second, 'asset2', 'IMG_2.jpg', deliberate: true),
          ],
          (d) => d.ledger[secondHash] == IngestionStatus.skipped,
          onNotify: (_) => throw StateError('snackbar died'));
      expect(dao.ledger[_hash], IngestionStatus.skipped);
      expect(notes, hasLength(2));
    });
  });
}

/// Polls until [done] holds: bound-stream photos resolve on the pipeline's
/// private FIFO, which nothing outside the pipeline can await.
Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    expect(DateTime.now().isBefore(deadline), isTrue,
        reason: 'the bound stream never reached the expected state');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Hands the test the sink `bind()` attaches, so it can be driven directly.
class _SinkCapturingIntake implements PhotoIntake {
  Future<bool> Function(IntakePhoto, DateTime?)? sink;
  @override
  Stream<IntakePhoto> get photos => const Stream.empty();
  @override
  void attachSink(Future<bool> Function(IntakePhoto, DateTime?)? s) =>
      sink = s;
  @override
  Future<DateTime?> backfillScan(
          {int lookbackDays = 0,
          DateTime? since,
          bool Function()? shouldContinue,
          Future<void> Function(DateTime safeFrontier)? onCovered,
          bool newestDayFirst = false}) async =>
      null;
  @override
  Future<void> lateImportScan({bool Function()? shouldContinue}) async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _ThrowingSaveDao extends FakeDao {
  @override
  Future<int> saveMeal(Meal meal,
      {IngestionStatus? markStatus, String? ownerStamp}) async {
    throw StateError('disk full');
  }
}


class _ThumbThrowingDao extends FakeDao {
  @override
  Future<void> saveMealThumb(int mealId, Uint8List jpeg) async {
    throw StateError('disk full');
  }
}

/// Holds reservePhotoHash open until [gate] completes.
/// A store too busy to release anything.
class _FailingReleaseDao extends FakeDao {
  @override
  Future<void> releasePhotoHash(String imageHash, {String? ownerStamp}) =>
      Future.error(StateError('database is locked'));
}

class _SlowReserveDao extends FakeDao {
  _SlowReserveDao(this.gate);
  final Future<void> gate;
  bool reserving = false;
  @override
  Future<PhotoReservationResult> reservePhotoHash(String imageHash,
      {required String source, bool reclaimDeliberate = false}) async {
    reserving = true;
    await gate;
    return super.reservePhotoHash(imageHash,
        source: source, reclaimDeliberate: reclaimDeliberate);
  }
}
