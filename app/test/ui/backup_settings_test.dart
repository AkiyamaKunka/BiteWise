// Settings › Your Data with iCloud Backup (1.7.0): the switch and its
// status line, the rows each state calls for, the footer that names the
// Files app only once a backup landed, the turn-off choice, the notice,
// the restore offer, Android's footer, and Import › Choose File… (records
// before pictures; the picked copies deleted afterwards).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/backup/backup_coordinator.dart';
import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:calorie_tracker/services/backup/backup_prefs.dart';
import 'package:calorie_tracker/services/backup/cloud_backup_channel.dart';
import 'package:calorie_tracker/services/backup/file_pick_channel.dart';
import 'package:calorie_tracker/ui/backup_sheets.dart';
import 'package:calorie_tracker/ui/screens/settings/data_section.dart';
import 'package:calorie_tracker/ui/widgets/small_spinner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_theme_harness.dart';
import '../support/fake_cloud_transport.dart';
import 'fakes.dart';

const _other = 'fedcba9876543210fedcba9876543210';
final _en = AppLocalizationsEn();

class _Picker implements FilePicker {
  _Picker(this.paths);
  final List<String> paths;
  @override
  Future<PickedFiles> pickJsonFiles() async => PickedFiles(paths);
}

/// A pick that answers when the test says (Android answers only once the
/// picked files are copied).
class _SlowPicker implements FilePicker {
  _SlowPicker(this.answer);
  final Future<PickedFiles> answer;
  int calls = 0;
  @override
  Future<PickedFiles> pickJsonFiles() {
    calls++;
    return answer;
  }
}

void main() {
  late SharedPreferences prefs;
  late FakeCloudTransport cloud;
  late FakeDao dao;
  late BackupCoordinator backup;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    cloud = FakeCloudTransport()..state = CloudStateUnavailable.value;
    dao = FakeDao();
    backup = BackupCoordinator(
        dao: dao,
        transport: cloud,
        prefs: prefs,
        tempDir: () async => Directory.systemTemp);
  });

  Future<void> pump(WidgetTester tester,
      {BackupCoordinator? b,
      bool android = false,
      FilePicker? picker,
      String platform = 'ios'}) =>
      pumpApp(
          tester,
          Scaffold(
            body: ListView(children: [
              DataSection(
                dao: dao,
                onOpenPrivacyPolicy: () {},
                backup: b,
                androidBackupNote: android,
                filePicker: picker ?? _Picker(const []),
                platform: platform,
              ),
            ]),
          ),
          size: const Size(390, 1400));

  String footerOf(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.contains('API keys are never included'))
      .join();

  testWidgets('the switch shows the status line; nothing names Files before '
      'a backup landed', (tester) async {
    await pump(tester, b: backup);
    expect(find.byKey(const Key('backupSwitch')), findsOneWidget);
    expect(find.text(_en.backupStatusNotStarted), findsOneWidget);
    expect(footerOf(tester), contains(_en.backupICloudFooterBefore));
    expect(footerOf(tester), isNot(contains('Files')));

    backup.debugSetStatus(BackupStatus(BackupState.ok,
        lastOkAt: DateTime.now(), bytes: 3 * 1024 * 1024));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last backup'), findsOneWidget);
    expect(find.textContaining('3.0 MB'), findsOneWidget);
    expect(footerOf(tester), contains('Files app'));
    expect(find.byKey(const Key('backupNowRow')), findsOneWidget);
  });

  testWidgets('a backup that skipped months of pictures says so',
      (tester) async {
    await pump(tester, b: backup);
    backup.debugSetStatus(BackupStatus(BackupState.ok,
        lastOkAt: DateTime.now(), bytes: 1024, skippedMonths: 2));
    await tester.pumpAndSettle();
    expect(find.textContaining(_en.backupStatusSkippedMonths(2)),
        findsOneWidget);
    backup.debugSetStatus(BackupStatus(BackupState.ok,
        lastOkAt: DateTime.now(), bytes: 1024));
    await tester.pumpAndSettle();
    expect(find.textContaining('months of pictures'), findsNothing);
  });

  testWidgets('off, no account or iCloud unavailable: the footer says '
      'nothing is copied and points to an export, in English and Chinese',
      (tester) async {
    final zh = AppLocalizationsZh();
    for (final locale in const [Locale('en'), Locale('zh')]) {
      await pumpApp(
          tester,
          Scaffold(
            body: ListView(children: [
              DataSection(
                dao: dao,
                onOpenPrivacyPolicy: () {},
                backup: backup,
                filePicker: _Picker(const []),
              ),
            ]),
          ),
          locale: locale,
          size: const Size(390, 1400));
      final l = locale.languageCode == 'zh' ? zh : _en;
      String footer() => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s.contains(l.settingsDataFooter))
          .join();
      for (final state in const [
        BackupState.off,
        BackupState.noAccount,
        BackupState.unavailable,
      ]) {
        // A backup landed before: the footer still goes by the state.
        backup.debugSetStatus(
            BackupStatus(state, lastOkAt: DateTime.now(), bytes: 10));
        await tester.pumpAndSettle();
        expect(footer(), contains(l.backupICloudFooterOff),
            reason: '$locale $state');
        expect(footer(), isNot(contains(l.backupICloudFooterBefore)));
        expect(footer(), isNot(contains(l.backupICloudFooter)));
      }
      backup.debugSetStatus(BackupStatus(BackupState.ok,
          lastOkAt: DateTime.now(), bytes: 10));
      await tester.pumpAndSettle();
      expect(footer(), contains(l.backupICloudFooter), reason: '$locale ok');
    }
    expect(_en.backupICloudFooterOff, contains('export a file'));
    expect(zh.backupICloudFooterOff, contains('导出'));
  });

  testWidgets('no iCloud identity: the line asks to sign in AND to turn on '
      'iCloud Drive for Chopstats, in English and Chinese', (tester) async {
    // iOS gives no identity token when signed out and also while iCloud
    // Drive is off for the phone or for the app, without saying which
    // (CloudBackupPlugin.statusName): "sign in" alone tells a signed-in
    // user to do what they did.
    await pump(tester, b: backup);
    backup.debugSetStatus(const BackupStatus(BackupState.noAccount));
    await tester.pumpAndSettle();
    expect(find.text(_en.backupStatusNoAccount), findsOneWidget);
    expect(_en.backupStatusNoAccount,
        allOf(contains('Sign in to iCloud'),
            contains('turn on iCloud Drive for Chopstats')));
    expect(AppLocalizationsZh().backupStatusNoAccount,
        allOf(contains('登录 iCloud'), contains('为筷拍打开 iCloud 云盘')));
  });

  testWidgets('each state shows only its own rows', (tester) async {
    await pump(tester, b: backup);
    final other = BackupHeader(
        kind: BackupKind.records, installId: _other, seq: 3, meals: 40,
        exportedAt: '2026-11-01T08:00:00.000Z');
    final cases = <BackupState, Key>{
      BackupState.otherDevice: const Key('backupTakeOverRow'),
      BackupState.changedElsewhere: const Key('backupTakeOverRow'),
      BackupState.unknownFile: const Key('backupTakeOverRow'),
      BackupState.twoCopies: const Key('backupCombineRow'),
      BackupState.missing: const Key('backupAgainRow'),
      BackupState.shrink: const Key('backupAnywayRow'),
      BackupState.emptyLog: const Key('backupDeleteRow'),
    };
    const all = [
      Key('backupTakeOverRow'),
      Key('backupCombineRow'),
      Key('backupAgainRow'),
      Key('backupAnywayRow'),
      Key('backupDeleteRow'),
    ];
    for (final MapEntry(key: state, value: row) in cases.entries) {
      backup.debugSetStatus(BackupStatus(state, other: other, count: 40));
      await tester.pumpAndSettle();
      for (final k in all) {
        expect(find.byKey(k), k == row ? findsOneWidget : findsNothing,
            reason: '$state $k');
      }
    }
    // Off: no Back Up Now, no repair rows.
    backup.debugSetStatus(const BackupStatus(BackupState.off));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backupNowRow')), findsNothing);
    expect(find.text(_en.backupStatusOff), findsOneWidget);
    // A backup of another install: Restore From iCloud…
    backup.debugSetStatus(BackupStatus(BackupState.never,
        restorable: [BackupCandidate(kRecordsFileName, other)]));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backupRestoreRow')), findsOneWidget);
  });

  testWidgets('turning it off asks Keep / Delete / Cancel; Keep keeps the '
      'files', (tester) async {
    await prefs.setBool(BackupPrefs.kNoticeSeen, true);
    backup.debugSetStatus(
        BackupStatus(BackupState.ok, lastOkAt: DateTime.now(), bytes: 10));
    await pump(tester, b: backup);
    await tester.tap(find.byKey(const Key('backupSwitch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backupTurnOffKeep')), findsOneWidget);
    expect(find.byKey(const Key('backupTurnOffDelete')), findsOneWidget);
    await tester.tap(find.byKey(const Key('backupTurnOffCancel')));
    await tester.pumpAndSettle();
    expect(prefs.getBool(BackupPrefs.kEnabled), isNull, reason: 'Cancel');
    await tester.tap(find.byKey(const Key('backupSwitch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backupTurnOffKeep')));
    await tester.pumpAndSettle();
    expect(prefs.getBool(BackupPrefs.kEnabled), isFalse);
    expect(cloud.log, isEmpty);
    expect(find.text(_en.backupStatusOff), findsOneWidget);
  });

  testWidgets('switched off with this iPhone\'s backup still in iCloud: '
      'Delete iCloud Backup… is offered', (tester) async {
    await pump(tester, b: backup);
    backup.debugSetStatus(const BackupStatus(BackupState.off));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backupDeleteRow')), findsNothing,
        reason: 'nothing of this install\'s in iCloud');
    backup.debugSetStatus(
        const BackupStatus(BackupState.off, ownsFiles: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backupDeleteRow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('backupDeleteRow')));
    await tester.pumpAndSettle();
    expect(find.text(_en.backupDeleteTitle), findsOneWidget);
  });

  testWidgets('paused after a relaunch (no last backup time): the turn-off '
      'sheet still offers Delete It…', (tester) async {
    await prefs.setBool(BackupPrefs.kNoticeSeen, true);
    backup.debugSetStatus(
        const BackupStatus(BackupState.missing, ownsFiles: true));
    await pump(tester, b: backup);
    await tester.tap(find.byKey(const Key('backupSwitch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backupTurnOffDelete')), findsOneWidget);
  });

  testWidgets('the notice: Keep On records the answer', (tester) async {
    await pump(tester);
    final ctx = tester.element(find.byType(DataSection));
    final shown = showBackupNotice(ctx, backup);
    await tester.pumpAndSettle();
    expect(find.text(_en.backupNoticeTitle), findsOneWidget);
    expect(find.textContaining('API keys are never included'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backupNoticeKeep')));
    await tester.pumpAndSettle();
    await shown;
    expect(prefs.getBool(BackupPrefs.kNoticeSeen), isTrue);
    expect(prefs.getBool(BackupPrefs.kEnabled), isTrue);
  });

  testWidgets('the restore offer shows the counts and warns about a merge',
      (tester) async {
    await pump(tester);
    final ctx = tester.element(find.byType(DataSection));
    final h = BackupHeader(
        kind: BackupKind.records, installId: _other, seq: 3, meals: 412,
        exportedAt: '2026-11-01T08:00:00.000Z');
    final shown = showRestoreOffer(
        ctx, backup, BackupCandidate(kRecordsFileName, h), 5);
    await tester.pumpAndSettle();
    expect(find.textContaining('412 meals'), findsOneWidget);
    expect(find.textContaining('already has 5 meals'), findsOneWidget);
    expect(find.textContaining(_en.backupRestoreNotIncluded), findsOneWidget);
    expect(find.textContaining(_en.backupRestoreTakesOver), findsOneWidget,
        reason: 'no backup of its own yet: restoring takes this one over');
    expect(find.byKey(const Key('backupRestore')), findsOneWidget);
    expect(find.byKey(const Key('backupStartFresh')), findsOneWidget);
    await tester.tap(find.byKey(const Key('backupNotNow')));
    await tester.pumpAndSettle();
    await shown;
    expect(prefs.getStringList(BackupPrefs.kOffersAnswered), [_other]);
  });

  testWidgets('the restore offer says nothing about taking over when this '
      'iPhone already has its own backup', (tester) async {
    await prefs.setInt(BackupPrefs.kLastSeq, 4);
    await pump(tester);
    final ctx = tester.element(find.byType(DataSection));
    final h = BackupHeader(
        kind: BackupKind.records, installId: _other, seq: 3, meals: 2,
        exportedAt: '2026-11-01T08:00:00.000Z');
    unawaited(showRestoreOffer(
        ctx, backup, BackupCandidate('Chopstats Backup 2.json', h), 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 meals'), findsOneWidget);
    expect(find.textContaining(_en.backupRestoreTakesOver), findsNothing);
    await tester.tap(find.byKey(const Key('backupNotNow')));
    await tester.pumpAndSettle();
  });

  testWidgets('with iCloud Backup off, the restore offer says nothing about '
      'taking the backup over', (tester) async {
    // Nothing would write over it, and its iPhone goes on backing up.
    await prefs.setBool(BackupPrefs.kNoticeSeen, true);
    await prefs.setBool(BackupPrefs.kEnabled, false);
    await pump(tester);
    final ctx = tester.element(find.byType(DataSection));
    final h = BackupHeader(
        kind: BackupKind.records, installId: _other, seq: 3, meals: 2,
        exportedAt: '2026-11-01T08:00:00.000Z');
    unawaited(showRestoreOffer(
        ctx, backup, BackupCandidate(kRecordsFileName, h), 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 meals'), findsOneWidget);
    expect(find.textContaining(_en.backupRestoreTakesOver), findsNothing);
    await tester.tap(find.byKey(const Key('backupNotNow')));
    await tester.pumpAndSettle();
  });

  testWidgets('Android: no iCloud rows, its own footer', (tester) async {
    await pump(tester, android: true);
    expect(find.byKey(const Key('backupSwitch')), findsNothing);
    expect(find.text(_en.backupAndroidFooter), findsOneWidget);
  });

  testWidgets('Choose File… imports records before pictures and deletes '
      'the copies', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ct_pick');
    addTearDown(() => dir.deleteSync(recursive: true));
    String file(String name, BackupKind kind, {String? month}) {
      final h = BackupHeader(
          kind: kind, installId: _other, seq: 1, month: month);
      final tables = kind == BackupKind.pictures
          ? '{"meal_thumbs":[]}'
          : '{"meals":[]}';
      final f = File('${dir.path}/$name')
        ..writeAsStringSync('${h.envelopePrefix(DateTime.utc(2026))}$tables}');
      return f.path;
    }

    final paths = [
      file('b.json', BackupKind.pictures, month: '2026-11'),
      file('a.json', BackupKind.pictures, month: '2026-10'),
      file('r.json', BackupKind.records),
    ];
    await pump(tester, picker: _Picker(paths));
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('importChooseFile')));
    // Real file I/O: each await needs the real event loop, then a pump for
    // the continuation in the test's zone.
    for (var i = 0; i < 40 && dao.imported.length < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final kinds = [
      for (final j in dao.imported)
        ((jsonDecode(j) as Map)['backup'] as Map)['month'] ??
            ((jsonDecode(j) as Map)['backup'] as Map)['kind'],
    ];
    expect(kinds, ['records', '2026-10', '2026-11']);
    for (final p in paths) {
      expect(File(p).existsSync(), isFalse, reason: 'copies are deleted');
    }
  });

  testWidgets('Android Choose File…: a file that could not be read is never '
      'called over 100 MB', (tester) async {
    // MainActivity.kt answers how many picks were too big and how many
    // could not be copied at all (a Drive file offline, a full disk).
    Object? answer;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel(filesChannelName),
        (call) async => call.method == 'pickFiles' ? answer : null);
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel(filesChannelName), null));
    await pump(tester, picker: const PlatformFilePicker());

    Future<String> pick(Map<String, Object?> reply) async {
      answer = reply;
      await tester.tap(find.byKey(const Key('importButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('importChooseFile')));
      await tester.pumpAndSettle();
      final shown = tester
          .widgetList<Text>(find.descendant(
              of: find.byType(SnackBar), matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .join();
      ScaffoldMessenger.of(tester.element(find.byType(DataSection)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
      return shown;
    }

    final failed = await pick(
        {'status': 'ok', 'paths': <String>[], 'tooBig': 0, 'failed': 1});
    expect(failed, _en.importPickUnavailable);
    final both = await pick(
        {'status': 'ok', 'paths': <String>[], 'tooBig': 1, 'failed': 1});
    expect(both, '${_en.importTooBig} ${_en.importPickUnavailable}');
  });

  testWidgets('Android Choose File…: Import is busy until the picked files '
      'are copied, so a second pick cannot empty the first one\'s copies',
      (tester) async {
    Future<void> chooseFile() async {
      await tester.tap(find.byKey(const Key('importButton')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('importChooseFile')));
      await tester.pump(const Duration(milliseconds: 500));
    }

    final copying = Completer<PickedFiles>();
    final picker = _SlowPicker(copying.future);
    await pump(tester, picker: picker, platform: 'android');
    await chooseFile();
    expect(picker.calls, 1);
    expect(find.byType(SmallSpinner), findsOneWidget);
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('importChooseFile')), findsNothing,
        reason: 'no second pick while the first one is copied');
    copying.complete(const PickedFiles([], cancelled: true));
    await tester.pumpAndSettle();
    expect(find.byType(SmallSpinner), findsNothing);

    // iOS answers only after its own picker's copy, and a picker swiped
    // away is reported not to answer on some iOS versions: the row stays
    // usable while it is up.
    final open = _SlowPicker(Completer<PickedFiles>().future);
    await pump(tester, picker: open);
    await chooseFile();
    expect(open.calls, 1);
    expect(find.byType(SmallSpinner), findsNothing);
  });

  test('a delete says done, done in part (try again), or not done', () {
    expect(backupDeleteMessage(_en, BackupDeleteResult.deleted),
        _en.backupDeleted);
    expect(backupDeleteMessage(_en, BackupDeleteResult.partial),
        allOf(_en.backupDeletePartial, contains('Try again')));
    expect(backupDeleteMessage(_en, BackupDeleteResult.failed),
        _en.backupActionFailed);
  });

  test('the import summary names pictures and what was left out', () {
    const s = ImportSummary({'meals': 2}, {},
        thumbsAdded: 2, mealsSkippedDeleted: 1);
    final text = importSummaryText(_en, s);
    expect(text, contains('Imported 2 meals'));
    expect(text, contains('Added 2 pictures.'));
    expect(text, contains('1 meal you deleted on this phone was left out.'));
    expect(importSummaryText(_en, const ImportSummary({}, {}, noMatchingMeals: true)),
        _en.importNoMatchingMeals);
    expect(
        combineImportSummaries(const [
          ImportSummary({'meals': 1}, {}),
          ImportSummary({}, {}, thumbsAdded: 3),
        ]).thumbsAdded,
        3);
  });
}

/// Keeps every automatic run out of the widget tests' fake async (the
/// coordinator stops at G7 when iCloud is unavailable).
abstract final class CloudStateUnavailable {
  static const value = CloudState.unavailable;
}
