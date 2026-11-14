// Export › Save to device on Android (privacy lane item 3). Android's share
// sheet has no "Save to Files" (a stock Pixel offers Quick Share, Drive and
// Gmail), yet the Android footer tells people to export before changing
// phones. Export now offers Save to Device… first and Share… second on
// Android: the system's save screen through MainActivity's `saveFile` on
// dev.calorietracker/files ({path, name, mime} → {status}), and the temp
// export is deleted afterwards, whatever the status. A build without the
// method (MissingPluginException) shares instead, and offers Share only
// from then on. iPhone is unchanged.
import 'dart:io';

import 'package:calorie_tracker/services/backup/file_pick_channel.dart';
import 'package:calorie_tracker/services/backup/save_file_channel.dart';
import 'package:calorie_tracker/ui/screens/settings/data_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart' show pumpApp;
import 'fakes.dart';

class _Saver implements FileSaver {
  _Saver(this.status);
  SaveFileStatus status;
  final calls = <({String path, String name, String mime, bool existed})>[];

  @override
  Future<SaveFileStatus> saveFile(
      {required String path,
      required String name,
      required String mime}) async {
    calls.add(
        (path: path, name: name, mime: mime, existed: File(path).existsSync()));
    return status;
  }
}

class _NoPicker implements FilePicker {
  @override
  Future<PickedFiles> pickJsonFiles() async => const PickedFiles([]);
}

void main() {
  late Directory tmp;
  late _Saver saver;
  late List<({String path, bool existed})> shared;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ct_export_save');
    saver = _Saver(SaveFileStatus.ok);
    shared = [];
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester,
          {String platform = 'android', Locale locale = const Locale('en')}) =>
      pumpApp(
          tester,
          Scaffold(
            body: ListView(children: [
              DataSection(
                dao: FakeDao(),
                onOpenPrivacyPolicy: () {},
                platform: platform,
                androidBackupNote: platform == 'android',
                filePicker: _NoPicker(),
                fileSaver: saver,
                tempDir: () async => tmp,
                shareFile: (path, subject) async =>
                    shared.add((path: path, existed: File(path).existsSync())),
              ),
            ]),
          ),
          locale: locale,
          size: const Size(390, 1400));

  List<String> exportsLeft() => [
        for (final f in tmp.listSync().whereType<File>())
          if (isExportFileName(f.path.split('/').last)) f.path
      ];

  /// Runs [action] (a tap) where real time passes — the export is written
  /// with real file I/O — and waits, up to 3 s, until [done]; then a
  /// little longer for what follows it, and lets the frames run.
  Future<void> realTime(WidgetTester tester, Future<void> Function() action,
      bool Function() done) async {
    await tester.runAsync(() async {
      await action();
      final until = DateTime.now().add(const Duration(seconds: 3));
      while (!done() && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
  }

  /// The export file is written and no longer growing (Android then opens
  /// the sheet), or it was shared (iPhone, or a build without the save).
  int lastSize = -1, steady = 0;
  bool exportWritten() {
    if (shared.isNotEmpty) return true;
    final files = exportsLeft();
    if (files.isEmpty) return false;
    final size = File(files.single).lengthSync();
    steady = size > 0 && size == lastSize ? steady + 1 : 0;
    lastSize = size;
    return steady >= 3;
  }

  Future<void> tapExport(WidgetTester tester) {
    lastSize = -1;
    steady = 0;
    return realTime(
        tester,
        () => tester.tap(find.byKey(const Key('exportButton'))),
        exportWritten);
  }

  Future<void> choose(WidgetTester tester, String key) => realTime(
      tester,
      () => tester.tap(find.byKey(Key(key))),
      () => saver.calls.isNotEmpty || shared.isNotEmpty);

  testWidgets('Android: the sheet offers Save to Device… first, Share… '
      'second', (tester) async {
    await pump(tester);
    await tapExport(tester);
    final save = find.byKey(const Key('exportSaveToDevice'));
    final share = find.byKey(const Key('exportShare'));
    expect(save, findsOneWidget);
    expect(share, findsOneWidget);
    expect(tester.getTopLeft(save).dy, lessThan(tester.getTopLeft(share).dy));
    expect(find.text('Save to Device…'), findsOneWidget);
    expect(find.text('Share…'), findsOneWidget);
    // The file is written before the choice; Cancel deletes it again.
    expect(exportsLeft(), hasLength(1));
    await realTime(tester,
        () => tester.tap(find.byKey(const Key('exportCancel'))),
        () => exportsLeft().isEmpty);
    expect(saver.calls, isEmpty);
    expect(shared, isEmpty);
    expect(exportsLeft(), isEmpty);
  });

  testWidgets('Save to Device: the contract args, "Export saved.", and the '
      'temp export is gone', (tester) async {
    await pump(tester);
    await tapExport(tester);
    await choose(tester, 'exportSaveToDevice');
    final call = saver.calls.single;
    expect(call.existed, isTrue, reason: 'written before the save screen');
    expect(call.path, startsWith(tmp.path),
        reason: 'the cache folder the native side accepts');
    expect(call.name, matches(RegExp(r'^chopstats-\d{4}-\d\d-\d\d\.json$')));
    expect(call.path.endsWith('/${call.name}'), isTrue);
    expect(call.mime, 'application/json');
    expect(shared, isEmpty);
    expect(find.text('Export saved.'), findsOneWidget);
    expect(exportsLeft(), isEmpty);
  });

  for (final (status, en, zh) in [
    (SaveFileStatus.ok, 'Export saved.', '导出文件已保存。'),
    (SaveFileStatus.cancelled, null, null),
    (
      SaveFileStatus.busy,
      'Another file window is still open. Close it, then try again.',
      '另一个文件窗口还开着。关掉它再试一次。'
    ),
    (
      SaveFileStatus.failed,
      'The export could not be saved. Try Share… instead.',
      '导出文件没能保存。可以改用「分享…」。'
    ),
  ]) {
    for (final locale in const [Locale('en'), Locale('zh')]) {
      testWidgets('Save to Device ${status.name} (${locale.languageCode}): '
          '${en == null ? 'nothing said' : 'said'}, temp export deleted',
          (tester) async {
        saver.status = status;
        await pump(tester, locale: locale);
        await tapExport(tester);
        await choose(tester, 'exportSaveToDevice');
        expect(saver.calls, hasLength(1));
        expect(shared, isEmpty);
        expect(exportsLeft(), isEmpty);
        final line = locale.languageCode == 'zh' ? zh : en;
        if (line != null) {
          expect(find.text(line), findsOneWidget);
        } else {
          expect(find.byType(SnackBar), findsNothing);
        }
      });
    }
  }

  testWidgets('Save to Device on a build without the method: shares the '
      'file instead, then offers Share only', (tester) async {
    saver.status = SaveFileStatus.unavailable;
    await pump(tester);
    await tapExport(tester);
    await choose(tester, 'exportSaveToDevice');
    expect(saver.calls, hasLength(1));
    expect(shared.single.existed, isTrue,
        reason: 'the share target reads the file after this');
    expect(shared.single.path, saver.calls.single.path);

    // Next time: no sheet, straight to Share.
    shared.clear();
    await tapExport(tester);
    expect(find.byKey(const Key('exportSaveToDevice')), findsNothing);
    expect(shared, hasLength(1));
    expect(saver.calls, hasLength(1));
  });

  testWidgets('Share…: the share sheet gets the file, the saver is not '
      'called', (tester) async {
    await pump(tester);
    await tapExport(tester);
    await choose(tester, 'exportShare');
    expect(saver.calls, isEmpty);
    expect(shared.single.existed, isTrue);
    expect(shared.single.path.split('/').last,
        matches(RegExp(r'^chopstats-\d{4}-\d\d-\d\d\.json$')));
  });

  testWidgets('iPhone: unchanged — no sheet, straight to Share',
      (tester) async {
    await pump(tester, platform: 'ios');
    await tapExport(tester);
    expect(find.byKey(const Key('exportSaveToDevice')), findsNothing);
    expect(shared, hasLength(1));
    expect(saver.calls, isEmpty);
  });

  group('PlatformFileSaver (the channel contract)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel(filesChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<SaveFileStatus> save() => const PlatformFileSaver().saveFile(
        path: '/cache/chopstats-2026-11-13.json',
        name: 'chopstats-2026-11-13.json',
        mime: 'application/json');

    test('sends saveFile {path, name, mime} on dev.calorietracker/files',
        () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'status': 'ok'};
      });
      expect(await save(), SaveFileStatus.ok);
      expect(calls.single.method, 'saveFile');
      expect(calls.single.arguments, {
        'path': '/cache/chopstats-2026-11-13.json',
        'name': 'chopstats-2026-11-13.json',
        'mime': 'application/json',
      });
    });

    test('each status the native side replies', () async {
      for (final (wire, status) in [
        ('ok', SaveFileStatus.ok),
        ('cancelled', SaveFileStatus.cancelled),
        ('busy', SaveFileStatus.busy),
        ('unavailable', SaveFileStatus.unavailable),
        ('failed', SaveFileStatus.failed),
        ('something new', SaveFileStatus.failed),
      ]) {
        messenger.setMockMethodCallHandler(
            channel, (_) async => {'status': wire});
        expect(await save(), status, reason: wire);
      }
      messenger.setMockMethodCallHandler(channel, (_) async => 'ok');
      expect(await save(), SaveFileStatus.failed, reason: 'not the map');
    });

    test('no method (an older MainActivity): unavailable', () async {
      // No handler at all: Flutter raises MissingPluginException, as for
      // result.notImplemented().
      expect(await save(), SaveFileStatus.unavailable);
    });

    test('a platform error: failed', () async {
      messenger.setMockMethodCallHandler(
          channel, (_) async => throw PlatformException(code: 'io'));
      expect(await save(), SaveFileStatus.failed);
    });
  });

  test('the method name and the export type the native side gets', () {
    expect(saveFileMethod, 'saveFile');
    expect(exportMimeType, 'application/json');
  });
}
