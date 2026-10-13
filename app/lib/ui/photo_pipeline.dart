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
import '../services/photo/filename_dates.dart'
    show captureWallClock, exifCapturedAt, exifWallAndOffset,
        validateCapturedAt;
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
      this.picked = false});
}

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

  final List<StreamSubscription<IntakePhoto>> _subs = [];

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
      Future<String> Function(Uint8List bytes)? hasher,
      DateTime Function()? clock})
      : _hash = hasher ?? _computeMd5,
        _clock = clock ?? DateTime.now;

  /// Injectable so tests stay synchronous; production hashes on a worker.
  final Future<String> Function(Uint8List bytes) _hash;

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

  /// One photo through the full pipeline. Never throws.
  Future<PhotoOutcome> process(IntakePhoto photo) => _process(photo);

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
      }

      // The day this photo belongs to. validateCapturedAt is NOT optional:
      // EXIF is attacker- and junk-controlled (a 2015 stock photo, a camera
      // with a dead clock, a forward-set date), and an unvalidated value
      // writes a meal into a random month of the user's log.
      // A capturedAt is re-expressed in the zone the photo was TAKEN in
      // when the EXIF shutter stamp names that zone and the same instant
      // (captureWallClock): iOS's createDateTime is an instant shown in the
      // CURRENT zone, so a photo first scanned after a flight was dated by
      // the destination's clock. Not re-validated against local now — the
      // instant already was, and a westbound wall clock can sit "ahead".
      final captured = photo.capturedAt;
      final when = (captured == null
              ? null
              : captureWallClock(captured, exifWallAndOffset(photo.bytes))) ??
          validateCapturedAt(exifCapturedAt(photo.bytes),
              now: DateTime.now()) ??
          DateTime.now();
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
      final outcome = held?.outcome ??
          await analyzer.analyzePhoto(photo.bytes, recentMeals: compacts);
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
        if (outcome.retryable) {
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
      // History thumbnail from the ORIGINAL bytes we already hold (spec §9
      // app-only). Best-effort AND awaited: the pipeline is serialized, so
      // finishing the thumb before the next photo keeps memory flat; any
      // failure must never un-save the meal.
      try {
        final thumb = await makeMealThumbAny(photo.bytes);
        if (thumb != null) await dao.saveMealThumb(id, thumb);
      } catch (_) {}
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

  static const _latchedMessage =
      'Automatic analysis is paused: the AI service refused the last '
      'photo for a reason every photo shares (API key or network region).';
}

/// A verdict a run already holds, and the meals its leftover indexes
/// resolve against (spec §4.2 snapshot rule).
typedef _HeldVerdict = ({AnalysisOutcome outcome, List<Meal> recent});
