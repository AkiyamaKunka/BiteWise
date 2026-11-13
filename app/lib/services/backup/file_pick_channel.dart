/// Import › Choose File… (1.7.0): the system's file picker, several JSON
/// files at once. iOS: UIDocumentPickerViewController through the iCloud
/// Backup channel (ios/Runner/CloudBackupPlugin.swift pickFiles); Android:
/// the Storage Access Framework (MainActivity.kt, `dev.calorietracker/
/// files`). Both hand back COPIES in the app's own temporary folders, and
/// the caller deletes them after the import.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'cloud_backup_channel.dart';

const String filesChannelName = 'dev.calorietracker/files';

/// What a pick gave: the copies' paths, how many were refused for size,
/// how many could not be copied at all, or that it was cancelled / is
/// unavailable.
class PickedFiles {
  const PickedFiles(this.paths,
      {this.cancelled = false,
      this.tooBig = 0,
      this.failed = 0,
      this.unavailable = false});
  final List<String> paths;
  final bool cancelled;
  final int tooBig;

  /// Android: picked files that could not be read or copied (a cloud file
  /// that cannot be fetched now, a grant the provider refuses, a full
  /// disk), whatever their size.
  final int failed;
  final bool unavailable;
}

abstract class FilePicker {
  Future<PickedFiles> pickJsonFiles();
}

class PlatformFilePicker implements FilePicker {
  const PlatformFilePicker(
      {this.ios = const ICloudTransport(),
      this.android = const MethodChannel(filesChannelName)});
  final BackupTransport ios;
  final MethodChannel android;

  @override
  Future<PickedFiles> pickJsonFiles() async {
    if (Platform.isIOS) {
      final r = await ios.pickFiles();
      return switch (r.kind) {
        CloudResultKind.ok => PickedFiles(r.paths),
        CloudResultKind.cancelled => const PickedFiles([], cancelled: true),
        _ => const PickedFiles([], unavailable: true),
      };
    }
    try {
      final r = await android.invokeMethod<Object?>('pickFiles');
      if (r is! Map) return const PickedFiles([], unavailable: true);
      return switch (r['status']) {
        'ok' => PickedFiles(
            [for (final p in (r['paths'] as List?) ?? const []) if (p is String) p],
            tooBig: (r['tooBig'] as num?)?.toInt() ?? 0,
            failed: (r['failed'] as num?)?.toInt() ?? 0),
        'cancelled' => const PickedFiles([], cancelled: true),
        _ => const PickedFiles([], unavailable: true),
      };
    } on MissingPluginException {
      return const PickedFiles([], unavailable: true);
    } on PlatformException {
      return const PickedFiles([], unavailable: true);
    }
  }
}
