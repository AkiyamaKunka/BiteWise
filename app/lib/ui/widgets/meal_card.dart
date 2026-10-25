/// One logged-meal card (spec §5.4 content: description, item lines,
/// ~kcal / P/C/F, corrected marker, time). All analysis reads are coerced —
/// hostile stored shapes must render, not crash (spec §3.5).
///
/// The restaurant assist's chip (design R7b) shows only while its stamps
/// hold: '{brand} numbers used for {n} item(s)' for applied published
/// numbers, '{brand} publishes {kcal} kcal — tap to review' for a
/// suggestion; {brand} is the chain's name from BiteWise's own table. A dot
/// beside it marks an automatic change the user has not opened yet.
library;

import 'package:flutter/material.dart';

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import 'dart:typed_data';

import '../../services/photo/glasses.dart' show isMetaGlassesAnalysis;
import '../assist_view.dart';
import '../format.dart';
import '../l10n.dart';
import '../large_text.dart';
import 'glasses_badge.dart';
import 'grouped.dart' show GroupedCard;
import 'macro_chart.dart' show MacroPalette;
import 'meal_thumb.dart';

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
  const MealCard(
      {super.key,
      required this.meal,
      this.showItems = true,
      this.onTap,
      this.thumb,
      this.assistUnseen = false});

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
            Row(
              children: [
                // Photo meals only: for text/manual meals the old
                // placeholder block read as a failed image load (panel,
                // cycle 1) — the title owns the width instead.
                if (thumb != null && meal.imageHash.isNotEmpty) ...[
                  MealThumbView(
                      thumb: thumb,
                      isPhotoMeal: true),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    mealDescription(a,
                        fallback: context.l10n.nlUnnamedMeal),
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
                if (meal.corrected)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    // ✏️ corrected marker (spec §2.2 / §5.2).
                    child: Tooltip(
                      message: context.l10n.correctedBadge,
                      child: Icon(Icons.edit,
                          key: const Key('correctedBadge'),
                          size: 16,
                          color: theme.colorScheme.tertiary),
                    ),
                  ),
                const SizedBox(width: 8),
                Text(context.clock(meal.time),
                    style: theme.textTheme.bodySmall),
                if (onTap != null) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.6)),
                ],
              ],
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
            ],
            if (showItems && items.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    // Item line per §5.4; name stringified, missing → '?'.
                    '• ${item['name'] ?? '?'}: '
                    '~${context.l10n.kcalAmount(displayItemCalories(item['estimated_calories']))}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
    );
  }

  Widget _chip(BuildContext context, String label,
      {bool emphasized = false, Color? tint}) {
    final scheme = Theme.of(context).colorScheme;
    // Identity never rests on colour ALONE (chart rule): the P/C/F letter
    // stays in the label; the tint is reinforcement.
    // Tint alphas: a11y-measured — 0.14 was compliant but nearly invisible;
    // 0.20 light / 0.25 dark actually reads while keeping >6:1 text headroom.
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The TOTAL wears solid primary — under the clay seed, primaryContainer
    // and the carb tint became near-twins, dissolving the hierarchy the
    // emphasized chip exists for.
    final bg = emphasized
        ? scheme.primary
        : tint != null
            ? tint.withValues(alpha: dark ? 0.25 : 0.20)
            : scheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: emphasized ? scheme.onPrimary : null,
              fontWeight: emphasized ? FontWeight.w600 : null)),
    );
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
              // At the accessibility sizes the words take the lines they
              // need; a cut chain name would say nothing.
              maxLines: isLargeText(context) ? null : 2,
              overflow: isLargeText(context) ? null : TextOverflow.ellipsis,
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
