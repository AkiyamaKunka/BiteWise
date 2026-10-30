// The Dart wrapper of the Meta glasses channel (feat/meta-dat prototype)
// against a mocked native side: every method's name and arguments, the
// status map, refusals as MetaDatException, and native events — including
// malformed ones, which are dropped rather than thrown at the UI.

import 'package:calorie_tracker/services/glasses/meta_dat_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_meta_dat_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeMetaDatNative native;
  late MetaDatChannel channel;

  setUp(() {
    native = FakeMetaDatNative();
    channel = MetaDatChannel();
  });

  tearDown(() async {
    await channel.dispose();
    native.dispose();
  });

  test('the channel name is the one the Swift plugin serves', () {
    expect(metaDatChannelName, 'dev.calorietracker/metadat');
  });

  group('methods', () {
    test('status before configure reads nothing from the SDK', () async {
      final s = await channel.status();
      expect(s.supported, isTrue);
      expect(s.configured, isFalse);
      expect(s.registration, MetaDatRegistration.unknown);
      expect(s.deviceCount, 0);
      expect(native.methods, ['status']);
    });

    test('configure → registered status with devices', () async {
      native.registration = 'registered';
      native.devices = 2;
      final s = await channel.configure();
      expect(s.configured, isTrue);
      expect(s.registered, isTrue);
      expect(s.deviceCount, 2);
      expect(s.mockAvailable, isTrue);
    });

    test('each action sends its method and arguments', () async {
      await channel.register();
      await channel.unregister();
      await channel.startSession();
      await channel.stopSession();
      expect(await channel.requestCameraPermission(), isTrue);
      expect(await channel.capture(), isTrue);
      expect(
          await channel.capture(
              resolution: MetaDatResolution.full,
              quality: MetaDatQuality.medium),
          isTrue);
      await channel.enableMock();
      await channel.enableMock(photo: fakeJpeg());
      expect(await channel.mockCapturePress(MetaDatPress.hold), isTrue);
      expect(native.methods, [
        'register',
        'unregister',
        'startSession',
        'stopSession',
        'requestCameraPermission',
        'capture',
        'capture',
        'enableMock',
        'enableMock',
        'mockCapturePress',
      ]);
      // Default capture: 1080p class at high quality, never full-size by
      // accident (slow over Bluetooth Classic).
      expect(native.calls[5].arguments,
          {'resolution': 'large', 'quality': 'high'});
      expect(native.calls[6].arguments,
          {'resolution': 'full', 'quality': 'medium'});
      // No photo → no key at all: the native side draws its own fixture.
      expect(native.calls[7].arguments, isEmpty);
      expect((native.calls[8].arguments as Map)['photo'], fakeJpeg());
      expect(native.calls[9].arguments, {'press': 'hold'});
    });

    test('a denied camera permission and a refused capture are false',
        () async {
      native.permission = 'denied';
      native.captureAccepted = false;
      expect(await channel.requestCameraPermission(), isFalse);
      expect(await channel.capture(), isFalse);
    });

    test('native refusals arrive as MetaDatException with their code',
        () async {
      native.failures['startSession'] = 'not_configured';
      await expectLater(
          channel.startSession(),
          throwsA(isA<MetaDatException>()
              .having((e) => e.code, 'code', 'not_configured')));
    });

    test('the glasses-app update opens Meta AI; a refusal keeps its code',
        () async {
      await channel.openGlassesAppUpdate();
      expect(native.methods, ['openGlassesAppUpdate']);
      expect(native.calls.single.arguments, isNull);
      native.failures['openGlassesAppUpdate'] = 'navigation';
      await expectLater(
          channel.openGlassesAppUpdate(),
          throwsA(isA<MetaDatException>()
              .having((e) => e.code, 'code', 'navigation')));
    });

    test('status never throws: a refusal reads as unsupported', () async {
      native.failures['status'] = 'internal';
      expect((await channel.status()).supported, isFalse);
    });

    test('no plugin (Android, a build without the branch) is unsupported',
        () async {
      native.dispose(); // nothing answers the channel any more
      expect(await channel.status(), same(MetaDatStatus.unsupported));
      await expectLater(
          channel.configure(),
          throwsA(isA<MetaDatException>()
              .having((e) => e.code, 'code', 'unsupported')));
    });

    test('only Meta AI callback links are forwarded', () async {
      final ok = Uri.parse(
          'bitewise-glasses://x?metaWearablesAction=register&state=abc');
      expect(await channel.handleCallback(ok), isTrue);
      expect(native.calls.single.arguments, {'url': ok.toString()});

      for (final other in [
        Uri.parse('bitewise://setup?server=https://example.com&key=k'),
        Uri.parse('bitewise-glasses://x?other=1'),
        Uri.parse('https://example.com/?metaWearablesAction=register'),
      ]) {
        expect(isMetaDatCallback(other), isFalse, reason: '$other');
        expect(await channel.handleCallback(other), isFalse);
      }
      expect(native.calls, hasLength(1));
      expect(
          isMetaDatCallback(
              Uri.parse('BITEWISE-GLASSES://x?metaWearablesAction=perm')),
          isTrue);
    });
  });

  group('events', () {
    Future<List<MetaDatEvent>> collect(
        Future<void> Function() pushes) async {
      final got = <MetaDatEvent>[];
      final sub = channel.events.listen(got.add);
      await pushes();
      await pumpEventQueue();
      await sub.cancel();
      return got;
    }

    test('every event type the plugin emits is parsed', () async {
      final at = DateTime(2026, 10, 23, 12, 30, 5);
      final got = await collect(() async {
        await native.push({'type': 'registration', 'state': 'registered'});
        await native.push({'type': 'devices', 'count': 1});
        await native.push({'type': 'session', 'state': 'started'});
        await native.push({'type': 'camera', 'state': 'started'});
        await native.push({'type': 'progress', 'fraction': 0.5});
        await native.push({'type': 'button', 'press': 'shortPress'});
        await native.photo(fakeJpeg(), at);
        await native.push(
            {'type': 'error', 'code': 'capture_timeout', 'message': 'x'});
      });
      expect(got, hasLength(8));
      expect((got[0] as MetaDatRegistrationChanged).state,
          MetaDatRegistration.registered);
      expect((got[1] as MetaDatDevicesChanged).count, 1);
      expect((got[2] as MetaDatSessionChanged).state,
          MetaDatSessionState.started);
      expect(
          (got[3] as MetaDatCameraChanged).state, MetaDatCameraState.started);
      expect((got[4] as MetaDatProgress).fraction, 0.5);
      expect((got[5] as MetaDatButton).press, MetaDatPress.shortPress);
      final photo = got[6] as MetaDatPhoto;
      expect(photo.bytes, fakeJpeg());
      expect(photo.format, MetaDatPhotoFormat.jpeg);
      expect(photo.receivedAt, at);
      expect((got[7] as MetaDatFailure).code, 'capture_timeout');
      expect((got[7] as MetaDatFailure).isWarning, isFalse);
    });

    test('only the version warning is news that stops nothing', () async {
      final got = await collect(() async {
        await native.push({
          'type': 'error',
          'code': 'session_version_warning',
          'message': 'dwaOutOfStuRange'
        });
        await native.push({
          'type': 'error',
          'code': 'session_update_glasses_app',
          'message': 'x'
        });
      });
      expect(metaDatVersionWarning, 'session_version_warning');
      expect([for (final e in got) (e as MetaDatFailure).isWarning],
          [true, false]);
    });

    test('malformed payloads are dropped, unknown states are unknown',
        () async {
      final got = await collect(() async {
        await native.push({'type': 'photo', 'bytes': 'not bytes'});
        await native.push({'type': 'photo', 'bytes': Uint8List(0),
            'receivedAtMs': 1});
        await native.push({'type': 'photo', 'bytes': fakeJpeg()});
        await native.push({'type': 'devices', 'count': -1});
        await native.push({'type': 'progress', 'fraction': 'half'});
        await native.push({'type': 'mystery'});
        await native.push({'nothing': true});
        await native.push({'type': 'session', 'state': 'teleporting'});
        await native.push({'type': 'button', 'press': 42});
        await native.push({'type': 'progress', 'fraction': 7});
        await native.push({'type': 'error'});
      });
      expect(got, hasLength(4));
      expect((got[0] as MetaDatSessionChanged).state,
          MetaDatSessionState.unknown);
      expect((got[1] as MetaDatButton).press, MetaDatPress.unknown);
      expect((got[2] as MetaDatProgress).fraction, 1.0); // clamped
      final failure = got[3] as MetaDatFailure;
      expect(failure.code, 'error');
      expect(failure.message, '');
    });

    test('a photo over the size ceiling is dropped', () {
      final big = Uint8List(metaDatMaxPhotoBytes + 1);
      big.setAll(0, [0xFF, 0xD8, 0xFF]);
      expect(
          parseMetaDatEvent(
              {'type': 'photo', 'bytes': big, 'receivedAtMs': 1}),
          isNull);
    });

    test('after dispose, events stop and the handler is released', () async {
      final events = channel.events;
      await channel.dispose();
      expect(await events.isEmpty, isTrue);
      // Pushing now must not throw (no handler answers it).
      await native.push({'type': 'devices', 'count': 1});
      channel = MetaDatChannel(); // tearDown disposes this one
    });
  });

  group('status and formats', () {
    test('fromWire tolerates junk and folds events in', () {
      expect(MetaDatStatus.fromWire(null).supported, isFalse);
      expect(MetaDatStatus.fromWire('x').supported, isFalse);
      final s = MetaDatStatus.fromWire({
        'supported': true,
        'configured': true,
        'registration': 'registered',
        'devices': 'many',
        'session': 'started',
        'camera': 'started',
      });
      expect(s.deviceCount, 0);
      expect(s.canCapture, isTrue);
      expect(s.sessionLive, isTrue);
      final stopped = s.apply(
          const MetaDatSessionChanged(MetaDatSessionState.stopped));
      expect(stopped.session, MetaDatSessionState.stopped);
      expect(stopped.camera, MetaDatCameraState.stopped,
          reason: 'a stopped session takes its camera with it');
      expect(stopped.canCapture, isFalse);
      expect(s.apply(const MetaDatDevicesChanged(3)).deviceCount, 3);
      expect(s.apply(const MetaDatProgress(0.2)), same(s));
    });

    test('JPEG and HEIC are told apart by their first bytes', () {
      expect(sniffPhotoFormat(fakeJpeg()), MetaDatPhotoFormat.jpeg);
      expect(sniffPhotoFormat(fakeHeic()), MetaDatPhotoFormat.heic);
      final mif1 = fakeHeic()..setAll(8, 'mif1'.codeUnits);
      expect(sniffPhotoFormat(mif1), MetaDatPhotoFormat.heic);
      final mp4 = fakeHeic()..setAll(8, 'isom'.codeUnits);
      expect(sniffPhotoFormat(mp4), MetaDatPhotoFormat.unknown);
      expect(sniffPhotoFormat(Uint8List.fromList([0x89, 0x50, 0x4E])),
          MetaDatPhotoFormat.unknown);
      expect(sniffPhotoFormat(Uint8List(0)), MetaDatPhotoFormat.unknown);
    });
  });

  test('an old instance disposed late does not unhook the new one',
      () async {
    final newer = MetaDatChannel();
    await channel.dispose(); // the screen animating out
    final got = <MetaDatEvent>[];
    final sub = newer.events.listen(got.add);
    await native.push({'type': 'devices', 'count': 1});
    await pumpEventQueue();
    expect(got, hasLength(1));
    await sub.cancel();
    channel = newer; // tearDown disposes it
  });

  test('the events stream is broadcast (screen + arbiter both listen)',
      () async {
    final a = <MetaDatEvent>[];
    final b = <MetaDatEvent>[];
    final s1 = channel.events.listen(a.add);
    final s2 = channel.events.listen(b.add);
    await native.push({'type': 'devices', 'count': 1});
    await pumpEventQueue();
    expect(a, hasLength(1));
    expect(b, hasLength(1));
    await s1.cancel();
    await s2.cancel();
  });

  test('handler returns null for unknown native calls', () async {
    Object? reply = 'unset';
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      metaDatChannelName,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('somethingElse')),
      (data) => reply = data == null
          ? null
          : const StandardMethodCodec().decodeEnvelope(data),
    );
    expect(reply, isNull);
  });
}
