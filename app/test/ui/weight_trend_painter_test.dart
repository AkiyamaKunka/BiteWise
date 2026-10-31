// WeightTrendPainter (run 7). B11: shouldRepaint compared only the count
// and the LAST point, so editing an older weigh-in left the old line on
// screen. It now compares every (date, kg) pair and everything it paints
// with. Also the label bands and the first/last date ticks (U18).
import 'dart:ui' as ui;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/widgets/weight_trend_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('fewer than two points paint nothing (and do not throw)', () {
      final recorder = ui.PictureRecorder();
      painter(entries: four.sublist(3))
          .paint(Canvas(recorder), const Size(311, 160));
      recorder.endRecording().dispose();
    });
  });
}
