/// The real photo_manager permission probes (2026-10-10): the manifest
/// declares READ_MEDIA_IMAGES (+ VISUAL_USER_SELECTED) and no video
/// permission, so both probes must ask Android for images only. With the
/// plugin default (image|video) PermissionDelegate34 folds the undeclared
/// READ_MEDIA_VIDEO into Limited — every 全部允许 grant on Android 14+ then
/// reads as 部分照片权限 with a 去修复 that cannot fix anything — and
/// PermissionDelegate33 (Android 13) answers Denied on every grant.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:calorie_tracker/services/photo/photo_library.dart';

/// photo_manager's own channel; its PMMethodChannel only adds a cancelToken
/// key to the argument map, so a mock keyed by name intercepts it.
const _channel = MethodChannel('com.fluttercandies/photo_manager');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  /// Replies [state] to every probe and records what the app asked for.
  List<MethodCall> reply(PermissionState state) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return state.index;
    });
    return calls;
  }

  void expectImagesOnly(MethodCall call, String method) {
    expect(call.method, method);
    final args = call.arguments as Map;
    final android = args['androidPermission'] as Map;
    expect(android['type'], RequestType.image.value,
        reason: '$method must not ask for video: the manifest declares '
            'READ_MEDIA_IMAGES only, so image|video reads as limited/denied');
    expect(android['mediaLocation'], isFalse);
    // iOS is untouched: IosAccessLevel.readWrite is sent as index + 1.
    expect(args['iosAccessLevel'], IosAccessLevel.readWrite.index + 1);
  }

  test('both probes ask Android for images only, never video', () async {
    final library = PhotoManagerLibrary();
    final calls = reply(PermissionState.authorized);
    expect(await library.hasFullAccess(), isTrue);
    expect(await library.requestPermission(), isTrue);
    expect(calls, hasLength(2));
    expectImagesOnly(calls[0], 'getPermissionState');
    expectImagesOnly(calls[1], 'requestPermissionExtend');
  });

  test('limited: access but not full; denied: no access', () async {
    final library = PhotoManagerLibrary();
    reply(PermissionState.limited);
    expect(await library.hasFullAccess(), isFalse);
    expect(await library.requestPermission(), isTrue);
    reply(PermissionState.denied);
    expect(await library.hasFullAccess(), isFalse);
    expect(await library.requestPermission(), isFalse);
  });
}
