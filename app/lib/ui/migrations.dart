/// One-time data repairs run at launch (composition root only).
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/contracts.dart';

/// Set once the iOS "unreadable photo" verdicts have been released.
const String iosUnreadPhotoReofferFlag = 'migrations.ios_heic_reoffer_v1';

/// Until 2026-09-30 an iPhone photo reached the model as raw HEIC labelled
/// image/jpeg: unreadable, so the answer was "not food" (or a decode
/// failure for originals over 5 MB) no matter what was on the plate. Those
/// verdicts sit in the ledger as skipped/failed, and the watcher never
/// re-offers either — the owner's real meals would stay invisible forever.
/// Release them ONCE; the next scan re-analyzes whatever is still inside
/// the lookback window, this time with a decodable JPEG.
Future<int> reofferUnreadPhotosOnce(
    MealsDao dao, SharedPreferences prefs) async {
  if (prefs.getBool(iosUnreadPhotoReofferFlag) ?? false) return 0;
  final released = await dao.reofferWatchVerdicts();
  await prefs.setBool(iosUnreadPhotoReofferFlag, true);
  return released;
}
