// The Body tab (2026-08-02): weight history + waist/chest/hip. These pin
// the page's contract: latest values with honest deltas, a chart only when
// there is a trend to draw, prefilled edit (so the full-row upsert can't
// eat data), validation on the SHARED weight bounds, and delete confirm.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  final clock = DateTime(2026, 8, 2, 10);

  Future<FakeDao> pump(WidgetTester tester,
      {Map<String, double>? weights,
      List<BodyMeasurements> measurements = const []}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    weights?.forEach((date, kg) =>
        dao.weightsByDate[date] = WeightEntry(date, kg, source: 'manual'));
    for (final m in measurements) {
      dao.measurementsByDate[m.date] = m;
    }
    // UniqueKey: a second pump in the same test must get a FRESH State
    // (same-type widgets at the same position reuse state, skipping
    // initState and therefore the new dao's load).
    await tester.pumpWidget(MaterialApp(
        home: BodyScreen(key: UniqueKey(), dao: dao, clock: () => clock)));
    await tester.pumpAndSettle();
    return dao;
  }

  testWidgets('empty state invites logging and mentions the chat path',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('bodyEmpty')), findsOneWidget);
    expect(find.byKey(const Key('logBodyButton')), findsOneWidget);
  });

  testWidgets('latest weight is the headline; delta is against the previous '
      'entry', (tester) async {
    await pump(tester, weights: {'2026-07-28': 82.4, '2026-08-02': 81.6});
    expect(find.byKey(const Key('bodyWeightHeadline')), findsOneWidget);
    expect(find.text('81.6'), findsOneWidget);
    final delta = tester
        .widget<Text>(find.descendant(
            of: find.byKey(const Key('bodyWeightDelta')),
            matching: find.byType(Text)))
        .data!;
    expect(delta, contains('0.8'));
    expect(delta, contains('▼'), reason: '81.6 < 82.4 — direction in text');
  });

  testWidgets('one weigh-in renders no chart; two render the trend',
      (tester) async {
    await pump(tester, weights: {'2026-08-02': 81.6});
    expect(find.byKey(const Key('weightTrendChart')), findsNothing,
        reason: 'a single point is not a trend');
    await pump(tester, weights: {'2026-07-28': 82.4, '2026-08-02': 81.6});
    expect(find.byKey(const Key('weightTrendChart')), findsOneWidget);
  });

  testWidgets('measurements card shows per-metric latest even when days are '
      'sparse', (tester) async {
    await pump(tester, measurements: [
      const BodyMeasurements('2026-07-30', waistCm: 84, chestCm: 100),
      const BodyMeasurements('2026-08-02', waistCm: 83.5), // chest not taken
    ]);
    expect(find.text('83.5 cm'), findsOneWidget);
    expect(find.text('100 cm'), findsOneWidget,
        reason: 'a day without chest must not blank the chest series');
  });

  testWidgets('logging weight through the sheet saves with source manual '
      'and refreshes the page', (tester) async {
    final dao = await pump(tester);
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.6');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();

    expect(dao.weightsByDate['2026-08-02']?.kg, 81.6);
    expect(dao.weightsByDate['2026-08-02']?.source, 'manual');
    expect(find.text('81.6'), findsOneWidget, reason: 'page reloaded');
    expect(find.byKey(const Key('bodyEmpty')), findsNothing);
  });

  testWidgets('a weight outside the SHARED parity bounds is refused with '
      'the bounds named', (tester) async {
    final dao = await pump(tester);
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '500');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bodySheetError')), findsOneWidget);
    expect(find.textContaining('300'), findsOneWidget,
        reason: 'the message names the real bound (shared weightMaxKg)');
    expect(dao.weightsByDate, isEmpty);
  });

  testWidgets('an empty sheet save is refused', (tester) async {
    final dao = await pump(tester);
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bodySheetError')), findsOneWidget);
    expect(dao.weightsByDate, isEmpty);
    expect(dao.measurementsByDate, isEmpty);
  });

  testWidgets('editing a day PREFILLS, so an untouched field survives the '
      'full-row upsert', (tester) async {
    final dao = await pump(tester, measurements: [
      const BodyMeasurements('2026-08-02', waistCm: 84, chestCm: 100),
    ]);
    await tester.tap(find.byKey(const Key('bodyDay2026-08-02')));
    await tester.pumpAndSettle();
    // Change only the waist; chest must carry through via the prefill.
    await tester.enterText(find.byKey(const Key('bodyWaistField')), '83.5');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();

    final saved = dao.measurementsByDate['2026-08-02']!;
    expect(saved.waistCm, 83.5);
    expect(saved.chestCm, 100, reason: 'prefill preserved the untouched field');
  });

  testWidgets('clearing a prefilled weight on edit deletes that weigh-in',
      (tester) async {
    final dao = await pump(tester,
        weights: {'2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-08-02', waistCm: 84)]);
    await tester.tap(find.byKey(const Key('bodyDay2026-08-02')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isEmpty,
        reason: 'a cleared field really clears');
    expect(dao.measurementsByDate['2026-08-02']?.waistCm, 84);
  });

  testWidgets('SWIPE to delete asks first, then removes both tables for '
      'the day', (tester) async {
    // The trailing delete button became swipe-to-delete (Apple idiom,
    // polish loop cycle 1) — the confirm dialog still gates it.
    final dao = await pump(tester,
        weights: {'2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-08-02', waistCm: 84)]);
    await tester.drag(
        find.byKey(const Key('bodyDay2026-08-02')), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isNotEmpty, reason: 'nothing until confirmed');
    await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isEmpty);
    expect(dao.measurementsByDate, isEmpty);
    expect(find.byKey(const Key('bodyEmpty')), findsOneWidget);
  });

  testWidgets('history rows list newest first with the values inline',
      (tester) async {
    await pump(tester,
        weights: {'2026-07-28': 82.4, '2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-08-02', waistCm: 84)]);
    // Rows are grouped cells now, ordered by their bodyDay keys.
    expect(
        tester
            .getTopLeft(find.byKey(const Key('bodyDay2026-08-02')))
            .dy,
        lessThan(tester
            .getTopLeft(find.byKey(const Key('bodyDay2026-07-28')))
            .dy),
        reason: 'newest first');
    expect(find.textContaining('W 84'), findsOneWidget);
  });

  // ── Measurements rows at accessibility text sizes (2026-10-07) ────────
  // The row was label (fixed 64 px) + value + 'on {date}' + Spacer + delta,
  // none of which could shrink: at 1.64× (AX1) and 2× it overflowed the
  // card, clipping the ▲/▼ delta, and 'Waist' broke mid-word in its box.
  // Whether text fits depends on the glyphs (the test font is a full em
  // per glyph, far wider than the phone's), so this loads the iPhone's own
  // system fonts — macOS only, skipped elsewhere, as row_fit_layout_test.
  const sfPath = '/System/Library/Fonts/SFNS.ttf';
  const cjkPath = '/System/Library/Fonts/Hiragino Sans GB.ttc';
  final haveIphoneFonts =
      File(sfPath).existsSync() && File(cjkPath).existsSync();

  Future<void> loadFont(String family, String path) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(
          ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }

  group('measurements rows fit at large text sizes (SF + Hiragino)', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadFont('BodySF', sfPath);
      await loadFont('BodyHiragino', cjkPath);
    });

    for (final lang in const ['en', 'zh']) {
      for (final width in const [375.0, 390.0]) {
        for (final scale in const [1.64, 2.0]) {
          testWidgets('$lang at ${scale}x on a $width pt phone',
              (tester) async {
            tester.view.physicalSize = Size(width, 2400);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(
                tester.platformDispatcher.clearTextScaleFactorTestValue);
            final dao = FakeDao();
            for (final m in const [
              BodyMeasurements('2026-07-30',
                  waistCm: 84, chestCm: 100, hipCm: 98),
              BodyMeasurements('2026-08-02',
                  waistCm: 83.5, chestCm: 101.5, hipCm: 97.5),
            ]) {
              dao.measurementsByDate[m.date] = m;
            }
            await tester.pumpWidget(MaterialApp(
              locale: Locale(lang),
              theme: ThemeData(
                  fontFamily: 'BodySF',
                  fontFamilyFallback: const ['BodyHiragino']),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: BodyScreen(dao: dao, clock: () => clock),
            ));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull,
                reason: 'the old row overflowed the card at this size');

            final card = find.ancestor(
                of: find.byKey(const Key('bodyWaistLatest')),
                matching: find.byType(Card));
            final cardRect = tester.getRect(card);
            for (final (key, value, delta) in const [
              ('bodyWaistLatest', '83.5 cm', '▼ 0.5'),
              ('bodyChestLatest', '101.5 cm', '▲ +1.5'),
              ('bodyHipLatest', '97.5 cm', '▼ 0.5'),
            ]) {
              final valueFinder = find.byKey(Key(key));
              expect(tester.widget<Text>(valueFinder).data, value);
              final row = find.ancestor(
                      of: valueFinder, matching: find.byType(Row))
                  .first;
              final deltaFinder =
                  find.descendant(of: row, matching: find.text(delta));
              expect(deltaFinder, findsOneWidget,
                  reason: '$key keeps its direction glyph');
              final deltaRect = tester.getRect(deltaFinder);
              expect(deltaRect.right, lessThanOrEqualTo(cardRect.right),
                  reason: '$key: the delta stays inside the card');
              // Only the date may give way; the label, value and delta
              // read in full.
              for (final p in tester.renderObjectList<RenderParagraph>(
                  find.descendant(of: row, matching: find.byType(RichText)))) {
                final text = p.text.toPlainText();
                if (text.contains('2026')) continue;
                expect(p.didExceedMaxLines, isFalse,
                    reason: '"$text" must not be cut');
                expect(p.size.width,
                    greaterThanOrEqualTo(p.getMaxIntrinsicWidth(
                            double.infinity) -
                        0.5),
                    reason: '"$text" must not wrap mid-word');
              }
            }
          });
        }
      }
    }
  }, skip: haveIphoneFonts ? false : 'needs the macOS system fonts');
}
