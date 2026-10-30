/// A meal photo's position, for restaurant assist's place query (design
/// R4, 2026-10-24).
///
/// [PhotoLocationReader.forAsset] reads where the photo library says the
/// photo was taken (PHAsset.location, through [AssetLocationSource]) and
/// nothing else: never the photo's bytes. How accurate the fix was and how
/// far it is from the shutter time come from the meal's analysis.capture
/// block (G2a), which was read at intake and holds no coordinates.
///
/// The coordinates live in memory for one place query and are then
/// dropped. A [PhotoPoint] is never stored, logged, exported or sent to an
/// AI recipient: it has no JSON form, and its toString leaves the numbers
/// out. Only Apple Maps on the phone (lib/services/places/places.dart)
/// receives them.
///
/// iOS only in v1. Android reads no photo location (that needs
/// ACCESS_MEDIA_LOCATION, which the app never declares), so the reader is
/// disabled there and answers null without asking.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show immutable;

import 'photo_library.dart' show AssetLocationSource;

/// A photo's latitude and longitude in degrees (WGS 84), for one query.
@immutable
final class PhotoPoint {
  const PhotoPoint._(this.lat, this.lon);

  final double lat;
  final double lon;

  /// A point when [lat] and [lon] are finite and in range; null otherwise.
  /// Exactly (0, 0) is null too: it is how a missing fix gets written as
  /// zeros, and nobody eats at that spot in the Gulf of Guinea.
  static PhotoPoint? tryCreate(double? lat, double? lon) {
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) {
      return null;
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    if (lat == 0 && lon == 0) return null;
    return PhotoPoint._(lat, lon);
  }

  /// No numbers: a point that reaches a log or an error message says
  /// nothing about where anyone was.
  @override
  String toString() => 'PhotoPoint(redacted)';
}

/// How long one read may take before it counts as none.
const Duration photoLocationTimeout = Duration(seconds: 2);

class PhotoLocationReader {
  /// [enabled] defaults to iOS.
  PhotoLocationReader(this._source,
      {bool? enabled, this.timeout = photoLocationTimeout})
      : enabled = enabled ?? Platform.isIOS;

  final AssetLocationSource _source;
  final bool enabled;
  final Duration timeout;

  /// Where the library says [assetId] was taken; null when it has no
  /// location (or the user removed it in Photos), when the numbers are not
  /// a position, when [assetId] is empty (a photo that came through the
  /// share sheet has no library asset), when the read fails or takes
  /// longer than [timeout], and always when the reader is disabled. Never
  /// throws.
  Future<PhotoPoint?> forAsset(String assetId) async {
    if (!enabled) return null;
    final id = assetId.trim();
    if (id.isEmpty) return null;
    try {
      final at = await _source.assetLatLng(id).timeout(timeout);
      if (at == null) return null;
      return PhotoPoint.tryCreate(at.latitude, at.longitude);
    } catch (_) {
      return null;
    }
  }
}
