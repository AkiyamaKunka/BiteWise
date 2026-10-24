// Native wiring gate for the Meta glasses bridge (feat/meta-dat
// prototype). Nothing in Dart can see a Swift file missing from Runner, an
// opt-out key dropped from Info.plist, or the SDK initialised at launch:
// the channel would just answer MissingPluginException, or Meta would
// quietly collect analytics. So the files themselves are pinned here.
import 'dart:io';

import 'package:calorie_tracker/services/glasses/meta_dat_channel.dart';
import 'package:flutter_test/flutter_test.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

String _read(String relative) =>
    File('${_appRoot().path}/$relative').readAsStringSync();

/// The body of a `project.pbxproj` object `ID /* comment */ = { isa = …`.
String _pbxObject(String pbxproj,
    {String id = '[0-9A-F]{24}', required String comment, required String isa}) {
  final match = RegExp(
    '\\n\\t\\t$id /\\* ${RegExp.escape(comment)} \\*/ = \\{\\s*isa = $isa;'
    '(.*?)\\n\\t\\t\\};',
    dotAll: true,
  ).firstMatch(pbxproj);
  expect(match, isNotNull, reason: 'project.pbxproj has no $isa "$comment"');
  return match!.group(1)!;
}

String _phase(String pbxproj, String target, String phase, String isa) {
  final id = RegExp('([0-9A-F]{24}) /\\* $phase \\*/')
      .firstMatch(
          _pbxObject(pbxproj, comment: target, isa: 'PBXNativeTarget'))
      ?.group(1);
  expect(id, isNotNull, reason: '$target has no $phase phase');
  return _pbxObject(pbxproj, id: id!, comment: phase, isa: isa);
}

void main() {
  late String swift;
  late String delegate;
  late String pbxproj;
  late String plist;

  setUpAll(() {
    swift = _read('ios/Runner/MetaDatPlugin.swift');
    delegate = _read('ios/Runner/AppDelegate.swift');
    pbxproj = _read('ios/Runner.xcodeproj/project.pbxproj');
    plist = _read('ios/Runner/Info.plist');
  });

  test('the Swift plugin serves the Dart channel name', () {
    expect(swift, contains('static let channelName = "$metaDatChannelName"'));
  });

  test('registered for the app engine only, never the headless one', () {
    final implicit = RegExp(
            r'func didInitializeImplicitFlutterEngine\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(implicit,
        contains('registerForegroundOnlyPlugins(with: engineBridge.pluginRegistry)'));
    final foregroundOnly = RegExp(
            r'static func registerForegroundOnlyPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(foregroundOnly, contains('MetaDatPlugin.register(with:'));
    // Not in the shared path both engines use, nor workmanager's callback.
    final shared = RegExp(r'static func registerAppPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(shared, isNot(contains('MetaDat')));
    final headless = RegExp(
            r'setPluginRegistrantCallback \{ registry in(.*?)\n    \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(1);
    expect(headless, isNot(contains('MetaDat')));
    expect(headless, isNot(contains('registerForegroundOnlyPlugins')));
  });

  test('the SDK is initialised only when Dart calls configure', () {
    final code = swift
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect('try Wearables.configure()'.allMatches(code), hasLength(1));
    final configure = RegExp(
            r'func configure\(\) throws -> \[String: Any\] \{.*?\n  \}',
            dotAll: true)
        .firstMatch(code)
        ?.group(0);
    expect(configure, contains('try Wearables.configure()'));
    expect(delegate, isNot(contains('Wearables')));
  });

  test('Mock Device Kit exists only in the Debug configuration', () {
    // Every mock reference sits inside #if METADAT_MOCK …
    final outside = swift.replaceAll(
        RegExp(r'#if METADAT_MOCK.*?#(else|endif)', dotAll: true), '');
    expect(outside, isNot(contains('MockDeviceKit')));
    expect(outside, isNot(contains('MWDATMockDevice')));
    // … and only Runner's Debug build defines it.
    final defines = RegExp(r'\n\t\t([0-9A-F]{24}) /\* (\w+) \*/ = \{\n'
            r'\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};', dotAll: true)
        .allMatches(pbxproj)
        .where((m) => m.group(3)!.contains('METADAT_MOCK'))
        .toList();
    expect(defines, hasLength(1));
    expect(defines.single.group(2), 'Debug');
    expect(defines.single.group(3),
        contains('PRODUCT_BUNDLE_IDENTIFIER = dev.calorietracker.calorieTracker;'));
  });

  test('the DAT package is pinned and linked into Runner only', () {
    final ref = _pbxObject(pbxproj,
        comment: 'XCRemoteSwiftPackageReference "meta-wearables-dat-ios"',
        isa: 'XCRemoteSwiftPackageReference');
    expect(ref,
        contains('repositoryURL = "https://github.com/facebook/meta-wearables-dat-ios";'));
    expect(ref, contains('kind = exactVersion;'));
    expect(ref, contains('version = 1.0.1;'));
    final runner =
        _pbxObject(pbxproj, comment: 'Runner', isa: 'PBXNativeTarget');
    final frameworks =
        _phase(pbxproj, 'Runner', 'Frameworks', 'PBXFrameworksBuildPhase');
    for (final product in [
      'MWDATCore',
      'MWDATCamera',
      'MWDATInputs',
      'MWDATMockDevice'
    ]) {
      expect(runner, contains('/* $product */'), reason: product);
      expect(frameworks, contains('/* $product in Frameworks */'),
          reason: product);
    }
    for (final other in ['ShareExtension', 'RunnerTests']) {
      expect(_pbxObject(pbxproj, comment: other, isa: 'PBXNativeTarget'),
          isNot(contains('MWDAT')),
          reason: '$other must not embed a second copy of the SDK');
    }
  });

  test('plugin in Runner, its XCTest in RunnerTests, neither elsewhere', () {
    expect(_phase(pbxproj, 'Runner', 'Sources', 'PBXSourcesBuildPhase'),
        contains('/* MetaDatPlugin.swift in Sources */'));
    expect(
        _phase(pbxproj, 'ShareExtension', 'Sources', 'PBXSourcesBuildPhase'),
        isNot(contains('MetaDat')));
    expect(_phase(pbxproj, 'RunnerTests', 'Sources', 'PBXSourcesBuildPhase'),
        contains('/* MetaDatTests.swift in Sources */'));
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('/* MetaDatPlugin.swift */'));
    expect(_pbxObject(pbxproj, comment: 'RunnerTests', isa: 'PBXGroup'),
        contains('/* MetaDatTests.swift */'));
  });

  test('iOS 17.2 floor for the app on this branch; the extension keeps 15',
      () {
    final targets = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);')
        .allMatches(pbxproj)
        .map((m) => m.group(1))
        .toList();
    // Three project-level configs (Runner and RunnerTests inherit them)
    // and the share extension's own three.
    expect(targets.where((t) => t == '17.2'), hasLength(3));
    expect(targets.where((t) => t == '15.0'), hasLength(3));
    for (final config in ['Debug', 'Release', 'Profile']) {
      final ext = RegExp(r'\n\t\t[0-9A-F]{24} /\* ' +
              config +
              r' \*/ = \{\n\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};',
              dotAll: true)
          .allMatches(pbxproj)
          .map((m) => m.group(1)!)
          .where((b) => b.contains('INFOPLIST_FILE = ShareExtension/Info.plist'))
          .single;
      expect(ext, contains('IPHONEOS_DEPLOYMENT_TARGET = 15.0;'));
    }
  });

  group('Info.plist', () {
    late String mwdat;
    setUpAll(() {
      mwdat = RegExp(r'<key>MWDAT</key>\s*<dict>(.*?)\n\t</dict>', dotAll: true)
              .firstMatch(plist)
              ?.group(1) ??
          '';
    });

    test("Meta's analytics and crash reporting are opted out", () {
      for (final key in ['Analytics', 'CrashReporting']) {
        expect(
            RegExp('<key>$key</key>\\s*<dict>\\s*<key>OptOut</key>\\s*<true/>')
                .hasMatch(mwdat),
            isTrue,
            reason: '$key OptOut must be true (DAT collects by default)');
      }
    });

    test('the callback scheme is ours, declared, and what Dart filters on',
        () {
      expect(mwdat,
          contains('<key>AppLinkURLScheme</key>\n\t\t<string>$metaDatCallbackScheme://</string>'));
      expect(plist, contains('<string>$metaDatCallbackScheme</string>'));
    });

    test('no identifier or token is committed: build settings only', () {
      String value(String key) =>
          RegExp('<key>$key</key>\\s*<string>([^<]*)</string>')
              .firstMatch(mwdat)
              ?.group(1) ??
          'missing';
      expect(value('MetaAppID'), r'$(META_APP_ID)');
      expect(value('ClientToken'), r'$(META_CLIENT_TOKEN)');
      expect(value('TeamID'), r'$(DEVELOPMENT_TEAM)');
      // The optional values live in an untracked xcconfig.
      expect(_read('ios/.gitignore'), contains('Flutter/MetaDat.xcconfig'));
      for (final xc in ['Debug', 'Release']) {
        expect(_read('ios/Flutter/$xc.xcconfig'),
            contains('#include? "MetaDat.xcconfig"'));
      }
    });

    test('Bluetooth LE and Classic links are declared; Wi-Fi is not', () {
      final modes = RegExp(r'<key>UIBackgroundModes</key>\s*<array>(.*?)</array>',
              dotAll: true)
          .firstMatch(plist)!
          .group(1)!;
      for (final mode in [
        'fetch',
        'bluetooth-central',
        'bluetooth-peripheral',
        'external-accessory'
      ]) {
        expect(modes, contains('<string>$mode</string>'));
      }
      expect(plist, contains('<string>com.meta.ar.wearable</string>'));
      // The Wi-Fi link needs Hotspot Configuration, which the owner's free
      // team cannot sign: no local-network prompt for nothing.
      expect(plist, isNot(contains('NSLocalNetworkUsageDescription')));
      expect(plist, isNot(contains('_bonjour._tcp')));
    });

    test('the Bluetooth prompt is worded in both languages', () {
      expect(
          RegExp(r'<key>NSBluetoothAlwaysUsageDescription</key>\s*<string>[^<]{20,}</string>')
              .hasMatch(plist),
          isTrue);
      expect(_read('ios/Runner/en.lproj/InfoPlist.strings'),
          contains('"NSBluetoothAlwaysUsageDescription"'));
      expect(_read('ios/Runner/zh-Hans.lproj/InfoPlist.strings'),
          contains('"NSBluetoothAlwaysUsageDescription" = "在眼镜拍摄模式中'));
    });
  });
}
