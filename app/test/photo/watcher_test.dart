// Watcher / backfill behavior (spec §6.1, §6.4): lookback window math,
// newest-last emission, deliberate=false, session dedup, permission flow,
// 25 MB cap (§8).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

  /// Ids whose lookup fails (no answer either way).
  final Set<String> unanswerable = {};
  final List<List<String>> lookedUp = [];

  @override
  Future<Map<String, LibraryAsset?>> imagesByIds(List<String> ids) async {
    lookedUp.add(List.of(ids));
    return {
      for (final id in ids)
        if (!unanswerable.contains(id))
          id: assets.where((a) => a.id == id).firstOrNull,
    };
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

    test('passOver (the background run\'s too-often-deferred photos): '
        'counted covered without being read, so the frontier passes it',
        () async {
      final reads = <String>[];
      library.assets = [
        for (final (id, h) in [('a', 8), ('stuck', 9), ('c', 10)])
          FakeAsset(id, 'IMG_$id.jpg', DateTime(2026, 7, 17, h), bytesOf(h),
              onRead: () => reads.add(id)),
      ];
      final passing = LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: library,
          clock: () => now,
          passOver: (id) => id == 'stuck');
      final safes = <DateTime?>[];
      passing.attachSink((p, safe) async {
        safes.add(safe);
        return true;
      });
      final frontier = await passing.backfillScan(lookbackDays: 2);
      expect(reads, ['a', 'c']);
      expect(safes, [DateTime(2026, 7, 17, 8), DateTime(2026, 7, 17, 10)]);
      expect(frontier, DateTime(2026, 7, 17, 10));
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

  // Design G1b, 2026-10-23: photos another app imports late keep their old
  // capture date, so only the library's change history finds them.
  group('lateImportScan (photos imported late)', () {
    // The window: 7 days back from Friday the 17th, so from the 11th.
    final takenTuesday = DateTime(2026, 7, 14, 19, 5);
    late Directory root;
    late FakePhotoLibrary library;
    late FakePhotoChangeSource history;
    late LibraryPhotoIntake intake;
    late List<(IntakePhoto, DateTime?)> delivered;
    late List<LateImportReport> reports;
    late Set<String> logged;
    late List<String> reads;

    LateImportCursor cursor() => LateImportCursor(
        source: history,
        store: LocalNoBackupStore(
            root: () async => root, createMissingDirectory: true),
        clock: () => now);

    LibraryPhotoIntake makeIntake({DateTime Function()? clock}) =>
        LibraryPhotoIntake(
            lookbackDays: () => 7,
            library: library,
            clock: clock ?? () => now,
            lateImports: cursor(),
            loggedAssetIds: (ids) async => logged.intersection(ids.toSet()),
            onLateImportPass: reports.add);

    FakeAsset asset(String id, DateTime created) => FakeAsset(
        id, '$id.HEIC', created, bytesOf(id.length),
        onRead: () => reads.add(id));

    /// The history reports [ids] once, then nothing new.
    void insert(List<String> ids) {
      var reported = false;
      history.onInsertedImagesSince = (token, _, _, _) {
        if (reported) {
          return InsertedImages(PhotoChangeStatus.ok,
              token: token, deviceTag: history.deviceTag);
        }
        reported = true;
        return InsertedImages(PhotoChangeStatus.ok,
            token: history.nextToken(),
            deviceTag: history.deviceTag,
            ids: [
              for (final id in ids)
                InsertedImage(id,
                    created: library.assets
                        .firstWhere((a) => a.id == id)
                        .createDateTime),
            ]);
      };
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(done(), isTrue, reason: 'timed out');
    }

    setUp(() async {
      root = Directory.systemTemp.createTempSync('watcher_late_import');
      library = FakePhotoLibrary();
      history = FakePhotoChangeSource();
      delivered = [];
      reports = [];
      logged = {};
      reads = [];
      intake = makeIntake();
      intake.attachSink((p, safe) async {
        delivered.add((p, safe));
        return true;
      });
      await intake.lateImportScan(); // the cursor starts from here
      expect(reports.single.status, lateImportReset);
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('a late import goes through the sink with no frontier, automatic, '
        'dated by its capture time', () async {
      library.assets = [asset('late', takenTuesday)];
      insert(['late']);
      await intake.lateImportScan();
      final (photo, safe) = delivered.single;
      expect(photo.assetId, 'late');
      expect(safe, isNull, reason: 'it must never move a watermark');
      expect(photo.deliberate, isFalse);
      expect(photo.capturedAt, takenTuesday);
      expect(reports.last.status, 'ok');
      expect(reports.last.caught, 1);
      expect((await cursor().read())!.carry, isEmpty);
    });

    test('the live watcher looks after each change, without moving its '
        'cutoff and without a rescan', () async {
      await intake.start();
      final startedAt = library.queriedCutoffs.length;
      library.assets = [asset('late', takenTuesday)];
      insert(['late']);
      library.changeListener!();
      await until(() => delivered.isNotEmpty);
      expect(delivered.single.$1.assetId, 'late');
      expect(delivered.single.$2, isNull);
      // The createDate query never listed it; the next change asks from
      // the same cutoff as before.
      library.changeListener!();
      await until(() => reports.length >= 3);
      final cutoffs = library.queriedCutoffs.sublist(startedAt);
      expect(cutoffs.toSet(), {now},
          reason: 'only the live query, from the start time: no window '
              'listing, and the late photo moved no cutoff');
      expect(delivered, hasLength(1));
    });

    test('a photo this session already handled is not read again, and a '
        'logged one never enters the carry', () async {
      library.assets = [
        asset('seen', DateTime(2026, 7, 17, 8)),
        asset('meal', takenTuesday),
      ];
      logged.add('meal');
      await intake.backfillScan(lookbackDays: 2); // reads 'seen' only
      expect(reads, ['seen']);
      insert(['seen', 'meal']);
      await intake.lateImportScan();
      expect(reads, ['seen'], reason: 'neither was read again');
      expect((await cursor().read())!.carry, isEmpty);
      expect(reports.last.caught, 0);
    });

    test('a photo a scan of this session released is not tried again by the '
        'pass: it waits in the carry for the next session', () async {
      library.assets = [asset('flaky', DateTime(2026, 7, 17, 8))];
      intake.attachSink((p, safe) async {
        delivered.add((p, safe));
        return false; // a transient failure: released for a retry
      });
      await intake.backfillScan(lookbackDays: 2);
      expect(reads, ['flaky']);
      insert(['flaky']);
      await intake.lateImportScan();
      expect(reads, ['flaky'], reason: 'one try per session from the pass');
      expect([for (final e in (await cursor().read())!.carry) e.id],
          ['flaky']);
      // The next session (the next background run, a relaunch) tries it.
      final next = makeIntake()
        ..attachSink((p, safe) async {
          delivered.add((p, safe));
          return true;
        });
      await next.lateImportScan();
      expect(reads, ['flaky', 'flaky']);
      expect(delivered.last.$2, isNull);
      expect((await cursor().read())!.carry, isEmpty);
      // Settled since: a later pass in that session leaves it alone.
      await next.lateImportScan();
      expect(reads, hasLength(2));
    });

    test('once a scan settles a released photo, the pass forgets it too',
        () async {
      library.assets = [asset('flaky', DateTime(2026, 7, 17, 8))];
      var fail = true;
      intake.attachSink((p, safe) async {
        delivered.add((p, safe));
        return !fail;
      });
      await intake.backfillScan(lookbackDays: 2); // released
      insert(['flaky']);
      await intake.lateImportScan(); // carried, not tried
      fail = false;
      await intake.backfillScan(lookbackDays: 2); // the scan's own retry
      await intake.lateImportScan();
      expect(reads, ['flaky', 'flaky'],
          reason: 'two scans, no read from the pass');
      expect((await cursor().read())!.carry, isEmpty);
    });

    test('stop() quiesces: a stopped watcher offers nothing until started '
        'again, and a stop mid-pass leaves the rest in the carry', () async {
      library.assets = [
        asset('a', DateTime(2026, 7, 13, 8)),
        asset('b', takenTuesday),
      ];
      await intake.start();
      await intake.stop();
      insert(['a', 'b']);
      await intake.lateImportScan();
      expect(delivered, isEmpty);
      expect(history.insertedImagesSinceTokens, isEmpty,
          reason: 'not even the history is read');
      await intake.start();
      intake.attachSink((p, _) async {
        delivered.add((p, null));
        await intake.stop(); // switched off during the first photo
        return true;
      });
      await intake.lateImportScan();
      expect(delivered.map((d) => d.$1.assetId), ['a'],
          reason: 'oldest first; b is never read');
      expect([for (final e in (await cursor().read())!.carry) e.id], ['b']);
    });

    test('passes run one at a time: the second reads on from the token the '
        'first stored', () async {
      final first = intake.lateImportScan();
      final second = intake.lateImportScan();
      await Future.wait([first, second]);
      final tokens = history.insertedImagesSinceTokens;
      expect(tokens, hasLength(2));
      expect(tokens[1], tokens[0],
          reason: 'nothing changed, so the token did not move — and the '
              'second call waited for the first');
      final storedNow = (await cursor().read())!.token;
      expect(storedNow, tokens[0]);
    });

    test('a complete scan of the whole window settles a rescan asked before '
        'it started; a narrowed one, or one that left photos unread, does '
        'not', () async {
      var t = now;
      final c = LateImportCursor(
          source: history,
          store: LocalNoBackupStore(
              root: () async => root, createMissingDirectory: true),
          clock: () => t);
      final timed = LibraryPhotoIntake(
          lookbackDays: () => 7,
          library: library,
          clock: () => t,
          lateImports: c,
          onLateImportPass: reports.add)
        ..attachSink((p, _) async => true);
      library.assets = [asset('w', DateTime(2026, 7, 16, 8))];
      await timed.backfillScan(); // the whole window, before the request
      // A minute later the history has expired: a rescan is owed.
      t = now.add(const Duration(minutes: 1));
      history.onInsertedImagesSince = (_, _, _, _) => InsertedImages(
          PhotoChangeStatus.expired,
          token: history.nextToken(),
          deviceTag: history.deviceTag);
      // No budget: the rescan is noted, the window not listed.
      await timed.lateImportScan(shouldContinue: () => false);
      expect(reports.last.rescanning, isTrue);
      history.onInsertedImagesSince = null;
      final listings = library.queriedCutoffs.length;
      // A narrowed scan (the background watermark) covers nothing.
      t = now.add(const Duration(minutes: 2));
      await timed.backfillScan(since: DateTime(2026, 7, 16, 12));
      await timed.lateImportScan(shouldContinue: () => false);
      expect(reports.last.rescanning, isTrue);
      // Nor does a whole-window scan that left a photo unread.
      library.assets = [...library.assets, asset('x', DateTime(2026, 7, 15))];
      await timed.backfillScan(shouldContinue: () => false);
      await timed.lateImportScan(shouldContinue: () => false);
      expect(reports.last.rescanning, isTrue);
      // The whole window, every photo read: the request is covered.
      t = now.add(const Duration(minutes: 3));
      await timed.backfillScan();
      await timed.lateImportScan(shouldContinue: () => false);
      expect(reports.last.rescanning, isFalse);
      expect((await c.read())!.rescanBefore, isNull);
      expect(library.queriedCutoffs.length, listings + 3,
          reason: 'the three scans only: the rescan never listed the window');
    });

    test('no change history (Android): nothing to do', () async {
      final plain = LibraryPhotoIntake(
          lookbackDays: () => 7, library: library, clock: () => now);
      await plain.lateImportScan();
      await plain.start();
      library.changeListener!();
      await pumpEventQueue();
      expect(library.lookedUp, isEmpty);
      expect(history.insertedImagesSinceTokens, isEmpty);
    });
  });

  // Design G2a: every photo the watcher reads carries how it was taken —
  // from the bytes it already holds, plus ONE album lookup per scan.
  group('capture (G2a)', () {
    late FakePhotoLibrary library;
    late List<IntakePhoto> delivered;
    late List<DateTime> albumAsks;

    Uint8List glassesJpeg() {
      final image = img.Image(width: 8, height: 6);
      image.exif.imageIfd['Make'] = 'Meta AI';
      image.exif.imageIfd['Model'] = 'Ray-Ban Meta Smart Glasses';
      image.exif.exifIfd['DateTimeOriginal'] = '2026:07:16 12:29:58';
      return Uint8List.fromList(img.encodeJpg(image));
    }

    LibraryPhotoIntake makeIntake(
        {Future<Set<String>> Function(DateTime since)? albums,
        Duration timeout = const Duration(seconds: 2)}) {
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: library,
          clock: () => now,
          metaAlbumIds: albums,
          metaAlbumTimeout: timeout);
      intake.attachSink((p, _) async {
        delivered.add(p);
        return true;
      });
      return intake;
    }

    setUp(() {
      library = FakePhotoLibrary();
      delivered = [];
      albumAsks = [];
    });

    test('filled from the bytes read: EXIF, the device, the creation date',
        () async {
      final created = DateTime(2026, 7, 16, 12, 30);
      library.assets = [
        FakeAsset('glasses', 'IMG_0042.JPG', created, glassesJpeg()),
        FakeAsset('named', 'photo-9_singular_display_fullPicture.HEIC',
            created.add(const Duration(minutes: 1)), bytesOf(9)),
        FakeAsset('camera', 'IMG_0043.HEIC',
            created.add(const Duration(minutes: 2)), bytesOf(3)),
      ];
      await makeIntake().backfillScan();
      final byId = {for (final p in delivered) p.assetId: p.capture!};
      expect(byId['glasses']!.device, CaptureDevice.metaGlasses);
      expect(byId['glasses']!.signal, CaptureSignal.exif);
      expect(byId['glasses']!.exif!.dateTimeOriginal,
          DateTime(2026, 7, 16, 12, 29, 58));
      expect(byId['glasses']!.createDate, created);
      expect(byId['named']!.signal, CaptureSignal.filename);
      expect(byId['camera']!.device, CaptureDevice.unknown);
      expect(byId['camera']!.exif, isNull);
    });

    test('ONE album lookup per scan, from before its oldest photo; a member '
        'is a glasses photo by its album', () async {
      final oldest = DateTime(2026, 7, 16, 9, 0);
      library.assets = [
        FakeAsset('b', 'IMG_2.HEIC', oldest.add(const Duration(hours: 2)),
            bytesOf(2)),
        FakeAsset('a', 'IMG_1.HEIC', oldest, bytesOf(1)),
        FakeAsset('c', 'IMG_3.HEIC', oldest.add(const Duration(hours: 3)),
            bytesOf(3)),
      ];
      final intake = makeIntake(albums: (since) async {
        albumAsks.add(since);
        return {'b'};
      });
      await intake.backfillScan();
      expect(albumAsks, hasLength(1));
      expect(albumAsks.single.isAfter(oldest), isFalse);
      final byId = {for (final p in delivered) p.assetId: p.capture!};
      expect(byId['b']!.signal, CaptureSignal.album);
      expect(byId['b']!.strength, CaptureStrength.strong);
      expect(byId['a']!.device, CaptureDevice.unknown);
      expect(byId['c']!.device, CaptureDevice.unknown);
      // A second scan asks again (members may have joined) …
      library.assets = [
        ...library.assets,
        FakeAsset('d', 'IMG_4.HEIC', oldest.add(const Duration(hours: 4)),
            bytesOf(4)),
      ];
      await intake.backfillScan();
      expect(albumAsks, hasLength(2));
      // … but a scan that reads nothing asks nothing.
      await intake.backfillScan();
      expect(albumAsks, hasLength(2));
    });

    test('a failing, throwing or stuck album lookup never holds or drops a '
        'photo: it is simply in no album', () async {
      final created = DateTime(2026, 7, 16, 12);
      for (final albums in <Future<Set<String>> Function(DateTime)>[
        (_) async => throw StateError('channel gone'),
        (_) => Future<Set<String>>.error(StateError('late error')),
        (_) => Completer<Set<String>>().future, // never answers
      ]) {
        delivered.clear();
        library.assets = [
          FakeAsset('x', 'photo-1_singular_display_fullPicture.HEIC', created,
              bytesOf(1)),
          FakeAsset('y', 'IMG_1.HEIC', created.add(const Duration(minutes: 1)),
              bytesOf(2)),
        ];
        final frontier = await makeIntake(
                albums: albums, timeout: const Duration(milliseconds: 20))
            .backfillScan();
        expect(delivered.map((p) => p.assetId), ['x', 'y']);
        expect(frontier, created.add(const Duration(minutes: 1)),
            reason: 'coverage is unchanged');
        expect(delivered[0].capture!.signal, CaptureSignal.filename);
        expect(delivered[1].capture!.device, CaptureDevice.unknown);
      }
    });

    test('Android (no album source): no lookup, the rest still read',
        () async {
      library.assets = [
        FakeAsset('g', 'IMG_0042.JPG', DateTime(2026, 7, 16, 12),
            glassesJpeg()),
      ];
      await makeIntake().backfillScan();
      expect(delivered.single.capture!.signal, CaptureSignal.exif);
    });

    test('metaAlbumAssetIds asks for the table titles; any trouble is empty',
        () async {
      final source = FakePhotoChangeSource();
      final since = DateTime(2026, 7, 16);
      DateTime? askedSince;
      int? askedLimit;
      source.onAlbumAssetIds = (titles, s, limit) {
        askedSince = s;
        askedLimit = limit;
        return const AlbumAssetIds(PhotoChangeStatus.ok, ids: ['a', 'b']);
      };
      expect(await metaAlbumAssetIds(source, since: since), {'a', 'b'});
      expect(source.albumAssetIdsTitles.single,
          ['Meta AI', 'Meta View', 'Ray-Ban Meta', 'Ray-Ban Stories']);
      expect(askedSince, since);
      expect(askedLimit, albumAssetIdsMaxLimit);
      for (final status in [
        PhotoChangeStatus.error,
        PhotoChangeStatus.denied,
        PhotoChangeStatus.unsupported,
      ]) {
        source.onAlbumAssetIds =
            (_, _, _) => AlbumAssetIds(status, ids: const ['a']);
        expect(await metaAlbumAssetIds(source, since: since), isEmpty);
      }
      source.onAlbumAssetIds = (_, _, _) => throw StateError('boom');
      expect(await metaAlbumAssetIds(source, since: since), isEmpty);
    });
  });

  // Design G2b: for a glasses photo the dating guard could re-date, the
  // watcher adds what says its creation date is only the import time — the
  // library's added date, and the late-import pass that offered it. Every
  // other photo costs no lookup.
  group('import-time evidence (G2b)', () {
    late FakePhotoLibrary library;
    late List<IntakePhoto> delivered;
    late List<String> asked;

    // Lunch at 12:29:58 by the glasses' clock.
    Uint8List glassesJpeg() {
      final image = img.Image(width: 8, height: 6);
      image.exif.imageIfd['Make'] = 'Meta AI';
      image.exif.imageIfd['Model'] = 'Ray-Ban Meta Smart Glasses';
      image.exif.exifIfd['DateTimeOriginal'] = '2026:07:16 12:29:58';
      return Uint8List.fromList(img.encodeJpg(image));
    }

    Uint8List cameraJpeg() {
      final image = img.Image(width: 8, height: 6);
      image.exif.imageIfd['Make'] = 'Apple';
      image.exif.exifIfd['DateTimeOriginal'] = '2026:07:16 12:29:58';
      return Uint8List.fromList(img.encodeJpg(image));
    }

    // Created 9 h 7 min after the shutter: no zone is that far off.
    final importedAt = DateTime(2026, 7, 16, 21, 37);
    final addedAt = importedAt.add(const Duration(seconds: 15));

    LibraryPhotoIntake makeIntake(
        {Future<DateTime?> Function(String id)? added,
        Duration timeout = const Duration(seconds: 2),
        LateImportCursor? lateImports}) {
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: library,
          clock: () => now,
          lateImports: lateImports,
          assetAddedDate: added,
          addedDateTimeout: timeout);
      intake.attachSink((p, _) async {
        delivered.add(p);
        return true;
      });
      return intake;
    }

    Future<DateTime?> lookup(String id) async {
      asked.add(id);
      return addedAt;
    }

    setUp(() {
      library = FakePhotoLibrary();
      delivered = [];
      asked = [];
    });

    test('asked only for a glasses photo whose creation date and shutter '
        'disagree', () async {
      library.assets = [
        FakeAsset('late', 'IMG_1.JPG', importedAt, glassesJpeg()),
        FakeAsset('ontime', 'IMG_2.JPG', DateTime(2026, 7, 16, 12, 30),
            glassesJpeg()),
        FakeAsset('camera', 'IMG_3.JPG', importedAt, cameraJpeg()),
      ];
      await makeIntake(added: lookup).backfillScan();
      expect(asked, ['late']);
      final byId = {for (final p in delivered) p.assetId: p.capture!};
      expect(byId['late']!.addedDate, addedAt);
      expect(byId['late']!.importPassAt, isNull,
          reason: 'a scan by date, not the late-import pass');
      expect(byId['late']!.isMetaGlasses, isTrue,
          reason: 'the G2a reading is kept');
      expect(byId['ontime']!.addedDate, isNull);
      expect(byId['camera']!.addedDate, isNull);
      // The intake still dates each photo as before; the pipeline decides,
      // with the evidence (capture_dating.dart).
      expect(byId.length, 3);
      expect({for (final p in delivered) p.assetId: p.capturedAt}, {
        'late': importedAt,
        'ontime': DateTime(2026, 7, 16, 12, 30),
        'camera': importedAt,
      });
    });

    test('a failing, throwing or stuck lookup never holds a photo: it goes on '
        'without the evidence', () async {
      for (final added in <Future<DateTime?> Function(String)>[
        (_) async => null,
        (_) async => throw StateError('channel gone'),
        (_) => Future<DateTime?>.error(StateError('late error')),
        (_) => Completer<DateTime?>().future, // never answers
      ]) {
        delivered.clear();
        library.assets = [
          FakeAsset('late', 'IMG_1.JPG', importedAt, glassesJpeg()),
        ];
        final frontier = await makeIntake(
                added: added, timeout: const Duration(milliseconds: 20))
            .backfillScan();
        expect(delivered.single.capture!.addedDate, isNull);
        expect(delivered.single.capture!.isMetaGlasses, isTrue);
        expect(frontier, importedAt, reason: 'coverage is unchanged');
      }
    });

    test('the late-import pass adds when it ran', () async {
      final root = Directory.systemTemp.createTempSync('watcher_g2b');
      addTearDown(() => root.deleteSync(recursive: true));
      final history = FakePhotoChangeSource();
      final cursor = LateImportCursor(
          source: history,
          store:
              LocalNoBackupStore(root: () async => root, createMissingDirectory: true),
          clock: () => now);
      final intake = makeIntake(lateImports: cursor); // no added dates
      await intake.lateImportScan(); // the cursor starts here
      library.assets = [
        FakeAsset('late', 'IMG_1.JPG', importedAt, glassesJpeg()),
        FakeAsset('camera', 'IMG_2.JPG', importedAt, cameraJpeg()),
      ];
      history.onInsertedImagesSince = (token, _, _, _) => InsertedImages(
          PhotoChangeStatus.ok,
          token: history.nextToken(),
          deviceTag: history.deviceTag,
          ids: [
            InsertedImage('late', created: importedAt),
            InsertedImage('camera', created: importedAt),
          ]);
      await intake.lateImportScan();
      final byId = {for (final p in delivered) p.assetId: p.capture!};
      expect(byId['late']!.importPassAt, now);
      expect(byId['late']!.addedDate, isNull);
      expect(byId['camera']!.importPassAt, isNull,
          reason: 'nothing the guard could use it for');
    });

    test('assetAddedDate reads the channel answer for that id; any trouble '
        'is unknown', () async {
      final source = FakePhotoChangeSource();
      source.onAssetDates = (ids) => AssetDates(PhotoChangeStatus.ok, ids: [
            InsertedImage('other', added: DateTime(2026, 1, 1)),
            InsertedImage(ids.single, created: importedAt, added: addedAt),
          ]);
      expect(await assetAddedDate(source, 'A/L0/001'), addedAt);
      expect(source.assetDatesIds.single, ['A/L0/001']);
      source.onAssetDates =
          (ids) => const AssetDates(PhotoChangeStatus.ok, ids: []);
      expect(await assetAddedDate(source, 'gone'), isNull);
      for (final status in [
        PhotoChangeStatus.error,
        PhotoChangeStatus.denied,
        PhotoChangeStatus.unsupported,
      ]) {
        source.onAssetDates = (ids) => AssetDates(status,
            ids: [InsertedImage(ids.single, added: addedAt)]);
        expect(await assetAddedDate(source, 'x'), isNull);
      }
      source.onAssetDates = (_) => throw StateError('boom');
      expect(await assetAddedDate(source, 'x'), isNull);
    });
  });
}
