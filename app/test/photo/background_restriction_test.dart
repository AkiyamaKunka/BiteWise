/// The Android 电池 › 受限 probe behind the 后台扫描 row (2026-10-10): the
/// native answer is inverted into "background allowed", and anything the
/// platform side cannot answer is null — never a throw — so Settings
/// leaves the row as it was instead of inventing a remedy.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/services/photo/background_restriction.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() =>
      messenger.setMockMethodCallHandler(backgroundRestrictionChannel, null));

  test('Restricted → not allowed; unrestricted → allowed', () async {
    for (final restricted in const [true, false]) {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(backgroundRestrictionChannel,
          (call) async {
        calls.add(call.method);
        return restricted;
      });
      expect(await androidBackgroundAllowed(), !restricted);
      expect(calls, ['isBackgroundRestricted']);
    }
  });

  test('no channel (tests, an older native build) → null, not a throw',
      () async {
    expect(await androidBackgroundAllowed(), isNull);
  });

  test('a platform error → null', () async {
    messenger.setMockMethodCallHandler(backgroundRestrictionChannel,
        (call) async => throw PlatformException(code: 'boom'));
    expect(await androidBackgroundAllowed(), isNull);
  });

  test('a null answer stays null', () async {
    messenger.setMockMethodCallHandler(
        backgroundRestrictionChannel, (call) async => null);
    expect(await androidBackgroundAllowed(), isNull);
  });
}
