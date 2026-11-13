// The size and date labels of Settings › Your Data (1.7.0): one size
// formula for the iCloud Backup status line and the clipboard import, and a
// backup's date as the LOCAL calendar day of its exported_at.
import 'package:calorie_tracker/core/coerce.dart' show isoDate;
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

  testWidgets('backupDateLabel: the local day of exported_at, as shortDate '
      'shows it; else the raw last day', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    // A one-digit month and day (unpadded, shortDate hands the raw string
    // back), and an offset that puts the instant on the next UTC day.
    final stamp = '${DateTime.now().year}-03-05T23:30:00.000-05:00';
    final want = AppFormats.shortDate(
        ctx, isoDate(DateTime.parse(stamp).toLocal()));
    expect(want, isNot(contains('-')), reason: 'a real day, not raw text');
    expect(backupDateLabel(ctx, _header(exportedAt: stamp)), want);
    expect(backupDateLabel(ctx, _header(lastDate: '2026-10-30')),
        '2026-10-30');
    expect(
        backupDateLabel(
            ctx, _header(exportedAt: 'not a time', lastDate: '2026-10-30')),
        '2026-10-30');
    expect(backupDateLabel(ctx, _header()), '');
  });

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
