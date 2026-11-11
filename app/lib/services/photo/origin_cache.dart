/// photo_manager's iOS cache of full-size originals, kept bounded.
///
/// WHY (run 7, P3): on iOS, photo_manager 3.x's `originBytes` is
/// `originFile` + `readAsBytes`, and `originFile` first writes the whole
/// original to `NSTemporaryDirectory()/.image/<id>_<modDate>_o_<name>`
/// (PMManager.m, PM_IMAGE_CACHE_PATH). Nothing but `clearFileCache` ever
/// removes those files, and the app never called it — so every photo the
/// watcher, a catch-up, the coverage audit or the picker read (food or
/// not, private ones included, GPS EXIF and all) stayed on disk as a
/// full-size copy, growing "Documents & Data" until iOS purged tmp.
///
/// NOT a full wipe: the cache is what makes each launch and resume
/// catch-up re-read its window cheaply, and a wipe racing an in-flight read
/// would drop a photo from that scan. Instead, once per app launch, only
/// files first written longer ago than the automatic window can reach are
/// deleted ([originCachePruneCutoff]): no automatic scan can ask for those
/// photos again, so nothing it reads is ever pulled from under it. A
/// user-run coverage audit over a longer window, or the picker, simply
/// fetches an older original again.
///
/// iOS only. Android never gets here: on API 29 and below `originFile` can
/// be the user's REAL photo, and on API 30+ no copy is made.
library;

import 'dart:io';

import 'watcher.dart' show clampLookbackDays;

/// photo_manager's image cache folder inside the temporary directory.
const String kOriginCacheDirName = '.image';

/// Files written before this are past every automatic scan's reach. The
/// scan window starts at local midnight `lookbackDays − 1` days before today
/// (lookbackCutoff), and a cache file is written when its photo is first
/// read, which is after the photo was taken. One extra day covers the
/// window's midnight rounding and an hour of capture-clock skew.
DateTime originCachePruneCutoff(DateTime now, int lookbackDays) =>
    now.subtract(Duration(days: clampLookbackDays(lookbackDays) + 1));

/// Deletes the regular files directly inside `<tmp>/.image` last modified
/// before [olderThan]; returns how many went. Never recurses, never follows
/// or deletes a link, ignores a missing folder, skips a file it cannot stat
/// or delete, and never throws.
Future<int> pruneOriginCache(Directory tmp,
    {required DateTime olderThan}) async {
  var deleted = 0;
  try {
    final dir = Directory('${tmp.path}/$kOriginCacheDirName');
    if (!await dir.exists()) return 0;
    await for (final entity
        in dir.list(recursive: false, followLinks: false)) {
      if (entity is! File) continue; // folders and links are left alone
      try {
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        if (!stat.modified.isBefore(olderThan)) continue;
        await entity.delete();
        deleted++;
      } catch (_) {
        // One file that cannot be read or removed never stops the rest.
      }
    }
  } catch (_) {
    // Housekeeping must never surface an error.
  }
  return deleted;
}

/// The launch call (di.dart, iOS only, fire-and-forget). [tmp] defaults to
/// [Directory.systemTemp]: on iOS that is the app's `TMPDIR`, the same
/// `<container>/tmp` NSTemporaryDirectory() returns. NOT path_provider's
/// getTemporaryDirectory, which on iOS is Library/Caches.
Future<int> pruneOriginCacheAtLaunch(int lookbackDays,
        {Directory? tmp, DateTime Function() clock = DateTime.now}) =>
    pruneOriginCache(tmp ?? Directory.systemTemp,
        olderThan: originCachePruneCutoff(clock(), lookbackDays));
