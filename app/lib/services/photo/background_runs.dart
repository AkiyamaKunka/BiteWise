/// A small, persisted record of the last background runs (2026-10-18).
///
/// The background scan runs where no debugger reaches: iOS starts it when
/// it likes, for ~30 s, and kills it without a word. Two timestamps were
/// all the app kept (last launch, last watermark), and when the watermark
/// froze for days (Oct 11, Oct 15) nothing on the phone said how far each
/// run had got. Each run now keeps ONE entry, rewritten at every step, so a
/// run the OS killed still shows the step it was on and what it had done.
///
/// Counts and timestamps only: never photo content, hashes, keys, URLs or
/// error messages (an error is recorded by its class name).
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One JSON list, newest first.
const String backgroundRunsPrefsKey = 'background.runs_v1';

/// How many runs are kept.
const int backgroundRunsKept = 20;

/// The step a run was on when it last wrote its entry. In run order; a run
/// moves between [photo] and [checkpoint] once per photo.
enum BackgroundRunStage {
  /// The OS launched it (before the settings load).
  boot,

  /// Settings loaded; the guards are next.
  settings,

  /// Listing the photo library.
  scan,

  /// A photo is being processed (hashed, decoded, analyzed, saved).
  photo,

  /// Moving the watermark forward after a photo.
  checkpoint,

  /// Finished — [BackgroundRunRecord.stopReason] says how.
  done,
}

/// Why a run ended. Anything else in the field is `error:<class name>`.
abstract final class BackgroundStop {
  static const done = 'done';
  static const budget = 'budget';
  static const paused = 'paused';
  static const noKey = 'no_key';
  static const watcherOff = 'watcher_off';
  static const noPermission = 'no_permission';
  static String error(Object e) => 'error:${e.runtimeType}';
}

class BackgroundRunRecord {
  const BackgroundRunRecord({
    required this.start,
    required this.platform,
    this.end,
    this.stage = BackgroundRunStage.boot,
    this.enumerated = 0,
    this.offered = 0,
    this.analyzed = 0,
    this.saved = 0,
    this.released = 0,
    this.stopReason,
    this.watermarkBefore,
    this.watermarkAfter,
  });

  /// UTC instants.
  final DateTime start;

  /// Null: the run never finished — the OS ended it at [stage] (or it is
  /// running right now).
  final DateTime? end;

  /// 'ios' or 'android'.
  final String platform;
  final BackgroundRunStage stage;

  /// Photos the scan listed in its window.
  final int enumerated;

  /// Photos whose bytes were read and handed to the pipeline.
  final int offered;

  /// Photos the pipeline finished with (any verdict).
  final int analyzed;

  /// New meals, or leftovers deducted from one.
  final int saved;

  /// Photos left eligible for a later run: a retryable verdict, or not
  /// started because the time budget ran out.
  final int released;
  final String? stopReason;

  /// The watermark (UTC) when the run started, and as it last wrote it.
  final DateTime? watermarkBefore;
  final DateTime? watermarkAfter;

  bool get finished => end != null;

  BackgroundRunRecord copyWith({
    DateTime? end,
    BackgroundRunStage? stage,
    int? enumerated,
    int? offered,
    int? analyzed,
    int? saved,
    int? released,
    String? stopReason,
    DateTime? watermarkAfter,
  }) =>
      BackgroundRunRecord(
        start: start,
        platform: platform,
        end: end ?? this.end,
        stage: stage ?? this.stage,
        enumerated: enumerated ?? this.enumerated,
        offered: offered ?? this.offered,
        analyzed: analyzed ?? this.analyzed,
        saved: saved ?? this.saved,
        released: released ?? this.released,
        stopReason: stopReason ?? this.stopReason,
        watermarkBefore: watermarkBefore,
        watermarkAfter: watermarkAfter ?? this.watermarkAfter,
      );

  Map<String, Object?> toJson() => {
        'start': start.toUtc().toIso8601String(),
        'end': end?.toUtc().toIso8601String(),
        'platform': platform,
        'stage': stage.name,
        'enumerated': enumerated,
        'offered': offered,
        'analyzed': analyzed,
        'saved': saved,
        'released': released,
        'stop': stopReason,
        'wm_before': watermarkBefore?.toUtc().toIso8601String(),
        'wm_after': watermarkAfter?.toUtc().toIso8601String(),
      };

  /// Null for an entry that cannot be read (a newer or damaged shape):
  /// one bad entry must not hide the others.
  static BackgroundRunRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = DateTime.tryParse('${json['start']}');
    if (start == null) return null;
    DateTime? instant(Object? v) => v is String ? DateTime.tryParse(v) : null;
    int count(Object? v) => v is int && v >= 0 ? v : 0;
    final stage = BackgroundRunStage.values
        .where((s) => s.name == json['stage'])
        .firstOrNull;
    final platform = json['platform'];
    final stop = json['stop'];
    return BackgroundRunRecord(
      start: start,
      end: instant(json['end']),
      platform: platform is String ? platform : '',
      stage: stage ?? BackgroundRunStage.boot,
      enumerated: count(json['enumerated']),
      offered: count(json['offered']),
      analyzed: count(json['analyzed']),
      saved: count(json['saved']),
      released: count(json['released']),
      stopReason: stop is String ? stop : null,
      watermarkBefore: instant(json['wm_before']),
      watermarkAfter: instant(json['wm_after']),
    );
  }
}

/// Parses the stored list, newest first; unreadable entries are skipped.
List<BackgroundRunRecord> decodeBackgroundRuns(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  try {
    final list = jsonDecode(stored);
    if (list is! List) return const [];
    return [
      for (final e in list) ?BackgroundRunRecord.fromJson(e),
    ];
  } catch (_) {
    return const [];
  }
}

/// The stored runs, read FRESH: the background engine wrote them from
/// another isolate, and this isolate's preferences cache would not know.
/// Empty when nothing is stored or the store cannot be read.
Future<List<BackgroundRunRecord>> readBackgroundRuns(
    {Future<SharedPreferences> Function()? prefs}) async {
  try {
    final p = await (prefs ?? SharedPreferences.getInstance)();
    await p.reload();
    return decodeBackgroundRuns(p.getString(backgroundRunsPrefsKey));
  } catch (_) {
    return const [];
  }
}

/// Writes THIS run's entry, incrementally: every call rewrites the entry
/// at once, so whatever the OS cuts short keeps the last step reached.
/// Never throws — a diagnostics write must not take the scan down — and
/// does nothing before [begin].
///
/// Only the background engine writes the key, and the OS never overlaps
/// two background runs, so the list is read once in [begin] and rewritten
/// from memory.
class BackgroundRunRecorder {
  BackgroundRunRecorder(this._prefs,
      {required this.platform, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final String platform;
  final DateTime Function() _clock;
  List<BackgroundRunRecord> _older = const [];
  BackgroundRunRecord? _current;

  /// This run's entry as last written (tests, and the run itself).
  BackgroundRunRecord? get current => _current;

  Future<void> begin({DateTime? watermarkBefore}) async {
    _older = decodeBackgroundRuns(_prefs.getString(backgroundRunsPrefsKey));
    _current = BackgroundRunRecord(
        start: _clock().toUtc(),
        platform: platform,
        watermarkBefore: watermarkBefore?.toUtc(),
        watermarkAfter: watermarkBefore?.toUtc());
    await _write();
  }

  Future<void> stage(BackgroundRunStage stage) => _update(
      (r) => r.stage == BackgroundRunStage.done ? r : r.copyWith(stage: stage));

  Future<void> listed(int enumerated) => _update((r) => r.copyWith(
      stage: BackgroundRunStage.scan, enumerated: r.enumerated + enumerated));

  /// A photo's bytes were handed to the pipeline: written BEFORE it is
  /// processed, so a kill mid-analysis reads "photo, offered n, analyzed
  /// n-1".
  Future<void> offered() => _update((r) => r.copyWith(
      stage: BackgroundRunStage.photo, offered: r.offered + 1));

  Future<void> processed({required bool saved, required bool released}) =>
      _update((r) => r.copyWith(
          analyzed: r.analyzed + 1,
          saved: r.saved + (saved ? 1 : 0),
          released: r.released + (released ? 1 : 0)));

  /// Photos released unprocessed (the time budget ran out).
  Future<void> releasedUnprocessed(int count) => count <= 0
      ? Future.value()
      : _update((r) => r.copyWith(released: r.released + count));

  Future<void> checkpoint(DateTime watermark) => _update((r) => r.copyWith(
      stage: BackgroundRunStage.checkpoint, watermarkAfter: watermark.toUtc()));

  Future<void> finish(String stopReason, {DateTime? watermarkAfter}) =>
      _update((r) => r.finished
          ? r
          : r.copyWith(
              end: _clock().toUtc(),
              stage: BackgroundRunStage.done,
              stopReason: stopReason,
              watermarkAfter: watermarkAfter?.toUtc()));

  /// A finished entry is final: a run abandoned at the iOS deadline
  /// (finishWithinGrant) may still report a step before its engine goes,
  /// and must not reopen the entry that already says how it ended.
  Future<void> _update(
      BackgroundRunRecord Function(BackgroundRunRecord r) change) async {
    final cur = _current;
    if (cur == null || cur.finished) return;
    _current = change(cur);
    await _write();
  }

  Future<void> _write() async {
    final cur = _current;
    if (cur == null) return;
    try {
      final list = [cur, ..._older].take(backgroundRunsKept);
      await _prefs.setString(backgroundRunsPrefsKey,
          jsonEncode([for (final r in list) r.toJson()]));
    } catch (_) {}
  }
}
