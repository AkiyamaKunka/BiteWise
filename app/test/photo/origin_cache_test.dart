// photo_manager's iOS original-file cache (tmp/.image) is pruned at launch
// to what the automatic scans can still read (run 7, P3).
import 'dart:io';

import 'package:calorie_tracker/services/photo/origin_cache.dart';
import 'package:calorie_tracker/services/photo/watcher.dart'
    show lookbackCutoff;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late Directory cache;
  final now = DateTime(2026, 10, 31, 9, 41);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_origin_cache');
    cache = await Directory('${tmp.path}/.image').create();
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<File> fileAt(String path, DateTime modified) async {
    final f = await File(path).create(recursive: true);
    await f.writeAsBytes(List.filled(16, 7));
    await f.setLastModified(modified);
    return f;
  }

  group('pruneOriginCache', () {
    test('deletes only the regular files in .image older than the cutoff',
        () async {
      final fresh = await fileAt('${cache.path}/A_1_o_IMG_1.HEIC',
          now.subtract(const Duration(days: 1)));
      final old = await fileAt('${cache.path}/B_2_o_IMG_2.HEIC',
          now.subtract(const Duration(days: 4)));
      // Outside .image: never touched, however old.
      final outside = await fileAt(
          '${tmp.path}/other.jpg', now.subtract(const Duration(days: 40)));
      // A nested folder is never descended into.
      final nested = await fileAt('${cache.path}/sub/C_3_o_IMG_3.JPG',
          now.subtract(const Duration(days: 40)));

      final deleted = await pruneOriginCache(tmp,
          olderThan: now.subtract(const Duration(days: 3)));

      expect(deleted, 1);
      expect(await old.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
      expect(await outside.exists(), isTrue);
      expect(await nested.exists(), isTrue);
      expect(await Directory('${cache.path}/sub').exists(), isTrue);
    });

    test('a link is never followed or deleted', () async {
      final target = await fileAt(
          '${tmp.path}/real_photo.jpg', now.subtract(const Duration(days: 40)));
      final link = Link('${cache.path}/D_4_o_IMG_4.JPG');
      await link.create(target.path);

      final deleted = await pruneOriginCache(tmp,
          olderThan: now.subtract(const Duration(days: 3)));

      expect(deleted, 0);
      expect(await link.exists(), isTrue);
      expect(await target.exists(), isTrue);
    });

    test('no .image folder: 0, no throw', () async {
      await cache.delete(recursive: true);
      expect(await pruneOriginCache(tmp, olderThan: now), 0);
      final missing = Directory('${tmp.path}/does_not_exist');
      expect(await pruneOriginCache(missing, olderThan: now), 0);
    });
  });

  group('originCachePruneCutoff', () {
    test('lies before the start of every automatic scan window', () {
      for (var days = 1; days <= 30; days++) {
        final cutoff = originCachePruneCutoff(now, days);
        // The scan window opens at local midnight days-1 days ago; a cache
        // file is written when its photo is first read, after it was taken.
        // Even with an hour of capture-clock skew, a file older than the
        // cutoff belongs to a photo before the window.
        expect(
            cutoff.add(const Duration(hours: 1))
                .isBefore(lookbackCutoff(now, days)),
            isTrue,
            reason: 'lookback $days');
      }
    });

    test('clamps the lookback like the scans do', () {
      expect(originCachePruneCutoff(now, 0),
          now.subtract(const Duration(days: 2)));
      expect(originCachePruneCutoff(now, 99),
          now.subtract(const Duration(days: 31)));
    });
  });

  test('the launch call prunes the given temp folder by the lookback',
      () async {
    final inWindow = await fileAt('${cache.path}/E_5_o_IMG_5.HEIC',
        now.subtract(const Duration(days: 2, hours: 23)));
    final pastWindow = await fileAt('${cache.path}/F_6_o_IMG_6.HEIC',
        now.subtract(const Duration(days: 3, hours: 1)));
    final deleted =
        await pruneOriginCacheAtLaunch(2, tmp: tmp, clock: () => now);
    expect(deleted, 1);
    expect(await inWindow.exists(), isTrue);
    expect(await pastWindow.exists(), isFalse);
  });
}
