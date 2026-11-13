// The size and date labels of Settings › Your Data (1.7.0): one size
// formula for the iCloud Backup status line and the clipboard import, and a
// backup's date as the LOCAL calendar day of its exported_at.
//
// A zone at UTC cannot tell a local day from a UTC day, so under TZ=UTC
// (CI, and how the UI tests run here) the 'off UTC' group is skipped and
// says so in the output. Run this file in a zone on each side of UTC too:
//   TZ=America/Chicago flutter test test/ui/backup_labels_test.dart
//   TZ=Asia/Shanghai flutter test test/ui/backup_labels_test.dart
import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:calorie_tracker/ui/app_formats.dart';
import 'package:calorie_tracker/ui/backup_sheets.dart';
import 'package:calorie_tracker/ui/screens/settings/data_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

BackupHeader _header({String? exportedAt, String? lastDate}) => BackupHeader(
    kind: BackupKind.records,
    installId: '0' * 32,
    seq: 1,
    meals: 1,
    exportedAt: exportedAt,
    lastDate: lastDate);

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
    ctx = c;
    return const SizedBox();
  })));
  return ctx;
}

/// An exported_at as backups write it (in UTC) whose LOCAL day in the zone
/// the tests run in is not its UTC day, with both days spelled out: 00:30Z
/// is still the day before west of UTC, 23:30Z already the day after east
/// of it. Null in a zone at UTC, where the two days are always one.
({String stamp, String localDay, String utcDay})? _stampOffItsUtcDay() {
  final west = DateTime.utc(2026, 3, 6, 0, 30);
  if (west.toLocal().day != west.day) {
    return (
      stamp: west.toIso8601String(),
      localDay: '2026-03-05',
      utcDay: '2026-03-06'
    );
  }
  final east = DateTime.utc(2026, 3, 5, 23, 30);
  if (east.toLocal().day != east.day) {
    return (
      stamp: east.toIso8601String(),
      localDay: '2026-03-06',
      utcDay: '2026-03-05'
    );
  }
  return null;
}

void main() {
  test('backupSizeLabel: whole KB rounded up under 1 MB, then MB to one '
      'decimal', () {
    expect(backupSizeLabel(0), '0 KB');
    expect(backupSizeLabel(1), '1 KB');
    expect(backupSizeLabel(1024), '1 KB');
    expect(backupSizeLabel(1025), '2 KB');
    expect(backupSizeLabel(1024 * 1024 - 1), '1024 KB');
    expect(backupSizeLabel(1024 * 1024), '1.0 MB');
    expect(backupSizeLabel(3 * 1024 * 1024 ~/ 2), '1.5 MB');
  });

  testWidgets('backupDateLabel: the day of exported_at, as shortDate shows '
      'it; else the raw last day', (tester) async {
    final ctx = await _pumpContext(tester);
    // A one-digit month and day (unpadded, shortDate hands the raw string
    // back). No offset: a local time, so the same day in every zone.
    final march5 = AppFormats.shortDate(ctx, '2026-03-05');
    expect(march5, isNot(contains('-')), reason: 'a real day, not raw text');
    expect(
        backupDateLabel(ctx, _header(exportedAt: '2026-03-05T12:00:00.000')),
        march5);
    expect(backupDateLabel(ctx, _header(lastDate: '2026-10-30')),
        '2026-10-30');
    expect(
        backupDateLabel(
            ctx, _header(exportedAt: 'not a time', lastDate: '2026-10-30')),
        '2026-10-30');
    expect(backupDateLabel(ctx, _header()), '');
  });

  final offUtc = _stampOffItsUtcDay();
  group('off UTC', () {
    testWidgets('backupDateLabel: a UTC exported_at shows its LOCAL day',
        (tester) async {
      final ctx = await _pumpContext(tester);
      final label = backupDateLabel(ctx, _header(exportedAt: offUtc!.stamp));
      expect(label, AppFormats.shortDate(ctx, offUtc.localDay));
      expect(label, isNot(AppFormats.shortDate(ctx, offUtc.utcDay)),
          reason: 'not the day the stamp has in UTC');
    });
  },
      skip: offUtc == null
          ? 'a zone at UTC cannot tell a local day from a UTC day; run '
              'this file with TZ=America/Chicago and TZ=Asia/Shanghai'
          : false);

  testWidgets('the clipboard import counts UTF-8 bytes, not characters',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 1,000 three-byte characters: 3,000 bytes, 3 KB (1 KB by length).
    final payload = '饭' * 1000;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': payload};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(children: [
      DataSection(dao: FakeDao(), onOpenPrivacyPolicy: () {}),
    ]))));
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('importFromClipboard')));
    await tester.pumpAndSettle();
    expect(
        tester.widget<Text>(find.byKey(const Key('importClipboardSize'))).data,
        'Read 3 KB from the clipboard');
  });
}
