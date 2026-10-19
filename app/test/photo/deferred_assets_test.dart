/// One undecodable photo must not freeze the background scan forever
/// (2026-10-19): after two deferrals, later background runs pass it over.
/// A photo the iOS deadline keeps cutting off takes three cuts.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calorie_tracker/services/photo/deferred_assets.dart';

void main() {
  late SharedPreferences prefs;
  final t0 = DateTime.utc(2026, 10, 19, 3);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  List<DeferredAsset> stored() =>
      decodeDeferredAssets(prefs.getString(deferredAssetsPrefsKey));

  Future<DeferredAssets> run([DateTime? at]) =>
      DeferredAssets.load(prefs, clock: () => at ?? t0);

  test('passed over only by runs AFTER the second deferral', () async {
    final first = await run();
    await first.deferred('A');
    expect(first.passOver('A'), isFalse);

    final second = await run(t0.add(const Duration(minutes: 30)));
    expect(second.passOver('A'), isFalse, reason: 'deferred once so far');
    await second.deferred('A');
    expect(second.passOver('A'), isFalse,
        reason: 'this run already offered it; the next one passes it over');

    final third = await run();
    expect(third.passOver('A'), isTrue);
    expect(third.passOver('B'), isFalse);
    final e = stored().single;
    expect((e.id, e.count, e.firstSeen), ('A', 2, t0),
        reason: 'first seen stays the first deferral');
  });

  test('only ids, counts and the first deferral are stored', () async {
    await (await run()).deferred('A');
    final raw = jsonDecode(prefs.getString(deferredAssetsPrefsKey)!) as List;
    expect(raw.single, {'id': 'A', 'n': 1, 'first': t0.toIso8601String()});
  });

  test('a verdict forgets the photo, in this run or the app', () async {
    final r = await run();
    await r.deferred('A');
    await r.deferred('B');
    await r.settled('A');
    expect(stored().map((e) => e.id), ['B']);
    // The app engine, through its own preferences cache.
    SharedPreferences.resetStatic();
    final app = await SharedPreferences.getInstance();
    await clearDeferredAsset('B', loadPrefs: () async => app);
    expect(app.getString(deferredAssetsPrefsKey), isNull);
    expect((await run()).passOver('B'), isFalse);
  });

  test('a verdict for a photo never deferred touches nothing', () async {
    final r = await run();
    await r.settled('Z');
    await clearDeferredAsset('Z', loadPrefs: () async => prefs);
    expect(prefs.getString(deferredAssetsPrefsKey), isNull);
  });

  test("the app engine goes to the store only for an id its copy holds: "
      "every other verdict (nearly all) costs no reload", () async {
    SharedPreferences.resetStatic();
    final app = await SharedPreferences.getInstance(); // empty copy
    // The background run defers a photo after the app loaded its copy.
    await (await run()).deferred('A');
    await clearDeferredAsset('A', loadPrefs: () async => app);
    await clearDeferredAsset('', loadPrefs: () async => app);
    expect(stored().map((e) => e.id), ['A'],
        reason: 'not reloaded, so left behind: harmless, the photo has a '
            'verdict now');
    // Once the copy knows it (any reload), the verdict forgets it.
    await app.reload();
    await clearDeferredAsset('A', loadPrefs: () async => app);
    await prefs.reload();
    expect(prefs.getString(deferredAssetsPrefsKey), isNull);
  });

  test('capped at 50: the earliest-deferred goes first', () async {
    final r = await run();
    for (var i = 0; i < deferredAssetsKept + 3; i++) {
      final at = t0.add(Duration(minutes: i));
      await (await run(at)).deferred('a$i');
    }
    await r.deferred('a10'); // a count, not a new entry
    final ids = stored().map((e) => e.id).toList();
    expect(ids, hasLength(deferredAssetsKept));
    expect(ids, isNot(contains('a0')));
    expect(ids, isNot(contains('a2')));
    expect(ids, contains('a3'));
    expect(stored().firstWhere((e) => e.id == 'a10').count, 2);
  });

  // Review, 2026-10-19: a deadline cut is mostly the server's or the
  // network's doing, not the photo's. Two of them used to pass a photo
  // over for good (the watermark moved past it) after a slow patch of two
  // runs.
  test('deadline cuts are counted apart, and pass a photo over only after '
      'three', () async {
    await (await run()).cutOff('A');
    await (await run()).cutOff('A');
    expect((await run()).passOver('A'), isFalse,
        reason: 'two hung runs: the next one still offers it');
    var e = stored().single;
    expect((e.count, e.cuts), (0, 2));
    // A deferral is its own count: one of each passes nothing over.
    await (await run()).deferred('A');
    expect((await run()).passOver('A'), isFalse);
    await (await run()).cutOff('A');
    expect((await run()).passOver('A'), isTrue,
        reason: 'cut off three times with the full window');
    e = stored().single;
    expect((e.count, e.cuts, e.firstSeen), (1, 3, t0));
  });

  test('a cut is stored as c, and an entry without one reads as no cuts',
      () async {
    await (await run()).cutOff('A');
    final raw = jsonDecode(prefs.getString(deferredAssetsPrefsKey)!) as List;
    expect(raw.single,
        {'id': 'A', 'n': 0, 'first': t0.toIso8601String(), 'c': 1});
    await prefs.setString(
        deferredAssetsPrefsKey,
        jsonEncode([
          {'id': 'B', 'n': 2, 'first': t0.toIso8601String()},
          {'id': 'C', 'n': 0, 'first': t0.toIso8601String(), 'c': 3},
          {'id': 'D', 'n': 0, 'first': t0.toIso8601String()}, // nothing
          {'id': 'E', 'n': 1, 'first': t0.toIso8601String(), 'c': 'x'},
        ]));
    expect(stored().map((e) => (e.id, e.count, e.cuts)),
        [('B', 2, 0), ('C', 0, 3)]);
    final r = await run();
    expect((r.passOver('B'), r.passOver('C')), (true, true));
    // A verdict forgets cuts like deferrals.
    await r.settled('C');
    expect(stored().map((e) => e.id), ['B']);
  });

  test('a damaged store reads as empty, and damaged entries are skipped',
      () async {
    await prefs.setString(deferredAssetsPrefsKey, '{not json');
    expect((await run()).passOver('A'), isFalse);
    await prefs.setString(
        deferredAssetsPrefsKey,
        jsonEncode([
          {'id': 'A', 'n': 2, 'first': t0.toIso8601String()},
          {'id': 7, 'n': 'x'},
          'junk',
        ]));
    final r = await run();
    expect(r.passOver('A'), isTrue);
    await r.deferred('B');
    expect(stored().map((e) => e.id), ['A', 'B']);
  });
}
