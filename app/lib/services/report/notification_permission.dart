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
/// Never in a background run. An install from before this scheme counts as
/// asked ([settleNotificationAskAtLaunch]): the old build asked it at every
/// start. After the one ask, Settings' notifications-off row opens the
/// app's notification settings ([fixNotificationsOff]).
///
/// iOS is untouched: DarwinInitializationSettings asks during
/// ReportNotifier.init, as before.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/platform_decode.dart' show isHeadlessEngine;
import '../photo/background_restriction.dart' show backgroundRestrictionChannel;

/// Set once a request has run (whatever the answer), or for an install
/// from before this scheme. The app's own engine is the only writer.
const String notificationPermissionAskedPrefsKey =
    'notifications.permission_asked';

/// Set at the first launch of this scheme ([settleNotificationAskAtLaunch]).
const String notificationAskSchemePrefsKey = 'notifications.ask_scheme';

/// Test seam: the system request. Null: flutter_local_notifications'.
@visibleForTesting
Future<bool?> Function()? debugRequestNotificationPermission;

/// Whether the in-context ask applies: Android, in the app's own engine.
bool get notificationPermissionInContext =>
    defaultTargetPlatform == TargetPlatform.android && !isHeadlessEngine;

/// At the app engine's launch, before anything else writes preferences:
/// an install from before this scheme counts as asked — the old build
/// asked at every start, so its user has answered (twice, maybe, which
/// Android makes permanent: a trigger would show nothing, and Settings'
/// button must open the settings page). Such an install is told by the
/// preferences an earlier version left; a fresh install has none at its
/// first launch. Once per install. Android, app engine; never throws.
Future<void> settleNotificationAskAtLaunch(
    {Future<SharedPreferences> Function()? prefs}) async {
  if (!notificationPermissionInContext) return;
  try {
    final p = await (prefs ?? SharedPreferences.getInstance)();
    if (p.getBool(notificationAskSchemePrefsKey) ?? false) return;
    final earlier = p.getKeys().any((k) =>
        k != notificationAskSchemePrefsKey &&
        k != notificationPermissionAskedPrefsKey);
    if (earlier) await p.setBool(notificationPermissionAskedPrefsKey, true);
    await p.setBool(notificationAskSchemePrefsKey, true);
  } catch (_) {}
}

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
/// asked. Returns the answer, or null when it did not ask (asked before,
/// asking right now, not Android, a background run, or the request
/// failed). Never throws.
Future<bool?> askNotificationPermissionOnce() async =>
    (await _askOnce())?.granted;

/// True while a request runs: a second trigger meanwhile (a meal saved
/// while the dialog is up, say) asks nothing.
bool _asking = false;

/// The one ask: the request, and whether a dialog came up. The flag is set
/// only once a request has RUN — a request that throws (no activity yet,
/// say) does not use up the one ask. Null when it did not ask.
Future<({bool? granted, bool dialog})?> _askOnce() async {
  if (!notificationPermissionInContext) return null;
  final SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {
    return null;
  }
  // Checked and taken in one synchronous step after the read: of two
  // triggers at once, the second finds it taken.
  if (_asking || (prefs.getBool(notificationPermissionAskedPrefsKey) ?? false)) {
    return null;
  }
  _asking = true;
  try {
    final answer = await _requestWatchingForDialog();
    if (answer == null) return null;
    await prefs.setBool(notificationPermissionAskedPrefsKey, true);
    return answer;
  } catch (_) {
    return null;
  } finally {
    _asking = false;
  }
}

/// Whether the app lost focus while the request ran — the system dialog
/// takes it (the app goes inactive). A request Android answers without a
/// dialog (Android 12 and older, where there is none; a denial Android no
/// longer asks about; a permission already granted) leaves the app as it
/// was.
class _DialogWatch with WidgetsBindingObserver {
  bool shown = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) shown = true;
  }
}

Future<({bool? granted, bool dialog})?> _requestWatchingForDialog() async {
  final watch = _DialogWatch();
  WidgetsBinding? binding;
  try {
    binding = WidgetsBinding.instance..addObserver(watch);
  } catch (_) {
    binding = null;
  }
  try {
    final granted = await (debugRequestNotificationPermission ?? _request)();
    return (granted: granted, dialog: watch.shown);
  } catch (_) {
    return null;
  } finally {
    binding?.removeObserver(watch);
  }
}

Future<bool?> _request() async => FlutterLocalNotificationsPlugin()
    .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
    ?.requestNotificationsPermission();

/// Settings' notifications-off row on Android. Never asked: Android's
/// dialog — and when no dialog comes up (Android 12 and older, where
/// there is none; a denial Android no longer asks about; a permission
/// already granted with the summary's channel blocked) or the request
/// fails, the settings page instead, so the button never does nothing.
/// Asked already: the app's own notification settings, through
/// MainActivity's openNotificationSettings, which answers whether a page
/// opened. A native build without that method, or a false answer, falls
/// back to [fallback] (App info). Never throws.
Future<void> fixNotificationsOff(
    {Future<void> Function()? fallback,
    MethodChannel channel = backgroundRestrictionChannel}) async {
  if (!notificationPermissionInContext) {
    // iOS: system settings, the only remedy there.
    try {
      await fallback?.call();
    } catch (_) {}
    return;
  }
  if (!await notificationPermissionAsked()) {
    final answer = await _askOnce();
    if (answer != null && answer.dialog) return; // answered in the dialog
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
