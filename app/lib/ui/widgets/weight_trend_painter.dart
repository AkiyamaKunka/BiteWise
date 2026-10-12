/// The Body tab's weight-trend chart painter. Split out of body_screen.dart.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../units.dart';

/// Weight over time: a line through date-proportional x positions (a gap in
/// logging shows as a long segment, not a lie of continuity), dots on the
/// data, selective labels on min / max / latest.
class WeightTrendPainter extends CustomPainter {
  WeightTrendPainter({
    required this.entries,
    required this.line,
    required this.axis,
    required this.label,
    required this.textDirection,
    this.imperial = false,
  });

  final List<WeightEntry> entries; // ascending by date
  final Color line;
  final Color axis;
  final Color label;
  final TextDirection textDirection;

  /// Label values convert to lb; geometry stays in kg (linear, so shape
  /// is identical either way).
  final bool imperial;

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.length < 2) return;
    const pad = 14.0; // label headroom top + bottom
    final plot = Rect.fromLTWH(0, pad, size.width, size.height - 2 * pad);

    final days = [for (final e in entries) _dayNumber(e.date)];
    final minDay = days.first, maxDay = days.last;
    final span = math.max(1, maxDay - minDay);
    final values = [for (final e in entries) e.kg];
    var minV = values.reduce(math.min), maxV = values.reduce(math.max);
    // Half-kilo floor on the domain: a flat week must read flat, not as
    // dramatic swings across a 0.1 kg range.
    if (maxV - minV < 1.0) {
      final mid = (maxV + minV) / 2;
      minV = mid - 0.5;
      maxV = mid + 0.5;
    }

    Offset at(int i) {
      final x = plot.left + (days[i] - minDay) / span * plot.width;
      final y = plot.bottom -
          (values[i] - minV) / (maxV - minV) * plot.height;
      return Offset(x, y);
    }

    // Recessive baseline.
    canvas.drawLine(Offset(plot.left, plot.bottom),
        Offset(plot.right, plot.bottom), Paint()..color = axis..strokeWidth = 1);

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < entries.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
    final dot = Paint()..color = line;
    for (var i = 0; i < entries.length; i++) {
      canvas.drawCircle(at(i), 3, dot);
    }

    // Selective labels: min, max, latest (dedup indices).
    var minI = 0, maxI = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] < values[minI]) minI = i;
      if (values[i] > values[maxI]) maxI = i;
    }
    for (final i in {minI, maxI, values.length - 1}) {
      final tp = TextPainter(
        text: TextSpan(
            text: weightForDisplay(values[i], imperial).toStringAsFixed(1),
            style: TextStyle(fontSize: 10, color: label)),
        textDirection: textDirection,
      )..layout();
      final p = at(i);
      final above = i == maxI; // max labels above the dot, others below
      final x =
          p.dx.clamp(0.0, math.max(0.0, size.width - tp.width)).toDouble();
      final y = (above ? p.dy - tp.height - 5 : p.dy + 5)
          .clamp(0.0, size.height - tp.height)
          .toDouble();
      tp.paint(canvas, Offset(x, y));
    }
  }

  /// Days since epoch for YYYY-MM-DD (UTC — only differences matter).
  static int _dayNumber(String date) =>
      DateTime.parse('${date}T00:00:00Z').millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  @override
  bool shouldRepaint(WeightTrendPainter old) =>
      old.entries.length != entries.length ||
      old.line != line ||
      old.imperial != imperial ||
      (entries.isNotEmpty &&
          old.entries.isNotEmpty &&
          (old.entries.last.date != entries.last.date ||
              old.entries.last.kg != entries.last.kg));
}
