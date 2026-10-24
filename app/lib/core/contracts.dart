/// Layer contracts: the seams the feature modules implement and consume.
///
/// These interfaces are the ONLY coupling between data/, services/, and ui/ —
/// each module depends on this file, never on another module's internals.
/// Semantics for every method are specified in docs/APP_PORT_SPEC.md; the
/// section references below are load-bearing.
library;

import 'dart:typed_data';

/// The `source` column's vocabulary. These strings are WIRE VALUES: they
/// are persisted in `meals.source` / `photo_ingestions.source`, exported by
/// exportJson, and MATCHED IN SQL — the reclaim sweep releases only
/// [appWatch] rows (spec §9). A literal typo in any one call site silently
/// changes intake policy rather than failing loudly, which is why they live
/// here instead of being spelled out at each use.
abstract final class MealSource {
  /// Deliberate photo add: in-app picker or the share sheet. Reclaims
  /// failed/skipped/deleted ledger rows (spec §2.3 deliberate re-send).
  static const String appPhoto = 'app_photo';

  /// Automated camera-roll intake (watcher, background job, catch-up scans).
  /// The strict reservation path — never reclaims.
  static const String appWatch = 'app_watch';

  /// A meal parsed from a TEXT description — the describe-a-meal screen and
  /// the NL new_meal intent. Server parity: telegram_bot uses this string
  /// for the same case (spec §4.6).
  static const String manualText = 'manual_text';

  /// Numbers typed by hand in the meal editor, no description parsed and no
  /// photo involved. Distinct from [manualText] on purpose: it records that
  /// NO model produced these values.
  static const String appManual = 'app_manual';

  /// Hand-entered numbers for a photo the model REFUSED (the coverage
  /// screen's "log it yourself" path): a photo exists and its md5 is
  /// ledgered, but every number came from the user.
  static const String appManualPhoto = 'app_manual_photo';
}

/// A logged meal row (spec §2: meals table).
class Meal {
  final int id;
  final int chatId; // fixed 1 on-device; kept for schema parity/export
  final String date; // user-local YYYY-MM-DD
  final String time; // user-local hh:mm AM/PM (server format parity)
  final String timestamp; // device clock ISO-8601
  final String source; // one of MealSource.* (plus imported/legacy values)
  final String imageHash; // md5 of ORIGINAL bytes, '' for text meals
  final String fileId; // local photo asset id / path hint, '' for text
  final Map<String, dynamic> analysis; // non-dict stored JSON coerced to {}
  final bool corrected;

  const Meal({
    required this.id,
    this.chatId = 1,
    required this.date,
    required this.time,
    required this.timestamp,
    required this.source,
    this.imageHash = '',
    this.fileId = '',
    required this.analysis,
    this.corrected = false,
  });
}

/// Photo-ingestion ledger statuses (spec §2/§6). The dedup contract:
/// one row per md5(original bytes); 'saved'/'processing' block re-ingestion,
/// 'failed'/'skipped'/'deleted' are reclaimable by a DELIBERATE user re-add
/// but not by the automatic watcher.
enum IngestionStatus { processing, saved, skipped, failed, deleted }

/// Answer to [MealsDao.reservePhotoHash].
///
/// Two refusals, told apart on purpose (2026-10-07): a row another run is
/// STILL WORKING ON is not a verdict. iOS can expire the ~30 s background
/// grant mid-analysis, which leaves that run's 'processing' row behind
/// until a cold launch sweeps it or it goes stale (appProcessingStaleAge,
/// 30 min); until then both
/// automated paths read the refusal as "already logged", marched the
/// watermark / seen-set past the photo, and never offered it again.
enum PhotoReservation {
  /// The hash is ours: analyze, then end the row saved/skipped/failed —
  /// or release it (spec §6 ledger rule).
  reserved,

  /// Claimed for good: a saved meal, or a verdict this caller's policy may
  /// not reclaim. Terminal — coverage may pass over the photo.
  claimed,

  /// A FRESH 'processing' row belongs to another run (the foreground app,
  /// a background isolate, or one iOS cut off mid-analysis). Not terminal:
  /// the photo must be offered again once that row is saved or released.
  inFlight,
}

/// [MealsDao.reservePhotoHash]'s answer. On [PhotoReservation.reserved]
/// with a non-empty hash, [stamp] is the exact last_seen_at the DAO wrote:
/// the run's proof that the 'processing' row is still ITS row. A row goes
/// stale after appProcessingStaleAge and another run may reclaim it, but a
/// run is not dead just because its process was SUSPENDED (iOS
/// backgrounding, Android's freezer) — it wakes up later still holding a
/// verdict (2026-10-12). Every write that settles the reservation passes
/// the stamp back; null (empty hash, or a refusal) means "nothing held".
typedef PhotoReservationResult = ({PhotoReservation kind, String? stamp});

/// Thrown by a settling write ([MealsDao.saveMeal], [MealsDao.markPhotoHash],
/// [MealsDao.releasePhotoHash]) given a reservation stamp when the row no
/// longer is 'processing' with that stamp: another run reclaimed it, the
/// user logged the photo by hand, or the launch sweep released it. Nothing
/// was written; the caller drops its verdict without a word.
class ReservationLost implements Exception {
  const ReservationLost();
  @override
  String toString() => 'ReservationLost';
}

/// What [MealsDao.saveMealWithOutcome] did: [inserted] is false when the
/// meals-table backstop found a meal for the same photo hash and returned
/// ITS [id] — nothing from this save was written to the meals table.
typedef MealSaveResult = ({int id, bool inserted});

/// Persistence seam (spec §2, §5 read shapes).
abstract class MealsDao {
  /// [ownerStamp]: the [PhotoReservationResult.stamp] this save settles —
  /// checked in the same transaction, [ReservationLost] when it no longer
  /// holds. Null = an unconditional save (the editor's deliberate log).
  Future<int> saveMeal(Meal meal,
      {IngestionStatus? markStatus, String? ownerStamp});

  /// [saveMeal] that also says whether the row was inserted or an existing
  /// meal for the same photo was returned. The editor's photo save needs
  /// the difference: the user's typed numbers must not vanish silently.
  Future<MealSaveResult> saveMealWithOutcome(Meal meal,
      {IngestionStatus? markStatus, String? ownerStamp});
  Future<void> updateMealAnalysis(int mealId, Map<String, dynamic> analysis);

  /// Editor save (spec §9): rewrites the analysis AND optionally moves the
  /// meal's local date/time — a mis-dated meal must be fixable in place
  /// rather than by delete + re-add (which would burn the photo's ledger
  /// row to 'deleted' and lose the original intake provenance). Sets
  /// corrected=1 like [updateMealAnalysis].
  Future<void> updateMealFields(int mealId,
      {Map<String, dynamic>? analysis, String? date, String? time});
  Future<void> deleteMeal(int mealId); // tombstones the ledger row (spec §2)
  Future<List<Meal>> mealsBetween(String startDate, String endDate);
  Future<List<Meal>> recentMeals({int days = 7}); // food-only, oldest-first
  Future<bool> isDuplicatePhoto(String imageHash); // 5-min same-hash window
  /// Reserve the hash before analysis (see [PhotoReservation]). Set
  /// [reclaimDeliberate] on user-initiated adds (reclaims failed/skipped/
  /// deleted rows, the "deliberate re-send" rule).
  Future<PhotoReservationResult> reservePhotoHash(String imageHash,
      {required String source, bool reclaimDeliberate = false});

  /// With [ownerStamp], only a 'processing' row carrying that stamp is
  /// settled, else [ReservationLost] (see [PhotoReservationResult]).
  Future<void> markPhotoHash(String imageHash, IngestionStatus status,
      {int? mealId, String? ownerStamp});
  Future<void> releasePhotoHash(String imageHash, {String? ownerStamp});

  /// An automatic leftover verdict, settled in ONE transaction: the
  /// [ownerStamp] check, the 'skipped' tombstone for [imageHash] and the
  /// deduction written to meal [mealId] (as [updateMealAnalysis]). Two
  /// separate writes lost the deduction silently when the app was killed,
  /// or the update threw, between them. [ReservationLost] as [markPhotoHash].
  Future<void> applyLeftoverVerdict(
      String imageHash, int mealId, Map<String, dynamic> analysis,
      {String? ownerStamp});
  Future<void> reclaimStaleProcessing(); // launch-time sweep (spec §2 delta)

  /// Forget every verdict from [source] that did not become a meal
  /// (skipped / failed), so the next scan re-offers those photos. Saved
  /// and user-deleted rows are never touched. Returns how many were
  /// released. One-time repair tool: verdicts reached while the model was
  /// being sent bytes it could not read are worthless (migrations.dart).
  Future<int> reofferUnsavedVerdicts({required String source});

  /// Read-only ledger lookup for the coverage audit (and for a pipeline run
  /// that lost its reservation): the status of one photo hash (and the meal
  /// it became, when saved). Null = never seen — the photo has NOT been
  /// through intake.
  Future<({IngestionStatus status, int? mealId})?> photoStatus(
      String imageHash);

  /// Those of [assetIds] a meal row already names as its photo
  /// (meals.file_id): logged, so the late-import pass (design G1b) need not
  /// read their bytes to find out. Read-only; empty ids never match.
  Future<Set<String>> loggedAssetIds(List<String> assetIds);

  /// The meals dated [fromDate]..[toDate] (YYYY-MM-DD, both inclusive)
  /// whose analysis.capture.shutter_key is [key] — another file of the same
  /// shutter press is already a meal (design G2b, the duplicate-capture
  /// guard). A cheap text prefilter, then the stored JSON itself decides;
  /// a [key] that is not 16 lowercase hex characters matches nothing.
  /// Ascending ids. Read-only.
  Future<List<int>> mealIdsWithShutterKey(
      String key, String fromDate, String toDate);

  /// Tiny per-meal JPEG (spec §9 app-only): written by the pipeline at
  /// save time, deleted with the meal, shown beside the analysis so the
  /// user can check the numbers against the actual photo.
  Future<void> saveMealThumb(int mealId, Uint8List jpeg);
  Future<Uint8List?> mealThumb(int mealId);
  // Fitness (phase 1: weight + activity only)
  /// One canonical weigh-in per user-local day (upsert on chat_id+date,
  /// spec §7.1). [source] is 'nl' for executor writes, 'manual' for the
  /// Body page.
  Future<void> saveBodyWeight(String date, double kg, {String source});

  /// Weigh-ins with [startDate] <= date <= [endDate], ascending — the
  /// same window shape as the server's get_body_weights.
  Future<List<WeightEntry>> listBodyWeights(String startDate, String endDate);
  Future<void> deleteBodyWeight(String date);

  /// App-only (spec §9): full-row upsert of the day's girth measurements.
  /// Null means "no value for this metric that day" and OVERWRITES — the
  /// Body page's sheet is prefilled with the existing row, so unchanged
  /// fields carry through and a cleared field really clears.
  Future<void> saveBodyMeasurements(String date,
      {double? waistCm, double? chestCm, double? hipCm});
  Future<List<BodyMeasurements>> listBodyMeasurements(
      String startDate, String endDate);
  Future<void> deleteBodyMeasurements(String date);
  Future<void> saveActivity(String date,
      {num? activeCalories, int? steps, double? distanceKm});
  Future<String> exportJson(); // full data export (spec §8)

  /// Merge a previously exported envelope into THIS database (§9 app-only).
  /// Never destructive: existing rows win, new rows are added, and the
  /// result reports what happened. Throws [FormatException] on a payload
  /// that is not a CalorieTracker export.
  Future<ImportSummary> importJson(String json);
}

/// One weigh-in row (body_weight): a date and the kilograms recorded for it.
class WeightEntry {
  const WeightEntry(this.date, this.kg, {this.source = 'manual'});
  final String date; // YYYY-MM-DD
  final double kg;
  final String source;
}

/// One day's girth measurements (body_measurements, app-only spec §9).
/// Any subset of the three may be present.
class BodyMeasurements {
  const BodyMeasurements(this.date, {this.waistCm, this.chestCm, this.hipCm});
  final String date; // YYYY-MM-DD
  final double? waistCm;
  final double? chestCm;
  final double? hipCm;

  bool get isEmpty => waistCm == null && chestCm == null && hipCm == null;
}

/// Outcome of [MealsDao.importJson] — per-table added/skipped counts so the
/// UI can say "142 meals added, 3 already here" instead of "done".
class ImportSummary {
  const ImportSummary(this.added, this.skipped, {this.exportedAt});
  final Map<String, int> added;
  final Map<String, int> skipped;
  final String? exportedAt;

  int get totalAdded => added.values.fold(0, (a, b) => a + b);
  int get totalSkipped => skipped.values.fold(0, (a, b) => a + b);
}

/// Why [MealsDao.importJson] refused a payload. The settings screen maps
/// each reason to a sentence in the user's language; the English
/// [ExportFormatException.message] is for logs and tests.
enum ExportRefusal { notJson, notExport, wrongFormatTag, badVersion, noTables }

/// The import parser's refusal — still a [FormatException], so every
/// `on FormatException` catcher and `throwsA(isA<FormatException>())` test
/// keeps working, but one that says WHY. Until 2026-10-07 the UI echoed
/// this English message straight into the Chinese UI.
class ExportFormatException extends FormatException {
  const ExportFormatException(this.refusal, String message) : super(message);
  final ExportRefusal refusal;
}

/// Result of one photo analysis (spec §3).
class AnalysisOutcome {
  final Map<String, dynamic>? analysis; // null = failed (kept for retry)
  final bool isFood; // already coerced via coerceIsFood
  final String? error; // user-facing failure summary

  /// True when the failure is transient (rate limit, network, quota pause,
  /// missing key) — the photo itself is fine and a later attempt can
  /// succeed. Automated intake RELEASES the reservation instead of burning
  /// it to 'failed' (which the watcher never reclaims, spec §2.3): on
  /// EMUI-class OSes mid-analysis kills and quota pauses are routine, and
  /// burning on them silently drops the user's photos forever.
  final bool retryable;
  final Duration wall;
  const AnalysisOutcome(
      {this.analysis,
      this.isFood = false,
      this.error,
      this.retryable = false,
      required this.wall});
}

/// The analysis seam (spec §3). FOUR implementations satisfy it — Gemini
/// REST, OpenAI, Anthropic, and the user's own server running Claude Code —
/// so the contract is deliberately transport-agnostic: callers hand ORIGINAL
/// bytes; the implementation normalizes (1568px q85 JPEG), asks its provider
/// for JSON, applies the §3.3 retry/quota-pause rules, and returns COERCED
/// output. Never throws for model/network trouble.
abstract class AnalyzerService {
  /// [recentMeals]: compact same-day meal summaries (leftover_logic
  /// .recentMealCompact shape) for the AUTOMATIC leftover check
  /// (2026-08-05) — direct providers format them into the prompt's
  /// RECENT MEALS block; the server provider ships them as data and the
  /// server composes its own block. Null/empty = no check.
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals});
  Future<Map<String, dynamic>?> textIntent(String prompt); // raw JSON or null
  Future<String?> validateKey(String apiKey); // null = OK, else error text

  /// Leftover-photo estimation (spec §9, 2026-08-04): given the leftover
  /// photo and the COMPACT original analysis, return the model's
  /// {same_meal, leftover_fraction, items, note} JSON, or null when this
  /// provider cannot estimate. Default null keeps existing fakes and
  /// third-party implementations compiling; real providers override.
  Future<Map<String, dynamic>?> leftoverIntent(
          Uint8List originalBytes, String originalCompact) async =>
      null;

  /// Richer probe for the diagnostics page. [validateKey] deliberately
  /// ACCEPTS a quota-class reply (it proves the key authenticated), which
  /// makes "key fine, account empty" indistinguishable from "all good" —
  /// so diagnostics could never name the out-of-credit case it promises
  /// to name. Default: derive from validateKey so third-party/fake
  /// implementations keep working.
  Future<KeyProbe> probeKey(String apiKey) async {
    final error = await validateKey(apiKey);
    return error == null
        ? const KeyProbe(KeyProbeResult.ok)
        : KeyProbe(KeyProbeResult.rejected, message: error);
  }
}

/// A text-intent reply that keeps WHY it failed. [json] is exactly what
/// [AnalyzerService.textIntent] returns; [error] is the analyzer's English
/// failure summary (the same prose the photo path shows, so
/// `classifyAnalysisError` reads it), or null when the cause is unknown or
/// the reply simply would not parse.
class TextIntentOutcome {
  const TextIntentOutcome(this.json, {this.error});
  final Map<String, dynamic>? json;
  final String? error;
}

/// Optional companion to [AnalyzerService.textIntent] for analyzers that can
/// say why a text request failed. textIntent folds EVERY failure into null,
/// so the chat and describe paths told a friend with a wrong key "联系 AI
/// 失败，请重试" forever, while the photo path on the same key said the key
/// was rejected (loop find 2026-10-08). A separate interface rather than a
/// default method on [AnalyzerService]: the test fakes `implements` it, and
/// an outcome VALUE (not a "last error" field) keeps the shared analyzer
/// free of per-call state.
abstract interface class TextIntentExplainer {
  Future<TextIntentOutcome> textIntentOutcome(String prompt);
}

/// [AnalyzerService.textIntent] with its failure reason when [analyzer] can
/// give one; otherwise the plain reply with no reason.
Future<TextIntentOutcome> askTextIntent(
    AnalyzerService analyzer, String prompt) async {
  if (analyzer is TextIntentExplainer) {
    return (analyzer as TextIntentExplainer).textIntentOutcome(prompt);
  }
  return TextIntentOutcome(await analyzer.textIntent(prompt));
}

/// What a [AnalyzerService.probeKey] learned about the credential.
enum KeyProbeResult {
  ok,

  /// The key authenticated but the account cannot pay — a recharge (or a
  /// free-tier provider) is the fix, NOT a new key.
  outOfCredit,

  /// The key authenticated but the provider is rate-limiting right now.
  rateLimited,

  /// The key was not refused; the MODEL id is wrong, retired or not
  /// activated. Picking a model is the fix, NOT a new key — reporting
  /// this as [rejected] sent users to re-copy a key that worked.
  modelNotFound,

  /// The key was not judged: the provider does not serve the network's
  /// region (Gemini behind a Hong Kong VPN exit). A different VPN node is
  /// the fix, NOT a new key.
  regionBlocked,

  /// The provider refused the credential, or the request could not be made.
  rejected,
}

class KeyProbe {
  const KeyProbe(this.result, {this.message});
  final KeyProbeResult result;
  final String? message;
}

/// One executed NL action's user-visible result (spec §4).
class NlReply {
  final String text;
  final bool needsDeleteConfirmation;
  final List<int> pendingDeleteIds; // meal ids awaiting the modal confirm
  final List<String> pendingDeleteLabels;

  /// True only when this reply reports a change the executor already wrote
  /// (a correction, a new meal, a weight or an activity). Refusals, errors,
  /// chat and a STAGED delete are false — a delete applies only once the
  /// modal confirms. The fix screen's "Applied this session" list used to
  /// record every request, so a cancelled delete or an "invalid meal index"
  /// refusal was shown as applied (loop find 2026-10-07).
  final bool applied;
  const NlReply(this.text,
      {this.needsDeleteConfirmation = false,
      this.pendingDeleteIds = const [],
      this.pendingDeleteLabels = const [],
      this.applied = false});
}

/// Result of describing a meal in free text: [analysis] on success (the
/// coerced food analysis, NOT yet saved), else [error] for display.
class DescribeOutcome {
  const DescribeOutcome({this.analysis, this.error, this.warning});
  final Map<String, dynamic>? analysis;
  final String? error;

  /// Non-fatal honesty: set when the reply described MORE meals than the
  /// single previewed one. Silently keeping the first would under-count the
  /// user's day with no way to notice.
  final String? warning;
  bool get ok => analysis != null;
}

/// The hardened NL executor (spec §4): builds the prompt from the meals
/// snapshot, normalizes single/multi/bare-array responses, caps at 5
/// actions, merges duplicate deletes, contains per-action failures, and
/// NEVER deletes without confirmation.
abstract class NlExecutor {
  Future<List<NlReply>> handleText(String userText);
  Future<String> confirmPendingDelete(List<int> mealIds);

  /// Analyze free text as a NEW meal ONLY — never a correction or delete —
  /// and return it for PREVIEW without saving. Works in any language (the
  /// shared prompt is multilingual). The dedicated entry exists because
  /// handleText is intent-routed: "a latte and two eggs" against a
  /// non-empty recent-meals list can legitimately parse as a correction of
  /// an existing meal, which is not what someone typing into a "describe a
  /// meal" box means.
  Future<DescribeOutcome> describeMeal(String text);
}

/// Photo intake events (spec §6). Implementations: Android background watch
/// (photo_manager change notify + periodic backfill scan), share-sheet
/// intake, and in-app picker. captured-at derives from the camera filename
/// regex with the 45-day/+1h validation before falling back to now.
class IntakePhoto {
  final Uint8List bytes;
  final String assetId;
  final String fileName;
  final DateTime? capturedAt;
  final bool deliberate; // user-picked/shared (reclaims failed/skipped rows)

  /// How the photo was taken, read from the bytes the intake already holds
  /// (design G2a, services/photo/glasses.dart captureMetaFor). Null when
  /// the intake did not look (older call sites, tests): nothing is stored
  /// for it then.
  final CaptureMeta? capture;
  const IntakePhoto(this.bytes, this.assetId, this.fileName,
      {this.capturedAt, this.deliberate = false, this.capture});
}

/// The capture facts a photo's own EXIF holds, as exifCapture
/// (services/photo/filename_dates.dart) reads them (design G2a). There is
/// deliberately NO latitude or longitude here, nor any way to carry one:
/// whether a position exists, how precise it was and when it was fixed are
/// all any later step needs to judge it, and a coordinate kept in memory
/// is one a later change can leak (the upload bytes are stripped of GPS,
/// exif_strip_test).
class ExifCapture {
  const ExifCapture(
      {this.make,
      this.model,
      this.dateTimeOriginal,
      this.subSec,
      this.offsetTimeOriginal,
      this.gpsPresent = false,
      this.gpsAccuracyM,
      this.gpsFixUtc,
      this.pixelW,
      this.pixelH});

  /// TIFF Make / Model, trimmed, at most 64 characters each.
  final String? make;
  final String? model;

  /// DateTimeOriginal: the camera's wall clock at the shutter (local
  /// components, no zone).
  final DateTime? dateTimeOriginal;

  /// SubSecTimeOriginal: its fraction of a second, digits only.
  final String? subSec;

  /// OffsetTimeOriginal: the zone [dateTimeOriginal] was in.
  final Duration? offsetTimeOriginal;

  /// The GPS block names a position (latitude and longitude tags both
  /// present). The position itself is never read.
  final bool gpsPresent;

  /// GPSHPositioningError (tag 0x1F), in metres.
  final double? gpsAccuracyM;

  /// When the position was fixed: GPSDateStamp + GPSTimeStamp, in UTC.
  final DateTime? gpsFixUtc;

  /// The full image's size in pixels (EXIF PixelX/YDimension, else the
  /// JPEG frame header or the HEIF image extents).
  final int? pixelW;
  final int? pixelH;
}

/// The device a photo came from, as far as the phone can tell.
enum CaptureDevice {
  /// Ray-Ban / Oakley Meta glasses, imported by the Meta AI app.
  metaGlasses,
  unknown,
}

/// How much the evidence for [CaptureDevice] is worth. The filename and
/// the album are set by the Meta AI app itself; EXIF Make/Model can be
/// written onto any photo by a converter, so it is only ever [medium].
enum CaptureStrength { strong, medium, none }

/// Which evidence decided [CaptureDevice]. The names are stored
/// (analysis.capture.signal).
enum CaptureSignal { filename, album, exif }

/// What an intake learned about how a photo was taken (design G2a): the
/// device, the evidence for it, the EXIF facts, and the library's
/// creation instant the GPS fix is compared with. The pipeline stores a
/// summary of it as analysis['capture'] (glasses.dart captureAnalysis);
/// none of it is ever a coordinate.
class CaptureMeta {
  const CaptureMeta(
      {this.device = CaptureDevice.unknown,
      this.strength = CaptureStrength.none,
      this.signal,
      this.exif,
      this.createDate,
      this.addedDate,
      this.importPassAt});

  final CaptureDevice device;
  final CaptureStrength strength;
  final CaptureSignal? signal;

  /// Null when the bytes carry no readable EXIF.
  final ExifCapture? exif;

  /// The library asset's creationDate (an instant); null for a shared file,
  /// which has no asset.
  final DateTime? createDate;

  /// When the asset joined the library (PHAsset.addedDate, iOS 26+), as
  /// the watcher learned it for a glasses photo the dating guard could
  /// re-date (design G2b, services/photo/capture_dating.dart): evidence that
  /// [createDate] is only the import time. Null: not asked, or not known.
  final DateTime? addedDate;

  /// Set when the late-import pass (design G1b) offered the photo: when
  /// that pass ran — the guard's evidence where [addedDate] is unknown.
  /// (Not 'lateImportAt': no member here may even read like a position —
  /// exif_capture_test scans the names.)
  final DateTime? importPassAt;

  bool get isMetaGlasses => device == CaptureDevice.metaGlasses;

  /// This reading with the import-time evidence an intake found added.
  CaptureMeta withImportEvidence(
          {DateTime? addedDate, DateTime? importPassAt}) =>
      CaptureMeta(
          device: device,
          strength: strength,
          signal: signal,
          exif: exif,
          createDate: createDate,
          addedDate: addedDate ?? this.addedDate,
          importPassAt: importPassAt ?? this.importPassAt);
}

abstract class PhotoIntake {
  Stream<IntakePhoto> get photos;

  /// Backpressured delivery: when a sink is attached, the intake DELIVERS
  /// each photo by awaiting it — reading the next photo's bytes only after
  /// the sink returns — instead of adding to [photos]. Without this, a scan
  /// reads the whole window's original bytes (25 MB each) ahead of a
  /// pipeline that takes 10–20 s per photo: a 200-photo backlog ≈ 1 GB
  /// resident → OOM-killed background runs in a loop.
  ///
  /// [safeFrontier] is the watermark value that is safe to persist IF this
  /// photo terminates successfully: it is createDate-based, halts at any
  /// transient failure earlier in the batch, and is null for the whole
  /// scan when the window was truncated (unseen older tail). Consumers
  /// checkpoint EXACTLY this value — deriving a watermark from the photo
  /// itself (e.g. filename dates) diverges from the createDate timebase
  /// the watermark filters on and skips photos permanently.
  ///
  /// The sink returns false when the photo was RELEASED for retry
  /// (transient failure) — the intake then forgets it was seen so a later
  /// scan re-offers it. Pass null to detach.
  void attachSink(
      Future<bool> Function(IntakePhoto photo, DateTime? safeFrontier)? sink);

  /// Scan the lookback window and emit every photo in it. [since], when
  /// LATER than the window cutoff, narrows the scan to photos created after
  /// it — the periodic background job passes its persisted watermark so a
  /// 30-minute cadence doesn't re-read the whole window's bytes every run.
  /// Returns the coverage FRONTIER: the newest createDate with everything
  /// at/before it terminally handled (a retryable release or transient read
  /// failure halts it) — watermarks must never advance past it. Null =
  /// nothing covered.
  ///
  /// [shouldContinue] (the iOS background run's time budget) is asked
  /// before each photo's original bytes are read. False leaves that photo
  /// UNREAD: not offered, not marked seen, not covered — the frontier stops
  /// in front of it and a later scan offers it. Every later unread photo is
  /// asked about too, so the caller can count what it left.
  ///
  /// [onCovered] hears the safeFrontier (see [attachSink]) each time a
  /// delivered photo terminates — the value a caller may persist as a
  /// watermark mid-scan, before the final frontier is known. Never called
  /// for a truncated window. A throwing callback never stops the scan.
  ///
  /// [newestDayFirst] (the app's launch/resume catch-up): the photos of the
  /// newest day not yet handled this session go first, in shooting order,
  /// then the usual oldest-first pass. Each photo is offered at most once
  /// per scan, and only the second pass reports frontiers, so coverage is
  /// exactly as without it. A whole day, in order, because the automatic
  /// leftover check compares a photo with the meals already logged on its
  /// own day.
  Future<DateTime?> backfillScan(
      {int lookbackDays,
      DateTime? since,
      bool Function()? shouldContinue,
      Future<void> Function(DateTime safeFrontier)? onCovered,
      bool newestDayFirst});

  /// Photos other apps added to the library LATE — keeping a capture date
  /// older than the scans' cutoffs, so neither the live watcher nor a
  /// watermark scan ever lists them: glasses photos the Meta AI app
  /// imports, AirDrop, WeChat, iCloud downloads (design G1b; on iOS, the
  /// library's change history, services/photo/photo_changes.dart). Each one
  /// goes through the attached sink like any automatic photo, but with a
  /// null safeFrontier: it never moves a cutoff or a watermark.
  /// [shouldContinue] as in [backfillScan]. Never throws.
  ///
  /// Default: nothing to do — right for an intake with no such history
  /// (Android's scans filter on the date a photo was ADDED).
  Future<void> lateImportScan({bool Function()? shouldContinue}) async {}
  Future<void> start();
  Future<void> stop();
}

/// Report/summary builders (spec §5). Pure functions over DAO reads; the
/// notification scheduler consumes dailyReport at the user's chosen time.
abstract class ReportBuilder {
  Future<String> todaySummary();
  Future<String> history({int days = 30});
  Future<String> dailyReport(String date);
  Future<String> stats();
}
