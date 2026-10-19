// The background-run diagnostics record (2026-10-18): one entry per run,
// rewritten at every step, so a run iOS kills still says how far it got.
import 'dart:convert';

import 'package:calorie_tracker/services/photo/background_runs.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs([Map<String, Object> initial = const {}]) {
  SharedPreferences.setMockInitialValues(initial);
  return SharedPreferences.getInstance();
}

List<Map<String, dynamic>> _stored(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(backgroundRunsPrefsKey)!) as List)
        .cast<Map<String, dynamic>>();

void main() {
  final t0 = DateTime.utc(2026, 10, 18, 3, 0, 0);

  test('begin writes the entry at once: boot, start, platform, watermark',
      () async {
    final prefs = await _prefs();
    final watermark = DateTime.utc(2026, 10, 11, 2, 26);
    await BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0)
        .begin(watermarkBefore: watermark);
    final runs = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey));
    expect(runs, hasLength(1));
    final r = runs.single;
    expect(r.start, t0);
    expect(r.end, isNull, reason: 'not finished — yet, or ever');
    expect(r.platform, 'ios');
    expect(r.stage, BackgroundRunStage.boot);
    expect(r.watermarkBefore, watermark);
    expect(r.watermarkAfter, watermark, reason: 'nothing moved it yet');
  });

  test('the boot before Dart (iOS native launch stamp) is kept, through '
      'every later write; none is stored without one', () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
    await rec.begin(bootLead: const Duration(milliseconds: 1750));
    await rec.offered();
    await rec.finish(BackgroundStop.done);
    expect(decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
        .single
        .bootMs, 1750);
    expect(_stored(prefs).single['boot_ms'], 1750);
    for (final lead in [null, Duration.zero]) {
      final p = await _prefs();
      await BackgroundRunRecorder(p, platform: 'android', clock: () => t0)
          .begin(bootLead: lead);
      expect(_stored(p).single.containsKey('boot_ms'), isFalse);
      expect(decodeBackgroundRuns(p.getString(backgroundRunsPrefsKey))
          .single
          .bootMs, isNull);
    }
  });

  test('a run the OS kills keeps the last step it wrote (no final write)',
      () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
    await rec.begin();
    await rec.stage(BackgroundRunStage.settings);
    await rec.stage(BackgroundRunStage.scan);
    await rec.listed(3);
    await rec.offered();
    await rec.processed(saved: true, released: false);
    await rec.checkpoint(DateTime.utc(2026, 10, 18, 2, 50));
    await rec.offered(); // photo 2 is mid-analysis when iOS expires the run
    // ... and nothing more: the process is gone. A fresh read (the app's
    // engine, later) sees exactly that.
    final r = (await readBackgroundRuns(prefs: () async => prefs)).single;
    expect(r.finished, isFalse);
    expect(r.stage, BackgroundRunStage.photo);
    expect((r.enumerated, r.offered, r.analyzed, r.saved, r.released),
        (3, 2, 1, 1, 0));
    expect(r.watermarkAfter, DateTime.utc(2026, 10, 18, 2, 50));
    expect(r.stopReason, isNull);
  });

  test('finish stamps the end, the reason and the final watermark; a second '
      'finish and later steps change nothing', () async {
    final prefs = await _prefs();
    var now = t0;
    final rec = BackgroundRunRecorder(prefs, platform: 'android',
        clock: () => now);
    await rec.begin();
    await rec.releasedUnprocessed(2);
    now = t0.add(const Duration(seconds: 14));
    await rec.finish(BackgroundStop.budget,
        watermarkAfter: DateTime.utc(2026, 10, 18, 2, 0));
    await rec.finish(BackgroundStop.done);
    await rec.stage(BackgroundRunStage.photo);
    final r = rec.current!;
    expect(r.end, t0.add(const Duration(seconds: 14)));
    expect(r.stage, BackgroundRunStage.done);
    expect(r.stopReason, BackgroundStop.budget);
    expect(r.released, 2);
    expect(r.watermarkAfter, DateTime.utc(2026, 10, 18, 2, 0));
    expect(decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
        .single
        .stopReason, BackgroundStop.budget);
  });

  test('newest first, and only the last 20 are kept', () async {
    final prefs = await _prefs();
    for (var i = 0; i < 23; i++) {
      final rec = BackgroundRunRecorder(prefs,
          platform: 'ios', clock: () => t0.add(Duration(minutes: 30 * i)));
      await rec.begin();
      await rec.finish(BackgroundStop.done);
    }
    final runs = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey));
    expect(runs, hasLength(backgroundRunsKept));
    expect(runs.first.start, t0.add(const Duration(minutes: 30 * 22)));
    expect(runs.last.start, t0.add(const Duration(minutes: 30 * 3)));
  });

  test('counts and timestamps only: the stored keys are pinned, and an error '
      'is its class name, never its message', () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
    await rec.begin();
    // A message can carry anything — a server address, a key prefix.
    final error = PlatformException(
        code: '-25308', message: 'https://my-server.example/?key=abc');
    await rec.finish(BackgroundStop.error(error));
    final entry = _stored(prefs).single;
    expect(entry.keys.toSet(), {
      'start', 'end', 'platform', 'stage', 'enumerated', 'offered',
      'analyzed', 'saved', 'released', 'stop', 'wm_before', 'wm_after',
    });
    expect(entry['stop'], 'error:PlatformException');
    expect(prefs.getString(backgroundRunsPrefsKey), isNot(contains('http')));
    expect(prefs.getString(backgroundRunsPrefsKey), isNot(contains('key=')));
  });

  test('a damaged store reads as what it can: bad entries skipped, bad JSON '
      'empty, and a new run still records', () async {
    expect(decodeBackgroundRuns('not json'), isEmpty);
    expect(decodeBackgroundRuns('{"a":1}'), isEmpty);
    final mixed = jsonEncode([
      {'start': t0.toIso8601String(), 'stage': 'scan', 'offered': -4},
      {'start': 'yesterday'},
      42,
      {'start': t0.toIso8601String(), 'stage': 'from-the-future'},
    ]);
    final runs = decodeBackgroundRuns(mixed);
    expect(runs, hasLength(2));
    expect(runs.first.stage, BackgroundRunStage.scan);
    expect(runs.first.offered, 0, reason: 'a negative count is not a count');
    expect(runs.last.stage, BackgroundRunStage.boot);

    final prefs = await _prefs({backgroundRunsPrefsKey: 'not json'});
    await BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0)
        .begin();
    expect(decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey)),
        hasLength(1));
  });

  test('nothing is written before begin', () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios');
    await rec.offered();
    await rec.finish(BackgroundStop.done);
    expect(prefs.getString(backgroundRunsPrefsKey), isNull);
  });

  test('readBackgroundRuns: an unreadable store is an empty history',
      () async {
    expect(
        await readBackgroundRuns(prefs: () async => throw StateError('no')),
        isEmpty);
  });

  // 2026-10-19: the Settings 后台扫描 row says when the runs show no
  // progress — and never for a quiet stretch with no photos.
  group('backgroundScanLooksStuck', () {
    final now = DateTime.utc(2026, 10, 19, 12);
    BackgroundRunRecord run(Duration ago,
            {int offered = 0,
            int analyzed = 0,
            int saved = 0,
            int released = 0,
            String? stop = BackgroundStop.done,
            DateTime? before,
            DateTime? after}) =>
        BackgroundRunRecord(
          start: now.subtract(ago),
          end: stop == null ? null : now.subtract(ago),
          platform: 'ios',
          stage: stop == null
              ? BackgroundRunStage.photo
              : BackgroundRunStage.done,
          offered: offered,
          analyzed: analyzed,
          saved: saved,
          released: released,
          stopReason: stop,
          watermarkBefore: before,
          watermarkAfter: after ?? before,
        );
    const h = Duration(hours: 1);

    test('the 3 newest runs each took a photo and finished none', () {
      final hung = [
        for (final ago in [1, 2, 3]) run(h * ago, offered: 1, stop: null),
      ];
      expect(backgroundScanLooksStuck(hung, now: now), isTrue);
      expect(backgroundScanLooksStuck(hung.take(2).toList(), now: now),
          isFalse, reason: 'two is not a pattern yet');
      expect(
          backgroundScanLooksStuck(
              [run(h, offered: 1, analyzed: 1), ...hung.skip(1)], now: now),
          isFalse,
          reason: 'the newest run finished its photo');
      expect(
          backgroundScanLooksStuck([
            run(h, offered: 1, stop: BackgroundStop.budget),
            ...hung.skip(1),
          ], now: now),
          isTrue,
          reason: 'out of time on it is no progress either');
    });

    test('a quiet week with no new photos is never stuck', () {
      final wm = DateTime.utc(2026, 10, 12);
      final quiet = [
        for (var i = 1; i <= 20; i++)
          run(h * (8 * i), offered: 1, analyzed: 1, before: wm),
      ];
      expect(backgroundScanLooksStuck(quiet, now: now), isFalse);
    });

    test('runs keep starting but none made progress for 2 days', () {
      final dying = [
        run(h * 2, stop: null), // killed at boot: nothing offered
        run(h * 10, stop: 'error:PlatformException'),
        run(h * 30, offered: 1, analyzed: 1, released: 1),
        run(h * 60, stop: null),
      ];
      expect(backgroundScanLooksStuck(dying, now: now), isTrue);
      expect(backgroundScanLooksStuck(dying.take(3).toList(), now: now),
          isFalse, reason: 'the record does not reach back 2 days');
      expect(
          backgroundScanLooksStuck(
              [run(h, saved: 1, offered: 1, analyzed: 1), ...dying],
              now: now),
          isFalse,
          reason: 'a meal saved is progress');
      expect(
          backgroundScanLooksStuck([
            run(h,
                before: DateTime.utc(2026, 10, 18),
                after: DateTime.utc(2026, 10, 19)),
            ...dying
          ], now: now),
          isFalse,
          reason: 'a watermark moved is progress');
      expect(
          backgroundScanLooksStuck(
              [dying.first, dying.last], now: now),
          isFalse,
          reason: 'fewer than 3 runs in 2 days: not "keep starting"');
    });

    test('runs a guard stopped (no key, paused…) are not "stuck": opening '
        'the app would not fix them', () {
      final guarded = [
        for (var i = 1; i <= 6; i++)
          run(h * (12 * i), stop: BackgroundStop.noKey),
      ];
      expect(backgroundScanLooksStuck(guarded, now: now), isFalse);
    });
  });
}
