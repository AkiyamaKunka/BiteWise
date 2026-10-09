// Layout at the largest iOS accessibility text size (AX5, ~3.1×) on a
// 390 pt phone, found on the simulator 2026-10-07: three RenderFlex
// overflows (the debug build's yellow/black stripe) that hid real text.
//   - Body tab, empty: the hint wrapped to ~8 lines inside a
//     SliverFillRemaining that pinned it to the viewport height, so its end
//     was clipped (BOTTOM OVERFLOWED BY 142 PIXELS) and no scroll reached it.
//   - Meal editor: the 'Items' header row gave the unflexed 'Totals follow
//     these items' hint the whole width, squeezing 'Items' to one glyph per
//     line (RIGHT OVERFLOWED BY 75 PIXELS).
//   - Macro legend (day detail + editor): one entry wider than the card
//     could not wrap inside its Row, so the percentage ran past the edge.
// Not overflows but still unreadable at that size (2026-10-08), so above
// 1.5x (ui/large_text.dart) these layouts stack instead of shrinking text:
//   - Day detail meal row: the clock beside the title squeezed a Chinese
//     title to ~2 glyphs a line; the clock now sits under the title.
//   - Meal editor: the date pill wrapped and the number-field labels were
//     cut ('Pr…', 'k…'); date/time and the total macros take a row each,
//     the item fields a 2x2 grid. Normal text keeps the one-row layout.
// Whether text fits depends on the glyphs (the test font is a full em per
// glyph, far wider than the phone's), so this loads the iPhone's own system
// fonts — macOS only, skipped elsewhere, as body_screen_test does.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const sfPath = '/System/Library/Fonts/SFNS.ttf';
const cjkPath = '/System/Library/Fonts/Hiragino Sans GB.ttc';
final haveIphoneFonts = File(sfPath).existsSync() && File(cjkPath).existsSync();

Future<void> loadFont(String family, String path) async {
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

Meal itemizedMeal() => Meal(
  id: 1,
  date: '2026-07-24',
  time: '01:30 PM',
  timestamp: '2026-07-24T13:30:00.000',
  source: 'app_photo',
  imageHash: 'h1',
  analysis: const {
    'is_food': true,
    'meal_description': 'Chicken salad',
    'total_calories': 450,
    'total_protein_g': 50,
    'total_carbs_g': 12,
    'total_fat_g': 22,
    'food_items': [
      {
        'name': 'Chicken',
        'estimated_calories': 450,
        'protein_g': 50,
        'carbs_g': 12,
        'fat_g': 22,
      },
    ],
  },
);

/// A generic dish name (not anyone's real meal) long enough to wrap.
Meal titledMeal(String title) => Meal(
  id: 1,
  date: '2026-07-24',
  time: '01:30 PM',
  timestamp: '2026-07-24T13:30:00.000',
  source: 'app_photo',
  imageHash: 'h1',
  analysis: {
    'is_food': true,
    'meal_description': title,
    'total_calories': 450,
    'total_protein_g': 50,
    'total_carbs_g': 12,
    'total_fat_g': 22,
  },
);

/// Every label paragraph inside [field] shows in full (no '…').
void expectLabelsUncut(WidgetTester tester, Finder field) {
  final paragraphs = tester.renderObjectList<RenderParagraph>(
    find.descendant(of: field, matching: find.byType(RichText)),
  );
  expect(paragraphs, isNotEmpty);
  for (final p in paragraphs) {
    expect(
      p.didExceedMaxLines,
      isFalse,
      reason: '"${p.text.toPlainText()}" is cut to an ellipsis',
    );
  }
}

/// [finder]'s last paragraph (a button's label comes after its icon,
/// itself a RichText) reads on one line.
void expectOneLine(WidgetTester tester, Finder finder) {
  final p = tester
      .renderObjectList<RenderParagraph>(
        find.descendant(of: finder, matching: find.byType(RichText)),
      )
      .last;
  expect(
    p.size.width,
    greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5),
    reason: '"${p.text.toPlainText()}" must not wrap',
  );
}

void main() {
  DateTime clock() => DateTime(2026, 7, 24, 19, 5);

  Future<void> pumpAt(
    WidgetTester tester,
    String lang,
    Widget home, {
    double scale = 3.1,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(lang),
        theme: ThemeData(
          fontFamily: 'AxSF',
          fontFamilyFallback: const ['AxHiragino'],
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  group(
    'largest accessibility text size, 390 pt phone (SF + Hiragino)',
    () {
      setUpAll(() async {
        TestWidgetsFlutterBinding.ensureInitialized();
        await loadFont('AxSF', sfPath);
        await loadFont('AxHiragino', cjkPath);
      });

      for (final lang in const ['en', 'zh']) {
        testWidgets('$lang: Body empty state scrolls instead of overflowing', (
          tester,
        ) async {
          await pumpAt(
            tester,
            lang,
            BodyScreen(dao: FakeDao(), clock: () => DateTime(2026, 8, 2)),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'the empty state overflowed the remaining viewport',
          );
          expect(find.byKey(const Key('bodyEmpty')), findsOneWidget);

          // The end of the hint must be reachable by scrolling.
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -3000),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final hint = find
              .descendant(
                of: find.byKey(const Key('bodyEmpty')),
                matching: find.byType(Text),
              )
              .last;
          expect(
            tester.getRect(hint).bottom,
            lessThanOrEqualTo(844),
            reason: 'the hint ends on screen once scrolled',
          );
        });

        testWidgets('$lang: meal editor Items header wraps its hint', (
          tester,
        ) async {
          final dao = FakeDao()..seed(itemizedMeal());
          await pumpAt(
            tester,
            lang,
            MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'the Items header / legend overflowed',
          );
          final hint = find.byKey(const Key('totalsDerivedHint'));
          await tester.scrollUntilVisible(
            hint,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final header = find.ancestor(of: hint, matching: find.byType(Wrap));
          expect(header, findsOneWidget);
          // The header word reads on one line, not one glyph per line.
          final title = tester
              .renderObjectList<RenderParagraph>(
                find.descendant(of: header, matching: find.byType(RichText)),
              )
              .first;
          expect(
            title.size.width,
            greaterThanOrEqualTo(
              title.getMaxIntrinsicWidth(double.infinity) - 0.5,
            ),
            reason: '"${title.text.toPlainText()}" must not wrap',
          );
          expect(tester.getRect(hint).right, lessThanOrEqualTo(390));
        });

        testWidgets('$lang: day detail macro legend wraps inside the card', (
          tester,
        ) async {
          final dao = FakeDao()..seed(itemizedMeal());
          await pumpAt(
            tester,
            lang,
            DayDetailScreen(dao: dao, date: '2026-07-24', now: clock),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'a legend entry overflowed the meal card',
          );
          final card = find.ancestor(
            of: find.byKey(const Key('mealRow1')),
            matching: find.byType(Card),
          );
          final legend = find.descendant(
            of: card,
            matching: find.byKey(const Key('macroLegend')),
          );
          await tester.scrollUntilVisible(
            legend,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final cardRect = tester.getRect(card);
          final entries = tester.renderObjectList<RenderParagraph>(
            find.descendant(of: legend, matching: find.byType(RichText)),
          );
          expect(entries, hasLength(3), reason: 'protein, carbs and fat');
          for (final p in entries) {
            final r = p.localToGlobal(Offset.zero) & p.size;
            expect(
              r.right,
              lessThanOrEqualTo(cardRect.right + 0.5),
              reason: '"${p.text.toPlainText()}" stays inside the card',
            );
          }
        });

        testWidgets('$lang: day detail meal title gets the row, clock below', (
          tester,
        ) async {
          final dao = FakeDao()
            ..seed(titledMeal(lang == 'zh' ? '番茄炒蛋配米饭和青菜' : 'Tomato egg rice'));
          await pumpAt(
            tester,
            lang,
            DayDetailScreen(dao: dao, date: '2026-07-24', now: clock),
          );
          expect(tester.takeException(), isNull);
          final row = find.byKey(const Key('mealRow1'));
          final title = find.descendant(
            of: row,
            matching: find.byKey(const Key('mealRowTitle')),
          );
          final time = find.descendant(
            of: row,
            matching: find.byKey(const Key('mealRowTime')),
          );
          await tester.scrollUntilVisible(
            time,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          // The clock sits under the title instead of taking a fixed slice
          // of its line, so the title is not squeezed to ~2 glyphs a line.
          expect(
            tester.getRect(time).top,
            greaterThanOrEqualTo(tester.getRect(title).bottom - 0.5),
          );
          expect(
            tester.getRect(title).width,
            greaterThanOrEqualTo(tester.getRect(row).width / 2),
          );
          expectOneLine(tester, time);
        });

        testWidgets('$lang: meal editor number labels and date read in full', (
          tester,
        ) async {
          final dao = FakeDao()..seed(itemizedMeal());
          await pumpAt(
            tester,
            lang,
            MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock),
          );
          expect(tester.takeException(), isNull);
          final scrollable = find.byType(Scrollable).first;
          expectOneLine(tester, find.byKey(const Key('editorDateButton')));
          expectOneLine(tester, find.byKey(const Key('editorTimeButton')));
          for (final k in const [
            'editorCalories',
            'editorProtein',
            'editorCarbs',
            'editorFat',
            'itemCal0',
            'itemPro0',
            'itemCarb0',
            'itemFat0',
          ]) {
            final field = find.byKey(Key(k));
            await tester.scrollUntilVisible(field, 200, scrollable: scrollable);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expectLabelsUncut(tester, field);
          }
        });

        testWidgets('$lang: normal text keeps the one-row field layout', (
          tester,
        ) async {
          final dao = FakeDao()..seed(itemizedMeal());
          await pumpAt(
            tester,
            lang,
            MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock),
            scale: 1.0,
          );
          expect(tester.takeException(), isNull);
          double top(String k) => tester.getRect(find.byKey(Key(k))).top;
          expect(top('editorTimeButton'), top('editorDateButton'));
          expect(top('editorCarbs'), top('editorProtein'));
          expect(top('editorFat'), top('editorProtein'));
          expect(top('itemPro0'), top('itemCal0'));
          expect(top('itemFat0'), top('itemCal0'));

          await pumpAt(
            tester,
            lang,
            DayDetailScreen(dao: dao, date: '2026-07-24', now: clock),
            scale: 1.0,
          );
          expect(tester.takeException(), isNull);
          // The clock stays beside the title.
          expect(
            tester.getRect(find.byKey(const Key('mealRowTime'))).left,
            greaterThanOrEqualTo(
              tester.getRect(find.byKey(const Key('mealRowTitle'))).right,
            ),
          );
        });
      }
    },
    skip: haveIphoneFonts ? false : 'needs the macOS system fonts',
  );
}
