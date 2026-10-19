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
