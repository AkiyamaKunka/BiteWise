/// Android's user-set 电池 › 受限 bucket (App info › App battery usage ›
/// Restricted; ActivityManager.isBackgroundRestricted, API 28+). In it the
/// OS parks the app's WorkManager jobs for days, so the periodic photo
/// scan — on Android also the only durable daily-summary path — never
/// runs while the app is closed. Settings asks MainActivity.kt over this
/// channel so the 后台扫描 row can say so instead of 尚未运行 forever.
///
/// Doze (battery optimization) is deliberately NOT probed: WorkManager is
/// Doze-compliant and runs in maintenance windows, and the exemption is
/// off for nearly every app — keying on it would cry wolf for everyone.
/// OEM auto-start managers (EMUI, MIUI) are private and undetectable.
library;

import 'package:flutter/services.dart';

/// Served by MainActivity.kt; the background engine never registers it.
const MethodChannel backgroundRestrictionChannel =
    MethodChannel('dev.calorietracker/background');

/// Whether Android will still launch the periodic background scan: false
/// when the user set the app to Restricted, true otherwise (and below API
/// 28). Null when the platform side cannot answer — no channel (tests, an
/// older native build) or a platform error — so the caller leaves the row
/// as it was. Shaped like the iOS Background App Refresh probe so the
/// 后台扫描 row needs no second remedy state.
Future<bool?> androidBackgroundAllowed(
    {MethodChannel channel = backgroundRestrictionChannel}) async {
  final bool? restricted;
  try {
    restricted = await channel.invokeMethod<bool>('isBackgroundRestricted');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
  return restricted == null ? null : !restricted;
}
