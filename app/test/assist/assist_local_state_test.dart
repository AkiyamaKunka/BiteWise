/// services/assist/assist_local_state.dart: the daily lookup counter in
/// shared_preferences (assist.daily.v1) and the backup-excluded documents
/// the assist keeps (unseen, decision log, miss list, jobs) — shapes, TTLs,
/// caps, corrupt documents reading empty, and no export path touching them.
library;

import 'dart:convert';
import 'dart:io';

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
      ]) {
        file(name)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('{not json');
      }
      expect(await s.unseen(), isEmpty);
      expect(await s.misses(), isEmpty);
      expect(await s.jobs(), isEmpty);
      expect(await s.decisions(), isEmpty);
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
        ]) {
          expect(src, isNot(contains(banned)), reason: '${f.path}: $banned');
        }
      }
    });
  });
}
