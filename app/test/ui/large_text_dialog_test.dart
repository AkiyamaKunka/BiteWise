/// Dialogs at the largest text size on the smallest phone (A1): title and
/// content scroll TOGETHER while the actions stay visible. Unscrollable,
/// the goal field got 0 pt with the keyboard up and the Stop sharing
/// explanation was cut to nothing on a 375x667 phone at AX5 (53/17 =
/// 3.12x, iOS's linear scale).
library;

import 'dart:async';

import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:calorie_tracker/ui/theme/app_dialog.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

const _ax5 = 53 / 17;

bool _hittable(WidgetTester tester, Finder f) {
  final center = tester.getCenter(f);
  final result = HitTestResult();
  tester.binding.hitTestInView(result, center, tester.view.viewId);
  final box = tester.renderObject(f);
  return result.path.any((e) => e.target == box);
}

void main() {
  setUpAll(loadIphoneFonts);

  for (final (locale, title, body) in const [
    (
      Locale('en'),
      'Stop sharing photos with Google Gemini?',
      'Chopstats stops sending your meal photos and text to Google Gemini. '
          'Meals already logged stay on this phone. Automatic logging pauses '
          'until you choose an AI again, and nothing is sent until you agree.',
    ),
    (
      Locale('zh'),
      '停止与 Google Gemini 共享照片？',
      '筷拍将停止把你的餐食照片和文字发送给 Google Gemini。已记录的餐食仍保存在这台手机上。'
          '自动记录会暂停，直到你重新选择 AI 服务；在你同意之前不会发送任何内容。',
    ),
  ]) {
    testWidgets('${locale.languageCode}: a long confirm reads in full and '
        'keeps its buttons', (tester) async {
      await pumpApp(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('open'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => appAlertDialog(
                    title: Text(title),
                    content: Text(body, key: const Key('body')),
                    actions: [
                      TextButton(
                          key: const Key('cancel'),
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          key: const Key('confirm'),
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Stop sharing')),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
          size: const Size(375, 667),
          locale: locale,
          scale: _ax5);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
          isTrue);
      expect(_hittable(tester, find.byKey(const Key('confirm'))), isTrue,
          reason: 'the actions stay pinned and visible');
      // The whole explanation is reachable by scrolling the dialog.
      final scrollable = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(Scrollable));
      await tester.dragUntilVisible(find.byKey(const Key('body')),
          scrollable.first, const Offset(0, -80));
      final bodyBox = tester.getRect(find.byKey(const Key('body')));
      expect(bodyBox.height, greaterThan(100),
          reason: 'the content is laid out at full height, not squeezed');
      expect(_hittable(tester, find.byKey(const Key('confirm'))), isTrue);
    });
  }

  testWidgets('a field in a dialog keeps its height with the keyboard up',
      (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 216);
    addTearDown(tester.view.resetViewInsets);
    await pumpApp(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => appAlertDialog(
                  title: const Text('Daily calorie goal'),
                  content: const TextField(
                      key: Key('goal'),
                      decoration: InputDecoration(suffixText: 'kcal')),
                  actions: [
                    FilledButton(
                        key: const Key('save'),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Save')),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
        size: const Size(375, 667),
        scale: _ax5);
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('goal'))).height,
        greaterThan(40),
        reason: 'unscrollable, the field got 0 pt at AX4-AX5');
    expect(_hittable(tester, find.byKey(const Key('save'))), isTrue);
  });

  // My usual foods' "Log it again?" (usual foods §4): a similar meal was
  // logged in the last 3 h, and its long name is in the body.
  for (final (locale, name) in const [
    (Locale('en'), 'Grilled chicken salad with quinoa and avocado'),
    (Locale('zh'), '牛油果藜麦烤鸡肉沙拉配溏心蛋'),
  ]) {
    testWidgets('${locale.languageCode}: "Log it again?" reads in full and '
        'keeps its buttons', (tester) async {
      DateTime now() => DateTime(2026, 11, 7, 12, 30);
      final dao = FakeDao();
      for (final (id, date, time) in const [
        (10, '2026-11-04', '12:15 PM'),
        (11, '2026-11-06', '12:40 PM'),
        (12, '2026-11-07', '11:50 AM'),
      ]) {
        dao.seed(foodMeal(
            id: id,
            date: date,
            time: time,
            description: name,
            items: [foodItem(name, 450, p: 40, c: 12, f: 22)]));
      }
      final usual = await makeUsualFoods(dao, clock: now);
      await pumpApp(tester, UsualFoodsScreen(usual: usual, now: now),
          size: const Size(375, 667), locale: locale, scale: _ax5);
      final row = find.text(name);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dialog = find.byKey(const Key('usualAgainDialog'));
      expect(dialog, findsOneWidget);
      expect(tester.widget<AlertDialog>(dialog).scrollable, isTrue);
      for (final key in ['usualAgainConfirm', 'usualAgainCancel']) {
        expect(_hittable(tester, find.byKey(Key(key))), isTrue,
            reason: '$key stays pinned and visible');
      }
      // The whole sentence, the meal's name in it, is reachable by
      // scrolling the dialog.
      final body =
          find.descendant(of: dialog, matching: find.textContaining(name));
      final scrollable =
          find.descendant(of: dialog, matching: find.byType(Scrollable));
      await tester.dragUntilVisible(
          body, scrollable.first, const Offset(0, -80));
      expect(_hittable(tester, find.byKey(const Key('usualAgainConfirm'))),
          isTrue);
      // A style move changes no outcome: Cancel logs nothing.
      await tester.tap(find.byKey(const Key('usualAgainCancel')));
      await tester.pumpAndSettle();
      expect(dao.meals, hasLength(3));
    });
  }

  testWidgets('the setup-link confirmation scrolls as a whole at AX5',
      (tester) async {
    final links = StreamController<Uri>.broadcast();
    addTearDown(links.close);
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: FakeSettings(apiKey: 'old', watcherEnabled: false),
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      reports: FakeReports(),
      setupLinks: links.stream,
    );
    await pumpApp(tester, HomeShell(services: services),
        size: const Size(375, 667), scale: _ax5);
    links.add(Uri.parse('bitewise://setup?server=http%3A%2F%2F10.0.0.7'
        '&key=k1234567890abcdef&backend=claude'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        isTrue);
    expect(_hittable(tester, find.byKey(const Key('setupLinkConfirm'))),
        isTrue);
  });
}
