/// Cleans a meal thumbnail before it goes into a backup or export file
/// (1.7.0 iCloud Backup).
///
/// The thumbnails in meal_thumbs are small JPEGs the app made itself, but
/// some carry what the encoder copied from the original: an EXIF block
/// (camera, time, and on some photos the place it was taken), XMP, or an
/// embedded preview. A backup file can be copied anywhere from the Files
/// app, so only what is needed to show the picture is kept.
///
/// Allowlist, segment by segment:
/// - kept: SOI; APP0 when it is JFIF; APP2 only when it is ICC_PROFILE;
///   APP14 (Adobe colour transform); quantization tables (DQT), Huffman
///   tables (DHT), arithmetic conditioning (DAC), the frame header (every
///   SOFn), the restart interval (DRI), DNL, each SOS with its scan data,
///   and the EOI;
/// - dropped: APP1 (EXIF, XMP), every other APP2 (MPF, FPXR), APP0 JFXX
///   (an embedded thumbnail), APP3–APP13, APP15, COM and anything unknown;
/// - everything after the first top-level EOI is cut (a second image
///   appended after the first, as multi-picture files do).
///
/// A file that cannot be walked (no SOI, a segment running past the end,
/// no scan, no EOI) gives null: the thumbnail is left out and counted as
/// skipped, never copied as it is.
///
/// Not the analyzer's stripJpegMetadata (services/analyzer/
/// platform_decode.dart): that one is a denylist that keeps every APP2 so
/// a photo still decodes the way the model expects; a backup file can be
/// copied anywhere, so this one keeps only what it names.
library;

import 'dart:typed_data';

Uint8List? stripThumbnailJpeg(Uint8List b) {
  final n = b.length;
  if (n < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var i = 2;
  var sawScan = false;
  var sawFrame = false;
  while (i < n) {
    if (b[i] != 0xFF) return null;
    // Fill bytes before a marker.
    while (i < n && b[i] == 0xFF) {
      i++;
    }
    if (i >= n) return null;
    final marker = b[i];
    i++;
    if (marker == 0xD9) {
      if (!sawScan || !sawFrame) return null;
      out.add(const [0xFF, 0xD9]);
      return out.takeBytes();
    }
    // Standalone markers outside a scan (TEM, a stray RSTn): nothing to
    // copy.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    if (marker == 0xD8 || marker == 0x00) return null;
    if (i + 2 > n) return null;
    final len = (b[i] << 8) | b[i + 1];
    if (len < 2 || i + len > n) return null;
    final segStart = i - 2;
    final segEnd = i + len;
    final payload = i + 2;
    if (marker == 0xDA) {
      out.add(Uint8List.sublistView(b, segStart, segEnd));
      // Entropy-coded data runs to the next marker that is not a stuffed
      // 0xFF00, a restart marker or a fill byte.
      var j = segEnd;
      while (true) {
        if (j >= n) return null;
        if (b[j] != 0xFF) {
          j++;
          continue;
        }
        if (j + 1 >= n) return null;
        final next = b[j + 1];
        if (next == 0x00 || (next >= 0xD0 && next <= 0xD7)) {
          j += 2;
          continue;
        }
        if (next == 0xFF) {
          j++;
          continue;
        }
        break;
      }
      out.add(Uint8List.sublistView(b, segEnd, j));
      sawScan = true;
      i = j;
      continue;
    }
    final isFrame = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) sawFrame = true;
    final keep = isFrame ||
        marker == 0xC4 || // DHT
        marker == 0xCC || // DAC
        marker == 0xDB || // DQT
        marker == 0xDD || // DRI
        marker == 0xDC || // DNL
        marker == 0xEE || // APP14 Adobe
        (marker == 0xE0 && _startsWith(b, payload, segEnd, _jfif)) ||
        (marker == 0xE2 && _startsWith(b, payload, segEnd, _icc));
    if (keep) out.add(Uint8List.sublistView(b, segStart, segEnd));
    i = segEnd;
  }
  return null;
}

const List<int> _jfif = [0x4A, 0x46, 0x49, 0x46, 0x00]; // "JFIF\0"
const List<int> _icc = [
  0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00 //
]; // "ICC_PROFILE\0"

bool _startsWith(Uint8List b, int from, int end, List<int> tag) {
  if (end - from < tag.length) return false;
  for (var k = 0; k < tag.length; k++) {
    if (b[from + k] != tag[k]) return false;
  }
  return true;
}
