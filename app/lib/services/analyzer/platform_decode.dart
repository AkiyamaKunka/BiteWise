/// Second-chance image decodes for what the pure-Dart `image` package
/// (normalize.dart) cannot read.
///
/// That package has no HEIC/HEIF decoder, and every iPhone camera photo is
/// HEIC. Until 2026-09-30 a failed decode fell back to "send the original
/// bytes" — raw HEIC, which every provider path labels image/jpeg. The
/// model cannot read that and answers `is_food: false`, so on the owner's
/// iPhone 94 of 102 photos were silently "not food" (the same test image:
/// JPEG → food, HEIC → not food).
///
/// The chain, in order ([decodeForUpload]):
///   1. iOS only: ImageIO over a platform channel
///      (ios/Runner/ImageIOPlugin.swift) — CPU only;
///   2. pure Dart in an isolate;
///   3. the engine codec (dart:ui), which decodes whatever the OS can
///      (HEIC/HEIF/AVIF on iOS and modern Android), with orientation
///      applied, at a reduced target size — never in the iOS background
///      engine, and always under [kPlatformDecodeTimeout].
/// On Android the engine codec runs FIRST, and pure Dart is the fallback
/// for what it could not decode.
///
/// WHY IMAGEIO FIRST ON iOS (run 7, P1): until then pure Dart ran first
/// everywhere, so on iOS only HEIC (which it cannot read) reached ImageIO,
/// and every JPEG/PNG (WeChat and Safari saves, screenshots, AirDrop,
/// "Most Compatible" camera photos) paid a full-resolution pure-Dart
/// decode — twice per saved photo (upload copy + thumbnail): about 2-4 s
/// of CPU and a 330 MB peak for a 12 MP JPEG (14 s / 1.2 GB at 48 MP),
/// against about 0.1 s and 56 MB through ImageIO, which subsamples a
/// JPEG while decoding. Its output is upright, sRGB, capped, and stripped
/// by [stripJpegMetadata] like every upload.
///
/// WHY THE ENGINE CODEC FIRST ON ANDROID (review 171, C0): pure Dart ran
/// first there until then, so every Android photo paid the same two
/// full-resolution decodes (the copy sent for analysis, then the history
/// thumbnail, which the Add flow's spinner waits for), the WorkManager run
/// included: about 2 s of desktop CPU each for a 12 MP JPEG, and 4.5-8 s
/// with a 0.75-1.3 GB peak each at 50 MP. The engine codec subsamples a
/// JPEG while it decodes: 0.3-0.8 s for that 12 MP photo's analysis copy
/// and about 50 ms for its thumbnail, on the same machine. Its output is
/// upright (the codec applies the EXIF Orientation), capped, and encoded
/// from bare pixels, so it carries no EXIF ([decodeViaPlatform]).
///
/// WHY 2 AND THE RULES ON 3 (2026-10-18): the background scan runs in a
/// headless engine, and on iOS that engine's GPU switch is off for the whole
/// BGAppRefresh run (FlutterEngine.mm sets it from the application state;
/// only entering the foreground clears it). dart:ui decodes the pixels on
/// the CPU but parks the texture upload until the GPU returns, so
/// `getNextFrame()` neither completed nor threw. The photo was already
/// reserved, no request ever left the phone, iOS expired the run, and every
/// run after it reclaimed the same photo and hung again — the background
/// watermark froze on Oct 11 and Oct 15 while runs kept starting.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, compute, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:image/image.dart' as img;

import 'normalize.dart';

/// The native ImageIO downscaler (ios/Runner/ImageIOPlugin.swift),
/// registered for the app's engine and the headless background one.
const String imageIOChannelName = 'dev.calorietracker/imageio';
const MethodChannel imageIOChannel = MethodChannel(imageIOChannelName);

/// The engine codec's deadline. A healthy decode of a phone photo at the
/// analysis size takes well under a second; a texture upload parked behind
/// a disabled GPU never finishes at all. Past this the photo counts as
/// undecodable for this attempt (null), instead of holding its reservation
/// until the OS kills the process.
const Duration kPlatformDecodeTimeout = Duration(seconds: 8);

/// The native call's deadline in the app's engine: generous (ImageIO is
/// CPU-only and finishes), but a reply that never comes must not hang the
/// pipeline either; past it the engine codec still gets its turn.
const Duration kNativeDecodeTimeout = Duration(seconds: 15);

/// The native call's deadline in the headless background engine. iOS gives
/// a BGAppRefresh run about 30 s, and `iosBackgroundBudget`
/// (ui/background_glue.dart) admits a photo until 15 s after the run
/// started (`backgroundRunStart`), itself a moment into the grant. A
/// stalled reply held for [kNativeDecodeTimeout] would come back past the
/// grant, after iOS had killed the run, and the photo's reservation would
/// be left 'processing' — the orphan this engine's rules exist to prevent.
/// ImageIO needs well under a second for a 48 MP HEIC; a miss here only
/// defers the photo (PhotoPipeline.deferUndecodable), so the deadline can
/// be short.
const Duration kHeadlessNativeDecodeTimeout = Duration(seconds: 5);

/// The native deadline for this engine: [kHeadlessNativeDecodeTimeout] in
/// the headless one ([headless], else [isHeadlessEngine]), otherwise
/// [kNativeDecodeTimeout].
Duration nativeDecodeTimeoutFor({bool? headless}) =>
    (headless ?? isHeadlessEngine)
        ? kHeadlessNativeDecodeTimeout
        : kNativeDecodeTimeout;

/// True in the headless background engine. Set first thing by
/// runHeadlessBackfill (ui/background_glue.dart) and never cleared: a
/// top-level variable is per-isolate, and the background engine's isolate
/// runs nothing but that one task. The app's own engine leaves it false.
bool isHeadlessEngine = false;

/// iOS, the app's own engine: whether it is in the background right now,
/// where iOS has switched its GPU off just like the headless engine's
/// (FlutterEngine.mm, on didEnterBackground) and a dart:ui decode parks
/// the same way (2026-10-19: a 105 MP HEIC ImageIO refuses hung the full
/// [kPlatformDecodeTimeout] and was burned to 'failed'; in the foreground
/// it decodes in under a second). Set by di.dart (appEngineBackgrounded);
/// never true elsewhere.
bool Function() isEngineBackgrounded = _never;
bool _never() => false;

/// How many times [decodeForUpload] gave up on a photo only because the
/// iOS app engine was in the background (dart:ui skipped, GPU off) — not
/// because the photo cannot be decoded. PhotoPipeline reads it around each
/// analysis: a skip during the photo's own analysis defers its badPhoto
/// verdict even when the app is back in the foreground by the time the
/// verdict lands (review, 2026-10-19: the decode and the verdict read the
/// lifecycle at different moments, and a user returning between them got
/// the photo burned to 'failed', which automatic intake never retries).
int gpuOffDecodeSkips = 0;

/// One step of the decode chain: [original] → a JPEG whose long side is at
/// most [longSidePx], or null.
typedef UploadDecoder = Future<Uint8List?> Function(Uint8List original,
    {required int longSidePx, required int jpegQuality});

/// [future]'s value, or null once [limit] passes without one; its error
/// still surfaces to the awaiting caller. Re-typed through `then` FIRST:
/// a future whose runtime type is narrower than its static one (an
/// `async => throw` closure is a `Future<Never>`) rejects `onTimeout: () =>
/// null` with a TypeError at the `timeout` call itself — before any
/// listener is attached, so its own error escaped every try/catch as an
/// unhandled one.
Future<T?> orNullAfter<T>(Future<T?> future, Duration limit) =>
    future.then<T?>((v) => v).timeout(limit, onTimeout: () => null);

/// JPEG magic. The ONLY originals the "send it unprocessed" fallback may
/// ship: every request labels its upload image/jpeg.
bool looksLikeJpeg(Uint8List b) =>
    b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

/// What a failed normalization may still send: the original, but only when
/// it is a small JPEG, and only with its metadata stripped
/// ([stripJpegMetadata]). Null = send nothing (the caller fails the photo
/// visibly instead of asking a model about bytes it cannot read, and a JPEG
/// whose segments cannot be walked is never sent with its GPS intact).
///
/// Only reached when both decoders failed, so nothing re-encodes the pixels:
/// the EXIF Orientation goes with the rest of the EXIF and a rotated photo
/// arrives sideways. Sideways is still readable; its location is not sent.
Uint8List? unprocessedFallback(Uint8List original, {required int maxBytes}) =>
    original.length < maxBytes && looksLikeJpeg(original)
        ? stripJpegMetadata(original)
        : null;

/// [jpeg] without its metadata segments: every APPn except the three a
/// decoder may need — APP0 (JFIF), APP2 (ICC profile / MPF index) and
/// APP14 (Adobe colour transform) — so APP1 (EXIF — GPS location, camera,
/// times — and XMP), APP11 (JUMBF / C2PA Content Credentials, which can
/// carry its own EXIF assertion with the GPS) and APP13 (Photoshop/IPTC,
/// which can name a place) all go; so does every COM, free text no decoder
/// reads that can hold anything. And nothing after the primary image's EOI. That trailer is where
/// MPF secondary images (iPhone gain maps, previews) and vendor blobs
/// (Samsung Motion Photo video) live, each able to carry its own EXIF/GPS.
/// Every other segment and all entropy-coded data — every scan of a
/// progressive JPEG, restart markers included — is copied byte-for-byte, so
/// the pixels are untouched. Null when the walk hits a malformed or
/// truncated segment, or runs out of bytes before the EOI.
Uint8List? stripJpegMetadata(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var sawScan = false;
  var i = 2;
  while (i < jpeg.length) {
    if (jpeg[i] != 0xFF) return null;
    // Fill bytes: any number of 0xFF may precede a marker code.
    var m = i + 1;
    while (m < jpeg.length && jpeg[m] == 0xFF) {
      m++;
    }
    if (m >= jpeg.length) return null;
    final marker = jpeg[m];
    if (marker == 0xD9) {
      if (!sawScan) return null; // EOI before any scan: no image to send
      // The primary image ends here; whatever follows is not sent.
      out.add(Uint8List.sublistView(jpeg, i, m + 1));
      return out.takeBytes();
    }
    if (marker == 0x00 || marker == 0xD8) {
      return null; // stuffing outside entropy data / a second SOI
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      out.add(Uint8List.sublistView(jpeg, i, m + 1)); // standalone marker
      i = m + 1;
      continue;
    }
    if (m + 2 >= jpeg.length) return null;
    final len = (jpeg[m + 1] << 8) | jpeg[m + 2];
    final end = m + 1 + len;
    if (len < 2 || end > jpeg.length) return null;
    final isApp = marker >= 0xE0 && marker <= 0xEF;
    final dropped = marker == 0xFE ||
        (isApp && marker != 0xE0 && marker != 0xE2 && marker != 0xEE);
    if (!dropped) {
      out.add(Uint8List.sublistView(jpeg, i, end));
    }
    i = end;
    if (marker == 0xDA) {
      // SOS: entropy-coded data follows. Inside it 0xFF is only ever
      // followed by 0x00 (stuffing) or D0–D7 (restart); anything else is
      // the next marker — EOI, or a DHT/SOS/DRI between progressive scans.
      sawScan = true;
      var k = end;
      while (true) {
        if (k + 1 >= jpeg.length) return null; // no EOI: truncated
        if (jpeg[k] == 0xFF) {
          final next = jpeg[k + 1];
          if (next != 0x00 && (next < 0xD0 || next > 0xD7)) break;
          k += 2;
        } else {
          k++;
        }
      }
      out.add(Uint8List.sublistView(jpeg, end, k));
      i = k;
    }
  }
  return null; // no EOI: there is no complete image to send
}

/// The analysis JPEG (1568 px, q85 — the shared constants).
Future<Uint8List?> normalizeAnyForAnalysis(Uint8List original) =>
    decodeForUpload(original,
        pureDart: normalizeForAnalysis,
        longSidePx: kAnalysisLongSidePx,
        jpegQuality: kAnalysisJpegQuality);

/// The history thumbnail, through the same chain: ImageIO or the engine
/// codec decode at the thumbnail size, never a second full-resolution
/// decode of the original (pure Dart, their fallback, still makes one).
Future<Uint8List?> makeMealThumbAny(Uint8List original) =>
    decodeForUpload(original,
        pureDart: makeMealThumb,
        longSidePx: kThumbLongSidePx,
        jpegQuality: kThumbJpegQuality);

/// The decode chain (library docs): on iOS ImageIO, then pure Dart, then
/// the engine codec where it can finish; elsewhere (Android) the engine
/// codec, then pure Dart. Null when every allowed step failed — the caller
/// reports an undecodable photo. Never throws.
///
/// The seams default to production: [isolate] runs [pureDart] (compute),
/// [native] is [downscaleViaImageIO], [engine] is [decodeViaPlatform];
/// [ios] / [headless] / [backgrounded] default to the target platform,
/// [isHeadlessEngine] and [isEngineBackgrounded]. The native step is
/// bounded here as well
/// ([nativeDecodeTimeoutFor]), whatever [native] does itself, and the
/// engine step always by [engineTimeout].
///
/// The native JPEG is used as is: ImageIO already baked the orientation,
/// capped the long side and re-encoded at [jpegQuality]. Piping it through
/// the pure-Dart step again would only re-compress it (a second lossy
/// pass) and spend a second decode of the background grant; its metadata
/// is dropped by [downscaleViaImageIO] with the same byte walk the
/// unprocessed fallback uses.
///
/// On Android the engine codec runs FIRST (library docs). Null from it (a
/// format it cannot read, a failure, its deadline) hands the photo to pure
/// Dart, and the engine is not asked again. Android never switches its
/// engine's GPU off, so its background run keeps it — under the same
/// deadline as every other caller. On iOS the engine codec stays the last
/// resort, and never runs in the background engine, or in the app engine
/// while it is in the background: there it cannot finish (library docs).
Future<Uint8List?> decodeForUpload(
  Uint8List original, {
  required Uint8List? Function(Uint8List) pureDart,
  required int longSidePx,
  required int jpegQuality,
  Future<Uint8List?> Function(
          Uint8List? Function(Uint8List) callback, Uint8List original)?
      isolate,
  UploadDecoder native = downscaleViaImageIO,
  UploadDecoder engine = decodeViaPlatform,
  bool? ios,
  bool? headless,
  bool? backgrounded,
  Duration engineTimeout = kPlatformDecodeTimeout,
}) async {
  final onIOS = ios ?? defaultTargetPlatform == TargetPlatform.iOS;
  final inHeadless = onIOS && (headless ?? isHeadlessEngine);
  if (onIOS) {
    // ImageIO first (library docs): a fraction of pure Dart's time and
    // memory for a JPEG/PNG, and the only CPU decoder for HEIC. Null (no
    // plugin, >100 MP, a format it cannot read, its deadline) falls
    // through to pure Dart.
    try {
      final viaImageIO = await orNullAfter(
          native(original, longSidePx: longSidePx, jpegQuality: jpegQuality),
          nativeDecodeTimeoutFor(headless: inHeadless));
      if (viaImageIO != null) return viaImageIO;
    } catch (_) {}
  } else {
    // Android: the engine codec first (library docs). Null (a format it
    // cannot read, such as TIFF or PSD, a failure, its deadline) falls
    // through to pure Dart.
    try {
      final viaCodec = await orNullAfter(
          engine(original, longSidePx: longSidePx, jpegQuality: jpegQuality),
          engineTimeout);
      if (viaCodec != null) return viaCodec;
    } catch (_) {}
  }
  try {
    final viaDart = await (isolate ?? _inIsolate)(pureDart, original);
    if (viaDart != null) return viaDart;
  } catch (_) {
    // compute() can fail to spawn on a low-memory device: try the others.
  }
  if (onIOS) {
    // The iOS background engine, or the app's own while it is in the
    // background: dart:ui would park behind the disabled GPU. Undecodable
    // HERE; the pipeline defers the photo to a run that has a GPU
    // (PhotoPipeline.deferUndecodable / backgrounded).
    if (inHeadless) return null;
    var gpuOff = backgrounded;
    if (gpuOff == null) {
      try {
        gpuOff = isEngineBackgrounded();
      } catch (_) {
        gpuOff = false;
      }
    }
    if (gpuOff) {
      gpuOffDecodeSkips++;
      return null;
    }
  } else {
    // Android asked the engine codec first: there is nothing left to try.
    return null;
  }
  try {
    return await orNullAfter(
        engine(original, longSidePx: longSidePx, jpegQuality: jpegQuality),
        engineTimeout);
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _inIsolate(
        Uint8List? Function(Uint8List) callback, Uint8List original) =>
    compute(callback, original);

/// ImageIO's downscale (ios/Runner/ImageIOPlugin.swift): orientation baked,
/// long side ≤ [longSidePx], JPEG at [jpegQuality], no source metadata.
/// Null on ANY failure — no plugin in this engine (MissingPluginException),
/// a PlatformException, a reply that is not a JPEG, or no reply within
/// [timeout] (default: this engine's, [nativeDecodeTimeoutFor]) — so the
/// chain falls through; never throws.
///
/// The reply goes through [stripJpegMetadata] as well: ImageIO copies no
/// source properties, but its encoder still writes its own small EXIF
/// (colour space, pixel size) and an APP13 block for some inputs. Dropping
/// them keeps the one rule every upload follows — no APP1, no APP13 — and
/// the walk doubles as a structural check of what came back.
Future<Uint8List?> downscaleViaImageIO(Uint8List original,
    {required int longSidePx,
    required int jpegQuality,
    MethodChannel channel = imageIOChannel,
    Duration? timeout}) async {
  try {
    final out = await orNullAfter(
        channel.invokeMethod<Uint8List>('downscaleJpeg', {
          'bytes': original,
          'maxPx': longSidePx,
          'quality': jpegQuality,
        }),
        timeout ?? nativeDecodeTimeoutFor());
    if (out == null || !looksLikeJpeg(out)) return null;
    return stripJpegMetadata(out);
  } catch (_) {
    return null;
  }
}

/// Decode [original] with the engine codec, downscaled so the long side is
/// at most [longSidePx] (never upscaled), and re-encode as JPEG. Null on
/// any failure — an undecodable image is the caller's problem to report.
///
/// The codec applies the EXIF Orientation, so the pixels come out upright
/// and the size is measured on the upright picture; a JPEG larger than
/// that size is subsampled while it decodes, never held at full
/// resolution. The JPEG is encoded from those bare pixels, so none of the
/// original's EXIF (GPS, camera, times) goes with it. A JPEG has no alpha:
/// a transparent pixel is laid over white once ([_encodeRgbaJpeg]), as
/// pure Dart's encoder and ImageIO lay it.
///
/// Can wait forever where the engine's GPU is off (the iOS background
/// engine; see the library docs) — callers go through [decodeForUpload],
/// which never calls it there and bounds it everywhere else.
Future<Uint8List?> decodeViaPlatform(Uint8List original,
    {required int longSidePx, required int jpegQuality}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(original);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    if (w <= 0 || h <= 0) return null;
    int? targetW, targetH;
    if ((w > h ? w : h) > longSidePx) {
      if (w >= h) {
        targetW = longSidePx;
      } else {
        targetH = longSidePx;
      }
    }
    codec = await descriptor.instantiateCodec(
        targetWidth: targetW, targetHeight: targetH);
    image = (await codec.getNextFrame()).image;
    // rawRgba is PREMULTIPLIED: [_encodeRgbaJpeg] relies on it.
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final rgba =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return await compute(
        _encodeRgbaJpeg, (rgba, image.width, image.height, jpegQuality));
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The codec's premultiplied RGBA → a JPEG at the given quality.
///
/// A JPEG has no alpha, so every pixel is laid over white first, once:
/// from premultiplied values that is c + (255 − a) per channel, the same
/// colour pure Dart's encoder makes from a straight one (c·a + 255·(1 − a))
/// and ImageIO's white fill gives. Until review 171's second pass these
/// bytes went to the encoder as straight RGBA, and it laid them over white
/// by their alpha a second time: half-transparent pixels came out too dark.
Uint8List? _encodeRgbaJpeg((Uint8List, int, int, int) a) {
  try {
    final (premultiplied, width, height, quality) = a;
    // Clamped: a premultiplied channel never exceeds its alpha, so a sum
    // over 255 would only come from a malformed pixel; it must not wrap.
    final rgb = Uint8ClampedList(width * height * 3);
    for (var i = 0, o = 0; o < rgb.length; i += 4, o += 3) {
      final white = 255 - premultiplied[i + 3];
      rgb[o] = premultiplied[i] + white;
      rgb[o + 1] = premultiplied[i + 1] + white;
      rgb[o + 2] = premultiplied[i + 2] + white;
    }
    final opaque = img.Image.fromBytes(
        width: width, height: height, bytes: rgb.buffer, numChannels: 3);
    return Uint8List.fromList(img.encodeJpg(opaque, quality: quality));
  } catch (_) {
    return null;
  }
}
