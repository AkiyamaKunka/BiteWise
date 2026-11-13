/// iCloud Backup's own state (1.7.0), every key under `settings.backup_`,
/// read from SharedPreferences directly. Every run starts with [reload]:
/// the app's engine and the headless background engine each keep their
/// own cache of the same store.
///
/// None of this is ever in a backup or an export (backup files hold the
/// export tables and pictures only), and setup links never carry it.
/// Android uses none of it.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'backup_format.dart';

/// What this install knows about one month's pictures file.
enum MonthState {
  /// This install wrote it.
  written,

  /// It came with a restore; its header names the adopted install.
  restored,

  /// No file existed when this install looked: it may create one.
  absent,

  /// Another install's file: never touched automatically.
  foreign,

  /// The adopted install's month that could not be read during the
  /// restore (a download that timed out on a fresh reinstall): its import
  /// is tried again in the foreground, its file is never written over
  /// until it came in, and this install's records header keeps listing it
  /// with [MonthRecord.count], so a later restore still fetches it.
  pending,
}

class MonthRecord {
  const MonthRecord(this.state,
      {this.print = '', this.skipped = 0, this.count = 0});
  final MonthState state;

  /// ThumbMonthPrint.key when the file was last written or restored.
  final String print;
  final int skipped;

  /// pending: the pictures the adopted install's header listed for it.
  final int count;

  Map<String, Object?> toJson() => {
        's': state.name,
        'p': print,
        if (skipped > 0) 'k': skipped,
        if (count > 0) 'n': count,
      };

  static MonthRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = MonthState.values.where((v) => v.name == j['s']);
    if (s.isEmpty) return null;
    return MonthRecord(s.first,
        print: j['p'] is String ? j['p'] as String : '',
        skipped: j['k'] is int ? j['k'] as int : 0,
        count: j['n'] is int ? j['n'] as int : 0);
  }
}

/// Why automatic backups are paused until the user acts.
enum BackupPause { none, missing, shrink }

class BackupPrefs {
  BackupPrefs(this._p);
  final SharedPreferences _p;

  static const String prefix = 'settings.backup_';
  static const String kEnabled = '${prefix}enabled';
  static const String kNoticeSeen = '${prefix}notice_seen';
  static const String kInstallId = '${prefix}install_id';
  static const String kDeviceKey = '${prefix}device_key';
  static const String kLastSeq = '${prefix}last_seq';
  static const String kPendingSeq = '${prefix}pending_seq';
  static const String kTopSeq = '${prefix}top_seq';
  static const String kAdoptedFrom = '${prefix}adopted_from';
  static const String kAdoptedSeq = '${prefix}adopted_seq';
  static const String kFirstEmptyAt = '${prefix}first_empty_at';
  static const String kMonths = '${prefix}months';
  static const String kLastRecordsChange = '${prefix}last_records_change';
  static const String kLastOkAt = '${prefix}last_ok_at';
  static const String kLastAttemptAt = '${prefix}last_attempt_at';
  static const String kLastBytes = '${prefix}last_bytes';
  static const String kLastError = '${prefix}last_error';
  static const String kLastMeals = '${prefix}last_meals';
  static const String kPreviousDay = '${prefix}previous_day';
  static const String kOffersAnswered = '${prefix}offers_answered';
  static const String kHoldCatchUpUntil = '${prefix}hold_catchup_until';
  static const String kPaused = '${prefix}paused';
  static const String kPausedCount = '${prefix}paused_count';
  static const String kSkippedMonths = '${prefix}skipped_months';

  /// Every key this file owns (the reset paths and the privacy test).
  static const List<String> allKeys = [
    kEnabled, kNoticeSeen, kInstallId, kDeviceKey, kLastSeq, kPendingSeq,
    kTopSeq, kAdoptedFrom, kAdoptedSeq, kFirstEmptyAt, kMonths,
    kLastRecordsChange, kLastOkAt, kLastAttemptAt, kLastBytes, kLastError,
    kLastMeals, kPreviousDay, kOffersAnswered, kHoldCatchUpUntil, kPaused,
    kPausedCount, kSkippedMonths,
  ];

  Future<void> reload() => _p.reload();

  bool get enabled => _p.getBool(kEnabled) ?? kCloudBackupDefaultOn;
  Future<void> setEnabled(bool v) => _p.setBool(kEnabled, v);

  /// The one-time notice was answered (Keep On or Turn Off).
  bool get noticeSeen => _p.getBool(kNoticeSeen) ?? false;
  Future<void> setNoticeSeen(bool v) => _p.setBool(kNoticeSeen, v);

  String get installId => _p.getString(kInstallId) ?? '';
  Future<void> setInstallId(String v) => _p.setString(kInstallId, v);

  String get deviceKey => _p.getString(kDeviceKey) ?? '';
  Future<void> setDeviceKey(String v) => _p.setString(kDeviceKey, v);

  /// The seq of the last records write that landed; 0 = never written.
  int get lastSeq => _p.getInt(kLastSeq) ?? 0;
  Future<void> setLastSeq(int v) => _p.setInt(kLastSeq, v);

  /// The seq of a records write in flight: if the app is killed right
  /// after it landed, the file carries this seq and is still ours.
  int get pendingSeq => _p.getInt(kPendingSeq) ?? 0;
  Future<void> setPendingSeq(int v) => _p.setInt(kPendingSeq, v);

  /// The highest seq this install id ever took, in any iCloud account.
  /// Unlike [lastSeq], [forgetBackup] keeps it: after an account change
  /// and back, the old account's file at a seq up to this one is still
  /// this install's, and a seq is never taken twice. A new install id
  /// starts again at 0.
  int get topSeq => _p.getInt(kTopSeq) ?? 0;
  Future<void> setTopSeq(int v) => _p.setInt(kTopSeq, v);

  /// The install whose backup this one restored or took over.
  String get adoptedFrom => _p.getString(kAdoptedFrom) ?? '';

  /// The seq of its records file then (WriteExpect.adoptMaxSeq): a later
  /// file of that install is another install's again.
  int? get adoptedSeq => _p.getInt(kAdoptedSeq);

  Future<void> setAdopted(BackupHeader header) async {
    await _p.setString(kAdoptedFrom, header.installId);
    await _p.setInt(kAdoptedSeq, header.seq);
  }

  /// The takeover given up before this install wrote over the file.
  Future<void> clearAdopted() async {
    await _p.remove(kAdoptedFrom);
    await _p.remove(kAdoptedSeq);
  }

  DateTime? get firstEmptyAt => _time(kFirstEmptyAt);
  Future<void> setFirstEmptyAt(DateTime? v) => _setTime(kFirstEmptyAt, v);

  Map<String, MonthRecord> get months {
    final raw = _p.getString(kMonths);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && MonthRecord.fromJson(e.value) != null)
            e.key as String: MonthRecord.fromJson(e.value)!,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> setMonths(Map<String, MonthRecord> m) => _p.setString(
      kMonths, jsonEncode({for (final e in m.entries) e.key: e.value.toJson()}));

  /// data_changes.records when the last records write landed; -1 = never.
  int get lastRecordsChange => _p.getInt(kLastRecordsChange) ?? -1;
  Future<void> setLastRecordsChange(int v) => _p.setInt(kLastRecordsChange, v);

  DateTime? get lastOkAt => _time(kLastOkAt);
  Future<void> setLastOkAt(DateTime? v) => _setTime(kLastOkAt, v);

  DateTime? get lastAttemptAt => _time(kLastAttemptAt);
  Future<void> setLastAttemptAt(DateTime? v) => _setTime(kLastAttemptAt, v);

  /// What the last successful run wrote, in bytes (the app's own count).
  int get lastBytes => _p.getInt(kLastBytes) ?? 0;
  Future<void> setLastBytes(int v) => _p.setInt(kLastBytes, v);

  /// The last run's failure, as a BackupState name; '' = none.
  String get lastError => _p.getString(kLastError) ?? '';
  Future<void> setLastError(String v) => _p.setString(kLastError, v);

  /// The meals in the last records file this install wrote.
  int get lastMeals => _p.getInt(kLastMeals) ?? 0;
  Future<void> setLastMeals(int v) => _p.setInt(kLastMeals, v);

  /// The day (YYYY-MM-DD) the previous copy was last rotated.
  String get previousDay => _p.getString(kPreviousDay) ?? '';
  Future<void> setPreviousDay(String v) => _p.setString(kPreviousDay, v);

  /// The installs whose restore offer was answered.
  List<String> get offersAnswered =>
      _p.getStringList(kOffersAnswered) ?? const [];
  Future<void> setOffersAnswered(List<String> v) =>
      _p.setStringList(kOffersAnswered, v);

  /// While in the future, neither engine starts the photo catch-up: a
  /// restore offer is open or a restore is running (a renewable lease, so
  /// a crash holds it 30 minutes at most).
  DateTime? get holdCatchUpUntil => _time(kHoldCatchUpUntil);
  Future<void> setHoldCatchUpUntil(DateTime? v) =>
      _setTime(kHoldCatchUpUntil, v);

  BackupPause get paused => switch (_p.getString(kPaused)) {
        'missing' => BackupPause.missing,
        'shrink' => BackupPause.shrink,
        _ => BackupPause.none,
      };

  /// shrink: the meals in the file the write would have replaced.
  int get pausedCount => _p.getInt(kPausedCount) ?? 0;
  Future<void> setPaused(BackupPause v, {int count = 0}) async {
    await _p.setString(kPaused, v == BackupPause.none ? '' : v.name);
    await _p.setInt(kPausedCount, count);
  }

  /// Months with pictures on this phone whose file is another install's
  /// (MonthState.foreign), as the last run left them.
  int get skippedMonths => _p.getInt(kSkippedMonths) ?? 0;
  Future<void> setSkippedMonths(int v) => _p.setInt(kSkippedMonths, v);

  DateTime? _time(String key) {
    final raw = _p.getString(key);
    return raw == null || raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  Future<void> _setTime(String key, DateTime? v) => v == null
      ? _p.remove(key)
      : _p.setString(key, v.toUtc().toIso8601String());

  /// What a backup this install wrote no longer applies to: a new install
  /// (another phone set up from this one's device backup) or a new iCloud
  /// account. [keepNotice]: the answer to the notice still holds.
  Future<void> forgetBackup({required bool keepNotice}) async {
    for (final k in [
      kLastSeq, kPendingSeq, kAdoptedFrom, kAdoptedSeq, kFirstEmptyAt,
      kMonths, kLastRecordsChange, kLastOkAt, kLastAttemptAt, kLastBytes,
      kLastError, kLastMeals, kPreviousDay, kPaused, kPausedCount,
      kHoldCatchUpUntil, kSkippedMonths,
      if (!keepNotice) kNoticeSeen,
    ]) {
      await _p.remove(k);
    }
  }
}

/// Whether a restore offer or a restore holds the photo catch-up (either
/// engine; background_glue reads it).
bool backupHoldsCatchUp(SharedPreferences prefs, DateTime now) {
  final raw = prefs.getString(BackupPrefs.kHoldCatchUpUntil);
  final until = raw == null ? null : DateTime.tryParse(raw);
  return until != null && until.isAfter(now);
}
