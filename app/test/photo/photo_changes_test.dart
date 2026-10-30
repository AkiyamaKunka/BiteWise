// The late-import cursor (lib/services/photo/photo_changes.dart, design
// G1b): what one pass reads from the photo library's change history, what
// it keeps in the backup-excluded store before offering anything, and how
// it acts on every status — against a scripted change source, a real
// LocalNoBackupStore in a temp directory and fake watcher hooks.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Asset implements LibraryAsset {
  _Asset(this.id, this.createDateTime);
  @override
  final String id;
  @override
  final DateTime createDateTime;
  @override
  Future<String> fileName() async => '$id.HEIC';
  @override
  Future<Uint8List?> originBytes() async => Uint8List(3);
}

/// The watcher's side of a pass, scripted.
class _Watcher {
  final Map<String, _Asset> library = {};
  final Set<String> settled = {};
  final Set<String> logged = {};
  final Set<String> unanswerable = {};
  final List<List<String>> offered = [];
  final List<List<String>> loggedAsked = [];
  int windowListings = 0;
  bool Function()? shouldContinue;

  /// Whether the pipeline reaches a verdict (true) or releases (false).
  bool Function(String id) verdict = (_) => true;

  /// Runs before each offered photo is "processed".
  Future<void> Function(String id)? before;

  void add(String id, DateTime created) => library[id] = _Asset(id, created);

  LateImportHooks hooks() => LateImportHooks(
        settled: settled.contains,
        logged: (ids) async {
          loggedAsked.add(List.of(ids));
          return {
            for (final id in ids)
              if (logged.contains(id)) id,
          };
        },
        resolve: (ids) async => {
          for (final id in ids)
            if (!unanswerable.contains(id)) id: library[id],
        },
        listWindow: (cutoff) async {
          windowListings++;
          return [
            for (final a in library.values)
              if (!a.createDateTime.isBefore(cutoff)) a,
          ];
        },
        shouldContinue: shouldContinue,
        offer: (assets, onSettled) async {
          offered.add([for (final a in assets) a.id]);
          for (final a in assets) {
            await before?.call(a.id);
            if (verdict(a.id)) await onSettled(a.id, delivered: true);
          }
        },
      );
}

const _tag = 'a1b2c3d4';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Friday 2026-10-23 noon; a 7-day lookback starts on the 17th.
  final now = DateTime(2026, 10, 23, 12);
  final cutoff = DateTime(2026, 10, 17);
  DateTime hoursAgo(int h) => now.subtract(Duration(hours: h));

  late Directory root;
  late FakePhotoChangeSource source;
  late _Watcher watcher;

  setUp(() {
    root = Directory.systemTemp.createTempSync('photo_changes_test');
    source = FakePhotoChangeSource(deviceTag: _tag);
    watcher = _Watcher();
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LocalNoBackupStore store() =>
      LocalNoBackupStore(root: () async => root, createMissingDirectory: true);

  /// A fresh cursor each time: a later pass may as well be the other
  /// engine's, so nothing may live in the instance.
  LateImportCursor cursor({DateTime Function()? clock}) => LateImportCursor(
      source: source, store: store(), clock: clock ?? () => now);

  Future<LateImportReport> pass(
          {bool rescan = true,
          DateTime? windowCoveredFrom,
          DateTime Function()? clock}) =>
      cursor(clock: clock).pass(
          cutoff: cutoff,
          hooks: watcher.hooks(),
          rescan: rescan,
          windowCoveredFrom: windowCoveredFrom);

  Future<LateImportCursorState?> stored() => cursor().read();

  Future<void> seed(
      {String token = 'T1',
      String tag = _tag,
      List<LateImportEntry> carry = const [],
      DateTime? rescanBefore,
      DateTime? rescanAt}) async {
    expect(
        await store().write(
            photoChangeCursorDocument,
            LateImportCursorState(
                    token: token,
                    deviceTag: tag,
                    carry: carry,
                    rescanBefore: rescanBefore,
                    rescanAt: rescanAt,
                    at: hoursAgo(1))
                .toJson(),
            version: photoChangeCursorVersion),
        isTrue);
  }

  InsertedImages inserted(List<String> ids,
          {String token = 'T2',
          int dropped = 0,
          bool truncated = false,
          String tag = _tag}) =>
      InsertedImages(PhotoChangeStatus.ok,
          token: token,
          deviceTag: tag,
          dropped: dropped,
          truncated: truncated,
          ids: [
            for (final id in ids)
              InsertedImage(id, created: watcher.library[id]?.createDateTime),
          ]);

  List<String> carried(LateImportCursorState? s) =>
      [for (final e in s?.carry ?? const <LateImportEntry>[]) e.id];

  group('starting', () {
    test('the first pass stores the current token and offers nothing',
        () async {
      final r = await pass();
      expect(r.status, lateImportReset);
      expect(source.currentTokenCalls, 1);
      expect(source.insertedImagesSinceTokens, isEmpty,
          reason: 'no history to read before there is a token');
      final s = await stored();
      expect(s!.token, 'fake-token-1');
      expect(s.deviceTag, _tag);
      expect(s.carry, isEmpty);
      expect(s.rescanBefore, isNull, reason: 'nothing was missed yet');
      expect(watcher.offered, isEmpty);
    });

    test('a document that cannot be read starts over the same way',
        () async {
      final dir = Directory('${root.path}/$localStoreDirName')
        ..createSync(recursive: true);
      File('${dir.path}/$photoChangeCursorDocument.json')
          .writeAsStringSync('{"v": 2, "token": ');
      expect((await pass()).status, lateImportReset);
      expect((await stored())!.token, 'fake-token-1');
      await store().write(photoChangeCursorDocument,
          {'token': 'T1', 'device_tag': 'not-a-tag'},
          version: photoChangeCursorVersion);
      expect((await pass()).status, lateImportReset);
      // An older schema version is not this one's.
      await store().write(
          photoChangeCursorDocument, {'token': 'T1', 'device_tag': _tag},
          version: 1);
      expect((await pass()).status, lateImportReset);
      expect(watcher.offered, isEmpty);
    });

    test('a device tag that is not this phone\'s starts over: no offer, the '
        'carry and the rescan let go', () async {
      watcher.add('x', hoursAgo(30));
      watcher.add('y', hoursAgo(20));
      await seed(
          tag: 'deadbeef',
          carry: [LateImportEntry('x', created: hoursAgo(30))],
          rescanBefore: hoursAgo(2),
          rescanAt: hoursAgo(2));
      source.onInsertedImagesSince = (_, _, _, _) => inserted(['y']);
      final r = await pass();
      expect(r.status, lateImportReset);
      expect(watcher.offered, isEmpty);
      final s = await stored();
      expect(s!.deviceTag, _tag);
      expect(s.token, 'fake-token-1');
      expect(s.carry, isEmpty);
      expect(s.rescanBefore, isNull);
    });

    test('no change history (iOS 15) or no access: nothing stored, nothing '
        'offered', () async {
      source.onCurrentToken =
          () => const PhotoChangeToken(PhotoChangeStatus.unsupported);
      expect((await pass()).status, 'unsupported');
      expect(await stored(), isNull);
      source.onCurrentToken =
          () => const PhotoChangeToken(PhotoChangeStatus.denied);
      expect((await pass()).status, 'denied');
      expect(await stored(), isNull);
      expect(watcher.offered, isEmpty);
    });
  });

  group('every status', () {
    setUp(() async {
      watcher.add('a', hoursAgo(48));
      watcher.add('b', hoursAgo(24));
    });

    test('ok: imports inside the window go out, after the new token and the '
        'carry are stored; each leaves the carry with its verdict', () async {
      watcher.add('old', DateTime(2026, 10, 10)); // before the window
      watcher.add('done', hoursAgo(3)); // handled by this session's scans
      watcher.add('meal', hoursAgo(5)); // a meal names it
      watcher.settled.add('done');
      watcher.logged.add('meal');
      await seed();
      source.onInsertedImagesSince =
          (_, _, _, _) => inserted(['done', 'meal', 'b', 'a', 'old']);
      final storedWhileOffering = <List<String>>[];
      watcher.before = (id) async {
        final s = await stored();
        expect(s!.token, 'T2', reason: 'stored before anything is offered');
        storedWhileOffering.add(carried(s));
      };
      final r = await pass();
      expect(r.status, 'ok');
      expect(r.caught, 2);
      expect(watcher.offered, [
        ['b', 'a'],
      ]);
      expect(storedWhileOffering.first, ['b', 'a']);
      expect(storedWhileOffering.last, ['a'], reason: 'b left with its verdict');
      expect(carried(await stored()), isEmpty);
      expect(source.insertedImagesSinceTokens, ['T1']);
      // The next pass reads on from the stored token.
      source.onInsertedImagesSince = null;
      await pass();
      expect(source.insertedImagesSinceTokens, ['T1', 'T2']);
      expect(watcher.offered, hasLength(1), reason: 'nothing new');
    });

    test('a kill after the store leaves the rest in the carry, and the next '
        'pass (any engine) offers it again', () async {
      await seed();
      source.onInsertedImagesSince = (_, _, _, _) => inserted(['a', 'b']);
      var processed = 0;
      watcher.before = (id) async {
        if (++processed == 2) throw StateError('killed');
      };
      await pass();
      expect(carried(await stored()), ['a'],
          reason: 'b got its verdict first (newest first), a never did');
      source.onInsertedImagesSince = null;
      watcher.before = null;
      final r = await pass();
      expect(watcher.offered.last, ['a']);
      expect(r.caught, 1);
      expect(carried(await stored()), isEmpty);
    });

    test('a photo the pipeline releases stays in the carry for the next '
        'pass', () async {
      await seed();
      source.onInsertedImagesSince = (_, _, _, _) => inserted(['a', 'b']);
      watcher.verdict = (id) => id != 'a';
      final r = await pass();
      expect(r.caught, 1);
      expect(carried(await stored()), ['a']);
      source.onInsertedImagesSince = null;
      watcher.verdict = (_) => true;
      await pass();
      expect(watcher.offered.last, ['a']);
      expect(carried(await stored()), isEmpty);
    });

    test('error keeps the token and still offers the carry', () async {
      await seed(carry: [LateImportEntry('a', created: hoursAgo(48))]);
      source.onInsertedImagesSince = (token, _, _, _) => InsertedImages(
          PhotoChangeStatus.error,
          token: token,
          errorCode: 'PHPhotosErrorDomain:3300');
      final r = await pass();
      expect(r.status, 'error');
      expect(watcher.offered, [
        ['a'],
      ]);
      expect((await stored())!.token, 'T1');
      await pass();
      expect(source.insertedImagesSinceTokens, ['T1', 'T1'],
          reason: 'the same changes are read again next time');
    });

    for (final status in [
      PhotoChangeStatus.expired,
      PhotoChangeStatus.unavailable,
    ]) {
      test('${status.name}: the new token is stored and a rescan by date is '
          'owed from now; the carry still goes out', () async {
        await seed(carry: [LateImportEntry('a', created: hoursAgo(48))]);
        source.onInsertedImagesSince = (_, _, _, _) => InsertedImages(status,
            token: 'T9', deviceTag: _tag, errorCode: 'x');
        final r = await pass(rescan: false);
        expect(r.status, status.name);
        expect(r.rescanning, isTrue);
        final s = await stored();
        expect(s!.token, 'T9');
        expect(s.rescanBefore, now);
        expect(s.rescanAt, now);
        expect(watcher.offered, [
          ['a'],
        ]);
      });
    }

    test('fresh stores the token it hands over', () async {
      await seed();
      source.onInsertedImagesSince = (_, _, _, _) => const InsertedImages(
          PhotoChangeStatus.fresh,
          token: 'T5',
          deviceTag: _tag);
      expect((await pass()).status, 'fresh');
      expect((await stored())!.token, 'T5');
    });

    for (final status in [
      PhotoChangeStatus.denied,
      PhotoChangeStatus.unsupported,
    ]) {
      test('${status.name}: the cursor stays as it is and nothing is offered',
          () async {
        await seed(carry: [LateImportEntry('a', created: hoursAgo(48))]);
        source.onInsertedImagesSince =
            (_, _, _, _) => InsertedImages(status);
        expect((await pass()).status, status.name);
        expect(watcher.offered, isEmpty);
        final s = await stored();
        expect(s!.token, 'T1');
        expect(carried(s), ['a']);
      });
    }

    test('truncated: the token of the last change read is stored, and the '
        'next pass reads on from it', () async {
      await seed();
      source.onInsertedImagesSince = (token, _, _, _) => token == 'T1'
          ? inserted(['a'], token: 'T1.5', truncated: true)
          : inserted(['b'], token: 'T2');
      await pass();
      expect((await stored())!.token, 'T1.5');
      expect(watcher.offered, [
        ['a'],
      ]);
      await pass();
      expect(source.insertedImagesSinceTokens, ['T1', 'T1.5']);
      expect(watcher.offered.last, ['b']);
      expect((await stored())!.token, 'T2');
    });
  });

  group('bounds', () {
    test('a 3,000-photo iCloud burst: 200 read, 100 carried, 50 offered, '
        'the rest owed to a rescan by date', () async {
      final ids = [
        for (var i = 0; i < 200; i++) 'p$i',
      ];
      for (var i = 0; i < ids.length; i++) {
        watcher.add(ids[i], hoursAgo(1 + i)); // p0 newest
      }
      await seed();
      int? asked;
      source.onInsertedImagesSince = (_, limit, _, _) {
        asked = limit;
        return inserted(ids, dropped: 2800);
      };
      final storedWhileOffering = <int>[];
      watcher.before = (_) async {
        if (storedWhileOffering.isEmpty) {
          storedWhileOffering.add((await stored())!.carry.length);
        }
      };
      final r = await pass(rescan: false);
      expect(asked, lateImportFetchLimit);
      expect(storedWhileOffering, [lateImportCarryLimit]);
      expect(watcher.offered.single, [
        for (var i = 0; i < lateImportPassLimit; i++) 'p$i',
      ]);
      final s = await stored();
      expect(carried(s), [
        for (var i = lateImportPassLimit; i < lateImportCarryLimit; i++) 'p$i',
      ]);
      expect(s!.rescanBefore, now);
      expect(r.rescanning, isTrue);
    });

    test('photos the call left out cannot be in the window when the oldest '
        'it returned is older: no rescan for them', () async {
      final ids = [
        for (var i = 0; i < 200; i++) 'p$i',
      ];
      for (var i = 0; i < ids.length; i++) {
        // 40 inside the window, then 160 older.
        watcher.add(ids[i], i < 40 ? hoursAgo(1 + i) : DateTime(2026, 9, 1));
      }
      await seed();
      source.onInsertedImagesSince = (_, _, _, _) => inserted(ids, dropped: 9);
      final r = await pass(rescan: false);
      expect(r.rescanning, isFalse);
      expect(watcher.offered.single, hasLength(40));
      expect((await stored())!.rescanBefore, isNull);
    });

    // The native side keeps the NEWEST inserts by creation date, so in a
    // burst it is the late imports (old shutter times) that are left out,
    // behind a token that has already moved past them. Here the carry stays
    // well under its bound (most of the 200 were handled already), so only
    // the left-out count can ask for the rescan that finds them.
    for (final dropped in [0, 37]) {
      test(
          '200 read, $dropped left out, the oldest read inside the window '
          'and the carry under its bound: '
          '${dropped > 0 ? 'a rescan by date is owed' : 'no rescan'}',
          () async {
        final ids = [
          for (var i = 0; i < 200; i++) 'p$i',
        ];
        for (var i = 0; i < ids.length; i++) {
          // Half an hour apart, p0 newest: all 200 inside the window.
          watcher.add(ids[i], now.subtract(Duration(minutes: 30 * (i + 1))));
          if (i < 120) {
            watcher.settled.add(ids[i]); // this session's scans had them
          } else if (i < 150) {
            watcher.logged.add(ids[i]); // a meal names them
          }
        }
        expect(watcher.library[ids.last]!.createDateTime.isBefore(cutoff),
            isFalse);
        await seed();
        source.onInsertedImagesSince =
            (_, _, _, _) => inserted(ids, dropped: dropped);
        final r = await pass(rescan: false);
        expect(watcher.offered.single,
            [for (var i = 150; i < 200; i++) 'p$i'],
            reason: '50 in the carry: the bound did not ask for anything');
        final s = await stored();
        expect(carried(s), isEmpty);
        if (dropped > 0) {
          expect(s!.rescanBefore, now);
          expect(s.rescanAt, now);
          expect(r.rescanning, isTrue);
        } else {
          expect(s!.rescanBefore, isNull);
          expect(r.rescanning, isFalse);
        }
      });
    }

    test('photos left out behind one whose creation date is unknown, or '
        'behind none at all, may be in the window: a rescan is owed',
        () async {
      watcher.add('dated', DateTime(2026, 9, 1)); // before the window
      await seed();
      // 'undated' is not in the library: its reply entry has no date.
      source.onInsertedImagesSince =
          (_, _, _, _) => inserted(['dated', 'undated'], dropped: 5);
      await pass(rescan: false);
      expect((await stored())!.rescanBefore, now);

      await seed();
      source.onInsertedImagesSince =
          (_, _, _, _) => inserted(const [], dropped: 5);
      final r = await pass(rescan: false);
      expect((await stored())!.rescanBefore, now);
      expect(r.rescanning, isTrue);
    });

    test('carried photos that are gone, hidden or older than the window are '
        'let go; one the library cannot answer for stays', () async {
      watcher.add('live', hoursAgo(10));
      watcher.add('aged', DateTime(2026, 10, 16, 23)); // taken before cutoff
      watcher.unanswerable.add('unknown');
      await seed(carry: [
        LateImportEntry('live', created: hoursAgo(10)),
        LateImportEntry('gone', created: hoursAgo(11)), // deleted or hidden
        LateImportEntry('aged', created: hoursAgo(12)),
        LateImportEntry('unknown', created: hoursAgo(13)),
        LateImportEntry('stale', created: DateTime(2026, 10, 1)),
      ]);
      await pass();
      expect(watcher.offered, [
        ['live'],
      ]);
      expect(carried(await stored()), ['unknown']);
    });

    test('carried photos this session already handled, or a meal names, '
        'leave without a read', () async {
      watcher.add('a', hoursAgo(10));
      watcher.add('b', hoursAgo(11));
      watcher.add('c', hoursAgo(12));
      watcher.settled.add('a');
      watcher.logged.add('b');
      await seed(carry: [
        LateImportEntry('a', created: hoursAgo(10)),
        LateImportEntry('b', created: hoursAgo(11)),
        LateImportEntry('c', created: hoursAgo(12)),
      ]);
      await pass();
      expect(watcher.offered, [
        ['c'],
      ]);
      expect(watcher.loggedAsked.first, unorderedEquals(['b', 'c']),
          reason: 'one query, and none for what the session settled');
      expect(carried(await stored()), isEmpty);
    });

    test('a failed meal lookup reads the photos rather than skip them',
        () async {
      watcher.add('a', hoursAgo(10));
      await seed(carry: [LateImportEntry('a', created: hoursAgo(10))]);
      final hooks = watcher.hooks();
      final failing = LateImportHooks(
          settled: hooks.settled,
          logged: (_) async => throw StateError('db locked'),
          resolve: hooks.resolve,
          listWindow: hooks.listWindow,
          offer: hooks.offer);
      await cursor().pass(cutoff: cutoff, hooks: failing);
      expect(watcher.offered, [
        ['a'],
      ]);
    });

    test('a photo this session already tried and released waits in the '
        'carry, unoffered; a later session offers it', () async {
      watcher.add('tried', hoursAgo(10));
      watcher.add('new', hoursAgo(11));
      await seed(carry: [LateImportEntry('tried', created: hoursAgo(10))]);
      source.onInsertedImagesSince = (_, _, _, _) => inserted(['new']);
      final hooks = watcher.hooks();
      LateImportHooks session(Set<String> released) => LateImportHooks(
          settled: hooks.settled,
          logged: hooks.logged,
          resolve: hooks.resolve,
          listWindow: hooks.listWindow,
          offer: hooks.offer,
          retryLater: released.contains);
      await cursor().pass(cutoff: cutoff, hooks: session({'tried'}));
      expect(watcher.offered, [
        ['new'],
      ]);
      expect(carried(await stored()), ['tried']);
      source.onInsertedImagesSince = null;
      await cursor().pass(cutoff: cutoff, hooks: session({}));
      expect(watcher.offered.last, ['tried']);
      expect(carried(await stored()), isEmpty);
    });

    test('a pass that finds nothing new writes nothing', () async {
      await seed(carry: [LateImportEntry('gone?', created: hoursAgo(10))]);
      watcher.unanswerable.add('gone?');
      await pass();
      final s = await stored();
      expect(s!.at.isAtSameMomentAs(hoursAgo(1)), isTrue,
          reason: 'the seeded document, untouched');
      expect(carried(s), ['gone?']);
      // A new token is news.
      source.onInsertedImagesSince =
          (_, _, _, _) => inserted(const [], token: 'T7');
      await pass();
      expect((await stored())!.token, 'T7');
      expect((await stored())!.at.isAtSameMomentAs(now), isTrue);
    });
  });

  group('the rescan by date', () {
    /// 120 photos inside the window, one an hour back from an hour ago.
    void window() {
      for (var i = 0; i < 120; i++) {
        watcher.add('w$i', hoursAgo(1 + i));
      }
    }

    test('resumes across passes (and engines), and then ends', () async {
      window();
      await seed(rescanBefore: now, rescanAt: now);
      // Photos that got a verdict became meals: a new session's pass knows
      // them by that, not by its (empty) settled set.
      watcher.verdict = (id) {
        watcher.logged.add(id);
        return true;
      };
      final boundWhileOffering = <DateTime?>[];
      watcher.before = (id) async {
        final s = await stored();
        if (boundWhileOffering.length < watcher.offered.length) {
          boundWhileOffering.add(s!.rescanBefore);
          expect(carried(s), contains(id),
              reason: 'the batch is in the carry before it goes out');
        }
      };
      var r = await pass();
      expect(r.rescanning, isTrue);
      expect(watcher.offered.single, hasLength(lateImportPassLimit));
      expect(watcher.offered.single.first, 'w0');
      expect(boundWhileOffering.single, hoursAgo(50),
          reason: 'moved past the batch before it was offered');
      r = await pass();
      expect(r.rescanning, isTrue);
      expect(watcher.offered.last.first, 'w50');
      r = await pass();
      expect(r.rescanning, isFalse);
      expect(watcher.offered.last, hasLength(20));
      expect(watcher.offered.last.last, 'w119');
      final s = await stored();
      expect(s!.rescanBefore, isNull);
      expect(s.rescanAt, isNull);
      expect(s.carry, isEmpty);
      await pass();
      expect(watcher.windowListings, 3, reason: 'ended: no more listings');
    });

    test('skips what the session handled, a meal names or the carry holds',
        () async {
      window();
      watcher.settled.addAll(['w0', 'w1']);
      watcher.logged.add('w2');
      watcher.unanswerable.add('w3'); // carried, cannot be looked up now
      await seed(
          carry: [LateImportEntry('w3', created: hoursAgo(4))],
          rescanBefore: now,
          rescanAt: now);
      await pass();
      final rescanBatch = watcher.offered.last;
      expect(rescanBatch.first, 'w4');
      expect(rescanBatch, isNot(contains('w3')));
    });

    test('waits for room in the carry, and for the budget', () async {
      window();
      await seed(carry: [
        for (var i = 0; i < lateImportCarryLimit; i++)
          LateImportEntry('c$i', created: hoursAgo(1)),
      ], rescanBefore: now, rescanAt: now);
      watcher.unanswerable.addAll([
        for (var i = 0; i < lateImportCarryLimit; i++) 'c$i',
      ]);
      var r = await pass();
      expect(r.rescanning, isTrue);
      expect(watcher.windowListings, 0, reason: 'a full carry comes first');

      await seed(rescanBefore: now, rescanAt: now);
      var asked = 0;
      watcher.shouldContinue = () {
        asked++;
        return false;
      };
      r = await pass();
      expect(r.rescanning, isTrue);
      expect(asked, 1);
      expect(watcher.windowListings, 0, reason: 'no budget, no listing');
    });

    test('a scan of the whole window that started after the request settles '
        'it; one that started before does not', () async {
      window();
      await seed(rescanBefore: now, rescanAt: now);
      var r = await pass(
          rescan: false,
          windowCoveredFrom: now.subtract(const Duration(minutes: 1)));
      expect(r.rescanning, isTrue);
      expect((await stored())!.rescanBefore, now);
      r = await pass(windowCoveredFrom: now);
      expect(r.rescanning, isFalse);
      expect(watcher.windowListings, 0);
      expect((await stored())!.rescanBefore, isNull);
    });

    test('rescan: false (the live watcher) notes it without listing the '
        'window', () async {
      window();
      await seed(rescanBefore: now, rescanAt: now);
      final r = await pass(rescan: false);
      expect(r.rescanning, isTrue);
      expect(watcher.windowListings, 0);
      expect(watcher.offered, isEmpty);
    });

    test('a batch that sits at its bound steps past it: sixty photos sharing '
        'one instant cannot hold the rescan forever', () async {
      // An app that saved a whole album at once: one creation date for all.
      final instant = hoursAgo(5);
      for (var i = 0; i < 60; i++) {
        watcher.add('s$i', instant);
      }
      await seed(rescanBefore: now, rescanAt: now);
      // Every pass is a new session (background runs): none of them knows
      // what an earlier one settled, and none of the photos is a meal.
      var r = await pass();
      expect(r.rescanning, isTrue);
      expect((await stored())!.rescanBefore, instant,
          reason: 'inclusive: the photos at the instant beyond the batch');
      r = await pass();
      expect(r.rescanning, isTrue);
      expect((await stored())!.rescanBefore,
          instant.subtract(const Duration(milliseconds: 1)),
          reason: 'no progress at the instant: step past it');
      r = await pass();
      expect(r.rescanning, isFalse);
      expect((await stored())!.rescanBefore, isNull);
      expect(watcher.windowListings, 3);
    });
  });

  group('the diagnostics record', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('counts what passes caught over 7 days, and keeps the last status',
        () async {
      final prefs = await SharedPreferences.getInstance();
      var at = DateTime(2026, 10, 10, 9);
      Future<void> record(LateImportReport r) => recordLateImportPass(r,
          prefs: () async => prefs, clock: () => at);
      await record(const LateImportReport('ok', caught: 2));
      at = DateTime(2026, 10, 20, 9);
      await record(const LateImportReport('ok', caught: 1));
      at = DateTime(2026, 10, 21, 9);
      await record(const LateImportReport('expired', rescanning: true));
      final stats = await readLateImportStats(prefs: () async => prefs);
      expect(stats!.caught, [DateTime(2026, 10, 20, 9)],
          reason: 'the two from the 10th aged out');
      expect(stats.caughtSince(DateTime(2026, 10, 14)), 1);
      expect(stats.lastAt, DateTime(2026, 10, 21, 9));
      expect(stats.lastStatus, lateImportRescanning);
      await record(const LateImportReport('unsupported'));
      expect((await readLateImportStats(prefs: () async => prefs))!.lastStatus,
          'unsupported');
    });

    test('nothing stored, or junk, reads as no record', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(await readLateImportStats(prefs: () async => prefs), isNull);
      await prefs.setString(lateImportStatsPrefsKey, '[1,2]');
      expect(await readLateImportStats(prefs: () async => prefs), isNull);
      expect(
          await readLateImportStats(
              prefs: () async => throw StateError('no store')),
          isNull);
      expect(decodeLateImportStats('{"caught7d": ["junk", 3]}')!.caught,
          isEmpty);
    });
  });
}
