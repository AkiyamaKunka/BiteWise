/// Pure decision logic for the data layer (no sqflite dependency).
///
/// Everything with pinned semantics that does not need a live Database lives
/// here so it can be unit-tested off-device: the reservation decision tree
/// (spec §2.3), the 5-minute duplicate window (spec §2.3), stored-analysis
/// coercion (spec §2.2), Python-truthiness is_food filtering (spec §3.5),
/// date windows (spec §1.2/§5.3), row→Meal mapping, and export shaping
/// (spec §8 / MealsDao.exportJson).
library;

import 'dart:convert';

import '../core/coerce.dart';
import '../core/contracts.dart';
import '../core/shared_generated.dart';

export '../core/coerce.dart' show isFoodTruthy, isoDate;

/// Spec §2: chat_id kept for schema/export parity; one constant local user.
const int localChatId = 1;

/// How long a 'processing' row counts as somebody's LIVE analysis before
/// any reservation may reclaim it. App-only (spec §2.3 adjusted): the
/// server's PHOTO_RESERVATION_STALE_SECONDS = 6 h (database.py:11) was
/// built for a process that is never killed mid-analysis. On the phone,
/// iOS expires BGAppRefresh runs and kills the app, and only a COLD launch
/// sweeps (reclaimStaleProcessing) — so under the server value an orphan
/// parked the photo for up to 6 h on every warm resume, background run and
/// deliberate pick (2026-10-12). The longest legitimate hold is ~15.3 min
/// (ServerAnalyzer: 3 attempts × the 5-min deadline + backoffs); 30 min
/// clears it with room to spare. Reclaiming a run that is still alive —
/// merely suspended, or a row that reads older than it is because
/// last_seen_at is a zone-less wall clock (a DST fall-back, an eastbound
/// zone change) — is harmless: that run's settling writes fail its
/// ownership stamp (PhotoReservationResult) and it drops its verdict
/// instead of saving a second time, at the cost of one redundant upload.
/// A longer age would only park the common orphan (iOS ends a background
/// grant mid-analysis, and the app is then only resumed) for longer.
const Duration appProcessingStaleAge = Duration(minutes: 30);

/// Spec §2.3: DUPLICATE_WINDOW_MINUTES (config.py:95), from shared/.
const int duplicateWindowMinutes = SharedConstants.duplicateWindowMinutes;

/// Spec §2.2: stored `analysis` is JSON text; a parse result that is not an
/// object/map coerces to {} — a poison row must never crash a reader.
Map<String, dynamic> coerceStoredAnalysis(dynamic stored) {
  if (stored is! String || stored.isEmpty) return <String, dynamic>{};
  dynamic parsed;
  try {
    parsed = jsonDecode(stored);
  } on FormatException {
    return <String, dynamic>{};
  }
  if (parsed is Map) return Map<String, dynamic>.from(parsed);
  return <String, dynamic>{};
}

/// Start date of an inclusive N-calendar-day window ending today
/// (spec §1.2 / §5.3: "last N days including today" → [today−(N−1), today]).
String windowStartDate(DateTime today, int days) =>
    isoDate(DateTime(today.year, today.month, today.day - (days - 1)));

/// Spec §2.3 pre-reservation dedup: given today's meal rows sharing the
/// photo's hash, "same photo again within 5 minutes" is a duplicate. A row
/// with a missing/blank timestamp counts as a duplicate; an unparseable
/// timestamp does not (telegram_bot.py:2854-2872).
bool hasDuplicateInWindow(Iterable<Map<String, Object?>> todaysRows, DateTime now) {
  for (final row in todaysRows) {
    final ts = row['timestamp'];
    if (ts is! String || ts.trim().isEmpty) return true;
    final parsed = DateTime.tryParse(ts);
    if (parsed == null) continue;
    if (now.difference(parsed) < const Duration(minutes: duplicateWindowMinutes)) {
      return true;
    }
  }
  return false;
}

/// Outcome of the reserve_photo_hash decision tree (spec §2.3).
enum ReserveDecision {
  /// Empty hash: nothing to reserve, reservation trivially succeeds.
  allowNoop,

  /// Hash already claimed (meals-table backstop or unreclaimable ledger row).
  refuse,

  /// A FRESH 'processing' row is in the way: another run holds the photo
  /// right now (or did, until iOS cut it off). Refused like [refuse], but
  /// the caller must NOT treat the photo as handled (2026-10-07).
  refuseInFlight,

  /// Existing ledger row flips back to 'processing' (stale or reclaimable).
  reclaim,

  /// No ledger row: insert a fresh 'processing' reservation.
  insert,
}

/// Port of the reserve_photo_hash decision tree (database.py:205-268, spec
/// §2.3), evaluated over a pre-read snapshot; the caller applies the decision
/// inside one transaction. [ledgerStatus] is null when no ledger row exists.
///
/// [reclaimDeliberate] maps the caller policies: a deliberate user re-add
/// reclaims {failed, skipped, deleted} (telegram_bot.py:4669-4674); the
/// automated intake passes false — strict, no reclaim (telegram_bot.py:4882).
ReserveDecision decideReservation({
  required bool hashEmpty,
  required bool mealRowExists,
  required String? ledgerStatus,
  required DateTime? ledgerLastSeenAt,
  required bool reclaimDeliberate,
  required DateTime now,
}) {
  // §2.3 step 1: empty-after-normalization hash means "no hash".
  if (hashEmpty) return ReserveDecision.allowNoop;
  // §2.3 step 2: meals-table backstop catches ledger/meal divergence.
  if (mealRowExists) return ReserveDecision.refuse;
  // §2.3 step 4: no ledger row → fresh reservation.
  if (ledgerStatus == null) return ReserveDecision.insert;
  // §2.3 step 3a: stale 'processing' rows are reclaimable — stale after
  // [appProcessingStaleAge], not the server's 6 h. An unparseable
  // last_seen_at reads as stale — a corrupt row must not block forever.
  // A FRESH one is somebody's live analysis: refused, but as IN FLIGHT,
  // so the automated paths wait in front of the photo instead of counting
  // it covered. (Only here — the backstop above is a real verdict.)
  if (ledgerStatus == IngestionStatus.processing.name) {
    final last = ledgerLastSeenAt;
    final stale = last == null ||
        // abs(): last_seen_at is a zone-less local wall clock, so after a
        // westbound flight an orphan sits HOURS in the future and would
        // never age; a row that far ahead is a moved clock, not a live run.
        now.difference(last).abs() > appProcessingStaleAge;
    return stale ? ReserveDecision.reclaim : ReserveDecision.refuseInFlight;
  }
  // §2.3 step 3b: deliberate re-send may re-log failed/skipped/deleted.
  const deliberateReclaim = {'failed', 'skipped', 'deleted'};
  if (reclaimDeliberate && deliberateReclaim.contains(ledgerStatus)) {
    return ReserveDecision.reclaim;
  }
  return ReserveDecision.refuse;
}

/// Map a meals-table row to the contract [Meal]: corrected 0/1 → bool
/// (database.py:435), analysis coerced per spec §2.2, hash normalized per
/// spec §2.2 (`(hash ?? '').trim().toLowerCase()`).
Meal mealFromRow(Map<String, Object?> row) => Meal(
      id: (row['id'] as num?)?.toInt() ?? 0,
      chatId: (row['chat_id'] as num?)?.toInt() ?? localChatId,
      date: (row['date'] as String?) ?? '',
      time: (row['time'] as String?) ?? '',
      timestamp: (row['timestamp'] as String?) ?? '',
      source: (row['source'] as String?) ?? '',
      imageHash: normalizeImageHash(row['image_hash'] as String?),
      fileId: (row['file_id'] as String?) ?? '',
      analysis: coerceStoredAnalysis(row['analysis']),
      corrected: ((row['corrected'] as num?) ?? 0) != 0,
    );

/// Versioned full-export envelope (MealsDao.exportJson, spec §8): every
/// table's raw rows under a stable version so a future importer can migrate.
Map<String, dynamic> buildExportEnvelope(
  Map<String, List<Map<String, Object?>>> tables,
  DateTime exportedAt,
) =>
    <String, dynamic>{
      'format': kExportFormat,
      'version': kExportVersion,
      'exported_at': exportedAt.toIso8601String(),
      'tables': tables,
    };

/// The export format the importer accepts. Bump-tolerant on purpose: a
/// file from a NEWER app version still imports (unknown tables/columns are
/// skipped row-by-row), because refusing outright would strand a user
/// moving between devices mid-upgrade.
const String kExportFormat = 'calorie_tracker_export';
const int kExportVersion = 1;

/// A parsed export: the per-table rows plus the stamp for the UI.
class ParsedExport {
  const ParsedExport(this.tables, this.exportedAt);
  final Map<String, List<Map<String, Object?>>> tables;
  final String? exportedAt;
}

/// Strictly validate an export payload — a wrong file is the ONE case
/// where import must refuse loudly, since the alternative is silently
/// writing a stranger's (or a random JSON's) rows into the food log.
/// Each refusal is an [ExportFormatException] with its [ExportRefusal], so
/// the UI can say why in the user's language.
ParsedExport parseExportEnvelope(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    throw const ExportFormatException(
        ExportRefusal.notJson, 'That file is not JSON.');
  }
  if (decoded is! Map) {
    throw const ExportFormatException(ExportRefusal.notExport,
        'That file is not a CalorieTracker export.');
  }
  if (decoded['format'] != kExportFormat) {
    throw const ExportFormatException(ExportRefusal.wrongFormatTag,
        'That file is not a CalorieTracker export (wrong format tag).');
  }
  final version = decoded['version'];
  if (version is! int || version < 1) {
    throw const ExportFormatException(ExportRefusal.badVersion,
        'That export has an unusable version tag.');
  }
  final rawTables = decoded['tables'];
  if (rawTables is! Map) {
    throw const ExportFormatException(
        ExportRefusal.noTables, 'That export has no tables section.');
  }
  final tables = <String, List<Map<String, Object?>>>{};
  rawTables.forEach((key, value) {
    if (key is! String || value is! List) return;
    tables[key] = [
      for (final row in value)
        if (row is Map) Map<String, Object?>.from(row),
    ];
  });
  final stamp = decoded['exported_at'];
  return ParsedExport(tables, stamp is String ? stamp : null);
}
