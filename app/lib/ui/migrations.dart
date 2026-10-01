/// One-time data repairs run at launch (composition root only).
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/contracts.dart';

/// Set once the iOS "unreadable photo" verdicts have been released — v1 for
/// the watcher's rows, v2 for deliberate ones (manual coverage scans: on
/// the owner's phone ALL 74 bad verdicts were of that kind, which v1 alone
/// left in place).
const String iosUnreadPhotoReofferFlag = 'migrations.ios_heic_reoffer_v1';
const String iosUnreadDeliberateReofferFlag = 'migrations.ios_heic_reoffer_v2';

/// Until 2026-09-30 an iPhone photo reached the model as raw HEIC labelled
/// image/jpeg: unreadable, so the answer was "not food" (or a decode
/// failure for originals over 5 MB) no matter what was on the plate. Those
/// verdicts sit in the ledger as skipped/failed, and the watcher never
/// re-offers a photo that has ANY row — the owner's real meals would stay
/// invisible forever. Release them ONCE per source; the next scan
/// re-analyzes whatever is still inside the lookback window, this time
/// with a decodable JPEG. Each flag is set at its first run, so verdicts
/// reached AFTER the fix are never touched.
Future<int> reofferUnreadPhotosOnce(
    MealsDao dao, SharedPreferences prefs) async {
  var released = 0;
  for (final (flag, source) in const [
    (iosUnreadPhotoReofferFlag, MealSource.appWatch),
    (iosUnreadDeliberateReofferFlag, MealSource.appPhoto),
  ]) {
    if (prefs.getBool(flag) ?? false) continue;
    released += await dao.reofferUnsavedVerdicts(source: source);
    await prefs.setBool(flag, true);
  }
  return released;
}
