/// Camera-roll watcher: the native re-implementation of the Android photo
/// watcher (spec §6).
///
/// Emits [IntakePhoto]s with `deliberate=false` — automated intake NEVER
/// reclaims failed/skipped/deleted ledger rows (spec §2.3 caller policy);
/// the downstream pipeline enforces that via `reservePhotoHash`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/contracts.dart';
import '../local_store.dart';
import '../settings/app_settings.dart' show AppSettings;
import 'filename_dates.dart';
import 'glasses.dart';
import 'photo_changes.dart';
import 'photo_library.dart';

/// §8: SYNC_LOOKBACK_DAYS range 1–30.
int clampLookbackDays(int days) => days < 1 ? 1 : (days > 30 ? 30 : days);

/// Backfill query cap. The library query returns the NEWEST assets first,
/// so hitting the cap means the window's oldest photos were not seen.
const int backfillQueryLimit = 2000;

/// Thrown AFTER emitting a capped result set: everything returned still
/// processes, but callers tracking coverage (the background watermark) must
/// treat the window as not fully scanned.
class BackfillWindowTruncated implements Exception {
  const BackfillWindowTruncated();
  @override
  String toString() =>
      'BackfillWindowTruncated: >$backfillQueryLimit images in the window';
}

/// Backfill window math (spec §6.4): include photos whose create-date DAY
/// falls within the last [lookbackDays] days — i.e. the cutoff is local
/// midnight (lookbackDays − 1) days before today, so lookbackDays=2 means
/// today + yesterday exactly (upload_photo.py sync_photos semantics).
/// Calendar-component arithmetic, NOT Duration subtraction: a Duration is
/// 24 absolute hours, which lands an hour off local midnight across a DST
/// transition (the device may travel even though China skips DST).
DateTime lookbackCutoff(DateTime now, int lookbackDays) {
  final days = clampLookbackDays(lookbackDays);
  return DateTime(now.year, now.month, now.day - (days - 1));
}

/// Integration-contract factory: the integrator wires this with the
/// settings module's [AppSettings]. The lookback window is read through a
/// closure so later settings edits apply to the next scan without rewiring.
/// [onBackfillListed], [passOver], [loggedAssetIds]: see
/// [LibraryPhotoIntake]. On iOS the intake also reads the library's change
/// history for late imports (design G1b), its cursor in the backup-excluded
/// local store, and asks the same channel which photos sit in a Meta
/// glasses album (G2a); elsewhere [PhotoIntake.lateImportScan] does nothing
/// and no album is asked about.
PhotoIntake createPhotoIntake(AppSettings settings,
    {FutureOr<void> Function(int count)? onBackfillListed,
    bool Function(String assetId)? passOver,
    Future<Set<String>> Function(List<String> assetIds)? loggedAssetIds,
    @visibleForTesting bool? isIOS}) {
  final changes = platformPhotoChangeSource(isIOS: isIOS);
  return LibraryPhotoIntake(
      lookbackDays: () => settings.lookbackDays,
      library: PhotoManagerLibrary(),
      onBackfillListed: onBackfillListed,
      passOver: passOver,
      lateImports: changes == null
          ? null
          : LateImportCursor(
              source: changes, store: LocalNoBackupStore.platform()),
      loggedAssetIds: loggedAssetIds,
      onLateImportPass: changes == null ? null : recordLateImportPass,
      metaAlbumIds: changes == null
          ? null
          : (since) => metaAlbumAssetIds(changes, since: since));
}

/// The ids of the images created at or after [since] in the Meta glasses
/// albums ([MetaGlassesStrings.albumTitles]); empty when the channel could
/// not say. Never throws.
Future<Set<String>> metaAlbumAssetIds(PhotoChangeSource source,
    {required DateTime since}) async {
  try {
    final found = await source.albumAssetIds(MetaGlassesStrings.albumTitles,
        since: since, limit: albumAssetIdsMaxLimit);
    return found.status == PhotoChangeStatus.ok
        ? found.ids.toSet()
        : const <String>{};
  } catch (_) {
    return const <String>{};
  }
}

/// How long one scan waits for the album answer before it reads every
/// photo as outside the albums (the filename and EXIF still recognize a
/// glasses photo). The native lookup takes milliseconds; this only bounds a
/// stuck channel, which must not hold the scan.
const Duration metaAlbumLookupTimeout = Duration(seconds: 2);

/// What one [LibraryPhotoIntake._emit] call left undone, for a scan that
/// wants to know whether it read its whole window.
class _EmitTally {
  /// Left unread because the caller's budget said stop.
  int unread = 0;

  /// Read (or tried) and released for a retry.
  int released = 0;

  /// stop() (or a closed stream) ended the delivery.
  bool stopped = false;

  bool get complete => unread == 0 && released == 0 && !stopped;
}

class LibraryPhotoIntake implements PhotoIntake {
  LibraryPhotoIntake(
      {required this._lookbackDays,
      required this._library,
      DateTime Function()? clock,
      // §8 CAPTURED_AT_MAX_AGE_DAYS: default 45, not user-editable.
      this._capturedAtMaxAgeDays = 45,
      this.onBackfillListed,
      this.passOver,
      this.lateImports,
      this.loggedAssetIds,
      this.onLateImportPass,
      this.metaAlbumIds,
      @visibleForTesting this.metaAlbumTimeout = metaAlbumLookupTimeout})
      : _clock = clock ?? DateTime.now;

  /// The ids of the images created at or after a time that sit in a Meta
  /// glasses album (design G2a; iOS: [metaAlbumAssetIds]). Asked at most
  /// once per batch a scan delivers (a launch catch-up delivers two), when
  /// its first photo is read — never for one that reads nothing — and only
  /// to recognize glasses photos: a failure, a timeout or null (Android,
  /// tests) just means "in no album".
  final Future<Set<String>> Function(DateTime since)? metaAlbumIds;

  /// [metaAlbumLookupTimeout]; shorter in tests.
  final Duration metaAlbumTimeout;

  /// The late-import cursor (photo_changes.dart); null where there is no
  /// change history to read (Android, iOS tests): [lateImportScan] then
  /// does nothing.
  final LateImportCursor? lateImports;

  /// Those of the ids a meal already names (MealsDao.loggedAssetIds): the
  /// late-import pass skips them without reading a byte. Null: none known.
  final Future<Set<String>> Function(List<String> assetIds)? loggedAssetIds;

  /// Hears what each late-import pass did (the diagnostics record). A
  /// throwing hook changes nothing.
  final FutureOr<void> Function(LateImportReport report)? onLateImportPass;

  /// The background run's photos to count covered WITHOUT reading them:
  /// the ones it has deferred too often (deferred_assets.dart), so one file
  /// it cannot decode no longer holds its watermark. Nothing is marked
  /// seen; the app's own intake has none of these.
  final bool Function(String assetId)? passOver;

  /// Told how many photos each [backfillScan] listed, before any is read
  /// — the background run's diagnostics record (background_runs.dart).
  /// A throwing hook never stops the scan.
  final FutureOr<void> Function(int count)? onBackfillListed;

  final int Function() _lookbackDays;
  final PhotoLibrary _library;
  final DateTime Function() _clock;
  final int _capturedAtMaxAgeDays;
  final StreamController<IntakePhoto> _controller =
      StreamController<IntakePhoto>.broadcast();
  // Session-scoped emission dedup; cross-session idempotency belongs to the
  // md5 ledger (spec §6.2/§2.3), not this set.
  final Set<String> _seenAssetIds = <String>{};
  DateTime? _incrementalCutoff;
  bool _scanning = false;
  bool _rescanPending = false;
  bool _started = false;
  Future<bool> Function(IntakePhoto, DateTime?)? _sink;
  // Asset ids whose delivery is still awaiting the sink: a CONCURRENT scan
  // must not count them as covered — their release may still be coming.
  final Set<String> _inFlightIds = <String>{};
  // stop() bumps this; in-flight emission loops observe the change and
  // quiesce instead of auto-logging on after the user disabled the watcher.
  int _generation = 0;
  // Started once and stopped since: the user switched the watcher off, and
  // no late-import pass may offer a photo until it is switched back on.
  bool _everStarted = false;
  // When the latest scan that read the WHOLE lookback window — nothing
  // left unread or released — started. A rescan the late-import cursor
  // asked for before then is covered by it.
  DateTime? _windowCoveredFrom;
  // Read this session and released for a retry, not settled since: the
  // late-import pass leaves these to the scans' own retries (and to the
  // next session), rather than trying each one twice.
  final Set<String> _releasedIds = <String>{};
  // Late-import passes run one at a time, in call order.
  Future<void> _lateTail = Future<void>.value();
  // A live-watcher pass is waiting its turn: change events coalesce.
  bool _liveLateQueued = false;

  @override
  Stream<IntakePhoto> get photos => _controller.stream;

  @override
  void attachSink(
      Future<bool> Function(IntakePhoto photo, DateTime? safeFrontier)?
          sink) {
    _sink = sink;
  }

  @override
  Future<void> start() async {
    if (_started) return;
    // §6 permission flow: denial is not an error — share/picker intake still
    // works; the watcher just stays silent.
    if (!await _library.requestPermission()) return;
    _incrementalCutoff = _clock();
    await _library.startChangeNotify(_onLibraryChange);
    _started = true;
    _everStarted = true;
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _generation++; // quiesce in-flight emission loops
    await _library.stopChangeNotify();
  }

  void _onLibraryChange() {
    unawaited(_incrementalScan());
  }

  Future<void> _incrementalScan() async {
    // A change event racing stop() (queued before the platform unregister
    // completed) must not start a fresh scan with the watcher disabled.
    if (!_started) return;
    if (_scanning) {
      // A scan with a bound sink can run MINUTES (one Gemini call per
      // photo) — dropping this event outright would blind the live
      // watcher to every photo taken mid-scan. Mark dirty and re-scan
      // when the current pass finishes.
      _rescanPending = true;
      return;
    }
    _scanning = true;
    try {
      final cutoff = _incrementalCutoff ?? _clock();
      final assets = await _library.imagesCreatedAfter(cutoff);
      // Same truncation rule as backfillScan: a capped result set hides an
      // OLDER tail — the cutoff must not advance over unseen photos
      // (recovered by the full-window backfill layers meanwhile).
      final truncated = assets.length >= 500;
      final frontier = await _emit(assets, reportFrontier: !truncated);
      // Advance ONLY over the contiguous run of successfully-covered
      // photos (oldest-first), and never past the wall clock: a transient
      // read failure must stay inside the window so the next change event
      // retries it, and one future-skewed createDate (camera clock drift)
      // must not blind the live watcher for the skew duration.
      if (!truncated && frontier != null) {
        final now = _clock();
        final capped = frontier.isAfter(now) ? now : frontier;
        final cur = _incrementalCutoff;
        if (cur == null || capped.isAfter(cur)) _incrementalCutoff = capped;
      }
    } catch (_) {
      // Change-notify runs unawaited: a library query failure must not
      // become an unhandled zone error. The cutoff didn't advance, so the
      // next change event retries the same window.
    } finally {
      _scanning = false;
      // The createDate query above cannot see a photo imported late with
      // an old capture date; the change history can (G1b). Queued behind
      // any pass in progress, never awaited here: the live watcher must
      // not wait on it for the next change event.
      if (_started) _queueLiveLateImport();
      if (_rescanPending) {
        _rescanPending = false;
        if (_started) unawaited(_incrementalScan());
      }
    }
  }

  @override
  Future<void> lateImportScan({bool Function()? shouldContinue}) =>
      _queueLateImport(shouldContinue: shouldContinue, rescan: true);

  /// The live watcher's pass: no budget, and no rescan by date (that one
  /// lists the whole window; the launch/resume and background passes do
  /// it). One waiting at most.
  void _queueLiveLateImport() {
    if (lateImports == null || _liveLateQueued) return;
    _liveLateQueued = true;
    unawaited(_queueLateImport(rescan: false, live: true));
  }

  Future<void> _queueLateImport(
      {bool Function()? shouldContinue,
      required bool rescan,
      bool live = false}) {
    final cursor = lateImports;
    if (cursor == null) return Future<void>.value();
    final run = _lateTail.then((_) => _lateImportPass(cursor,
        shouldContinue: shouldContinue, rescan: rescan, live: live));
    // A pass never throws; were one to, the next must still run.
    _lateTail = run.catchError((Object _) {});
    return run;
  }

  Future<void> _lateImportPass(LateImportCursor cursor,
      {bool Function()? shouldContinue,
      required bool rescan,
      required bool live}) async {
    if (live) {
      _liveLateQueued = false;
      if (!_started) return;
    }
    // Switched off by the user: offer nothing (the background engine's
    // intake is never started, and is never stopped either).
    if (_everStarted && !_started) return;
    final generation = _generation;
    try {
      final report = await cursor.pass(
        cutoff: lookbackCutoff(_clock(), _lookbackDays()),
        rescan: rescan,
        windowCoveredFrom: _windowCoveredFrom,
        hooks: LateImportHooks(
          settled: (id) =>
              _seenAssetIds.contains(id) && !_inFlightIds.contains(id),
          retryLater: _releasedIds.contains,
          logged: (ids) async =>
              await loggedAssetIds?.call(ids) ?? const <String>{},
          resolve: _library.imagesByIds,
          listWindow: (cutoff) =>
              _library.imagesCreatedAfter(cutoff, limit: backfillQueryLimit),
          shouldContinue: shouldContinue,
          offer: (assets, onSettled) async {
            if (_generation != generation || (_everStarted && !_started)) {
              return; // stopped meanwhile: they stay in the carry
            }
            // No frontier, no onCovered: a late photo's createDate lies
            // behind every cutoff and watermark, and must not move one.
            await _emit(assets,
                reportFrontier: false,
                shouldContinue: shouldContinue,
                onSettled: onSettled);
          },
        ),
      );
      try {
        await onLateImportPass?.call(report);
      } catch (_) {}
    } catch (_) {
      // Never past here: the next pass, or the app's catch-up over the
      // whole window, finds what this one could not.
    }
  }

  @override
  Future<DateTime?> backfillScan(
      {int lookbackDays = 0,
      DateTime? since,
      bool Function()? shouldContinue,
      Future<void> Function(DateTime safeFrontier)? onCovered,
      bool newestDayFirst = false}) async {
    // 0 (unset) → the configured §8 default from settings.
    final days = lookbackDays > 0 ? lookbackDays : _lookbackDays();
    final scanStart = _clock();
    var cutoff = lookbackCutoff(scanStart, days);
    // A watermark can only NARROW the window, never widen it past §8's
    // lookback clamp.
    final narrowed = since != null && since.isAfter(cutoff);
    if (narrowed) cutoff = since;
    // §6.4: EVERY photo in the window is offered downstream; the status
    // ledger (saved/skipped/failed/deleted incl. tombstones) is what makes
    // the re-scan idempotent — keep the window small. The raised limit
    // keeps a heavy-shooter window from being truncated newest-first
    // (a truncated scan under a watermark skips the tail forever).
    final assets =
        await _library.imagesCreatedAfter(cutoff, limit: backfillQueryLimit);
    try {
      await onBackfillListed?.call(assets.length);
    } catch (_) {}
    // Truncation is known BEFORE emission (query hit its cap): the unseen
    // tail is OLDER than everything returned, so no frontier — per-photo
    // or final — may be reported for this scan.
    final truncated = assets.length >= backfillQueryLimit;
    // The newest day first (2026-10-19): a cold launch used to walk ~100
    // already-logged originals of the past week, oldest first, before the
    // first new photo — and a quick "did it log?" open was suspended long
    // before it reached today's meal. That pass reports no frontier; what
    // it handled is "seen" by the pass after it, which counts it covered
    // without reading it again, and what it released stays out of that
    // pass (one try per scan) and halts the frontier there.
    final released = <String>{};
    final tally = _EmitTally();
    if (newestDayFirst) {
      await _emit(_newestDay(assets),
          reportFrontier: false,
          shouldContinue: shouldContinue,
          released: released,
          tally: tally);
    }
    final frontier = await _emit(assets,
        reportFrontier: !truncated,
        shouldContinue: shouldContinue,
        onCovered: onCovered,
        released: released,
        tally: tally);
    // Signal AFTER emitting: the caller processes what was seen, but a
    // watermark must not advance over the unseen tail.
    if (truncated) throw const BackfillWindowTruncated();
    // The whole configured window, every photo in it read and settled:
    // nothing imported before this scan started can be missing from it.
    if (lookbackDays <= 0 && !narrowed && tally.complete) {
      final covered = _windowCoveredFrom;
      if (covered == null || scanStart.isAfter(covered)) {
        _windowCoveredFrom = scanStart;
      }
    }
    return frontier;
  }

  /// The photos not yet handled this session that were taken on the same
  /// local day as the newest of them.
  List<LibraryAsset> _newestDay(List<LibraryAsset> assets) {
    final unseen = [
      for (final a in assets)
        if (!_seenAssetIds.contains(a.id)) a,
    ];
    if (unseen.isEmpty) return const [];
    final newest = unseen
        .map((a) => a.createDateTime)
        .reduce((a, b) => b.isAfter(a) ? b : a);
    return [
      for (final a in unseen)
        if (a.createDateTime.year == newest.year &&
            a.createDateTime.month == newest.month &&
            a.createDateTime.day == newest.day)
          a,
    ];
  }

  /// Delivers [assets] oldest-first and returns the coverage FRONTIER: the
  /// newest createDate such that every asset at or before it was terminally
  /// handled (delivered, seen before, or permanently skipped). The frontier
  /// halts at the first transient failure or retryable release so callers
  /// never advance a cutoff/watermark past a photo that still needs a
  /// retry. Null = nothing covered.
  /// [reportFrontier] false (truncated window): every delivery carries
  /// safeFrontier null — the unseen OLDER tail forbids any watermark claim.
  /// [shouldContinue] false: the photo is left unread; [onCovered] hears
  /// each terminal delivery's safeFrontier (see [PhotoIntake.backfillScan]).
  /// [released]: photos an earlier pass of the same scan left eligible —
  /// skipped here (uncovered, so the frontier halts) — and this pass adds
  /// its own.
  /// [onSettled] hears each photo that reached a verdict here (delivered:
  /// read and handed over, rather than passed over or already handled),
  /// before the next photo is considered — the late-import cursor's
  /// carry. [tally] counts what was left undone.
  Future<DateTime?> _emit(List<LibraryAsset> assets,
      {bool reportFrontier = true,
      bool Function()? shouldContinue,
      Future<void> Function(DateTime safeFrontier)? onCovered,
      Set<String>? released,
      Future<void> Function(String assetId, {required bool delivered})?
          onSettled,
      _EmitTally? tally}) async {
    // §6: newest-LAST emission — oldest first, so downstream meal rows land
    // in chronological order.
    final ordered = [...assets]
      ..sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
    final generation = _generation;
    DateTime? frontier;
    var frontierOpen = true;
    final settled = <(String, bool)>[];
    // The Meta album members of this batch, looked up once (see
    // [metaAlbumIds]); from a minute before its oldest photo, so a
    // creation date rounded either way is still inside.
    Future<Set<String>>? albumIds;
    Future<bool> inMetaAlbum(String id) async {
      final lookup = metaAlbumIds;
      if (lookup == null || ordered.isEmpty) return false;
      albumIds ??= () async {
        try {
          final since = ordered.first.createDateTime
              .subtract(const Duration(minutes: 1));
          // Through then<Set<String>>: a lookup typed narrower (a
          // Future<Never> that throws) would reject timeout's onTimeout
          // and leave its own error unhandled.
          return await lookup(since)
              .then<Set<String>>((ids) => ids)
              .timeout(metaAlbumTimeout, onTimeout: () => const <String>{});
        } catch (_) {
          return const <String>{};
        }
      }();
      return (await albumIds!).contains(id);
    }

    void cover(LibraryAsset asset, {bool delivered = false}) {
      if (frontierOpen) frontier = asset.createDateTime;
      _releasedIds.remove(asset.id);
      if (onSettled != null) settled.add((asset.id, delivered));
    }

    Future<void> reportSettled(
        Future<void> Function(String assetId, {required bool delivered})
            hook) async {
      final batch = List.of(settled);
      settled.clear();
      for (final (id, delivered) in batch) {
        try {
          await hook(id, delivered: delivered);
        } catch (_) {}
      }
    }

    for (final asset in ordered) {
      if (onSettled != null) await reportSettled(onSettled);
      if (_controller.isClosed || _generation != generation) {
        tally?.stopped = true; // stop(): quiesce mid-batch
        break;
      }
      if (released != null && released.contains(asset.id)) {
        frontierOpen = false; // tried once this scan; the next scan retries
        tally?.released++;
        continue;
      }
      if (passOver != null &&
          !_seenAssetIds.contains(asset.id) &&
          passOver!(asset.id)) {
        cover(asset);
        continue;
      }
      // The caller's time budget, asked BEFORE the original is read: past
      // it, each remaining photo used to be read in full (multi-MB, an
      // iCloud fetch for some) only for the sink to release it, long after
      // iOS's grant. Unread means not seen and not covered, so the frontier
      // halts here and the next scan offers it. A photo this session
      // already handled costs nothing and still counts below.
      if (shouldContinue != null &&
          !_seenAssetIds.contains(asset.id) &&
          !shouldContinue()) {
        frontierOpen = false;
        tally?.unread++;
        continue;
      }
      if (!_seenAssetIds.add(asset.id)) {
        if (_inFlightIds.contains(asset.id)) {
          // A concurrent scan is still delivering it — its release may be
          // coming; nothing may pass it yet.
          frontierOpen = false;
          tally?.released++; // not settled by this scan either
        } else {
          cover(asset); // already terminally handled this session
        }
        continue;
      }
      // In-flight from the same instant it becomes "seen": a concurrent
      // scan meeting this id during our byte-read awaits (seconds for a
      // 25 MB original) must halt its frontier, not count it covered.
      _inFlightIds.add(asset.id);
      try {
        final Uint8List? bytes;
        final String name;
        try {
          bytes = await asset.originBytes(); // ORIGINAL bytes (§6.2)
          if (bytes == null || bytes.isEmpty) {
            _seenAssetIds
                .remove(asset.id); // transient read failure: retryable
            released?.add(asset.id);
            _releasedIds.add(asset.id);
            frontierOpen = false;
            tally?.released++;
            continue;
          }
          if (bytes.length > maxPhotoBytes) {
            cover(asset); // §8 25 MB pre-decode cap: permanent skip
            continue;
          }
          name = await asset.fileName();
        } catch (_) {
          // photo_manager REPLIES an error (not null) for unreadable/
          // deleted assets on Android 11+ — one bad asset must skip, not
          // abort the whole scan (a scan abort loses every photo behind
          // it AND, in the background job, kills the run before its
          // watermark logic).
          _seenAssetIds.remove(asset.id);
          released?.add(asset.id);
          _releasedIds.add(asset.id);
          frontierOpen = false;
          tally?.released++;
          continue;
        }
        final capturedAt = deriveCapturedAt(
            fileName: name,
            assetCreateDate: asset.createDateTime,
            now: _clock(),
            maxAgeDays: _capturedAtMaxAgeDays);
        // How it was taken, from the bytes already in hand (design G2a):
        // a header read, and one album lookup per scan. Neither throws;
        // were one to, the photo goes on without it.
        CaptureMeta? capture;
        try {
          capture = captureMetaFor(bytes, name,
              createDate: asset.createDateTime,
              inMetaAlbum: await inMetaAlbum(asset.id));
        } catch (_) {
          capture = null;
        }
        // deliberate=false: automated intake, strict reservation (§2.3).
        final photo = IntakePhoto(bytes, asset.id, name,
            capturedAt: capturedAt, deliberate: false, capture: capture);
        final sink = _sink;
        if (sink != null) {
          // Backpressured path: the next asset's bytes are read only after
          // this photo fully processed — one photo resident at a time. The
          // safeFrontier is what a consumer may persist if THIS photo
          // terminates: createDate-based and halted at any earlier failure.
          final safe = (reportFrontier && frontierOpen)
              ? asset.createDateTime
              : (reportFrontier ? frontier : null);
          final terminal = await sink(photo, safe);
          if (terminal) {
            cover(asset, delivered: true);
            if (onCovered != null && safe != null) {
              try {
                await onCovered(safe);
              } catch (_) {}
            }
          } else {
            _seenAssetIds.remove(asset.id); // released: re-offer next scan
            released?.add(asset.id);
            _releasedIds.add(asset.id);
            frontierOpen = false;
            tally?.released++;
          }
        } else {
          _controller.add(photo);
          cover(asset, delivered: true);
        }
      } finally {
        _inFlightIds.remove(asset.id);
      }
    }
    if (onSettled != null) await reportSettled(onSettled);
    return frontier;
  }
}
