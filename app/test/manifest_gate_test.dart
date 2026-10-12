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
  // The ~ipad list keeps every orientation, because iPad multitasking
  // requires all four and the wider screen has room for the layout.
  test('Info.plist locks iPhone to portrait and leaves iPad free', () {
    final plist = File('${_appRoot().path}/ios/Runner/Info.plist')
        .readAsStringSync();
    expect(_plistStrings(plist, 'UISupportedInterfaceOrientations'),
        ['UIInterfaceOrientationPortrait']);
    expect(
        _plistStrings(plist, 'UISupportedInterfaceOrientations~ipad'),
        containsAll([
          'UIInterfaceOrientationPortrait',
          'UIInterfaceOrientationPortraitUpsideDown',
          'UIInterfaceOrientationLandscapeLeft',
          'UIInterfaceOrientationLandscapeRight',
        ]));
  });
}
