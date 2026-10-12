/// Second-chance image decode through the PLATFORM codec (dart:ui).
///
/// The pure-Dart `image` package (normalize.dart) has no HEIC/HEIF decoder,
/// and every iPhone camera photo is HEIC. Until 2026-09-30 a failed decode
/// fell back to "send the original bytes" — raw HEIC, which every provider
/// path labels image/jpeg. The model cannot read that and answers
/// `is_food: false`, so on the owner's iPhone 94 of 102 photos were
/// silently "not food" (the same test image: JPEG → food, HEIC → not food).
///
/// The engine's own codec decodes whatever the OS can (HEIC/HEIF/AVIF on
/// iOS and modern Android), with orientation applied, at a reduced target
/// size; the RGBA frame is then JPEG-encoded off the UI isolate.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'normalize.dart';

/// JPEG magic. The ONLY originals the "send it unprocessed" fallback may
/// ship: every request labels its upload image/jpeg.
bool looksLikeJpeg(Uint8List b) =>
    b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

/// What a failed normalization may still send: the original, but only when
/// it is a small JPEG. Null = send nothing (the caller fails the photo
/// visibly instead of asking a model about bytes it cannot read).
Uint8List? unprocessedFallback(Uint8List original, {required int maxBytes}) =>
    original.length < maxBytes && looksLikeJpeg(original) ? original : null;

/// The analysis JPEG: pure-Dart decode first (unchanged, runs in an
/// isolate), platform codec second.
Future<Uint8List?> normalizeAnyForAnalysis(Uint8List original) async =>
    await compute(normalizeForAnalysis, original) ??
    await decodeViaPlatform(original,
        longSidePx: kAnalysisLongSidePx, jpegQuality: kAnalysisJpegQuality);

/// The history thumbnail, with the same second chance.
Future<Uint8List?> makeMealThumbAny(Uint8List original) async =>
    await compute(makeMealThumb, original) ??
    await decodeViaPlatform(original,
        longSidePx: kThumbLongSidePx, jpegQuality: kThumbJpegQuality);

/// Decode [original] with the engine codec, downscaled so the long side is
/// at most [longSidePx] (never upscaled), and re-encode as JPEG. Null on
/// any failure — an undecodable image is the caller's problem to report.
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

Uint8List? _encodeRgbaJpeg((Uint8List, int, int, int) a) {
  try {
    final (rgba, width, height, quality) = a;
    final decoded = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgba.buffer,
        bytesOffset: rgba.offsetInBytes,
        numChannels: 4);
    return Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
  } catch (_) {
    return null;
  }
}
