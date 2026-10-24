/// The Glasses check record (design G3, 2026-10-24): what happened to the
/// last Meta glasses photos, for the diagnostics card — the only view the
/// owner has of an automatic intake that may run in a background engine
/// with no screen at all.
///
/// One entry per photo (its asset id; a later verdict replaces an earlier
/// one), the newest [glassesCheckKept] from the last [glassesCheckWindow]:
/// how it was recognized, the camera's Make/Model, how long after the
/// shutter it joined the library, whether it carries a GPS block and how
/// far the fix lies from the shutter, the on-device food score, and the
/// outcome. Never a coordinate, a place or a picture: the location-shaped
/// fields are a yes/no and a time difference.
///
/// It lives in the backup-excluded store (local_store.dart, design F1): it
/// names this phone's asset ids and hints at when its owner carries a
/// camera. Both engines write it (read, change, write); two writes racing
/// can lose one entry, which a diagnostics record can afford.
library;

import 'dart:async';

import '../../core/contracts.dart';
import '../local_store.dart';
import 'food_prefilter.dart';
import 'glasses.dart' show captureAnalysis;

/// The local_store.dart document.
const String glassesCheckDocument = 'glasses_check';

/// Its schema version ('v').
const int glassesCheckVersion = 1;

/// Photos kept.
const int glassesCheckKept = 20;

/// How far back the record reaches.
const Duration glassesCheckWindow = Duration(days: 14);

/// The longest Make or Model kept: EXIF text is the camera's to write.
const int glassesCheckMaxText = 64;

/// What happened to a glasses photo ([GlassesCheckEntry.outcome]).
abstract final class GlassesCheckOutcome {
  /// A meal was logged (or a leftover deducted).
  static const logged = 'logged';

  /// The on-device check found no food: never uploaded.
  static const notFood = 'not_food';

  /// The AI service said it is not food.
  static const notFoodAi = 'not_food_ai';

  /// Another file of the same shutter press is already a meal.
  static const duplicate = 'duplicate';

  /// A preview copy, waiting for its full-size version.
  static const previewWait = 'preview_wait';

  /// The user switched Meta glasses photos off.
  static const excluded = 'excluded';

  /// The food check could not run in the background: waits for the app.
  static const appWait = 'app_wait';

  /// Its scan had sent its share of glasses photos: waits for the next.
  static const queued = 'queued';

  /// Released for a later try (a network error, the app went to the
  /// background, the run ran out of time).
  static const retry = 'retry';

  /// Analysis failed for good.
  static const failed = 'failed';

  static const all = {
    logged,
    notFood,
    notFoodAi,
    duplicate,
    previewWait,
    excluded,
    appWait,
    queued,
    retry,
    failed,
  };
}

/// One photo's row.
class GlassesCheckEntry {
  const GlassesCheckEntry({
    required this.assetId,
    required this.at,
    required this.outcome,
    this.signal,
    this.make,
    this.model,
    this.lagSeconds,
    this.hasGps = false,
    this.gpsFixDeltaSeconds,
    this.foodScore,
  });

  /// The library asset ('' for a shared file, which has none).
  final String assetId;

  /// When the verdict was reached.
  final DateTime at;

  /// A [GlassesCheckOutcome].
  final String outcome;

  /// How it was recognized: a CaptureSignal name (filename, album, exif).
  final String? signal;

  /// EXIF Make and Model, as the camera wrote them (shortened).
  final String? make;
  final String? model;

  /// When it joined the library minus its creation date, in seconds: the
  /// import lag. Null when the library did not say (before iOS 26).
  final int? lagSeconds;

  /// Whether its EXIF carries a GPS position (never the position itself).
  final bool hasGps;

  /// The GPS fix time minus the shutter, in seconds (glasses.dart
  /// captureAnalysis' gps_fix_delta_s); null without one.
  final int? gpsFixDeltaSeconds;

  /// The on-device food score, 0–1; null when no check ran.
  final double? foodScore;

  Map<String, Object?> toJson() => {
        'asset': assetId,
        'at': at.toUtc().toIso8601String(),
        'outcome': outcome,
        if (signal != null) 'signal': signal,
        if (make != null) 'make': make,
        if (model != null) 'model': model,
        if (lagSeconds != null) 'lag_s': lagSeconds,
        'gps': hasGps,
        if (gpsFixDeltaSeconds != null) 'gps_fix_delta_s': gpsFixDeltaSeconds,
        if (foodScore != null) 'food': foodScore,
      };

  /// Null for anything that is not an entry this version wrote.
  static GlassesCheckEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final asset = raw['asset'];
    final at = raw['at'];
    final outcome = raw['outcome'];
    if (asset is! String || at is! String || outcome is! String) return null;
    if (!GlassesCheckOutcome.all.contains(outcome)) return null;
    final when = DateTime.tryParse(at);
    if (when == null) return null;
    String? text(Object? v) => v is String && v.isNotEmpty ? _short(v) : null;
    int? seconds(Object? v) => v is int ? v : null;
    final food = raw['food'];
    return GlassesCheckEntry(
      assetId: asset,
      at: when.toLocal(),
      outcome: outcome,
      signal: text(raw['signal']),
      make: text(raw['make']),
      model: text(raw['model']),
      lagSeconds: seconds(raw['lag_s']),
      hasGps: raw['gps'] == true,
      gpsFixDeltaSeconds: seconds(raw['gps_fix_delta_s']),
      foodScore: food is num && food.isFinite && food >= 0 && food <= 1
          ? food.toDouble()
          : null,
    );
  }

  /// [photo]'s row: [outcome] reached [at], with the food check that ran
  /// on it ([check], null when none did). Never throws.
  static GlassesCheckEntry of(IntakePhoto photo,
      {required String outcome, FoodCheck? check, required DateTime at}) {
    final capture = photo.capture;
    final exif = capture?.exif;
    int? lag;
    final created = capture?.createDate, added = capture?.addedDate;
    if (created != null && added != null) {
      final s = added.difference(created).inSeconds;
      if (s.abs() <= _maxSeconds) lag = s;
    }
    int? fixDelta;
    try {
      final delta = capture == null
          ? null
          : captureAnalysis(capture)['gps_fix_delta_s'];
      if (delta is int) fixDelta = delta;
    } catch (_) {}
    final score = check?.status == FoodCheckStatus.ok ? check?.score : null;
    return GlassesCheckEntry(
      assetId: photo.assetId,
      at: at,
      outcome: outcome,
      signal: capture?.signal?.name,
      make: _text(exif?.make),
      model: _text(exif?.model),
      lagSeconds: lag,
      hasGps: exif?.gpsPresent ?? false,
      gpsFixDeltaSeconds: fixDelta,
      foodScore: score,
    );
  }
}

/// A difference no real import has (400 days); past it, a broken clock.
const int _maxSeconds = 400 * 24 * 3600;

/// Control characters out, at most [glassesCheckMaxText] characters.
String _short(String v) {
  final clean = v.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  return clean.length > glassesCheckMaxText
      ? clean.substring(0, glassesCheckMaxText)
      : clean;
}

String? _text(String? v) {
  if (v == null) return null;
  final s = _short(v);
  return s.isEmpty ? null : s;
}

/// Adds [entry] to the record in [store]: it replaces an earlier row of the
/// same asset, then rows older than [glassesCheckWindow] and all but the
/// newest [glassesCheckKept] go. Never throws.
Future<void> recordGlassesCheck(LocalNoBackupStore store,
    GlassesCheckEntry entry,
    {DateTime? now}) async {
  try {
    final at = now ?? DateTime.now();
    final doc =
        await store.read(glassesCheckDocument, version: glassesCheckVersion);
    final rows = [
      for (final row in pruneByTtl(doc['entries'], 'at', glassesCheckWindow,
          now: at))
        if (entry.assetId.isEmpty || row['asset'] != entry.assetId) row,
      entry.toJson(),
    ];
    await store.write(glassesCheckDocument,
        {'entries': capNewest(rows, glassesCheckKept, field: 'at')},
        version: glassesCheckVersion);
  } catch (_) {}
}

/// The record in [store] (default: this app's), newest first; empty when
/// there is none or it cannot be read. Never throws.
Future<List<GlassesCheckEntry>> readGlassesChecks(
    {LocalNoBackupStore? store, DateTime? now}) async {
  try {
    final doc = await (store ?? LocalNoBackupStore.platform())
        .read(glassesCheckDocument, version: glassesCheckVersion);
    final rows = [
      for (final row in pruneByTtl(
          doc['entries'], 'at', glassesCheckWindow, now: now ?? DateTime.now()))
        ?GlassesCheckEntry.fromJson(row),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return rows.length > glassesCheckKept
        ? rows.sublist(0, glassesCheckKept)
        : rows;
  } catch (_) {
    return const [];
  }
}

/// [recordGlassesCheck] into this app's store: PhotoPipeline's
/// glassesCheckLog in both engines (di.dart, background_glue.dart).
Future<void> recordGlassesCheckLocally(GlassesCheckEntry entry) =>
    recordGlassesCheck(LocalNoBackupStore.platform(), entry);
