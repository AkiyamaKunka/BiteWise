/// iOS background time for a photo already in flight (2026-10-19).
///
/// iOS suspends the app a few seconds after the user leaves it. A photo the
/// open app was analyzing at that moment froze mid-upload or mid-save: the
/// server's answer was lost (Oct 14 01:59), or the photo stayed reserved
/// and was never sent (Oct 18 14:11), and the next open had to wait for the
/// stale reservation. [BackgroundTime.guard] asks iOS for the time to finish
/// that one photo (UIApplication.beginBackgroundTask, in
/// ios/Runner/BackgroundTimePlugin.swift).
///
/// Rules: ONE task per photo, always ended (in `finally`), never begun twice
/// to stretch the time. The native expiration handler ends the task itself
/// when iOS runs out of patience. Only the app's own engine uses this; the
/// headless background run has BGTaskScheduler's grant instead, and Android
/// does not suspend an app this way (no instance there).
library;

import 'dart:ui' show AppLifecycleState;

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show MethodChannel;

/// ios/Runner/BackgroundTimePlugin.swift.
const String backgroundTimeChannelName = 'dev.calorietracker/bgtime';

class BackgroundTime {
  const BackgroundTime(
      [this._channel = const MethodChannel(backgroundTimeChannelName)]);

  final MethodChannel _channel;

  /// The task's token, or null when iOS refused or the channel is missing
  /// (then there is nothing to end).
  Future<int?> begin(String name) async {
    try {
      return await _channel.invokeMethod<int>('begin', {'name': name});
    } catch (_) {
      return null;
    }
  }

  /// Ends [id]'s task; null does nothing. Never throws.
  Future<void> end(int? id) async {
    if (id == null) return;
    try {
      await _channel.invokeMethod<void>('end', {'id': id});
    } catch (_) {}
  }

  /// Runs [body] inside one background task: begun before it, ended after
  /// it, however it ends.
  Future<T> guard<T>(String name, Future<T> Function() body) async {
    final id = await begin(name);
    try {
      return await body();
    } finally {
      await end(id);
    }
  }
}

/// Whether the app's own engine is in the background right now (paused or
/// hidden) — the only time a [BackgroundTime] task matters (2026-10-19).
///
/// Then the photo already in flight finishes inside its task, but nothing
/// new may start: the next photo of a catch-up began a task from the
/// background, shared the same ~30 s, and froze reserved or mid-upload
/// when the time ran out, one or two photos later (simulator: three
/// photos begun after expiry). And iOS has switched the engine's GPU off
/// there (FlutterEngine.mm, on didEnterBackground), so a dart:ui decode
/// parks exactly as in the headless engine (platform_decode.dart).
///
/// 'inactive' is not background: Control Center or the app switcher over
/// a visible app leaves the GPU on. No binding (yet), or no state yet,
/// reads as the foreground: the app keeps logging as it did before.
///
/// The framework's state, not UIApplication's, and the two can differ
/// (review, 2026-10-19; Flutter engine c9a6c48423): a full-screen modal
/// over the Flutter view sends 'paused' (viewDidDisappear) though the app
/// is open — none is presented today, and photos released then are offered
/// again on 'resumed'; and a scene iOS connected in the background would
/// send 'inactive' (viewWillAppear) though the GPU is off — not seen for
/// BGAppRefresh launches, which run the headless engine.
bool appEngineBackgrounded() {
  final AppLifecycleState? state;
  try {
    state = SchedulerBinding.instance.lifecycleState;
  } catch (_) {
    return false;
  }
  return state == AppLifecycleState.paused ||
      state == AppLifecycleState.hidden;
}

/// [appEngineBackgrounded]'s complement, for a catch-up's shouldContinue
/// (foregroundCatchUp): read the next photo only while the app is open.
bool appEngineInForeground() => !appEngineBackgrounded();
