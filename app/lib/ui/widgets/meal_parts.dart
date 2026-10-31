/// The pieces one meal is drawn with, shared by Today's meal cards and Day
/// detail's rows so a meal reads the same on both screens: the header line
/// (thumbnail, title, clock, corrected mark, chevron), the number chips and
/// the corrected mark itself.
library;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../large_text.dart';
import '../theme/tokens.dart';

/// Thumbnail, title, clock and an optional chevron in one line.
///
/// Above 1.5x (isLargeText) the clock and [marker] move UNDER the title and
/// the title takes every line it needs. Beside a 3x clock a meal name was
/// cut to a few glyphs ('拿铁/咖…', 'Ch…') on the main screen (A4); Day
/// detail already stacked this way.
class MealHeader extends StatelessWidget {
  const MealHeader({
    super.key,
    required this.title,
    required this.time,
    this.leading,
    this.marker,
    this.maxTitleLines,
    this.showChevron = false,
    this.stacked,
    this.titleKey,
    this.timeKey,
  });

  final String title;

  /// The meal's display clock (context.clock).
  final String time;

  /// The thumbnail; null gives the title the whole width.
  final Widget? leading;

  /// Shown beside the clock (the corrected mark).
  final Widget? marker;

  /// The title's line limit at standard sizes (ellipsis after it); none at
  /// accessibility sizes.
  final int? maxTitleLines;

  /// The disclosure chevron of a row that opens the editor.
  final bool showChevron;

  /// Clock under the title; null decides by isLargeText.
  final bool? stacked;
  final Key? titleKey;
  final Key? timeKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final below = stacked ?? isLargeText(context);
    final limit = below ? null : maxTitleLines;
    final titleText = Text(
      title,
      key: titleKey,
      maxLines: limit,
      overflow: limit == null ? null : TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(color: colors.label),
    );
    final timeText = Text(
      time,
      key: timeKey,
      style: theme.textTheme.bodySmall?.copyWith(
        color: colors.secondaryLabel,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final mark = marker;
    return Row(
      children: [
        if (leading != null) ...[
          leading!,
          const SizedBox(width: AppSpace.s12),
        ],
        Expanded(
          child: below
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleText,
                    const SizedBox(height: AppSpace.s2),
                    Row(
                      children: [
                        Flexible(child: timeText),
                        if (mark != null) ...[
                          const SizedBox(width: AppSpace.s8),
                          mark,
                        ],
                      ],
                    ),
                  ],
                )
              : titleText,
        ),
        if (!below) ...[
          if (mark != null) ...[
            const SizedBox(width: AppSpace.s8),
            mark,
          ],
          const SizedBox(width: AppSpace.s8),
          timeText,
        ],
        if (showChevron) ...[
          const SizedBox(width: AppSpace.s4),
          Icon(Icons.chevron_right_rounded,
              size: scaledGlyph(context, 20), color: colors.tertiaryLabel),
        ],
      ],
    );
  }
}

/// [base] pt scaled with the text, up to 1.5x: SF Symbols beside text grow
/// with Dynamic Type, and a 15-pt pencil beside a 3x clock all but vanished.
double scaledGlyph(BuildContext context, double base) =>
    MediaQuery.textScalerOf(context).scale(base).clamp(base, base * 1.5);

/// The ✏️ corrected-by-hand mark (spec §2.2 / §5.2). With [tooltip] its
/// name is a tooltip (long-press shows it); otherwise the icon's own
/// semantic label names it.
class CorrectedMark extends StatelessWidget {
  const CorrectedMark({super.key, this.iconKey, this.tooltip = false});

  /// On the Icon (Today keeps Key('correctedBadge')).
  final Key? iconKey;
  final bool tooltip;

  @override
  Widget build(BuildContext context) {
    final name = context.l10n.correctedBadge;
    final icon = Icon(
      Icons.edit_rounded,
      key: iconKey,
      size: scaledGlyph(context, 15),
      color: AppColors.of(context).secondaryLabel,
      semanticLabel: tooltip ? null : name,
    );
    return tooltip ? Tooltip(message: name, child: icon) : icon;
  }
}

/// One number chip: the meal's kcal (solid accent, [emphasized]) or a macro
/// in its fixed identity hue ([tint], at the chip alpha) with label-colour
/// text. Identity never rests on colour alone: the P/C/F letter stays in
/// [label]. The total is SOLID so it never turns into a near-twin of the
/// carb tint; the tint alpha (0.20 light / 0.25 dark, AppColors) was
/// a11y-measured: visible, with the text still 6:1 or better.
class MealChip extends StatelessWidget {
  const MealChip({
    super.key,
    required this.label,
    this.emphasized = false,
    this.tint,
  });

  final String label;
  final bool emphasized;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final tint = this.tint;
    final background = emphasized
        ? colors.accent
        : tint != null
            ? tint.withValues(alpha: colors.macroChipAlpha)
            : colors.fill;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: background,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.chipH, vertical: AppSpace.chipV),
        child: Text(
          label,
          style: AppNumerals.of(context).chip.copyWith(
              color: emphasized ? colors.onAccent : colors.label),
        ),
      ),
    );
  }
}
