// The share extension links Photos.framework (receive_sharing_intent's
// PHAsset lookup, compiled statically into the appex through SPM), and App
// Store Connect's purpose-string scan (ITMS-90683) runs per bundle — so the
// extension carries Runner's NSPhotoLibraryUsageDescription too, in both
// languages (release finding T-TC-1). The extension never asks at runtime.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

String? _plistString(String plist, String key) => RegExp(
        '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>')
    .firstMatch(plist)
    ?.group(1);

String? _stringsValue(String strings, String key) =>
    RegExp('"${RegExp.escape(key)}"\\s*=\\s*"([^"]*)";')
        .firstMatch(strings)
        ?.group(1);

void main() {
  final ios = '${_appRoot().path}/ios';
  const key = 'NSPhotoLibraryUsageDescription';

  test('the share extension has the photo purpose string, same as Runner',
      () {
    final runner = File('$ios/Runner/Info.plist').readAsStringSync();
    final ext = File('$ios/ShareExtension/Info.plist').readAsStringSync();
    final runnerText = _plistString(runner, key);
    expect(runnerText, isNotNull);
    expect(_plistString(ext, key), runnerText);
  });

  test('and its localized copies match Runner\'s, per language', () {
    for (final lang in ['en', 'zh-Hans']) {
      final runner =
          File('$ios/Runner/$lang.lproj/InfoPlist.strings').readAsStringSync();
      final ext = File('$ios/ShareExtension/$lang.lproj/InfoPlist.strings')
          .readAsStringSync();
      final runnerText = _stringsValue(runner, key);
      expect(runnerText, isNotNull, reason: lang);
      expect(_stringsValue(ext, key), runnerText, reason: lang);
    }
  });
}
