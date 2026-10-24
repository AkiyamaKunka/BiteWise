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
/// [LateImportCursor] (design G1b, below) keeps the token in the backup-
/// excluded local store, with the photos still owed a verdict, and acts on
/// each [PhotoChangeStatus]; the watcher runs it after its own scans
/// (LibraryPhotoIntake.lateImportScan).
///
/// Every call answers; none throws. A missing plugin, a platform error, a
/// timeout or a reply of the wrong shape all come back as
/// [PhotoChangeStatus.error] — which changes nothing: the caller keeps its
/// token and tries again later.
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:shared_preferences/shared_preferences.dart';

import '../local_store.dart';
import 'photo_library.dart' show LibraryAsset;

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

// ---------------------------------------------------------------------------
// The late-import cursor (design G1b, 2026-10-23).
//
// One pass, run after the watcher's own scans:
//   1. fetch what the history inserted since the stored token;
//   2. filter: taken within the lookback window, not named by a meal
//      (MealsDao.loggedAssetIds), not already handled this session; newest
//      first, merged into the carry (at most [lateImportCarryLimit]);
//   3. persist {token, carry} BEFORE anything is offered, so a kill
//      mid-pass leaves the rest in the carry and the token past them;
//   4. offer at most [lateImportPassLimit] of the carry, and drop each one
//      from it once it reaches a verdict.
// Then, when a rescan by date is owed (the history expired, or more photos
// arrived than the carry holds), one bounded batch of it.
//
// The document lives in the backup-excluded store and is tied to this
// phone (device_tag): restored onto another one, or unreadable, it starts
// over from the library's current token and offers nothing. Both engines
// write it, last writer wins; an ID that loses that race is found again by
// the rescan, or by the app's catch-up over the whole lookback window.

/// The local_store.dart document that holds the cursor.
const String photoChangeCursorDocument = 'photo_change_cursor';

/// Its schema version ('v').
const int photoChangeCursorVersion = 2;

/// Inserted images one pass asks the history for (newest first). More
/// than the carry holds: most inserts are camera photos the scans already
/// handled, and they are filtered out here.
const int lateImportFetchLimit = 200;

/// Photos one pass offers.
const int lateImportPassLimit = 50;

/// Photos waiting for a verdict across passes. Past it the oldest are let
/// go, and a rescan by date finds them.
const int lateImportCarryLimit = 100;

/// One photo the cursor still owes a verdict.
class LateImportEntry {
  const LateImportEntry(this.id, {this.created});

  /// The PHAsset localIdentifier.
  final String id;

  /// Its creationDate when the history reported it; null if unknown.
  final DateTime? created;

  Map<String, Object?> toJson() => {
        'id': id,
        if (created != null) 'created_ms': created!.millisecondsSinceEpoch,
      };

  /// Null for anything that is not an entry.
  static LateImportEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final ms = raw['created_ms'];
    return LateImportEntry(id,
        created: ms is int && ms.abs() <= 8640000000000000
            ? DateTime.fromMillisecondsSinceEpoch(ms)
            : null);
  }

  @override
  String toString() => 'LateImportEntry($id)';
}

/// Newest first; an unknown creation date counts as the newest, so a cap
/// never lets it go before the dated ones.
int _newestFirst(LateImportEntry a, LateImportEntry b) {
  final ca = a.created, cb = b.created;
  if (ca == null) return cb == null ? 0 : -1;
  if (cb == null) return 1;
  return cb.compareTo(ca);
}

/// The stored cursor ([photoChangeCursorDocument]).
class LateImportCursorState {
  const LateImportCursorState({
    required this.token,
    required this.deviceTag,
    this.carry = const [],
    this.rescanBefore,
    this.rescanAt,
    required this.at,
  });

  /// Where the next read of the history starts.
  final String token;

  /// The phone [token] belongs to (8 hex, see [PhotoChangeToken]).
  final String deviceTag;

  /// Photos still owed a verdict, newest first.
  final List<LateImportEntry> carry;

  /// A rescan by date is owed for the photos created at or before this
  /// (it moves down as the rescan goes); null: none.
  final DateTime? rescanBefore;

  /// When that rescan was asked for: a scan of the whole lookback window
  /// that started later covers it (set whenever [rescanBefore] is).
  final DateTime? rescanAt;

  /// Last written.
  final DateTime at;

  LateImportCursorState withCarry(List<LateImportEntry> carry, DateTime at) =>
      LateImportCursorState(
          token: token,
          deviceTag: deviceTag,
          carry: carry,
          rescanBefore: rescanBefore,
          rescanAt: rescanAt,
          at: at);

  LateImportCursorState withRescan(
          {required DateTime? before,
          required DateTime? requested,
          List<LateImportEntry>? carry,
          required DateTime at}) =>
      LateImportCursorState(
          token: token,
          deviceTag: deviceTag,
          carry: carry ?? this.carry,
          rescanBefore: before,
          rescanAt: before == null ? null : requested,
          at: at);

  Map<String, Object?> toJson() => {
        'token': token,
        'device_tag': deviceTag,
        'carry': [for (final e in carry) e.toJson()],
        if (rescanBefore != null)
          'rescan_before': rescanBefore!.toUtc().toIso8601String(),
        if (rescanBefore != null && rescanAt != null)
          'rescan_at': rescanAt!.toUtc().toIso8601String(),
        'at': at.toUtc().toIso8601String(),
      };

  /// Null when [doc] holds no usable cursor (no token, no device tag):
  /// the caller starts over. Bad carry entries are dropped one by one.
  static LateImportCursorState? fromJson(Map<String, Object?> doc) {
    final token = doc['token'];
    final tag = doc['device_tag'];
    if (token is! String || token.isEmpty) return null;
    if (tag is! String || !_deviceTagShape.hasMatch(tag)) return null;
    DateTime? stamp(Object? v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    final carry = <LateImportEntry>[];
    final ids = <String>{};
    final raw = doc['carry'];
    if (raw is List) {
      for (final r in raw) {
        final e = LateImportEntry.fromJson(r);
        if (e != null && ids.add(e.id)) carry.add(e);
      }
    }
    carry.sort(_newestFirst);
    final at = stamp(doc['at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final before = stamp(doc['rescan_before']);
    return LateImportCursorState(
        token: token,
        deviceTag: tag,
        carry: carry.length > lateImportCarryLimit
            ? carry.sublist(0, lateImportCarryLimit)
            : carry,
        rescanBefore: before,
        // Owed since at least the last write when the request time is lost.
        rescanAt: before == null ? null : (stamp(doc['rescan_at']) ?? at),
        at: at);
  }
}

/// What a pass needs from the watcher. Every hook may fail; none stops
/// the pass.
class LateImportHooks {
  const LateImportHooks({
    required this.settled,
    required this.logged,
    required this.resolve,
    required this.offer,
    required this.listWindow,
    this.shouldContinue,
    this.retryLater,
  });

  /// Handled to a verdict in this session already (not still in flight).
  final bool Function(String id) settled;

  /// Tried in this session already and released for a retry (a transient
  /// failure, a photo still being analyzed elsewhere): it stays in the
  /// carry but is not offered again until a later session. The scans
  /// retry such a photo themselves; offering it again right away would
  /// double the attempt — and in the background run count one undecodable
  /// photo's deferral twice (deferred_assets.dart). Null: none.
  final bool Function(String id)? retryLater;

  /// Those among the IDs a meal already names (MealsDao.loggedAssetIds).
  /// A throw counts as none: the photo is read, and the ledger knows it.
  final Future<Set<String>> Function(List<String> ids) logged;

  /// The library's answer for each ID (PhotoLibrary.imagesByIds): the
  /// asset, null when it is gone or hidden, no entry when it could not
  /// tell.
  final Future<Map<String, LibraryAsset?>> Function(List<String> ids) resolve;

  /// Hands the assets to the pipeline, reporting each that reached a
  /// verdict through [onSettled] (delivered: read and processed, rather
  /// than passed over or already handled).
  final Future<void> Function(
      List<LibraryAsset> assets,
      Future<void> Function(String id, {required bool delivered})
          onSettled) offer;

  /// The lookback window's images, no bytes read: the rescan's source.
  final Future<List<LibraryAsset>> Function(DateTime cutoff) listWindow;

  /// The caller's time budget, asked once before a rescan batch (the
  /// offers ask it per photo themselves).
  final bool Function()? shouldContinue;
}

/// What one pass did, for the diagnostics row.
class LateImportReport {
  const LateImportReport(this.status, {this.caught = 0, this.rescanning = false});

  /// The history's [PhotoChangeStatus] name, or [lateImportReset] when the
  /// cursor started over.
  final String status;

  /// Photos read and processed through the pass.
  final int caught;

  /// A rescan by date is still owed.
  final bool rescanning;

  @override
  String toString() => 'LateImportReport($status, $caught caught'
      '${rescanning ? ', rescanning' : ''})';
}

/// [LateImportReport.status] of a pass that started the cursor over.
const String lateImportReset = 'reset';

class LateImportCursor {
  LateImportCursor(
      {required this.source,
      required this.store,
      DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final PhotoChangeSource source;
  final LocalNoBackupStore store;
  final DateTime Function() _clock;

  /// The stored cursor; null when there is none worth using.
  Future<LateImportCursorState?> read() async => LateImportCursorState.fromJson(
      await store.read(photoChangeCursorDocument,
          version: photoChangeCursorVersion));

  Future<bool> _write(LateImportCursorState state) => store.write(
      photoChangeCursorDocument, state.toJson(),
      version: photoChangeCursorVersion);

  /// One pass (see above). [cutoff] is the lookback window's start.
  /// [rescan]: run a batch of an owed rescan (false: only note it).
  /// [windowCoveredFrom]: when the latest scan of the whole window that
  /// read every photo in it started; it settles a rescan asked before it.
  /// Never throws.
  Future<LateImportReport> pass({
    required DateTime cutoff,
    required LateImportHooks hooks,
    bool rescan = true,
    DateTime? windowCoveredFrom,
  }) async {
    try {
      final (status, offer) = await _begin(cutoff, hooks);
      if (offer == null) return LateImportReport(status);
      var caught = 0;
      if (offer.isNotEmpty) caught += await _offerCarry(offer, cutoff, hooks);
      if (windowCoveredFrom != null) {
        await _clearRescanCoveredBy(windowCoveredFrom);
      }
      var rescanning = (await read())?.rescanBefore != null;
      if (rescanning && rescan) {
        final r = await _rescanBatch(cutoff, hooks);
        caught += r.caught;
        rescanning = r.pending;
      }
      return LateImportReport(status, caught: caught, rescanning: rescanning);
    } catch (_) {
      return LateImportReport(PhotoChangeStatus.error.name);
    }
  }

  /// Phases 1–3. The carry to offer, or null when the pass stops here
  /// (no access, no history, or the cursor just started over).
  Future<(String, List<LateImportEntry>?)> _begin(
      DateTime cutoff, LateImportHooks hooks) async {
    final now = _clock();
    final state = await read();
    if (state == null) return (await _startOver(now), null);
    final reply = await source.insertedImagesSince(state.token,
        limit: lateImportFetchLimit);
    final tag = reply.deviceTag;
    if (tag != null && tag != state.deviceTag) {
      // Another phone's (or another install's) token: its history says
      // nothing about this library.
      return (await _startOver(now), null);
    }
    switch (reply.status) {
      case PhotoChangeStatus.unsupported:
      case PhotoChangeStatus.denied:
        return (reply.status.name, null);
      case PhotoChangeStatus.ok:
      case PhotoChangeStatus.fresh:
      case PhotoChangeStatus.expired:
      case PhotoChangeStatus.unavailable:
      case PhotoChangeStatus.error:
        break;
    }
    final inserted = reply.status == PhotoChangeStatus.ok
        ? reply.ids
        : const <InsertedImage>[];
    final byId = <String, LateImportEntry>{
      for (final e in state.carry) e.id: e,
    };
    for (final image in inserted) {
      byId.putIfAbsent(
          image.id, () => LateImportEntry(image.id, created: image.created));
    }
    final kept = [
      for (final e in byId.values)
        if ((e.created == null || !e.created!.isBefore(cutoff)) &&
            !hooks.settled(e.id))
          e,
    ];
    final logged = await _logged(hooks, [for (final e in kept) e.id]);
    var carry = [
      for (final e in kept)
        if (!logged.contains(e.id)) e,
    ]..sort(_newestFirst);
    var rescanWanted = reply.status == PhotoChangeStatus.expired ||
        reply.status == PhotoChangeStatus.unavailable;
    if (carry.length > lateImportCarryLimit) {
      carry = carry.sublist(0, lateImportCarryLimit);
      rescanWanted = true;
    }
    if (reply.dropped > 0 && _droppedMayBeInWindow(inserted, cutoff)) {
      rescanWanted = true;
    }
    // error keeps the token it has; every other status hands a new one.
    final token = reply.status == PhotoChangeStatus.error
        ? state.token
        : (reply.token ?? state.token);
    final next = LateImportCursorState(
        token: token,
        deviceTag: state.deviceTag,
        carry: carry,
        // A new request starts over from now: the photos it owes may have
        // any creation date.
        rescanBefore: rescanWanted ? now : state.rescanBefore,
        rescanAt: rescanWanted ? now : state.rescanAt,
        at: now);
    // The live watcher passes on every library change, and most find
    // nothing new: no write then (nor a chance to overwrite what the other
    // engine just wrote).
    if (!_sameCursor(state, next)) await _write(next);
    final waiting = hooks.retryLater;
    final offer = [
      for (final e in carry)
        if (waiting == null || !waiting(e.id)) e,
    ];
    return (
      reply.status.name,
      offer.length > lateImportPassLimit
          ? offer.sublist(0, lateImportPassLimit)
          : offer,
    );
  }

  /// Whether [a] and [b] hold the same cursor, whenever they were written.
  static bool _sameCursor(LateImportCursorState a, LateImportCursorState b) {
    String body(LateImportCursorState s) =>
        jsonEncode(s.toJson()..remove('at'));
    return body(a) == body(b);
  }

  /// The images a call's limit left out are older than every one it
  /// returned: they can be inside the window only if the oldest returned
  /// one is (or its date is unknown).
  static bool _droppedMayBeInWindow(
      List<InsertedImage> returned, DateTime cutoff) {
    if (returned.isEmpty) return true;
    DateTime? oldest;
    for (final image in returned) {
      final created = image.created;
      if (created == null) return true;
      if (oldest == null || created.isBefore(oldest)) oldest = created;
    }
    return !oldest!.isBefore(cutoff);
  }

  /// No usable cursor: the library's current token, an empty carry, no
  /// rescan. Nothing is offered — there is no history to read yet.
  Future<String> _startOver(DateTime now) async {
    final current = await source.currentToken();
    if (current.status != PhotoChangeStatus.ok) return current.status.name;
    await _write(LateImportCursorState(
        token: current.token!, deviceTag: current.deviceTag!, at: now));
    return lateImportReset;
  }

  static Future<Set<String>> _logged(
      LateImportHooks hooks, List<String> ids) async {
    if (ids.isEmpty) return const {};
    try {
      return await hooks.logged(ids);
    } catch (_) {
      return const {};
    }
  }

  /// Phase 4 for carried entries: looks them up, lets go of the ones that
  /// are gone, hidden or older than the window, offers the rest.
  Future<int> _offerCarry(List<LateImportEntry> entries, DateTime cutoff,
      LateImportHooks hooks) async {
    final Map<String, LibraryAsset?> found;
    try {
      found = await hooks.resolve([for (final e in entries) e.id]);
    } catch (_) {
      return 0; // could not tell: everything stays for the next pass
    }
    final gone = <String>[];
    final live = <LibraryAsset>[];
    for (final e in entries) {
      if (!found.containsKey(e.id)) continue; // unknown: keep it
      final asset = found[e.id];
      if (asset == null || asset.createDateTime.isBefore(cutoff)) {
        gone.add(e.id);
      } else {
        live.add(asset);
      }
    }
    if (gone.isNotEmpty) await settle(gone);
    return _offer(live, hooks);
  }

  Future<int> _offer(List<LibraryAsset> all, LateImportHooks hooks) async {
    final waiting = hooks.retryLater;
    final assets = [
      for (final a in all)
        if (waiting == null || !waiting(a.id)) a,
    ];
    if (assets.isEmpty) return 0;
    var caught = 0;
    await hooks.offer(assets, (id, {required bool delivered}) async {
      if (delivered) caught++;
      await settle([id]);
    });
    return caught;
  }

  /// Forgets [ids]: they reached a verdict, or are gone. Never throws.
  Future<void> settle(Iterable<String> ids) async {
    final drop = ids.toSet();
    if (drop.isEmpty) return;
    try {
      final state = await read();
      if (state == null) return;
      final kept = [
        for (final e in state.carry)
          if (!drop.contains(e.id)) e,
      ];
      if (kept.length == state.carry.length) return;
      await _write(state.withCarry(kept, _clock()));
    } catch (_) {}
  }

  Future<void> _clearRescanCoveredBy(DateTime coveredFrom) async {
    final state = await read();
    final requested = state?.rescanAt;
    if (state == null || requested == null || requested.isAfter(coveredFrom)) {
      return;
    }
    await _write(
        state.withRescan(before: null, requested: null, at: _clock()));
  }

  /// One batch of an owed rescan: the newest photos of the window taken
  /// at or before the bound that no meal names and this session has not
  /// handled. They join the carry, and the bound moves past them (or the
  /// rescan ends), BEFORE they are offered. Room in the carry first: a
  /// batch never pushes carried photos out.
  Future<({int caught, bool pending})> _rescanBatch(
      DateTime cutoff, LateImportHooks hooks) async {
    final state = await read();
    final before = state?.rescanBefore;
    if (state == null || before == null) return (caught: 0, pending: false);
    final room = lateImportCarryLimit - state.carry.length;
    final size = room < lateImportPassLimit ? room : lateImportPassLimit;
    if (size <= 0) return (caught: 0, pending: true);
    final ask = hooks.shouldContinue;
    if (ask != null && !ask()) return (caught: 0, pending: true);
    final List<LibraryAsset> window;
    try {
      window = await hooks.listWindow(cutoff);
    } catch (_) {
      return (caught: 0, pending: true);
    }
    final carried = {for (final e in state.carry) e.id};
    final candidates = [
      for (final a in window)
        if (!a.createDateTime.isAfter(before) &&
            !a.createDateTime.isBefore(cutoff) &&
            !carried.contains(a.id) &&
            !hooks.settled(a.id))
          a,
    ];
    final logged = await _logged(hooks, [for (final a in candidates) a.id]);
    candidates
      ..removeWhere((a) => logged.contains(a.id))
      ..sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    final batch =
        candidates.length > size ? candidates.sublist(0, size) : candidates;
    final finished = candidates.length <= size;
    // Re-read: the listing took a while, and the other engine may have
    // written meanwhile.
    final latest = await read();
    if (latest == null || latest.rescanBefore == null) {
      return (caught: 0, pending: false); // started over, or settled
    }
    final inCarry = {for (final e in latest.carry) e.id};
    final carry = [
      ...latest.carry,
      for (final a in batch)
        if (!inCarry.contains(a.id))
          LateImportEntry(a.id, created: a.createDateTime),
    ]..sort(_newestFirst);
    // Inclusive next time: photos sharing the batch's oldest instant are
    // looked at again rather than skipped. Unless the whole batch sits AT
    // the bound: a later session, which has handled none of them, would
    // list that same batch again, run after run, and never get past it.
    // Then the bound steps past the instant, and any more photos sharing
    // it are left to the app's catch-up over the whole window.
    var next = finished ? null : batch.last.createDateTime;
    if (next != null && !next.isBefore(before)) {
      next = before.subtract(const Duration(milliseconds: 1));
    }
    await _write(latest.withRescan(
        before: next,
        requested: latest.rescanAt,
        carry: carry.length > lateImportCarryLimit
            ? carry.sublist(0, lateImportCarryLimit)
            : carry,
        at: _clock()));
    return (caught: await _offer(batch, hooks), pending: !finished);
  }
}

// ---------------------------------------------------------------------------
// The diagnostics record: shared_preferences, both engines.

/// {caught7d: [ISO instants], last_at: ISO, last_status: String}.
const String lateImportStatsPrefsKey = 'photo.late_import_stats.v1';

/// How far back the caught count reaches.
const Duration lateImportStatsWindow = Duration(days: 7);

/// Caught instants kept at most.
const int lateImportStatsMaxCaught = 500;

/// [LateImportStats.lastStatus] while a rescan by date is owed.
const String lateImportRescanning = 'rescanning';

class LateImportStats {
  const LateImportStats({this.caught = const [], this.lastAt, this.lastStatus});

  /// When photos were caught, oldest first.
  final List<DateTime> caught;

  /// The last pass.
  final DateTime? lastAt;

  /// Its status ([LateImportReport.status], or [lateImportRescanning]).
  final String? lastStatus;

  int caughtSince(DateTime from) =>
      caught.where((t) => !t.isBefore(from)).length;
}

/// Null when nothing (readable) is stored.
LateImportStats? decodeLateImportStats(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final map = jsonDecode(raw);
    if (map is! Map) return null;
    final caught = <DateTime>[
      if (map['caught7d'] case final List list)
        for (final v in list)
          if (v is String)
            if (DateTime.tryParse(v) case final t?) t.toLocal(),
    ]..sort();
    final lastAt = map['last_at'];
    final lastStatus = map['last_status'];
    return LateImportStats(
        caught: caught,
        lastAt: lastAt is String ? DateTime.tryParse(lastAt)?.toLocal() : null,
        lastStatus: lastStatus is String ? lastStatus : null);
  } catch (_) {
    return null;
  }
}

/// Adds one pass to the record. Never throws.
Future<void> recordLateImportPass(LateImportReport report,
    {Future<SharedPreferences> Function()? prefs,
    DateTime Function()? clock}) async {
  try {
    final p = await (prefs ?? SharedPreferences.getInstance)();
    await p.reload(); // the other engine writes it too
    final now = (clock ?? DateTime.now)();
    final from = now.subtract(lateImportStatsWindow);
    final before = decodeLateImportStats(p.getString(lateImportStatsPrefsKey));
    var caught = [
      for (final t in before?.caught ?? const <DateTime>[])
        if (!t.isBefore(from) && !t.isAfter(now.add(ttlFutureSlack))) t,
      for (var i = 0; i < report.caught; i++) now,
    ];
    if (caught.length > lateImportStatsMaxCaught) {
      caught = caught.sublist(caught.length - lateImportStatsMaxCaught);
    }
    await p.setString(
        lateImportStatsPrefsKey,
        jsonEncode({
          'caught7d': [for (final t in caught) t.toUtc().toIso8601String()],
          'last_at': now.toUtc().toIso8601String(),
          'last_status':
              report.rescanning ? lateImportRescanning : report.status,
        }));
  } catch (_) {}
}

/// The record, read FRESH (the background engine writes it); null when
/// there is none or it cannot be read.
Future<LateImportStats?> readLateImportStats(
    {Future<SharedPreferences> Function()? prefs}) async {
  try {
    final p = await (prefs ?? SharedPreferences.getInstance)();
    await p.reload();
    return decodeLateImportStats(p.getString(lateImportStatsPrefsKey));
  } catch (_) {
    return null;
  }
}
