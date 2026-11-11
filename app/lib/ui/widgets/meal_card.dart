/// One logged-meal card (spec §5.4 content: description, item lines,
/// ~kcal / P/C/F, corrected marker, time). All analysis reads are coerced —
/// hostile stored shapes must render, not crash (spec §3.5).
///
/// The restaurant assist's chip (design R7b) shows only while its stamps
/// hold: '{brand} numbers used for {n} item(s)' for applied published
/// numbers, '{brand} publishes {kcal} kcal — tap to review' for a
/// suggestion; {brand} is the chain's name from the app's own table. A dot
/// beside it marks an automatic change the user has not opened yet.
///
/// In the same slot, only when the assist shows no chip: Today's "your
/// usual numbers" chip (widgets/usual_chip.dart), handed in ready-made.
library;

import 'package:flutter/material.dart';

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import 'dart:typed_data';

import '../../services/photo/glasses.dart' show isMetaGlassesAnalysis;
import '../assist_view.dart';
import '../format.dart';
import '../l10n.dart';
import 'glasses_badge.dart';
import 'grouped.dart' show GroupedCard;
import 'macro_chart.dart' show MacroPalette;
import 'meal_thumb.dart';
import 'meal_parts.dart';

class MealCard extends StatelessWidget {
  final Meal meal;
  final bool showItems;

  /// Optional drill-in (Today taps through to the editor). Null keeps the
  /// card inert, which is what the report/notification-style usages want.
  final VoidCallback? onTap;

  /// Resolved photo thumbnail; null skips the leading image entirely
  /// (tests / contexts without a resolver).
  final Future<Uint8List?>? thumb;

  /// An automatic restaurant lookup changed this meal and it was not
  /// opened since (design R7b): a dot beside the assist chip.
  final bool assistUnseen;

  /// Today's usual-numbers chip for this meal (usual foods §3.4), shown in
  /// the assist chip's slot only when the assist has none: one chip per
  /// card, and the assist's always wins.
  final Widget? usualChip;
  const MealCard(
      {super.key,
      required this.meal,
      this.showItems = true,
      this.onTap,
      this.thumb,
      this.assistUnseen = false,
      this.usualChip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = meal.analysis;
    final items = safeFoodItems(a); // spec §3.5: never iterate the raw field
    final assistChip = AssistView.of(a).chipText(context.l10n);
    return GroupedCard(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      onTap: onTap,
      child: Padding(
          padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MealHeader(
              // Photo meals only: for text/manual meals the old
              // placeholder block read as a failed image load (panel,
              // cycle 1) — the title owns the width instead.
              leading: thumb != null && meal.imageHash.isNotEmpty
                  ? MealThumbView(thumb: thumb, isPhotoMeal: true)
                  : null,
              title: mealDescription(a, fallback: context.l10n.nlUnnamedMeal),
              titleKey: const Key('mealCardTitle'),
              time: context.clock(meal.time),
              timeKey: const Key('mealCardTime'),
              maxTitleLines: 2,
              marker: meal.corrected
                  ? const CorrectedMark(
                      iconKey: Key('correctedBadge'), tooltip: true)
                  : null,
              showChevron: onTap != null,
            ),
            const SizedBox(height: 8),
            // Macro chips carry their FIXED identity hues (research: Apple's
            // color discipline — the same metric wears the same color on
            // every screen; grey chips made Today color-blind).
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _chip(context,
                    '~${context.l10n.kcalAmount(displayTotalCalories(a))}',
                    emphasized: true),
                _chip(context, '${context.l10n.macroProteinShort}: ${displayMacro(a, 'total_protein_g')}g',
                    tint: MacroPalette.of(context).protein),
                _chip(context, '${context.l10n.macroCarbsShort}: ${displayMacro(a, 'total_carbs_g')}g',
                    tint: MacroPalette.of(context).carbs),
                _chip(context, '${context.l10n.macroFatShort}: ${displayMacro(a, 'total_fat_g')}g',
                    tint: MacroPalette.of(context).fat),
                // Taken with Meta glasses (design G2a): where the photo
                // came from, after what the meal holds.
                if (isMetaGlassesAnalysis(a))
                  const MetaGlassesBadge(key: Key('metaGlassesBadge')),
              ],
            ),
            if (assistChip != null) ...[
              const SizedBox(height: 6),
              _AssistChip(text: assistChip, unseen: assistUnseen),
            ] else if (usualChip != null) ...[
              const SizedBox(height: 6),
              usualChip!,
            ],
            if (showItems && items.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    // Item line per §5.4; name stringified, missing → '?'.
                    // A template, so zh gets its full-width colon (L7).
                    '• ${context.l10n.mealItemLine(
                      '${item['name'] ?? '?'}',
                      context.l10n.kcalAmount(
                          displayItemCalories(item['estimated_calories'])),
                    )}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
    );
  }

  /// Macro chips carry their FIXED identity hues; the total wears the
  /// solid accent so it stays the first thing read (see [MealChip]).
  Widget _chip(BuildContext context, String label,
      {bool emphasized = false, Color? tint}) {
    return MealChip(label: label, emphasized: emphasized, tint: tint);
  }
}

/// The restaurant assist's chip: the chain's published numbers in use, or
/// a suggestion to review (the card's own tap opens the editor). Outlined,
/// not filled — the filled chips above are the meal's numbers.
class _AssistChip extends StatelessWidget {
  const _AssistChip({required this.text, required this.unseen});

  final String text;
  final bool unseen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = MediaQuery.textScalerOf(context).scale(14).clamp(14.0, 28.0);
    return Container(
      key: const Key('assistChip'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storefront_outlined,
              size: icon, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
              // The words take the lines they need, at every text size: a
              // cut chain name would say nothing. Two lines cut the long
              // table names (Red Robin Gourmet Burgers and Brews) on
              // 320–390 pt phones (RC 1.6.0); a name is at most
              // kAssistBrandNameMax characters, so the chip stays short.
            ),
          ),
          if (unseen) ...[
            const SizedBox(width: 6),
            Semantics(
              label: context.l10n.assistUnseenLabel,
              child: Container(
                key: const Key('assistUnseenDot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
