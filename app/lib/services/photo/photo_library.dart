/// photo_manager seam for the photo-intake module (spec §6.1).
///
/// Everything the watcher / picker needs from the device photo library sits
/// behind [PhotoLibrary] so tests can fake it — `flutter test` has no
/// platform channels. [PhotoManagerLibrary] is the only production
/// implementation.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodCall;
import 'package:photo_manager/photo_manager.dart';

/// Spec §8: refuse photos larger than 25 MB before any decode.
const int maxPhotoBytes = 25 * 1024 * 1024;

/// One image asset. [originBytes] MUST return the ORIGINAL library bytes —
/// the md5 dedup identity is md5(original bytes), never a recompression
/// (spec §6.2).
abstract class LibraryAsset {
  String get id;
  DateTime get createDateTime;
  Future<String> fileName();
  Future<Uint8List?> originBytes();
}

abstract class PhotoLibrary {
  /// Request read access; limited/partial grants count as access.
  Future<bool> requestPermission();

  /// Small display thumbnail for a known asset id; null when the asset is
  /// gone, unreadable, or permission is missing. Used to lazily backfill
  /// meal thumbs for meals logged before thumbs existed, and for the
  /// coverage audit's missing-photo list.
  Future<Uint8List?> thumbnailByAssetId(String assetId, {int size = 160});

  /// ORIGINAL bytes for a known asset id (md5-identity grade, §6.2);
  /// null when gone/unreadable. Direct fetch — no window re-query.
  Future<Uint8List?> originBytesByAssetId(String assetId);

  /// True when the OS granted FULL library access; false for iOS limited /
  /// Android selected-photos mode, where scans see only a subset and no
  /// coverage promise can be made for the rest.
  Future<bool> hasFullAccess();

  /// Images whose createDate is at/after [cutoff] (spec §6.4 backfill
  /// window). Order unspecified — callers sort for emission.
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
      {int limit = 500});

  /// Most-recent images, newest first (in-app picker grid source).
  Future<List<LibraryAsset>> recentImages(int limit);

  /// The library's answer for each of [ids] (design G1b, the late-import
  /// pass): the image asset; null when the library says it is no longer
  /// there to read — deleted, hidden, or not an image; NO entry when the
  /// lookup itself failed, so the caller cannot tell and keeps the id for
  /// later. Never throws.
  Future<Map<String, LibraryAsset?>> imagesByIds(List<String> ids);

  /// Change-notify subscription while the app is alive (spec §6.1 watcher).
  Future<void> startChangeNotify(void Function() onChange);
  Future<void> stopChangeNotify();
}

class _PhotoManagerAsset implements LibraryAsset {
  _PhotoManagerAsset(this._entity);
  final AssetEntity _entity;

  @override
  String get id => _entity.id;

  @override
  DateTime get createDateTime => _entity.createDateTime;

  @override
  Future<String> fileName() => _entity.titleAsync;

  @override
  Future<Uint8List?> originBytes() => _entity.originBytes;
}

/// Whether the app may read the photo library at all (full or limited),
/// asked WITHOUT a prompt; null when the platform cannot say. The background
/// run's diagnostics use it to tell "no photo access" from "no new photos".
Future<bool?> photoLibraryAccess() async {
  try {
    final state = await PhotoManager.getPermissionState(
        requestOption: PhotoManagerLibrary._photosOnly);
    return state.hasAccess;
  } catch (_) {
    return null;
  }
}

class PhotoManagerLibrary implements PhotoLibrary {
  /// Ask Android for images only. The manifest declares READ_MEDIA_IMAGES
  /// (+ VISUAL_USER_SELECTED) and no video permission; photo_manager's
  /// default option asks for image|video, and its Android 14+ delegate folds
  /// the undeclared READ_MEDIA_VIDEO into "limited" — so every 全部允许 /
  /// "Allow all" grant read as partial access and 去修复 could fix nothing —
  /// while the Android 13 delegate answers "denied" on every grant.
  /// iosAccessLevel stays the default readWrite; iOS ignores the rest.
  static const _photosOnly = PermissionRequestOption(
    androidPermission:
        AndroidPermission(type: RequestType.image, mediaLocation: false),
  );

  void Function(MethodCall)? _changeCallback;

  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId, {int size = 160}) async {
    if (assetId.isEmpty) return null;
    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) return null;
      return await entity.thumbnailDataWithSize(ThumbnailSize.square(size));
    } catch (_) {
      return null; // deleted asset / revoked permission: display-degrade
    }
  }

  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) async {
    if (assetId.isEmpty) return null;
    try {
      final entity = await AssetEntity.fromId(assetId);
      return await entity?.originBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasFullAccess() async {
    try {
      final state =
          await PhotoManager.getPermissionState(requestOption: _photosOnly);
      return state == PermissionState.authorized;
    } catch (_) {
      // Unknown → assume full: the caveat line is advisory, and a false
      // "limited" would permanently deny the green summary.
      return true;
    }
  }

  @override
  Future<bool> requestPermission() async {
    // Spec §6 permission flow: iOS "limited" / Android "selected photos"
    // still exposes a user-granted subset, which is enough to watch.
    final state =
        await PhotoManager.requestPermissionExtend(requestOption: _photosOnly);
    return state.hasAccess;
  }


  Future<List<LibraryAsset>> _query(
      FilterOptionGroup filter, int limit) async {
    final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image, onlyAll: true, filterOption: filter);
    if (paths.isEmpty) return const [];
    final assets = await paths.first.getAssetListRange(start: 0, end: limit);
    return assets.map(_PhotoManagerAsset.new).toList();
  }

  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
      {int limit = 500}) {
    final filter = FilterOptionGroup(
      createTimeCond: DateTimeCond(
        min: cutoff,
        // Upper bound mirrors the §6.3 +1h future-skew allowance.
        max: DateTime.now().add(const Duration(hours: 1)),
      ),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
    );
    return _query(filter, limit);
  }

  @override
  Future<List<LibraryAsset>> recentImages(int limit) {
    final filter = FilterOptionGroup(
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
    );
    return _query(filter, limit);
  }

  /// One fetch per id (AssetEntity.fromId; at most a pass's worth of
  /// ids). photo_manager fetches by identifier with default fetch options,
  /// which leave hidden assets out, so a photo hidden since the history
  /// reported it (the native side drops hidden ones then) comes back null
  /// like a deleted one — unless photo_manager still has it cached, in
  /// which case it is read once more and the ledger has the last word.
  @override
  Future<Map<String, LibraryAsset?>> imagesByIds(List<String> ids) async {
    final found = <String, LibraryAsset?>{};
    for (final id in ids) {
      if (id.isEmpty) continue;
      try {
        final entity = await AssetEntity.fromId(id);
        found[id] = entity == null || entity.type != AssetType.image
            ? null
            : _PhotoManagerAsset(entity);
      } catch (_) {
        // A failed lookup says nothing about the photo: no entry.
      }
    }
    return found;
  }

  @override
  Future<void> startChangeNotify(void Function() onChange) async {
    _changeCallback ??= (MethodCall _) => onChange();
    PhotoManager.addChangeCallback(_changeCallback!);
    await PhotoManager.startChangeNotify();
  }

  @override
  Future<void> stopChangeNotify() async {
    final cb = _changeCallback;
    if (cb != null) {
      PhotoManager.removeChangeCallback(cb);
      _changeCallback = null;
    }
    await PhotoManager.stopChangeNotify();
  }
}
