/// The restaurant assist's own bookkeeping (design R6b, "Storage" and
/// "Day window"; data_contracts §9).
///
/// Two homes, as the design splits them:
///
///   * shared_preferences — only the daily counter, `assist.daily.v1`
///     {date, count, usd}: [AssistDailyBudget], the app's daily lookup
///     ledger (20 a day). Every lookup client consults it before it sends
///     and reports what the lookup cost after (clients/lookup_cost.dart
///     LookupBudget), so the cap counts what was really sent, whichever
///     provider sent it.
///   * the backup-excluded F1 store (services/local_store.dart) — the rest,
///     each a small document with a TTL and a cap:
///       - 'assist_unseen'    {meals: [{id, at}]}: meals an automatic
///         apply changed that the user has not opened since (the card's
///         dot, R7b); 30 d, newest 100;
///       - 'assist_decisions' {log: [{at, code, old_kcal, new_kcal,
///         provider}]}: the last 20 decisions for diagnostics — reason
///         codes and kcal ONLY, never a chain, item, place or meal id;
///       - 'assist_casmiss'   {misses: [{id, n, at}]}: meals whose result
///         was dropped because they changed meanwhile (compare-and-set
///         miss); at [assistMissesBeforeDenylist] the meal is skipped from
///         then on; 3 d, newest 200;
///       - 'assist_jobs'      {jobs: [{meal_id, job_id, req_hash, attempts,
///         next_at, at}]}: Claude Plan lookups the owner's server is still
///         running; 24 h (the server keeps a job that long), newest 50.
///
/// Meal ids are row ids of this phone's database: they name no place and
/// no restaurant. Nothing here is exported, backed up or logged. Reads never
/// throw and come back empty on a missing, corrupt or other-version
/// document; malformed entries are dropped. Writes never throw either, say
/// whether they landed, and run one at a time through an instance. The app
/// engine is the only writer (MealAssist; background_glue never builds one).
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/coerce.dart' show isoDate;
import '../local_store.dart';
import 'clients/lookup_client.dart' show LookupCost;
import 'clients/lookup_cost.dart' show LookupBudget;

// ─── The daily counter (shared_preferences) ────────────────────────────

/// The prefs key of the daily lookup counter.
const String assistDailyPrefsKey = 'assist.daily.v1';

/// The design's daily cap: at most this many lookups are SENT per local
/// calendar day, across providers.
const int assistDailyCap = 20;

/// A dollar ceiling per day on top of the count (the direct clients'
/// worst-case pre-flight is checked against it; the owner's server costs
/// nothing per call here).
const double assistDailyMaxUsd = 0.50;

/// The app's daily lookup ledger: [assistDailyCap] lookups and
/// [assistDailyMaxUsd] dollars per local day, kept in `assist.daily.v1`
/// so a restart does not reset it. A stored day other than today reads as
/// a fresh day. Synchronous reads (the prefs cache); writes are fired and
/// never throw.
class AssistDailyBudget implements LookupBudget {
  AssistDailyBudget(
    this._prefs, {
    this.cap = assistDailyCap,
    this.maxUsdPerDay = assistDailyMaxUsd,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final int cap;
  final double maxUsdPerDay;
  final DateTime Function() _clock;

  ({String date, int count, double usd}) _today() {
    final today = isoDate(_clock());
    try {
      final raw = _prefs.getString(assistDailyPrefsKey);
      if (raw != null) {
        final m = jsonDecode(raw);
        if (m is Map && m['date'] == today) {
          final c = m['count'];
          final u = m['usd'];
          return (
            date: today,
            count: c is int && c >= 0 ? c : 0,
            usd: u is num && u.isFinite && u >= 0 ? u.toDouble() : 0.0,
          );
        }
      }
    } catch (_) {}
    return (date: today, count: 0, usd: 0.0);
  }

  void _write(String date, int count, double usd) {
    try {
      unawaited(
        _prefs
            .setString(
              assistDailyPrefsKey,
              jsonEncode({'date': date, 'count': count, 'usd': usd}),
            )
            .then((_) {}, onError: (Object _) {}),
      );
    } catch (_) {}
  }

  /// Lookups sent today.
  int get lookupsToday => _today().count;

  /// No lookup may start until tomorrow.
  bool get capReached => lookupsToday >= cap;

  /// Counts the lookup when one more may start (an abandoned call still
  /// costs, so it is counted before it is sent).
  @override
  bool tryStartLookup(double worstCaseUsd) {
    final t = _today();
    if (t.count >= cap) return false;
    final worst = worstCaseUsd.isFinite && worstCaseUsd > 0 ? worstCaseUsd : 0;
    if (t.usd + worst > maxUsdPerDay + 1e-12) return false;
    _write(t.date, t.count + 1, t.usd);
    return true;
  }

  @override
  void recordSpend(LookupCost cost) {
    final usd = cost.usd;
    if (!usd.isFinite || usd <= 0) return;
    final t = _today();
    _write(t.date, t.count, t.usd + usd);
  }
}

// ─── F1 documents ──────────────────────────────────────────────────────

const String assistUnseenDocument = 'assist_unseen';
const String assistDecisionsDocument = 'assist_decisions';
const String assistMissDocument = 'assist_casmiss';
const String assistJobsDocument = 'assist_jobs';

/// Every document's schema version.
const int assistLocalVersion = 1;

/// The decision log keeps the last this many decisions.
const int assistDecisionLogCap = 20;

/// Compare-and-set misses after which a meal is skipped for good.
const int assistMissesBeforeDenylist = 2;

const int assistUnseenCap = 100;
const Duration assistUnseenTtl = Duration(days: 30);
const int assistMissCap = 200;

/// Automatic eligibility ends after 24 h; a miss outlives it a little.
const Duration assistMissTtl = Duration(days: 3);
const int assistJobsCap = 50;

/// The owner's server keeps a job's result for 24 h (R3b).
const Duration assistJobTtl = Duration(hours: 24);

final RegExp _codeRe = RegExp(r'^[a-z0-9_]{1,40}$');
final RegExp _providerRe = RegExp(r'^[a-z0-9_]{0,20}$');
final RegExp _jobIdRe = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
final RegExp _hashRe = RegExp(r'^[0-9a-f]{8,64}$');

/// A kcal value worth logging: a whole number 0..20000.
int? _kcal(Object? v) {
  if (v is! num || !v.isFinite) return null;
  final r = v.round();
  return r >= 0 && r <= 20000 ? r : null;
}

int? _mealId(Object? v) => v is int && v > 0 ? v : null;

/// One entry of the decision log: what was decided (a reason code), the
/// covered items' kcal before and after, and who answered. Nothing else.
final class AssistDecisionEntry {
  const AssistDecisionEntry({
    required this.at,
    required this.code,
    this.oldKcal,
    this.newKcal,
    this.provider = '',
  });

  final DateTime at;
  final String code;
  final int? oldKcal;
  final int? newKcal;
  final String provider;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'code': code,
    'old_kcal': oldKcal,
    'new_kcal': newKcal,
    'provider': provider,
  };

  /// Null for anything that is not a well-formed entry.
  static AssistDecisionEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    final code = raw['code'];
    final provider = raw['provider'] ?? '';
    final when = at is String ? DateTime.tryParse(at) : null;
    if (when == null ||
        code is! String ||
        !_codeRe.hasMatch(code) ||
        provider is! String ||
        !_providerRe.hasMatch(provider)) {
      return null;
    }
    return AssistDecisionEntry(
      at: when,
      code: code,
      oldKcal: _kcal(raw['old_kcal']),
      newKcal: _kcal(raw['new_kcal']),
      provider: provider,
    );
  }
}

/// A Claude Plan lookup the owner's server is still running for a meal.
final class AssistJob {
  const AssistJob({
    required this.jobId,
    required this.reqHash,
    required this.at,
    required this.nextAt,
    this.attempts = 0,
  });

  final String jobId;

  /// The hash of the request the job was submitted for (meal_assist.dart
  /// lookupRequestHash): a meal whose request changed since is no longer
  /// what the job answers.
  final String reqHash;
  final int attempts;
  final DateTime nextAt;

  /// When the job was submitted.
  final DateTime at;
}

class AssistLocalState {
  AssistLocalState(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The app's store (LocalNoBackupStore.platform()).
  factory AssistLocalState.platform() =>
      AssistLocalState(LocalNoBackupStore.platform());

  final LocalNoBackupStore _store;
  final DateTime Function() _clock;
  Future<void> _tail = Future<void>.value();

  /// Runs [body] after every earlier write of this instance; never throws.
  Future<T> _serial<T>(Future<T> Function() body, T onError) {
    final run = _tail.then((_) async {
      try {
        return await body();
      } catch (_) {
        return onError;
      }
    });
    _tail = run.then((_) {});
    return run;
  }

  Future<List<Map<String, Object?>>> _entries(
    String document,
    String list,
    String stampField,
    Duration ttl,
  ) async {
    final doc = await _store.read(document, version: assistLocalVersion);
    return pruneByTtl(doc[list], stampField, ttl, now: _clock());
  }

  // ── Unseen ──

  /// Meals an automatic apply changed that were not opened since.
  Future<Set<int>> unseen() async {
    try {
      return {
        for (final e in await _entries(
          assistUnseenDocument,
          'meals',
          'at',
          assistUnseenTtl,
        ))
          ?_mealId(e['id']),
      };
    } catch (_) {
      return {};
    }
  }

  Future<bool> addUnseen(int mealId) => _serial(() async {
    final now = _clock();
    final entries = await _entries(
      assistUnseenDocument,
      'meals',
      'at',
      assistUnseenTtl,
    );
    entries
      ..removeWhere((e) => e['id'] == mealId)
      ..add({'id': mealId, 'at': now.toUtc().toIso8601String()});
    return _store.write(assistUnseenDocument, {
      'meals': capNewest(entries, assistUnseenCap),
    }, version: assistLocalVersion);
  }, false);

  /// The meal was opened (or undone): no dot.
  Future<bool> markSeen(int mealId) => _serial(() async {
    final entries = await _entries(
      assistUnseenDocument,
      'meals',
      'at',
      assistUnseenTtl,
    );
    final before = entries.length;
    entries.removeWhere((e) => e['id'] == mealId);
    if (entries.length == before) return true;
    return _store.write(assistUnseenDocument, {
      'meals': entries,
    }, version: assistLocalVersion);
  }, false);

  // ── Decision log ──

  /// The last decisions, oldest first.
  Future<List<AssistDecisionEntry>> decisions() async {
    try {
      final doc = await _store.read(
        assistDecisionsDocument,
        version: assistLocalVersion,
      );
      final log = doc['log'];
      return capNewest([
        if (log is List)
          for (final e in log) ?AssistDecisionEntry.fromJson(e),
      ], assistDecisionLogCap);
    } catch (_) {
      return [];
    }
  }

  Future<bool> logDecision(AssistDecisionEntry entry) => _serial(() async {
    if (!_codeRe.hasMatch(entry.code) ||
        !_providerRe.hasMatch(entry.provider)) {
      return false;
    }
    final log = [...await decisions(), entry];
    return _store.write(assistDecisionsDocument, {
      'log': [for (final e in capNewest(log, assistDecisionLogCap)) e.toJson()],
    }, version: assistLocalVersion);
  }, false);

  // ── Compare-and-set misses ──

  /// Each meal's miss count.
  Future<Map<int, int>> misses() async {
    try {
      final out = <int, int>{};
      for (final e in await _entries(
        assistMissDocument,
        'misses',
        'at',
        assistMissTtl,
      )) {
        final id = _mealId(e['id']);
        final n = e['n'];
        if (id != null && n is int && n > 0) out[id] = n;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Counts one more miss for [mealId] (or sets it straight to the
  /// denylist with [denylist]). Returns the count now, 0 when the write did
  /// not land.
  Future<int> addMiss(int mealId, {bool denylist = false}) => _serial(() async {
    final entries = await _entries(
      assistMissDocument,
      'misses',
      'at',
      assistMissTtl,
    );
    var n = 0;
    entries.removeWhere((e) {
      if (e['id'] != mealId) return false;
      final c = e['n'];
      if (c is int && c > n) n = c;
      return true;
    });
    n = denylist ? assistMissesBeforeDenylist : n + 1;
    if (n > assistMissesBeforeDenylist) n = assistMissesBeforeDenylist;
    entries.add({
      'id': mealId,
      'n': n,
      'at': _clock().toUtc().toIso8601String(),
    });
    final ok = await _store.write(assistMissDocument, {
      'misses': capNewest(entries, assistMissCap),
    }, version: assistLocalVersion);
    return ok ? n : 0;
  }, 0);

  // ── Jobs ──

  Future<Map<int, AssistJob>> jobs() async {
    try {
      final out = <int, AssistJob>{};
      for (final e in await _entries(
        assistJobsDocument,
        'jobs',
        'at',
        assistJobTtl,
      )) {
        final id = _mealId(e['meal_id']);
        final job = e['job_id'];
        final hash = e['req_hash'];
        final attempts = e['attempts'];
        final at = DateTime.tryParse('${e['at']}');
        final next = DateTime.tryParse('${e['next_at']}');
        if (id == null ||
            job is! String ||
            !_jobIdRe.hasMatch(job) ||
            hash is! String ||
            !_hashRe.hasMatch(hash) ||
            at == null ||
            next == null) {
          continue;
        }
        out[id] = AssistJob(
          jobId: job,
          reqHash: hash,
          at: at,
          nextAt: next,
          attempts: attempts is int && attempts >= 0 ? attempts : 0,
        );
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<bool> _writeJobs(Map<int, AssistJob> jobs) {
    final entries = [
      for (final e in jobs.entries)
        <String, Object?>{
          'meal_id': e.key,
          'job_id': e.value.jobId,
          'req_hash': e.value.reqHash,
          'attempts': e.value.attempts,
          'next_at': e.value.nextAt.toUtc().toIso8601String(),
          'at': e.value.at.toUtc().toIso8601String(),
        },
    ];
    if (entries.isEmpty) return _store.delete(assistJobsDocument);
    return _store.write(assistJobsDocument, {
      'jobs': capNewest(entries, assistJobsCap, field: 'at'),
    }, version: assistLocalVersion);
  }

  Future<bool> putJob(int mealId, AssistJob job) => _serial(() async {
    if (!_jobIdRe.hasMatch(job.jobId) || !_hashRe.hasMatch(job.reqHash)) {
      return false;
    }
    final all = await jobs();
    all[mealId] = job;
    return _writeJobs(all);
  }, false);

  Future<bool> removeJob(int mealId) => _serial(() async {
    final all = await jobs();
    if (all.remove(mealId) == null) return true;
    return _writeJobs(all);
  }, false);

  /// Keeps only the jobs of [mealIds] (a job for a meal that is gone, or
  /// out of the window, answers nothing anyone will read).
  Future<bool> retainJobs(Set<int> mealIds) => _serial(() async {
    final all = await jobs();
    final before = all.length;
    all.removeWhere((id, _) => !mealIds.contains(id));
    if (all.length == before) return true;
    return _writeJobs(all);
  }, false);

  /// Mode Off: every pending job is forgotten.
  Future<bool> clearJobs() =>
      _serial(() => _store.delete(assistJobsDocument), false);
}
