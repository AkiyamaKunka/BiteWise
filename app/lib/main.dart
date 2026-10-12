/// Entry point: async init (settings → dao → reclaimStaleProcessing →
/// services, wired in ui/di.dart), then the Material app shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'ui/app.dart';
import 'ui/di.dart';

final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

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
      // Notification-style snackbar for background photo saves (spec §6).
      notify: (msg) => messengerKey.currentState
          ?.showSnackBar(SnackBar(content: Text(msg))),
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
