/// One undecodable photo must not freeze the background scan forever
/// (2026-10-19): after two deferrals, later background runs pass it over.
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
