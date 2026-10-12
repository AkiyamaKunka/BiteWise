// The meal editor in the Chinese UI (the owner's language): every rejection
// the form can produce, the multi-error snackbar, and the item-row field
// labels must come from the app language. Found 2026-10-07: a zh user who
// typed '300千卡' got 'Calories must be a number.' and the item rows read
// 'kcal' / 'P g' while the meal cards one screen back say 蛋/碳/脂.
// The English values stay byte-identical (meal_editor_screen_test.dart and
// meal_edit_logic_test.dart pin them without delegates).
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/meal_edit_logic.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Widget zhHost(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );

void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  DateTime clock() => DateTime(2026, 7, 24, 19, 5);

  testWidgets('zh: totals rejections and the snackbar are Chinese',
      (tester) async {
    useTallSurface(tester);
    final dao = FakeDao();
    await tester.pumpWidget(zhHost(MealEditorScreen(dao: dao, now: clock)));

    await tester.enterText(find.byKey(const Key('editorCalories')), '300千卡');
    await tester.enterText(find.byKey(const Key('editorFat')), '-3');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pump();

    expect(find.byKey(const Key('editorErrors')), findsOneWidget);
    expect(find.textContaining('热量必须是数字。'), findsOneWidget);
    expect(find.textContaining('脂肪不能为负数。'), findsOneWidget);
    expect(find.text('有 2 处需要修改，请看顶部。'), findsOneWidget);
    expect(find.textContaining('must be a number'), findsNothing);
    expect(find.textContaining('cannot be negative'), findsNothing);
    expect(find.textContaining('things need fixing'), findsNothing);
    expect(dao.saved, isEmpty);
  });

  testWidgets('zh: item rows use 千卡/蛋/碳/脂 and name the row in Chinese',
      (tester) async {
    useTallSurface(tester);
    final dao = FakeDao();
    await tester.pumpWidget(zhHost(MealEditorScreen(dao: dao, now: clock)));

    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();

    // Same vocabulary as the meal cards (macroProteinShort etc.).
    expect(find.text('千卡'), findsNWidgets(2));
    expect(find.text('蛋 g'), findsNWidgets(2));
    expect(find.text('碳 g'), findsNWidgets(2));
    expect(find.text('脂 g'), findsNWidgets(2));
    expect(find.text('kcal'), findsNothing);
    expect(find.text('P g'), findsNothing);

    // Row 1 stays blank (skipped); row 2 carries the typo.
    await tester.enterText(find.byKey(const Key('itemName1')), '鸡蛋');
    await tester.enterText(find.byKey(const Key('itemPro1')), 'abc');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pump();

    // One error: the card AND the snackbar show the same sentence.
    expect(find.text('第 2 项食物的蛋白质必须是数字。'), findsNWidgets(2));
    expect(find.textContaining('Item 2'), findsNothing);
    expect(dao.saved, isEmpty);
  });

  testWidgets('zh: the four-field item row still lays out on a narrow phone '
      'at a large text size', (tester) async {
    tester.view.physicalSize = const Size(320, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!),
      home: MealEditorScreen(dao: FakeDao(), now: clock),
    ));
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    expect(find.text('千卡'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('zh logic: every validate() message is Chinese; en default unchanged',
      () {
    final zh = AppLocalizationsZh();
    final d = MealDraft(
      description: 'x' * (maxDescriptionChars + 1),
      dateIso: '2026-02-30',
      time: 'noon',
      calories: '99999',
      protein: '',
      carbs: '',
      fat: '',
      items: [
        for (var i = 0; i < maxItemsPerMeal + 1; i++)
          MealItemDraft(name: 'i$i'),
      ],
    );
    expect(d.validate(zh), [
      '描述太长了（上限 300 字）。',
      '日期必须是真实存在的 YYYY-MM-DD 日期。',
      '时间格式应类似 07:30 PM。',
      '热量太大了（上限 20000）。',
      '食物太多了（上限 40 项）。',
    ]);
    expect(d.validate(), [
      'Description is too long (max 300).',
      'Date must be a real YYYY-MM-DD date.',
      'Time must look like 07:30 PM.',
      'Calories looks too large (max 20000).',
      'Too many items (max 40).',
    ]);
  });
}
