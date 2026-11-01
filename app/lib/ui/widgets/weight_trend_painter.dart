/// The Body tab's weight-trend chart painter. Split out of body_screen.dart.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../units.dart';

/// Weight over time: a line through date-proportional x positions (a gap in
/// logging shows as a long segment, not a lie of continuity), dots on the
/// data, selective labels on min / max / latest, and the first and last
/// dates under the baseline (U18: the window can be a week or a year).
///
/// Layout, top to bottom, each band one label line tall: the max label,
/// the plot, the min/latest labels, the dates. The bands are measured
/// from the label style at the caller's (clamped) text scale, so labels
/// never collide at large text sizes; [preferredHeight] gives the box.
class WeightTrendPainter extends CustomPainter {
  WeightTrendPainter({
    required this.entries,
    required this.line,
    required this.axis,
    required this.label,
    required this.textDirection,
    this.dotRing,
    this.labelStyle = const TextStyle(fontSize: 11),
    this.textScaler = TextScaler.noScaling,
    this.startLabel,
    this.endLabel,
    this.imperial = false,
  });

  final List<WeightEntry> entries; // ascending by date
  final Color line;
  final Color axis;

  /// The value and date labels' colour (over [labelStyle]).
  final Color label;

  /// A ring around each dot in the card colour, so dots read where the
  /// line runs through them; null draws plain dots.
  final Color? dotRing;

  /// caption2 at the call site; [label] supplies the colour.
  final TextStyle labelStyle;

  /// The caller clamps it (2.0x): chart labels may stop growing, the plot
  /// may not vanish under them.
  final TextScaler textScaler;

  /// The first and last dates, already formatted for display.
  final String? startLabel;
  final String? endLabel;
  final TextDirection textDirection;

  /// Label values convert to lb; geometry stays in kg (linear, so shape
  /// is identical either way).
  final bool imperial;

  /// The plot's own height; label bands are added around it.
  static const double plotHeight = 104;
  static const double _labelGap = 4;
  static const double _dotRadius = 3;
  static const double _ringWidth = 1.5;

  /// One label band: a label line plus its gap.
  static double labelBand(TextStyle style, TextScaler scaler) {
    final tp = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final h = tp.height;
    tp.dispose();
    return h + _labelGap;
  }

  /// The height that fits the plot and its three label bands.
  static double preferredHeight(TextStyle style, TextScaler scaler) =>
      plotHeight + 3 * labelBand(style, scaler);

  TextPainter _text(String text) => TextPainter(
        text: TextSpan(text: text, style: labelStyle.copyWith(color: label)),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.length < 2) return;
    final band = labelBand(labelStyle, textScaler);
    final hasDates = startLabel != null || endLabel != null;
    // Inset by a dot's reach so the end dots are not cut by the box.
    const reach = _dotRadius + _ringWidth;
    final plotBottom = math.max(
        band + 1, size.height - band - (hasDates ? band : 0));
    final plot = Rect.fromLTRB(reach, band, size.width - reach, plotBottom);

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
    canvas.drawLine(Offset(0, plot.bottom), Offset(size.width, plot.bottom),
        Paint()..color = axis..strokeWidth = 1);

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
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
    final ring = dotRing == null ? null : (Paint()..color = dotRing!);
    final dot = Paint()..color = line;
    for (var i = 0; i < entries.length; i++) {
      if (ring != null) canvas.drawCircle(at(i), reach, ring);
      canvas.drawCircle(at(i), _dotRadius, dot);
    }

    // Selective labels: min, max, latest (dedup indices). The max sits
    // above its dot, the others under theirs — never in the date band.
    // A label under its dot that would reach the baseline drops into the
    // band below it: the half-kilo domain floor lifts the lowest dot
    // about 10 pt off the baseline, and a label just under it was struck
    // through by the axis line. The latest is placed first and wins a
    // collision, as the latest date does below.
    var minI = 0, maxI = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] < values[minI]) minI = i;
      if (values[i] > values[maxI]) maxI = i;
    }
    final valueFloor = plot.bottom + band;
    final placed = <Rect>[];
    for (final i in {values.length - 1, maxI, minI}) {
      final tp =
          _text(weightForDisplay(values[i], imperial).toStringAsFixed(1));
      final p = at(i);
      final above = i == maxI;
      final x =
          (p.dx - tp.width / 2).clamp(0.0, math.max(0.0, size.width - tp.width))
              .toDouble();
      var y = above ? p.dy - tp.height - _labelGap : p.dy + _labelGap;
      if (!above && y + tp.height > plot.bottom - 1) {
        y = math.max(y, plot.bottom + _labelGap);
      }
      y = y.clamp(0.0, math.max(0.0, valueFloor - tp.height)).toDouble();
      final rect = Rect.fromLTWH(x, y, tp.width, tp.height);
      if (!placed.any((r) => r.inflate(_labelGap / 2).overlaps(rect))) {
        tp.paint(canvas, Offset(x, y));
        placed.add(rect);
      }
      tp.dispose();
    }

    // First and last dates, left- and right-aligned under the value band.
    // When both do not fit side by side, the latest wins.
    if (hasDates) {
      final start = startLabel == null ? null : _text(startLabel!);
      final end = endLabel == null ? null : _text(endLabel!);
      final y = size.height - band + _labelGap;
      final fitsBoth = start == null ||
          end == null ||
          start.width + end.width + 2 * _labelGap <= size.width;
      if (start != null && fitsBoth) start.paint(canvas, Offset(0, y));
      if (end != null) {
        end.paint(canvas, Offset(math.max(0.0, size.width - end.width), y));
      }
      start?.dispose();
      end?.dispose();
    }
  }

  /// Days since epoch for YYYY-MM-DD (UTC — only differences matter).
  static int _dayNumber(String date) =>
      DateTime.parse('${date}T00:00:00Z').millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  /// Compares the DATA, not its size (B11): editing an older weigh-in
  /// keeps the count and the last point, and the chart kept the old line
  /// while the history row showed the new value. WeightEntry has no ==,
  /// so the (date, kg) pairs are compared one by one — at most a year of
  /// points, and only when the card rebuilds.
  @override
  bool shouldRepaint(WeightTrendPainter old) {
    if (old.line != line ||
        old.axis != axis ||
        old.label != label ||
        old.dotRing != dotRing ||
        old.labelStyle != labelStyle ||
        old.textScaler != textScaler ||
        old.textDirection != textDirection ||
        old.imperial != imperial ||
        old.startLabel != startLabel ||
        old.endLabel != endLabel ||
        old.entries.length != entries.length) {
      return true;
    }
    for (var i = 0; i < entries.length; i++) {
      if (old.entries[i].date != entries[i].date ||
          old.entries[i].kg != entries[i].kg) {
        return true;
      }
    }
    return false;
  }
}
