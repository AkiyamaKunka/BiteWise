/// photo_manager seam for the photo-intake module (spec §6.1).
///
/// Everything the watcher / picker needs from the device photo library sits
/// behind [PhotoLibrary] so tests can fake it — `flutter test` has no
/// platform channels. [PhotoManagerLibrary] is the only production
/// implementation.
library;

import 'dart:collection' show ListBase;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
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
  /// window). Order unspecified — callers sort for emission. At most
  /// [limit] are listed; [listedCount] of the result reaching [limit]
  /// means older ones may have gone unseen.
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

/// What [PhotoLibrary.imagesCreatedAfter] kept of what the library listed
/// (Android leaves some out, see [PhotoManagerLibrary.imagesCreatedAfter]),
/// and how many the library listed: the query's cap applies to those, so a
/// listing filled with photos left out (a phone transfer of old ones) is
/// still a capped one.
class LibraryListing extends ListBase<LibraryAsset> {
  LibraryListing(this._kept, {required this.listed});

  final List<LibraryAsset> _kept;

  /// How many images the library listed, before any was left out.
  final int listed;

  @override
  int get length => _kept.length;

  @override
  set length(int length) => _kept.length = length;

  @override
  LibraryAsset operator [](int index) => _kept[index];

  @override
  void operator []=(int index, LibraryAsset value) => _kept[index] = value;
}

/// How many images the library listed for [assets] (review 171, C4): its
/// [LibraryListing.listed], else its length. A scan compares this, not the
/// photos it kept, with its cap to tell whether the listing was truncated.
int listedCount(List<LibraryAsset> assets) =>
    assets is LibraryListing ? assets.listed : assets.length;

/// Where the photo library says an asset was taken (design R4, restaurant
/// assist): PHAsset.location on iOS, the position the Photos app shows. A
/// location the user changed there is the one read, and one removed there
/// ('No Location') reads as none. Read from the library's record of the
/// asset, never from its bytes: no original, file or thumbnail is opened.
/// [PhotoLocationReader] (photo_location.dart) is the only caller; it
/// checks the numbers and catches anything thrown.
abstract class AssetLocationSource {
  /// [assetId]'s coordinates, or null when it has none, is gone or is not
  /// an image.
  Future<({double latitude, double longitude})?> assetLatLng(String assetId);
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

/// What [reselectPhotoAccess] came to.
enum PhotoAccessFix {
  /// Full access now.
  full,

  /// Partial access, still or newly (a selection kept, or chosen from a
  /// denial), or a partial grant the user withdrew in the dialog: their
  /// choice, so nothing more is opened.
  answered,

  /// The dialog could not help: no access before and none after — Android
  /// no longer asks (a permanent denial), the phone is below Android 14
  /// (where presentLimited does nothing), or the platform would not say.
  /// The caller opens system settings instead, as before.
  openSettings,
}

/// Test seam for [reselectPhotoAccess].
@visibleForTesting
Future<PhotoAccessFix> Function()? debugReselectPhotoAccess;

/// Android 14+: with partial photo access ('Allow limited access'), shows
/// Android's own dialog again — reselect photos, or Allow all — through
/// photo_manager's presentLimited, which asks for READ_MEDIA_IMAGES and
/// READ_MEDIA_VISUAL_USER_SELECTED (photo_manager 3.10.0,
/// PermissionDelegate34). Settings' Fix used to open App info, where 'Allow
/// all' is three screens down (Play push, UX screenshots 18, 19, 21). App
/// info stays the remedy only when the dialog could not help
/// ([PhotoAccessFix.openSettings]): below Android 14, where presentLimited
/// does nothing, and after a permanent denial, where Android shows no
/// dialog. A top-level seam, not a [PhotoLibrary] member: the interface
/// has a dozen test fakes. Android only; never throws.
Future<PhotoAccessFix> reselectPhotoAccess() async {
  final override = debugReselectPhotoAccess;
  if (override != null) return override();
  try {
    Future<PermissionState> state() => PhotoManager.getPermissionState(
        requestOption: PhotoManagerLibrary._photosOnly);
    final before = await state();
    if (before == PermissionState.authorized) return PhotoAccessFix.full;
    await PhotoManager.presentLimited(type: RequestType.image);
    final after = await state();
    if (after == PermissionState.authorized) return PhotoAccessFix.full;
    if (after.hasAccess || before == PermissionState.limited) {
      return PhotoAccessFix.answered;
    }
    return PhotoAccessFix.openSettings;
  } catch (_) {
    return PhotoAccessFix.openSettings;
  }
}

class PhotoManagerLibrary implements PhotoLibrary, AssetLocationSource {
  PhotoManagerLibrary(
      {this._windowStart, @visibleForTesting bool? isAndroid})
      : _isAndroid = isAndroid ?? Platform.isAndroid;

  final bool _isAndroid;

  /// Android: where the lookback window starts now (createPhotoIntake reads
  /// it from the user's setting). A scan from a later cutoff still keeps
  /// the photos taken since then ([imagesCreatedAfter]). Null: a scan keeps
  /// only those taken at/after its own cutoff.
  final DateTime Function()? _windowStart;

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

  /// iOS only: there, photo_manager answers from the PHAsset it fetches
  /// fresh by identifier (never its cache), with no extra permission.
  /// Android: null, always, without asking. A photo's location there comes
  /// from the file's EXIF and needs ACCESS_MEDIA_LOCATION, which v1 never
  /// declares or requests.
  @override
  Future<({double latitude, double longitude})?> assetLatLng(
      String assetId) async {
    if (!Platform.isIOS || assetId.isEmpty) return null;
    final entity = await AssetEntity.fromId(assetId);
    if (entity == null || entity.type != AssetType.image) return null;
    final at = await entity.latlngAsync();
    if (at == null) return null;
    return (latitude: at.latitude, longitude: at.longitude);
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

  /// Android: photo_manager filters this window on MediaStore DATE_ADDED
  /// (when the file joined the library) but reports createDateTime from
  /// DATE_TAKEN (review 171, C4). A photo copied onto the phone (a phone
  /// transfer, a USB copy, a saved original) joins the library now with its
  /// old DATE_TAKEN, and the automatic scans sent it to the AI as a new
  /// photo, logged as eaten today once older than 45 days. Only the photos
  /// taken at/after [cutoff], or at/after the lookback window's start
  /// ([_windowStart]) when that is earlier, are kept; one with no date
  /// taken reports when it joined, and stays. A photo imported late (the
  /// Meta AI app copying glasses photos in hours after they were taken,
  /// AirDrop, a WeChat original), taken before a scan's cutoff and added
  /// after it, is thus still found by the next scan (the live watcher's, or
  /// the background run's from its watermark) while it was taken inside
  /// the window: the rule iOS's late-import pass (photo_changes.dart)
  /// applies to its change history. Both dates are whole seconds
  /// there. [limit] caps what the query lists, before any is left out; the
  /// [LibraryListing] says how many it listed, so a listing filled with old
  /// copies still reads as truncated.
  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
      {int limit = 500}) async {
    final filter = FilterOptionGroup(
      createTimeCond: DateTimeCond(
        min: cutoff,
        // Upper bound mirrors the §6.3 +1h future-skew allowance.
        max: DateTime.now().add(const Duration(hours: 1)),
      ),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
    );
    final listed = await _query(filter, limit);
    if (!_isAndroid) return listed;
    var bound = cutoff;
    try {
      final start = _windowStart?.call();
      if (start != null && start.isBefore(bound)) bound = start;
    } catch (_) {
      // Unreadable: the scan's own cutoff, as with no window start.
    }
    final since = DateTime.fromMillisecondsSinceEpoch(
        bound.millisecondsSinceEpoch ~/ 1000 * 1000);
    return LibraryListing([
      for (final asset in listed)
        if (!asset.createDateTime.isBefore(since)) asset,
    ], listed: listed.length);
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
