// The second-chance decode that makes iPhone (HEIC) photos analyzable, and
// the rule for what may be sent when every decoder fails.
import 'dart:typed_data';

import 'package:calorie_tracker/services/analyzer/platform_decode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('unprocessedFallback', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
    final heic = Uint8List.fromList(
        [0, 0, 0, 0x24, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);

    test('a small JPEG may go out unprocessed', () {
      expect(unprocessedFallback(jpeg, maxBytes: 1024), same(jpeg));
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
}
