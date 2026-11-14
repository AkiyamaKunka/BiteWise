/// Deliberate intake: share-sheet stream + in-app "recent photos" picker
/// source (spec §6, §2.3 caller policy).
///
/// Everything emitted here carries `deliberate=true`: a human re-sending a
/// photo may reclaim failed/skipped/deleted ledger rows (the "deliberate
/// re-send" rule, spec §2.3).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../core/contracts.dart';
import '../settings/app_settings.dart' show AppSettings;
import 'filename_dates.dart';
import 'glasses.dart' show captureMetaFor;
import 'photo_library.dart';

/// Spec §6.1: SUPPORTED_QUEUE_EXTENSIONS ∪ server-side .tiff, plus WebP
/// and GIF (2026-11): what Android browsers and chat apps share, and how
/// MainActivity names a nameless image stream (`IMG_<ts>.webp`, from its MIME
/// type); they were dropped without a word. Every decoder in the upload
/// chain reads both (the engine codec, iOS ImageIO, the `image` package),
/// and a GIF is sent as its first frame. Not AVIF: its decoding is
/// unverified. Content is ultimately validated by decodability downstream
/// (the analyzer's decode), not by extension — this set only filters
/// obvious non-photos out of the share sheet.
const Set<String> supportedPhotoExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.heic',
  '.heif',
  '.tiff',
  '.webp',
  '.gif',
};

bool hasSupportedPhotoExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return supportedPhotoExtensions.contains(name.substring(dot).toLowerCase());
}

String fileBaseName(String path) {
  final sep = path.lastIndexOf(RegExp(r'[/\\]'));
  return sep < 0 ? path : path.substring(sep + 1);
}

/// receive_sharing_intent seam so tests can fake the platform stream.
abstract class SharedMediaSource {
  /// Batches of shared image file paths while the app is alive.
  Stream<List<String>> imagePathBatches();

  /// The cold-start share that launched the app (consumed once).
  Future<List<String>> initialImagePaths();
}

class ReceiveSharingIntentSource implements SharedMediaSource {
  List<String> _imagePaths(List<SharedMediaFile> files) => files
      .where((f) => f.type == SharedMediaType.image)
      .map((f) => f.path)
      .toList();

  @override
  Stream<List<String>> imagePathBatches() =>
      ReceiveSharingIntent.instance.getMediaStream().map(_imagePaths);

  @override
  Future<List<String>> initialImagePaths() async {
    final files = await ReceiveSharingIntent.instance.getInitialMedia();
    // Consume the launch intent so a hot restart does not re-log the share.
    ReceiveSharingIntent.instance.reset();
    return _imagePaths(files);
  }
}

/// Android: the folder in the app's cache that MainActivity copies every
/// shared image into, one folder per image (MainActivity.kt SHARE_FOLDER;
/// review 171, C5). Share intake reads and deletes nothing outside it.
const String androidShareFolderName = 'shared_photos';

/// [androidShareFolderName] in the cache directory MainActivity copies into.
Future<String> androidSharedPhotoFolder() async =>
    '${(await getTemporaryDirectory()).path}/$androidShareFolderName';

/// Whether the absolute POSIX [path] lies inside [folder] once '.' and '..'
/// are resolved; a relative path never does.
bool isWithinFolder(String path, String folder) {
  List<String>? segments(String p) {
    if (!p.startsWith('/')) return null;
    final out = <String>[];
    for (final s in p.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (out.isEmpty) return null;
        out.removeLast();
      } else {
        out.add(s);
      }
    }
    return out;
  }

  final inner = segments(path);
  final outer = segments(folder);
  if (inner == null || outer == null || inner.length <= outer.length) {
    return false;
  }
  for (var i = 0; i < outer.length; i++) {
    if (inner[i] != outer[i]) return false;
  }
  return true;
}

/// [path] with '.' and '..' resolved, for comparing two spellings of one
/// file.
String _normalized(String path) {
  final out = <String>[];
  for (final s in path.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(s);
    }
  }
  return '/${out.join('/')}';
}

typedef FileBytesReader = Future<Uint8List?> Function(String path);
typedef SharedFileCleanup = Future<void> Function(String path);

Future<Uint8List?> _readFileBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null; // unreadable share target: skip, never crash intake
  }
}

/// The plugin COPIES every share into the app's container (iOS app-group /
/// Android app dir) and its API contract says the consumer deletes the copy
/// after use — nothing else ever purges them, so skipping this leaks the
/// full-size original of every shared photo forever (storage + privacy).
Future<void> _deleteSharedFile(String path) async {
  try {
    await File(path).delete();
  } catch (_) {
    // Best effort: a vanished/locked file must not break intake.
  }
}

/// Integration-contract factory: the integrator wires this next to
/// `createPhotoIntake` with the settings module's [AppSettings]. (Share
/// intake currently needs no settings knob — the parameter keeps the wiring
/// uniform and future-proof.)
ShareIntake createShareIntake(AppSettings settings) => ShareIntake(
    source: ReceiveSharingIntentSource(),
    library: PhotoManagerLibrary(),
    readBytes: _readFileBytes,
    sharedFolder: Platform.isAndroid ? androidSharedPhotoFolder : null);

class ShareIntake {
  ShareIntake(
      {required this._source,
      required this._library,
      required this._readBytes,
      SharedFileCleanup? cleanup,
      DateTime Function()? clock,
      // §8 CAPTURED_AT_MAX_AGE_DAYS: default 45, not user-editable.
      this._capturedAtMaxAgeDays = 45,
      this._sharedFolder})
      : _cleanup = cleanup ?? _deleteSharedFile,
        _clock = clock ?? DateTime.now;

  /// The folder a shared file must lie in to be read or deleted (Android:
  /// [androidSharedPhotoFolder]); null: any path (iOS, where the share
  /// extension writes the copies, and tests).
  final Future<String> Function()? _sharedFolder;

  /// Whether a copy may wait on disk for its turn: only where every copy
  /// has a path of its own (Android's share folder). See [photos].
  bool get _copiesWait => _sharedFolder != null;
  final SharedMediaSource _source;
  final PhotoLibrary _library;
  final FileBytesReader _readBytes;
  final SharedFileCleanup _cleanup;
  final DateTime Function() _clock;
  final int _capturedAtMaxAgeDays;

  /// Cold-start share first, then live shares for the app's lifetime.
  /// (Explicit controller, not async*: an async* generator parked on the
  /// live-share stream would defer subscription cancellation forever.)
  ///
  /// BACKPRESSURE (review 171, C2), Android: a copy is read only while the
  /// listener is not paused. The pipeline pauses the stream until each
  /// photo's turn ends (PhotoPipeline.bindStream), and the consent gate
  /// while it asks, so a 40-photo share holds one original in memory, plus
  /// at most one read ahead — not all 40 (about 160 MB) in the stream's
  /// buffer. The copies wait in the share folder meanwhile, each in a
  /// folder of its own (MainActivity). Batches are read one after another,
  /// in order.
  ///
  /// iOS reads each copy the moment it arrives, as before: the share
  /// extension writes `<appGroup>/<file name>` and replaces a file of the
  /// same name (FullSizeRender.jpg for every edited photo, TempImage.png
  /// for every in-memory image), so a copy left waiting was overwritten by
  /// the next share of that name — two shares, one meal (review
  /// 2026-11-13). iOS shares one image at a time: one original per share.
  Stream<IntakePhoto> photos() {
    late final StreamController<IntakePhoto> controller;
    StreamSubscription<List<String>>? liveSub;
    var cancelled = false;
    Completer<void>? resumed;
    var reading = Future<void>.value();

    void wake() {
      final r = resumed;
      resumed = null;
      r?.complete();
    }

    Future<void> emitPaths(List<String> paths) async {
      for (final path in paths) {
        while (_copiesWait && controller.isPaused && !cancelled) {
          await (resumed ??= Completer<void>()).future;
        }
        if (cancelled || controller.isClosed) {
          // Not read, but not left in the cache either.
          await _discard(path);
          continue;
        }
        final IntakePhoto? photo;
        try {
          photo = await _fromPath(path);
        } catch (_) {
          continue; // one bad copy (already deleted) never stops the rest
        }
        if (photo != null && !cancelled && !controller.isClosed) {
          controller.add(photo);
        }
      }
    }

    // One reader, batch after batch: a failure cannot break the chain, or
    // every later share would wait behind it for good.
    void enqueue(List<String> paths) => reading =
        reading.then((_) => emitPaths(paths)).catchError((Object _) {});

    controller = StreamController<IntakePhoto>(
      onListen: () async {
        final initial = await _source.initialImagePaths();
        if (cancelled) return;
        enqueue(initial);
        // Listened for at once, not after the launch share is read: the
        // plugin drops a share that arrives while nobody listens, and the
        // launch share may now wait on the pipeline for minutes.
        liveSub = _source.imagePathBatches().listen(enqueue,
            onError: controller.addError,
            onDone: () => reading = reading.then((_) => controller.close()));
        if (_copiesWait) {
          final left = await _leftOver(initial);
          if (!cancelled && left.isNotEmpty) enqueue(left);
        }
      },
      onResume: wake,
      onCancel: () async {
        cancelled = true;
        wake();
        await liveSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// How long a copy a killed app left unread is still logged at the next
  /// start (Android); older ones are deleted unread.
  static const strandedMaxAge = Duration(hours: 24);

  /// A copy younger than this may still be being written for a share
  /// whose own event delivers it: the start-up sweep leaves it alone.
  static const strandedMinAge = Duration(seconds: 10);

  /// The share folder's copies an earlier run never read (Android, review
  /// 2026-11-13): with the C2 backpressure they wait there for minutes,
  /// and an app killed mid-batch left them for good — full-size originals
  /// in the cache, never logged, nothing said (MainActivity removes only
  /// empty folders, and a recreated activity hands no share over again).
  /// Those shared within [strandedMaxAge] come back, oldest first, to go
  /// through the same consent gate and pipeline as any share: the user
  /// shared them to be logged, and a copy still on disk was never read
  /// (reading deletes it), so nothing is sent twice. Older ones are
  /// deleted here, unread: logged days late they would surprise, and
  /// could land on the wrong day. The launch share's own copies, and any
  /// younger than [strandedMinAge], are left out.
  Future<List<String>> _leftOver(List<String> launch) async {
    final String root;
    try {
      root = await _sharedFolder!();
    } catch (_) {
      return const [];
    }
    final skip = {for (final p in launch) _normalized(p)};
    final now = _clock();
    final keep = <(DateTime, String)>[];
    try {
      await for (final entry
          in Directory(root).list(recursive: true, followLinks: false)) {
        if (entry is! File || !isWithinFolder(entry.path, root)) continue;
        if (skip.contains(_normalized(entry.path))) continue;
        final DateTime modified;
        try {
          modified = await entry.lastModified();
        } catch (_) {
          continue;
        }
        final age = now.difference(modified);
        if (age < strandedMinAge) continue;
        if (age > strandedMaxAge) {
          await _cleanup(entry.path);
          continue;
        }
        keep.add((modified, entry.path));
      }
    } catch (_) {
      // No folder yet, or it cannot be listed: nothing left over.
    }
    keep.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final k in keep) k.$2];
  }

  /// Deletes [path] unread when it is a copy this intake may delete.
  Future<void> _discard(String path) async {
    if (await _isShareCopy(path)) await _cleanup(path);
  }

  /// Whether [path] is a copy this intake may read and delete.
  Future<bool> _isShareCopy(String path) async {
    final folder = _sharedFolder;
    if (folder == null) return true;
    try {
      return isWithinFolder(path, await folder());
    } catch (_) {
      return false; // cannot tell: leave it alone
    }
  }

  Future<IntakePhoto?> _fromPath(String path) async {
    // Android (review 171, C5): the plugin used to hand over a path of the
    // sender's making (its file name, climbing out of the cache with
    // '..'; or a share's text when it had no stream), which was read when
    // it looked like a photo and deleted either way: the meal database,
    // the settings. Only MainActivity's copies are touched now.
    if (!await _isShareCopy(path)) return null;
    try {
      final name = fileBaseName(path);
      if (!hasSupportedPhotoExtension(name)) return null; // §6.1
      final bytes = await _readBytes(path);
      if (bytes == null || bytes.isEmpty) return null;
      if (bytes.length > maxPhotoBytes) return null; // §8: 25 MB cap
      // A shared file has no library asset date; filename timestamp or bust
      // (§6.3 fallback = intake-time dating, expressed as capturedAt null).
      final capturedAt = deriveCapturedAt(
          fileName: name, now: _clock(), maxAgeDays: _capturedAtMaxAgeDays);
      // How it was taken, from its own bytes (design G2a): no asset, so no
      // creation date and no album.
      return IntakePhoto(bytes, '', name,
          capturedAt: capturedAt,
          deliberate: true,
          capture: captureMetaFor(bytes, name));
    } finally {
      // Always remove the plugin's container copy — accepted, rejected, or
      // unreadable, it has served its purpose once we've looked at it (the
      // bytes above are already in memory when accepted).
      await _cleanup(path);
    }
  }

  /// Recent library assets for the UI's own picker grid (the UI renders the
  /// grid; this module only supplies the data). deliberate=true — a picked
  /// photo is a user decision, reclaiming failed/skipped/deleted (§2.3).
  Future<List<IntakePhoto>> pickFromRecent(int limit) async {
    if (limit <= 0) return const [];
    if (!await _library.requestPermission()) return const [];
    final assets = await _library.recentImages(limit);
    final out = <IntakePhoto>[];
    for (final asset in assets.take(limit)) {
      final bytes = await asset.originBytes(); // ORIGINAL bytes (§6.2)
      if (bytes == null || bytes.isEmpty) continue;
      if (bytes.length > maxPhotoBytes) continue;
      final name = await asset.fileName();
      final capturedAt = deriveCapturedAt(
          fileName: name,
          assetCreateDate: asset.createDateTime,
          now: _clock(),
          maxAgeDays: _capturedAtMaxAgeDays);
      out.add(IntakePhoto(bytes, asset.id, name,
          capturedAt: capturedAt,
          deliberate: true,
          capture: captureMetaFor(bytes, name,
              createDate: asset.createDateTime)));
    }
    return out;
  }
}
