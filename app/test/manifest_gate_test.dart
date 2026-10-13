import 'dart:io';

import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:flutter_test/flutter_test.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

List<String> _plistStrings(String plist, String key) {
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<array>(.*?)</array>',
    dotAll: true,
  ).firstMatch(plist);
  expect(match, isNotNull, reason: '$key missing from Info.plist');
  return RegExp(r'<string>([^<]*)</string>')
      .allMatches(match!.group(1)!)
      .map((m) => m.group(1)!)
      .toList();
}

/// The body of the `project.pbxproj` object `ID /* comment */ = { isa = ...;
/// ... };` at object depth (two tabs); [id] narrows it when the comment is
/// shared, e.g. the two `Resources` build phases.
String _pbxObject(
  String pbxproj, {
  String id = '[0-9A-F]{24}',
  required String comment,
  required String isa,
}) {
  final match = RegExp(
    '\\n\\t\\t$id /\\* ${RegExp.escape(comment)} \\*/ = \\{\\s*isa = $isa;'
    '(.*?)\\n\\t\\t\\};',
    dotAll: true,
  ).firstMatch(pbxproj);
  expect(match, isNotNull, reason: 'project.pbxproj has no $isa "$comment"');
  return match!.group(1)!;
}

/// Release-manifest drift gate.
///
/// Flutter auto-injects INTERNET into the DEBUG and PROFILE manifests (for
/// hot reload / VM service), so debug- and profile-mode testing can never
/// catch a missing network permission — the release APK shipped without
/// internet once and every Gemini call died with "Error contacting Gemini"
/// while all E2E stayed green. The MAIN manifest must declare what release
/// actually needs.
void main() {
  test('main AndroidManifest declares the permissions release needs', () {
    final manifest =
        File('${_appRoot().path}/android/app/src/main/AndroidManifest.xml')
            .readAsStringSync();
    for (final permission in [
      'android.permission.INTERNET',
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.POST_NOTIFICATIONS',
    ]) {
      expect(manifest.contains(permission), isTrue,
          reason: '$permission missing from the MAIN manifest — debug/profile '
              'builds get it auto-injected, release does not.');
    }
  });

  // The notification small icon is only ever named from Dart, which the
  // release resource shrinker cannot see. A drawable stripped from the
  // release APK makes initialize() fail with invalid_icon, the callers'
  // catch blocks swallow it, and Android notifications silently stop in
  // release only. Android also renders the small icon from its alpha
  // channel, so any colour other than white would just be lost.
  test('the notification small icon is white-only and kept in release', () {
    final res = '${_appRoot().path}/android/app/src/main/res';
    final icon = File('$res/drawable/${ReportNotifier.androidSmallIcon}.xml');
    expect(icon.existsSync(), isTrue, reason: '${icon.path} missing');
    final xml = icon.readAsStringSync();
    final colours = RegExp(r'android:(?:fill|stroke)Color="([^"]+)"')
        .allMatches(xml)
        .map((m) => m.group(1)!.toUpperCase())
        .toSet();
    expect(colours, isNotEmpty);
    expect(colours.difference({'#FFFFFFFF', '#FFFFFF', '#FFF'}), isEmpty,
        reason: 'small icons are alpha masks; found $colours');

    final keep = File('$res/raw/keep.xml');
    expect(keep.existsSync(), isTrue,
        reason: 'res/raw/keep.xml missing: release shrinking strips the icon');
    final kept = RegExp(r'tools:keep="([^"]*)"')
        .firstMatch(keep.readAsStringSync())
        ?.group(1)
        ?.split(',')
        .map((e) => e.trim());
    expect(
        kept,
        anyOf(contains('@drawable/${ReportNotifier.androidSmallIcon}'),
            contains('@drawable/*')));
  });

  // The tab screens are laid out portrait-first and do not apply side
  // safe-area insets: rotated, an iPhone drew the calorie ring and the first
  // History bar under the Dynamic Island, and the large title plus the tab bar
  // left only the top of one card visible. The iPhone list is portrait-only.
  // The app is iPhone-only (2026-10-12, owner's App Store decision): both
  // targets are TARGETED_DEVICE_FAMILY = 1 and there is no ~ipad list, so
  // App Review never sees a stretched phone layout on an iPad. Adding iPad
  // back is allowed later; removing it after an iPad build shipped is not.
  test('Info.plist locks iPhone to portrait and the app is iPhone-only', () {
    final plist = File('${_appRoot().path}/ios/Runner/Info.plist')
        .readAsStringSync();
    expect(_plistStrings(plist, 'UISupportedInterfaceOrientations'),
        ['UIInterfaceOrientationPortrait']);
    expect(plist.contains('UISupportedInterfaceOrientations~ipad'), isFalse);
    final pbxproj =
        File('${_appRoot().path}/ios/Runner.xcodeproj/project.pbxproj')
            .readAsStringSync();
    final families = RegExp(r'TARGETED_DEVICE_FAMILY = ([^;]+);')
        .allMatches(pbxproj)
        .map((m) => m.group(1))
        .toList();
    expect(families, isNotEmpty);
    expect(families, everyElement('1'));
  });
  // App Store Connect scans every executable in the IPA for "required
  // reason" APIs and emails ITMS-91053 for each bundle that uses one without
  // a PrivacyInfo.xcprivacy beside it. Both targets do: receive_sharing_intent
  // (which ships no manifest) is compiled into the share extension and the
  // app with its UserDefaults(suiteName:) call, and photo_manager's PHAsset
  // reads leave the creationDate/modificationDate selectors in the app binary
  // (the FileTimestamp category). A plugin's own manifest only covers its
  // resource bundle, so the app and the extension each carry one, and Xcode
  // only copies it when the target's Resources phase lists it.
  test('both iOS targets ship a privacy manifest for the APIs they use', () {
    final ios = '${_appRoot().path}/ios';
    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    const categories = {
      'Runner': {
        'NSPrivacyAccessedAPICategoryUserDefaults',
        'NSPrivacyAccessedAPICategoryFileTimestamp',
      },
      'ShareExtension': {'NSPrivacyAccessedAPICategoryUserDefaults'},
    };
    categories.forEach((target, expected) {
      final file = File('$ios/$target/PrivacyInfo.xcprivacy');
      expect(file.existsSync(), isTrue, reason: '${file.path} missing');
      final plist = file.readAsStringSync();
      for (final key in [
        'NSPrivacyTracking',
        'NSPrivacyTrackingDomains',
        'NSPrivacyCollectedDataTypes',
        'NSPrivacyAccessedAPITypes',
      ]) {
        expect(plist.contains('<key>$key</key>'), isTrue,
            reason: '$key missing from $target/PrivacyInfo.xcprivacy');
      }
      final declared = {
        for (final m in RegExp(
          r'<key>NSPrivacyAccessedAPIType</key>\s*<string>([^<]+)</string>\s*'
          r'<key>NSPrivacyAccessedAPITypeReasons</key>\s*<array>(.*?)</array>',
          dotAll: true,
        ).allMatches(plist))
          m.group(1)!: RegExp(r'<string>([^<]*)</string>')
              .allMatches(m.group(2)!)
              .map((r) => r.group(1)!)
              .toList(),
      };
      expect(declared.keys, unorderedEquals(expected), reason: target);
      for (final reasons in declared.values) {
        expect(reasons, isNotEmpty, reason: target);
        for (final reason in reasons) {
          expect(reason, matches(RegExp(r'^[0-9A-F]{4}\.\d$')),
              reason: '$target declares "$reason", not an approved reason '
                  'code such as CA92.1');
        }
      }

      // target → its Resources phase → the PBXBuildFile → a PBXFileReference
      // that sits in the target's own group, so `path = PrivacyInfo.xcprivacy`
      // resolves to ios/<target>/PrivacyInfo.xcprivacy.
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Resources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Resources phase');
      final buildFileId =
          RegExp(r'([0-9A-F]{24}) /\* PrivacyInfo.xcprivacy in Resources \*/')
              .firstMatch(_pbxObject(pbxproj,
                  id: phaseId!,
                  comment: 'Resources',
                  isa: 'PBXResourcesBuildPhase'))
              ?.group(1);
      expect(buildFileId, isNotNull,
          reason: 'PrivacyInfo.xcprivacy is not in the $target target\'s '
              'Resources build phase, so Xcode never copies it');
      final fileRefId = RegExp('$buildFileId /\\* PrivacyInfo.xcprivacy in '
              'Resources \\*/ = \\{isa = PBXBuildFile; fileRef = ([0-9A-F]{24})')
          .firstMatch(pbxproj)
          ?.group(1);
      expect(fileRefId, isNotNull, reason: '$buildFileId has no fileRef');
      final group = _pbxObject(pbxproj, comment: target, isa: 'PBXGroup');
      expect(group, contains('path = $target;'));
      expect(group, contains('$fileRefId /* PrivacyInfo.xcprivacy */'),
          reason: 'the $target manifest reference is not in the $target '
              'group, so its path would resolve elsewhere');
    });
  });
}
