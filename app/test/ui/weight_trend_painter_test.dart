// WeightTrendPainter (run 7). B11: shouldRepaint compared only the count
// and the LAST point, so editing an older weigh-in left the old line on
// screen. It now compares every (date, kg) pair and everything it paints
// with. Also the label bands and the first/last date ticks (U18).
import 'dart:ui' as ui;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/widgets/weight_trend_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records where the painter draws its labels and lines. A label's size is
/// read when it is drawn: the painter disposes its paragraphs right after.
class _Recorder implements Canvas {
  final labels = <Rect>[];
  final lines = <(Offset, Offset)>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) =>
      labels.add(offset & Size(paragraph.longestLine, paragraph.height));

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  const four = [
    WeightEntry('2026-10-24', 72.0, source: 'manual'),
    WeightEntry('2026-10-26', 72.0, source: 'manual'),
    WeightEntry('2026-10-28', 71.8, source: 'manual'),
    WeightEntry('2026-10-30', 71.6, source: 'manual'),
  ];

  WeightTrendPainter painter({
    List<WeightEntry> entries = four,
    Color line = const Color(0xFFA64B2A),
    Color axis = const Color(0xFFC6C6C8),
    Color label = const Color(0xFF6C6C70),
    Color? dotRing = const Color(0xFFFFFFFF),
    TextStyle labelStyle = const TextStyle(fontSize: 11),
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    String? startLabel = 'Oct 24',
    String? endLabel = 'Oct 30',
    bool imperial = false,
  }) =>
      WeightTrendPainter(
        // A fresh list every time, as every reload builds one.
        entries: [...entries],
        line: line,
        axis: axis,
        label: label,
        dotRing: dotRing,
        labelStyle: labelStyle,
        textScaler: textScaler,
        textDirection: textDirection,
        startLabel: startLabel,
        endLabel: endLabel,
        imperial: imperial,
      );

  List<WeightEntry> withSecond(WeightEntry e) => [four[0], e, four[2], four[3]];

  group('shouldRepaint', () {
    test('false for an equal copy (a reload with the same data)', () {
      expect(painter().shouldRepaint(painter()), isFalse);
    });

    test('true when the 2nd of 4 entries changes its kg', () {
      final edited = painter(
          entries: withSecond(
              const WeightEntry('2026-10-26', 66.0, source: 'manual')));
      expect(edited.shouldRepaint(painter()), isTrue);
    });

    test('true when the 2nd of 4 entries changes its date', () {
      final edited = painter(
          entries: withSecond(
              const WeightEntry('2026-10-25', 72.0, source: 'manual')));
      expect(edited.shouldRepaint(painter()), isTrue);
    });

    test('true when the count changes', () {
      expect(painter(entries: four.sublist(1)).shouldRepaint(painter()),
          isTrue);
    });

    test('true for each paint input on its own', () {
      final base = painter();
      for (final (name, p) in [
        ('line', painter(line: const Color(0xFFF2A07B))),
        ('axis', painter(axis: const Color(0xFF38383A))),
        ('label', painter(label: const Color(0xFF98989F))),
        ('dotRing', painter(dotRing: const Color(0xFF1C1C1E))),
        ('labelStyle', painter(labelStyle: const TextStyle(fontSize: 13))),
        ('textScaler', painter(textScaler: const TextScaler.linear(2))),
        ('textDirection', painter(textDirection: TextDirection.rtl)),
        ('startLabel', painter(startLabel: 'Oct 23')),
        ('endLabel', painter(endLabel: '10月30日')),
        ('imperial', painter(imperial: true)),
      ]) {
        expect(p.shouldRepaint(base), isTrue, reason: name);
      }
    });
  });

  group('layout', () {
    test('the box grows with the (clamped) label scale', () {
      const style = TextStyle(fontSize: 11);
      final normal =
          WeightTrendPainter.preferredHeight(style, TextScaler.noScaling);
      final big = WeightTrendPainter.preferredHeight(
          style, const TextScaler.linear(3.1).clamp(maxScaleFactor: 2.0));
      expect(normal, greaterThan(WeightTrendPainter.plotHeight));
      expect(big, greaterThan(normal),
          reason: 'label bands are measured, not a fixed 14 px');
      expect(big - WeightTrendPainter.plotHeight,
          greaterThan(1.5 * (normal - WeightTrendPainter.plotHeight)),
          reason: 'the plot keeps its height; the label bands grow');
    });

    test('a year-long range with both date ticks paints without error', () {
      final year = [
        for (var i = 0; i < 365; i += 3)
          WeightEntry(
              DateTime.utc(2025, 11, 1)
                  .add(Duration(days: i))
                  .toIso8601String()
                  .substring(0, 10),
              70 + (i % 30) / 10,
              source: 'manual'),
      ];
      for (final scaler in const [
        TextScaler.noScaling,
        TextScaler.linear(2),
      ]) {
        final p = painter(
            entries: year,
            textScaler: scaler,
            startLabel: 'Nov 1, 2025',
            endLabel: 'Oct 30');
        const style = TextStyle(fontSize: 11);
        final size =
            Size(311, WeightTrendPainter.preferredHeight(style, scaler));
        final recorder = ui.PictureRecorder();
        p.paint(Canvas(recorder), size);
        recorder.endRecording().dispose();
      }
    });

    // The half-kilo domain floor lifts the lowest dot about 10 pt off the
    // baseline, and its label just under the dot was struck through by
    // the axis line ('71.6' on a typical week; run-7 E2E-1).
    group('value labels', () {
      const style = TextStyle(fontSize: 11);
      ({List<Rect> values, double baseline, double dateTop}) record(
          List<WeightEntry> entries,
          {TextScaler scaler = TextScaler.noScaling,
          double width = 311}) {
        final size = Size(width, WeightTrendPainter.preferredHeight(style, scaler));
        final canvas = _Recorder();
        painter(entries: entries, textScaler: scaler).paint(canvas, size);
        final dateTop =
            size.height - WeightTrendPainter.labelBand(style, scaler);
        return (
          values: [
            for (final r in canvas.labels)
              if (r.top < dateTop) r,
          ],
          baseline: canvas.lines.first.$1.dy,
          dateTop: dateTop,
        );
      }

      final week = [
        for (final (d, kg) in [
          // A 0.8 kg range: the domain floor pads 0.1 kg under the min,
          // about 10 pt over the baseline.
          ('2026-10-24', 72.4), ('2026-10-25', 72.1), ('2026-10-26', 72.2),
          ('2026-10-27', 71.9), ('2026-10-28', 71.8), ('2026-10-29', 72.0),
          ('2026-10-30', 71.6),
        ])
          WeightEntry(d, kg, source: 'manual'),
      ];

      for (final scaler in const [
        TextScaler.noScaling,
        TextScaler.linear(2),
      ]) {
        test('no label crosses the baseline (${scaler.scale(10) / 10}x)', () {
          for (final entries in [four, week]) {
            final r = record(entries, scaler: scaler);
            expect(r.values, hasLength(greaterThanOrEqualTo(2)));
            for (final label in r.values) {
              expect(label.top >= r.baseline || label.bottom <= r.baseline,
                  isTrue,
                  reason: '$label straddles the baseline at ${r.baseline}');
              expect(label.bottom, lessThanOrEqualTo(r.dateTop + 0.01),
                  reason: 'never in the date band');
            }
          }
        });
      }

      test('labels never overlap; the latest wins', () {
        // The min (71.0) right before the latest (71.1): their labels
        // meet in the band under the baseline on a narrow chart.
        final close = [
          const WeightEntry('2026-10-24', 72.0, source: 'manual'),
          const WeightEntry('2026-10-29', 71.0, source: 'manual'),
          const WeightEntry('2026-10-30', 71.1, source: 'manual'),
        ];
        final r = record(close, scaler: const TextScaler.linear(2), width: 160);
        for (var i = 0; i < r.values.length; i++) {
          for (var j = i + 1; j < r.values.length; j++) {
            expect(r.values[i].overlaps(r.values[j]), isFalse,
                reason: '${r.values[i]} vs ${r.values[j]}');
          }
        }
        expect(r.values.map((l) => l.right).reduce((a, b) => a > b ? a : b),
            closeTo(160, 0.01),
            reason: 'the latest, at the right edge, is the one kept');
      });
    });

    test('fewer than two points paint nothing (and do not throw)', () {
      final recorder = ui.PictureRecorder();
      painter(entries: four.sublist(3))
          .paint(Canvas(recorder), const Size(311, 160));
      recorder.endRecording().dispose();
    });
  });
}
