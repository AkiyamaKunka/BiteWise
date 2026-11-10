/// A stand-in for ios/Runner/MetaDatPlugin.swift on the test binary
/// messenger: answers the channel's methods from a scripted state and
/// pushes native → Dart `event` calls exactly as the plugin does.
library;

import 'dart:async';

import 'package:calorie_tracker/services/glasses/meta_dat_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMetaDatNative {
  FakeMetaDatNative() {
    _messenger.setMockMethodCallHandler(channel, _handle);
  }

  static const channel = MethodChannel(metaDatChannelName);
  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  List<String> get methods => [for (final c in calls) c.method];

  // Scripted native state, reported by `status`.
  bool configured = false;
  String registration = 'available';
  int devices = 1;
  bool activeDevice = false;
  String session = 'idle';
  String camera = 'stopped';
  bool mock = false;
  bool mockAvailable = true;

  String permission = 'granted';
  bool captureAccepted = true;

  /// Method name → the PlatformException code it fails with.
  final failures = <String, String>{};

  /// Answer every call as a build without the plugin would.
  bool noPlugin = false;

  /// The glasses get picked right AFTER configure answered: its snapshot
  /// says no device, then the event follows while Dart is still booting.
  bool activateAfterConfigure = false;

  Map<String, Object?> get status => {
        'supported': true,
        'configured': configured,
        'registration': configured ? registration : 'unknown',
        'devices': configured ? devices : 0,
        'activeDevice': configured && activeDevice,
        'session': session,
        'camera': camera,
        'mock': mock,
        'mockAvailable': mockAvailable,
      };

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    if (noPlugin) throw MissingPluginException();
    final code = failures[call.method];
    if (code != null) {
      throw PlatformException(code: code, message: 'scripted $code');
    }
    switch (call.method) {
      case 'status':
        return status;
      case 'configure':
        configured = true;
        final snapshot = status;
        if (activateAfterConfigure) {
          activeDevice = true;
          unawaited(push({'type': 'activeDevice', 'active': true}));
        }
        return snapshot;
      case 'enableMock':
        mock = true;
        registration = 'registered';
        activeDevice = true;
        return null;
      case 'register':
      case 'unregister':
      case 'stopSession':
      case 'openGlassesAppUpdate':
        return null;
      case 'startSession':
        session = 'starting';
        return null;
      case 'handleUrl':
        return true;
      case 'requestCameraPermission':
        return permission;
      case 'capture':
        return captureAccepted;
      case 'mockCapturePress':
        return mock;
    }
    throw MissingPluginException();
  }

  /// A native → Dart event, delivered through the real codec.
  Future<void> push(Map<String, Object?> event) async {
    await _messenger.handlePlatformMessage(
      metaDatChannelName,
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', event)),
      (_) {},
    );
  }

  Future<void> photo(Uint8List bytes, DateTime receivedAt) => push({
        'type': 'photo',
        'bytes': bytes,
        'receivedAtMs': receivedAt.millisecondsSinceEpoch,
      });

  void dispose() => _messenger.setMockMethodCallHandler(channel, null);
}

/// The first bytes of a JPEG / an HEIC, enough for [sniffPhotoFormat].
Uint8List fakeJpeg([int fill = 1]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(60, fill)]);

Uint8List fakeHeic() => Uint8List.fromList([
      0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, // size, 'ftyp'
      0x68, 0x65, 0x69, 0x63, // 'heic'
      ...List.filled(40, 7),
    ]);
