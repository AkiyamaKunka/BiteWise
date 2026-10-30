import 'dart:io';

import 'package:calorie_tracker/services/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('local_store_test');
    dir = Directory('${root.path}/$localStoreDirName');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LocalNoBackupStore store({
    bool create = true,
    DateTime Function()? clock,
    Future<void> Function(File temp)? beforeRename,
  }) =>
      LocalNoBackupStore(
        root: () async => root,
        createMissingDirectory: create,
        clock: clock,
        beforeRename: beforeRename,
      );

  List<String> filesIn(Directory d) =>
      [for (final f in d.listSync()) f.uri.pathSegments.last]..sort();

  group('read and write', () {
    test('a document round-trips with its version stamped', () async {
      final s = store();
      final doc = {
        'token': 'abc',
        'carry': ['a', 'b'],
        'nested': {'n': 1, 'ok': true, 'none': null},
        'v': 99, // overwritten by the write's version
      };
      expect(await s.write('photo_change_cursor', doc, version: 2), isTrue);
      expect(File('${dir.path}/photo_change_cursor.json').existsSync(),
          isTrue);
      final back = await s.read('photo_change_cursor');
      expect(back, {
        'v': 2,
        'token': 'abc',
        'carry': ['a', 'b'],
        'nested': {'n': 1, 'ok': true, 'none': null},
      });
      // A second instance (the other engine) reads the same document.
      expect(await store().read('photo_change_cursor', version: 2), back);
      expect(filesIn(dir), ['photo_change_cursor.json'],
          reason: 'no temp file is left behind');
    });

    test('a later write replaces the document whole', () async {
      final s = store();
      await s.write('assist_jobs', {'a': 1, 'b': 2}, version: 1);
      await s.write('assist_jobs', {'c': 3}, version: 1);
      expect(await s.read('assist_jobs'), {'v': 1, 'c': 3});
    });

    test('a missing document or directory reads as {}', () async {
      expect(await store().read('assist_cache'), isEmpty);
      expect(dir.existsSync(), isFalse, reason: 'a read creates nothing');
      dir.createSync();
      expect(await store().read('assist_cache'), isEmpty);
    });

    test('a corrupt, truncated or non-object document reads as {}',
        () async {
      dir.createSync();
      for (final raw in [
        '{"v":1,"token":"ab', // cut off mid-write by an older writer
        '',
        'not json',
        '[1,2,3]',
        '"text"',
        '42',
        'null',
      ]) {
        File('${dir.path}/assist_places.json').writeAsStringSync(raw);
        expect(await store().read('assist_places'), isEmpty, reason: raw);
      }
      File('${dir.path}/assist_places.json')
          .writeAsBytesSync([0x7b, 0xff, 0xfe, 0x7d]); // not UTF-8
      expect(await store().read('assist_places'), isEmpty);
    });

    test('a document of another version reads as {} when one is asked',
        () async {
      final s = store();
      await s.write('photo_change_cursor', {'token': 'x'}, version: 1);
      expect(await s.read('photo_change_cursor', version: 2), isEmpty);
      expect(await s.read('photo_change_cursor', version: 1),
          {'v': 1, 'token': 'x'});
      dir.createSync(recursive: true);
      File('${dir.path}/unversioned.json').writeAsStringSync('{"a":1}');
      expect(await s.read('unversioned', version: 1), isEmpty);
      expect(await s.read('unversioned'), {'a': 1});
    });

    test('an oversized document is refused on write and empty on read',
        () async {
      final s = store();
      expect(await s.write('assist_cache', {'k': 'small'}, version: 1),
          isTrue);
      final big = 'x' * localDocumentMaxBytes;
      expect(await s.write('assist_cache', {'k': big}, version: 1), isFalse);
      expect(await s.read('assist_cache'), {'v': 1, 'k': 'small'},
          reason: 'the refused write left the old document');
      File('${dir.path}/assist_cache.json')
          .writeAsStringSync('{"k":"$big"}');
      expect(await s.read('assist_cache'), isEmpty);
    });

    test('a value JSON cannot hold is refused and changes nothing',
        () async {
      final s = store();
      await s.write('assist_jobs', {'a': 1}, version: 1);
      expect(
          await s.write('assist_jobs', {'when': DateTime(2026)}, version: 1),
          isFalse);
      expect(await s.read('assist_jobs'), {'v': 1, 'a': 1});
      expect(filesIn(dir), ['assist_jobs.json']);
    });

    test('names that could leave the directory are refused', () async {
      final s = store();
      for (final name in [
        '../escape',
        'a/b',
        '',
        'Upper',
        '1starts_with_digit',
        'dot.name',
        'x' * 65,
      ]) {
        expect(await s.write(name, {'a': 1}, version: 1), isFalse,
            reason: name);
        expect(await s.read(name), isEmpty, reason: name);
        expect(await s.delete(name), isFalse, reason: name);
      }
      expect(root.listSync(), isEmpty, reason: 'nothing was written');
    });

    test('delete removes the document; a missing one is already gone',
        () async {
      final s = store();
      await s.write('assist_places', {'zones': []}, version: 1);
      expect(await s.delete('assist_places'), isTrue);
      expect(await s.read('assist_places'), isEmpty);
      expect(await s.delete('assist_places'), isTrue);
      expect(await store(create: false).delete('nothing_here'), isTrue);
    });
  });

  group('atomic write', () {
    test('a crash between the temp write and the rename leaves the old '
        'document readable', () async {
      final s0 = store();
      await s0.write('photo_change_cursor', {'token': 'old'}, version: 1);
      File? seen;
      final s = store(beforeRename: (temp) async {
        seen = temp;
        // The moment of the crash: the new bytes are complete in the temp
        // file, the rename has not happened.
        expect(temp.existsSync(), isTrue);
        expect(temp.readAsStringSync(), contains('"new"'));
        expect(await store().read('photo_change_cursor'),
            {'v': 1, 'token': 'old'});
        throw const FileSystemException('simulated crash');
      });
      expect(await s.write('photo_change_cursor', {'token': 'new'}, version: 1),
          isFalse);
      expect(seen, isNotNull);
      expect(await store().read('photo_change_cursor'),
          {'v': 1, 'token': 'old'});
      expect(filesIn(dir), ['photo_change_cursor.json'],
          reason: 'the failed write cleaned up its temp file');
    });

    test('a temp file a killed process left is ignored by reads and swept '
        'by a later write once stale', () async {
      final now = DateTime.utc(2026, 10, 23, 12);
      final s = store(clock: () => now);
      await s.write('photo_change_cursor', {'token': 'old'}, version: 1);
      final stale = now.subtract(const Duration(hours: 2));
      final fresh = now.subtract(const Duration(minutes: 1));
      final staleTemp = File('${dir.path}/photo_change_cursor.json.'
          '${stale.millisecondsSinceEpoch}.1a2b.tmp')
        ..writeAsStringSync('{"v":1,"token":"half');
      final otherDocStale = File('${dir.path}/assist_jobs.json.'
          '${stale.millisecondsSinceEpoch}.ff.tmp')
        ..writeAsStringSync('{}');
      final inFlight = File('${dir.path}/photo_change_cursor.json.'
          '${fresh.millisecondsSinceEpoch}.3c.tmp')
        ..writeAsStringSync('{"v":1,"token":"other engine"}');
      final unrelated = File('${dir.path}/notes.txt')..writeAsStringSync('x');

      expect(await s.read('photo_change_cursor'), {'v': 1, 'token': 'old'});
      expect(await s.write('assist_places', {'zones': []}, version: 1),
          isTrue);
      expect(staleTemp.existsSync(), isFalse);
      expect(otherDocStale.existsSync(), isFalse);
      expect(inFlight.existsSync(), isTrue,
          reason: "another engine's write in flight is never touched");
      expect(unrelated.existsSync(), isTrue);
    });

    test('two engines writing at once leave one whole document', () async {
      final a = store();
      final b = store();
      await Future.wait([
        for (var i = 0; i < 20; i++)
          (i.isEven ? a : b).write('assist_jobs', {'writer': i}, version: 1),
      ]);
      final doc = await a.read('assist_jobs');
      expect(doc['v'], 1);
      expect(doc['writer'], isA<int>());
      expect(filesIn(dir), ['assist_jobs.json']);
    });
  });

  group('directory', () {
    test('Android creates the directory on the first write', () async {
      expect(await store().write('assist_cache', {}, version: 1), isTrue);
      expect(dir.existsSync(), isTrue);
    });

    test('iOS never creates it: without the directory AppDelegate made and '
        'excluded, writes refuse and reads are empty', () async {
      final s = store(create: false);
      expect(await s.write('assist_places', {'zones': []}, version: 1),
          isFalse);
      expect(dir.existsSync(), isFalse);
      expect(await s.read('assist_places'), isEmpty);
      dir.createSync(); // what AppDelegate.prepareLocalStore does at launch
      expect(await s.write('assist_places', {'zones': []}, version: 1),
          isTrue);
      expect(await s.read('assist_places'), {'v': 1, 'zones': []});
    });

    test('a root that cannot be resolved reads {} and refuses writes, and '
        'is asked again next time', () async {
      var calls = 0;
      final s = LocalNoBackupStore(
        root: () async {
          calls++;
          if (calls == 1) throw StateError('no platform channel');
          return root;
        },
        createMissingDirectory: true,
      );
      expect(await s.write('assist_jobs', {'a': 1}, version: 1), isFalse);
      expect(await s.write('assist_jobs', {'a': 1}, version: 1), isTrue);
      expect(await s.read('assist_jobs'), {'v': 1, 'a': 1});
      expect(calls, 2, reason: 'a resolved root is kept');
    });

    test('a file where the directory should be makes every call fail '
        'safely', () async {
      File('${root.path}/$localStoreDirName').writeAsStringSync('in the way');
      final s = store();
      expect(await s.read('assist_jobs'), isEmpty);
      expect(await s.write('assist_jobs', {'a': 1}, version: 1), isFalse);
      expect(await s.delete('assist_jobs'), isTrue);
    });
  });

  group('pruneByTtl', () {
    final now = DateTime.utc(2026, 10, 23, 12);
    String ago(Duration d) => now.subtract(d).toIso8601String();

    test('keeps entries within the TTL, in order, and drops the rest', () {
      final kept = pruneByTtl(
        [
          {'cell': 'a', 'at': ago(const Duration(days: 1))},
          {'cell': 'b', 'at': ago(const Duration(days: 181))},
          {'cell': 'c', 'at': ago(const Duration(days: 180))}, // exactly TTL
          {'cell': 'd', 'at': ago(const Duration(minutes: 1))},
        ],
        'at',
        const Duration(days: 180),
        now: now,
      );
      expect([for (final e in kept) e['cell']], ['a', 'c', 'd']);
    });

    test('drops malformed entries and anything that is not a list', () {
      final kept = pruneByTtl(
        [
          {'cell': 'ok', 'at': ago(Duration.zero)},
          {'cell': 'no stamp'},
          {'cell': 'number', 'at': now.millisecondsSinceEpoch},
          {'cell': 'garbage', 'at': 'yesterday'},
          'just a string',
          null,
          [1, 2],
        ],
        'at',
        const Duration(days: 30),
        now: now,
      );
      expect(kept, [
        {'cell': 'ok', 'at': ago(Duration.zero)},
      ]);
      expect(pruneByTtl(null, 'at', const Duration(days: 1), now: now),
          isEmpty);
      expect(pruneByTtl({'at': ago(Duration.zero)}, 'at',
          const Duration(days: 1), now: now), isEmpty);
    });

    test('a stamp from a clock set ahead outlives its TTL by at most the '
        'slack', () {
      String ahead(Duration d) => now.add(d).toIso8601String();
      final kept = pruneByTtl(
        [
          {'k': 'skew', 'at': ahead(const Duration(hours: 2))},
          {'k': 'far', 'at': ahead(const Duration(days: 400))},
        ],
        'at',
        const Duration(days: 180),
        now: now,
      );
      expect([for (final e in kept) e['k']], ['skew']);
      expect(ttlFutureSlack, const Duration(days: 1));
    });

    test('compares instants, whatever offset a stamp was written with', () {
      final kept = pruneByTtl(
        [
          // 2026-10-23T05:30Z, 6.5 h before now: inside a 7 h TTL.
          {'k': 'offset', 'at': '2026-10-23T00:30:00-05:00'},
          // 2026-10-23T04:30Z, 7.5 h before now: outside it.
          {'k': 'old', 'at': '2026-10-23T12:30:00+08:00'},
        ],
        'at',
        const Duration(hours: 7),
        now: now,
      );
      expect([for (final e in kept) e['k']], ['offset']);
    });
  });

  group('capNewest', () {
    test('without a field, keeps the last n (appended newest last)', () {
      expect(capNewest([1, 2, 3, 4, 5], 3), [3, 4, 5]);
      expect(capNewest(['a', 'b'], 5), ['a', 'b']);
      expect(capNewest([1, 2, 3], 0), isEmpty);
      expect(capNewest([1, 2, 3], -1), isEmpty);
    });

    test('with a field, keeps the n newest stamps in their original order',
        () {
      final entries = [
        {'k': 'mid', 'at': '2026-10-02T00:00:00Z'},
        {'k': 'newest', 'at': '2026-10-20T00:00:00Z'},
        {'k': 'unstamped'},
        {'k': 'oldest', 'at': '2026-09-01T00:00:00Z'},
        {'k': 'new', 'at': '2026-10-10T00:00:00Z'},
      ];
      expect([for (final e in capNewest(entries, 3, field: 'at')) e['k']],
          ['mid', 'newest', 'new']);
      expect([for (final e in capNewest(entries, 4, field: 'at')) e['k']],
          ['mid', 'newest', 'oldest', 'new'],
          reason: 'an entry without a readable stamp counts as the oldest');
    });

    test('equal stamps keep the later position as the newer', () {
      final entries = [
        {'k': 'first', 'at': '2026-10-01T00:00:00Z'},
        {'k': 'second', 'at': '2026-10-01T00:00:00Z'},
        {'k': 'third', 'at': '2026-10-01T00:00:00Z'},
      ];
      expect([for (final e in capNewest(entries, 2, field: 'at')) e['k']],
          ['second', 'third']);
    });

    test('returns a new list', () {
      final entries = [1, 2, 3];
      final capped = capNewest(entries, 3)..add(4);
      expect(entries, [1, 2, 3]);
      expect(capped, [1, 2, 3, 4]);
    });
  });
}
