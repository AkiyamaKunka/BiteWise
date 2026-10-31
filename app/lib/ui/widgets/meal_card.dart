/// One logged-meal card (spec §5.4 content: description, item lines,
/// ~kcal / P/C/F, corrected marker, time). All analysis reads are coerced —
/// hostile stored shapes must render, not crash (spec §3.5).
library;

import 'package:flutter/material.dart';

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import 'dart:typed_data';

import '../format.dart';
import '../l10n.dart';
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
  const MealCard(
      {super.key,
      required this.meal,
      this.showItems = true,
      this.onTap,
      this.thumb});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = meal.analysis;
    final items = safeFoodItems(a); // spec §3.5: never iterate the raw field
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
              ],
            ),
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

  /// Macro chips carry their FIXED identity hues; the total wears the
  /// solid accent so it stays the first thing read (see [MealChip]).
  Widget _chip(BuildContext context, String label,
      {bool emphasized = false, Color? tint}) {
    return MealChip(label: label, emphasized: emphasized, tint: tint);
  }
}
