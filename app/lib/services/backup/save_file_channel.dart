/// Export › Save to device on Android: the system's "save as" screen
/// (Storage Access Framework, ACTION_CREATE_DOCUMENT) through
/// MainActivity's `saveFile` on `dev.calorietracker/files`. Android's
/// share sheet has no "Save to Files": a stock Pixel offers only Quick
/// Share, Drive and Gmail for the export, so a file on the phone itself
/// (Downloads, or any folder the picker shows) needs this.
///
/// The contract (native lane, MainActivity.kt):
/// - args `{path, name, mime}`: [path] is the export in the app's cache
///   folder (getTemporaryDirectory); the native side refuses any path
///   whose canonical form is outside it, so this can never copy the
///   database out;
/// - reply `{status: 'ok' | 'cancelled' | 'busy' | 'unavailable' |
///   'failed'}` once the copy is written, the picker was closed, or it
///   could not run.
///
/// A build without the method (an older MainActivity) answers
/// notImplemented, which Flutter raises as a MissingPluginException:
/// that is [SaveFileStatus.unavailable], and Export falls back to the
/// share sheet.
library;

import 'package:flutter/services.dart';

import 'file_pick_channel.dart' show filesChannelName;

/// The method's name on [filesChannelName].
const String saveFileMethod = 'saveFile';

/// The MIME type of an export.
const String exportMimeType = 'application/json';

enum SaveFileStatus {
  /// The copy is written where the user chose.
  ok,

  /// The user closed the picker: nothing written.
  cancelled,

  /// Another save is still open (one at a time).
  busy,

  /// This build or phone cannot do it: share instead.
  unavailable,

  /// The picker ran but the copy could not be written.
  failed,
}

/// Saves a file the app wrote to a place the user picks.
abstract class FileSaver {
  Future<SaveFileStatus> saveFile(
      {required String path, required String name, required String mime});
}

class PlatformFileSaver implements FileSaver {
  const PlatformFileSaver(
      {this.channel = const MethodChannel(filesChannelName)});
  final MethodChannel channel;

  @override
  Future<SaveFileStatus> saveFile(
      {required String path,
      required String name,
      required String mime}) async {
    try {
      final r = await channel.invokeMethod<Object?>(
          saveFileMethod, {'path': path, 'name': name, 'mime': mime});
      return saveFileStatusOf(r);
    } on MissingPluginException {
      return SaveFileStatus.unavailable;
    } on PlatformException {
      return SaveFileStatus.failed;
    }
  }
}

/// The native reply as a status. Anything that is not the contract's map
/// is [SaveFileStatus.failed]: something answered, so the method exists,
/// but nothing says the copy was written.
SaveFileStatus saveFileStatusOf(Object? reply) {
  if (reply is! Map) return SaveFileStatus.failed;
  return switch (reply['status']) {
    'ok' => SaveFileStatus.ok,
    'cancelled' => SaveFileStatus.cancelled,
    'busy' => SaveFileStatus.busy,
    'unavailable' => SaveFileStatus.unavailable,
    _ => SaveFileStatus.failed,
  };
}
