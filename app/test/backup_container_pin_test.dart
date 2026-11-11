// The iCloud container id is spelled the same everywhere (1.7.0 iCloud
// Backup): Dart's kICloudContainerId, CloudBackupPlugin.swift, the Runner
// entitlements and Info.plist's NSUbiquitousContainers — a one-letter
// difference and the app silently has no container. The ShareExtension
// never gets iCloud, and the Info.plist block is keyed by the literal id
// (iOS does not expand $(...) there).
import 'dart:io';

import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:flutter_test/flutter_test.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

/// The `<string>`s of the array under [key] in a plist's XML.
List<String> _array(String plist, String key) {
  final m = RegExp('<key>${RegExp.escape(key)}</key>\\s*<array>(.*?)</array>',
          dotAll: true)
      .firstMatch(plist);
  if (m == null) return const [];
  return [
    for (final s in RegExp('<string>([^<]*)</string>').allMatches(m.group(1)!))
      s.group(1)!,
  ];
}

void main() {
  final ios = '${_appRoot().path}/ios';
  final runnerEnt = File('$ios/Runner/Runner.entitlements').readAsStringSync();
  final shareEnt =
      File('$ios/ShareExtension/ShareExtension.entitlements').readAsStringSync();
  final info = File('$ios/Runner/Info.plist').readAsStringSync();
  final swift =
      File('$ios/Runner/CloudBackupPlugin.swift').readAsStringSync();

  test('Swift names the container Dart names', () {
    expect(swift,
        contains('static let containerIdentifier = "$kICloudContainerId"'));
  });

  test('Runner is entitled to exactly that container, for iCloud Documents',
      () {
    expect(_array(runnerEnt, 'com.apple.developer.icloud-container-identifiers'),
        [kICloudContainerId]);
    expect(_array(runnerEnt, 'com.apple.developer.ubiquity-container-identifiers'),
        [kICloudContainerId]);
    expect(_array(runnerEnt, 'com.apple.developer.icloud-services'),
        ['CloudDocuments']);
    // Xcode picks the environment from the signing; a hard-coded one
    // breaks either development or distribution.
    expect(runnerEnt, isNot(contains('icloud-container-environment')));
    // The app group is still there (the share extension needs it).
    expect(_array(runnerEnt, 'com.apple.security.application-groups'),
        ['group.dev.calorietracker.calorieTracker']);
  });

  test('the ShareExtension never gets iCloud', () {
    expect(shareEnt.toLowerCase(), isNot(contains('icloud')));
    expect(shareEnt, isNot(contains('ubiquity')));
  });

  test('Files shows the folder as Chopstats, keyed by the literal id', () {
    final block = RegExp(
            '<key>NSUbiquitousContainers</key>\\s*<dict>\\s*'
            '<key>([^<]*)</key>\\s*<dict>(.*?)</dict>\\s*</dict>',
            dotAll: true)
        .firstMatch(info);
    expect(block, isNotNull);
    expect(block!.group(1), kICloudContainerId);
    expect(block.group(1), isNot(contains(r'$(')));
    final body = block.group(2)!;
    expect(body,
        matches(RegExp(r'<key>NSUbiquitousContainerIsDocumentScopePublic</key>\s*<true/>')));
    expect(body,
        matches(RegExp(r'<key>NSUbiquitousContainerName</key>\s*<string>Chopstats</string>')));
    expect(body,
        matches(RegExp(r'<key>NSUbiquitousContainerSupportedFolderLevels</key>\s*<string>One</string>')));
  });
}
