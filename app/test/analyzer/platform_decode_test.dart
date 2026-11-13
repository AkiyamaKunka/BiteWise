// The second-chance decode that makes iPhone (HEIC) photos analyzable, and
// the rule for what may be sent when every decoder fails.
import 'dart:async';

import 'package:calorie_tracker/services/analyzer/normalize.dart';
import 'package:calorie_tracker/services/analyzer/platform_decode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A real JPEG carrying an APP1 (EXIF) segment, like ImageIO's encoder
/// writes for some inputs.
Uint8List _jpegWithApp1() {
  final plain = img.encodeJpg(img.Image(width: 8, height: 4));
  const app1 = [0xFF, 0xE1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
  return Uint8List.fromList(
      [...plain.sublist(0, 2), ...app1, ...plain.sublist(2)]);
}

bool _hasApp1(Uint8List jpeg) {
  for (var i = 0; i + 1 < jpeg.length; i++) {
    if (jpeg[i] == 0xFF && jpeg[i + 1] == 0xE1) return true;
    if (jpeg[i] == 0xFF && jpeg[i + 1] == 0xDA) return false; // scan starts
  }
  return false;
}

/// A 400x200 JPEG as stored, red | green over blue | white, with EXIF
/// Orientation 6 (turn it 90° clockwise to view it: 200x400 upright) and a
/// GPS position.
Uint8List _rotatedJpegWithGps() {
  final src = img.Image(width: 400, height: 200);
  for (final p in src) {
    final (r, g, b) = p.y < 100
        ? (p.x < 200 ? (255, 0, 0) : (0, 255, 0))
        : (p.x < 200 ? (0, 0, 255) : (255, 255, 255));
    p.setRgb(r, g, b);
  }
  src.exif.imageIfd['Orientation'] = 6;
  src.exif.gpsIfd[0x0001] = img.IfdValueAscii('N'); // GPSLatitudeRef
  src.exif.gpsIfd[0x0002] = img.IfdValueRational(43, 1); // GPSLatitude
  final jpeg = Uint8List.fromList(img.encodeJpg(src));
  expect(_hasApp1(jpeg), isTrue, reason: 'the fixture carries its EXIF');
  expect(img.decodeJpg(jpeg)!.exif.gpsIfd[0x0002], isNotNull);
  return jpeg;
}

/// The chain's steps as call-counting fakes.
class _Steps {
  _Steps({this.dart, this.nativeOut, this.engineOut});
  final Uint8List? dart;
  final Uint8List? nativeOut;
  final Future<Uint8List?>? engineOut;
  int dartCalls = 0, nativeCalls = 0, engineCalls = 0;
  ({int longSidePx, int jpegQuality})? nativeArgs, engineArgs;

  /// The steps in the order they ran.
  final order = <String>[];

  Future<Uint8List?> isolate(
      Uint8List? Function(Uint8List) callback, Uint8List original) async {
    dartCalls++;
    order.add('dart');
    return dart;
  }

  Future<Uint8List?> native(Uint8List original,
      {required int longSidePx, required int jpegQuality}) async {
    nativeCalls++;
    order.add('native');
    nativeArgs = (longSidePx: longSidePx, jpegQuality: jpegQuality);
    return nativeOut;
  }

  Future<Uint8List?> engine(Uint8List original,
      {required int longSidePx, required int jpegQuality}) {
    engineCalls++;
    order.add('engine');
    engineArgs = (longSidePx: longSidePx, jpegQuality: jpegQuality);
    return engineOut ?? Future.value(null);
  }

  /// The chain for the analysis copy, or with [thumb] for the history
  /// thumbnail (what makeMealThumbAny passes). A null [ios] / [headless]
  /// leaves them to the platform defaults.
  Future<Uint8List?> run(
          {bool? ios, bool? headless, bool? backgrounded, bool thumb = false}) =>
      decodeForUpload(Uint8List.fromList([1, 2, 3]),
          pureDart: thumb ? makeMealThumb : normalizeForAnalysis,
          longSidePx: thumb ? kThumbLongSidePx : kAnalysisLongSidePx,
          jpegQuality: thumb ? kThumbJpegQuality : kAnalysisJpegQuality,
          isolate: isolate,
          native: native,
          engine: engine,
          ios: ios,
          headless: headless,
          backgrounded: backgrounded);
}

Future<Uint8List?> _noDecoder(Uint8List original,
        {required int longSidePx, required int jpegQuality}) async =>
    null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('unprocessedFallback', () {
    // SOI + SOS + scan + EOI: a well-formed marker walk with nothing to
    // strip.
    final jpeg = Uint8List.fromList(
        [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 1, 2, 3, 0xFF, 0xD9]);
    final heic = Uint8List.fromList(
        [0, 0, 0, 0x24, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);

    test('a small JPEG may go out unprocessed', () {
      expect(unprocessedFallback(jpeg, maxBytes: 1024), jpeg);
    });

    test('a JPEG at or over the cap may not', () {
      expect(unprocessedFallback(jpeg, maxBytes: jpeg.length), isNull);
    });

    test('anything that is not a JPEG may NEVER go out unprocessed', () {
      // Every provider path labels the upload image/jpeg; raw HEIC under
      // that label reads as "not food".
      expect(looksLikeJpeg(heic), isFalse);
      expect(unprocessedFallback(heic, maxBytes: 1 << 20), isNull);
      expect(unprocessedFallback(Uint8List(0), maxBytes: 1 << 20), isNull);
    });
  });

  group('decodeViaPlatform', () {
    testWidgets('decodes with the engine codec, downscales, emits a JPEG',
        (tester) async {
      // PNG stands in for HEIC: the test host's engine has no HEIC codec,
      // but the path (descriptor -> sized codec -> RGBA -> JPEG) is the same.
      final png = Uint8List.fromList(
          img.encodePng(img.Image(width: 400, height: 200)));
      final out = await tester.runAsync(
          () => decodeViaPlatform(png, longSidePx: 64, jpegQuality: 80));
      expect(out, isNotNull);
      expect(looksLikeJpeg(out!), isTrue);
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 64, reason: 'long side clamped');
      expect(decoded.height, 32, reason: 'aspect preserved');
    });

    testWidgets('never upscales a small image', (tester) async {
      final png = Uint8List.fromList(
          img.encodePng(img.Image(width: 30, height: 20)));
      final out = await tester.runAsync(
          () => decodeViaPlatform(png, longSidePx: 64, jpegQuality: 80));
      final decoded = img.decodeJpg(out!)!;
      expect((decoded.width, decoded.height), (30, 20));
    });

    testWidgets('undecodable bytes answer null, never throw', (tester) async {
      final out = await tester.runAsync(() => decodeViaPlatform(
          Uint8List.fromList(List.filled(64, 7)),
          longSidePx: 64,
          jpegQuality: 80));
      expect(out, isNull);
    });
  });

  // 2026-10-18: the iOS background engine's GPU is off for the whole run,
  // and a dart:ui decode there never completed — the photo stayed reserved
  // and every later run hung on it again.
  group('decodeForUpload', () {
    final jpeg =
        Uint8List.fromList(img.encodeJpg(img.Image(width: 4, height: 4)));

    // Review 171, C0: pure Dart used to run first on Android, so every
    // photo paid two full-resolution pure-Dart decodes, the analysis copy
    // and then the history thumbnail (which the Add flow's spinner waits
    // for): about 4 s of CPU on a desktop core for a 12 MP JPEG, and a
    // 0.75-1.3 GB peak per decode at 50 MP, in the WorkManager run too.
    // The engine codec subsamples a JPEG while it decodes. Android never
    // switches its engine's GPU off, so the background engine keeps it.
    test('Android: the engine codec runs FIRST, at the analysis size, and '
        'neither pure Dart nor ImageIO is called when it answers, in both '
        'engines', () async {
      for (final headless in [false, true]) {
        final steps = _Steps(
            dart: Uint8List(2),
            nativeOut: Uint8List(1),
            engineOut: Future.value(jpeg));
        expect(await steps.run(ios: false, headless: headless), same(jpeg),
            reason: 'headless: $headless');
        expect(steps.order, ['engine'], reason: 'headless: $headless');
        expect(steps.engineArgs,
            (longSidePx: kAnalysisLongSidePx, jpegQuality: kAnalysisJpegQuality));
      }
    });

    test('Android: the thumbnail is the engine codec decoding at the '
        'thumbnail size, not a second full-resolution decode', () async {
      final steps = _Steps(dart: Uint8List(2), engineOut: Future.value(jpeg));
      expect(await steps.run(ios: false, headless: false, thumb: true),
          same(jpeg));
      expect(steps.order, ['engine']);
      expect(steps.engineArgs,
          (longSidePx: kThumbLongSidePx, jpegQuality: kThumbJpegQuality));
    });

    test('Android: pure Dart reads what the engine codec cannot (it stays '
        'the fallback); nothing is asked twice', () async {
      for (final thumb in [false, true]) {
        final viaDart = _Steps(dart: jpeg, nativeOut: Uint8List(1));
        expect(await viaDart.run(ios: false, headless: false, thumb: thumb),
            same(jpeg));
        expect(viaDart.order, ['engine', 'dart'], reason: 'thumb: $thumb');
      }
      final none = _Steps(nativeOut: Uint8List(1));
      expect(await none.run(ios: false, headless: true), isNull);
      expect(none.order, ['engine', 'dart']);
    });

    test('Android by default (the target platform decides): the engine '
        'codec first', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final steps = _Steps(dart: Uint8List(2), engineOut: Future.value(jpeg));
      expect(await steps.run(), same(jpeg));
      expect(steps.order, ['engine']);
    });

    testWidgets('Android: an engine decode that never finishes hands over to '
        'pure Dart at its deadline', (tester) async {
      // testWidgets runs in fake time: the 8 s pass without waiting.
      final steps =
          _Steps(dart: jpeg, engineOut: Completer<Uint8List?>().future);
      Uint8List? result;
      steps.run(ios: false, headless: false).then((r) => result = r);
      await tester
          .pump(kPlatformDecodeTimeout - const Duration(milliseconds: 1));
      expect(result, isNull);
      expect(steps.order, ['engine']);
      await tester.pump(const Duration(milliseconds: 1));
      expect(result, same(jpeg));
      expect(steps.order, ['engine', 'dart']);
    });

    // Run 7, P1: pure Dart used to run first on iOS too, so every JPEG/PNG
    // paid a full-resolution pure-Dart decode (2-4 s and ~330 MB for a
    // 12 MP JPEG, twice per saved photo) before ImageIO was ever asked.
    test('iOS: ImageIO runs FIRST and pure Dart is not called when it '
        'answers, in both engines', () async {
      for (final headless in [false, true]) {
        final steps = _Steps(dart: Uint8List(2), nativeOut: jpeg);
        expect(await steps.run(ios: true, headless: headless), same(jpeg),
            reason: 'headless: $headless');
        expect(steps.order, ['native'], reason: 'headless: $headless');
      }
    });

    test('iOS: ImageIO answers what pure Dart cannot (HEIC), at the '
        'analysis size and quality', () async {
      final steps = _Steps(nativeOut: jpeg);
      expect(await steps.run(ios: true, headless: false), same(jpeg));
      expect(steps.nativeArgs,
          (longSidePx: kAnalysisLongSidePx, jpegQuality: kAnalysisJpegQuality));
      expect(steps.engineCalls, 0,
          reason: 'no GPU decode when ImageIO did it');
    });

    test('iOS app engine (foreground): ImageIO null → pure Dart → the '
        'engine codec', () async {
      final viaDart = _Steps(dart: jpeg, engineOut: Future.value(Uint8List(3)));
      expect(await viaDart.run(ios: true, headless: false, backgrounded: false),
          same(jpeg));
      expect(viaDart.order, ['native', 'dart']);
      final viaEngine = _Steps(engineOut: Future.value(jpeg));
      expect(
          await viaEngine.run(ios: true, headless: false, backgrounded: false),
          same(jpeg));
      expect(viaEngine.order, ['native', 'dart', 'engine']);
    });

    test('iOS background engine: ImageIO null → pure Dart; dart:ui never',
        () async {
      final viaDart = _Steps(dart: jpeg, engineOut: Future.value(Uint8List(3)));
      expect(await viaDart.run(ios: true, headless: true), same(jpeg));
      expect(viaDart.order, ['native', 'dart']);
      final none = _Steps(engineOut: Future.value(jpeg));
      expect(await none.run(ios: true, headless: true), isNull);
      expect(none.order, ['native', 'dart']);
    });

    test('iOS background engine: dart:ui is NEVER called, even when ImageIO '
        'fails', () async {
      final steps = _Steps(engineOut: Future.value(jpeg));
      expect(await steps.run(ios: true, headless: true), isNull);
      expect(steps.nativeCalls, 1);
      expect(steps.engineCalls, 0,
          reason: 'its texture upload parks behind the disabled GPU forever');
    });

    test('iOS app engine: ImageIO null → the engine codec is the fallback',
        () async {
      final steps = _Steps(engineOut: Future.value(jpeg));
      expect(await steps.run(ios: true, headless: false), same(jpeg));
      expect((steps.nativeCalls, steps.dartCalls, steps.engineCalls),
          (1, 1, 1));
    });

    // 2026-10-19: iOS switches the APP engine's GPU off too once the user
    // leaves; a 105 MP HEIC ImageIO refuses hung the full deadline there
    // and was burned to 'failed'.
    test('iOS app engine in the background: ImageIO still runs, dart:ui '
        'never', () async {
      final steps = _Steps(engineOut: Future.value(jpeg));
      expect(
          await steps.run(ios: true, headless: false, backgrounded: true),
          isNull);
      expect((steps.nativeCalls, steps.engineCalls), (1, 0));
      final viaImageIO = _Steps(nativeOut: jpeg);
      final skips = gpuOffDecodeSkips;
      expect(
          await viaImageIO.run(
              ios: true, headless: false, backgrounded: true),
          same(jpeg));
      expect(gpuOffDecodeSkips, skips, reason: 'decoded: nothing skipped');
      // Only a give-up for the GPU counts (PhotoPipeline defers on it).
      await _Steps().run(ios: true, headless: false, backgrounded: true);
      expect(gpuOffDecodeSkips, skips + 1);
      await _Steps().run(ios: true, headless: true);
      await _Steps().run(ios: true, headless: false, backgrounded: false);
      expect(gpuOffDecodeSkips, skips + 1);
    });

    test('the background probe di.dart installs (isEngineBackgrounded) is '
        'what decides by default; a throwing one reads as the foreground',
        () async {
      addTearDown(() => isEngineBackgrounded = () => false);
      isEngineBackgrounded = () => true;
      final away = _Steps(engineOut: Future.value(jpeg));
      expect(await away.run(ios: true, headless: false), isNull);
      expect(away.engineCalls, 0);
      // Android never consults it: its GPU stays on.
      final android = _Steps(engineOut: Future.value(jpeg));
      expect(await android.run(ios: false, headless: false), same(jpeg));
      isEngineBackgrounded = () => throw StateError('no binding');
      final broken = _Steps(engineOut: Future.value(jpeg));
      expect(await broken.run(ios: true, headless: false), same(jpeg));
    });

    test('Android (background too) keeps the engine codec and never asks '
        'for ImageIO', () async {
      // Android never switches its engine's GPU off.
      final steps = _Steps(engineOut: Future.value(jpeg));
      expect(await steps.run(ios: false, headless: true), same(jpeg));
      expect((steps.nativeCalls, steps.engineCalls), (0, 1));
    });

    testWidgets('a dart:ui decode that never finishes answers null at the '
        'deadline — not later, not never', (tester) async {
      // testWidgets runs in fake time: the 8 s pass without waiting.
      final steps = _Steps(engineOut: Completer<Uint8List?>().future);
      var done = false;
      Uint8List? result = Uint8List(1);
      steps.run(ios: false, headless: false).then((r) {
        done = true;
        result = r;
      });
      await tester
          .pump(kPlatformDecodeTimeout - const Duration(milliseconds: 100));
      expect(done, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      expect(done, isTrue);
      expect(result, isNull);
    });

    // A BGAppRefresh grant is ~30 s and the budget admits a photo until
    // 15 s after the scan starts: a stalled ImageIO reply held for the app
    // engine's 15 s would return after iOS had killed the run, leaving the
    // photo 'processing'.
    group('a native reply that never comes', () {
      Future<Uint8List?> stalled(Uint8List original,
              {required int longSidePx, required int jpegQuality}) =>
          Completer<Uint8List?>().future;

      testWidgets('iOS background engine: null at the SHORT headless '
          'deadline, and still no dart:ui', (tester) async {
        expect(kHeadlessNativeDecodeTimeout,
            lessThanOrEqualTo(const Duration(seconds: 5)));
        var engineCalls = 0;
        var done = false;
        Uint8List? result = Uint8List(1);
        decodeForUpload(Uint8List.fromList([1, 2]),
            pureDart: normalizeForAnalysis,
            longSidePx: kAnalysisLongSidePx,
            jpegQuality: kAnalysisJpegQuality,
            isolate: (_, _) async => null,
            native: stalled,
            engine: (_, {required longSidePx, required jpegQuality}) async {
              engineCalls++;
              return Uint8List(1);
            },
            ios: true,
            headless: true).then((r) {
          done = true;
          result = r;
        });
        await tester.pump(
            kHeadlessNativeDecodeTimeout - const Duration(milliseconds: 1));
        expect(done, isFalse);
        await tester.pump(const Duration(milliseconds: 1));
        expect(done, isTrue);
        expect(result, isNull);
        expect(engineCalls, 0);
      });

      testWidgets('iOS background engine: pure Dart still gets its turn '
          'after the short deadline', (tester) async {
        final jpeg =
            Uint8List.fromList(img.encodeJpg(img.Image(width: 4, height: 4)));
        Uint8List? result;
        decodeForUpload(Uint8List.fromList([1, 2]),
            pureDart: normalizeForAnalysis,
            longSidePx: kAnalysisLongSidePx,
            jpegQuality: kAnalysisJpegQuality,
            isolate: (_, _) async => jpeg,
            native: stalled,
            ios: true,
            headless: true).then((r) => result = r);
        await tester.pump(
            kHeadlessNativeDecodeTimeout - const Duration(milliseconds: 1));
        expect(result, isNull);
        await tester.pump(const Duration(milliseconds: 1));
        expect(result, same(jpeg));
      });

      testWidgets("iOS app engine: the longer deadline, then the engine "
          'codec gets its turn', (tester) async {
        final jpeg =
            Uint8List.fromList(img.encodeJpg(img.Image(width: 4, height: 4)));
        Uint8List? result;
        decodeForUpload(Uint8List.fromList([1, 2]),
            pureDart: normalizeForAnalysis,
            longSidePx: kAnalysisLongSidePx,
            jpegQuality: kAnalysisJpegQuality,
            isolate: (_, _) async => null,
            native: stalled,
            engine: (_, {required longSidePx, required jpegQuality}) async =>
                jpeg,
            ios: true,
            headless: false).then((r) => result = r);
        await tester.pump(kHeadlessNativeDecodeTimeout);
        expect(result, isNull, reason: 'the app engine is not hurried');
        await tester.pump(kNativeDecodeTimeout - kHeadlessNativeDecodeTimeout);
        expect(result, same(jpeg));
      });
    });

    test('a step that throws is a step that failed — never a throw',
        () async {
      final out = await decodeForUpload(Uint8List.fromList([1]),
          pureDart: normalizeForAnalysis,
          longSidePx: 64,
          jpegQuality: 80,
          isolate: (_, _) async => throw StateError('no isolate'),
          native: (_, {required longSidePx, required jpegQuality}) async =>
              throw StateError('channel'),
          engine: (_, {required longSidePx, required jpegQuality}) async =>
              throw StateError('codec'),
          ios: true,
          headless: false);
      expect(out, isNull);
    });

    test('the defaults read the target platform and isHeadlessEngine',
        () async {
      // Production passes no seams: the iOS background run must skip
      // dart:ui on the strength of runHeadlessBackfill's flag alone.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      isHeadlessEngine = true;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        isHeadlessEngine = false;
      });
      var engineCalls = 0;
      final out = await decodeForUpload(Uint8List.fromList([1]),
          pureDart: normalizeForAnalysis,
          longSidePx: 64,
          jpegQuality: 80,
          isolate: (_, _) async => null,
          native: _noDecoder,
          engine: (_, {required longSidePx, required jpegQuality}) async {
            engineCalls++;
            return jpeg;
          });
      expect(out, isNull);
      expect(engineCalls, 0);
    });
  });

  // Review 171, C0: on Android the engine codec, not pure Dart, now makes
  // the copy sent for analysis and the history thumbnail. It must give the
  // picture pure Dart gave (upright by the EXIF Orientation, at the size
  // asked) and carry none of the original's EXIF.
  group('decodeForUpload on Android, with the real engine codec', () {
    /// [_rotatedJpegWithGps] as it is meant to be viewed, one colour per
    /// quadrant: top-left, top-right, bottom-left, bottom-right.
    const upright = [
      (0, 0, 255), // blue: stored bottom-left
      (255, 0, 0), // red: stored top-left
      (255, 255, 255), // white: stored bottom-right
      (0, 255, 0), // green: stored top-right
    ];

    /// [jpeg]'s colour at the centre of each quadrant is [upright]'s, each
    /// channel within JPEG noise.
    void expectUpright(Uint8List jpeg) {
      final im = img.decodeJpg(jpeg)!;
      final w = im.width, h = im.height;
      final at = [
        (w ~/ 4, h ~/ 4),
        (3 * w ~/ 4, h ~/ 4),
        (w ~/ 4, 3 * h ~/ 4),
        (3 * w ~/ 4, 3 * h ~/ 4),
      ];
      for (var q = 0; q < 4; q++) {
        final p = im.getPixel(at[q].$1, at[q].$2);
        final (r, g, b) = upright[q];
        for (final (got, want) in [(p.r, r), (p.g, g), (p.b, b)]) {
          expect((got - want).abs(), lessThan(48),
              reason: 'quadrant $q at ${at[q]}: ${(p.r, p.g, p.b)}, '
                  'want ${upright[q]}');
        }
      }
    }

    testWidgets('the analysis copy: upright and the size pure Dart makes, '
        'no EXIF, and pure Dart never runs', (tester) async {
      final photo = _rotatedJpegWithGps();
      var dartCalls = 0;
      final out = await tester.runAsync(() => decodeForUpload(photo,
          pureDart: normalizeForAnalysis,
          longSidePx: kAnalysisLongSidePx,
          jpegQuality: kAnalysisJpegQuality,
          isolate: (_, _) async {
            dartCalls++;
            return Uint8List(1);
          },
          ios: false,
          headless: false));
      expect(dartCalls, 0, reason: 'no full-resolution pure-Dart decode');
      expect(out, isNotNull);
      expect(looksLikeJpeg(out!), isTrue);
      expect(_hasApp1(out), isFalse, reason: 'no EXIF: no GPS, no camera');
      final viaEngine = img.decodeJpg(out)!;
      final dartOut = normalizeForAnalysis(photo)!;
      final viaDart = img.decodeJpg(dartOut)!;
      expect((viaEngine.width, viaEngine.height), (200, 400));
      expect((viaEngine.width, viaEngine.height),
          (viaDart.width, viaDart.height));
      expectUpright(out);
      expectUpright(dartOut); // the same picture pure Dart made
    });

    testWidgets('the thumbnail: upright at the thumbnail size, no EXIF, and '
        'pure Dart never runs', (tester) async {
      final photo = _rotatedJpegWithGps();
      var dartCalls = 0;
      final out = await tester.runAsync(() => decodeForUpload(photo,
          pureDart: makeMealThumb,
          longSidePx: kThumbLongSidePx,
          jpegQuality: kThumbJpegQuality,
          isolate: (_, _) async {
            dartCalls++;
            return Uint8List(1);
          },
          ios: false,
          headless: true));
      expect(dartCalls, 0, reason: 'no second full-resolution decode');
      expect(out, isNotNull);
      expect(_hasApp1(out!), isFalse);
      final viaEngine = img.decodeJpg(out)!;
      final dartOut = makeMealThumb(photo)!;
      final viaDart = img.decodeJpg(dartOut)!;
      expect((viaEngine.width, viaEngine.height), (80, kThumbLongSidePx));
      expect((viaEngine.width, viaEngine.height),
          (viaDart.width, viaDart.height));
      expectUpright(out);
      expectUpright(dartOut); // the same picture pure Dart made
    });

    // Review 171, second pass: the codec's pixels were read premultiplied
    // and handed to the JPEG encoder as straight RGBA, and the encoder lays
    // a pixel over white by its alpha (a JPEG has none): a second time. The
    // soft shadow or anti-aliased edge of a cut-out PNG came out too dark.
    // Pure Dart, like ImageIO on iOS, lays it over white once.
    testWidgets('a half-transparent PNG is laid over white once, as pure '
        'Dart lays it', (tester) async {
      // Sauce red in four bands, at alpha 0, 64, 128 and 192.
      const alphas = [0, 64, 128, 192];
      final src = img.Image(width: 64, height: 16, numChannels: 4);
      for (final p in src) {
        p
          ..r = 200
          ..g = 40
          ..b = 40
          ..a = alphas[p.x ~/ 16];
      }
      final png = Uint8List.fromList(img.encodePng(src));
      for (final thumb in [false, true]) {
        final pureDart = thumb ? makeMealThumb : normalizeForAnalysis;
        var dartCalls = 0;
        final out = await tester.runAsync(() => decodeForUpload(png,
            pureDart: pureDart,
            longSidePx: thumb ? kThumbLongSidePx : kAnalysisLongSidePx,
            jpegQuality: thumb ? kThumbJpegQuality : kAnalysisJpegQuality,
            isolate: (_, _) async {
              dartCalls++;
              return Uint8List(1);
            },
            ios: false,
            headless: false));
        expect(dartCalls, 0, reason: 'the engine codec decoded it');
        final viaEngine = img.decodeJpg(out!)!;
        final viaDart = img.decodeJpg(pureDart(png)!)!;
        for (var band = 0; band < alphas.length; band++) {
          final e = viaEngine.getPixel(16 * band + 8, 8);
          final d = viaDart.getPixel(16 * band + 8, 8);
          for (final (got, want) in [(e.r, d.r), (e.g, d.g), (e.b, d.b)]) {
            expect((got - want).abs(), lessThanOrEqualTo(3),
                reason: 'thumb: $thumb, alpha ${alphas[band]}: the engine '
                    'gave ${(e.r, e.g, e.b)}, pure Dart ${(d.r, d.g, d.b)}');
          }
        }
      }
    });
  });

  group('orNullAfter', () {
    test('passes a value through', () async {
      expect(await orNullAfter(Future.value(3), const Duration(seconds: 1)),
          3);
    });

    test('a Future<Never> error reaches the caller\'s catch, not the zone',
        () async {
      // `async => throw` is a Future<Never>; a bare .timeout(onTimeout:
      // () => null) on it threw a TypeError before listening, and the
      // StateError surfaced as an unhandled error (found by the "step that
      // throws" test above).
      Future<int?> failing() async => throw StateError('decoder');
      Object? caught;
      try {
        await orNullAfter<int>(failing(), const Duration(seconds: 1));
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
    });
  });

  group('downscaleViaImageIO (mocked channel)', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(imageIOChannel, null));

    Future<Uint8List?> call() =>
        downscaleViaImageIO(Uint8List(3), longSidePx: 64, jpegQuality: 80);

    test('asks ImageIO for the size and quality, returns its JPEG without '
        'APP1', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(imageIOChannel, (call) async {
        seen = call;
        return _jpegWithApp1();
      });
      final original = Uint8List.fromList([9, 8, 7]);
      final out = await downscaleViaImageIO(original,
          longSidePx: kThumbLongSidePx, jpegQuality: kThumbJpegQuality);
      expect(seen!.method, 'downscaleJpeg');
      expect(seen!.arguments, {
        'bytes': original,
        'maxPx': kThumbLongSidePx,
        'quality': kThumbJpegQuality,
      });
      expect(out, isNotNull);
      expect(looksLikeJpeg(out!), isTrue);
      expect(_hasApp1(_jpegWithApp1()), isTrue);
      expect(_hasApp1(out), isFalse,
          reason: 'the same strip rule as every upload');
      expect(img.decodeJpg(out)!.width, 8);
    });

    test('ImageIO answering null → null', () async {
      messenger.setMockMethodCallHandler(imageIOChannel, (_) async => null);
      expect(await call(), isNull);
    });

    test('a PlatformException → null, never a throw', () async {
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) async => throw PlatformException(code: 'boom'));
      expect(await call(), isNull);
    });

    test('no plugin in this engine (MissingPluginException) → null',
        () async {
      // No handler: what an engine without the registration answers.
      expect(await call(), isNull);
    });

    test('a reply that is not a JPEG → null', () async {
      messenger.setMockMethodCallHandler(imageIOChannel,
          (_) async => Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]));
      expect(await call(), isNull);
    });

    testWidgets('a reply that never comes → null at its deadline',
        (tester) async {
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) => Completer<Object?>().future);
      var done = false;
      Uint8List? result = Uint8List(1);
      call().then((r) {
        done = true;
        result = r;
      });
      await tester.pump(kNativeDecodeTimeout);
      expect(done, isTrue);
      expect(result, isNull);
    });

    testWidgets('in the headless engine its deadline is the short one',
        (tester) async {
      isHeadlessEngine = true;
      addTearDown(() => isHeadlessEngine = false);
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) => Completer<Object?>().future);
      var done = false;
      call().then((_) => done = true);
      await tester.pump(
          kHeadlessNativeDecodeTimeout - const Duration(milliseconds: 1));
      expect(done, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(done, isTrue,
          reason: 'and no longer timer is left behind (testWidgets fails '
              'on a pending one)');
    });

    test('end to end on the iOS background engine: the channel fails and '
        'dart:ui is still never touched', () async {
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) async => throw PlatformException(code: 'x'));
      var engineCalls = 0;
      final out = await decodeForUpload(Uint8List.fromList([1, 2]),
          pureDart: normalizeForAnalysis,
          longSidePx: kAnalysisLongSidePx,
          jpegQuality: kAnalysisJpegQuality,
          isolate: (_, _) async => null,
          engine: (_, {required longSidePx, required jpegQuality}) async {
            engineCalls++;
            return null;
          },
          ios: true,
          headless: true);
      expect(out, isNull);
      expect(engineCalls, 0);
    });

    test('end to end: the channel JPEG is what the chain returns', () async {
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) async => _jpegWithApp1());
      final out = await decodeForUpload(Uint8List.fromList([1, 2]),
          pureDart: normalizeForAnalysis,
          longSidePx: kAnalysisLongSidePx,
          jpegQuality: kAnalysisJpegQuality,
          isolate: (_, _) async => null,
          ios: true,
          headless: true);
      expect(out, isNotNull);
      expect(_hasApp1(out!), isFalse);
    });
  });
}
