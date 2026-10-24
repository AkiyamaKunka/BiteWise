/// The iOS photo library's persistent change history (design G1a,
/// 2026-10-23): which photos were ADDED since a saved token, whatever date
/// they carry.
///
/// The automatic scan finds new photos by creation date (watcher.dart). A
/// photo another app imports late — the Meta AI app copying glasses photos
/// in hours after they were taken, AirDrop, WeChat, an iCloud download —
/// keeps its capture time as its creationDate, so "created after the last
/// scan" never sees it. iOS 16+ keeps a history of every insert, from any
/// app, across launches; ios/Runner/PhotoChangesPlugin.swift reads it.
/// Android needs none of this: there the scan already filters on the date a
/// photo was added (MediaStore DATE_ADDED), so [platformPhotoChangeSource]
/// is null.
///
/// Not wired into the watcher yet (G1b keeps the token, in the backup-
/// excluded local store, and acts on each [PhotoChangeStatus]).
///
/// Every call answers; none throws. A missing plugin, a platform error, a
/// timeout or a reply of the wrong shape all come back as
/// [PhotoChangeStatus.error] — which changes nothing: the caller keeps its
/// token and tries again later.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// ios/Runner/PhotoChangesPlugin.swift.
const String photoChangesChannelName = 'dev.calorietracker/photochanges';

/// What a call found. The native side's strings, one for one.
enum PhotoChangeStatus {
  /// Read; [InsertedImages.token] is the token to store next.
  ok,

  /// No token was sent: here is the current one, nothing to report.
  fresh,

  /// The token is older than the history iOS keeps (PHPhotosError 3105):
  /// store the new token and rescan by date.
  expired,

  /// History since the token cannot be reconstructed (PHPhotosError 3210,
  /// or a token that no longer unarchives): store the new token and rescan
  /// by date.
  unavailable,

  /// Anything else that went wrong: keep the token, try again later.
  error,

  /// iOS 15: no change history.
  unsupported,

  /// No Photos access (never asked for here).
  denied,
}

const Map<String, PhotoChangeStatus> _statuses = {
  'ok': PhotoChangeStatus.ok,
  'fresh': PhotoChangeStatus.fresh,
  'expired': PhotoChangeStatus.expired,
  'unavailable': PhotoChangeStatus.unavailable,
  'error': PhotoChangeStatus.error,
  'unsupported': PhotoChangeStatus.unsupported,
  'denied': PhotoChangeStatus.denied,
};

/// The statuses that come with a token to store.
const Set<PhotoChangeStatus> _withNewToken = {
  PhotoChangeStatus.ok,
  PhotoChangeStatus.fresh,
  PhotoChangeStatus.expired,
  PhotoChangeStatus.unavailable,
};

/// 8 lowercase hex characters of SHA-256(identifierForVendor): which phone
/// (and app install) a token belongs to.
final RegExp _deviceTagShape = RegExp(r'^[0-9a-f]{8}$');

/// The native caps (InsertedImagesRequest / AlbumRequest in the Swift
/// file); clamped here as well so a caller's typo cannot ask for more.
const int photoChangesMaxLimit = 500;
const Duration photoChangesMaxBudget = Duration(milliseconds: 1500);
const Duration photoChangesDefaultBudget = Duration(milliseconds: 1000);
const int photoChangesMaxChanges = 5000;
const int albumAssetIdsMaxLimit = 1000;

/// How long a call may take before it counts as an error. The native read
/// stops itself after 1.5 s; the rest is resolving IDs and the hop back.
const Duration photoChangesCallTimeout = Duration(seconds: 5);

/// The error codes this side adds to the native ones (which are
/// `no_device_tag`, `archive_failed`, `token_unreadable` and
/// `<NSError domain>:<code>`).
const String photoChangesMalformed = 'malformed';
const String photoChangesMissingPlugin = 'missing_plugin';
const String photoChangesTimeout = 'timeout';

/// currentToken's answer.
class PhotoChangeToken {
  const PhotoChangeToken(this.status,
      {this.token, this.deviceTag, this.errorCode});

  final PhotoChangeStatus status;

  /// Base64 of the archived token; set when [status] is ok.
  final String? token;
  final String? deviceTag;
  final String? errorCode;

  @override
  String toString() => 'PhotoChangeToken($status'
      '${errorCode == null ? '' : ', $errorCode'})';
}

/// One inserted image, as the library has it now.
class InsertedImage {
  const InsertedImage(this.id, {this.created, this.added});

  /// The PHAsset localIdentifier (photo_manager's AssetEntity.id).
  final String id;

  /// creationDate: the capture time, which a late import keeps.
  final DateTime? created;

  /// When it joined the library (iOS 26+ only).
  final DateTime? added;

  @override
  String toString() => 'InsertedImage($id)';
}

/// insertedImagesSince's answer.
class InsertedImages {
  const InsertedImages(this.status,
      {this.token,
      this.ids = const [],
      this.truncated = false,
      this.dropped = 0,
      this.deviceTag,
      this.errorCode});

  final PhotoChangeStatus status;

  /// The token to store next: set for ok, fresh, expired and unavailable
  /// (for error, the one sent, when the native side got that far).
  final String? token;

  /// Newest first by [InsertedImage.created]; only ever non-empty for ok.
  final List<InsertedImage> ids;

  /// The read stopped at its time or change budget: [token] is the last
  /// change it processed, and the next call carries on from there.
  final bool truncated;

  /// Older inserted images left out by the call's limit (ok only). [token]
  /// has moved past them too: only a rescan by date can still find them.
  final int dropped;
  final String? deviceTag;
  final String? errorCode;

  @override
  String toString() => 'InsertedImages($status, ${ids.length} ids'
      '${truncated ? ', truncated' : ''}'
      '${dropped > 0 ? ', $dropped dropped' : ''}'
      '${errorCode == null ? '' : ', $errorCode'})';
}

/// albumAssetIds' answer.
class AlbumAssetIds {
  const AlbumAssetIds(this.status, {this.ids = const [], this.errorCode});

  final PhotoChangeStatus status;
  final List<String> ids;
  final String? errorCode;

  @override
  String toString() => 'AlbumAssetIds($status, ${ids.length} ids'
      '${errorCode == null ? '' : ', $errorCode'})';
}

abstract class PhotoChangeSource {
  /// The library's current token: the starting point for
  /// [insertedImagesSince].
  Future<PhotoChangeToken> currentToken();

  /// Images inserted since [token] (null: none yet → fresh), newest
  /// first, at most [limit] (older ones are only counted, in
  /// [InsertedImages.dropped]), reading history for at most [budget] or
  /// [maxChanges] changes.
  Future<InsertedImages> insertedImagesSince(String? token,
      {int limit = 50,
      Duration budget = photoChangesDefaultBudget,
      int maxChanges = photoChangesMaxChanges});

  /// Images created at or after [since] in the user albums titled one of
  /// [titles] (case-insensitive), at most [limit].
  Future<AlbumAssetIds> albumAssetIds(List<String> titles,
      {DateTime? since, int limit = 500});
}

/// The channel to PhotoChangesPlugin.swift on iOS; null elsewhere.
PhotoChangeSource? platformPhotoChangeSource({bool? isIOS}) =>
    (isIOS ?? Platform.isIOS) ? ChannelPhotoChangeSource() : null;

class ChannelPhotoChangeSource implements PhotoChangeSource {
  ChannelPhotoChangeSource(
      {this._channel = const MethodChannel(photoChangesChannelName),
      this.timeout = photoChangesCallTimeout});

  final MethodChannel _channel;
  final Duration timeout;

  /// The raw reply, or the error code for why there is none.
  Future<(Object?, String?)> _invoke(String method,
      [Map<String, Object?>? args]) async {
    try {
      final reply = await _channel
          .invokeMethod<Object?>(method, args)
          .then<(Object?, String?)>((v) => (v, null))
          .timeout(timeout, onTimeout: () => (null, photoChangesTimeout));
      return reply;
    } on MissingPluginException {
      return (null, photoChangesMissingPlugin);
    } on PlatformException catch (e) {
      return (null, 'platform:${e.code}');
    } catch (_) {
      return (null, 'exception');
    }
  }

  @override
  Future<PhotoChangeToken> currentToken() async {
    final (reply, failure) = await _invoke('currentToken');
    if (failure != null) {
      return PhotoChangeToken(PhotoChangeStatus.error, errorCode: failure);
    }
    return decodeCurrentToken(reply);
  }

  @override
  Future<InsertedImages> insertedImagesSince(String? token,
      {int limit = 50,
      Duration budget = photoChangesDefaultBudget,
      int maxChanges = photoChangesMaxChanges}) async {
    final (reply, failure) = await _invoke('insertedImagesSince', {
      'token': token,
      'limit': limit.clamp(1, photoChangesMaxLimit),
      'budget_ms':
          budget.inMilliseconds.clamp(0, photoChangesMaxBudget.inMilliseconds),
      'max_changes': maxChanges.clamp(1, photoChangesMaxChanges),
    });
    if (failure != null) {
      return InsertedImages(PhotoChangeStatus.error, errorCode: failure);
    }
    return decodeInsertedImages(reply);
  }

  @override
  Future<AlbumAssetIds> albumAssetIds(List<String> titles,
      {DateTime? since, int limit = 500}) async {
    final (reply, failure) = await _invoke('albumAssetIds', {
      'titles': titles,
      'sinceMs': since?.millisecondsSinceEpoch ?? 0,
      'limit': limit.clamp(1, albumAssetIdsMaxLimit),
    });
    if (failure != null) {
      return AlbumAssetIds(PhotoChangeStatus.error, errorCode: failure);
    }
    return decodeAlbumAssetIds(reply);
  }
}

// ---------------------------------------------------------------------------
// Decoding. A reply that is not exactly the contract's shape is an error,
// never a partial result: a dropped ID behind an advanced token would be a
// photo lost, while an error keeps the token and the next call reads the
// same changes again.

class _Malformed implements Exception {
  const _Malformed();
}

Map<Object?, Object?> _asMap(Object? reply) =>
    reply is Map ? reply : throw const _Malformed();

PhotoChangeStatus _status(Map<Object?, Object?> map) =>
    _statuses[map['status']] ?? (throw const _Malformed());

/// [key]'s String, null when absent; anything else is malformed.
String? _optionalString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is String) return value;
  throw const _Malformed();
}

/// A token to store: a non-empty String.
String _requiredToken(Map<Object?, Object?> map) {
  final token = _optionalString(map, 'token');
  if (token == null || token.isEmpty) throw const _Malformed();
  return token;
}

/// The device tag, which must have its shape whenever it is present and
/// must be present with every token to store.
String? _deviceTag(Map<Object?, Object?> map, {required bool required}) {
  final tag = _optionalString(map, 'device_tag');
  if (tag == null) {
    if (required) throw const _Malformed();
    return null;
  }
  if (!_deviceTagShape.hasMatch(tag)) throw const _Malformed();
  return tag;
}

/// error_code: a String, or a number some native path sent as one.
String? _errorCode(Map<Object?, Object?> map) {
  final value = map['error_code'];
  if (value == null) return null;
  if (value is String) return value;
  if (value is int) return '$value';
  throw const _Malformed();
}

/// Epoch milliseconds → local DateTime; null when absent.
DateTime? _millis(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int || value.abs() > 8640000000000000) {
    throw const _Malformed();
  }
  return DateTime.fromMillisecondsSinceEpoch(value);
}

/// currentToken's reply → [PhotoChangeToken]; malformed → error.
@visibleForTesting
PhotoChangeToken decodeCurrentToken(Object? reply) {
  try {
    final map = _asMap(reply);
    final status = _status(map);
    switch (status) {
      case PhotoChangeStatus.ok:
        return PhotoChangeToken(status,
            token: _requiredToken(map),
            deviceTag: _deviceTag(map, required: true));
      case PhotoChangeStatus.error:
      case PhotoChangeStatus.unsupported:
      case PhotoChangeStatus.denied:
        return PhotoChangeToken(status,
            deviceTag: _deviceTag(map, required: false),
            errorCode: _errorCode(map));
      case PhotoChangeStatus.fresh:
      case PhotoChangeStatus.expired:
      case PhotoChangeStatus.unavailable:
        // Not answers currentToken gives.
        throw const _Malformed();
    }
  } catch (_) {
    return const PhotoChangeToken(PhotoChangeStatus.error,
        errorCode: photoChangesMalformed);
  }
}

/// insertedImagesSince's reply → [InsertedImages]; malformed → error.
@visibleForTesting
InsertedImages decodeInsertedImages(Object? reply) {
  try {
    final map = _asMap(reply);
    final status = _status(map);
    final truncatedValue = map['truncated'];
    if (truncatedValue != null && truncatedValue is! bool) {
      throw const _Malformed();
    }
    final truncated = truncatedValue == true;
    final errorCode = _errorCode(map);
    if (!_withNewToken.contains(status)) {
      // error / unsupported / denied: nothing to act on but the reason.
      return InsertedImages(status,
          token: _optionalString(map, 'token'),
          deviceTag: _deviceTag(map, required: false),
          errorCode: errorCode);
    }
    final token = _requiredToken(map);
    final deviceTag = _deviceTag(map, required: true);
    if (status != PhotoChangeStatus.ok) {
      // fresh / expired / unavailable restart from [token]; they never
      // carry IDs.
      return InsertedImages(status,
          token: token, deviceTag: deviceTag, errorCode: errorCode);
    }
    final droppedValue = map['dropped'] ?? 0;
    if (droppedValue is! int || droppedValue < 0) throw const _Malformed();
    final rawIds = map['ids'];
    if (rawIds is! List) throw const _Malformed();
    final ids = <InsertedImage>[];
    for (final raw in rawIds) {
      final entry = _asMap(raw);
      final id = entry['id'];
      if (id is! String || id.isEmpty) throw const _Malformed();
      ids.add(InsertedImage(id,
          created: _millis(entry, 'created_ms'),
          added: _millis(entry, 'added_ms')));
    }
    return InsertedImages(status,
        token: token,
        ids: List.unmodifiable(ids),
        truncated: truncated,
        dropped: droppedValue,
        deviceTag: deviceTag,
        errorCode: errorCode);
  } catch (_) {
    return const InsertedImages(PhotoChangeStatus.error,
        errorCode: photoChangesMalformed);
  }
}

/// albumAssetIds' reply → [AlbumAssetIds]; malformed → error.
@visibleForTesting
AlbumAssetIds decodeAlbumAssetIds(Object? reply) {
  try {
    final map = _asMap(reply);
    final status = _status(map);
    switch (status) {
      case PhotoChangeStatus.ok:
        final rawIds = map['ids'];
        if (rawIds is! List) throw const _Malformed();
        final ids = <String>[];
        for (final id in rawIds) {
          if (id is! String || id.isEmpty) throw const _Malformed();
          ids.add(id);
        }
        return AlbumAssetIds(status, ids: List.unmodifiable(ids));
      case PhotoChangeStatus.error:
      case PhotoChangeStatus.unsupported:
      case PhotoChangeStatus.denied:
        return AlbumAssetIds(status, errorCode: _errorCode(map));
      case PhotoChangeStatus.fresh:
      case PhotoChangeStatus.expired:
      case PhotoChangeStatus.unavailable:
        throw const _Malformed();
    }
  } catch (_) {
    return const AlbumAssetIds(PhotoChangeStatus.error,
        errorCode: photoChangesMalformed);
  }
}

// ---------------------------------------------------------------------------

/// A scripted [PhotoChangeSource] for tests (G1b's cursor, the watcher).
/// Each answer comes from its handler when set, else a quiet default: a
/// token `fake-token-<n>` with [deviceTag], nothing inserted, no albums.
/// Every call is recorded.
@visibleForTesting
class FakePhotoChangeSource implements PhotoChangeSource {
  FakePhotoChangeSource({this.deviceTag = 'a1b2c3d4'});

  String deviceTag;
  int _serial = 0;

  PhotoChangeToken Function()? onCurrentToken;
  InsertedImages Function(String? token, int limit, Duration budget,
      int maxChanges)? onInsertedImagesSince;
  AlbumAssetIds Function(List<String> titles, DateTime? since, int limit)?
      onAlbumAssetIds;

  int currentTokenCalls = 0;
  final List<String?> insertedImagesSinceTokens = [];
  final List<List<String>> albumAssetIdsTitles = [];

  /// A new token, as the library would hand out after a change.
  String nextToken() => 'fake-token-${++_serial}';

  @override
  Future<PhotoChangeToken> currentToken() async {
    currentTokenCalls++;
    return onCurrentToken?.call() ??
        PhotoChangeToken(PhotoChangeStatus.ok,
            token: nextToken(), deviceTag: deviceTag);
  }

  @override
  Future<InsertedImages> insertedImagesSince(String? token,
      {int limit = 50,
      Duration budget = photoChangesDefaultBudget,
      int maxChanges = photoChangesMaxChanges}) async {
    insertedImagesSinceTokens.add(token);
    final handler = onInsertedImagesSince;
    if (handler != null) return handler(token, limit, budget, maxChanges);
    if (token == null) {
      return InsertedImages(PhotoChangeStatus.fresh,
          token: nextToken(), deviceTag: deviceTag);
    }
    return InsertedImages(PhotoChangeStatus.ok,
        token: token, deviceTag: deviceTag);
  }

  @override
  Future<AlbumAssetIds> albumAssetIds(List<String> titles,
      {DateTime? since, int limit = 500}) async {
    albumAssetIdsTitles.add(List.of(titles));
    return onAlbumAssetIds?.call(titles, since, limit) ??
        const AlbumAssetIds(PhotoChangeStatus.ok);
  }
}
