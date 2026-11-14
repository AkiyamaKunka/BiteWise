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
    await fixNotificationsOff(fallback: () async {});
    expect(requests, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(notificationPermissionAskedPrefsKey), isNull);
  });

  test('a failing request is not a throw', () async {
    debugRequestNotificationPermission =
        () async => throw PlatformException(code: 'no activity');
    expect(await askNotificationPermissionOnce(), isNull);
  });

  group('fixNotificationsOff (Settings\' notifications-off row)', () {
    test('never asked → the system dialog, not a settings page', () async {
      var fallbacks = 0;
      nativeAnswers((_) => true);
      await fixNotificationsOff(fallback: () async => fallbacks++);
      expect(requests, 1);
      expect(channelCalls, isEmpty);
      expect(fallbacks, 0);
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
