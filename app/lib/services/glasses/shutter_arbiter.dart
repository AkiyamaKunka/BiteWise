/// What a press of the glasses' capture button should do during a session.
///
/// DAT 1.0 leaves two things open until real hardware is in hand (H1,
/// docs/META_DAT.md): whether the glasses still take their own photo when
/// an app listens to the capture button (DAT says such shots "arrive on the
/// same publisher" as the app's), and a known issue that a DOUBLE press
/// sends a short press first. So a short press only ARMS a capture: if
/// the glasses' own photo starts arriving within [window], or the press
/// turns out to be a double press or a hold, nothing more happens; only
/// silence makes the app ask for the photo itself. Either way one press
/// gives one photo, never two.
library;

import 'dart:async';

import 'meta_dat_channel.dart';

class ShutterArbiter {
  ShutterArbiter({
    required this.capture,
    this.window = const Duration(seconds: 3),
  });

  /// Asks the glasses for a photo (MetaDatChannel.capture).
  final Future<bool> Function() capture;
  final Duration window;

  Timer? _armed;
  bool _disposed = false;

  bool get armed => _armed != null;

  /// Feed every channel event through here.
  void onEvent(MetaDatEvent e) {
    switch (e) {
      case MetaDatButton(press: MetaDatPress.shortPress):
        _cancel();
        _armed = Timer(window, _fire);
      case MetaDatButton():
        // doublePress follows its own shortPress (known issue); hold has
        // no meaning here. Neither is a photo request.
        _cancel();
      case MetaDatProgress() || MetaDatPhoto():
        // The glasses' own shot is on its way.
        _cancel();
      case MetaDatSessionChanged(:final state)
          when state != MetaDatSessionState.started:
        _cancel();
      case MetaDatCameraChanged(:final state)
          when state != MetaDatCameraState.started:
        _cancel();
      default:
        break;
    }
  }

  void _fire() {
    _armed = null;
    if (_disposed) return;
    // A refused request (busy, not ready) is the screen's to explain via
    // the channel's own error events; never thrown from a timer.
    unawaited(capture().then((_) {}, onError: (Object _) {}));
  }

  void _cancel() {
    _armed?.cancel();
    _armed = null;
  }

  void dispose() {
    _disposed = true;
    _cancel();
  }
}
