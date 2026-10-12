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

void main() {
  DateTime clock() => DateTime(2026, 7, 24, 19, 5);

  Future<void> pumpAt(WidgetTester tester, String lang, Widget home) async {
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
          ).copyWith(textScaler: const TextScaler.linear(3.1)),
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
      }
    },
    skip: haveIphoneFonts ? false : 'needs the macOS system fonts',
  );
}
