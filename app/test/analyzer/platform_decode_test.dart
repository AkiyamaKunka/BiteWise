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

/// The chain's steps as call-counting fakes.
class _Steps {
  _Steps({this.dart, this.nativeOut, this.engineOut});
  final Uint8List? dart;
  final Uint8List? nativeOut;
  final Future<Uint8List?>? engineOut;
  int dartCalls = 0, nativeCalls = 0, engineCalls = 0;
  ({int longSidePx, int jpegQuality})? nativeArgs;

  Future<Uint8List?> isolate(
      Uint8List? Function(Uint8List) callback, Uint8List original) async {
    dartCalls++;
    return dart;
  }

  Future<Uint8List?> native(Uint8List original,
      {required int longSidePx, required int jpegQuality}) async {
    nativeCalls++;
    nativeArgs = (longSidePx: longSidePx, jpegQuality: jpegQuality);
    return nativeOut;
  }

  Future<Uint8List?> engine(Uint8List original,
      {required int longSidePx, required int jpegQuality}) {
    engineCalls++;
    return engineOut ?? Future.value(null);
  }

  Future<Uint8List?> run({required bool ios, required bool headless}) =>
      decodeForUpload(Uint8List.fromList([1, 2, 3]),
          pureDart: normalizeForAnalysis,
          longSidePx: kAnalysisLongSidePx,
          jpegQuality: kAnalysisJpegQuality,
          isolate: isolate,
          native: native,
          engine: engine,
          ios: ios,
          headless: headless);
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

    test('the pure-Dart result wins; nothing else runs', () async {
      final steps = _Steps(dart: jpeg);
      expect(await steps.run(ios: true, headless: true), same(jpeg));
      expect((steps.nativeCalls, steps.engineCalls), (0, 0));
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
      expect((steps.nativeCalls, steps.engineCalls), (1, 1));
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
