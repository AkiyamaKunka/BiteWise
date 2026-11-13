// iCloud Backup's questions (the notice, a restore offer) are asked by the
// app shell, only over itself with nothing on top. Since 6d10515 an open
// restore offer holds every automatic photo until it is answered, so one
// raised while a screen is pushed (the add flow opened during the launch's
// look for a backup, say) is asked as soon as the shell is back on top. It
// waited, unseen, until the offer changed or the user left the app and
// came back (review 1.7.1).
import 'dart:async';
import 'dart:io';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/services/backup/backup_coordinator.dart';
import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:calorie_tracker/services/backup/backup_prefs.dart';
import 'package:calorie_tracker/services/backup/cloud_backup_channel.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_cloud_transport.dart';
import 'fakes.dart';

final _en = AppLocalizationsEn();

void main() {
  late BackupCoordinator backup;

  setUp(() async {
    // The one-time notice answered already: no notice follows the offer.
    SharedPreferences.setMockInitialValues({BackupPrefs.kNoticeSeen: true});
    backup = BackupCoordinator(
        dao: FakeDao(),
        // Keeps every automatic run out of the test's fake async (the
        // coordinator stops at G7 when iCloud is unavailable).
        transport: FakeCloudTransport()..state = CloudState.unavailable,
        prefs: await SharedPreferences.getInstance(),
        tempDir: () async => Directory.systemTemp);
  });

  /// The shell on Today (a key, so no first-run landing on Settings), with
  /// [backup]; it starts the coordinator after the first frame.
  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomeShell(
        services: UiServices(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          executor: FakeExecutor(),
          settings: FakeSettings(apiKey: 'k'),
          picker: FakePicker(),
          requestPhotoPermission: () async => true,
          cloudBackup: backup,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  RestoreOfferPrompt offer() => RestoreOfferPrompt(
      BackupCandidate(
          kRecordsFileName,
          BackupHeader(
              kind: BackupKind.records,
              installId: 'fedcba9876543210fedcba9876543210',
              seq: 3,
              meals: 412,
              exportedAt: '2026-11-01T08:00:00.000Z')),
      0);

  final offerSheet = find.text(_en.backupRestoreTitle);

  testWidgets('a restore offer raised under a screen is asked once the '
      'screen is popped', (tester) async {
    await launch(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('a screen')))));
    await tester.pumpAndSettle();

    backup.prompt.value = offer();
    await tester.pumpAndSettle();
    expect(offerSheet, findsNothing, reason: 'never over a screen');
    expect(backup.holdsCatchUpNow, isTrue,
        reason: 'it holds the automatic photos while it waits');

    nav.pop();
    await tester.pumpAndSettle();
    expect(offerSheet, findsOneWidget,
        reason: 'asked as soon as the shell is back on top');
    expect(find.textContaining('412 meals'), findsOneWidget);

    await tester.tap(find.byKey(const Key('backupNotNow')));
    await tester.pumpAndSettle();
    expect(offerSheet, findsNothing);
    expect(backup.prompt.value, isNull);
    expect(backup.holdsCatchUpNow, isFalse);

    // Answered: another screen pushed and popped asks nothing.
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('a screen')))));
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    expect(offerSheet, findsNothing);
    await backup.stop();
  });

  testWidgets('one raised with nothing on top is asked at once, and only '
      'once', (tester) async {
    await launch(tester);
    backup.prompt.value = offer();
    await tester.pumpAndSettle();
    expect(offerSheet, findsOneWidget);
    // The sheet itself is a route over the shell; nothing asks twice.
    expect(find.byKey(const Key('backupNotNow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('backupNotNow')));
    await tester.pumpAndSettle();
    expect(offerSheet, findsNothing);
    await backup.stop();
  });
}
