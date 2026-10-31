// Body tab and Log body sheet on the run-7 theme at real phone sizes, with
// the iPhone's own fonts (macOS; glyph-dependent checks skip elsewhere).
//
// A5: at AX5 the weight row (number + unit + change chip) overflowed the
// card by 185 px on an iPhone SE, and the girth deltas were clipped.
// A7: the sheet's two-per-row fields cut their labels to 'We…'/'Wai…' and
// hid the typed weight behind its unit.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

void main() {
  final clock = DateTime(2026, 10, 31, 9);
  // iOS body-size ratios: L 1.0, AX1 1.647, AX2 1.941, AX3 2.353,
  // AX4 2.765, AX5 3.118.
  const scales = [1.0, 1.647, 1.941, 2.353, 2.765, 3.118];
  const se = Size(375, 667);
  const seTop = EdgeInsets.only(top: 20);

  FakeDao seeded({double latest = 71.6, double before = 72.0}) {
    final dao = FakeDao();
    for (final (d, kg) in [
      ('2026-10-24', 72.4),
      ('2026-10-28', before),
      ('2026-10-30', latest),
    ]) {
      dao.weightsByDate[d] = WeightEntry(d, kg, source: 'manual');
    }
    for (final m in const [
      BodyMeasurements('2026-10-21', waistCm: 84, chestCm: 98.5, hipCm: 97),
      BodyMeasurements('2026-10-28', waistCm: 83.2, chestCm: 98, hipCm: 96.5),
    ]) {
      dao.measurementsByDate[m.date] = m;
    }
    return dao;
  }

  setUpAll(loadIphoneFonts);

  /// Every paragraph under [of] reads in full (no ellipsis, no mid-word
  /// wrap).
  void expectUncut(WidgetTester tester, Finder of, String why) {
    for (final p in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: of, matching: find.byType(RichText)))) {
      final text = p.text.toPlainText();
      expect(p.didExceedMaxLines, isFalse, reason: '$why: "$text" is cut');
    }
  }

  group('weight card', () {
    for (final lang in const ['en', 'zh']) {
      for (final (latest, before) in const [(71.6, 72.0), (102.4, 99.0)]) {
        for (final scale in scales) {
          testWidgets('$lang $latest kg at ${scale}x on an iPhone SE',
              (tester) async {
            await pumpApp(
              tester,
              BodyScreen(
                  dao: seeded(latest: latest, before: before),
                  clock: () => clock),
              // Tall enough to lay out every card; the width is the SE's.
              size: Size(se.width, 3000),
              locale: Locale(lang),
              scale: scale,
              padding: seTop,
            );
            expect(tester.takeException(), isNull,
                reason: 'no RenderFlex overflow (stress shot 40: 185 px)');
            final card = tester.getRect(find.byKey(const Key('bodyWeightCard')));
            for (final key in const [
              'bodyWeightHeadline',
              'bodyWeightUnit',
              'bodyWeightDelta',
              'bodyWeightDate',
            ]) {
              final r = tester.getRect(find.byKey(Key(key)));
              expect(r.right, lessThanOrEqualTo(card.right - 15.5),
                  reason: '$key stays inside the card padding');
              expect(r.left, greaterThanOrEqualTo(card.left + 15.5));
            }
            expectUncut(tester, find.byKey(const Key('bodyWeightCard')),
                'weight card');
            final headline = tester.renderObject<RenderParagraph>(find
                .descendant(
                    of: find.byKey(const Key('bodyWeightHeadline')),
                    matching: find.byType(RichText)));
            expect(headline.size.height,
                lessThan(2 * headline.preferredLineHeight + 1),
                reason: 'the number never breaks over two lines');
            if (scale > 1.5) {
              expect(
                  tester.getTopLeft(find.byKey(const Key('bodyWeightDelta'))).dy,
                  greaterThanOrEqualTo(tester
                      .getBottomLeft(find.byKey(const Key('bodyWeightHeadline')))
                      .dy),
                  reason: 'the chip takes its own line at large sizes');
            }
            // The chart keeps its plot height under its label bands.
            expect(
                tester.getSize(find.byKey(const Key('weightTrendChart'))).height,
                greaterThan(104));

            final measurements =
                tester.getRect(find.byKey(const Key('bodyMeasurementsCard')));
            for (final k in const ['bodyWaist', 'bodyChest', 'bodyHip']) {
              final row = find.byKey(Key('${k}Row'));
              expect(tester.getRect(row).right,
                  lessThanOrEqualTo(measurements.right));
              expectUncut(tester, row, k);
            }
          }, skip: !haveIphoneFonts);
        }
      }
    }

    testWidgets('dark mode renders the same page without errors',
        (tester) async {
      await pumpApp(tester, BodyScreen(dao: seeded(), clock: () => clock),
          size: const Size(390, 2400), brightness: Brightness.dark);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('weightTrendChart')), findsOneWidget);
    });
  });

  group('Log body sheet', () {
    Future<void> openSheet(WidgetTester tester, String lang, double scale,
        {FakeSettings? settings}) async {
      await pumpApp(
        tester,
        BodyScreen(dao: FakeDao(), settings: settings, clock: () => clock),
        size: se,
        locale: Locale(lang),
        scale: scale,
        padding: seTop,
      );
      await tester.tap(find.byKey(const Key('logBodyButton')));
      await tester.pumpAndSettle();
    }

    const fields = [
      'bodyWeightField',
      'bodyWaistField',
      'bodyChestField',
      'bodyHipField',
    ];

    for (final lang in const ['en', 'zh']) {
      for (final scale in scales) {
        testWidgets('$lang at ${scale}x on an iPhone SE', (tester) async {
          await openSheet(tester, lang, scale);
          expect(tester.takeException(), isNull);
          expect(tester.getTopLeft(find.byType(BottomSheet)).dy,
              greaterThanOrEqualTo(seTop.top),
              reason: 'the sheet stays below the status bar');
          final dys = [
            for (final f in fields) tester.getTopLeft(find.byKey(Key(f))).dy,
          ];
          if (scale > 1.5) {
            expect(dys.toSet(), hasLength(4),
                reason: 'one field per row at accessibility sizes');
          } else {
            expect(dys[0], dys[1], reason: 'Weight and Waist share a row');
            expect(dys[2], dys[3], reason: 'Chest and Hip share a row');
          }
          for (final f in fields) {
            expectUncut(tester, find.byKey(Key(f)), f);
          }
          final save = tester.getRect(find.byKey(const Key('bodySheetSave')));
          final sheet = tester.getRect(find.byType(BottomSheet));
          expect(save.width, closeTo(sheet.width - 32, 0.5),
              reason: 'full-width Save inside the 16-pt gutters');
          expect(save.height, greaterThanOrEqualTo(48));
        }, skip: !haveIphoneFonts);
      }
    }

    testWidgets('AX5 imperial: a typed weight is not hidden behind its unit',
        (tester) async {
      await openSheet(tester, 'en', 3.118,
          settings: FakeSettings()..units = 'imperial');
      await tester.enterText(find.byKey(const Key('bodyWeightField')), '165.3');
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(find.descendant(
          of: find.byKey(const Key('bodyWeightField')),
          matching: find.byType(Scrollable)));
      expect(scrollable.position.maxScrollExtent, 0,
          reason: 'the whole value fits beside "lb"');
      expect(tester.takeException(), isNull);
    }, skip: !haveIphoneFonts);

    testWidgets('dark mode: fields use the in-sheet cell colour',
        (tester) async {
      await pumpApp(tester, BodyScreen(dao: FakeDao(), clock: () => clock),
          brightness: Brightness.dark);
      await tester.tap(find.byKey(const Key('logBodyButton')));
      await tester.pumpAndSettle();
      final field =
          tester.widget<TextField>(find.byKey(const Key('bodyWeightField')));
      expect(field.decoration!.fillColor, const Color(0xFF2C2C2E),
          reason: 'sheetCell; the page-cell #1C1C1E is the sheet itself');
    });
  });
}
