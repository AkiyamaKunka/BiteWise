/// Build flags for the Meta glasses session (feat/meta-dat prototype,
/// docs/META_DAT.md). Both default OFF: a plain build shows nothing, and the
/// native SDK is never initialised because nothing calls `configure`.
///
///   flutter build ios --dart-define=BITEWISE_META_DAT=true
///   (xcodebuild: `DART_DEFINES=` + base64 of `BITEWISE_META_DAT=true`)
///
/// BITEWISE_META_DAT_MOCK=true additionally pairs DAT's Mock Device Kit
/// glasses (debug builds only) so the whole flow runs on the simulator.
library;

import 'package:flutter/foundation.dart' show TargetPlatform;

const bool kMetaDatEnabled = bool.fromEnvironment('BITEWISE_META_DAT');
const bool kMetaDatMock = bool.fromEnvironment('BITEWISE_META_DAT_MOCK');

/// Whether the add sheet offers the glasses session: the flag is on and
/// the phone is an iPhone (DAT's Android toolkit is not wired here).
bool metaDatEntryVisible(
  TargetPlatform platform, {
  bool enabled = kMetaDatEnabled,
}) => enabled && platform == TargetPlatform.iOS;
