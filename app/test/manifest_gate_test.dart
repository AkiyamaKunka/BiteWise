import 'dart:io';

import 'package:calorie_tracker/services/analyzer/platform_decode.dart'
    show imageIOChannelName;
import 'package:calorie_tracker/services/local_store.dart'
    show localStoreDirName;
import 'package:calorie_tracker/services/photo/background_time.dart'
    show backgroundTimeChannelName;
import 'package:calorie_tracker/services/photo/photo_changes.dart'
    show photoChangesChannelName;
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
      'transfer, and nothing else', () {
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
}
