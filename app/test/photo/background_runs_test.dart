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
}
