/// Entry point: async init (settings → dao → reclaimStaleProcessing →
/// services, wired in ui/di.dart), then the Material app shell.
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:sqflite/sqflite.dart' show DatabaseException;

import 'ui/app.dart';
import 'ui/di.dart';
import 'ui/widgets/usual_offer_card.dart' show usualSnackClosing;

final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Snackbar sink for the photo pipeline and the startup glue (di.dart
/// `notify`). A message can arrive BEFORE the first frame: a cold-start
/// share whose verdict needs no analyzer call (duplicate / already logged,
/// DB-only) resolves while init is still running, and
/// `currentState?.showSnackBar` dropped it on the floor. Held until a frame
/// has mounted the ScaffoldMessenger, then shown in arrival order.
final List<({String message, SnackBarAction? action})> _pendingSnackbars = [];

void showAppSnackbar(String message) => _holdSnackbar(message, null);

/// [showAppSnackbar] with one action button: the restaurant assist's Undo
/// after it applied a chain's published numbers (di.dart `notifyAction`).
void showAppSnackbarWithAction(
        String message, String action, void Function() onAction) =>
    _holdSnackbar(message, SnackBarAction(label: action, onPressed: onAction));

void _holdSnackbar(String message, SnackBarAction? action) {
  _pendingSnackbars.add((message: message, action: action));
  _flushSoon();
}

/// [_flushSnackbars] now, or after the next frame when the messenger is
/// not mounted yet.
void _flushSoon() {
  if (!_flushSnackbars()) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushSnackbars());
  }
}

/// How long a snackbar with an action (the lookup's Undo) stays up: the
/// same 8 s as the usual-foods and Settings ones.
const Duration kAppActionSnackDuration = Duration(seconds: 8);

/// The one message of ours the messenger holds (on screen, or behind a
/// screen's own snackbar), until it closes.
({
  ScaffoldMessengerState messenger,
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller,
})? _shown;

/// The usual-foods snackbar's closing that [_flushSnackbars] waits for.
Future<void>? _waitingFor;

/// True once the messenger is mounted (the next pending message is on it,
/// or waits for the one it holds). Not mounted (startup error screen):
/// kept for the next message or frame.
///
/// One at a time, so a usual-foods result and its Undo (showUsualSnack,
/// shown in place of the snackbar that is up) are next on screen, and the
/// messages still pending here follow it (owner decision 2026-11-11, RC
/// 1.6.0 finding 4). Handed over all at once, a catch-up's "Logged" lines
/// sat in the messenger's own queue, ahead of the Undo, 4 s each.
///
/// None is handed over while a usual-foods snackbar is up either
/// (usualSnackClosing): in the messenger's queue the message would wait
/// behind it, and a second Use, which replaces only the snackbar that is
/// up, would put its own Undo behind the message.
///
/// A snackbar with an action never times out by default (SnackBar.persist
/// defaults to `action != null`): the lookup's Undo stayed up until tapped,
/// and every later message queued unseen behind it. It times out after
/// [kAppActionSnackDuration] and is held only with a screen reader on,
/// where reaching Undo takes longer (the usual-foods rule).
bool _flushSnackbars() {
  final messenger = messengerKey.currentState;
  if (messenger == null) return false;
  final shown = _shown;
  // A disposed messenger never reports its snackbars closed: once it is
  // gone, nothing waits for it.
  if (shown != null &&
      identical(shown.messenger, messenger) &&
      messenger.mounted) {
    return true;
  }
  _shown = null;
  if (_pendingSnackbars.isEmpty) return true;
  final usual = usualSnackClosing(messenger);
  if (usual != null) {
    if (!identical(_waitingFor, usual)) {
      _waitingFor = usual;
      usual.whenComplete(() {
        if (identical(_waitingFor, usual)) _waitingFor = null;
        _flushSoon();
      });
    }
    return true;
  }
  final s = _pendingSnackbars.removeAt(0);
  final controller = messenger.showSnackBar(s.action == null
      ? SnackBar(content: Text(s.message))
      : SnackBar(
          content: Text(s.message),
          action: s.action,
          duration: kAppActionSnackDuration,
          persist: MediaQuery.accessibleNavigationOf(messenger.context),
        ));
  _shown = (messenger: messenger, controller: controller);
  controller.closed.whenComplete(() {
    if (!identical(_shown?.controller, controller)) return;
    _shown = null;
    _flushSoon();
  });
  return true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformDispatcher.instance.onError = onUncaughtError;
  await _boot();
}

/// The root isolate's uncaught errors. The engine's own report of one
/// ('Unhandled Exception: ' and its text) reaches the device log in release
/// builds too, and sqflite's text carries the statement and its arguments:
/// meal text, weights, girths. A database error is logged by its type and
/// its stack, never its text, and handled; every other error goes on to
/// the engine's report as before (false). A backstop: the code that writes
/// catches its errors.
///
/// The stack is frames only (function, file, line; in a release build
/// addresses, which `flutter symbolize` reads with the Dart symbols each
/// release keeps), so it says which write threw. The string as the VM
/// made it: debugPrintStack parses every frame, and a release build's
/// split-debug-info frames do not parse (it throws on them).
@visibleForTesting
bool onUncaughtError(Object error, StackTrace stack) {
  if (error is! DatabaseException) return false;
  debugPrint('Uncaught database error (${error.runtimeType})\n$stack');
  return true;
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
      // The restaurant assist's "used the chain's numbers" line and its Undo.
      notifyAction: showAppSnackbarWithAction,
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
