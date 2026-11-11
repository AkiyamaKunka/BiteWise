/// The Today hero ring: eaten vs the day's budget, remaining in the center.
///
/// Research-derived (scratchpad/uiux_direction.md): every leading health app
/// answers "how am I doing?" with ONE glanceable element, and MFP's 20-M-user
/// muscle memory is the transparent arithmetic `budget − food + exercise =
/// remaining`. Ours: budget = typical-day median + Garmin active burn, and
/// the rows beside the ring VISIBLY produce the center number (review panel:
/// arithmetic that doesn't reconcile is worse than no arithmetic).
///
/// Design rules: single hue for the intake arc (the accent — macros keep
/// their own fixed hues elsewhere), NO shame state (over renders in the same calm
/// hue at full sweep, the "+over" stated in text; red guilt is the #1
/// researched complaint driver), hand-drawn painter (no packages).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../format.dart';
import '../l10n.dart';
import '../large_text.dart';
import '../theme/tokens.dart';

class CalorieRing extends StatelessWidget {
  const CalorieRing({
    super.key,
    required this.eatenKcal,
    required this.typicalKcal,
    this.burnKcal = 0,
    this.size = 144,
  });

  final num eatenKcal;

  /// Null until ≥2 prior days have data (spec §5.1) — the ring then draws
  /// a neutral full track with the eaten number centered, no fraction.
  final num? typicalKcal;

  /// Garmin active burn: EXTENDS the budget (MFP framing — exercise gives
  /// calories back). Zero when absent; never shown as an operand elsewhere
  /// without also being folded in here.
  final num burnKcal;

  /// 144 on Today (the report passes 116). A 4-digit day ('1,240') in the
  /// 34-pt hero numerals plus its caption needs a 120-pt inner circle to
  /// draw at full size; at 140 it was shrunk 3% at the default text size.
  final double size;

  /// One rounded integer per quantity: the ring, the rows and the caption
  /// must never disagree by a rounding path (review panel: a card that
  /// says both "+0 over" and "0 headroom" is lying twice).
  int get _eaten => eatenKcal.round();
  int? get _budget =>
      typicalKcal == null ? null : (typicalKcal!.round() + burnKcal.round());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final budget = _budget;
    final frac = (budget == null || budget <= 0)
        ? null
        : (_eaten / budget).clamp(0.0, 1.0).toDouble();
    final over = budget != null && _eaten > budget;
    // The hero is what you ATE, never what is left (owner decision
    // 2026-08-06): a tracker's job is to report intake, and a
    // countdown-to-zero frames every meal as spending a budget. The arc
    // still carries the progress-against-typical context.
    final l = context.l10n;
    final centerBig = formatKcal(_eaten);
    final centerSmall = l.ringKcalToday;
    // The spoken sentence follows the app language like the visible
    // labels do (a zh VoiceOver user heard English here), and keeps the
    // neutral 'above typical' wording — no shame state in speech either.
    // It names the Typical row's number, not the budget: with Garmin burn
    // VoiceOver said 'typical day 2,500' beside a row showing 2,100, so the
    // burn is its own clause.
    final burn = burnKcal.round();
    final burnClause = burn > 0 ? l.ringSemanticsBurn(formatKcal(burn)) : '';
    final semantics = budget == null
        ? l.ringSemantics(formatKcal(_eaten))
        : over
            ? l.ringSemanticsAboveTypical(formatKcal(_eaten),
                formatKcal(typicalKcal!.round()), burnClause)
            : l.ringSemanticsTypical(formatKcal(_eaten),
                formatKcal(typicalKcal!.round()), burnClause);
    final centre = Center(
      // The ring is a fixed box; large system font scales (or 5-digit
      // values) must shrink to fit inside the stroke, never run over
      // it. A square box let the two-line column use the full height,
      // so at the largest size '千卡' sat on the bottom of the ring.
      child: Semantics(
        label: semantics,
        excludeSemantics: true,
        child: _FitInCircle(
          diameter: size - 2 * _RingPainter.stroke,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(centerBig,
                  key: const Key('ringCenterValue'),
                  maxLines: 1,
                  softWrap: false,
                  style:
                      AppNumerals.of(context).hero.copyWith(color: colors.label)),
              Text(centerSmall,
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: colors.secondaryLabel)),
            ],
          ),
        ),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      // The arc eases to a new total (a meal logged, an edit) instead of
      // jumping; the first build draws it in place, and Reduce Motion
      // makes the change instant.
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: frac ?? 0),
        duration: AppMotion.of(context, AppMotion.ring),
        curve: AppMotion.curve,
        builder: (context, sweep, child) => CustomPaint(
          painter: _RingPainter(
            fraction: frac == null ? null : sweep,
            arc: colors.accent,
            // The track is decorative: it shows the denominator ("how
            // much of a typical day") but carries no contrast duty of its
            // own. The ARC carries it, against the track: 4.57:1 light,
            // 5.62:1 dark (the old comment's '3:1 track' was never true —
            // the blended track sat near 1.7:1 on the card, A13).
            track: colors.track,
          ),
          child: child,
        ),
        child: centre,
      ),
    );
  }
}

/// Scales its child down (never up) until the child's box, corners
/// included, lies inside a centred circle of [diameter]: a w×h box centred
/// in a circle fits iff w² + h² ≤ d². Not the inscribed square (d/√2 a
/// side): that would shrink the day report's 1.0x '1,240' for no reason.
class _FitInCircle extends SingleChildRenderObjectWidget {
  const _FitInCircle({required this.diameter, super.child});
  final double diameter;

  @override
  _RenderFitInCircle createRenderObject(BuildContext context) =>
      _RenderFitInCircle(diameter);

  @override
  void updateRenderObject(BuildContext context, _RenderFitInCircle r) =>
      r.diameter = diameter;
}

class _RenderFitInCircle extends RenderProxyBox {
  _RenderFitInCircle(this._diameter);

  double _diameter;
  set diameter(double v) {
    if (v == _diameter) return;
    _diameter = v;
    markNeedsLayout();
  }

  double _scale = 1;
  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  double _scaleFor(Size s) {
    final diagonal = math.sqrt(s.width * s.width + s.height * s.height);
    return diagonal <= _diameter ? 1.0 : _diameter / diagonal;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = child;
    if (c == null) return constraints.smallest;
    final s = c.getDryLayout(const BoxConstraints());
    return constraints.constrain(s * _scaleFor(s));
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(const BoxConstraints(), parentUsesSize: true);
    _scale = _scaleFor(c.size);
    size = constraints.constrain(c.size * _scale);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    layer = context.pushTransform(needsCompositing, offset, _transform,
        super.paint,
        oldLayer: layer is TransformLayer ? layer as TransformLayer : null);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final c = child;
    if (c == null) return false;
    return result.addWithPaintTransform(
        transform: _transform,
        position: position,
        hitTest: (result, p) => c.hitTest(result, position: p));
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.arc,
    required this.track,
  });

  final double? fraction; // null → indeterminate day (no typical yet)
  final Color arc;
  final Color track;

  static const stroke = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (math.min(size.width, size.height) - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = track);
    final f = fraction;
    if (f == null || f <= 0) return;
    // Start at 12 o'clock, sweep clockwise; rounded ends read as progress,
    // not pie. At/over 100% the arc simply closes — calm, complete, no red.
    canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * f,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = f >= 1.0 ? StrokeCap.butt : StrokeCap.round
          ..color = arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.arc != arc || old.track != track;
}

/// One row of the transparent arithmetic beside the ring:
/// a fixed-hue dot, a label, and a right-aligned tabular number.
class ArithmeticRow extends StatelessWidget {
  const ArithmeticRow({
    super.key,
    required this.label,
    required this.value,
    required this.dot,
    this.emphasized = false,
  });
  final String label;
  final String value;
  final Color dot;

  /// The `=` result row: the number the ring's center restates. It reads
  /// heavier (AppNumerals.value, 17 w600) than the context rows (inline,
  /// 15 w400). The old pair, labelLarge vs titleSmall, resolved to the
  /// same 14 w500, so the emphasis never reached the screen (U15).
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final nums = AppNumerals.of(context);
    final dotBox = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
    );
    final labelStyle =
        theme.textTheme.bodyMedium?.copyWith(color: colors.secondaryLabel);
    // FittedBox: at narrow widths × large font scale the number wins
    // over the label, shrinking instead of overflowing the row.
    final valueBox = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(value,
          maxLines: 1,
          softWrap: false,
          style: (emphasized ? nums.value : nums.inline)
              .copyWith(color: colors.label)),
    );
    if (isLargeText(context)) {
      // At accessibility sizes the one-line label was cut to '已…', and
      // with three rows (日常 / 消耗 / 已摄入) the numbers lost their
      // meaning: the label gets the full width and wraps, the number
      // sits under it.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                dotBox,
                const SizedBox(width: AppSpace.s8),
                Flexible(child: Text(label, style: labelStyle)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.s16),
              child: valueBox,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          dotBox,
          const SizedBox(width: AppSpace.s8),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle),
          ),
          valueBox,
        ],
      ),
    );
  }
}

/// The macro trio: three fixed-hue mini-bars (Cronometer's tiering —
/// ring first, three bars second, full depth on the detail screens).
class MacroTrio extends StatelessWidget {
  const MacroTrio({
    super.key,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.proteinColor,
    required this.carbsColor,
    required this.fatColor,
  });
  final num proteinG;
  final num carbsG;
  final num fatG;
  final Color proteinColor;
  final Color carbsColor;
  final Color fatColor;

  @override
  Widget build(BuildContext context) {
    // Bars fill by CALORIE share (Atwater 4/4/9), matching the detail
    // screen's macro bar — the codebase's own rule: a gram-proportional
    // bar "would misstate what the meal is made of". Labels stay grams.
    final pKcal = math.max(0, proteinG) * 4;
    final cKcal = math.max(0, carbsG) * 4;
    final fKcal = math.max(0, fatG) * 9;
    final totalKcal = pKcal + cKcal + fKcal;
    // Same short labels as the meal-card chips below (zh 蛋/碳/脂), so the
    // hero and the cards agree.
    final l = context.l10n;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    // The track is decorative, like the ring's: the coloured fill is what
    // carries the value.
    Widget bar(String label, num g, num kcal, Color color) {
      final frac =
          totalKcal <= 0 ? 0.0 : (kcal / totalKcal).clamp(0.0, 1.0).toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label ${g.round()}g',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: colors.secondaryLabel)),
          const SizedBox(height: AppSpace.s4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: LayoutBuilder(
                builder: (context, c) => Stack(children: [
                  Container(width: c.maxWidth, color: colors.track),
                  Container(
                      width: math.max(frac * c.maxWidth, g > 0 ? 6.0 : 0.0),
                      color: color),
                ]),
              ),
            ),
          ),
        ],
      );
    }

    final bars = [
      bar(l.macroProteinShort, proteinG, pKcal, proteinColor),
      bar(l.macroCarbsShort, carbsG, cKcal, carbsColor),
      bar(l.macroFatShort, fatG, fKcal, fatColor),
    ];
    if (isLargeText(context)) {
      // Three columns left each label a third of the card at 3x, so
      // '蛋 104g' wrapped glyph by glyph: each macro takes a full-width
      // row, its label above its bar.
      return Column(
        key: const Key('macroTrio'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < bars.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpace.s12),
            bars[i],
          ],
        ],
      );
    }
    return Row(
      key: const Key('macroTrio'),
      children: [
        for (var i = 0; i < bars.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpace.s12),
          Expanded(child: bars[i]),
        ],
      ],
    );
  }
}
