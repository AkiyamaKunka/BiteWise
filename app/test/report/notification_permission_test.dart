/// Android 13+'s notification permission, asked in context (the Play
/// push, 2026-11-13): once, never in a background run, never on iOS; and
/// Settings' remedy after that one ask opens the app's notification
/// settings, falling back to App info on an older native build.
library;

import 'package:calorie_tracker/services/analyzer/platform_decode.dart'
    show isHeadlessEngine;
import 'package:calorie_tracker/services/photo/background_restriction.dart'
    show backgroundRestrictionChannel;
import 'package:calorie_tracker/services/report/notification_permission.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int requests;
  late List<String> channelCalls;

  void nativeAnswers(Object? Function(MethodCall call) answer) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backgroundRestrictionChannel, (call) async {
        channelCalls.add(call.method);
        return answer(call);
      });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = 0;
    channelCalls = [];
    debugRequestNotificationPermission = () async {
      requests++;
      return false;
    };
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugRequestNotificationPermission = null;
    debugDefaultTargetPlatformOverride = null;
    isHeadlessEngine = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundRestrictionChannel, null);
  });

  test('asks once, whatever the answer, and remembers it', () async {
    expect(await notificationPermissionAsked(), isFalse);
    expect(await askNotificationPermissionOnce(), isFalse);
    expect(requests, 1);
    expect(await notificationPermissionAsked(), isTrue);
    // Every later trigger (a meal saved, the summary switched on again).
    expect(await askNotificationPermissionOnce(), isNull);
    expect(await askNotificationPermissionOnce(), isNull);
    expect(requests, 1, reason: 'two denials would be permanent');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(notificationPermissionAskedPrefsKey), isTrue);
  });

  test('two triggers at once still show one dialog', () async {
    await Future.wait(
        [askNotificationPermissionOnce(), askNotificationPermissionOnce()]);
    expect(requests, 1);
  });

  test('never in a background run', () async {
    isHeadlessEngine = true;
    expect(await askNotificationPermissionOnce(), isNull);
    expect(requests, 0);
    isHeadlessEngine = false;
    expect(await notificationPermissionAsked(), isFalse,
        reason: 'the run did not use up the one ask');
  });

  test('never on iOS (it asks during init, as before)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await askNotificationPermissionOnce(), isNull);
    var settingsOpened = 0;
    await fixNotificationsOff(fallback: () async => settingsOpened++);
    expect(settingsOpened, 1, reason: 'iOS: system settings, as before');
    expect(requests, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(notificationPermissionAskedPrefsKey), isNull);
  });

  test('a failing request is not a throw, and does not use up the one ask',
      () async {
    debugRequestNotificationPermission =
        () async => throw PlatformException(code: 'no activity');
    expect(await askNotificationPermissionOnce(), isNull);
    expect(await notificationPermissionAsked(), isFalse,
        reason: 'no request ran');
    debugRequestNotificationPermission = () async {
      requests++;
      return true;
    };
    expect(await askNotificationPermissionOnce(), isTrue);
    expect(requests, 1);
    expect(await notificationPermissionAsked(), isTrue);
  });

  // Review (finding 8): main asked at every start, so an upgrader has
  // answered already — maybe twice, which Android makes permanent.
  group('an install from before this scheme counts as asked', () {
    test('preferences an earlier version left: asked, once per install',
        () async {
      SharedPreferences.setMockInitialValues(
          {'settings.report_time': '21:30', 'background.last_run_iso': 'x'});
      await settleNotificationAskAtLaunch();
      expect(await notificationPermissionAsked(), isTrue);
      expect(await askNotificationPermissionOnce(), isNull);
      expect(requests, 0, reason: 'a trigger asks nothing');
    });

    test('a fresh install (nothing stored at its first launch): not asked, '
        'and still not at its second launch', () async {
      SharedPreferences.setMockInitialValues({});
      await settleNotificationAskAtLaunch();
      expect(await notificationPermissionAsked(), isFalse);
      // The first launch wrote settings; the second must not read them as
      // an earlier version's.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('settings.report_time', '21:30');
      await settleNotificationAskAtLaunch();
      expect(await notificationPermissionAsked(), isFalse);
      expect(await askNotificationPermissionOnce(), isFalse);
      expect(requests, 1);
    });

    test('never in a background run, never on iOS', () async {
      SharedPreferences.setMockInitialValues({'settings.report_time': 'x'});
      isHeadlessEngine = true;
      await settleNotificationAskAtLaunch();
      isHeadlessEngine = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await settleNotificationAskAtLaunch();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(notificationAskSchemePrefsKey), isNull);
    });
  });

  group('fixNotificationsOff (Settings\' notifications-off row)', () {
    /// A request during which Android's dialog comes up: the app loses
    /// focus, then gets it back.
    Future<bool?> withDialog(bool answer) async {
      requests++;
      final binding = TestWidgetsFlutterBinding.instance;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return answer;
    }

    setUp(() => TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    test('never asked → the system dialog, not a settings page', () async {
      debugRequestNotificationPermission = () => withDialog(false);
      var fallbacks = 0;
      nativeAnswers((_) => true);
      await fixNotificationsOff(fallback: () async => fallbacks++);
      expect(requests, 1);
      expect(channelCalls, isEmpty, reason: 'the user answered the dialog');
      expect(fallbacks, 0);
    });

    test('never asked, but no dialog comes up (Android 12 and older, or a '
        'denial Android no longer asks about) → the settings page', () async {
      nativeAnswers((_) => true);
      await fixNotificationsOff(fallback: () async {});
      expect(requests, 1, reason: 'the request ran: the ask is used');
      expect(channelCalls, ['openNotificationSettings'],
          reason: 'the first tap must do something');
      expect(await notificationPermissionAsked(), isTrue);
    });

    test('never asked, and the request fails → the settings page, and the '
        'ask is not used up', () async {
      debugRequestNotificationPermission =
          () async => throw PlatformException(code: 'no activity');
      nativeAnswers((_) => true);
      await fixNotificationsOff(fallback: () async {});
      expect(channelCalls, ['openNotificationSettings']);
      expect(await notificationPermissionAsked(), isFalse);
    });

    test('asked → the app\'s notification settings page', () async {
      await askNotificationPermissionOnce();
      var fallbacks = 0;
      nativeAnswers((call) =>
          call.method == 'openNotificationSettings' ? true : null);
      await fixNotificationsOff(fallback: () async => fallbacks++);
      expect(channelCalls, ['openNotificationSettings']);
      expect(fallbacks, 0);
      expect(requests, 1, reason: 'no second dialog');
    });

    test('an older native build (no such method) → App info', () async {
      await askNotificationPermissionOnce();
      var fallbacks = 0;
      // No handler at all: MissingPluginException.
      await fixNotificationsOff(fallback: () async => fallbacks++);
      expect(fallbacks, 1);
    });

    test('a page that would not open, or a platform error → App info',
        () async {
      await askNotificationPermissionOnce();
      var fallbacks = 0;
      nativeAnswers((_) => false);
      await fixNotificationsOff(fallback: () async => fallbacks++);
      nativeAnswers((_) => throw PlatformException(code: 'x'));
      await fixNotificationsOff(fallback: () async => fallbacks++);
      expect(fallbacks, 2);
    });
  });
}
