/// The Android daily summary is an alarm the OS holds (ui/os_summary.dart,
/// ReportNotifier.scheduleDailyAt → zonedSchedule). flutter_local_notifications
/// delivers it through ScheduledNotificationReceiver, and re-arms it after
/// a reboot or an app update through ScheduledNotificationBootReceiver —
/// both of which the APP's manifest must declare (FLN 22 README,
/// 'AndroidManifest.xml setup'). Without them zonedSchedule succeeds and
/// the card never comes: a silent failure no unit test of the Dart side
/// can see. The native lane declares them (PR #62); this pins that the
/// branch that relies on them never ships without them.
///
/// Inexact only: no exact-alarm permission (Play policy for the
/// SCHEDULE_EXACT_ALARM / USE_EXACT_ALARM declarations).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _manifest() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return File('${dir.path}/android/app/src/main/AndroidManifest.xml')
      .readAsStringSync()
      // Comments may name what is not declared.
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
}

const _fln = 'com.dexterous.flutterlocalnotifications';

/// The `<receiver …>` element (through its end) whose name is [name].
String? _receiver(String manifest, String name) {
  final open = RegExp(
      r'<receiver\b[^>]*android:name="' + RegExp.escape(name) + r'"[^>]*?(/?)>',
      dotAll: true);
  final m = open.firstMatch(manifest);
  if (m == null) return null;
  if (m.group(1) == '/') return m.group(0);
  final end = manifest.indexOf('</receiver>', m.end);
  return end < 0 ? null : manifest.substring(m.start, end);
}

void main() {
  test('the receiver that delivers the summary alarm is declared, not '
      'exported', () {
    final r = _receiver(_manifest(), '$_fln.ScheduledNotificationReceiver');
    expect(r, isNotNull);
    expect(r, contains('android:exported="false"'));
  });

  test('the boot receiver re-arms it after a reboot and an app update', () {
    final m = _manifest();
    final r = _receiver(m, '$_fln.ScheduledNotificationBootReceiver');
    expect(r, isNotNull);
    expect(r, contains('android:exported="false"'));
    for (final action in const [
      'android.intent.action.BOOT_COMPLETED',
      'android.intent.action.MY_PACKAGE_REPLACED',
      'android.intent.action.QUICKBOOT_POWERON',
      'com.htc.intent.action.QUICKBOOT_POWERON',
    ]) {
      expect(r, contains('<action android:name="$action"'), reason: action);
    }
    expect(
        m,
        matches(RegExp(r'<uses-permission\s+android:name='
            r'"android\.permission\.RECEIVE_BOOT_COMPLETED"')));
  });

  test('no exact-alarm permission: the card is an inexact alarm', () {
    final m = _manifest();
    for (final p in const [
      'android.permission.SCHEDULE_EXACT_ALARM',
      'android.permission.USE_EXACT_ALARM',
    ]) {
      expect(m, isNot(contains('"$p"')), reason: p);
    }
  });
}
