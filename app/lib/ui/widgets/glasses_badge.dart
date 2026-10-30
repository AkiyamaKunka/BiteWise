/// The "Meta glasses" mark on a meal whose photo came from Meta glasses
/// (design G2a: analysis.capture.device == 'meta_glasses'). A neutral,
/// outlined pill — the filled chips beside it are the meal's numbers — with
/// a drawn glasses glyph (Material Icons has none) and the words, so the
/// mark never rests on a picture alone.
library;

import 'package:flutter/material.dart';

import '../l10n.dart';

class MetaGlassesBadge extends StatelessWidget {
  const MetaGlassesBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.labelSmall?.copyWith(color: color);
    // The glyph grows with the text, as the words beside it do.
    final glyph = MediaQuery.textScalerOf(context).scale(14).clamp(14.0, 28.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: CustomPaint(
              size: Size(glyph, glyph),
              painter: GlassesGlyphPainter(color),
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              context.l10n.captureMetaGlasses,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A pair of glasses: two rounded lenses, the bridge, the hinges.
class GlassesGlyphPainter extends CustomPainter {
  const GlassesGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round;
    final top = size.height / 2 - s * 0.16;
    for (final left in [s * 0.06, s * 0.56]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, s * 0.38, s * 0.32),
          Radius.circular(s * 0.12),
        ),
        paint,
      );
    }
    final bridge = Path()
      ..moveTo(s * 0.44, top + s * 0.1)
      ..quadraticBezierTo(s * 0.5, top + s * 0.02, s * 0.56, top + s * 0.1);
    canvas.drawPath(bridge, paint);
    // The hinges, angled back.
    canvas.drawLine(
      Offset(s * 0.06, top + s * 0.06),
      Offset(s * 0.0, top - s * 0.06),
      paint,
    );
    canvas.drawLine(
      Offset(s * 0.94, top + s * 0.06),
      Offset(s * 1.0, top - s * 0.06),
      paint,
    );
  }

  @override
  bool shouldRepaint(GlassesGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}
