/// Android's system Photo Picker for Log › From recent photos and for
/// Leftovers (Google Play's Photo and Video Permissions policy, 2026-11).
///
/// Play asks apps that only need a photo now and then to let the user
/// choose it in the system picker instead of asking for the whole library
/// (READ_MEDIA_IMAGES), and the Play build ships without that permission
/// at all. The picker needs no permission: it hands the app the photos the
/// user chose, and nothing else.
///
/// The native half is MainActivity.kt's `pickImages` on the
/// `dev.calorietracker/files` channel. It copies each chosen photo into
/// the app's cache, `<cacheDir>/picked_photos/<uuid>/<name>`, and answers
/// `{status: 'ok' | 'cancelled' | 'busy' | 'unavailable',
///   items: [{path, name, dateTakenMs?}], tooBig, failed}`.
/// This side reads each copy, deletes it and its folder, and builds the
/// same deliberate [IntakePhoto] the grid and the share sheet build, so
/// the photo meets the same AI consent, pipeline and md5 identity: a
/// photo logged here is "already logged" when Watch Camera Roll later
/// reads the same bytes from the library.
///
/// iOS keeps its grid ([platformSystemPhotoPicker] is null there).
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:photo_manager/photo_manager.dart';

import '../../core/contracts.dart';
import '../backup/file_pick_channel.dart' show filesChannelName;
import 'filename_dates.dart';
import 'glasses.dart' show captureMetaFor;
import 'photo_library.dart' show maxPhotoBytes;
import 'share_intake.dart' show fileBaseName, isWithinFolder;

/// The method MainActivity.kt answers on [filesChannelName].
const String pickImagesMethod = 'pickImages';

/// The folder in the app's cache that MainActivity copies picked photos
/// into, one folder per photo. Only copies inside it are read or deleted.
const String androidPickedPhotoFolderName = 'picked_photos';

/// [androidPickedPhotoFolderName] in the cache directory (path_provider's
/// temporary directory is Context.getCacheDir on Android).
Future<String> androidPickedPhotoFolder() async =>
    '${(await getTemporaryDirectory()).path}/$androidPickedPhotoFolderName';

/// How a pick ended.
enum SystemPickStatus {
  /// The user chose photos; [SystemPick.photos] holds those that could be
  /// read (none when every one was too big or unreadable).
  ok,

  /// The user closed the picker without choosing.
  cancelled,

  /// Another pick (this one or Import's file picker) is still open.
  busy,

  /// The picker could not open on this phone, or failed.
  unavailable,

  /// This build has no native picker (MissingPluginException): the caller
  /// keeps the library grid as it was before the picker.
  missing,
}

/// What [SystemPhotoPicker.pick] gave.
class SystemPick {
  const SystemPick(this.status,
      {this.photos = const [], this.tooBig = 0, this.failed = 0});

  final SystemPickStatus status;
  final List<IntakePhoto> photos;

  /// Chosen photos over [maxPhotoBytes], refused natively or here.
  final int tooBig;

  /// Chosen photos that could not be copied or read.
  final int failed;
}

/// Android's system Photo Picker. Injectable: the screens take it as an
/// optional constructor parameter ([platformSystemPhotoPicker] in
/// production), and tests fake it or mock its channel.
class SystemPhotoPicker {
  SystemPhotoPicker({
    this._channel = const MethodChannel(filesChannelName),
    Future<String> Function()? pickedFolder,
    Future<Uint8List?> Function(String path)? readBytes,
    Future<bool> Function()? broadAccess,
    DateTime Function()? clock,
  })  : _pickedFolder = pickedFolder ?? androidPickedPhotoFolder,
        _readBytes = readBytes ?? _readFile,
        _broadAccess = broadAccess ?? _androidBroadAccess,
        _clock = clock ?? DateTime.now;

  final MethodChannel _channel;
  final Future<String> Function() _pickedFolder;
  final Future<Uint8List?> Function(String path) _readBytes;
  final Future<bool> Function() _broadAccess;
  final DateTime Function() _clock;

  /// Whether the user granted access to ALL photos, asked without a
  /// prompt. Anything else is false: "selected photos", denied, a build
  /// that does not declare the permission (the Play build), or a platform
  /// that cannot say. PhotoLibrary.hasFullAccess answers true for
  /// "unknown"; here that would open the grid, whose listing asks for the
  /// permission — the prompt this picker exists to avoid.
  Future<bool> hasBroadAccess() async {
    try {
      return await _broadAccess();
    } catch (_) {
      return false;
    }
  }

  /// Opens the picker for up to [max] photos. Never throws. Every copy the
  /// native side reports is deleted before this returns, read or not.
  Future<SystemPick> pick({int max = 1}) async {
    final limit = max < 1 ? 1 : max;
    final Object? reply;
    try {
      reply = await _channel
          .invokeMethod<Object?>(pickImagesMethod, {'max': limit});
    } on MissingPluginException {
      return const SystemPick(SystemPickStatus.missing);
    } on PlatformException {
      return const SystemPick(SystemPickStatus.unavailable);
    }
    if (reply is! Map) return const SystemPick(SystemPickStatus.unavailable);
    final items = reply['items'];
    final listed = items is List ? items : const [];
    final status = switch (reply['status']) {
      'ok' => SystemPickStatus.ok,
      'cancelled' => SystemPickStatus.cancelled,
      'busy' => SystemPickStatus.busy,
      _ => SystemPickStatus.unavailable,
    };
    var tooBig = _count(reply['tooBig']);
    var failed = _count(reply['failed']);
    final photos = <IntakePhoto>[];
    String? folder;
    try {
      folder = await _pickedFolder();
    } catch (_) {
      folder = null; // cannot tell where the copies are: touch none
    }
    for (final item in listed) {
      final path = item is Map ? item['path'] : null;
      if (path is! String || folder == null || !isWithinFolder(path, folder)) {
        // Never read or delete a path outside the picker's folder.
        if (status == SystemPickStatus.ok) failed++;
        continue;
      }
      try {
        if (status != SystemPickStatus.ok || photos.length >= limit) continue;
        final read = await _read(path, item as Map);
        final photo = read.photo;
        if (photo != null) {
          photos.add(photo);
        } else if (read.tooBig) {
          tooBig++;
        } else {
          failed++;
        }
      } finally {
        await _discard(path, folder);
      }
    }
    return SystemPick(status, photos: photos, tooBig: tooBig, failed: failed);
  }

  Future<_Read> _read(String path, Map<Object?, Object?> item) async {
    final Uint8List? bytes;
    try {
      bytes = await _readBytes(path);
    } catch (_) {
      return const _Read();
    }
    if (bytes == null || bytes.isEmpty) return const _Read();
    // §8: the 25 MB cap every intake path enforces (MainActivity refuses
    // bigger copies already; this holds if it ever does not).
    if (bytes.length > maxPhotoBytes) return const _Read(tooBig: true);
    final rawName = item['name'];
    final named = rawName is String ? fileBaseName(rawName) : '';
    final name = named.isEmpty ? fileBaseName(path) : named;
    final ms = item['dateTakenMs'];
    final taken = ms is num && ms > 0
        ? DateTime.fromMillisecondsSinceEpoch(ms.toInt())
        : null;
    // The grid's rules (§6.3 dating from the file name, then the photo's
    // own date; design G2a capture), with the picker's DATE_TAKEN as the
    // asset date. deliberate=true: the user chose it (spec §2.3). No asset
    // id: a picker URI is not a library asset.
    return _Read(
        photo: IntakePhoto(bytes, '', name,
            capturedAt: deriveCapturedAt(
                fileName: name, assetCreateDate: taken, now: _clock()),
            deliberate: true,
            capture: captureMetaFor(bytes, name, createDate: taken)));
  }
}

class _Read {
  const _Read({this.photo, this.tooBig = false});
  final IntakePhoto? photo;
  final bool tooBig;
}

int _count(Object? n) => n is num && n > 0 ? n.toInt() : 0;

Future<Uint8List?> _readFile(String path) => File(path).readAsBytes();

/// Deletes the copy at [path] and then its own folder (the per-photo
/// folder MainActivity made), never [folder] itself. Best effort.
Future<void> _discard(String path, String folder) async {
  try {
    await File(path).delete();
  } catch (_) {}
  final parent = File(path).parent.path;
  if (!isWithinFolder(parent, folder)) return;
  try {
    await Directory(parent).delete(); // only when empty
  } catch (_) {}
}

/// Full access to the photo library, asked without a prompt.
Future<bool> _androidBroadAccess() async {
  final state = await PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(
          androidPermission:
              AndroidPermission(type: RequestType.image, mediaLocation: false)));
  return state == PermissionState.authorized;
}

/// Tests: the picker [platformSystemPhotoPicker] hands out, as on Android.
@visibleForTesting
SystemPhotoPicker? Function()? debugSystemPhotoPicker;

/// The system picker on Android; null on iOS, which keeps its grid.
SystemPhotoPicker? platformSystemPhotoPicker() {
  final override = debugSystemPhotoPicker;
  if (override != null) return override();
  return Platform.isAndroid ? SystemPhotoPicker() : null;
}
