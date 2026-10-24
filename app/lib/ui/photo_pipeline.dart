/// Photo intake → ledger → analyzer → meal glue (spec §2.3 reservation
/// contract, §3.5 persist sanitization, §6 intake rules).
///
/// Per-photo errors are contained (mark `failed`, keep the stream alive) —
/// spec §6 ledger rules: every reservation must end saved/skipped/failed.
library;

import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:intl/intl.dart';

import '../core/coerce.dart';
import '../core/contracts.dart';
import '../core/outcome_kind.dart';
import '../core/leftover_logic.dart';
import '../services/analyzer/platform_decode.dart';
import '../services/photo/background_time.dart';
import '../services/photo/capture_dating.dart' show glassesCapturedAt;
import '../services/photo/filename_dates.dart'
    show captureWallClock, exifCapturedAt, exifWallAndOffset,
        validateCapturedAt;
import '../services/photo/glasses.dart'
    show captureAnalysis, isGlassesPreview, shutterKey;
import '../services/photo/photo_hash.dart' show originalBytesMd5;
import 'format.dart';

Future<String> _computeMd5(Uint8List bytes) =>
    compute(originalBytesMd5, bytes);

enum PhotoOutcomeKind {
  saved,
  skipped,
  failed,
  duplicate,
  alreadyTracked,

  /// Another run holds a FRESH 'processing' reservation for this photo:
  /// it is being analyzed right now, or was until iOS expired that run's
  /// background grant (2026-10-07). Always [PhotoOutcome.retryable], so the
  /// frontier halts in front of it, the watcher forgets it was seen, and
  /// the add flow says "still analyzing" rather than "already logged".
  inFlight,

  /// The photo was the REMAINS of an earlier meal (2026-08-05): no new
  /// row — the original meal's totals shrank and the photo's hash is
  /// tombstoned so no scan re-offers it.
  leftoverApplied,
}

class PhotoOutcome {
  final PhotoOutcomeKind kind;
  final Map<String, dynamic>? analysis; // present when kind == saved

  /// True when the photo stays ELIGIBLE: a transient failure whose
  /// reservation was released, or a reservation that was never ours
  /// ([PhotoOutcomeKind.inFlight]) — a later scan re-offers it. Consumers
  /// use this to hold watermarks/seen-sets open instead of marking coverage.
  final bool retryable;
  final String message; // user-facing summary (English, parity-pinned)

  /// Why a [PhotoOutcomeKind.failed] happened, classified for localization;
  /// [AnalysisErrorKind.none] for every other kind.
  final AnalysisErrorKind errorKind;

  /// The variable part the UI needs to re-say [message] in another
  /// language: the meal summary for saved/leftover, the raw error for
  /// failed. Null means "nothing beyond the kind" — the UI then falls back
  /// to [message] verbatim.
  final String? detail;

  /// [PhotoOutcomeKind.saved] / [PhotoOutcomeKind.leftoverApplied]: the
  /// parts of [detail], so the UI says it in the app language (zh 千卡, not
  /// 'kcal'). [kcal] is the saved meal's total, or the cut meal's NEW
  /// total; [deductedKcal] is the leftover's cut. Null when an outcome was
  /// built without them — the UI then shows [detail].
  final String? mealName;
  final String? kcal;
  final int? deductedKcal;

  /// [PhotoOutcomeKind.leftoverApplied] only: the meal that was cut, its
  /// day, and its analysis as it stood just BEFORE this deduction — what
  /// the add flow's "not leftovers" undo writes back (revertedLeftover).
  /// [analysis] is then the deducted analysis this run stored.
  final int? mealId;
  final String? mealDate;
  final Map<String, dynamic>? previousAnalysis;

  /// Set by [PhotoPipeline.bindStream] on the share-sheet announcement of
  /// a TRANSIENT failure, so the snackbar can ask for a re-share instead
  /// of claiming the photo was kept (outcomeSnackbar).
  final bool shared;

  /// [shared]'s twin for a photo PICKED in the add flow whose screen was
  /// closed before the verdict came back (unannouncedOutcome): the
  /// snackbar asks the user to pick it again.
  final bool picked;

  /// Why the automatic intake skipped or held a photo back without asking
  /// the model, machine-readable ([duplicateCaptureReason],
  /// [glassesPreviewReason]); null for every other verdict. Never shown:
  /// those guards act on automatic photos only, whose skips and releases
  /// nobody announces.
  final String? reason;
  const PhotoOutcome(this.kind, this.message,
      {this.analysis,
      this.retryable = false,
      this.errorKind = AnalysisErrorKind.none,
      this.detail,
      this.mealName,
      this.kcal,
      this.deductedKcal,
      this.mealId,
      this.mealDate,
      this.previousAnalysis,
      this.shared = false,
      this.picked = false,
      this.reason});
}

/// [PhotoOutcome.reason] of an automatic glasses photo skipped because
/// another file of the same shutter press is already a meal (design G2b).
const String duplicateCaptureReason = 'duplicate_capture';

/// [PhotoOutcome.reason] of an automatic glasses preview copy held back
/// for its full-size version (design G2b, deferred_assets.dart).
const String glassesPreviewReason = 'glasses_preview';

/// What to announce for a verdict NOBODY is awaiting — a shared photo
/// (bindStream), or a picked one whose add-flow screen was closed
/// mid-analysis — or null when process() already announced it itself
/// (saves, leftover deductions, permanent failures). One filter for both
/// callers, so the kinds cannot drift apart. A transient failure comes back
/// flagged [shared] / [picked] so the snackbar asks for the photo again:
/// it was released, and nothing will re-offer it.
PhotoOutcome? unannouncedOutcome(PhotoOutcome o,
        {bool shared = false, bool picked = false}) =>
    switch (o.kind) {
      PhotoOutcomeKind.skipped ||
      PhotoOutcomeKind.duplicate ||
      PhotoOutcomeKind.alreadyTracked ||
      PhotoOutcomeKind.inFlight =>
        o,
      PhotoOutcomeKind.failed when o.retryable => PhotoOutcome(
          o.kind, o.message,
          retryable: true,
          errorKind: o.errorKind,
          detail: o.detail,
          shared: shared,
          picked: picked),
      PhotoOutcomeKind.saved ||
      PhotoOutcomeKind.leftoverApplied ||
      PhotoOutcomeKind.failed =>
        null,
    };

/// The persisted automatic-analysis latch (AppSettings.isAnalysisBlocked),
/// as the pipeline sees it. A rejected key or a blocked region refuses
/// EVERY automatic photo the same way; once one came back like that, the
/// rest of the scan — and every scan after it until the latch lifts — is
/// released without an analyzer call instead of re-uploading the whole
/// lookback window (2026-10-12). Built by [autoScanLatchFor] in production.
class AutoScanLatch {
  const AutoScanLatch(
      {required this.blockedKind,
      required this.revision,
      required this.block,
      required this.clear,
      this.refresh});

  /// Re-read the latch from disk before an automatic photo is checked: the
  /// other engine (the background run is another isolate with its own
  /// preferences cache) may have armed it since this one loaded. Without
  /// it a photo event delivered to the open app after a background run
  /// paused the scan was uploaded again on the rejected key (API 35
  /// emulator, 2026-10-12). Null (tests) trusts [blockedKind] as is.
  final Future<void> Function()? refresh;

  /// The armed latch's kind ([AnalysisErrorKind.rejectedKey] or
  /// [AnalysisErrorKind.regionBlocked]); null while automatic analysis may
  /// run.
  final AnalysisErrorKind? Function() blockedKind;

  /// The credentials revision, read BEFORE an analysis and handed back to
  /// [block]: a refusal of the key the user has since replaced is dropped.
  final int Function() revision;
  final Future<void> Function(AnalysisErrorKind kind, int revision) block;

  /// Lift the latch (an analysis succeeded).
  final Future<void> Function() clear;
}

class PhotoPipeline {
  final MealsDao dao;
  final AnalyzerService analyzer;

  /// Notification-style surface (snackbar) for verdicts nobody awaits:
  /// process() announces saves, leftover deductions and PERMANENT failures
  /// on every path (plus, throttled, a rejected key or blocked region on
  /// the automatic scan), and [bindStream] (the share sheet) and the add
  /// flow closed mid-analysis add the rest (unannouncedOutcome). Handed
  /// the OUTCOME, not a sentence: the caller words it in the app language
  /// (di.dart via outcomeSnackbar). Passing [PhotoOutcome.message] here put
  /// English snackbars ("Meal logged: …") in front of the Chinese UI every
  /// time the automatic scan saved a photo with the app open (2026-10-08).
  final void Function(PhotoOutcome outcome)? notify;

  /// Called after a meal row lands, so open screens can re-query. Separate
  /// from [notify] on purpose: notify also fires for failures, and only a
  /// SAVE changes what the lists should show.
  final void Function()? onMealSaved;

  /// Null (tests, the add flow's fallback instance) = no latch: every
  /// automatic photo reaches the analyzer.
  final AutoScanLatch? latch;

  /// True in the iOS background engine (runHeadlessBackfill): a photo the
  /// analyzer could not turn into upload bytes is DEFERRED — released,
  /// retryable — instead of burned to 'failed'. That engine lacks a decoder
  /// the app has (its GPU is off, so platform_decode.dart never asks dart:ui
  /// there), and the app's own run that re-offers the photo can still read
  /// it; burning it lost the photo for good (watch intake never reclaims a
  /// failure). The cost is a watermark that waits in front of that photo
  /// until the app next opens, when the launch catch-up settles it either
  /// way. Android's background run has every decoder, so its verdicts stay
  /// as they were (false).
  final bool deferUndecodable;

  /// iOS, the app's own engine only (di.dart): each photo runs inside one
  /// background task, so leaving the app mid-analysis lets that photo's
  /// upload and save finish instead of freezing with it (2026-10-19). Null
  /// everywhere else — the headless run has the OS grant, Android does not
  /// suspend this way, tests opt in.
  final BackgroundTime? backgroundTime;

  /// iOS, the app's own engine only (di.dart: appEngineBackgrounded):
  /// whether the app is in the background right now. Then an AUTOMATIC
  /// photo is not started at all — released before it is hashed, reserved
  /// or given a task, so only the photo already in flight spends the time
  /// iOS gives; the next open or background run offers the rest
  /// (2026-10-19). And an undecodable verdict reached there is deferred,
  /// not burned: dart:ui cannot decode with the GPU off, and the same photo
  /// decodes in the foreground. Deliberate photos (picked, shared) always
  /// run. Null everywhere else.
  final bool Function()? backgrounded;

  /// Every verdict, after process() reached it (any intake). The app engine
  /// uses it to forget a photo the background run kept deferring once the
  /// app settled it (deferred_assets.dart). A throw is contained.
  final void Function(IntakePhoto photo, PhotoOutcome outcome)? onOutcome;

  /// Asked for an AUTOMATIC Meta glasses photo below 2 MP (design G2b,
  /// glasses.dart isGlassesPreview): true holds it back — released,
  /// retryable, untouched — so its full-size version can arrive first.
  /// Production: deferred_assets.dart holdGlassesPreview (once, for 10
  /// minutes). Null (tests, the add flow's fallback instance): never held.
  /// A throw counts as false.
  final Future<bool> Function(String assetId)? previewHold;

  final List<StreamSubscription<IntakePhoto>> _subs = [];

  /// The 'processing' reservation the photo in flight holds right now, and
  /// that photo's asset id — what [abandon] gives back.
  ({String hash, String stamp, String assetId})? _held;

  /// Set by [abandon]: nothing more is uploaded, settled or saved.
  bool _abandoned = false;

  // FIFO tail: bound-stream photos process ONE at a time. A backfill batch
  // fired concurrently self-inflicts Gemini RPM 429s (free tier) and piles
  // write contention onto the ledger; the server processed sequentially too.
  // process() never throws (contract), so the chain cannot break.
  Future<void> _tail = Future.value();

  PhotoPipeline(
      {required this.dao,
      required this.analyzer,
      this.notify,
      this.onMealSaved,
      this.latch,
      this.deferUndecodable = false,
      this.backgroundTime,
      this.backgrounded,
      this.onOutcome,
      this.previewHold,
      Future<String> Function(Uint8List bytes)? hasher,
      Future<Uint8List?> Function(Uint8List original)? thumbnailer,
      DateTime Function()? clock})
      : _hash = hasher ?? _computeMd5,
        _thumb = thumbnailer ?? makeMealThumbAny,
        _clock = clock ?? DateTime.now;

  /// Injectable so tests stay synchronous; production hashes on a worker.
  final Future<String> Function(Uint8List bytes) _hash;

  /// The history thumbnail (platform_decode's chain); injectable so tests
  /// can make it hang or throw.
  final Future<Uint8List?> Function(Uint8List original) _thumb;

  /// How long a saved meal may wait for its thumbnail in the iOS background
  /// run (the one [deferUndecodable] marks). The meal is already committed,
  /// but process() has not returned: its notification card and the
  /// watermark checkpoint come only after it, and the OS grant is ~30 s. A
  /// thumb that is not ready by then is skipped (the meal shows without
  /// one), never waited on.
  ///
  /// Every other run awaits the thumb to the end, as before: platform_decode
  /// bounds its own native and engine steps, and the pure-Dart step always
  /// finishes. Abandoning that step (a 50 MP JPEG on a slow Android phone)
  /// would leave its full decode running in the isolate while the next
  /// photo's starts — the memory the serialized pipeline exists to save.
  static const thumbnailTimeout = Duration(seconds: 8);

  /// Injectable for the rejected-key notice throttle below.
  final DateTime Function() _clock;

  /// When the automatic scan last told the user their key was rejected or
  /// their region blocked: a backlog of 40 photos against a revoked key is
  /// ONE problem, not 40 stacked snackbars.
  DateTime? _lastRejectedKeyNotice;
  static const rejectedKeyNoticeInterval = Duration(minutes: 10);

  /// The refusals that say nothing about the PHOTO: every automatic photo
  /// would come back the same way until the user's setup changes.
  static bool _refusesEveryPhoto(AnalysisErrorKind k) =>
      k == AnalysisErrorKind.rejectedKey || k == AnalysisErrorKind.regionBlocked;

  /// Wire the watcher intake with BACKPRESSURE: the intake awaits each
  /// photo's turn through the same global FIFO the share stream uses, so
  /// byte reads never run ahead of processing (one photo's bytes resident
  /// at a time). Returns non-retryable to the intake so released photos
  /// are re-offered by later scans.
  void bind(PhotoIntake intake) {
    intake.attachSink((p, _) {
      final slot = _tail.then((_) => process(p));
      _tail = slot.then((_) {});
      return slot.then((o) => !o.retryable);
    });
  }

  /// FIFO-honest single-photo entry: chains onto the same global tail the
  /// watcher sink and share stream use, so callers (coverage Log/Retry)
  /// QUEUE BEHIND — never race — an in-flight scan. Calling process()
  /// directly would run a second analyzer call concurrently (free-tier RPM
  /// 429s) and hold two originals in memory.
  Future<PhotoOutcome> enqueue(IntakePhoto photo) {
    final slot = _tail.then((_) => process(photo));
    _tail = slot.then((_) {});
    return slot;
  }

  /// Also used for the share-sheet intake stream (deliberate adds, spec §6).
  ///
  /// Nobody awaits a shared photo's verdict, so the kinds process() leaves
  /// to its caller — not food, duplicate, already logged, still analyzing,
  /// a transient failure — are announced HERE. The add flow awaits
  /// enqueue() and shows each of
  /// them as a dialog; a share that ended the same way showed nothing at
  /// all, indistinguishable from a share that silently failed, and invited
  /// a re-share that re-analyzed the photo just as silently (2026-10-10).
  /// process() keeps announcing saves, leftover deductions and permanent
  /// failures itself (every path), so none of those is said twice, and the
  /// watcher's bind() stays quiet about them.
  void bindStream(Stream<IntakePhoto> photos) {
    _subs.add(photos.listen((p) {
      final slot = _tail.then((_) => process(p));
      _tail = slot.then((o) {
        // A transient failure was released, and the share copy is already
        // gone: nothing will ever re-offer it, so silence read as "it
        // worked" — it comes back flagged [PhotoOutcome.shared] and the
        // snackbar asks for a re-share (outcomeSnackbar words it).
        final say = unannouncedOutcome(o, shared: true);
        if (say == null) return;
        // Shielded like process()'s own notify calls: this runs ON the
        // shared tail, and a throwing snackbar would reject it and stall
        // every later photo (watcher, share, coverage Log/Retry) until an
        // app restart.
        try {
          notify?.call(say);
        } catch (_) {}
      });
    }, onError: (Object _) {}));
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  /// Ends this pipeline's work for good (2026-10-19): the iOS background
  /// run's deadline (finishWithinGrant) replies to workmanager, which
  /// destroys the engine right after — so a photo still in flight would
  /// never finish, and its 'processing' row would answer every later run
  /// (and the open app) "still analyzing" for appProcessingStaleAge,
  /// holding the background watermark in front of it.
  ///
  /// Releases the reservation the photo in flight holds, with its
  /// ownership stamp (a row another run took is left alone), waiting at
  /// most [limit]; from then on process() uploads, settles and saves
  /// nothing — a late reply is dropped, the photo stays eligible. Returns
  /// the released photo's asset id, or null when none was held. Never
  /// throws.
  Future<String?> abandon(
      {Duration limit = const Duration(seconds: 1)}) async {
    _abandoned = true;
    final held = _held;
    _held = null;
    if (held == null) return null;
    try {
      await dao
          .releasePhotoHash(held.hash, ownerStamp: held.stamp)
          .timeout(limit);
    } catch (_) {
      // Lost to another run already, or the store is busy: nothing more
      // this run can do before its engine goes.
    }
    return held.assetId;
  }

  /// [backgrounded], contained: a throwing probe reads as the foreground.
  bool _inBackground() {
    try {
      return backgrounded?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The clock [photo]'s meal is dated by. validateCapturedAt is NOT
  /// optional: EXIF is attacker- and junk-controlled (a 2015 stock photo, a
  /// camera with a dead clock, a forward-set date), and an unvalidated
  /// value writes a meal into a random month of the user's log.
  /// A capturedAt is re-expressed in the zone the photo was TAKEN in when
  /// the EXIF shutter stamp names that zone and the same instant
  /// (captureWallClock): iOS's createDateTime is an instant shown in the
  /// CURRENT zone, so a photo first scanned after a flight was dated by the
  /// destination's clock. Not re-validated against local now — the instant
  /// already was, and a westbound wall clock can sit "ahead".
  /// First, design G2b: a Meta glasses photo whose creation date is only
  /// the time it was imported is dated by its EXIF shutter clock
  /// (capture_dating.dart glassesCapturedAt, with the evidence the watcher
  /// found). Every other photo is dated exactly as before.
  static DateTime _mealClock(IntakePhoto photo) {
    final now = DateTime.now();
    final redated = glassesCapturedAt(photo.capture, now: now);
    if (redated != null) return redated;
    final captured = photo.capturedAt;
    return (captured == null
            ? null
            : captureWallClock(captured, exifWallAndOffset(photo.bytes))) ??
        validateCapturedAt(exifCapturedAt(photo.bytes), now: now) ??
        now;
  }

  /// How many days either side of a photo's own day the duplicate-capture
  /// guard looks for a meal of the same shutter press: the two files may
  /// have been dated differently (one by its import time).
  static const int sameShotWindowDays = 2;

  /// [photo]'s shutter key when the duplicate-capture guard (design G2b)
  /// looks at it — an AUTOMATIC Meta glasses photo whose EXIF names its
  /// shutter press — else null.
  static String? _guardedShutterKey(IntakePhoto photo) {
    if (photo.deliberate) return null;
    final capture = photo.capture;
    if (capture == null || !capture.isMetaGlasses) return null;
    return shutterKey(capture.exif);
  }

  /// Whether a meal dated within [sameShotWindowDays] of [clock]'s day
  /// already holds [key]. A store that cannot say lets the photo through:
  /// the guard must never cost a photo.
  Future<bool> _sameShotLogged(String key, DateTime clock) async {
    try {
      final from = isoDate(
          DateTime(clock.year, clock.month, clock.day - sameShotWindowDays));
      final to = isoDate(
          DateTime(clock.year, clock.month, clock.day + sameShotWindowDays));
      final ids = await dao.mealIdsWithShutterKey(key, from, to);
      return ids.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether [previewHold] holds the AUTOMATIC glasses preview [photo]
  /// back now. A throwing hold lets it through.
  Future<bool> _holdsPreview(IntakePhoto photo) async {
    final hold = previewHold;
    if (hold == null || photo.deliberate || photo.assetId.isEmpty) {
      return false;
    }
    if (!isGlassesPreview(photo.capture)) return false;
    try {
      return await hold(photo.assetId);
    } catch (_) {
      return false;
    }
  }

  /// The photo's verdict once [abandon] ran: retryable, so the intake
  /// releases it and the frontier halts in front of it. Releases the
  /// reservation itself when [abandon] could not (it was taken after).
  Future<PhotoOutcome> _whenAbandoned() async {
    final held = _held;
    _held = null;
    if (held != null) {
      try {
        await dao.releasePhotoHash(held.hash, ownerStamp: held.stamp);
      } catch (_) {}
    }
    return _outOfTime;
  }

  /// One photo through the full pipeline. Never throws.
  ///
  /// Every intake comes through here (watcher, share sheet, add flow,
  /// coverage), one photo at a time off the FIFO, so [backgroundTime] holds
  /// exactly one task per photo. A lost reservation's second settle
  /// ([_afterLost]) stays inside the same task.
  Future<PhotoOutcome> process(IntakePhoto photo) async {
    final time = backgroundTime;
    final outcome = !photo.deliberate && _inBackground()
        ? _waitsForForeground
        : await (time == null
            ? _process(photo)
            : time.guard('photo', () => _process(photo)));
    // Settled or released by now: no reservation is held past process().
    _held = null;
    try {
      onOutcome?.call(photo, outcome);
    } catch (_) {}
    return outcome;
  }

  /// [held]: a verdict this photo ALREADY got, with the meal snapshot its
  /// leftover indexes resolve against — settled again instead of uploading
  /// the photo a second time (see [_afterLost]).
  Future<PhotoOutcome> _process(IntakePhoto photo,
      {_HeldVerdict? held}) async {
    // Identity = md5 of ORIGINAL bytes, normalized (spec §6.2, §2.2).
    // OFF the UI isolate: md5 over a 12-25 MB original is tens of ms of
    // straight-line work, and an album burst runs this once per photo —
    // visible jank while the user scrolls (the coverage auditor already
    // hashes via compute for exactly this reason).
    //
    // INSIDE the try: compute() spawns an isolate and can fail on a
    // low-RAM device, and process() is contractually non-throwing — a
    // throw here would poison the shared _tail future and silently stop
    // ALL later photos until an app restart.
    // Non-final: the catch block reads it, and a hash failure leaves it
    // empty (nothing was reserved under it, so nothing to mark).
    var hash = '';
    var reserved = false;
    // Our reservation's ownership stamp: every write that settles the photo
    // carries it, and fails (ReservationLost) once the row is not ours.
    String? stamp;
    // The verdict this run holds once the analyzer answered.
    _HeldVerdict? verdict;
    try {
      if (_abandoned) return _outOfTime;
      // The automatic-analysis latch is armed: release the photo before
      // even hashing it — no ledger row, no analyzer call, no upload. It
      // stays eligible (retryable), so the scan after the fix picks it up.
      // Deliberate adds always go through: they are how the fix is tested.
      final gate = photo.deliberate ? null : latch;
      if (gate != null && gate.refresh != null) {
        try {
          await gate.refresh!(); // a prefs read: cheap next to an upload
        } catch (_) {
          // Unreadable store: fall back to this engine's own copy.
        }
      }
      final latched = gate?.blockedKind();
      if (latched != null) {
        return PhotoOutcome(PhotoOutcomeKind.failed, _latchedMessage,
            retryable: true, errorKind: latched, detail: _latchedMessage);
      }
      // Design G2b, AUTOMATIC Meta glasses photos only — a deliberate add
      // is the user's call. Another file of the same shutter press (a
      // preview and its full-size copy) already being a meal is decided
      // HERE, before the reservation and without the model; the photo is
      // tombstoned 'skipped' below once its reservation is ours. The meal
      // clock it needs is read now only for such a photo: the EXIF scan
      // behind it is not repeated for the already-logged photos every
      // catch-up re-offers.
      final shotKey = _guardedShutterKey(photo);
      final shotClock = shotKey == null ? null : _mealClock(photo);
      final sameShot =
          shotKey != null && await _sameShotLogged(shotKey, shotClock!);
      // A glasses preview copy (< 2 MP) waits once for its full-size
      // version: released untouched, before it is even hashed.
      if (!sameShot && await _holdsPreview(photo)) return _previewHeld;
      hash = normalizeImageHash(await _hash(photo.bytes));
      // Pre-reservation 5-minute duplicate window — deliberate (user-facing)
      // path only, matching the server's chat-only check (spec §2.3).
      if (photo.deliberate && await dao.isDuplicatePhoto(hash)) {
        return const PhotoOutcome(PhotoOutcomeKind.duplicate,
            'Looks like a duplicate of a photo logged minutes ago.');
      }

      // Reservation: deliberate adds reclaim failed/skipped/deleted rows;
      // automated watch intake is strict (spec §2.3 caller policies).
      final source =
          photo.deliberate ? MealSource.appPhoto : MealSource.appWatch;
      final reservation = await dao.reservePhotoHash(hash,
          source: source, reclaimDeliberate: photo.deliberate);
      switch (reservation.kind) {
        case PhotoReservation.claimed:
          return _alreadyTracked;
        case PhotoReservation.inFlight:
          // Not ours and not a verdict: another run is mid-analysis, or
          // iOS killed one mid-analysis and its row has not gone stale yet
          // (appProcessingStaleAge, 30 min). RETRYABLE, and the row is
          // left alone: reporting this as alreadyTracked let the background
          // watermark and the watcher's seen-set march past a photo nobody
          // had analyzed (2026-10-07).
          return _inFlight;
        case PhotoReservation.reserved:
          reserved = true;
          stamp = reservation.stamp;
          if (stamp != null) {
            _held = (hash: hash, stamp: stamp, assetId: photo.assetId);
          }
      }
      if (_abandoned) return await _whenAbandoned();
      if (sameShot) {
        // Settled as a verdict, so no scan offers it again; a deliberate
        // add still reclaims it (spec §2.3).
        await dao.markPhotoHash(hash, IngestionStatus.skipped,
            ownerStamp: stamp);
        _held = null;
        return _duplicateCapture;
      }

      // The day this photo belongs to ([_mealClock]).
      final when = shotClock ?? _mealClock(photo);
      // AUTOMATIC leftover check (2026-08-05): the meals of the day the
      // photo was TAKEN ride along as compacts; the model may answer
      // leftover_of instead of a new meal. The SNAPSHOT is captured here —
      // reply indexes resolve against exactly this list (spec §4.2
      // snapshot rule). The photo's own day, never "today": a backfilled or
      // re-scanned photo from last week used to be matched against today's
      // meals and could deduct from the wrong one (loop find 2026-10-07).
      final today = isoDate(when);
      final candidates = byMealClock(
              (await dao.mealsBetween(today, today)).where(isFoodMeal))
          .toList();
      // A held verdict resolves against the snapshot ITS model call saw.
      final recent = held?.recent ??
          (candidates.length > kAutoLeftoverMaxCandidates
              ? candidates
                  .sublist(candidates.length - kAutoLeftoverMaxCandidates)
              : candidates);
      final compacts = [
        for (final m in recent)
          recentMealCompact(time: m.time, analysis: m.analysis),
      ];

      final revision = latch?.revision();
      if (_abandoned) return await _whenAbandoned(); // no upload
      final gpuOffSkips = gpuOffDecodeSkips;
      final outcome = held?.outcome ??
          await analyzer.analyzePhoto(photo.bytes, recentMeals: compacts);
      // The run's deadline passed during the analysis: abandon() released
      // the photo, and nothing below may write for it.
      if (_abandoned) return await _whenAbandoned();
      verdict = (outcome: outcome, recent: recent);
      if (outcome.analysis == null) {
        final why = outcome.error ?? 'Analysis failed.';
        final errorKind = classifyAnalysisError(outcome.error);
        if (!photo.deliberate && _refusesEveryPhoto(errorKind)) {
          // A rejected key (or a region the provider does not serve) is
          // the USER's state, like a missing key: every photo of the
          // automatic scan would fail the same way. Burning each to
          // 'failed' dropped the whole backlog for good (watch intake never
          // reclaims) and stacked one snackbar per photo. Release instead —
          // fixing the key / VPN brings them all back — arm the latch so
          // the rest of this scan and later scans stop uploading, and say
          // it once per [rejectedKeyNoticeInterval], since a retryable
          // failure is otherwise never announced. The analyzer still calls
          // the key non-retryable (probeKey/diagnostics read that);
          // deliberate adds keep their own verdict below.
          await dao.releasePhotoHash(hash, ownerStamp: stamp);
          final held = PhotoOutcome(PhotoOutcomeKind.failed, why,
              retryable: true, errorKind: errorKind, detail: why);
          if (latch != null && revision != null) {
            try {
              await latch!.block(errorKind, revision);
            } catch (_) {}
          }
          final now = _clock();
          final last = _lastRejectedKeyNotice;
          if (last == null ||
              now.isBefore(last) ||
              now.difference(last) >= rejectedKeyNoticeInterval) {
            _lastRejectedKeyNotice = now;
            try {
              notify?.call(held);
            } catch (_) {}
          }
          return held;
        }
        // The analyzer's "could not process this photo (decode failed …)":
        // nothing was sent. In the iOS background engine — or the app's
        // own while it is in the background ([backgrounded]), or when its
        // decode skipped dart:ui because it was then ([gpuOffDecodeSkips];
        // the user may be back already) — that says more about the engine
        // than the photo: defer it to a run that has every decoder
        // ([deferUndecodable]). Everywhere else the permanent verdict below
        // stands.
        final deferred = (deferUndecodable ||
                _inBackground() ||
                gpuOffDecodeSkips != gpuOffSkips) &&
            errorKind == AnalysisErrorKind.badPhoto;
        if (outcome.retryable || deferred) {
          // Transient trouble (rate limit / network / quota pause / no key):
          // RELEASE the reservation so the next scan simply re-offers the
          // photo. Burning it to 'failed' would drop it forever on the
          // automated path (watch intake never reclaims, spec §2.3).
          await dao.releasePhotoHash(hash, ownerStamp: stamp);
          return PhotoOutcome(PhotoOutcomeKind.failed, why,
              retryable: true, errorKind: errorKind, detail: why);
        }
        // Permanent failure: kept as status failed for deliberate retry
        // (spec §6.5).
        await dao.markPhotoHash(hash, IngestionStatus.failed,
            ownerStamp: stamp);
        final failed = PhotoOutcome(PhotoOutcomeKind.failed, why,
            errorKind: errorKind, detail: why);
        // Shielded like the save paths below: the failed mark is already
        // committed, and a throwing snackbar must not turn this verdict
        // into the outer catch's "Photo intake failed".
        try {
          notify?.call(failed);
        } catch (_) {}
        return failed;
      }
      // An answer came back, so the key and the region work: lift the
      // automatic-analysis latch (a deliberate add after the fix included).
      try {
        await latch?.clear();
      } catch (_) {}
      if (!outcome.isFood) {
        // Tombstone so backfill never re-analyzes it (spec §6.4).
        await dao.markPhotoHash(hash, IngestionStatus.skipped,
            ownerStamp: stamp);
        return _notFood;
      }

      final analysis = Map<String, dynamic>.from(outcome.analysis!);

      // AUTOMATIC leftover application (2026-08-05): a confident
      // leftover_of verdict ADJUSTS the original meal in place — no new
      // row, no double-count, photo tombstoned. Unusable verdicts fall
      // through to a normal save (the manual flow remains the repair
      // path); this branch never deletes anything.
      final autoIdx =
          autoLeftoverIndex(analysis, candidateCount: recent.length);
      if (autoIdx != null) {
        final original = recent[autoIdx];
        final applied = applyLeftover(original.analysis, analysis,
            leftoverPhotoMd5: hash,
            appliedAtIso: DateTime.now().toIso8601String());
        if (applied != null) {
          // Tombstone and deduction in ONE owner-checked transaction: a run
          // that lost the photo (to another run, or to the user's own
          // 手动记录) must not cut the earlier meal, and a kill or a failed
          // update can no longer tombstone the photo without the deduction.
          await dao.applyLeftoverVerdict(hash, original.id, applied.adjusted,
              ownerStamp: stamp);
          final newKcal =
              safeNumber(applied.adjusted['total_calories']).round();
          final name = mealDescription(original.analysis);
          final summary = '$name — −${applied.deductedKcal} '
              'kcal, now ~$newKcal kcal';
          final leftover = PhotoOutcome(
              PhotoOutcomeKind.leftoverApplied, 'Leftovers deducted: $summary',
              analysis: applied.adjusted,
              detail: summary,
              mealName: name,
              kcal: '$newKcal',
              deductedKcal: applied.deductedKcal,
              mealId: original.id,
              mealDate: original.date,
              // The row as THIS application found it, not
              // leftover.original: undoing a wrong second deduction
              // must keep an earlier, correct one.
              previousAnalysis: original.analysis);
          try {
            notify?.call(leftover);
            onMealSaved?.call();
          } catch (_) {}
          return leftover;
        }
      }

      if (analysis.containsKey('food_items')) {
        // Sanitize before persisting — a hostile shape is never stored
        // (spec §3.5).
        analysis['food_items'] = safeFoodItems(analysis);
      }

      // How the photo was taken (design G2a): the intake's reading of its
      // own bytes, never the model's — a reply carrying a 'capture' key is
      // not evidence of a camera. No coordinates, no timestamps.
      analysis.remove('capture');
      final capture = photo.capture;
      if (capture != null) analysis['capture'] = captureAnalysis(capture);

      // Backdating: a valid capturedAt (validated by the intake module,
      // spec §6.3) sets date/time; timestamp stays now (spec §2.2).
      // When BOTH §6.3 sources failed (share-sheet photo, no timestamp in
      // the filename), the JPEG's own EXIF shutter time is the last truth
      // before intake-time dating — same validation window (§9 app-only,
      // 2026-07-31). This is what keeps a 23:50 photo shared after
      // midnight on YESTERDAY's total.
      final id = await dao.saveMeal(
        Meal(
          id: 0, // assigned by the DAO on insert
          date: isoDate(when),
          // 12-hour zero-padded hh:mm AM/PM, server parity (spec §2.2).
          time: DateFormat('hh:mm a').format(when),
          timestamp: DateTime.now().toIso8601String(),
          source: source,
          imageHash: hash,
          fileId: photo.assetId,
          analysis: analysis,
        ),
        markStatus: IngestionStatus.saved, // atomic saved mark (spec §2.3)
        ownerStamp: stamp,
      );
      _held = null; // saved: no longer a reservation
      // History thumbnail from the ORIGINAL bytes we already hold (spec §9
      // app-only). Best-effort AND awaited: the pipeline is serialized, so
      // finishing the thumb before the next photo keeps memory flat; any
      // failure must never un-save the meal, and in the iOS background run
      // a thumb that never comes must not hold the verdict past
      // [thumbnailTimeout].
      // An abandoned run (its engine about to go) starts no thumbnail.
      if (!_abandoned) {
        try {
          final pending = _thumb(photo.bytes);
          final thumb = await (deferUndecodable
              ? orNullAfter(pending, thumbnailTimeout)
              : pending);
          if (thumb != null) await dao.saveMealThumb(id, thumb);
        } catch (_) {}
      }
      final name = mealDescription(analysis);
      final kcal = displayTotalCalories(analysis);
      final summary = '$name — ~$kcal kcal';
      // No row id in the copy: the chat flow numbers meals by LIST position
      // ("meal 2 was roast duck"), so surfacing the SQLite id taught users
      // a number that is guaranteed to miss.
      final saved = PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged: $summary',
          analysis: analysis, detail: summary, mealName: name, kcal: kcal);
      // Same shield as the thumbnail: these run AFTER the commit, so a
      // throwing callback must not fall into the outer catch — that
      // flipped the committed ledger row saved→failed and told the user
      // the intake failed (pressure-test find, 2026-08-03).
      try {
        notify?.call(saved);
        onMealSaved?.call();
      } catch (_) {}
      return saved;
    } on ReservationLost {
      // Our 'processing' row was reclaimed while this run was suspended
      // (or the user logged the photo by hand): the photo is somebody
      // else's now. Drop the verdict without a word — the owner saves and
      // announces it — unless the user is waiting on this very photo.
      return _afterLost(photo, hash, verdict, retried: held != null);
    } catch (e) {
      // Containment: never rethrow (spec §6). Mark failed ONLY if we hold
      // the reservation — a pre-reservation throw (e.g. the duplicate
      // check or reserve itself, typically transient DB contention) must
      // not burn an untracked hash into 'failed'. It also leaves NO ledger
      // row, so report it RETRYABLE: the frontier then halts and a later
      // scan re-offers the photo instead of the watermark passing over an
      // unrecorded one.
      if (reserved) {
        try {
          await dao.markPhotoHash(hash, IngestionStatus.failed,
              ownerStamp: stamp);
        } catch (_) {}
      }
      return PhotoOutcome(PhotoOutcomeKind.failed, 'Photo intake failed: $e',
          retryable: !reserved, errorKind: AnalysisErrorKind.unknown,
          detail: '$e');
    }
  }

  /// What a run that lost its reservation says, read from the ledger NOW
  /// (2026-10-12). A blanket "still analyzing" was wrong twice for a photo
  /// the user picked or shared: when the other run had already SAVED it,
  /// 手动记录 then landed on that meal and dropped the typed numbers; when
  /// it had marked the photo not-food, the user's food verdict was lost and
  /// nothing ever logged it. A deliberate run therefore settles the verdict
  /// it holds ONCE more under a fresh deliberate reservation — no second
  /// upload. Automatic runs stay quiet and retryable: if the row was only
  /// released, the next scan re-offers the photo.
  Future<PhotoOutcome> _afterLost(
      IntakePhoto photo, String hash, _HeldVerdict? verdict,
      {required bool retried}) async {
    if (!photo.deliberate) return _inFlight;
    final IngestionStatus? status;
    try {
      status = (await dao.photoStatus(hash))?.status;
    } catch (_) {
      return _inFlight;
    }
    if (status == IngestionStatus.saved) return _alreadyTracked;
    if (status == IngestionStatus.processing || verdict == null) {
      return _inFlight;
    }
    final outcome = verdict.outcome;
    if (retried) {
      // Lost twice: report what is there, never a third try.
      return switch (status) {
        IngestionStatus.skipped => _notFood,
        IngestionStatus.failed => PhotoOutcome(
            PhotoOutcomeKind.failed, outcome.error ?? 'Analysis failed.',
            errorKind: classifyAnalysisError(outcome.error),
            detail: outcome.error ?? 'Analysis failed.'),
        _ => _inFlight,
      };
    }
    if (outcome.analysis == null && outcome.retryable) {
      // A transient failure settles as a release: nothing to re-write, and
      // reclaiming another run's verdict only to delete it would be worse.
      final why = outcome.error ?? 'Analysis failed.';
      return PhotoOutcome(PhotoOutcomeKind.failed, why,
          retryable: true,
          errorKind: classifyAnalysisError(outcome.error),
          detail: why);
    }
    return _process(photo, held: verdict);
  }

  static const _alreadyTracked = PhotoOutcome(
      PhotoOutcomeKind.alreadyTracked, 'This photo was already logged.');

  static const _notFood =
      PhotoOutcome(PhotoOutcomeKind.skipped, 'No food detected in this photo.');

  static const _inFlight = PhotoOutcome(PhotoOutcomeKind.inFlight,
      'This photo is still being analyzed — check back in a moment.',
      retryable: true);

  /// An automatic photo met while the app is in the background
  /// ([backgrounded]): released untouched, offered again by the next open
  /// or background run.
  static const _waitsForForeground = PhotoOutcome(PhotoOutcomeKind.failed,
      'The app is in the background: this photo waits for the next scan.',
      retryable: true,
      errorKind: AnalysisErrorKind.unknown,
      detail: 'in the background');

  /// An automatic glasses photo another file of whose shutter press is
  /// already a meal (design G2b): tombstoned, no model call.
  static const _duplicateCapture = PhotoOutcome(PhotoOutcomeKind.skipped,
      'Another copy of this shot is already logged.',
      reason: duplicateCaptureReason);

  /// An automatic glasses preview held back for its full-size version
  /// (design G2b): released untouched, offered again by a later scan. Not
  /// [AnalysisErrorKind.badPhoto], so the background run never counts it
  /// as a photo it cannot decode (deferred_assets.dart).
  static const _previewHeld = PhotoOutcome(PhotoOutcomeKind.failed,
      'A preview copy of a glasses photo: it waits for the full-size one.',
      retryable: true,
      errorKind: AnalysisErrorKind.unknown,
      detail: 'glasses preview',
      reason: glassesPreviewReason);

  /// [abandon]'s verdict: released, offered again by a later scan.
  static const _outOfTime = PhotoOutcome(PhotoOutcomeKind.failed,
      'The background run ran out of time before this photo was done.',
      retryable: true,
      errorKind: AnalysisErrorKind.unknown,
      detail: 'out of time');

  static const _latchedMessage =
      'Automatic analysis is paused: the AI service refused the last '
      'photo for a reason every photo shares (API key or network region).';
}

/// A verdict a run already holds, and the meals its leftover indexes
/// resolve against (spec §4.2 snapshot rule).
typedef _HeldVerdict = ({AnalysisOutcome outcome, List<Meal> recent});
