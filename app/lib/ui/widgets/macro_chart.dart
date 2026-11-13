/// Charts for the meal detail / history screens.
///
/// Hand-drawn with CustomPainter — no chart dependency (the app ships to
/// phones on a metered build pipeline; a 3-mark chart does not justify a
/// package). Design rules applied from the dataviz guidance:
///   - categorical hues in FIXED order, taken from the validated reference
///     palette's first three slots (all-pairs CVD-safe in both modes);
///     protein=blue, carbs=orange, fat=aqua, never cycled or reordered.
///   - identity is never colour-alone: every segment carries a direct label
///     and the legend is always present (the light-mode aqua step sits under
///     3:1 on-surface contrast, so the relief rule requires visible labels).
///   - dark mode uses its OWN steps from the same ramps, not a flipped fill.
///   - thin marks, 2px surface gaps between fills, 4px rounded data ends,
///     recessive axes, selective (not per-point) value labels.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../app_formats.dart';
import '../format.dart' show formatKcal, formatOneDecimal, isoDate;
import '../l10n.dart';
import '../theme/tokens.dart';

/// Macro identity colours. Index order is the contract — callers must not
/// reassign hues per screen (colour follows the entity, never its rank).
class MacroPalette {
  const MacroPalette({
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final Color protein;
  final Color carbs;
  final Color fat;

  static const MacroPalette light = MacroPalette(
    protein: Color(0xFF2A78D6),
    carbs: Color(0xFFEB6834),
    fat: Color(0xFF1BAF7A),
  );

  static const MacroPalette dark = MacroPalette(
    protein: Color(0xFF3987E5),
    carbs: Color(0xFFD95926),
    fat: Color(0xFF199E70),
  );

  static MacroPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// Energy per gram (Atwater): the macro bar segments by CALORIE share, not
/// gram share — 1 g of fat carries 2.25× the energy of 1 g of protein, so a
/// gram-proportional bar would misstate what the meal is made of.
const num kcalPerGramProtein = 4;
const num kcalPerGramCarbs = 4;
const num kcalPerGramFat = 9;

/// One macro's contribution, already resolved to grams + energy.
class MacroSlice {
  const MacroSlice(this.label, this.grams, this.kcal, this.color);
  final String label;
  final num grams;
  final num kcal;
  final Color color;
}

/// [labels] are the localized macro names (protein, carbs, fat) — the
/// chart is used inside meal surfaces, so these MUST follow the app
/// language (user report 2026-08-06: they stayed English in zh).
List<MacroSlice> macroSlices({
  required num proteinG,
  required num carbsG,
  required num fatG,
  required MacroPalette palette,
  (String, String, String) labels = ('Protein', 'Carbs', 'Fat'),
}) =>
    [
      MacroSlice(labels.$1, proteinG, proteinG * kcalPerGramProtein,
          palette.protein),
      MacroSlice(labels.$2, carbsG, carbsG * kcalPerGramCarbs, palette.carbs),
      MacroSlice(labels.$3, fatG, fatG * kcalPerGramFat, palette.fat),
    ];

/// Horizontal stacked bar: what this meal's energy is made of.
///
/// Falls back to an explanatory line when every macro is zero/unknown — an
/// empty axis with no marks reads as a rendering bug.
class MacroBreakdownBar extends StatelessWidget {
  const MacroBreakdownBar({
    super.key,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    this.height = 10,
  });

  final num proteinG;
  final num carbsG;
  final num fatG;

  /// The bar's thickness; its ends are rounded to half of it (a capsule).
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final l = context.l10n;
    final slices = macroSlices(
      labels: (l.macroProtein, l.macroCarbs, l.macroFat),
      proteinG: math.max(0, proteinG),
      carbsG: math.max(0, carbsG),
      fatG: math.max(0, fatG),
      palette: MacroPalette.of(context),
    );
    final totalKcal = slices.fold<num>(0, (a, s) => a + s.kcal);
    if (totalKcal <= 0) {
      return Text(context.l10n.macroNoBreakdown,
          key: const Key('macroBarEmpty'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: colors.secondaryLabel));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            key: const Key('macroBar'),
            painter: _StackedBarPainter(
              slices: slices,
              gap: 2, // the cell shows through between fills
              radius: height / 2, // capsule ends
              surface: colors.cell,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Legend + direct labels in one row: identity never rests on colour,
        // and the numbers wear text tokens rather than the series colour.
        Wrap(
          key: const Key('macroLegend'),
          spacing: 14,
          runSpacing: 4,
          children: [
            for (final s in slices)
              _LegendEntry(
                color: s.color,
                text: '${s.label} ${formatOneDecimal(s.grams)} g'
                    ' · ${(s.kcal / totalKcal * 100).round()}%',
              ),
          ],
        ),
      ],
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration:
              BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        // Flexible: the Wrap caps each entry at its own width, but an
        // unflexed Text ignored that, so at the largest text sizes an entry
        // wider than the card ran its percentage past the edge (RenderFlex
        // overflow). Now that one entry wraps onto a second line instead.
        Flexible(
          child: Text(text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.of(context).secondaryLabel)),
        ),
      ],
    );
  }
}

class _StackedBarPainter extends CustomPainter {
  _StackedBarPainter({
    required this.slices,
    required this.gap,
    required this.radius,
    required this.surface,
  });

  final List<MacroSlice> slices;
  final double gap;
  final double radius;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    final visible = slices.where((s) => s.kcal > 0).toList();
    if (visible.isEmpty) return;
    final total = visible.fold<num>(0, (a, s) => a + s.kcal);
    // Reserve the inter-segment gaps so the stack still spans exactly the
    // full width (segments must not drift past the axis).
    final gaps = gap * (visible.length - 1);
    final usable = math.max(0.0, size.width - gaps);
    var x = 0.0;
    for (var i = 0; i < visible.length; i++) {
      final s = visible[i];
      final w = usable * (s.kcal / total);
      final isFirst = i == 0;
      final isLast = i == visible.length - 1;
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, 0, w, size.height),
        // Only the outer ends of the whole stack are rounded; interior
        // joins stay square so the bar reads as one quantity.
        topLeft: Radius.circular(isFirst ? radius : 0),
        bottomLeft: Radius.circular(isFirst ? radius : 0),
        topRight: Radius.circular(isLast ? radius : 0),
        bottomRight: Radius.circular(isLast ? radius : 0),
      );
      canvas.drawRRect(rect, Paint()..color = s.color);
      x += w + gap;
    }
  }

  @override
  bool shouldRepaint(_StackedBarPainter old) =>
      old.surface != surface ||
      old.slices.length != slices.length ||
      List.generate(slices.length, (i) => i).any((i) =>
          old.slices[i].kcal != slices[i].kcal ||
          old.slices[i].color != slices[i].color);
}


/// The calorie trend chart's geometry, from its [size] and the height of
/// one (scaled) value label:
///
///  * [labelBand] runs along the TOP: the value labels sit above their
///    bars, and the tallest bar reaches up to the band's bottom edge, so a
///    label always has room and never lands on a bar.
///  * [plot] holds the bars, which rise from its bottom edge (the
///    baseline).
///  * [axisBand] under the baseline holds the date axis, or is empty
///    (zero height) when [axisLabelHeight] is 0.
///
/// Nothing else is reserved. Before run 7 a 16-pt × text-scale strip under
/// the bars stayed blank while the peak label was drawn over the tallest
/// bar from about 1.3x text up (A12).
typedef TrendChartLayout = ({Rect labelBand, Rect plot, Rect axisBand});

/// The gap between a label and the bar or baseline it belongs to.
const double kTrendLabelGap = 4;

TrendChartLayout trendChartLayout(
  Size size, {
  required double labelHeight,
  double axisLabelHeight = 0,
}) {
  final top = labelHeight + kTrendLabelGap;
  final bottom = axisLabelHeight > 0 ? axisLabelHeight + kTrendLabelGap : 0.0;
  final plotBottom = math.max(top + 1, size.height - bottom);
  return (
    labelBand: Rect.fromLTWH(0, 0, size.width, top),
    plot: Rect.fromLTRB(0, top, size.width, plotBottom),
    axisBand: Rect.fromLTRB(
        0, plotBottom, size.width, math.max(plotBottom, size.height)),
  );
}

/// The total height [trendChartLayout] needs for a [plotHeight]-tall plot.
double trendChartHeight(
  double plotHeight, {
  required double labelHeight,
  double axisLabelHeight = 0,
}) =>
    labelHeight +
    kTrendLabelGap +
    plotHeight +
    (axisLabelHeight > 0 ? axisLabelHeight + kTrendLabelGap : 0);

/// Daily calorie bars over a date window, newest at the right, with the
/// average as a reference line. Single series → one hue, no legend (the
/// title names it); value labels only on the peak and the latest day, and
/// a quiet date axis: the first day at the left, Today (or the last day)
/// at the right.
class CalorieTrendChart extends StatelessWidget {
  const CalorieTrendChart({
    super.key,
    required this.dayTotals,
    this.height = 132,
    this.onDayTap,
    this.average,
  });

  /// date (YYYY-MM-DD) → kcal. Rendered in ascending date order, one
  /// equal slot per entry — a caller that wants calendar gaps visible
  /// passes them as 0 (an empty slot, no bar, no label).
  final Map<String, num> dayTotals;

  /// The PLOT's height, where the bars are. The value labels get a band
  /// above it and the date axis one below, both sized from the text scale
  /// (clamped at 2x), so the bars keep their height at every text size.
  final double height;
  final void Function(String date)? onDayTap;

  /// The dashed reference line's value. Null → mean of every entry. A
  /// caller that pads gap days with 0 passes its own mean so the line
  /// still matches the days-with-data average it prints.
  final num? average;

  /// Chart labels follow Dynamic Type up to 2x; past that they would eat
  /// the plot (design spec: text never shrinks except in the ring and
  /// chart labels).
  static const double maxLabelScale = 2.0;

  @override
  Widget build(BuildContext context) {
    if (dayTotals.isEmpty) return const SizedBox.shrink();
    final colors = AppColors.of(context);
    final l = context.l10n;
    final dates = dayTotals.keys.toList()..sort();
    final values = [for (final d in dates) math.max(0, dayTotals[d]!)];
    final maxV = values.fold<num>(0, math.max);
    final avg = average?.toDouble() ??
        values.fold<num>(0, (a, b) => a + b) / values.length;
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: maxLabelScale);
    final labelStyle = AppTypography.of(context)
        .caption2
        .copyWith(color: colors.secondaryLabel);
    final probe = TextPainter(
      text: TextSpan(text: '0', style: labelStyle),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    final labelHeight = probe.height;
    probe.dispose();
    // The date axis: where the span starts, and where it ends — 'Today'
    // when it ends today, as it always does on History.
    final endLabel = dates.last == isoDate(DateTime.now())
        ? l.tabToday
        : AppFormats.shortDate(context, dates.last);
    final startLabel =
        dates.length > 1 ? AppFormats.shortDate(context, dates.first) : null;
    final totalHeight = trendChartHeight(height,
        labelHeight: labelHeight, axisLabelHeight: labelHeight);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          // Sighted taps only. A screen reader's tap is synthesized at the
          // box CENTRE, so it opened whichever day sat in the middle slot —
          // and the action merged into the caption below, making
          // "平均：约 … 千卡 / 天" an activatable element that opened an
          // arbitrary day. The day rows under the chart are the accessible
          // drill-down.
          excludeFromSemantics: true,
          onTapUp: onDayTap == null
              ? null
              : (details) {
                  final i = _indexAt(details.localPosition.dx, width, dates.length);
                  if (i != null) onDayTap!(dates[i]);
                },
          child: SizedBox(
            height: totalHeight,
            width: width,
            child: CustomPaint(
              key: const Key('calorieTrendChart'),
              painter: _TrendPainter(
                values: values,
                maxValue: maxV,
                average: avg,
                // The accent, NOT protein blue: colour follows the ENTITY
                // (this file's own header rule) — day-kcal is the accent
                // on the ring, the day rows, and here.
                bar: colors.accent,
                baseline: colors.separator,
                averageLine: colors.tertiaryLabel,
                labelStyle: labelStyle,
                labelBacking: colors.cell,
                labelHeight: labelHeight,
                startLabel: startLabel,
                endLabel: endLabel,
                textDirection: textDirection,
                textScaler: textScaler,
              ),
            ),
          ),
        );
      },
    );
  }

  static int? _indexAt(double dx, double width, int count) {
    if (count <= 0 || width <= 0) return null;
    final i = (dx / (width / count)).floor();
    return (i < 0 || i >= count) ? null : i;
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.values,
    required this.maxValue,
    required this.average,
    required this.bar,
    required this.baseline,
    required this.averageLine,
    required this.labelStyle,
    required this.labelBacking,
    required this.labelHeight,
    required this.textDirection,
    this.startLabel,
    this.endLabel,
    this.textScaler = TextScaler.noScaling,
  });

  final List<num> values;
  final num maxValue;
  final double average;
  final Color bar;
  final Color baseline;
  final Color averageLine;

  /// caption2 in the secondary label colour.
  final TextStyle labelStyle;

  /// Painted behind a value label so the dashed average never runs
  /// through its digits (the cell colour).
  final Color labelBacking;

  /// One scaled label's height: the bands [trendChartLayout] reserves.
  final double labelHeight;
  final String? startLabel;
  final String? endLabel;
  final TextDirection textDirection;
  final TextScaler textScaler;

  /// A slot's bar never gets wider than this: with only a few days in the
  /// span, full-slot bars read as blocks, not a trend.
  static const double maxBarWidth = 28;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final layout = trendChartLayout(size,
        labelHeight: labelHeight, axisLabelHeight: labelHeight);
    final plot = layout.plot;
    final scaleMax = math.max(1.0, maxValue.toDouble());
    final slot = size.width / values.length;
    // 2-pt gap between bars, capped width for sparse spans.
    final barW = math.min(maxBarWidth, math.max(2.0, slot - 2));
    double barLeft(int i) => i * slot + (slot - barW) / 2;
    double barHeight(int i) =>
        math.max(0.0, values[i].toDouble()) / scaleMax * plot.height;

    // Baseline + average reference, both recessive.
    canvas.drawLine(
      Offset(0, plot.bottom - 0.5),
      Offset(size.width, plot.bottom - 0.5),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );
    if (average > 0) {
      final y = plot.bottom - (average / scaleMax) * plot.height;
      final dash = Paint()
        ..color = averageLine
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 6) {
        canvas.drawLine(
            Offset(x, y), Offset(math.min(x + 3, size.width), y), dash);
      }
    }

    final fill = Paint()..color = bar;
    var maxIndex = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] > values[maxIndex]) maxIndex = i;
    }
    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final h = barHeight(i);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(barLeft(i), plot.bottom - h, barW, h),
          // Rounded data end, anchored square to the baseline.
          topLeft: const Radius.circular(AppRadius.xs),
          topRight: const Radius.circular(AppRadius.xs),
        ),
        fill,
      );
    }

    // Selective direct labels: the peak and the latest LOGGED day only —
    // with gap days padded as 0, an empty today must not hide the most
    // recent value. A label sits above the TALLEST bar under its own
    // width, so it never covers a neighbouring bar either.
    Rect placeLabel(int index, TextPainter tp) {
      final cx = index * slot + slot / 2 - tp.width / 2;
      final left =
          cx.clamp(0.0, math.max(0.0, size.width - tp.width)).toDouble();
      final span = Rect.fromLTWH(left - 2, 0, tp.width + 4, 0);
      var top = plot.bottom;
      for (var i = 0; i < values.length; i++) {
        if (values[i] <= 0) continue;
        final l = barLeft(i);
        if (l < span.right && l + barW > span.left) {
          top = math.min(top, plot.bottom - barHeight(i));
        }
      }
      final y = math.max(0.0, top - tp.height - 2);
      return Rect.fromLTWH(left, y, tp.width, tp.height);
    }

    void paintLabel(TextPainter tp, Rect at) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(at.left - 2, at.top, at.right + 2, at.bottom),
            const Radius.circular(2)),
        Paint()..color = labelBacking,
      );
      tp.paint(canvas, at.topLeft);
    }

    final painters = <TextPainter>[];
    try {
      Rect? peakRect;
      if (values[maxIndex] > 0) {
        final tp = _text(formatKcal(values[maxIndex]));
        painters.add(tp);
        peakRect = placeLabel(maxIndex, tp);
        paintLabel(tp, peakRect);
      }
      final latest = values.lastIndexWhere((v) => v > 0);
      if (latest >= 0 && latest != maxIndex) {
        final tp = _text(formatKcal(values[latest]));
        painters.add(tp);
        final rect = placeLabel(latest, tp);
        // Beside the peak's label there is no room for a second one: the
        // day rows below carry every value anyway.
        if (peakRect == null || !rect.inflate(2).overlaps(peakRect)) {
          paintLabel(tp, rect);
        }
      }

      // The date axis, under the baseline.
      final axisY = layout.axisBand.top + kTrendLabelGap;
      final end = endLabel == null ? null : _text(endLabel!);
      final start = startLabel == null ? null : _text(startLabel!);
      if (end != null) {
        painters.add(end);
        end.paint(canvas, Offset(math.max(0, size.width - end.width), axisY));
      }
      if (start != null) {
        painters.add(start);
        final room = size.width - (end?.width ?? 0) - 8;
        if (start.width <= room) start.paint(canvas, Offset(0, axisY));
      }
    } finally {
      for (final tp in painters) {
        tp.dispose();
      }
    }
  }

  TextPainter _text(String text) => TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();

  @override
  bool shouldRepaint(_TrendPainter old) =>
      // Contents, not just length: with a fixed calendar span, moving a
      // meal between two days keeps length, max and average equal.
      !listEquals(old.values, values) ||
      old.maxValue != maxValue ||
      old.average != average ||
      old.bar != bar ||
      old.baseline != baseline ||
      old.averageLine != averageLine ||
      old.labelStyle != labelStyle ||
      old.labelBacking != labelBacking ||
      old.labelHeight != labelHeight ||
      old.startLabel != startLabel ||
      old.endLabel != endLabel ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler;
}
