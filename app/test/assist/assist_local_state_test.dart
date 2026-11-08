/// services/assist/assist_local_state.dart: the daily lookup counter in
/// shared_preferences (assist.daily.v1) and the backup-excluded documents
/// the assist keeps (unseen, decision log, miss list, jobs and retries with
/// their place context, the lookup cache) — shapes, TTLs, caps, corrupt
/// documents reading empty, and no export path touching them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

void main() {
  group('AssistDailyBudget (assist.daily.v1)', () {
    late DateTime now;
    setUp(() {
      now = DateTime(2026, 10, 24, 9);
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'counts each lookup it lets start, up to the cap, and persists',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final b = AssistDailyBudget(prefs, cap: 3, clock: () => now);
        expect(b.lookupsToday, 0);
        expect(b.capReached, isFalse);
        expect(
          [for (var i = 0; i < 4; i++) b.tryStartLookup(0)],
          [true, true, true, false],
        );
        expect(b.lookupsToday, 3);
        expect(b.capReached, isTrue);
        final stored = jsonDecode(prefs.getString(assistDailyPrefsKey)!) as Map;
        expect(stored['date'], '2026-10-24');
        expect(stored['count'], 3);
        // A restart reads the same day back.
        expect(
          AssistDailyBudget(prefs, cap: 3, clock: () => now).capReached,
          isTrue,
        );
      },
    );

    test('a new local day starts from zero', () async {
      final prefs = await SharedPreferences.getInstance();
      final b = AssistDailyBudget(prefs, cap: 1, clock: () => now);
      expect(b.tryStartLookup(0), isTrue);
      expect(b.tryStartLookup(0), isFalse);
      now = DateTime(2026, 10, 25, 0, 1);
      expect(b.lookupsToday, 0);
      expect(b.tryStartLookup(0), isTrue);
    });

    test('the dollar ceiling: worst case before, real spend after', () async {
      final prefs = await SharedPreferences.getInstance();
      final b = AssistDailyBudget(prefs, maxUsdPerDay: 0.10, clock: () => now);
      expect(b.tryStartLookup(0.06), isTrue);
      b.recordSpend(const LookupCost(estimatedUsd: 0.06));
      expect(b.tryStartLookup(0.05), isFalse, reason: '0.06 + 0.05 > 0.10');
      expect(b.tryStartLookup(0.03), isTrue);
      expect(b.lookupsToday, 2);
    });

    test('the default cap is the design\'s 20', () async {
      final b = AssistDailyBudget(
        await SharedPreferences.getInstance(),
        clock: () => now,
      );
      for (var i = 0; i < assistDailyCap; i++) {
        expect(b.tryStartLookup(0), isTrue);
      }
      expect(b.tryStartLookup(0), isFalse);
      expect(assistDailyCap, 20);
    });

    test('a corrupt or foreign value reads as a fresh day', () async {
      for (final raw in [
        'not json',
        '[]',
        jsonEncode({'date': '2026-10-24', 'count': -4}),
        jsonEncode({'date': '2026-10-24', 'count': 'many'}),
      ]) {
        SharedPreferences.setMockInitialValues({assistDailyPrefsKey: raw});
        final b = AssistDailyBudget(
          await SharedPreferences.getInstance(),
          clock: () => now,
        );
        expect(b.lookupsToday, 0, reason: raw);
        expect(b.tryStartLookup(0), isTrue, reason: raw);
      }
    });
  });

  group('AssistLocalState (F1 documents)', () {
    late Directory root;
    late DateTime now;
    setUp(() {
      root = Directory.systemTemp.createTempSync('assist_local_state_test');
      now = DateTime.utc(2026, 10, 24, 18);
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    AssistLocalState state() => AssistLocalState(
      LocalNoBackupStore(
        root: () async => root,
        createMissingDirectory: true,
        clock: () => now,
      ),
      clock: () => now,
    );
    File file(String name) =>
        File('${root.path}/$localStoreDirName/$name.json');
    Map<String, Object?> doc(String name) =>
        jsonDecode(file(name).readAsStringSync()) as Map<String, Object?>;

    test('unseen: added, read, seen; 30 days', () async {
      final s = state();
      expect(await s.unseen(), isEmpty);
      expect(await s.addUnseen(7), isTrue);
      expect(await s.addUnseen(9), isTrue);
      expect(await s.unseen(), {7, 9});
      expect(doc(assistUnseenDocument)['v'], assistLocalVersion);
      expect(await s.markSeen(7), isTrue);
      expect(await s.unseen(), {9});
      now = now.add(const Duration(days: 31));
      expect(await s.unseen(), isEmpty);
    });

    test('misses count to the denylist, never past it; 3 days', () async {
      final s = state();
      expect(await s.addMiss(4), 1);
      expect(await s.addMiss(4), 2);
      expect(await s.addMiss(4), assistMissesBeforeDenylist);
      expect(await s.addMiss(5, denylist: true), assistMissesBeforeDenylist);
      expect(await s.misses(), {4: 2, 5: 2});
      now = now.add(const Duration(days: 4));
      expect(await s.misses(), isEmpty);
    });

    test('jobs: put, read, retain, remove, clear; 24 h', () async {
      final s = state();
      AssistJob job(String id) => AssistJob(
        jobId: id,
        reqHash: '0123456789abcdef',
        at: now,
        nextAt: now,
      );
      expect(await s.putJob(1, job('job_aaaaaaaa')), isTrue);
      expect(await s.putJob(2, job('job_bbbbbbbb')), isTrue);
      expect(await s.putJob(3, job('bad id')), isFalse);
      expect((await s.jobs()).keys.toSet(), {1, 2});
      expect((await s.jobs())[1]!.reqHash, '0123456789abcdef');
      expect(await s.retainJobs({2}), isTrue);
      expect((await s.jobs()).keys, [2]);
      expect(await s.removeJob(2), isTrue);
      expect(file(assistJobsDocument).existsSync(), isFalse);
      await s.putJob(5, job('job_cccccccc'));
      expect(await s.clearJobs(), isTrue);
      expect(await s.jobs(), isEmpty);
      await s.putJob(6, job('job_dddddddd'));
      now = now.add(const Duration(hours: 25));
      expect(await s.jobs(), isEmpty);
    });

    test('a retry record has no job id; the place context round-trips as '
        'chain keys and flags only', () async {
      final s = state();
      const place = AssistPlaceContext(
        chains: ['mcdonalds', 'starbucks'],
        picked: 'mcdonalds',
        confirmed: {'mcdonalds'},
        blocked: {'subway'},
        verified: true,
        dense: false,
      );
      expect(
        await s.putJob(
          1,
          AssistJob(
            reqHash: '0123456789abcdef',
            at: now,
            nextAt: now.add(const Duration(minutes: 5)),
            attempts: 1,
            place: place,
          ),
        ),
        isTrue,
      );
      final job = (await s.jobs())[1]!;
      expect(job.jobId, isNull);
      expect(job.isPending, isFalse);
      expect(job.attempts, 1);
      expect(job.place?.chains, ['mcdonalds', 'starbucks']);
      expect(job.place?.picked, 'mcdonalds');
      expect(job.place?.confirmed, {'mcdonalds'});
      expect(job.place?.blocked, {'subway'});
      expect(job.place?.verified, isTrue);
      final raw = file(assistJobsDocument).readAsStringSync();
      expect(raw, isNot(contains('job_id')));
      expect(jsonDecode(raw)['jobs'][0]['place'], place.toJson());

      // A context that is not table keys, or a pick outside its chains, is
      // dropped with its entry.
      for (final bad in [
        {
          'chains': ['Chipotle near 1st St'],
          'verified': true,
          'dense': false,
        },
        {
          'chains': ['mcdonalds'],
          'picked': 'subway',
          'verified': true,
          'dense': false,
        },
        {
          'chains': ['mcdonalds'],
          'verified': 'yes',
          'dense': false,
        },
        {
          'chains': ['mcdonalds', 'subway', 'qdoba', 'chipotle'],
          'verified': true,
          'dense': false,
        },
      ]) {
        file(assistJobsDocument).writeAsStringSync(
          jsonEncode({
            'v': assistLocalVersion,
            'jobs': [
              {
                'meal_id': 1,
                'req_hash': '0123456789abcdef',
                'attempts': 1,
                'next_at': now.toIso8601String(),
                'at': now.toIso8601String(),
                'place': bad,
              },
            ],
          }),
        );
        expect(await s.jobs(), isEmpty, reason: '$bad');
      }
    });

    test('the editor\'s picked chain (R7b) round-trips as a table key; '
        'anything else drops the entry', () async {
      final s = state();
      expect(
        await s.putJob(
          1,
          AssistJob(
            jobId: 'job_pick_0001',
            reqHash: '0123456789abcdef',
            at: now,
            nextAt: now,
            manual: true,
            pick: 'qdoba',
          ),
        ),
        isTrue,
      );
      expect((await s.jobs())[1]!.pick, 'qdoba');
      expect((await s.jobs())[1]!.manual, isTrue);
      expect(
        await s.putJob(
          2,
          AssistJob(
            jobId: 'job_pick_0002',
            reqHash: '0123456789abcdef',
            at: now,
            nextAt: now,
            pick: 'Joe\'s Diner',
          ),
        ),
        isFalse,
      );
      file(assistJobsDocument).writeAsStringSync(
        jsonEncode({
          'v': assistLocalVersion,
          'jobs': [
            {
              'meal_id': 1,
              'job_id': 'job_pick_0001',
              'req_hash': '0123456789abcdef',
              'attempts': 0,
              'next_at': now.toIso8601String(),
              'at': now.toIso8601String(),
              'manual': true,
              'pick': 'Chipotle on 5th Ave',
            },
          ],
        }),
      );
      expect(await s.jobs(), isEmpty);
    });

    test('AssistPlaceContext.within keeps what the request carries', () {
      const place = AssistPlaceContext(
        chains: ['mcdonalds', 'starbucks'],
        picked: 'starbucks',
        confirmed: {'starbucks'},
        blocked: {'subway', 'qdoba'},
        verified: true,
      );
      final kept = place.within(['subway', 'mcdonalds']);
      expect(kept.chains, ['mcdonalds']);
      expect(kept.picked, isNull);
      expect(kept.confirmed, isEmpty);
      expect(kept.blocked, {'subway'});
      expect(kept.verified, isTrue);
    });

    AssistCachedLookup entry(
      String key, {
      String text = 'Big Mac 590 Cal.',
      String status = 'found',
      String provider = 'anthropic',
      DateTime? at,
    }) => AssistCachedLookup(
      key: key,
      chainKey: 'mcdonalds',
      names: const ['big mac'],
      lookup: AssistLookup(
        result: {'status': status, 'chain_key': 'mcdonalds'},
        provider: provider,
        citedUrls: const ['https://www.mcdonalds.com/big-mac'],
        evidence: [
          AssistEvidence(
            url: 'https://www.mcdonalds.com/big-mac',
            text: text,
            pageAge: '2026-01-02',
          ),
        ],
      ),
      at: at ?? now,
    );

    List<Map<String, Object?>> stored() =>
        ((doc(assistCacheDocument)['entries'] as List)
            .cast<Map<String, Object?>>());

    test('the cache: put, read, replace, clear', () async {
      final s = state();
      final key = 'a' * 32;
      expect(await s.cachedLookup(key), isNull);
      expect(await s.putCachedLookup(entry(key)), isTrue);
      final hit = (await s.cachedLookup(key))!;
      expect(hit.chainKey, 'mcdonalds');
      expect(hit.names, ['big mac']);
      expect(hit.lookup.provider, 'anthropic');
      expect(hit.lookup.evidence.single.pageAge, '2026-01-02');
      expect(hit.lookup.evidence.single.verbatim, isTrue);
      expect(hit.found, isTrue);
      expect(await s.putCachedLookup(entry(key, text: 'newer')), isTrue);
      expect((await s.cachedLookup(key))!.lookup.evidence.single.text, 'newer');
      expect(stored().length, 1);
      expect(await s.clearCache(), isTrue);
      expect(await s.cachedLookup(key), isNull);
    });

    // Usual foods D1/D2: published numbers a search found are kept a year
    // from the fetch, an answer that found nothing 30 days. Neither slides
    // with use.
    test('a found answer reads at 364 days and is gone at 366; any other '
        'is gone at 31; both are measured from the fetch', () async {
      final s = state();
      final fetched = now;
      final found = 'a' * 32;
      await s.putCachedLookup(entry(found));
      final negatives = {
        'not_published': 'b' * 32,
        'no_match': 'c' * 32,
        'ambiguous': 'd' * 32,
      };
      for (final MapEntry(key: status, value: key) in negatives.entries) {
        expect(await s.putCachedLookup(entry(key, status: status)), isTrue);
        expect((await s.cachedLookup(key))!.found, isFalse, reason: status);
      }
      now = fetched.add(const Duration(days: 30));
      for (final key in negatives.values) {
        expect(await s.cachedLookup(key), isNotNull, reason: 'day 30');
      }
      now = fetched.add(const Duration(days: 31));
      for (final MapEntry(key: status, value: key) in negatives.entries) {
        expect(await s.cachedLookup(key), isNull, reason: status);
      }
      expect(await s.cachedLookup(found), isNotNull);
      // Uses on day 300 and day 363 do not move its life.
      now = fetched.add(const Duration(days: 300));
      expect(await s.touchCachedLookup(found), isTrue);
      now = fetched.add(const Duration(days: 363));
      expect(await s.touchCachedLookup(found), isTrue);
      now = fetched.add(const Duration(days: 364));
      final late = (await s.cachedLookup(found))!;
      expect(late.at, fetched);
      expect(late.usedAt, fetched.add(const Duration(days: 363)));
      now = fetched.add(const Duration(days: 366));
      expect(await s.cachedLookup(found), isNull,
          reason: 'measured from at, not used_at');
    });

    // An automatic lookup touches a negative hit too, so a life measured
    // from used_at would keep a "not published" answer alive for as long
    // as it keeps being hit.
    test('a used negative answer is still gone 31 days after its fetch',
        () async {
      final s = state();
      final key = 'b' * 32;
      final fetched = now;
      expect(await s.putCachedLookup(entry(key, status: 'not_published')),
          isTrue);
      // Hit (and touched) on days 20 and 29.
      now = fetched.add(const Duration(days: 20));
      expect(await s.touchCachedLookup(key), isTrue);
      now = fetched.add(const Duration(days: 29));
      expect(await s.touchCachedLookup(key), isTrue);
      expect((await s.cachedLookup(key))!.usedAt, now);
      now = fetched.add(const Duration(days: 31));
      expect(await s.cachedLookup(key), isNull,
          reason: '30 days from at, not from used_at');
    });

    // Usual foods D3: the least recently used goes first, so an answer
    // the owner keeps using is never pushed out by newer fetches.
    test('the cap keeps the answers used most recently', () async {
      final s = state();
      String k(int i) => i.toRadixString(16).padLeft(32, '0');
      for (var i = 0; i < assistCacheCap; i++) {
        now = now.add(const Duration(minutes: 1));
        expect(await s.putCachedLookup(entry(k(i))), isTrue);
      }
      now = now.add(const Duration(minutes: 1));
      expect(await s.touchCachedLookup(k(0)), isTrue,
          reason: 'the first fetched is used again');
      now = now.add(const Duration(minutes: 1));
      expect(await s.putCachedLookup(entry(k(assistCacheCap))), isTrue);
      expect(stored(), hasLength(assistCacheCap));
      expect(await s.cachedLookup(k(0)), isNotNull);
      expect(await s.cachedLookup(k(1)), isNull,
          reason: 'the least recently used went');
      expect(await s.cachedLookup(k(assistCacheCap)), isNotNull);
    });

    test('a touch sets used_at to the clock and keeps at and the declined '
        'mark; a mark keeps used_at; a replacing found answer resets it',
        () async {
      final s = state();
      final key = 'e' * 32;
      final fetched = now;
      expect(await s.touchCachedLookup(key), isTrue, reason: 'absent');
      expect(await s.cachedLookup(key), isNull);
      await s.putCachedLookup(entry(key));
      expect((await s.cachedLookup(key))!.usedAt, fetched);
      expect(stored().single['used_at'], fetched.toIso8601String());
      expect(await s.markCachedLookup(key, declined: true), isTrue);

      now = fetched.add(const Duration(days: 40));
      expect(await s.touchCachedLookup(key), isTrue);
      final touched = (await s.cachedLookup(key))!;
      expect(touched.usedAt, now);
      expect(touched.at, fetched, reason: 'a touch never moves the year');
      expect(touched.declined, isTrue);

      final usedAt = now;
      now = fetched.add(const Duration(days: 41));
      expect(await s.markCachedLookup(key, declined: false), isTrue);
      expect(await s.markCachedLookup(key, declined: true), isTrue);
      final marked = (await s.cachedLookup(key))!;
      expect(marked.usedAt, usedAt, reason: 'a mark is not a use');
      expect(marked.at, fetched);

      now = fetched.add(const Duration(days: 42));
      await s.putCachedLookup(entry(key, text: 'fresh'));
      final fresh = (await s.cachedLookup(key))!;
      expect(fresh.at, now);
      expect(fresh.usedAt, now);
      expect(fresh.declined, isTrue);
    });

    // Usual foods D2a: a later search that found nothing never pushes out
    // published numbers the same provider found for these items.
    test('a negative answer never replaces a found one from the same '
        'provider; a newer found answer, or another provider, does',
        () async {
      final s = state();
      final key = 'f' * 32;
      final fetched = now;
      await s.putCachedLookup(entry(key, text: 'found'));
      final before = file(assistCacheDocument).readAsStringSync();
      now = fetched.add(const Duration(days: 5));
      expect(
        await s.putCachedLookup(entry(key, status: 'not_published')),
        isTrue,
        reason: 'the store holds the best answer',
      );
      expect(file(assistCacheDocument).readAsStringSync(), before,
          reason: 'nothing is written');
      final kept = (await s.cachedLookup(key))!;
      expect(kept.found, isTrue);
      expect(kept.lookup.evidence.single.text, 'found');

      await s.putCachedLookup(entry(key, text: 'newer found'));
      final newer = (await s.cachedLookup(key))!;
      expect(newer.lookup.evidence.single.text, 'newer found');
      expect(newer.at, now);

      final other = 'f0' * 16;
      await s.putCachedLookup(entry(other, text: 'found'));
      expect(
        await s.putCachedLookup(
          entry(other, status: 'no_match', provider: 'claude_plan'),
        ),
        isTrue,
      );
      final replaced = (await s.cachedLookup(other))!;
      expect(replaced.found, isFalse);
      expect(replaced.lookup.provider, 'claude_plan');

      // An expired found answer is gone, so a negative takes its key.
      final aged = 'f1' * 16;
      now = fetched;
      await s.putCachedLookup(entry(aged));
      now = fetched.add(const Duration(days: 366));
      await s.putCachedLookup(entry(aged, status: 'not_published'));
      expect((await s.cachedLookup(aged))!.found, isFalse);
    });

    test('an entry written before used_at existed reads used_at as at; the '
        'other documents still read after a cache write', () async {
      final s = state();
      await s.addUnseen(3);
      await s.addMiss(4);
      await s.logDecision(AssistDecisionEntry(at: now, code: 'ok'));
      await s.putJob(
        5,
        AssistJob(
          jobId: 'job_abcdef01',
          reqHash: '0123456789abcdef',
          at: now,
          nextAt: now,
        ),
      );
      final fetched = now.subtract(const Duration(days: 45));
      Map<String, Object?> legacy(String key, {Object? usedAt}) =>
          {...entry(key, at: fetched).toJson()}
            ..remove('used_at')
            ..addAll({'used_at': ?usedAt});
      file(assistCacheDocument).writeAsStringSync(
        jsonEncode({
          'v': assistLocalVersion,
          'entries': [
            legacy('1' * 32),
            legacy('2' * 32, usedAt: 'yesterday'),
            legacy('3' * 32,
                usedAt: fetched.subtract(const Duration(days: 1))
                    .toIso8601String()),
            legacy('4' * 32,
                usedAt: now.add(const Duration(days: 3)).toIso8601String()),
            legacy('5' * 32,
                usedAt: now.subtract(const Duration(days: 2))
                    .toIso8601String()),
          ],
        }),
      );
      for (final k in ['1', '2', '3', '4']) {
        expect((await s.cachedLookup(k * 32))!.usedAt, fetched, reason: k);
      }
      expect((await s.cachedLookup('5' * 32))!.usedAt,
          now.subtract(const Duration(days: 2)));
      // The next write stores it, and the version is unchanged.
      await s.putCachedLookup(entry('6' * 32));
      expect(doc(assistCacheDocument)['v'], 1);
      expect(stored().every((e) => e['used_at'] is String), isTrue);
      expect(await s.unseen(), {3});
      expect(await s.misses(), {4: 1});
      expect(await s.decisions(), hasLength(1));
      expect((await s.jobs()).keys, [5]);
    });

    test('an entry that fits only without used_at is refused; the full '
        'store fits in one document', () async {
      final s = state();
      // The text that makes the entry, with used_at, one byte over the cap.
      int size(AssistCachedLookup e) =>
          utf8.encode(jsonEncode(e.toJson())).length;
      final base = size(entry('a' * 32, text: ''));
      final over = entry(
        'a' * 32,
        text: 'x' * (assistCacheEntryMaxBytes - base + 1),
      );
      expect(size(over), assistCacheEntryMaxBytes + 1);
      final withoutUsedAt = {...over.toJson()}..remove('used_at');
      expect(
        utf8.encode(jsonEncode(withoutUsedAt)).length,
        lessThanOrEqualTo(assistCacheEntryMaxBytes),
      );
      expect(await s.putCachedLookup(over), isFalse);
      expect(await s.cachedLookup('a' * 32), isNull);
      expect(
        assistCacheCap * assistCacheEntryMaxBytes + 4096,
        lessThan(localDocumentMaxBytes),
      );
    });

    test('a declined mark: set and cleared in place, kept when a fresh '
        'answer replaces the entry', () async {
      final s = state();
      final key = 'b' * 32;
      expect(
        await s.markCachedLookup(key, declined: true),
        isTrue,
        reason: 'nothing to mark',
      );
      expect(await s.cachedLookup(key), isNull);
      await s.putCachedLookup(entry(key));
      expect((await s.cachedLookup(key))!.declined, isFalse);
      final stored = jsonDecode(file(assistCacheDocument).readAsStringSync());
      expect(
        ((stored['entries'] as List).single as Map).containsKey('declined'),
        isFalse,
      );

      now = now.add(const Duration(days: 2));
      expect(await s.markCachedLookup(key, declined: true), isTrue);
      final marked = (await s.cachedLookup(key))!;
      expect(marked.declined, isTrue);
      expect(
        marked.at,
        now.subtract(const Duration(days: 2)),
        reason: 'its age is unchanged',
      );

      // A fresh answer for the same key keeps the user's refusal.
      await s.putCachedLookup(entry(key, text: 'fresh'));
      final fresh = (await s.cachedLookup(key))!;
      expect(fresh.lookup.evidence.single.text, 'fresh');
      expect(fresh.declined, isTrue);

      expect(await s.markCachedLookup(key, declined: false), isTrue);
      expect((await s.cachedLookup(key))!.declined, isFalse);
    });

    test('the cache keeps 200 and refuses an oversized or malformed entry',
        () async {
      final s = state();
      for (var i = 0; i < assistCacheCap + 3; i++) {
        now = now.add(const Duration(minutes: 1));
        await s.putCachedLookup(entry(i.toRadixString(16).padLeft(32, '0')));
      }
      expect(await s.cachedLookup('0' * 32), isNull);
      expect(
        await s.cachedLookup(
          (assistCacheCap + 2).toRadixString(16).padLeft(32, '0'),
        ),
        isNotNull,
      );
      expect(
        await s.putCachedLookup(entry('b' * 32, text: 'x' * 9000)),
        isFalse,
      );
      expect(await s.putCachedLookup(entry('not a key')), isFalse);
      file(assistCacheDocument).writeAsStringSync(
        jsonEncode({
          'v': assistLocalVersion,
          'entries': [
            {...entry('c' * 32).toJson(), 'chain_key': 'Chipotle'},
            {...entry('d' * 32).toJson(), 'result': 'junk'},
            {
              ...entry('e' * 32).toJson(),
              'result': {'status': 'found', 'chain_key': 'subway'},
            },
            entry('f' * 32).toJson(),
          ],
        }),
      );
      expect(await s.cachedLookup('c' * 32), isNull);
      expect(await s.cachedLookup('d' * 32), isNull);
      expect(await s.cachedLookup('e' * 32), isNull);
      expect(await s.cachedLookup('f' * 32), isNotNull);
    });

    test('decision entries are validated: a code or provider of another '
        'shape is refused on write and dropped on read', () async {
      final s = state();
      expect(
        await s.logDecision(AssistDecisionEntry(at: now, code: 'Big Mac')),
        isFalse,
      );
      expect(
        await s.logDecision(
          AssistDecisionEntry(at: now, code: 'ok', provider: 'a b'),
        ),
        isFalse,
      );
      expect(
        await s.logDecision(AssistDecisionEntry(at: now, code: 'ok')),
        isTrue,
      );
      file(assistDecisionsDocument).writeAsStringSync(
        jsonEncode({
          'v': assistLocalVersion,
          'log': [
            {'at': now.toIso8601String(), 'code': 'applied', 'old_kcal': 540},
            {'at': now.toIso8601String(), 'code': 'Chipotle near 1st St'},
            {'at': 'yesterday', 'code': 'ok'},
            'junk',
          ],
        }),
      );
      final log = await s.decisions();
      expect([for (final e in log) e.code], ['applied']);
      expect(log.single.oldKcal, 540);
    });

    test('a corrupt or other-version document reads empty', () async {
      final s = state();
      for (final name in [
        assistUnseenDocument,
        assistMissDocument,
        assistJobsDocument,
        assistDecisionsDocument,
        assistCacheDocument,
      ]) {
        file(name)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('{not json');
      }
      expect(await s.unseen(), isEmpty);
      expect(await s.misses(), isEmpty);
      expect(await s.jobs(), isEmpty);
      expect(await s.decisions(), isEmpty);
      expect(await s.cachedLookup('a' * 32), isNull);
      file(assistUnseenDocument).writeAsStringSync(
        jsonEncode({
          'v': 99,
          'meals': [
            {'id': 1, 'at': now.toIso8601String()},
          ],
        }),
      );
      expect(await s.unseen(), isEmpty);
    });

    test('a cap: the newest unseen meals stay', () async {
      final s = state();
      for (var i = 1; i <= assistUnseenCap + 5; i++) {
        await s.addUnseen(i);
      }
      final unseen = await s.unseen();
      expect(unseen, hasLength(assistUnseenCap));
      expect(unseen.contains(1), isFalse);
      expect(unseen.contains(assistUnseenCap + 5), isTrue);
    });

    test('no export or import code references the assist\'s documents', () {
      final lib = Directory('${_appRoot().path}/lib');
      for (final f in lib.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        final exporter =
            f.path.contains('/lib/data/') ||
            f.path.contains('/lib/services/report/') ||
            src.contains('exportJson(') ||
            src.contains('importJson(');
        if (!exporter) continue;
        for (final banned in [
          'assist_local_state',
          'AssistLocalState',
          'assist_unseen',
          'assist_decisions',
          'assist_casmiss',
          'assist_jobs',
          'assist_cache',
        ]) {
          expect(src, isNot(contains(banned)), reason: '${f.path}: $banned');
        }
      }
    });
  });
}
