/// Dart side of the Meta glasses bridge (ios/Runner/MetaDatPlugin.swift,
/// feat/meta-dat prototype, docs/META_DAT.md).
///
/// One method channel both ways. Dart calls the methods below; the native
/// side reports what the glasses do as `event` calls, parsed into
/// [MetaDatEvent]s. Native payloads are untrusted shapes: anything
/// malformed is dropped, never thrown at the UI.
library;

import 'dart:async';

import 'package:flutter/services.dart';

const String metaDatChannelName = 'dev.calorietracker/metadat';

/// The URL scheme the Meta AI app calls back on after registration and
/// permission prompts (Info.plist MWDAT > AppLinkURLScheme).
const String metaDatCallbackScheme = 'bitewise-glasses';

/// A link meant for the toolkit: our callback scheme AND the query item
/// Meta's samples filter on, so no other link is ever forwarded.
bool isMetaDatCallback(Uri uri) =>
    uri.scheme.toLowerCase() == metaDatCallbackScheme &&
    uri.queryParameters.containsKey('metaWearablesAction');

enum MetaDatRegistration {
  unavailable,
  available,
  registering,
  registered,
  unknown,
}

enum MetaDatSessionState {
  idle,
  starting,
  started,
  paused,
  stopping,
  stopped,
  unknown,
}

/// The standalone photo capability's state; capture works in [started].
enum MetaDatCameraState { stopped, starting, started, stopping, unknown }

enum MetaDatPress { shortPress, hold, doublePress, unknown }

enum MetaDatPhotoFormat { jpeg, heic, unknown }

/// Size classes DAT offers (only [full] is fixed: 4032×3024).
enum MetaDatResolution { small, medium, large, full }

enum MetaDatQuality { low, medium, high }

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}

/// What the native side knows right now. [supported] is false where there
/// is no plugin (Android, tests, a build without this branch).
class MetaDatStatus {
  final bool supported;
  final bool configured;
  final MetaDatRegistration registration;
  final int deviceCount;

  /// The toolkit picked connected glasses for a session; until then DAT
  /// refuses one (no_device).
  final bool activeDevice;
  final MetaDatSessionState session;
  final MetaDatCameraState camera;

  /// Mock Device Kit glasses are paired (debug builds only).
  final bool mock;
  final bool mockAvailable;

  const MetaDatStatus({
    this.supported = true,
    this.configured = false,
    this.registration = MetaDatRegistration.unknown,
    this.deviceCount = 0,
    this.activeDevice = false,
    this.session = MetaDatSessionState.idle,
    this.camera = MetaDatCameraState.stopped,
    this.mock = false,
    this.mockAvailable = false,
  });

  static const unsupported = MetaDatStatus(supported: false);

  factory MetaDatStatus.fromWire(Object? raw) {
    if (raw is! Map) return unsupported;
    final devices = raw['devices'];
    return MetaDatStatus(
      supported: raw['supported'] == true,
      configured: raw['configured'] == true,
      registration: _enumByName(
        MetaDatRegistration.values,
        raw['registration'],
        MetaDatRegistration.unknown,
      ),
      deviceCount: devices is int && devices > 0 ? devices : 0,
      activeDevice: raw['activeDevice'] == true,
      session: _enumByName(
        MetaDatSessionState.values,
        raw['session'],
        MetaDatSessionState.unknown,
      ),
      camera: _enumByName(
        MetaDatCameraState.values,
        raw['camera'],
        MetaDatCameraState.unknown,
      ),
      mock: raw['mock'] == true,
      mockAvailable: raw['mockAvailable'] == true,
    );
  }

  bool get registered => registration == MetaDatRegistration.registered;
  bool get canStart => registered && activeDevice;
  bool get sessionLive =>
      session == MetaDatSessionState.starting ||
      session == MetaDatSessionState.started ||
      session == MetaDatSessionState.paused;
  bool get canCapture =>
      session == MetaDatSessionState.started &&
      camera == MetaDatCameraState.started;

  MetaDatStatus copyWith({
    MetaDatRegistration? registration,
    int? deviceCount,
    bool? activeDevice,
    MetaDatSessionState? session,
    MetaDatCameraState? camera,
  }) => MetaDatStatus(
    supported: supported,
    configured: configured,
    registration: registration ?? this.registration,
    deviceCount: deviceCount ?? this.deviceCount,
    activeDevice: activeDevice ?? this.activeDevice,
    session: session ?? this.session,
    camera: camera ?? this.camera,
    mock: mock,
    mockAvailable: mockAvailable,
  );

  /// Folds a state event in; other events leave the status as it is.
  MetaDatStatus apply(MetaDatEvent e) => switch (e) {
    MetaDatRegistrationChanged(:final state) => copyWith(registration: state),
    MetaDatDevicesChanged(:final count) => copyWith(deviceCount: count),
    MetaDatActiveDeviceChanged(:final active) => copyWith(activeDevice: active),
    // A stopped session takes its photo capability with it.
    MetaDatSessionChanged(:final state) => copyWith(
      session: state,
      camera: state == MetaDatSessionState.stopped
          ? MetaDatCameraState.stopped
          : null,
    ),
    MetaDatCameraChanged(:final state) => copyWith(camera: state),
    _ => this,
  };
}

sealed class MetaDatEvent {
  const MetaDatEvent();
}

final class MetaDatRegistrationChanged extends MetaDatEvent {
  final MetaDatRegistration state;
  const MetaDatRegistrationChanged(this.state);
}

final class MetaDatDevicesChanged extends MetaDatEvent {
  final int count;
  const MetaDatDevicesChanged(this.count);
}

/// The toolkit picked (or lost) the glasses a session would run on.
final class MetaDatActiveDeviceChanged extends MetaDatEvent {
  final bool active;
  const MetaDatActiveDeviceChanged(this.active);
}

final class MetaDatSessionChanged extends MetaDatEvent {
  final MetaDatSessionState state;
  const MetaDatSessionChanged(this.state);
}

final class MetaDatCameraChanged extends MetaDatEvent {
  final MetaDatCameraState state;
  const MetaDatCameraChanged(this.state);
}

/// A photo from the glasses: the bytes exactly as they were produced (JPEG
/// or HEIC with EXIF), and when the PHONE received it — DAT's timestamp is
/// the first transport packet's arrival, seconds after the shutter.
final class MetaDatPhoto extends MetaDatEvent {
  final Uint8List bytes;
  final MetaDatPhotoFormat format;
  final DateTime receivedAt;
  const MetaDatPhoto(this.bytes, this.format, this.receivedAt);
}

/// Transfer progress of a photo on its way (0..1).
final class MetaDatProgress extends MetaDatEvent {
  final double fraction;
  const MetaDatProgress(this.fraction);
}

/// The glasses' capture button.
final class MetaDatButton extends MetaDatEvent {
  final MetaDatPress press;
  const MetaDatButton(this.press);
}

/// The one session error that stops nothing (Swift
/// MetaDatWire.versionWarning, DAT's dwaOutOfStuRange): Meta says the
/// session goes on and the user is only told to update now and then.
const String metaDatVersionWarning = 'session_version_warning';

/// An asynchronous failure (session, photo capability, inputs, a capture
/// that timed out). [code] is a stable wire code; [message] is the SDK's
/// case description, for diagnostics only.
final class MetaDatFailure extends MetaDatEvent {
  final String code;
  final String message;
  const MetaDatFailure(this.code, this.message);

  /// News that stops nothing ([metaDatVersionWarning]).
  bool get isWarning => code == metaDatVersionWarning;
}

/// The largest photo the bridge accepts (mirrors the Swift guard).
const int metaDatMaxPhotoBytes = 50 * 1024 * 1024;

/// One native `event` payload → its event; null for anything malformed.
MetaDatEvent? parseMetaDatEvent(Object? raw) {
  if (raw is! Map) return null;
  switch (raw['type']) {
    case 'registration':
      return MetaDatRegistrationChanged(
        _enumByName(
          MetaDatRegistration.values,
          raw['state'],
          MetaDatRegistration.unknown,
        ),
      );
    case 'devices':
      final count = raw['count'];
      return count is int && count >= 0 ? MetaDatDevicesChanged(count) : null;
    case 'activeDevice':
      final active = raw['active'];
      return active is bool ? MetaDatActiveDeviceChanged(active) : null;
    case 'session':
      return MetaDatSessionChanged(
        _enumByName(
          MetaDatSessionState.values,
          raw['state'],
          MetaDatSessionState.unknown,
        ),
      );
    case 'camera':
      return MetaDatCameraChanged(
        _enumByName(
          MetaDatCameraState.values,
          raw['state'],
          MetaDatCameraState.unknown,
        ),
      );
    case 'progress':
      final f = raw['fraction'];
      if (f is! num || f.isNaN) return null;
      return MetaDatProgress(f.toDouble().clamp(0.0, 1.0));
    case 'button':
      return MetaDatButton(
        _enumByName(MetaDatPress.values, raw['press'], MetaDatPress.unknown),
      );
    case 'photo':
      final bytes = raw['bytes'];
      final ms = raw['receivedAtMs'];
      if (bytes is! Uint8List ||
          bytes.isEmpty ||
          bytes.length > metaDatMaxPhotoBytes ||
          ms is! int) {
        return null;
      }
      return MetaDatPhoto(
        bytes,
        sniffPhotoFormat(bytes),
        DateTime.fromMillisecondsSinceEpoch(ms),
      );
    case 'error':
      final code = raw['code'];
      final message = raw['message'];
      return MetaDatFailure(
        code is String && code.isNotEmpty ? code : 'error',
        message is String ? message : '',
      );
  }
  return null;
}

/// JPEG (FF D8 FF) or HEIC (an ISO-BMFF `ftyp` box with a HEIF brand),
/// from the first bytes; DAT says only "JPEG or HEIC".
MetaDatPhotoFormat sniffPhotoFormat(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return MetaDatPhotoFormat.jpeg;
  }
  if (b.length >= 12 &&
      b[4] == 0x66 && // f
      b[5] == 0x74 && // t
      b[6] == 0x79 && // y
      b[7] == 0x70) {
    // p
    final brand = String.fromCharCodes(b.sublist(8, 12));
    const heif = {
      'heic',
      'heix',
      'hevc',
      'hevx',
      'heim',
      'heis',
      'mif1',
      'msf1',
    };
    if (heif.contains(brand)) return MetaDatPhotoFormat.heic;
  }
  return MetaDatPhotoFormat.unknown;
}

/// A synchronous refusal from the native side ([code] as the Swift
/// MetaDatFailure names it: not_configured, registration, session, …).
class MetaDatException implements Exception {
  final String code;
  final String message;
  const MetaDatException(this.code, this.message);
  @override
  String toString() => 'MetaDatException($code)';
}

/// Typed access to the channel. Owns the channel's handler while alive:
/// create one per screen and [dispose] it.
class MetaDatChannel {
  MetaDatChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(metaDatChannelName) {
    _channel.setMethodCallHandler(_onNativeCall);
    _owner = this;
  }

  /// The instance whose handler is installed. A channel name has ONE
  /// handler: a screen re-opened while the old one is still animating out
  /// installs its own, and the old one's dispose must not remove it.
  static MetaDatChannel? _owner;

  final MethodChannel _channel;
  final _events = StreamController<MetaDatEvent>.broadcast();

  Stream<MetaDatEvent> get events => _events.stream;

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'event') return null;
    final e = parseMetaDatEvent(call.arguments);
    if (e != null && !_events.isClosed) _events.add(e);
    return null;
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw MetaDatException(e.code, e.message ?? '');
    } on MissingPluginException {
      throw const MetaDatException('unsupported', 'No Meta glasses support.');
    }
  }

  /// Never throws: no plugin (or a refusal) reads as unsupported.
  Future<MetaDatStatus> status() async {
    try {
      return MetaDatStatus.fromWire(
        await _channel.invokeMethod<Object?>('status'),
      );
    } on MissingPluginException {
      return MetaDatStatus.unsupported;
    } on PlatformException {
      return MetaDatStatus.unsupported;
    }
  }

  /// Initialises the toolkit (once per process; again is a no-op).
  Future<MetaDatStatus> configure() async =>
      MetaDatStatus.fromWire(await _invoke<Object?>('configure'));

  /// Hands over to the Meta AI app to approve Chopstats; the answer comes
  /// back as a [metaDatCallbackScheme] link for [handleCallback].
  Future<void> register() => _invoke<void>('register');

  Future<void> unregister() => _invoke<void>('unregister');

  /// Forwards a Meta AI callback link; anything else is ignored here.
  Future<bool> handleCallback(Uri uri) async {
    if (!isMetaDatCallback(uri)) return false;
    return await _invoke<bool>('handleUrl', {'url': uri.toString()}) ?? false;
  }

  /// The glasses-camera permission, asked through the Meta AI app.
  Future<bool> requestCameraPermission() async =>
      await _invoke<String>('requestCameraPermission') == 'granted';

  Future<void> startSession() => _invoke<void>('startSession');

  Future<void> stopSession() => _invoke<void>('stopSession');

  /// Asks the glasses for one photo. False while the capability is not
  /// ready or another capture is still in flight.
  Future<bool> capture({
    MetaDatResolution resolution = MetaDatResolution.large,
    MetaDatQuality quality = MetaDatQuality.high,
  }) async =>
      await _invoke<bool>('capture', {
        'resolution': resolution.name,
        'quality': quality.name,
      }) ??
      false;

  /// Opens Meta AI's page that updates the toolkit's app on the glasses:
  /// the remedy for `session_update_glasses_app`.
  Future<void> openGlassesAppUpdate() => _invoke<void>('openGlassesAppUpdate');

  /// Debug builds: pair Mock Device Kit glasses whose captures return
  /// [photo] (a drawn plate when null).
  Future<void> enableMock({Uint8List? photo}) =>
      _invoke<void>('enableMock', {'photo': ?photo});

  /// Debug builds: press the mock glasses' capture button.
  Future<bool> mockCapturePress([
    MetaDatPress press = MetaDatPress.shortPress,
  ]) async =>
      await _invoke<bool>('mockCapturePress', {'press': press.name}) ?? false;

  Future<void> dispose() async {
    if (identical(_owner, this)) {
      _channel.setMethodCallHandler(null);
      _owner = null;
    }
    await _events.close();
  }
}
