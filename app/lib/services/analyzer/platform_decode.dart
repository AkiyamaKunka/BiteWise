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
