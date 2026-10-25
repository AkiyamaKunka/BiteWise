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
//   - Settings rows (2026-10-10): GroupedRow kept its one-line title beside
//     a 170 pt value at every size, so the root Settings read '后…  系统已关闭'
//     and 'AI…  Claud…' — the row names and the last-scan time unreadable.
//     Above 1.5x the value now sits under the title and both wrap, as iOS
//     Settings lays its cells out at accessibility sizes.
//   - Today ring legend (2026-10-12): each ArithmeticRow kept a one-line
//     label beside its number, so in zh '已摄入' read '已…' and with prior
//     days the three rows (日常 / 消耗 / 已摄入) lost their meaning. Above
//     1.5x the label wraps on its own line and the number sits under it.
//   - Today ring centre (2026-10-12): the two-line centre could use the
//     ring's full square height, so '千卡' ran over the stroke; it now
//     shrinks until its box fits inside the ring's inner circle.
// Whether text fits depends on the glyphs (the test font is a full em per
// glyph, far wider than the phone's), so this loads the iPhone's own system
// fonts — macOS only, skipped elsewhere, as body_screen_test does.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart'
    show LookupRecipient, LookupSupport;
import 'package:calorie_tracker/services/garmin_client.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/widgets/calorie_ring.dart'
    show ArithmeticRow, CalorieRing;
import 'package:calorie_tracker/ui/widgets/grouped.dart';
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

/// A food meal [daysAgo] calendar days before today (computed — a pinned
/// date is a time bomb).
Meal dayMeal(int id, int daysAgo, num kcal) {
  final now = DateTime.now();
  final date = isoDate(DateTime(now.year, now.month, now.day - daysAgo));
  return Meal(
    id: id,
    date: date,
    time: '12:00 PM',
    timestamp: '${date}T12:00:00',
    source: 'app_photo',
    imageHash: 'h$id',
    analysis: {
      'is_food': true,
      'meal_description': 'Lunch',
      'total_calories': kcal,
      'total_protein_g': 20,
      'total_carbs_g': 50,
      'total_fat_g': 10,
    },
  );
}

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

        // The test above seeds a filled meal, whose labels float at 0.75x.
        // A NEW meal's empty fields rest their labels at the full 3.1x, and
        // in English 'Calories (kcal)' read 'Calories (kc…' until tapped
        // (2026-10-10). The unit is a suffix now, like the macro fields' g.
        testWidgets('$lang: new meal number labels rest uncut, unit as suffix', (
          tester,
        ) async {
          await pumpAt(
            tester,
            lang,
            MealEditorScreen(dao: FakeDao(), now: clock),
          );
          expect(tester.takeException(), isNull);
          final scrollable = find.byType(Scrollable).first;
          for (final k in const [
            'editorDescription',
            'editorCalories',
            'editorProtein',
            'editorCarbs',
            'editorFat',
          ]) {
            final field = find.byKey(Key(k));
            await tester.scrollUntilVisible(field, 200, scrollable: scrollable);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expectLabelsUncut(tester, field);
            if (k != 'editorCalories') continue;
            // Typed, the label floats and the unit shows beside the number
            // (checked here, while the lazy list still has the field).
            await tester.enterText(field, '1234');
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              find.descendant(
                of: field,
                matching: find.text(lang == 'zh' ? '千卡' : 'kcal'),
              ),
              findsOneWidget,
            );
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

        // The owner's own Settings root: Claude Plan, a last background
        // scan, an armed summary, a goal — every row that shows a value.
        Widget settingsRoot() {
          final now = DateTime.now();
          return SettingsScreen(
            settings: FakeSettings(apiKey: 'k')
              ..provider = 'server'
              ..serverBackend = 'claude'
              ..calorieGoal = 1800
              ..restaurantAssist = 'auto'
              ..restaurantAssistLocation = true
              ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
              ..restaurantAssistConsentRecipient = 'claude_plan:ffffffff',
            analyzer: FakeAnalyzer(),
            dao: FakeDao(),
            requestPhotoPermission: () async => true,
            lastBackgroundScan: () async =>
                now.subtract(const Duration(hours: 1)),
            backgroundRefreshEnabled: () async => true,
            openSystemSettings: () async {},
            nextSummaryAt: () async => now.add(const Duration(hours: 2)),
            // Design R7a: Restaurant nutrition on, paused for a new server
            // (every one of its rows shows).
            restaurantAssist: RestaurantAssistControls(
              lookupSupport: () => const LookupSupport(
                supported: true,
                recipient: LookupRecipient.claudePlan,
                locationAllowed: true,
                recipientHostTag: '0a1b2c3d',
              ),
              clearLearnedPlaces: () async => true,
              locationSupported: true,
            ),
          );
        }

        const valueRows = [
          'aiProviderRow',
          'backgroundScanRow',
          'reportTimeTile',
          'nextSummaryRow',
          'calorieGoalTile',
          'dietaryProfileRow',
          'languageRow',
        ];

        Finder titleOf(WidgetTester tester, Finder row) => find.descendant(
          of: row,
          matching: find.text(tester.widget<GroupedRow>(row).title),
        );
        Finder valueOf(WidgetTester tester, Finder row) => find.descendant(
          of: row,
          matching: find.text(tester.widget<GroupedRow>(row).value!),
        );

        // 2.0x is where the cuts start (≈AX2); 3.1x is AX5.
        for (final scale in const [2.0, 3.1]) {
          testWidgets('$lang: settings rows read in full at ${scale}x, value '
              'under the title', (tester) async {
            await pumpAt(tester, lang, settingsRoot(), scale: scale);
            expect(tester.takeException(), isNull);
            final scrollable = find.byType(Scrollable).first;

            // In page order: the sliver builds rows lazily and
            // scrollUntilVisible only scrolls down. The toggle row has no
            // value; its title ('Watch Camera Roll') was cut at 2.0x in en.
            final rows = <(String, Finder)>[
              ('aiProviderRow', find.byKey(const Key('aiProviderRow'))),
              (
                'watcherToggle',
                find.ancestor(
                  of: find.byKey(const Key('watcherToggle')),
                  matching: find.byType(GroupedRow),
                ),
              ),
              // Design G3: the glasses switch right under it.
              (
                'watchGlassesToggle',
                find.ancestor(
                  of: find.byKey(const Key('watchGlassesToggle')),
                  matching: find.byType(GroupedRow),
                ),
              ),
              // The Photos group's last value row, then Restaurant
              // nutrition (design R7a), then the rest.
              for (final k in valueRows.skip(1).take(1))
                (k, find.byKey(Key(k))),
              (
                'restaurantModeRow',
                find.byKey(const Key('restaurantModeRow')),
              ),
              (
                'restaurantLocationToggle',
                find.ancestor(
                  of: find.byKey(const Key('restaurantLocationToggle')),
                  matching: find.byType(GroupedRow),
                ),
              ),
              (
                'restaurantPausedRow',
                find.byKey(const Key('restaurantPausedRow')),
              ),
              (
                'clearLearnedPlacesRow',
                find.byKey(const Key('clearLearnedPlacesRow')),
              ),
              for (final k in valueRows.skip(2)) (k, find.byKey(Key(k))),
            ];
            for (final (name, row) in rows) {
              await tester.scrollUntilVisible(row, 300, scrollable: scrollable);
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: '$name overflowed',
              );
              expectLabelsUncut(tester, row);
              if (tester.widget<GroupedRow>(row).value == null) continue;
              final title = tester.getRect(titleOf(tester, row));
              final value = tester.getRect(valueOf(tester, row));
              expect(
                value.top,
                greaterThanOrEqualTo(title.bottom - 0.5),
                reason: '$name: the value sits under the title, not beside it',
              );
            }
          });
        }

        // Prior days give a typical day and Garmin a burn: all three
        // legend rows show, as on the owner's phone.
        Widget todayWithTypical() {
          final dao = FakeDao()
            ..seed(dayMeal(1, 0, 1234))
            ..seed(dayMeal(2, 1, 1850))
            ..seed(dayMeal(3, 2, 2010))
            ..seed(dayMeal(4, 3, 1760));
          return Scaffold(
            body: TodayScreen(
              dao: dao,
              executor: FakeExecutor(),
              garminDaily: (date) async => GarminDaily(
                activeCalories: 512,
                steps: 8000,
                distanceM: 6200,
                activityCount: 1,
              ),
            ),
          );
        }

        testWidgets('$lang: Today ring legend labels read in full, number '
            'under the label', (tester) async {
          await pumpAt(tester, lang, todayWithTypical());
          expect(tester.takeException(), isNull);
          final rows = find.byType(ArithmeticRow);
          expect(rows, findsNWidgets(3), reason: 'typical, burn and eaten');
          for (final row in rows.evaluate().toList()) {
            final w = row.widget as ArithmeticRow;
            final f = find.byWidget(w);
            expectLabelsUncut(tester, f);
            final label = tester.getRect(
              find.descendant(of: f, matching: find.text(w.label)),
            );
            final value = tester.getRect(
              find.descendant(of: f, matching: find.text(w.value)),
            );
            expect(
              value.top,
              greaterThanOrEqualTo(label.bottom - 0.5),
              reason: '"${w.label}": the number sits under the label',
            );
          }
          expect(
            find.text(lang == 'zh' ? '已摄入' : 'Eaten'),
            findsOneWidget,
          );
        });

        testWidgets('$lang: standard sizes keep the ring legend on one row', (
          tester,
        ) async {
          await pumpAt(tester, lang, todayWithTypical(), scale: 1.0);
          expect(tester.takeException(), isNull);
          final row = find.byKey(const Key('arithmeticResultRow'));
          final w = tester.widget<ArithmeticRow>(row);
          final label = tester.getRect(
            find.descendant(of: row, matching: find.text(w.label)),
          );
          final value = tester.getRect(
            find.descendant(of: row, matching: find.text(w.value)),
          );
          expect(value.left, greaterThanOrEqualTo(label.right));
          expect(value.top, lessThan(label.bottom));
        });

        testWidgets('$lang: the ring centre text stays inside the ring', (
          tester,
        ) async {
          // At the largest size the two-line centre could use the ring's
          // full square height, so '千卡' ran over the bottom of the
          // stroke (simulator 2026-10-12). Every corner of both lines must
          // lie inside the inner circle (radius = size / 2 − stroke).
          for (final scale in const [1.0, 3.1]) {
            for (final size in const [132.0, 116.0]) {
              for (final kcal in const [0, 1240, 12345]) {
                await pumpAt(
                  tester,
                  lang,
                  Scaffold(
                    body: Center(
                      child: CalorieRing(
                        eatenKcal: kcal,
                        typicalKcal: 2000,
                        size: size,
                      ),
                    ),
                  ),
                  scale: scale,
                );
                expect(tester.takeException(), isNull);
                final centre = tester.getCenter(find.byType(CalorieRing));
                final innerR = size / 2 - 11;
                final texts = find.descendant(
                  of: find.byType(CalorieRing),
                  matching: find.byType(RichText),
                );
                expect(texts, findsNWidgets(2));
                for (final e in texts.evaluate()) {
                  final r = tester.getRect(find.byWidget(e.widget));
                  for (final p in [
                    r.topLeft,
                    r.topRight,
                    r.bottomLeft,
                    r.bottomRight,
                  ]) {
                    expect(
                      (p - centre).distance,
                      lessThanOrEqualTo(innerR + 0.5),
                      reason: '${scale}x, $size pt ring, $kcal kcal: '
                          '"${(e.widget as RichText).text.toPlainText()}" '
                          'runs over the ring',
                    );
                  }
                }
              }
            }
          }
          // The usual day at standard size draws at full size, as before.
          await pumpAt(
            tester,
            lang,
            const Scaffold(
              body: Center(
                child: CalorieRing(eatenKcal: 1240, typicalKcal: 2000),
              ),
            ),
            scale: 1.0,
          );
          final value = find.byKey(const Key('ringCenterValue'));
          expect(
            tester.getRect(value).width,
            closeTo(tester.getSize(value).width, 0.01),
            reason: "'1,240' at 1.0x is not scaled down",
          );
        });

        testWidgets('$lang: standard sizes keep the settings value beside '
            'its title', (tester) async {
          for (final scale in const [1.0, 1.35]) {
            await pumpAt(tester, lang, settingsRoot(), scale: scale);
            expect(tester.takeException(), isNull);
            final row = find.byKey(const Key('aiProviderRow'));
            final title = tester.getRect(titleOf(tester, row));
            final value = tester.getRect(valueOf(tester, row));
            expect(value.left, greaterThanOrEqualTo(title.right),
                reason: 'at ${scale}x the value stays on the title line');
            expect(value.right, lessThanOrEqualTo(tester.getRect(row).right));
          }
        });
      }
    },
    skip: haveIphoneFonts ? false : 'needs the macOS system fonts',
  );
}
