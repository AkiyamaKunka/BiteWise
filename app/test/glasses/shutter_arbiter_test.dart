// One press of the glasses' capture button = one photo, never two
// (lib/services/glasses/shutter_arbiter.dart). Whether the glasses still
// shoot by themselves while an app listens to the button is unknown until
// hardware (H1), and a double press sends a short press first (DAT 1.0
// known issue): the app asks for a photo only when, after a short press,
// nothing else happened within the window.
import 'package:calorie_tracker/services/glasses/meta_dat_channel.dart';
import 'package:calorie_tracker/services/glasses/shutter_arbiter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_meta_dat_native.dart';

void main() {
  late int captures;
  late ShutterArbiter arbiter;

  setUp(() {
    captures = 0;
    arbiter = ShutterArbiter(capture: () async {
      captures++;
      return true;
    });
  });

  tearDown(() => arbiter.dispose());

  const short = MetaDatButton(MetaDatPress.shortPress);

  testWidgets('a short press with no photo of its own → the app asks once',
      (tester) async {
    arbiter.onEvent(short);
    expect(arbiter.armed, isTrue);
    await tester.pump(const Duration(milliseconds: 2900));
    expect(captures, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(captures, 1);
    expect(arbiter.armed, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(captures, 1);
  });

  testWidgets('the glasses shooting by themselves cancels the request',
      (tester) async {
    for (final own in <MetaDatEvent>[
      const MetaDatProgress(0.1),
      MetaDatPhoto(fakeJpeg(), MetaDatPhotoFormat.jpeg, DateTime(2026)),
    ]) {
      arbiter.onEvent(short);
      await tester.pump(const Duration(seconds: 1));
      arbiter.onEvent(own);
      await tester.pump(const Duration(seconds: 5));
    }
    expect(captures, 0);
  });

  testWidgets('a double press (short press first) and a hold take no photo',
      (tester) async {
    arbiter.onEvent(short);
    await tester.pump(const Duration(milliseconds: 400));
    arbiter.onEvent(const MetaDatButton(MetaDatPress.doublePress));
    arbiter.onEvent(const MetaDatButton(MetaDatPress.hold));
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 0);
  });

  testWidgets('a second short press restarts the window, still one photo',
      (tester) async {
    arbiter.onEvent(short);
    await tester.pump(const Duration(seconds: 2));
    arbiter.onEvent(short);
    await tester.pump(const Duration(seconds: 2));
    expect(captures, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(captures, 1);
  });

  testWidgets('a session or camera that stops disarms it', (tester) async {
    arbiter.onEvent(short);
    arbiter.onEvent(const MetaDatSessionChanged(MetaDatSessionState.paused));
    arbiter.onEvent(short);
    arbiter.onEvent(const MetaDatCameraChanged(MetaDatCameraState.stopping));
    // A started state is not a reason to cancel.
    arbiter.onEvent(short);
    arbiter.onEvent(const MetaDatSessionChanged(MetaDatSessionState.started));
    arbiter.onEvent(const MetaDatCameraChanged(MetaDatCameraState.started));
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 1);
  });

  testWidgets('dispose cancels; a failing capture never throws',
      (tester) async {
    arbiter.onEvent(short);
    arbiter.dispose();
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 0);

    final failing = ShutterArbiter(
        capture: () async => throw StateError('busy'),
        window: const Duration(milliseconds: 10));
    failing.onEvent(short);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    failing.dispose();
  });
}
