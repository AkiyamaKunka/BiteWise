import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/services/analyzer/platform_decode.dart'
    show imageIOChannelName;
import 'package:calorie_tracker/services/local_store.dart'
    show localStoreDirName;
import 'package:calorie_tracker/services/photo/background_time.dart'
    show backgroundTimeChannelName;
import 'package:calorie_tracker/services/photo/photo_changes.dart'
    show photoChangesChannelName;
import 'package:calorie_tracker/services/places/places.dart'
    show placesChannelName;
import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:calorie_tracker/ui/background_glue.dart'
    show backgroundNativeLaunchPrefsKey;
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

String _mainActivity() => File('${_appRoot().path}/android/app/src/main/'
        'kotlin/dev/calorietracker/calorie_tracker/MainActivity.kt')
    .readAsStringSync();

String _intakeRules() => File('${_appRoot().path}/android/app/src/main/'
        'kotlin/dev/calorietracker/calorie_tracker/IntakeRules.kt')
    .readAsStringSync();

/// [kotlin] with its comments removed (string literals kept) and every run
/// of whitespace collapsed to one space, so a pin matches code only: a
/// commented-out line no longer satisfies it, and a reflow breaks nothing.
String _kotlinCode(String kotlin) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < kotlin.length) {
    final c = kotlin[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < kotlin.length) {
        out.write(kotlin[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (kotlin.startsWith('//', i)) {
      final end = kotlin.indexOf('\n', i);
      i = end < 0 ? kotlin.length : end;
      continue;
    }
    if (kotlin.startsWith('/*', i)) {
      final end = kotlin.indexOf('*/', i + 2);
      i = end < 0 ? kotlin.length : end + 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The braced body of the function whose declaration starts with
/// [declaration] in [code] (from [_kotlinCode]), braces included; '' for
/// an expression body. Fails when the declaration is missing or repeated.
String _kotlinFunction(String code, String declaration) {
  expect(declaration.allMatches(code), hasLength(1), reason: declaration);
  final start = code.indexOf(declaration);
  // The parameter list, then a return type or not, then { or =.
  var depth = 0;
  var i = code.indexOf('(', start);
  for (; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')' && --depth == 0) break;
  }
  final open = code.indexOf('{', i);
  final equals = code.indexOf('=', i);
  if (equals >= 0 && equals < open) return '';
  String? quote;
  depth = 0;
  for (var j = open; j < code.length; j++) {
    final c = code[j];
    if (quote != null) {
      if (c == r'\') {
        j++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return code.substring(open, j + 1);
    }
  }
  fail('$declaration has no closing brace');
}

/// The JVM tests (android/app/src/test) exercise each of [rules].
void _expectJvmTests(List<String> rules) {
  final test = File('${_appRoot().path}/android/app/src/test/kotlin/dev/'
      'calorietracker/calorie_tracker/IntakeRulesTest.kt');
  expect(test.existsSync(), isTrue, reason: test.path);
  final source = test.readAsStringSync();
  for (final rule in rules) {
    expect(source, contains(rule), reason: 'IntakeRulesTest never runs $rule');
  }
}

/// Where pub resolved [package] (.dart_tool/package_config.json), so a
/// gate can read the plugin version the app actually builds with.
String _pluginRoot(String package) {
  final config = jsonDecode(
      File('${_appRoot().path}/.dart_tool/package_config.json')
          .readAsStringSync()) as Map<String, Object?>;
  final entry = (config['packages'] as List)
      .cast<Map<String, Object?>>()
      .firstWhere((p) => p['name'] == package);
  final root = Uri.parse(entry['rootUri'] as String);
  return root.isAbsolute
      ? root.toFilePath()
      : Directory('${_appRoot().path}/.dart_tool')
          .uri
          .resolveUri(root)
          .toFilePath();
}

String _manifest() =>
    File('${_appRoot().path}/android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

/// [xml] without its comments, so a comment that names a permission or a
/// component never satisfies (or trips) a gate.
String _uncommented(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// Every `<uses-permission>` in [manifest], by name: true when the entry is
/// a `tools:node="remove"` (it strips a library's permission from the
/// merged manifest rather than declaring one).
Map<String, bool> _permissions(String manifest) => {
      for (final m in RegExp(r'<uses-permission\b([^>]*)>')
          .allMatches(_uncommented(manifest)))
        RegExp(r'android:name="([^"]+)"').firstMatch(m.group(1)!)!.group(1)!:
            m.group(1)!.contains('tools:node="remove"'),
    };

/// The permissions [manifest] declares (removals left out).
Set<String> _declared(String manifest) => {
      for (final e in _permissions(manifest).entries)
        if (!e.value) e.key,
    };

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
    final declared = _declared(_manifest());
    for (final permission in [
      'android.permission.INTERNET',
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.POST_NOTIFICATIONS',
    ]) {
      expect(declared.contains(permission), isTrue,
          reason: '$permission missing from the MAIN manifest — debug/profile '
              'builds get it auto-injected, release does not.');
    }
  });

  // Every permission is a Play review question (and a Data safety answer),
  // so none arrives unnoticed. The system photo picker, Save to device
  // and the notification-settings link need none.
  test('the main manifest declares exactly these permissions', () {
    expect(_declared(_manifest()), {
      'android.permission.INTERNET',
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
      'android.permission.READ_EXTERNAL_STORAGE',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.RECEIVE_BOOT_COMPLETED',
    });
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

  // The background scan decodes HEIC through ImageIOPlugin.swift: the
  // headless engine's GPU is off for the whole run, and dart:ui decoding
  // never finishes there (2026-10-18). Nothing in Dart can see a Swift file
  // that is missing from the Runner target, or a channel registered only in
  // the app's engine — the call just answers MissingPluginException and the
  // photo is deferred on every run. So: compiled into Runner (and only
  // Runner — the share extension has no Flutter engine), and registered in
  // BOTH registrant paths.
  test('the ImageIO plugin is built into Runner and registered for both '
      'engines', () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/ImageIOPlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    // The Dart side's channel (platform_decode.dart) is the one Swift serves.
    expect(swift.readAsStringSync(), contains('"$imageIOChannelName"'));
    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* ImageIOPlugin.swift \*/ = '
            r'\{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* ImageIOPlugin.swift */'),
        reason: 'not in the Runner group, so its path resolves elsewhere');
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* ImageIOPlugin.swift in '
            'Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    String sourcesOf(String target) {
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Sources phase');
      return _pbxObject(pbxproj,
          id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase');
    }

    expect(sourcesOf('Runner'),
        contains('$buildFile /* ImageIOPlugin.swift in Sources */'));
    expect(sourcesOf('ShareExtension'), isNot(contains('ImageIOPlugin')));

    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final workmanager = RegExp(
            r'setPluginRegistrantCallback \{ registry in(.*?)\n    \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(1);
    expect(workmanager, isNotNull);
    expect(workmanager, contains('registerAppPlugins(with: registry)'),
        reason: 'the headless background engine would lack the channel');
    final implicit = RegExp(
            r'func didInitializeImplicitFlutterEngine\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(implicit, isNotNull);
    expect(implicit,
        contains('registerAppPlugins(with: engineBridge.pluginRegistry)'));
    expect(delegate, contains('ImageIOPlugin.register(with:'));
  });

  // The app's photo in flight asks iOS for time to finish when the user
  // leaves (BackgroundTimePlugin.swift, 2026-10-19). A Swift file missing
  // from Runner answers MissingPluginException, which the Dart side
  // swallows by design — so nothing but this gate would notice.
  test('the background-time plugin is built into Runner and registered',
      () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/BackgroundTimePlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    final source = swift.readAsStringSync();
    expect(source, contains('"$backgroundTimeChannelName"'));
    // The expiration handler must END the task, or iOS kills the app —
    // through the plugin, and without it too (its engine gone).
    expect(
        RegExp(r'beginBackgroundTask\(withName: name\) \{[^}]*end\(token\)'
                r'[^}]*task\.end\(\)')
            .hasMatch(source),
        isTrue);
    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* BackgroundTimePlugin.swift '
            r'\*/ = \{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* BackgroundTimePlugin.swift */'));
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* BackgroundTimePlugin.swift '
            'in Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
        .firstMatch(
            _pbxObject(pbxproj, comment: 'Runner', isa: 'PBXNativeTarget'))
        ?.group(1);
    expect(
        _pbxObject(pbxproj,
            id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase'),
        contains('$buildFile /* BackgroundTimePlugin.swift in Sources */'));
    // The app's engine registers app-local plugins through this one path.
    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final register = RegExp(
            r'static func registerAppPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(register, contains('BackgroundTimePlugin.register(with:'));
  });

  // The photo library's change history (PhotoChangesPlugin.swift, design
  // G1a, 2026-10-23) is how photos another app imports late — glasses
  // photos the Meta AI app copies in hours later, keeping their capture
  // time — are found at all. A Swift file missing from Runner, or a
  // registration only one engine gets, answers MissingPluginException,
  // which the Dart side turns into a quiet 'error' by design; so the wiring
  // is pinned here. The background run reads the history too, hence both
  // engines (registerAppPlugins; its two callers are pinned above). And it
  // stays read-only: it never writes to the library, and never asks for
  // access, which from a background run would be a prompt nobody sees.
  test('the photo-changes plugin is built into Runner, registered for both '
      'engines, and read-only', () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/PhotoChangesPlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    final source = swift.readAsStringSync();
    expect(source, contains('"$photoChangesChannelName"'));
    for (final write in [
      'performChanges',
      'ChangeRequest',
      'requestAuthorization',
      'presentLimitedLibraryPicker',
    ]) {
      expect(source, isNot(contains(write)),
          reason: 'PhotoChangesPlugin must stay read-only and never prompt');
    }
    expect(source, contains('PHPhotoLibrary.authorizationStatus(for: '
        '.readWrite)'));

    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* PhotoChangesPlugin.swift '
            r'\*/ = \{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* PhotoChangesPlugin.swift */'),
        reason: 'not in the Runner group, so its path resolves elsewhere');
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* PhotoChangesPlugin.swift '
            'in Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    String sourcesOf(String target) {
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Sources phase');
      return _pbxObject(pbxproj,
          id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase');
    }

    expect(sourcesOf('Runner'),
        contains('$buildFile /* PhotoChangesPlugin.swift in Sources */'));
    expect(sourcesOf('ShareExtension'), isNot(contains('PhotoChangesPlugin')));

    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final register = RegExp(
            r'static func registerAppPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(register, contains('registrar(forPlugin: "PhotoChangesPlugin")'));
    expect(register, contains('PhotoChangesPlugin.register(with:'));
  });

  // Restaurant assist's places (PlacesPlugin.swift, design R4,
  // 2026-10-24): Apple Maps on the phone lists the food places around a
  // photo's position. A Swift file missing from Runner answers
  // MissingPluginException, which the Dart side turns into a quiet 'error'
  // by design, so the wiring is pinned here. And it must never need a
  // location permission: no CLLocationManager (the prompt), no geocoder
  // (no city or street, ever), no NSLocation* key in either Info.plist —
  // and on Android no location permission at all, ACCESS_MEDIA_LOCATION
  // included (v1 reads no photo location there).
  test('the places plugin is built into Runner, registered, and needs no '
      'location permission on either platform', () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/PlacesPlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    final source = swift.readAsStringSync();
    expect(source, contains('"$placesChannelName"'));
    expect(source, contains('MKLocalPointsOfInterestRequest'));
    // The code, without its comments (which name what it never does).
    final full = source
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
        .join('\n');
    // The one part of an address it reads (run 6, the meal country): each
    // place's ISO country — the region of addressRepresentations on iOS
    // 26+, the placemark's isoCountryCode before — exactly here, once.
    const countryReads = [
      'let address: MKAddressRepresentations? = item.addressRepresentations',
      'let region: Locale.Region? = address?.region',
      'country = region?.identifier',
      'country = item.placemark.isoCountryCode',
    ];
    var code = full;
    for (final read in countryReads) {
      expect(read.allMatches(full), hasLength(1), reason: read);
      code = code.replaceFirst(read, '');
    }
    // Of a placemark, only its position and that country.
    expect(
        RegExp(r'placemark\.(?!location\b|isoCountryCode\b)').hasMatch(code),
        isFalse,
        reason: 'PlacesPlugin.swift reads more of a placemark');
    for (final banned in [
      'isoCountryCode',
      'fullAddress',
      'cityName',
      'cityWithContext',
      'regionName',
      'regionCode',
      'locality',
      'postalCode',
      'administrativeArea',
      'CLLocationManager',
      'CLGeocoder',
      'requestWhenInUseAuthorization',
      'requestAlwaysAuthorization',
      'requestLocation',
      'startUpdatingLocation',
      'MKReverseGeocodingRequest',
      'MKGeocodingRequest',
      'reverseGeocode',
      // Nothing that identifies or addresses a place goes back to Dart.
      'phoneNumber',
      '.identifier',
      'thoroughfare',
      'postalAddress',
      'addressRepresentations',
      'UserDefaults',
      'FileManager',
    ]) {
      expect(code, isNot(contains(banned)),
          reason: 'PlacesPlugin.swift must not use $banned');
    }

    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* PlacesPlugin.swift \*/ = '
            r'\{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* PlacesPlugin.swift */'),
        reason: 'not in the Runner group, so its path resolves elsewhere');
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* PlacesPlugin.swift in '
            'Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    String sourcesOf(String target) {
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Sources phase');
      return _pbxObject(pbxproj,
          id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase');
    }

    expect(sourcesOf('Runner'),
        contains('$buildFile /* PlacesPlugin.swift in Sources */'));
    expect(sourcesOf('ShareExtension'), isNot(contains('PlacesPlugin')));

    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final register = RegExp(
            r'static func registerAppPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(register, contains('registrar(forPlugin: "PlacesPlugin")'));
    expect(register, contains('PlacesPlugin.register(with:'));

    for (final target in ['Runner', 'ShareExtension']) {
      final plist =
          File('$ios/$target/Info.plist').readAsStringSync();
      expect(RegExp(r'<key>NSLocation[A-Za-z]*</key>').hasMatch(plist),
          isFalse,
          reason: '$target/Info.plist declares a location key: places need '
              'no location permission, and none may be asked for');
    }

    final manifest = File('${_appRoot().path}/android/app/src/main/'
            'AndroidManifest.xml')
        .readAsStringSync();
    for (final permission in [
      'ACCESS_MEDIA_LOCATION',
      'ACCESS_FINE_LOCATION',
      'ACCESS_COARSE_LOCATION',
      'ACCESS_BACKGROUND_LOCATION',
    ]) {
      expect(manifest, isNot(contains(permission)),
          reason: 'v1 reads no location on Android');
    }
  });

  // The iOS background run counts its time budgets from the moment
  // workmanager started its engine (2026-10-19): the AppDelegate stamps it
  // in the registrant callback, which runs right after the engine is
  // created and started and before Dart's task, under the name
  // shared_preferences gives the Dart key. A renamed key, or a stamp written later in the callback,
  // silently falls back to the Dart entry and the boot is uncounted again.
  test('the background launch stamp is written first, under the Dart key',
      () {
    final delegate = File('${_appRoot().path}/ios/Runner/AppDelegate.swift')
        .readAsStringSync();
    expect(delegate,
        contains('"flutter.$backgroundNativeLaunchPrefsKey"'));
    final callback = RegExp(
            r'setPluginRegistrantCallback \{ registry in\s*\n(\s*)(\S[^\n]*)')
        .firstMatch(delegate);
    expect(callback?.group(2), 'AppDelegate.stampBackgroundLaunch()');
  });

  // The backup-excluded local store (lib/services/local_store.dart, design
  // F1, 2026-10-23) holds state that hints at location or only works on
  // this device. Nothing at runtime notices a backup rule that went
  // missing — the app works the same, and the documents just start riding
  // along to iCloud, a computer or a new phone — so the wiring is pinned
  // here. iOS: AppDelegate makes the directory and flags it before
  // anything else at launch (Dart never creates it there).
  test('iOS excludes the local store directory from backup at launch', () {
    final delegate = File('${_appRoot().path}/ios/Runner/AppDelegate.swift')
        .readAsStringSync();
    expect(delegate,
        contains('static let localStoreDirectoryName = "$localStoreDirName"'));
    final prepare = RegExp(r'static func prepareLocalStore\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(prepare, isNotNull, reason: 'AppDelegate.prepareLocalStore missing');
    expect(prepare, contains('.applicationSupportDirectory'));
    expect(prepare, contains('appendingPathComponent(\n      '
        'localStoreDirectoryName, isDirectory: true)'));
    expect(prepare, contains('createDirectory('));
    expect(prepare, contains('values.isExcludedFromBackup = true'));
    expect(prepare, contains('directory.setResourceValues(values)'));

    final launch = RegExp(
            r'didFinishLaunchingWithOptions launchOptions.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(launch, isNotNull);
    final call = launch!.indexOf('AppDelegate.prepareLocalStore()');
    expect(call, greaterThanOrEqualTo(0),
        reason: 'didFinishLaunching never prepares the local store');
    for (final later in [
      'WorkmanagerPlugin.setPluginRegistrantCallback',
      'WorkmanagerPlugin.registerPeriodicTask',
      'super.application(',
    ]) {
      expect(launch.indexOf(later), greaterThan(call),
          reason: 'the local store must be flagged before $later — before '
              'either engine can write into it');
    }
  });

  // Android: exclusion rules by path for both backup schemes, referenced
  // from <application>. Exclude-only: an <include> would silently stop
  // backing up everything else the app keeps.
  test('Android excludes the local store from cloud backup and device '
      'transfer, and includes nothing', () {
    final main = '${_appRoot().path}/android/app/src/main';
    final manifest = File('$main/AndroidManifest.xml').readAsStringSync();
    final application =
        RegExp(r'<application\b[^>]*>').firstMatch(manifest)?.group(0);
    expect(application, isNotNull);
    expect(application,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    expect(application,
        contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(application, isNot(contains('android:allowBackup="false"')),
        reason: 'F1 only excludes the local store; backup stays on');

    final exclude = RegExp('<exclude\\s+domain="file"\\s+'
        'path="${RegExp.escape(localStoreDirName)}/"\\s*/>');
    String section(String xml, String tag) {
      final body = RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true)
          .firstMatch(xml)
          ?.group(1);
      expect(body, isNotNull, reason: '<$tag> missing');
      return body!;
    }

    final extraction = File('$main/res/xml/data_extraction_rules.xml');
    expect(extraction.existsSync(), isTrue, reason: extraction.path);
    final rules = section(
        extraction.readAsStringSync(), 'data-extraction-rules');
    for (final scheme in ['cloud-backup', 'device-transfer']) {
      final body = section(rules, scheme);
      expect(exclude.hasMatch(body), isTrue,
          reason: '$scheme does not exclude $localStoreDirName/');
      expect(body, isNot(contains('<include')), reason: scheme);
    }

    final legacy = File('$main/res/xml/backup_rules.xml');
    expect(legacy.existsSync(), isTrue, reason: legacy.path);
    final full = section(legacy.readAsStringSync(), 'full-backup-content');
    expect(exclude.hasMatch(full), isTrue,
        reason: 'fullBackupContent does not exclude $localStoreDirName/');
    expect(full, isNot(contains('<include')));
  });

  // flutter_secure_storage's files hold the API keys encrypted with a key
  // in this phone's Android Keystore, which never leaves the phone: a copy
  // restored from a cloud backup or carried to a new phone can never be
  // read there (and the plugin's README asks apps to exclude them). Every
  // one of its shared_prefs files stays out of both backup schemes and the
  // Android 11-and-lower rules, so a restored phone starts with no keys
  // and asks for them (AndroidSecureKeyStore covers a copy that already
  // got through). Paths take no wildcards, hence each file by name. No
  // disableIfNoEncryptionCapabilities: an owner decision of its own.
  test("Android keeps flutter_secure_storage's files out of backup and "
      'device transfer', () {
    final main = '${_appRoot().path}/android/app/src/main';
    const files = [
      'FlutterSecureStorage.xml',
      'FlutterSecureKeyStorage.xml',
      'FlutterSecureStorageConfiguration.xml',
      'FlutterSecureStorageConfiguration:FlutterSecureStorage.xml',
    ];
    String section(String xml, String tag) {
      final body = RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true)
          .firstMatch(_uncommented(xml))
          ?.group(1);
      expect(body, isNotNull, reason: '<$tag> missing');
      return body!;
    }

    final extraction =
        File('$main/res/xml/data_extraction_rules.xml').readAsStringSync();
    final legacy = File('$main/res/xml/backup_rules.xml').readAsStringSync();
    final sections = {
      'cloud-backup': section(extraction, 'cloud-backup'),
      'device-transfer': section(extraction, 'device-transfer'),
      'full-backup-content': section(legacy, 'full-backup-content'),
    };
    sections.forEach((name, body) {
      for (final file in files) {
        expect(
            RegExp('<exclude\\s+domain="sharedpref"\\s+'
                    'path="${RegExp.escape(file)}"\\s*/>')
                .hasMatch(body),
            isTrue,
            reason: '$name does not exclude $file');
      }
      expect(body, isNot(contains('<include')), reason: name);
    });
    expect(extraction, isNot(contains('disableIfNoEncryptionCapabilities')));

    // The names, in the plugin version pub resolved: the data and the
    // wrapped-key files (FlutterSecureStorageConfig.java), the saved
    // cipher settings (NamespacedConfigSource.java).
    final java = '${_pluginRoot('flutter_secure_storage')}/android/src/main/'
        'java/com/it_nomads/fluttersecurestorage';
    final config =
        File('$java/FlutterSecureStorageConfig.java').readAsStringSync();
    expect(config,
        contains('DEFAULT_PREF_NAME = "FlutterSecureStorage";'));
    expect(config, contains(': "FlutterSecureKeyStorage";'));
    final source =
        File('$java/NamespacedConfigSource.java').readAsStringSync();
    expect(source,
        contains('LEGACY_GLOBAL_CONFIG_NAME = "FlutterSecureStorageConfiguration";'));
    expect(source,
        contains('return "FlutterSecureStorageConfiguration:" + sharedPreferencesName;'));
  });

  // Design R7a: while restaurant lookup uses the photo location, the app
  // reads where a meal photo was taken. iOS shows NSPhotoLibraryUsageDescription
  // in the permission prompt, from Info.plist and from each InfoPlist.strings
  // (which wins for its language) — so all three must say it, in step: the
  // English pair identical, the Chinese one saying the same. Neither may
  // suggest the location leaves for anyone but Apple Maps.
  test('the photo-library usage string says when the photo location is read, '
      'in Info.plist and both InfoPlist.strings', () {
    final ios = '${_appRoot().path}/ios/Runner';
    final plist = File('$ios/Info.plist').readAsStringSync();
    final fromPlist = RegExp(
            r'<key>NSPhotoLibraryUsageDescription</key>\s*<string>([^<]*)</string>')
        .firstMatch(plist)
        ?.group(1);
    String fromStrings(String lproj) {
      final file = File('$ios/$lproj/InfoPlist.strings');
      expect(file.existsSync(), isTrue, reason: file.path);
      final value = RegExp(r'"NSPhotoLibraryUsageDescription" = "([^"]*)";')
          .firstMatch(file.readAsStringSync())
          ?.group(1);
      expect(value, isNotNull, reason: '$lproj has no usage string');
      return value!;
    }

    expect(fromPlist, isNotNull);
    final en = fromStrings('en.lproj');
    final zh = fromStrings('zh-Hans.lproj');
    expect(en, fromPlist, reason: 'en.lproj mirrors Info.plist');
    // The photo prompt's first purpose is unchanged.
    expect(en, contains('AI service you choose in Settings'));
    expect(zh, contains('AI 服务'));
    // R7a: the photo's location, read only for restaurant lookup, and only
    // to ask Apple Maps — and (run 6) to check on the phone whether a
    // restaurant or takeout photo was taken in the US.
    expect(en, contains('restaurant lookup with photo location'));
    expect(en, contains('where a restaurant or takeout meal photo was taken'));
    expect(en, contains('only to check on this phone whether it was taken in '
        'the US, to ask Apple Maps'));
    expect(zh, contains('使用照片位置的餐厅查询'));
    expect(zh, contains('餐厅餐或外卖照片的拍摄位置'));
    expect(zh, contains('仅用于在本机判断照片是否在美国拍摄、向 Apple 地图查询'));
    // The editor's answers keep a ~100 m cell on the phone (review
    // 2026-10-25): the prompt says so too.
    expect(en, contains('to remember, on this phone, the restaurants you '
        'confirm or rule out'));
    expect(zh, contains('在本机记住你在那里确认或排除的餐厅'));
  });

  // App Store Connect's App Privacy answer is B (docs/RELEASING.md § 4.3,
  // owner decision R-F8): the Runner manifest declares what leaves the
  // phone (photos, health, other user content; release_decisions_test.dart
  // pins the three entries). The restaurant lookup adds no data type: its
  // chain and food names go to the same user-chosen recipient as the
  // photos, and the photo location goes only to Apple's MapKit — so no
  // location type, in either manifest. The share extension sends nothing
  // itself and keeps an empty array.
  test('the restaurant lookup adds no collected data type to either manifest',
      () {
    final ios = '${_appRoot().path}/ios';
    for (final target in const ['Runner', 'ShareExtension']) {
      final plist =
          File('$ios/$target/PrivacyInfo.xcprivacy').readAsStringSync();
      expect(plist, isNot(contains('NSPrivacyCollectedDataTypePreciseLocation')),
          reason: target);
      expect(plist, isNot(contains('NSPrivacyCollectedDataTypeCoarseLocation')),
          reason: target);
      expect(
          RegExp(r'<key>NSPrivacyTracking</key>\s*<false\s*/>').hasMatch(plist),
          isTrue,
          reason: target);
    }
    final share = File('$ios/ShareExtension/PrivacyInfo.xcprivacy')
        .readAsStringSync();
    expect(
        RegExp(r'<key>NSPrivacyCollectedDataTypes</key>\s*<array\s*/>')
            .hasMatch(share),
        isTrue,
        reason: 'ShareExtension/PrivacyInfo.xcprivacy must keep '
            'NSPrivacyCollectedDataTypes an empty array (RELEASING.md § 4.3)');
    final releasing = File('${_appRoot().parent.path}/docs/RELEASING.md')
        .readAsStringSync();
    expect(releasing, contains('NSPrivacyCollectedDataTypes'));
    expect(releasing, contains('the lookup adds no data type'));
  });

  // MainActivity's decisions live in IntakeRules.kt, where the JVM unit
  // tests (android/app/src/test, run by mobile-build.yml) exercise them for
  // real; the pins below hold MainActivity's wiring of them, on its code
  // with the comments stripped and whitespace collapsed (so neither a
  // commented-out line nor a reflow satisfies them).

  // A share is delivered once. After Android stops the process, reopening
  // the app from Recents or the icon recreates MainActivity with the
  // intent that first started its task (and the sender's grant), and
  // receive_sharing_intent reads activity.intent as a new share while
  // super.onCreate attaches it: a deleted meal came back, a not-food photo
  // went to the AI again. A recreated activity (saved state) or a launch
  // from Recents therefore hands the plugins an empty intent — no copy —
  // which also keeps a bitewise://setup link from reopening its dialog.
  // New shares still arrive through onNewIntent, unchanged.
  test('a recreated MainActivity never re-delivers its launch share', () {
    final code = _kotlinCode(_mainActivity());
    final create = _kotlinFunction(code, 'override fun onCreate(');
    expect(
        create,
        contains('val replay = IntakeRules.isRedelivery(savedInstanceState '
            '!= null, intent?.flags ?: 0) if (replay) { intent?.let { '
            'setIntent(emptyShare(it)) } } else { intent?.let { '
            'setIntent(withSafeShares(it)) } } super.onCreate('
            'savedInstanceState)'),
        reason: 'replay → the empty intent, else the safe copies, both '
            'before the plugins read it in super.onCreate');
    expect(_kotlinFunction(code, 'override fun onNewIntent('),
        '{ super.onNewIntent(withSafeShares(intent)) }');
    final rules = _kotlinCode(_intakeRules());
    expect(
        rules,
        contains('fun isRedelivery(hasSavedState: Boolean, flags: Int): '
            'Boolean = hasSavedState || (flags and '
            'Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0'));
    _expectJvmTests(['isRedelivery']);
  });

  // Chopstats is a target in its own sharesheet: Today's day image and the
  // Export file go out through share_plus's FileProvider. Picked there,
  // the report image would come back in as a meal photo and go to the AI.
  // Share intake leaves out every stream from that provider; with nothing
  // left, the share reaches no plugin.
  test("share intake leaves out the app's own share-out files", () {
    final code = _kotlinCode(_mainActivity());
    final safe = _kotlinFunction(code, 'private fun withSafeShares(');
    expect(
        safe,
        contains('if (uri == null) return@forEachIndexed if '
            '(IntakeRules.isOwnShareOut(uri.scheme, uri.authority, '
            'packageName)) return@forEachIndexed val name = shareName(uri) '
            '?: return@forEachIndexed'),
        reason: 'skipped before anything is read or copied');
    expect(safe, contains('if (copies.isEmpty()) return emptyShare(intent)'));
    final rules = _kotlinCode(_intakeRules());
    expect(rules,
        contains('const val SHARE_OUT_AUTHORITY_SUFFIX = ".flutter.share_provider"'));
    _expectJvmTests(['isOwnShareOut']);
    // share_plus's provider: the applicationId, which is the package.
    final sharePlus = _pluginRoot('share_plus');
    final pluginManifest =
        File('$sharePlus/android/src/main/AndroidManifest.xml')
            .readAsStringSync();
    expect(pluginManifest,
        contains(r'android:authorities="${applicationId}.flutter.share_provider"'));
  });

  // A file:// URI into the app's own data is never copied, shared or
  // picked (review 171, C5; review 2026-11-13 for picks).
  test("neither a share nor a pick copies the app's own files", () {
    final code = _kotlinCode(_mainActivity());
    expect(
        code,
        contains('private fun isOwnFile(uri: Uri): Boolean = "file".equals('
            'uri.scheme, ignoreCase = true) && IntakeRules.liesIn('
            'File(applicationInfo.dataDir), uri.path)'));
    expect(_kotlinFunction(code, 'private fun copyShare('),
        startsWith('{ if (isOwnFile(uri)) return null '));
    final picked = _kotlinFunction(code, 'private fun onPhotosPicked(');
    final own = picked.indexOf('if (isOwnFile(uri)) { failed++ return@forEach }');
    expect(own, greaterThan(0));
    expect(picked.indexOf('copyAtMost(uri, out, MAX_SHARE_BYTES)'),
        greaterThan(own));
    _expectJvmTests(['liesIn']);
  });

  // Log and Leftovers pick photos through the system Photo Picker, which
  // needs no permission (Play's Photo and Video FAQ asks apps to serve
  // users who grant no broad access). FlutterActivity is a plain Activity
  // with no registerForActivityResult, so MainActivity runs AndroidX's
  // contracts by hand: createIntent, startActivityForResult, parseResult.
  // Copies go to cacheDir/picked_photos/<uuid>/<name>, under the share cap.
  // One call at a time, answered exactly once (SingleCall): a reply sent
  // twice crashes, and a call never answered leaves every later pick busy.
  // The ModuleDependencies entry asks Play services for the backported
  // picker on Android 7-10 (minSdk 24); elsewhere the contract falls back
  // to ACTION_OPEN_DOCUMENT by itself.
  test('MainActivity serves pickImages through the system photo picker', () {
    final code = _kotlinCode(_mainActivity());
    expect(
        code,
        contains('"pickImages" -> pickImages( (call.argument<Any?>("max") as? '
            'Number)?.toInt() ?: 1, result, )'));
    expect(code, contains('const val PICKED_PHOTO_FOLDER = "picked_photos"'));
    expect(code, contains('const val PHOTO_PICK_REQUEST = 4208'));
    expect(code, contains('PHOTO_PICK_REQUEST -> onPhotosPicked(resultCode, data)'));

    final pick = _kotlinFunction(code, 'private fun pickImages(');
    expect(
        pick,
        startsWith('{ if (photoPicks.isOpen) { result.success('
            'photoPickAnswer("busy")) return } val max = '
            'IntakeRules.pickMax(requested, systemPickLimit()) '));
    expect(
        pick,
        contains('if (max == 1) ActivityResultContracts.PickVisualMedia()'
            '.createIntent(this, request) else ActivityResultContracts'
            '.PickMultipleVisualMedia(max).createIntent(this, request)'));
    expect(
        pick,
        contains('PickVisualMediaRequest(ActivityResultContracts'
            '.PickVisualMedia.ImageOnly)'));
    expect(
        pick,
        contains('} catch (e: Exception) { result.success('
            'photoPickAnswer("unavailable")) return } val call = '
            'photoPicks.open { result.success(it) } ?: return '
            'result.success(photoPickAnswer("busy")) photoPickCall = call '
            'photoPickMax = max try { startActivityForResult(intent, '
            'PHOTO_PICK_REQUEST) } catch (e: Exception) { '
            'photoPicks.answer(call, photoPickAnswer("unavailable")) } }'));
    expect(
        _kotlinFunction(code, 'private fun systemPickLimit('),
        isEmpty,
        reason: 'an expression body, pinned below');
    expect(
        code,
        contains('private fun systemPickLimit(): Int? = if '
            '(Build.VERSION.SDK_INT >= 33 || (Build.VERSION.SDK_INT >= 30 && '
            'SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2) ) '
            'MediaStore.getPickImagesMaxLimit() else null'));

    final picked = _kotlinFunction(code, 'private fun onPhotosPicked(');
    expect(
        picked,
        startsWith('{ if (!photoPicks.isOpen) return val call = '
            'photoPickCall val max = photoPickMax '));
    expect(picked,
        contains('ActivityResultContracts.PickVisualMedia().parseResult('
            'resultCode, data)'));
    expect(picked,
        contains('ActivityResultContracts.PickMultipleVisualMedia(max)'
            '.parseResult(resultCode, data)'));
    expect(
        picked,
        contains('val uris = IntakeRules.firstPicks(picked, max) if '
            '(resultCode != Activity.RESULT_OK || uris.isEmpty()) { '
            'photoPicks.answer(call, photoPickAnswer("cancelled")) return }'));
    expect(
        picked,
        contains('val root = File(cacheDir, PICKED_PHOTO_FOLDER) '
            'IntakeRules.tidyPickFolders(root, System.currentTimeMillis())'));
    expect(picked, isNot(contains('deleteRecursively')),
        reason: 'only tidyPickFolders clears earlier picks');
    expect(picked, contains('copyAtMost(uri, out, MAX_SHARE_BYTES)'));
    expect(picked, contains('val dir = File(root, UUID.randomUUID().toString())'));
    expect(picked, contains('dateTaken(uri)?.let { item["dateTakenMs"] = it }'));
    expect(
        picked,
        contains('runOnUiThread { photoPicks.answer(call, photoPickAnswer('
            '"ok", items, tooBig, failed)) } }.start() }'));
    expect('.success('.allMatches(picked), isEmpty,
        reason: 'answers only through SingleCall, which answers once');
    expect('photoPicks.answer('.allMatches(picked), hasLength(2));
    expect(code, contains('MediaStore.MediaColumns.DATE_TAKEN'));
    _expectJvmTests(['pickMax', 'firstPicks', 'tidyPickFolders', 'SingleCall']);

    final gradle = File('${_appRoot().path}/android/app/build.gradle.kts')
        .readAsStringSync();
    final activity = RegExp(r'implementation\("androidx\.activity:activity-ktx:'
            r'(\d+)\.(\d+)\.(\d+)"\)')
        .firstMatch(gradle);
    expect(activity, isNotNull, reason: 'androidx.activity is not declared');
    final major = int.parse(activity!.group(1)!);
    final minor = int.parse(activity.group(2)!);
    expect(major > 1 || (major == 1 && minor >= 7), isTrue,
        reason: 'the picker contracts need androidx.activity 1.7.0 or later');

    final manifest = _manifest();
    expect(RegExp(r'<manifest\b[^>]*>').firstMatch(manifest)?.group(0),
        contains('xmlns:tools="http://schemas.android.com/tools"'));
    final service = RegExp(
            r'<service\s+android:name="com\.google\.android\.gms\.metadata\.'
            r'ModuleDependencies"(.*?)</service>',
            dotAll: true)
        .firstMatch(_uncommented(manifest))
        ?.group(1);
    expect(service, isNotNull, reason: 'the picker backport entry is missing');
    expect(service, contains('android:enabled="false"'));
    expect(service, contains('android:exported="false"'));
    expect(service, contains('tools:ignore="MissingClass"'));
    expect(service, contains('<action android:name='
        '"com.google.android.gms.metadata.MODULE_DEPENDENCIES"'));
    expect(service, contains('<meta-data android:name='
        '"photopicker_activity:0:required" android:value=""'));
  });

  // Export › Save to device: a stock Pixel's sharesheet has no "save to
  // Files", so the export is written where the user picks with the
  // Storage Access Framework (no permission). The method only ever copies
  // a regular file whose real path lies in the app's cache, where the
  // export is written: never the database or anything else the app keeps.
  // The new document is opened only in a truncating mode, and a failed
  // copy removes it. If Android recreates the activity while the screen is
  // up, the source survives in the saved state, so the user's pick still
  // gets the file (or, with no source, the empty document is removed).
  test('MainActivity serves saveFile, from the cache only', () {
    final code = _kotlinCode(_mainActivity());
    expect(
        code,
        contains('"saveFile" -> saveFile( call.argument<Any?>("path") as? '
            'String, call.argument<Any?>("name") as? String, '
            'call.argument<Any?>("mime") as? String, result, )'));
    expect(code, contains('const val SAVE_REQUEST = 4209'));
    expect(code, contains('SAVE_REQUEST -> onSaveTargetPicked(resultCode, data)'));
    expect(
        code,
        contains('private fun cachedFile(path: String?): File? = '
            'IntakeRules.regularFileIn(cacheDir, path)'));
    final save = _kotlinFunction(code, 'private fun saveFile(');
    expect(
        save,
        startsWith('{ if (saves.isOpen) { result.success(saveAnswer("busy")) '
            'return } val source = cachedFile(path) if (source == null) { '
            'result.success(saveAnswer("failed")) return } val intent = '
            'Intent(Intent.ACTION_CREATE_DOCUMENT).apply { addCategory('
            'Intent.CATEGORY_OPENABLE) '));
    expect(save, contains('putExtra(Intent.EXTRA_TITLE, baseName(name) ?: source.name)'));
    expect(
        save,
        contains('val call = saves.open { result.success(it) } ?: return '
            'result.success(saveAnswer("busy")) saveCall = call '
            'pendingSaveSource = source try { startActivityForResult(intent, '
            'SAVE_REQUEST) } catch (e: Exception) { pendingSaveSource = null '
            'saves.answer(call, saveAnswer("unavailable")) } }'));

    final saved = _kotlinFunction(code, 'private fun onSaveTargetPicked(');
    expect(
        saved,
        startsWith('{ val call = if (saves.isOpen) saveCall else null val uri '
            '= data?.data val source = pendingSaveSource pendingSaveSource = '
            'null val step = IntakeRules.saveStep(resultCode == '
            'Activity.RESULT_OK, uri != null, source != null) if (step == '
            'IntakeRules.SaveStep.CANCEL || uri == null) { call?.let { '
            'saves.answer(it, saveAnswer("cancelled")) } return } if (step == '
            'IntakeRules.SaveStep.DISCARD || source == null) { '
            'discardDocument(uri) call?.let { saves.answer(it, '
            'saveAnswer("failed")) } return } Thread { val ok = try { val '
            'file = cachedFile(source.path) ?: throw IllegalStateException() '
            'val out = IntakeRules.firstStream(IntakeRules.SAVE_MODES) { '
            'contentResolver.openOutputStream(uri, it) } out?.use { o -> '
            'file.inputStream().use { it.copyTo(o, 64 * 1024) } } != null } '
            'catch (e: Exception) { false } if (!ok) discardDocument(uri) '
            'runOnUiThread { call?.let { saves.answer(it, if (ok) '
            'saveAnswer("ok") else saveAnswer("failed")) } } }.start() }'));
    expect('.success('.allMatches(saved), isEmpty,
        reason: 'answers only through SingleCall, which answers once');
    expect(code, isNot(contains('openOutputStream(uri, "w")')),
        reason: 'plain "w" may leave stale bytes; SAVE_MODES only');
    expect(_kotlinFunction(code, 'private fun discardDocument('),
        contains('DocumentsContract.deleteDocument(contentResolver, uri)'));
    // The pending source outlives a recreated activity.
    expect(_kotlinFunction(code, 'override fun onSaveInstanceState('),
        '{ super.onSaveInstanceState(outState) pendingSaveSource?.let { '
        'outState.putString(STATE_SAVE_SOURCE, it.path) } }');
    final create = _kotlinFunction(code, 'override fun onCreate(');
    expect(
        create,
        endsWith('super.onCreate(savedInstanceState) pendingSaveSource = '
            'cachedFile(savedInstanceState?.getString(STATE_SAVE_SOURCE)) }'),
        reason: 'restored through the same cache check');
    _expectJvmTests(
        ['regularFileIn', 'saveStep', 'SAVE_MODES', 'firstStream', 'SingleCall']);
  });

  // Settings' notifications-off remedy lands on the app's own
  // notification page (API 26+), not App info two taps away; App info
  // stays the fallback. True only when a page actually opened. The
  // background lane calls it and falls back to openAppSettings when it is
  // not implemented.
  test('MainActivity serves openNotificationSettings', () {
    final code = _kotlinCode(_mainActivity());
    final channel = RegExp(
            r'MethodChannel\(flutterEngine\.dartExecutor\.binaryMessenger, '
            r'CHANNEL\)(.*?)\}\s*\}',
            dotAll: true)
        .firstMatch(code)
        ?.group(1);
    expect(channel, contains('"openNotificationSettings" -> '
        'result.success(openNotificationSettings())'));
    expect(code, contains('const val CHANNEL = "dev.calorietracker/background"'));
    expect(
        _kotlinFunction(code, 'private fun openNotificationSettings('),
        '{ val pages = mutableListOf<Intent>() if (Build.VERSION.SDK_INT >= '
        'Build.VERSION_CODES.O) { pages.add( Intent('
        'Settings.ACTION_APP_NOTIFICATION_SETTINGS) .putExtra('
        'Settings.EXTRA_APP_PACKAGE, packageName), ) } pages.add( Intent('
        'Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts('
        '"package", packageName, null)), ) return IntakeRules.openFirst(pages) '
        '{ startActivity(it) } }');
    _expectJvmTests(['openFirst']);
  });

  // The JVM unit tests run on CI (mobile-build.yml), and the built APK's
  // permissions are checked there against an allowlist: the merged
  // manifest, which this file cannot see, is what Play reviews. Every
  // permission the main manifest declares must be on that list, so a new
  // one needs a deliberate edit in both places.
  test('CI runs the JVM unit tests and checks the APK permissions', () {
    final root = _appRoot().parent.path;
    final workflow =
        File('$root/.github/workflows/mobile-build.yml').readAsStringSync();
    expect(workflow, contains('./gradlew :app:testDebugUnitTest'));
    expect(workflow, contains('flutter build apk --release'));
    expect(workflow, contains('dump permissions'));
    final allowed = RegExp(r'^\s+(android\.permission\.[A-Z_]+|'
            r'dev\.calorietracker\.calorie_tracker\.[A-Z_]+)\s*$',
            multiLine: true)
        .allMatches(workflow)
        .map((m) => m.group(1)!)
        .toSet();
    expect(allowed, containsAll(_declared(_manifest())));
    for (final banned in [
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.SCHEDULE_EXACT_ALARM',
      'android.permission.USE_EXACT_ALARM',
    ]) {
      expect(allowed, isNot(contains(banned)));
    }
    final gradle = File('${_appRoot().path}/android/app/build.gradle.kts')
        .readAsStringSync();
    expect(gradle, contains('testImplementation("junit:junit:'));
  });

  // The daily summary is armed with the OS on Android too (background
  // lane): flutter_local_notifications' zonedSchedule posts it from
  // ScheduledNotificationReceiver, and alarms die at shutdown, so the boot
  // receiver re-arms them after a reboot or an app update. Inexact only
  // (AndroidScheduleMode.inexactAllowWhileIdle): no exact-alarm permission,
  // which Play reviews.
  test("flutter_local_notifications' scheduled-notification receivers are "
      'declared, and no exact-alarm permission', () {
    final manifest = _uncommented(_manifest());
    final application = RegExp(r'<application\b.*?</application>',
            dotAll: true)
        .firstMatch(manifest)
        ?.group(0);
    expect(application, isNotNull);
    const package = 'com.dexterous.flutterlocalnotifications';
    expect(
        RegExp('<receiver\\s+android:exported="false"\\s+'
                'android:name="$package\\.ScheduledNotificationReceiver"\\s*/>')
            .hasMatch(application!),
        isTrue,
        reason: 'ScheduledNotificationReceiver missing');
    final boot = RegExp(
            '<receiver\\s+android:exported="false"\\s+'
            'android:name="$package\\.ScheduledNotificationBootReceiver"\\s*>'
            '(.*?)</receiver>',
            dotAll: true)
        .firstMatch(application)
        ?.group(1);
    expect(boot, isNotNull, reason: 'ScheduledNotificationBootReceiver missing');
    expect(
        RegExp(r'<action android:name="([^"]+)"\s*/>')
            .allMatches(boot!)
            .map((m) => m.group(1))
            .toSet(),
        {
          'android.intent.action.BOOT_COMPLETED',
          'android.intent.action.MY_PACKAGE_REPLACED',
          'android.intent.action.QUICKBOOT_POWERON',
          'com.htc.intent.action.QUICKBOOT_POWERON',
        });
    expect(_declared(manifest), contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    for (final exact in ['SCHEDULE_EXACT_ALARM', 'USE_EXACT_ALARM']) {
      expect(manifest, isNot(contains(exact)), reason: exact);
    }
    // The classes exist in the plugin version pub resolved.
    final sources = '${_pluginRoot('flutter_local_notifications')}/android/'
        'src/main/java/com/dexterous/flutterlocalnotifications';
    for (final receiver in [
      'ScheduledNotificationReceiver',
      'ScheduledNotificationBootReceiver',
    ]) {
      expect(File('$sources/$receiver.java').existsSync(), isTrue,
          reason: receiver);
    }
  });

  // WorkManager's library manifest brings FOREGROUND_SERVICE and its
  // SystemForegroundService (no type), which it only uses for expedited
  // work on Android 11 and lower or for setForeground. The app registers
  // one periodic task and nothing else, so both are stripped from the
  // merged manifest. Expedited or one-off work would need them back.
  // hasFragileUserData: on Android 10+ the uninstall dialog offers to keep
  // the app's data, and the meal log lives only on the phone. Should the
  // kept key store lose its Keystore key, AndroidSecureKeyStore turns it
  // into "no key" (android_key_store_test).
  test('the manifest strips WorkManager\'s foreground service and keeps '
      'data on uninstall when asked', () {
    final manifest = _manifest();
    final permissions = _permissions(manifest);
    expect(permissions['android.permission.FOREGROUND_SERVICE'], isTrue,
        reason: 'FOREGROUND_SERVICE must be a tools:node="remove" entry');
    expect(_declared(manifest),
        isNot(contains('android.permission.FOREGROUND_SERVICE')));
    expect(
        RegExp(r'<service\s+android:name="androidx\.work\.impl\.foreground\.'
                r'SystemForegroundService"\s+tools:node="remove"\s*/>')
            .hasMatch(_uncommented(manifest)),
        isTrue,
        reason: 'SystemForegroundService is not removed');
    final application = RegExp(r'<application\b[^>]*>')
        .firstMatch(_uncommented(manifest))
        ?.group(0);
    expect(application, contains('android:hasFragileUserData="true"'));

    // Nothing in Dart asks WorkManager for expedited or one-off work,
    // which on Android 11 and lower runs as that foreground service.
    final dart = Directory('${_appRoot().path}/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in dart) {
      final source = file.readAsStringSync();
      for (final call in [
        'registerOneOffTask',
        'outOfQuotaPolicy',
        'OutOfQuotaPolicy',
      ]) {
        expect(source, isNot(contains(call)),
            reason: '${file.path} uses $call: put WorkManager\'s '
                'foreground service back first');
      }
    }
  });

  // Owner decision 2026-11-13: the package stays, and the upload key the
  // GitHub APKs are signed with becomes Play's app-signing key. Both are
  // permanent once the first bundle is uploaded: a new package is a new
  // app on Play, and a phone can only update between builds of one
  // package and one signer (the log lives only on the phone, so an
  // uninstall loses it).
  test('the Android package is permanent', () {
    final gradle =
        File('${_appRoot().path}/android/app/build.gradle.kts')
            .readAsStringSync();
    const package = 'dev.calorietracker.calorie_tracker';
    expect(gradle, contains('applicationId = "$package"'));
    expect(gradle, contains('namespace = "$package"'));
    expect(gradle, isNot(contains('applicationIdSuffix')));
    for (final invite in [
      'TODO: Specify your own unique Application ID',
      'You can update the following values to match your application needs',
    ]) {
      expect(gradle, isNot(contains(invite)),
          reason: 'the template line invites a change that would orphan '
              'every installed copy');
    }
    final note = RegExp(r'\n(\s*//[^\n]*\n)+\s*applicationId = ')
        .firstMatch(gradle)
        ?.group(0);
    expect(note, contains('never change applicationId'),
        reason: 'the note above applicationId says it is permanent');
    expect(_mainActivity(), startsWith('package $package\n'));
  });
}
