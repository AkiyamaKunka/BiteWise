/// The 监控相册 toggle path and 导入数据…/导出数据… spoke English inside the
/// Chinese UI (2026-10-07 testing loop): the permission snackbar and its
/// action, the "watching is on, but…" notices, the limited-access warning
/// and its Fix button, the import dialog, every import/export result line
/// and the parser's refusals were string literals in settings_screen.dart.
/// Each is an ARB key now. These tests pump the REAL delegates in zh and
/// in en, so the Chinese actually appears and the English stays
/// byte-identical to what the literals said.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';

import 'fakes.dart';

/// One locale's expected copy. The en record IS the pre-l10n literal set.
typedef _Copy = ({
  Locale locale,
  String denied,
  String openSettings,
  String noKey,
  String paused,
  String limited,
  String fix,
  String dialogTitle,
  String dialogBody,
  String cancel,
  String importBtn,
  String imported,
  String importedKept,
  String nothingNew,
  String notJson,
  String importFailed,
  String exportFailed,
});

const _en = (
  locale: Locale('en'),
  denied: 'Photo library permission is required for automatic intake.',
  openSettings: 'Open system settings',
  noKey: "Watching is on, but photos won't be analyzed until a working API "
      'key is set above.',
  paused: 'Watching is on, but analyses are paused by the daily quota — '
      'new photos will wait.',
  limited: "Only SELECTED photos are shared, so new food photos won't be "
      'seen automatically. Grant access to ALL photos for automatic '
      'logging.',
  fix: 'Fix',
  dialogTitle: 'Import exported data',
  dialogBody: 'Paste the contents of an exported JSON file. Existing meals '
      'are kept; only new ones are added.',
  cancel: 'Cancel',
  importBtn: 'Import',
  imported: 'Imported 1 meal (1 rows total).',
  importedKept: 'Imported 2 meals (2 rows total); 1 already here.',
  nothingNew: 'Nothing new to import — everything in that file is already '
      'here.',
  notJson: 'That file is not JSON.',
  importFailed: 'Import failed: Bad state: disk full',
  exportFailed: 'Export failed: Bad state: disk full',
);

const _zh = (
  locale: Locale('zh'),
  denied: '自动记录需要相册访问权限。',
  openSettings: '打开系统设置',
  noKey: '监控已打开，但要等上方设置好可用的 API Key 后，照片才会被分析。',
  paused: '监控已打开，但分析因当日额度已暂停 —— 新照片会先保留。',
  limited: '目前只共享了部分选中的照片，新的食物照片不会被自动看到。'
      '请授予访问所有照片的权限，才能自动记录。',
  fix: '去修复',
  dialogTitle: '导入已导出的数据',
  dialogBody: '粘贴导出的 JSON 文件内容。已有的餐会保留，只会添加新的。',
  cancel: '取消',
  importBtn: '导入',
  imported: '已导入 1 餐（共 1 行）。',
  importedKept: '已导入 2 餐（共 2 行）；1 条已存在。',
  nothingNew: '没有可导入的新内容 —— 那个文件里的记录这里都已经有了。',
  notJson: '这个文件不是 JSON。',
  importFailed: '导入失败：Bad state: disk full',
  exportFailed: '导出失败：Bad state: disk full',
);

const _validPayload = '{"format":"calorie_tracker_export","version":1,'
    '"exported_at":"2026-07-30T10:00:00.000",'
    '"tables":{"meals":[{"date":"2026-07-30"}]}}';
const _emptyPayload = '{"format":"calorie_tracker_export","version":1,'
    '"tables":{"meals":[]}}';

/// iOS "selected photos" / Android partial grant: every other method is
/// unreachable from the toggle path and says so loudly if that changes.
class _LimitedLibrary implements PhotoLibrary {
  @override
  Future<bool> hasFullAccess() async => false;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId, {int size = 160}) =>
      throw UnimplementedError();
  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) =>
      throw UnimplementedError();
  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
          {int limit = 500}) =>
      throw UnimplementedError();
  @override
  Future<List<LibraryAsset>> recentImages(int limit) =>
      throw UnimplementedError();
  @override
  Future<void> startChangeNotify(void Function() onChange) =>
      throw UnimplementedError();
  @override
  Future<void> stopChangeNotify() => throw UnimplementedError();
}

/// The merge found one row already present — the only way to reach the
/// "; N already here" sentence (the base fake never reports skips).
class _KeptDao extends FakeDao {
  @override
  Future<ImportSummary> importJson(String json) async =>
      const ImportSummary({'meals': 2}, {'meals': 1});
}

/// A non-format failure on either side: the generic "failed: …" lines.
class _FailingDao extends FakeDao {
  @override
  Future<ImportSummary> importJson(String json) async =>
      throw StateError('disk full');
  @override
  Future<String> exportJson() async => throw StateError('disk full');
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    Locale locale, {
    FakeSettings? settings,
    FakeDao? dao,
    bool permission = true,
    PhotoLibrary? library,
    Future<void> Function()? openSystemSettings,
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SettingsScreen(
          settings: settings ?? FakeSettings(apiKey: 'k'),
          analyzer: FakeAnalyzer(),
          dao: dao ?? FakeDao(),
          requestPhotoPermission: () async => permission,
          photoLibrary: library,
          openSystemSettings: openSystemSettings,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> importVia(WidgetTester tester, String payload) async {
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('importField')), payload);
    await tester.tap(find.byKey(const Key('importConfirm')));
    await tester.pumpAndSettle();
  }

  for (final c in <_Copy>[_zh, _en]) {
    final tag = c.locale.languageCode;

    group('[$tag] 监控相册 toggle path', () {
      testWidgets('permission denied: the sentence and its system-settings '
          'action', (tester) async {
        var opened = 0;
        await pump(tester, c.locale,
            settings: FakeSettings(watcherEnabled: false),
            permission: false,
            openSystemSettings: () async => opened++);
        await tester.tap(find.byKey(const Key('watcherToggle')));
        await tester.pumpAndSettle();
        expect(find.text(c.denied), findsOneWidget);
        expect(find.text(c.openSettings), findsOneWidget,
            reason: 'the action reuses the app-wide openSystemSettings key');
        await tester.tap(find.text(c.openSettings));
        await tester.pump();
        expect(opened, 1);
      });

      testWidgets('no usable key: "watching is on, but…"', (tester) async {
        await pump(tester, c.locale,
            settings: FakeSettings(apiKey: '', watcherEnabled: false));
        await tester.tap(find.byKey(const Key('watcherToggle')));
        await tester.pumpAndSettle();
        expect(find.text(c.noKey), findsOneWidget);
      });

      testWidgets('quota pause: the paused variant', (tester) async {
        await pump(tester, c.locale,
            settings: FakeSettings(apiKey: 'k', watcherEnabled: false)
              ..isQuotaPaused = true);
        await tester.tap(find.byKey(const Key('watcherToggle')));
        await tester.pumpAndSettle();
        expect(find.text(c.paused), findsOneWidget);
      });

      testWidgets('limited photo access: the warning and its Fix action',
          (tester) async {
        var opened = 0;
        await pump(tester, c.locale,
            settings: FakeSettings(apiKey: 'k', watcherEnabled: false),
            library: _LimitedLibrary(),
            openSystemSettings: () async => opened++);
        await tester.tap(find.byKey(const Key('watcherToggle')));
        await tester.pumpAndSettle();
        expect(find.text(c.limited), findsOneWidget);
        expect(find.text(c.fix), findsOneWidget);
        await tester.tap(find.text(c.fix));
        await tester.pump();
        expect(opened, 1);
      });
    });

    group('[$tag] 导入数据… / 导出数据…', () {
      testWidgets('the dialog: title, body, Cancel and Import',
          (tester) async {
        await pump(tester, c.locale);
        await tester.tap(find.byKey(const Key('importButton')));
        await tester.pumpAndSettle();
        expect(find.text(c.dialogTitle), findsOneWidget);
        expect(find.text(c.dialogBody), findsOneWidget);
        expect(find.text(c.cancel), findsOneWidget);
        expect(find.text(c.importBtn), findsOneWidget);
      });

      testWidgets('a merge reports what it did', (tester) async {
        await pump(tester, c.locale);
        await importVia(tester, _validPayload);
        expect(find.text(c.imported), findsOneWidget);
      });

      testWidgets('rows already here are counted in the same sentence',
          (tester) async {
        await pump(tester, c.locale, dao: _KeptDao());
        await importVia(tester, _validPayload);
        expect(find.text(c.importedKept), findsOneWidget);
      });

      testWidgets('an import with nothing new says so', (tester) async {
        await pump(tester, c.locale);
        await importVia(tester, _emptyPayload);
        expect(find.text(c.nothingNew), findsOneWidget);
      });

      testWidgets("the parser's refusal is spoken, not echoed in English",
          (tester) async {
        await pump(tester, c.locale);
        await importVia(tester, 'my shopping list');
        expect(find.text(c.notJson), findsOneWidget);
      });

      testWidgets('a non-format import failure: "Import failed: …"',
          (tester) async {
        await pump(tester, c.locale, dao: _FailingDao());
        await importVia(tester, _validPayload);
        expect(find.text(c.importFailed), findsOneWidget);
      });

      testWidgets('an export failure: "Export failed: …"', (tester) async {
        await pump(tester, c.locale, dao: _FailingDao());
        await tester.tap(find.byKey(const Key('exportButton')));
        await tester.pumpAndSettle();
        expect(find.text(c.exportFailed), findsOneWidget);
      });
    });
  }

  testWidgets('the bare-MaterialApp English fallback (every other suite) '
      'still gets the literal sentences', (tester) async {
    // settings_validation_test pins two of these through the fallback;
    // this one pins that the fallback path and the en delegate agree.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SettingsScreen(
      settings: FakeSettings(watcherEnabled: false),
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => false,
    ))));
    await tester.tap(find.byKey(const Key('watcherToggle')));
    await tester.pumpAndSettle();
    expect(find.text(_en.denied), findsOneWidget);
  });
}
