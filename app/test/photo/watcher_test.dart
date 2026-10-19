// Watcher / backfill behavior (spec §6.1, §6.4): lookback window math,
// newest-last emission, deliberate=false, session dedup, permission flow,
// 25 MB cap (§8).
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAsset implements LibraryAsset {
  FakeAsset(this.id, this.name, this.createDateTime, this.bytes,
      {this.onRead, this.throwOnRead = false});
  @override
  final String id;
  final String name;
  @override
  final DateTime createDateTime;
  final Uint8List? bytes;
  final void Function()? onRead;
  final bool throwOnRead; // Android 11+ replies errors for unreadable assets

  @override
  Future<String> fileName() async => name;

  @override
  Future<Uint8List?> originBytes() async {
    onRead?.call();
    if (throwOnRead) throw StateError('202: get originBytes error');
    return bytes;
  }
}

class FakePhotoLibrary implements PhotoLibrary {
  List<FakeAsset> assets = [];
  bool permissionGranted = true;
  int permissionRequests = 0;
  void Function()? changeListener;
  final List<DateTime> queriedCutoffs = [];
  final Map<String, Uint8List> thumbnails = {};
  bool fullAccess = true;

  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId, {int size = 160}) async =>
      thumbnails[assetId];

  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) async {
    for (final a in assets) {
      if (a.id == assetId) return a.originBytes();
    }
    return null;
  }

  @override
  Future<bool> hasFullAccess() async => fullAccess;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
      {int limit = 500}) async {
    queriedCutoffs.add(cutoff);
    return assets
        .where((a) => !a.createDateTime.isBefore(cutoff))
        .take(limit)
        .toList();
  }

  @override
  Future<List<LibraryAsset>> recentImages(int limit) async {
    final sorted = [...assets]
      ..sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    return sorted.take(limit).toList();
  }

  @override
  Future<void> startChangeNotify(void Function() onChange) async {
    changeListener = onChange;
  }

  @override
  Future<void> stopChangeNotify() async {
    changeListener = null;
  }
}

Uint8List bytesOf(int n, [int len = 3]) =>
    Uint8List.fromList(List.filled(len, n));

void main() {
  final now = DateTime(2026, 7, 17, 12, 0, 0);

  group('lookbackCutoff (§6.4 window math)', () {
    test('2 days = today + yesterday, cut at local midnight', () {
      expect(lookbackCutoff(now, 2), DateTime(2026, 7, 16));
    });
    test('1 day = today only', () {
      expect(lookbackCutoff(now, 1), DateTime(2026, 7, 17));
    });
    test('clamps to the §8 range 1–30', () {
      expect(lookbackCutoff(now, 0), DateTime(2026, 7, 17)); // → 1
      expect(lookbackCutoff(now, -5), DateTime(2026, 7, 17)); // → 1
      expect(lookbackCutoff(now, 99), DateTime(2026, 6, 18)); // → 30
    });
  });

  group('backfillScan', () {
    late FakePhotoLibrary library;
    late PhotoIntake intake;
    late List<IntakePhoto> emitted;

    setUp(() {
      library = FakePhotoLibrary();
      intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => now);
      emitted = [];
      intake.photos.listen(emitted.add);
    });

    test('onBackfillListed hears how many photos the scan listed, before '
        'any is read (background-run diagnostics)', () async {
      final events = <String>[];
      library.assets = [
        FakeAsset('a', 'IMG_a.jpg', DateTime(2026, 7, 17, 8), bytesOf(1),
            onRead: () => events.add('read')),
        FakeAsset('b', 'IMG_b.jpg', DateTime(2026, 7, 17, 9), bytesOf(2),
            onRead: () => events.add('read')),
      ];
      final listed = LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: library,
          clock: () => now,
          onBackfillListed: (n) async => events.add('listed:$n'));
      await listed.backfillScan(lookbackDays: 2);
      expect(events, ['listed:2', 'read', 'read']);
    });

    test('a throwing onBackfillListed never stops the scan', () async {
      library.assets = [
        FakeAsset('a', 'IMG_a.jpg', DateTime(2026, 7, 17, 8), bytesOf(1)),
      ];
      final delivered = <String>[];
      final listed = LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: library,
          clock: () => now,
          onBackfillListed: (_) => throw StateError('prefs'));
      listed.attachSink((p, _) async {
        delivered.add(p.assetId);
        return true;
      });
      await listed.backfillScan(lookbackDays: 2);
      expect(delivered, ['a']);
    });

    test('since AFTER the window cutoff narrows the scan (watermark)',
        () async {
      final mark = DateTime(2026, 7, 17, 9, 30);
      await intake.backfillScan(lookbackDays: 2, since: mark);
      expect(library.queriedCutoffs.single, mark);
    });

    test('since BEFORE the window cutoff is ignored (never widens §8 clamp)',
        () async {
      await intake.backfillScan(
          lookbackDays: 2, since: DateTime(2026, 7, 1));
      expect(library.queriedCutoffs.single, DateTime(2026, 7, 16));
    });

    test('a capped result set emits everything, then signals truncation',
        () async {
      library.assets = List.generate(
          backfillQueryLimit,
          (i) => FakeAsset('t$i', 'IMG_t$i.jpg',
              DateTime(2026, 7, 17, 8, 0, i ~/ 60, i % 60 * 16), bytesOf(1)));
      final delivered = <String>[];
      intake.attachSink((p, _) async {
        delivered.add(p.assetId);
        return true;
      });
      await expectLater(intake.backfillScan(lookbackDays: 2),
          throwsA(isA<BackfillWindowTruncated>()));
      // Everything the query returned was processed BEFORE the signal —
      // truncation warns about the unseen tail, it must not abandon work.
      expect(delivered, hasLength(backfillQueryLimit));
    });

    test('sink backpressure: next bytes are read only after the sink returns',
        () async {
      final events = <String>[];
      library.assets = [
        FakeAsset('a', 'IMG_a.jpg', DateTime(2026, 7, 17, 8), bytesOf(1),
            onRead: () => events.add('read:a')),
        FakeAsset('b', 'IMG_b.jpg', DateTime(2026, 7, 17, 9), bytesOf(2),
            onRead: () => events.add('read:b')),
      ];
      intake.attachSink((p, _) async {
        events.add('sink:${p.assetId}');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        events.add('done:${p.assetId}');
        return true;
      });
      await intake.backfillScan(lookbackDays: 2);
      expect(events,
          ['read:a', 'sink:a', 'done:a', 'read:b', 'sink:b', 'done:b'],
          reason: 'reading ahead of the pipeline holds every queued '
              'photo\'s bytes in memory at once (OOM class)');
    });

    test('released photo (sink false) is re-offered by the NEXT scan; '
        'terminal is not', () async {
      library.assets = [
        FakeAsset('keep', 'IMG_k.jpg', DateTime(2026, 7, 17, 8), bytesOf(1)),
        FakeAsset('retry', 'IMG_r.jpg', DateTime(2026, 7, 17, 9), bytesOf(2)),
      ];
      final delivered = <String>[];
      intake.attachSink((p, _) async {
        delivered.add(p.assetId);
        return p.assetId != 'retry'; // 'retry' → released
      });
      await intake.backfillScan(lookbackDays: 2);
      await intake.backfillScan(lookbackDays: 2);
      expect(delivered, ['keep', 'retry', 'retry']);
    });

    // 2026-10-19: past the iOS budget every remaining original used to be
    // read in full just for the sink to release it, after the grant.
    test('shouldContinue false: the rest is left UNREAD — not seen, not '
        'covered — and the next scan offers it', () async {
      final reads = <String>[];
      library.assets = [
        for (final (id, h) in [('a', 8), ('b', 9), ('c', 10)])
          FakeAsset(id, 'IMG_$id.jpg', DateTime(2026, 7, 17, h), bytesOf(h),
              onRead: () => reads.add(id)),
      ];
      final delivered = <String>[];
      intake.attachSink((p, _) async {
        delivered.add(p.assetId);
        return true;
      });
      var asked = 0;
      final frontier = await intake.backfillScan(
          lookbackDays: 2,
          shouldContinue: () => ++asked <= 1); // budget for one photo
      expect(reads, ['a'], reason: 'b and c must not be read at all');
      expect(delivered, ['a']);
      expect(asked, 3, reason: 'asked once per unread photo, so the caller '
          'can count what it left');
      expect(frontier, DateTime(2026, 7, 17, 8),
          reason: 'the frontier stops at the last covered photo');

      final again = await intake.backfillScan(lookbackDays: 2);
      expect(delivered, ['a', 'b', 'c'],
          reason: 'unread photos were never marked seen');
      expect(reads, ['a', 'b', 'c'], reason: 'a stays seen: not re-read');
      expect(again, DateTime(2026, 7, 17, 10));
    });

    test('shouldContinue is not asked for a photo this session already '
        'handled: it costs nothing and still counts as covered', () async {
      library.assets = [
        FakeAsset('a', 'IMG_a.jpg', DateTime(2026, 7, 17, 8), bytesOf(1)),
      ];
      intake.attachSink((p, _) async => true);
      await intake.backfillScan(lookbackDays: 2);
      final frontier = await intake.backfillScan(
          lookbackDays: 2,
          shouldContinue: () => fail('nothing to read, nothing to ask'));
      expect(frontier, DateTime(2026, 7, 17, 8));
    });

    test('onCovered hears each terminal delivery\'s safeFrontier, halted at '
        'a release — what the app checkpoints mid-scan', () async {
      library.assets = [
        for (final (id, h) in [('a', 8), ('b', 9), ('c', 10)])
          FakeAsset(id, 'IMG_$id.jpg', DateTime(2026, 7, 17, h), bytesOf(h)),
      ];
      intake.attachSink((p, _) async => p.assetId != 'b'); // b released
      final heard = <DateTime>[];
      final frontier = await intake.backfillScan(
          lookbackDays: 2, onCovered: (f) async => heard.add(f));
      expect(heard, [DateTime(2026, 7, 17, 8), DateTime(2026, 7, 17, 8)],
          reason: 'c terminated, but nothing may pass the released b');
      expect(frontier, DateTime(2026, 7, 17, 8));
    });

    test('onCovered is never called for a truncated window, and a throwing '
        'one never stops the scan', () async {
      library.assets = [
        for (var i = 0; i < backfillQueryLimit; i++)
          FakeAsset('t$i', 'IMG_$i.jpg',
              DateTime(2026, 7, 17, 8).add(Duration(seconds: i)), bytesOf(1)),
      ];
      var delivered = 0;
      intake.attachSink((p, _) async {
        delivered++;
        return true;
      });
      await expectLater(
          intake.backfillScan(
              lookbackDays: 2,
              onCovered: (_) async => fail('no frontier for a truncated scan')),
          throwsA(isA<BackfillWindowTruncated>()));
      expect(delivered, backfillQueryLimit);

      library.assets = [
        FakeAsset('x', 'IMG_x.jpg', DateTime(2026, 7, 17, 11), bytesOf(2)),
        FakeAsset('y', 'IMG_y.jpg', DateTime(2026, 7, 17, 12), bytesOf(3)),
      ];
      final frontier = await intake.backfillScan(
          lookbackDays: 2, onCovered: (_) async => throw StateError('prefs'));
      expect(frontier, DateTime(2026, 7, 17, 12));
    });

    // 2026-10-19: a quick open walked the past week's already-logged
    // originals, oldest first, before it reached today's meal.
    group('newestDayFirst (the app\'s catch-up)', () {
      List<FakeAsset> week(List<String> reads) => [
            for (final (id, d, h) in [
              ('mon8', 16, 8),
              ('mon12', 16, 12),
              ('tue9', 17, 9),
              ('tue11', 17, 11),
            ])
              FakeAsset(id, 'IMG_$id.jpg', DateTime(2026, 7, d, h), bytesOf(h),
                  onRead: () => reads.add(id)),
          ];

      test('the newest day goes first, in shooting order (the leftover '
          'check needs that day\'s earlier meals logged), then the rest '
          'oldest-first — each read once', () async {
        final reads = <String>[];
        library.assets = week(reads);
        final delivered = <String>[];
        final safes = <DateTime?>[];
        intake.attachSink((p, safe) async {
          delivered.add(p.assetId);
          safes.add(safe);
          return true;
        });
        final heard = <DateTime>[];
        final frontier = await intake.backfillScan(
            lookbackDays: 2,
            newestDayFirst: true,
            onCovered: (f) async => heard.add(f));
        expect(delivered, ['tue9', 'tue11', 'mon8', 'mon12']);
        expect(reads, delivered, reason: 'no photo read twice');
        expect(safes.take(2), [null, null],
            reason: 'the first pass claims no coverage');
        expect(heard, [DateTime(2026, 7, 16, 8), DateTime(2026, 7, 16, 12)]);
        expect(frontier, DateTime(2026, 7, 17, 11),
            reason: 'tue photos are seen, so the coverage pass counts them');
      });

      test('a photo the first pass released is not offered again in the same '
          'scan, and the frontier stops in front of it', () async {
        final reads = <String>[];
        library.assets = week(reads);
        final delivered = <String>[];
        intake.attachSink((p, _) async {
          delivered.add(p.assetId);
          return p.assetId != 'tue9'; // a transient failure
        });
        final heard = <DateTime>[];
        final frontier = await intake.backfillScan(
            lookbackDays: 2,
            newestDayFirst: true,
            onCovered: (f) async => heard.add(f));
        expect(delivered, ['tue9', 'tue11', 'mon8', 'mon12']);
        expect(heard, [DateTime(2026, 7, 16, 8), DateTime(2026, 7, 16, 12)]);
        expect(frontier, DateTime(2026, 7, 16, 12));

        await intake.backfillScan(lookbackDays: 2, newestDayFirst: true);
        expect(delivered.skip(4), ['tue9'], reason: 'the next scan retries');
      });

      test('the newest day is the newest NOT yet handled this session', () async {
        final reads = <String>[];
        library.assets = week(reads);
        final delivered = <String>[];
        intake.attachSink((p, _) async {
          delivered.add(p.assetId);
          return true;
        });
        await intake.backfillScan(lookbackDays: 2);
        library.assets = [
          ...library.assets,
          FakeAsset('mon20', 'IMG_mon20.jpg', DateTime(2026, 7, 16, 20),
              bytesOf(20)),
        ];
        await intake.backfillScan(lookbackDays: 2, newestDayFirst: true);
        expect(delivered.skip(4), ['mon20']);
      });
    });

    test('frontier halts at the first failure and at retryable releases',
        () async {
      library.assets = [
        FakeAsset('ok1', 'IMG_1.jpg', DateTime(2026, 7, 17, 8), bytesOf(1)),
        FakeAsset('bad', 'IMG_2.jpg', DateTime(2026, 7, 17, 9), null),
        FakeAsset('ok2', 'IMG_3.jpg', DateTime(2026, 7, 17, 10), bytesOf(3)),
      ];
      intake.attachSink((p, _) async => true);
      final frontier = await intake.backfillScan(lookbackDays: 2);
      // ok2 processed fine, but the watermark may not pass 'bad'.
      expect(frontier, DateTime(2026, 7, 17, 8));
    });

    test('oversize photos are covered (permanent skip), null-bytes are not',
        () async {
      library.assets = [
        FakeAsset('big', 'IMG_big.jpg', DateTime(2026, 7, 17, 8),
            Uint8List(maxPhotoBytes + 1)),
        FakeAsset('flaky', 'IMG_f.jpg', DateTime(2026, 7, 17, 9), null),
      ];
      intake.attachSink((p, _) async => true);
      await intake.backfillScan(lookbackDays: 2);
      // Second scan: oversize NOT re-read (seen), flaky re-offered.
      var flakyReads = 0;
      library.assets = [
        FakeAsset('big', 'IMG_big.jpg', DateTime(2026, 7, 17, 8),
            Uint8List(maxPhotoBytes + 1),
            onRead: () => fail('oversize must stay covered')),
        FakeAsset('flaky', 'IMG_f.jpg', DateTime(2026, 7, 17, 9), bytesOf(2),
            onRead: () => flakyReads++),
      ];
      await intake.backfillScan(lookbackDays: 2);
      expect(flakyReads, 1);
    });

    test('safeFrontier per delivery: own createDate while clean, halted '
        'value after a failure, null when truncated', () async {
      library.assets = [
        FakeAsset('a', 'IMG_a.jpg', DateTime(2026, 7, 17, 8), bytesOf(1)),
        FakeAsset('bad', 'IMG_bad.jpg', DateTime(2026, 7, 17, 9), null),
        FakeAsset('b', 'IMG_b.jpg', DateTime(2026, 7, 17, 10), bytesOf(2)),
      ];
      final safes = <DateTime?>[];
      intake.attachSink((p, safe) async {
        safes.add(safe);
        return true;
      });
      await intake.backfillScan(lookbackDays: 2);
      expect(safes, [
        DateTime(2026, 7, 17, 8), // a: clean → its own createDate
        DateTime(2026, 7, 17, 8), // b: after bad → halted at a
      ]);

      // Truncated window: NO frontier may be reported at all.
      library.assets = List.generate(
          backfillQueryLimit,
          (i) => FakeAsset('tt$i', 'IMG_tt$i.jpg',
              DateTime(2026, 7, 17, 9, 0, i ~/ 60, i % 60 * 16), bytesOf(1)));
      safes.clear();
      await expectLater(intake.backfillScan(lookbackDays: 2),
          throwsA(isA<BackfillWindowTruncated>()));
      expect(safes, everyElement(isNull));
    });

    test('a THROWING asset (Android 11+ unreadable) skips, not aborts',
        () async {
      library.assets = [
        FakeAsset('gone', 'IMG_g.jpg', DateTime(2026, 7, 17, 8), null,
            throwOnRead: true),
        FakeAsset('fine', 'IMG_f.jpg', DateTime(2026, 7, 17, 9), bytesOf(1)),
      ];
      final delivered = <String>[];
      intake.attachSink((p, _) async {
        delivered.add(p.assetId);
        return true;
      });
      final frontier = await intake.backfillScan(lookbackDays: 2);
      expect(delivered, ['fine']); // scan survived the poison asset
      expect(frontier, isNull); // but coverage halts before it
    });

    test('stop() quiesces a batch mid-delivery', () async {
      library.assets = [
        FakeAsset('p1', 'IMG_1.jpg', DateTime(2026, 7, 17, 8), bytesOf(1)),
        FakeAsset('p2', 'IMG_2.jpg', DateTime(2026, 7, 17, 9), bytesOf(2)),
      ];
      library.permissionGranted = true;
      await intake.start();
      final delivered = <String>[];
      intake.attachSink((p, _) async {
        delivered.add(p.assetId);
        await intake.stop(); // user flips the toggle mid-batch
        return true;
      });
      await intake.backfillScan(lookbackDays: 2);
      expect(delivered, ['p1'],
          reason: 'meals must not keep auto-logging after the watcher is '
              'disabled');
    });

    test('window honors lookbackDays; older photos excluded', () async {
      library.assets = [
        FakeAsset('a', 'IMG_20260717_080000.jpg',
            DateTime(2026, 7, 17, 8, 0), bytesOf(1)),
        FakeAsset('b', 'IMG_20260716_080000.jpg',
            DateTime(2026, 7, 16, 8, 0), bytesOf(2)),
        FakeAsset('c', 'IMG_20260715_235900.jpg',
            DateTime(2026, 7, 15, 23, 59), bytesOf(3)), // outside 2-day window
      ];
      await intake.backfillScan(lookbackDays: 2);
      await pumpEventQueue();
      expect(emitted.map((p) => p.assetId), ['b', 'a']);
    });

    test('emission is newest-LAST and deliberate=false with metadata', () async {
      library.assets = [
        FakeAsset('new', 'IMG_20260717_090000.jpg',
            DateTime(2026, 7, 17, 9, 0), bytesOf(9)),
        FakeAsset('old', 'IMG_20260716_070000.jpg',
            DateTime(2026, 7, 16, 7, 0), bytesOf(7)),
      ];
      await intake.backfillScan();
      await pumpEventQueue();
      expect(emitted.map((p) => p.assetId), ['old', 'new']);
      final old = emitted.first;
      expect(old.deliberate, isFalse); // §2.3: automated intake is strict
      expect(old.fileName, 'IMG_20260716_070000.jpg');
      expect(old.capturedAt, DateTime(2026, 7, 16, 7, 0, 0));
      expect(old.bytes, bytesOf(7));
    });

    test('lookbackDays unset uses the settings-provided default (2)', () async {
      await intake.backfillScan();
      expect(library.queriedCutoffs.single, DateTime(2026, 7, 16));
    });

    test('null/empty bytes skipped; >25 MB refused before decode (§8)',
        () async {
      library.assets = [
        FakeAsset('nul', 'IMG_20260717_080000.jpg',
            DateTime(2026, 7, 17, 8, 0), null),
        FakeAsset('big', 'IMG_20260717_081000.jpg',
            DateTime(2026, 7, 17, 8, 10),
            Uint8List(maxPhotoBytes + 1)),
        FakeAsset('ok', 'IMG_20260717_082000.jpg',
            DateTime(2026, 7, 17, 8, 20), bytesOf(1)),
      ];
      await intake.backfillScan();
      await pumpEventQueue();
      expect(emitted.map((p) => p.assetId), ['ok']);
    });

    test('capturedAt falls back to asset create date on junk names', () async {
      library.assets = [
        FakeAsset('x', 'restored.jpeg', DateTime(2026, 7, 16, 18, 5),
            bytesOf(4)),
      ];
      await intake.backfillScan();
      await pumpEventQueue();
      expect(emitted.single.capturedAt, DateTime(2026, 7, 16, 18, 5));
    });
  });

  group('change-notify watch (§6.1)', () {
    test('start requests permission and subscribes; new assets emit once',
        () async {
      final library = FakePhotoLibrary();
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => now);
      final emitted = <IntakePhoto>[];
      intake.photos.listen(emitted.add);

      await intake.start();
      expect(library.permissionRequests, 1);
      expect(library.changeListener, isNotNull);

      library.assets = [
        FakeAsset('n1', 'IMG_20260717_120100.jpg',
            now.add(const Duration(minutes: 1)), bytesOf(1)),
      ];
      library.changeListener!();
      await pumpEventQueue();
      expect(emitted.map((p) => p.assetId), ['n1']);

      // A second change notification must not re-emit the same asset.
      library.changeListener!();
      await pumpEventQueue();
      expect(emitted.length, 1);
    });

    test('permission denied: silent no-op, no subscription', () async {
      final library = FakePhotoLibrary()..permissionGranted = false;
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => now);
      await intake.start();
      expect(library.changeListener, isNull);
    });

    test('stop unsubscribes', () async {
      final library = FakePhotoLibrary();
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => now);
      await intake.start();
      expect(library.changeListener, isNotNull);
      await intake.stop();
      expect(library.changeListener, isNull);
    });
  });
}
