// The History screen in the run-7 design (lane history-charts-share).
//
// - A12: the calorie trend reserved a 16-pt × text-scale band UNDER its
//   bars that stayed blank, and drew the peak label ABOVE the tallest bar
//   inside the plot, so from about 1.3x text the digits sat on the bar
//   (about 1:1 in dark mode). The label band is now above the plot, labels
//   clear every bar at every text size, and the only band below the bars
//   holds the date axis.
// - A3: at accessibility text sizes a day row's trailing kcal kept its
//   full width, so the date got 11 pt in zh on an SE ('今/天', rows 570 pt
//   tall) and a gap day's 'no meals logged' left the date no width at all
//   ('Trailing widget consumes the entire tile width'). The value now sits
//   under the date there.
// - The rows are grouped cells (buttons to VoiceOver), the empty and error
//   states are the shared ones, and the average reads as the card's
//   headline with its pinned plain text unchanged.
import 'dart:ui' as ui;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/screens/history_screen.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart';
import 'package:calorie_tracker/ui/widgets/macro_chart.dart';
import 'package:calorie_tracker/ui/widgets/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, SemanticsAction;
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

Meal _meal(String date, {num cal = 500, int id = 0}) => Meal(
      id: id,
      date: date,
      time: '12:00 PM',
      timestamp: '${date}T12:00:00.000',
      source: 'app_watch',
      imageHash: 'h$date$id',
      analysis: {'is_food': true, 'total_calories': cal},
    );

String _daysAgo(int n) => isoDate(DateTime.now().subtract(Duration(days: n)));

FakeDao _dao(Map<int, num> kcalByDaysAgo) {
  final dao = FakeDao();
  var id = 1;
  kcalByDaysAgo.forEach((ago, cal) {
    dao.meals.add(_meal(_daysAgo(ago), cal: cal, id: id++));
  });
  return dao;
}

class _FailingDao extends FakeDao {
  bool fail = true;
  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) async {
    if (fail) throw StateError('disk I/O error');
    return super.mealsBetween(startDate, endDate);
  }
}

/// What the trend chart painted, read back from a recording canvas.
class _Painted {
  _Painted(this.size, this.bars, this.labels, this.backings);
  final Size size;
  final List<Rect> bars;

  /// Every paragraph (value labels above the baseline, axis labels below).
  final List<Rect> labels;
  final List<Rect> backings;

  double get baseline => bars.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
  List<Rect> get valueLabels =>
      labels.where((r) => r.bottom <= baseline + 0.01).toList();
  List<Rect> get axisLabels =>
      labels.where((r) => r.top >= baseline - 0.01).toList();
}

/// Records each paragraph's box while it is drawn: the painter disposes
/// its TextPainters (and their paragraphs) once it is done.
class _Canvas extends TestRecordingCanvas {
  final paragraphs = <Rect>[];
  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add(offset & Size(paragraph.longestLine, paragraph.height));
    super.drawParagraph(paragraph, offset);
  }
}

_Painted _paintedChart(WidgetTester tester) {
  final finder = find.byKey(const Key('calorieTrendChart'));
  final painter = tester.widget<CustomPaint>(finder).painter!;
  final size = tester.getSize(finder);
  final canvas = _Canvas();
  painter.paint(canvas, size);
  final accent = AppColors.light.accent;
  final bars = <Rect>[];
  final backings = <Rect>[];
  final labels = <Rect>[];
  for (final call in canvas.invocations) {
    final inv = call.invocation;
    if (inv.memberName == #drawRRect) {
      final rect = (inv.positionalArguments[0] as RRect).outerRect;
      final paint = inv.positionalArguments[1] as Paint;
      // Paint keeps float components: compare the 32-bit values.
      (paint.color.toARGB32() == accent.toARGB32() ? bars : backings)
          .add(rect);
    }
  }
  labels.addAll(canvas.paragraphs);
  return _Painted(size, bars, labels, backings);
}

Future<void> _pumpChart(WidgetTester tester, Map<String, num> totals,
    {double scale = 1.0, double width = 300}) async {
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: CalorieTrendChart(dayTotals: totals),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  setUpAll(loadIphoneFonts);

  group('trendChartLayout', () {
    test('the label band is ABOVE the plot and nothing blank is left below',
        () {
      final l = trendChartLayout(const Size(300, 200), labelHeight: 13);
      expect(l.labelBand, const Rect.fromLTWH(0, 0, 300, 17));
      expect(l.plot, const Rect.fromLTRB(0, 17, 300, 200));
      expect(l.axisBand.height, 0, reason: 'no axis → no band at all');
    });

    test('with a date axis the band below is exactly one label plus its gap',
        () {
      final l = trendChartLayout(const Size(300, 200),
          labelHeight: 13, axisLabelHeight: 13);
      expect(l.plot, const Rect.fromLTRB(0, 17, 300, 183));
      expect(l.axisBand, const Rect.fromLTRB(0, 183, 300, 200));
      expect(
          trendChartHeight(132, labelHeight: 13, axisLabelHeight: 13), 166,
          reason: 'the plot keeps its 132 pt; the bands are added around it');
    });

    test('a degenerate size never yields a negative plot', () {
      final l = trendChartLayout(const Size(10, 5),
          labelHeight: 26, axisLabelHeight: 26);
      expect(l.plot.height, greaterThan(0));
      expect(l.axisBand.height, greaterThanOrEqualTo(0));
    });
  });

  group('value labels never sit on a bar', () {
    for (final scale in const [1.0, 2.0, 3.1]) {
      testWidgets('at ${scale}x text', (tester) async {
        await _pumpChart(tester, const {
          '2026-10-01': 1000,
          '2026-10-02': 3000,
          '2026-10-03': 2000,
        }, scale: scale);
        final p = _paintedChart(tester);
        expect(p.bars, hasLength(3));
        expect(p.valueLabels, hasLength(2), reason: 'the peak and the latest');
        for (final label in p.valueLabels) {
          expect(label.top, greaterThanOrEqualTo(0));
          for (final bar in p.bars) {
            expect(label.overlaps(bar), isFalse,
                reason: 'label $label lands on bar $bar at ${scale}x');
          }
        }
        // The tallest bar reaches the label band: no blank strip above it
        // either, just its label.
        final peak = p.bars.reduce((a, b) => a.height > b.height ? a : b);
        final peakLabel = p.valueLabels
            .reduce((a, b) => (a.center.dx - peak.center.dx).abs() <
                    (b.center.dx - peak.center.dx).abs()
                ? a
                : b);
        expect(peak.top - peakLabel.bottom, inInclusiveRange(1.5, 2.5));
      });
    }

    testWidgets('labels are clamped at 2x: AX5 does not eat the plot',
        (tester) async {
      const totals = {'2026-10-01': 1000, '2026-10-02': 3000};
      await _pumpChart(tester, totals, scale: 2.0);
      final at2 = _paintedChart(tester);
      await _pumpChart(tester, totals, scale: 3.1);
      final at31 = _paintedChart(tester);
      expect(at31.size.height, at2.size.height);
      expect(at31.valueLabels.first.height, at2.valueLabels.first.height);
      // The bars keep the full 132-pt plot at every size.
      final tallest =
          at31.bars.map((r) => r.height).reduce((a, b) => a > b ? a : b);
      expect(tallest, moreOrLessEquals(132, epsilon: 0.01));
    });

    testWidgets('dense month: a label never covers a neighbouring bar or the '
        'other label', (tester) async {
      // 30 slots in 300 pt: a 10-pt slot under a ~30-pt label. The peak
      // and the latest day are neighbours, as on the owner's History.
      final totals = <String, num>{
        for (var i = 1; i <= 30; i++)
          '2026-09-${i.toString().padLeft(2, '0')}': 1500 + (i * 37) % 600,
      };
      totals['2026-09-29'] = 2575;
      totals['2026-09-30'] = 1751;
      await _pumpChart(tester, totals);
      final p = _paintedChart(tester);
      expect(p.bars, hasLength(30));
      for (final label in p.valueLabels) {
        for (final bar in p.bars) {
          expect(label.overlaps(bar), isFalse);
        }
        for (final other in p.valueLabels) {
          if (!identical(label, other)) expect(label.overlaps(other), isFalse);
        }
      }
      expect(p.valueLabels, isNotEmpty, reason: 'the peak is always labelled');
    });

    testWidgets('label values read like every other total: 2,575 not 2575 '
        '(L3)', (tester) async {
      await _pumpChart(tester, const {'2026-10-01': 2575, '2026-10-02': 0});
      final painter = tester
          .widget<CustomPaint>(find.byKey(const Key('calorieTrendChart')))
          .painter! as dynamic;
      double widthOf(String text) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: painter.labelStyle as TextStyle),
          textDirection: TextDirection.ltr,
          textScaler: painter.textScaler as TextScaler,
        )..layout();
        final w = tp.width;
        tp.dispose();
        return w;
      }

      final p = _paintedChart(tester);
      expect(p.valueLabels, hasLength(1));
      // The test font draws every glyph one em wide, so the separator
      // shows up as width.
      expect(p.valueLabels.single.width, widthOf('2,575'));
      expect(widthOf('2,575'), isNot(widthOf('2575')));
    });
  });

  group('the band under the bars holds the date axis and nothing else', () {
    testWidgets('first day at the left, Today at the right', (tester) async {
      final totals = {_daysAgo(6): 900, _daysAgo(3): 1200, _daysAgo(0): 400};
      await _pumpChart(tester, totals);
      final p = _paintedChart(tester);
      expect(p.axisLabels, hasLength(2));
      final left = p.axisLabels.reduce((a, b) => a.left < b.left ? a : b);
      final right = p.axisLabels.reduce((a, b) => a.left > b.left ? a : b);
      expect(left.left, 0);
      expect(right.right, moreOrLessEquals(p.size.width, epsilon: 0.5));
      // The band is exactly the axis line: label + gap, filled by labels.
      expect(p.size.height - p.baseline,
          moreOrLessEquals(left.height + kTrendLabelGap, epsilon: 0.01));
      expect(left.bottom, moreOrLessEquals(p.size.height, epsilon: 0.01));
    });

    testWidgets('one day: only its own label, no colliding pair',
        (tester) async {
      await _pumpChart(tester, {_daysAgo(0): 400});
      final p = _paintedChart(tester);
      expect(p.axisLabels, hasLength(1));
    });
  });

  group('History screen', () {
    testWidgets('day rows are grouped cells that read as buttons',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, Scaffold(body: HistoryScreen(dao: _dao({0: 650, 2: 1800}))),
          size: const Size(390, 1400));
      expect(
          find.ancestor(
              of: find.byKey(Key('historyDay${_daysAgo(0)}')),
              matching: find.byType(GroupedSection)),
          findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      for (final ago in const [0, 1, 2]) {
        final data = tester
            .getSemantics(find.byKey(Key('historyDay${_daysAgo(ago)}')))
            .getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue, reason: '$ago days ago');
        expect(data.hasAction(SemanticsAction.tap), isTrue);
      }
      // The row reads its day and its value, once.
      final today = tester
          .getSemantics(find.byKey(Key('historyDay${_daysAgo(0)}')))
          .getSemanticsData();
      expect(today.label, contains('Today'));
      expect(today.label, contains('~650 kcal'));
      expect(RegExp('650').allMatches(today.label), hasLength(1));
      handle.dispose();
    });

    testWidgets('the average is the card headline; its plain text is the '
        'pinned string', (tester) async {
      await pumpApp(tester,
          Scaffold(body: HistoryScreen(dao: _dao({0: 1900, 1: 1918}))));
      final avg = tester.widget<Text>(find.byKey(const Key('historyAverage')));
      expect(avg.textSpan!.toPlainText(), 'Average: ~1,909 kcal / day');
      expect(find.text('Average: ~1,909 kcal / day'), findsOneWidget);
      final number = (avg.textSpan! as TextSpan)
          .children!
          .whereType<TextSpan>()
          .singleWhere((s) => s.text == '1,909');
      expect(number.style!.fontWeight, FontWeight.w600);
      expect(number.style!.fontFeatures,
          contains(const FontFeature.tabularFigures()));
      // Above the chart, inside the same card.
      expect(
          tester.getRect(find.byKey(const Key('historyAverage'))).bottom,
          lessThan(tester
              .getRect(find.byKey(const Key('calorieTrendChart')))
              .top));
    });

    testWidgets('empty History is the shared EmptyState, text centred inside '
        'the gutters', (tester) async {
      await pumpApp(tester, Scaffold(body: HistoryScreen(dao: FakeDao())),
          size: const Size(375, 667), scale: 3.1);
      expect(find.byType(EmptyState), findsOneWidget);
      final text = find.text('No meals logged in the past 30 days.');
      expect(text, findsOneWidget);
      expect(tester.widget<Text>(text).textAlign, TextAlign.center);
      final r = tester.getRect(text);
      expect(r.left, greaterThanOrEqualTo(24));
      expect(r.right, lessThanOrEqualTo(375 - 24));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed load shows the user sentence, and Retry reloads',
        (tester) async {
      final dao = _FailingDao();
      dao.meals.add(_meal(_daysAgo(0), cal: 650, id: 1));
      await pumpApp(tester, Scaffold(body: HistoryScreen(dao: dao)));
      expect(find.byType(InlineError), findsOneWidget);
      expect(find.text("Couldn't load your history."), findsOneWidget);
      expect(find.textContaining('disk I/O'), findsNothing,
          reason: 'the raw error belongs in the log');
      dao.fail = false;
      await tester.tap(find.byKey(const Key('historyRetry')));
      await tester.pumpAndSettle();
      expect(find.byType(InlineError), findsNothing);
      expect(find.byKey(Key('historyDay${_daysAgo(0)}')), findsOneWidget);
    });

    testWidgets('zh: the error sentence is Chinese', (tester) async {
      await pumpApp(tester, Scaffold(body: HistoryScreen(dao: _FailingDao())),
          locale: const Locale('zh'));
      expect(find.text('无法加载历史记录。'), findsOneWidget);
    });
  });

  // A3, measured with the iPhone's own fonts (macOS only).
  group('day rows at accessibility text sizes', () {
    for (final (locale, width) in const [
      (Locale('en'), 375.0),
      (Locale('zh'), 375.0),
      (Locale('en'), 390.0),
      (Locale('zh'), 390.0),
    ]) {
      testWidgets('$locale at 3.1x on $width pt: the date keeps the row, the '
          'value sits under it', (tester) async {
        // Yesterday is a gap day: its 'no meals logged' used to take the
        // whole tile (en) or squeeze the date to a glyph a line (zh).
        await pumpApp(
            tester,
            Scaffold(
                body: HistoryScreen(
                    dao: _dao({0: 2140, 2: 1585, 3: 1990}))),
            size: Size(width, 2600),
            locale: locale,
            scale: 3.1);
        expect(tester.takeException(), isNull);
        for (final ago in const [0, 1, 2]) {
          final row = find.byKey(Key('historyDay${_daysAgo(ago)}'));
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final rowRect = tester.getRect(row);
          final title = tester.renderObject<RenderParagraph>(find
              .descendant(of: row, matching: find.byType(RichText))
              .first);
          expect(title.constraints.maxWidth,
              greaterThanOrEqualTo(rowRect.width / 2),
              reason: '$ago days ago: the date must keep the row');
          // Every line of text in the row lays out without clipping.
          for (final e in find
              .descendant(of: row, matching: find.byType(RichText))
              .evaluate()) {
            final para = e.renderObject! as RenderParagraph;
            expect(para.didExceedMaxLines, isFalse);
            expect(para.size.width, lessThanOrEqualTo(rowRect.width));
          }
        }
      }, skip: !haveIphoneFonts);
    }

    testWidgets('zh at 3.1x: a two-line value breaks between the number '
        'and 千卡, never inside the unit', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(
          tester, Scaffold(body: HistoryScreen(dao: _dao({0: 1751}))),
          size: const Size(375, 1400),
          locale: const Locale('zh'),
          scale: 3.1);
      final row = find.byKey(Key('historyDay${_daysAgo(0)}'));
      final unit = find.descendant(of: row, matching: find.text('千卡'));
      expect(unit, findsOneWidget, reason: 'the unit is one unbreakable run');
      expect(find.descendant(of: row, matching: find.text('~1,751')),
          findsOneWidget);
      final para = tester.renderObject<RenderParagraph>(find.descendant(
          of: unit, matching: find.byType(RichText)));
      final oneLine = para.getMaxIntrinsicHeight(double.infinity);
      expect(para.size.height, moreOrLessEquals(oneLine, epsilon: 0.5));
      // VoiceOver still hears one value.
      final label = tester.getSemantics(row).getSemanticsData().label;
      expect(label, contains('~1,751 千卡'));
      expect(RegExp('1,751').allMatches(label), hasLength(1));
      handle.dispose();
    }, skip: !haveIphoneFonts);

    testWidgets('at the default size the value stays trailing, beside the '
        'date', (tester) async {
      await pumpApp(tester, Scaffold(body: HistoryScreen(dao: _dao({0: 2140}))));
      final row = find.byKey(Key('historyDay${_daysAgo(0)}'));
      final date = tester.getRect(find.text('Today'));
      final value = tester.getRect(find.text('~2,140 kcal'));
      expect(value.left, greaterThan(date.right));
      expect((value.center.dy - date.center.dy).abs(), lessThan(12));
      expect(tester.getRect(row).height, lessThan(80));
    });
  });

  testWidgets('MacroBreakdownBar keeps its API; the bar is a 10-pt capsule',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MacroBreakdownBar(proteinG: 20, carbsG: 50, fatG: 10),
      ),
    ));
    expect(tester.getSize(find.byKey(const Key('macroBar'))).height, 10);
    expect(find.byKey(const Key('macroLegend')), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MacroBreakdownBar(proteinG: 0, carbsG: 0, fatG: 0, height: 12),
      ),
    ));
    expect(find.byKey(const Key('macroBarEmpty')), findsOneWidget);
  });
}
