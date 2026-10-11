/// Entry point: async init (settings → dao → reclaimStaleProcessing →
/// services, wired in ui/di.dart), then the Material app shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'ui/app.dart';
import 'ui/di.dart';

final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Snackbar sink for the photo pipeline and the startup glue (di.dart
/// `notify`). A message can arrive BEFORE the first frame: a cold-start
/// share whose verdict needs no analyzer call (duplicate / already logged,
/// DB-only) resolves while init is still running, and
/// `currentState?.showSnackBar` dropped it on the floor. Held until a frame
/// has mounted the ScaffoldMessenger, then shown in arrival order.
final List<String> _pendingSnackbars = [];

void showAppSnackbar(String message) {
  _pendingSnackbars.add(message);
  if (!_flushSnackbars()) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushSnackbars());
  }
}

/// True once the messenger is mounted and everything pending was shown.
/// Not mounted (startup error screen): kept for the next message or frame.
bool _flushSnackbars() {
  final messenger = messengerKey.currentState;
  if (messenger == null) return false;
  for (final message in _pendingSnackbars) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
  _pendingSnackbars.clear();
  return true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _boot();
}

/// One startup attempt. A failure shows [StartupErrorApp], which calls this
/// again when the app returns to the foreground: the usual cause is an iOS
/// launch while the phone is still locked before the stored keys have
/// moved to the after-first-unlock keychain class — unlocking fixes it,
/// and nothing should require a force-quit (2026-10-09). AppSettings.load
/// is init's first step, so a keychain failure leaves nothing half-done.
Future<void> _boot() async {
  try {
    final services = await AppServices.init(
      // Notification-style snackbar for background photo saves and
      // share-sheet verdicts (spec §6).
      notify: showAppSnackbar,
    );
    runApp(CalorieTrackerApp(services: services.ui, messengerKey: messengerKey));
  } catch (e) {
    // Startup must never leave a blank screen; surface the failure.
    // Only a keychain failure (PlatformException from the settings load,
    // init's first step) is retried: it clears once the phone unlocks. A
    // later step failing would re-run init's side effects on every resume.
    runApp(StartupErrorApp(
        error: '$e', onRetry: e is PlatformException ? _boot : null));
  }
}
