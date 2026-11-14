/// Android 13+'s notification permission, asked in context (the Play push,
/// 2026-11-13).
///
/// It used to be asked by ReportNotifier.init at every start: a fresh
/// install got the dialog over the setup screens, and again at the second
/// launch — and two denials are permanent (developer.android.com, the
/// notification-permission page). Now it is asked ONCE, and only when the
/// user is doing something notifications are for:
///   * switching the daily summary on (Settings);
///   * switching Watch Camera Roll on, after its photo prompt (Settings);
///   * after the first meal saved in the app's own engine (di.dart), while
///     the summary or the watcher is on and the app is in front.
/// Never in a background run. After that one ask, Settings'
/// notifications-off row opens the app's notification settings instead
/// ([fixNotificationsOff]).
///
/// iOS is untouched: DarwinInitializationSettings asks during
/// ReportNotifier.init, as before.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/platform_decode.dart' show isHeadlessEngine;
import '../photo/background_restriction.dart' show backgroundRestrictionChannel;

/// Set once the app has asked (whatever the answer). The app's own engine
/// is the only writer.
const String notificationPermissionAskedPrefsKey =
    'notifications.permission_asked';

/// Test seam: the system request. Null: flutter_local_notifications'.
@visibleForTesting
Future<bool?> Function()? debugRequestNotificationPermission;

/// Whether the in-context ask applies: Android, in the app's own engine.
bool get notificationPermissionInContext =>
    defaultTargetPlatform == TargetPlatform.android && !isHeadlessEngine;

/// Whether the app has asked already. False off Android, and when the
/// store cannot be read.
Future<bool> notificationPermissionAsked() async {
  if (!notificationPermissionInContext) return false;
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(notificationPermissionAskedPrefsKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// Shows Android's notification-permission dialog if the app has never
/// asked, and remembers that it did. Returns the answer, or null when it
/// did not ask (asked before, not Android, a background run, or the
/// platform would not say). Never throws.
Future<bool?> askNotificationPermissionOnce() async {
  if (!notificationPermissionInContext) return null;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(notificationPermissionAskedPrefsKey) ?? false) {
      return null;
    }
    // Marked before the dialog: a second trigger while it is up (a meal
    // saved, say) must not queue another.
    await prefs.setBool(notificationPermissionAskedPrefsKey, true);
    return await (debugRequestNotificationPermission ?? _request)();
  } catch (_) {
    return null;
  }
}

Future<bool?> _request() async => FlutterLocalNotificationsPlugin()
    .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
    ?.requestNotificationsPermission();

/// Settings' notifications-off row on Android: the system dialog when the
/// app has never asked; after that (a denial Android may no longer show a
/// dialog for), the app's own notification settings, through MainActivity's
/// openNotificationSettings, which answers whether a page opened. A native
/// build without that method, or a false answer, falls back to [fallback]
/// (App info). Never throws.
Future<void> fixNotificationsOff(
    {Future<void> Function()? fallback,
    MethodChannel channel = backgroundRestrictionChannel}) async {
  if (!await notificationPermissionAsked()) {
    await askNotificationPermissionOnce();
    return;
  }
  var opened = false;
  try {
    opened = await channel.invokeMethod<bool>('openNotificationSettings') ??
        false;
  } on MissingPluginException {
    // An older native build: App info, as before.
  } on PlatformException {
    // Same.
  }
  if (opened) return;
  try {
    await fallback?.call();
  } catch (_) {}
}
