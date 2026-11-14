/// reselectPhotoAccess (the Play push): Settings' Fix for partial photo
/// access shows Android 14+'s own reselect dialog, and App info only when
/// the dialog could not help. The dialog itself is photo_manager's
/// presentLimited, which a desktop test host skips; the permission states
/// before and after it are answered here over photo_manager's channel.
library;

import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart' show PermissionState;

const _channel = MethodChannel('com.fluttercandies/photo_manager');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The states the platform answers, one per getPermissionState call.
  void states(List<Object> answers) {
    final queue = [...answers];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'getPermissionState') return null;
      final next = queue.removeAt(0);
      if (next is PlatformException) throw next;
      return (next as PermissionState).index;
    });
  }

  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  test('already full: nothing to do', () async {
    states([PermissionState.authorized]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.full);
  });

  test('partial, then Allow all: full', () async {
    states([PermissionState.limited, PermissionState.authorized]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.full);
  });

  test('partial, and a selection kept — or access withdrawn in the dialog: '
      'the user\'s answer, no App info', () async {
    states([PermissionState.limited, PermissionState.limited]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.answered);
    states([PermissionState.limited, PermissionState.denied]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.answered);
  });

  test('withdrawn, and the dialog grants something: answered', () async {
    states([PermissionState.denied, PermissionState.limited]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.answered);
    states([PermissionState.denied, PermissionState.authorized]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.full);
  });

  test('no access before or after (a permanent denial, or below Android '
      '14): App info', () async {
    states([PermissionState.denied, PermissionState.denied]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.openSettings);
  });

  test('the platform would not say: App info', () async {
    states([PlatformException(code: 'x')]);
    expect(await reselectPhotoAccess(), PhotoAccessFix.openSettings);
  });
}
