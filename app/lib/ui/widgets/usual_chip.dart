/// Today's "your usual numbers" chip (usual foods §3.4, D17), in the meal
/// card's assist-chip slot when the restaurant assist shows none.
///
/// One food: "Oatmeal: AI 300 → your usual 350 kcal" (its macros instead
/// when the kcal hardly moves) and **Use**, which writes them (with Undo on
/// the snackbar). Two or more: "Your usual
/// numbers for {count} items" and **Review**, which opens the editor's
/// card: an offer of several foods is taken or left whole, after a look.
/// Nothing changes without the tap. No dot, no notification.
library;

import 'package:flutter/material.dart';

import '../../services/usual/usual_foods.dart';
import '../l10n.dart';
import '../large_text.dart';
import 'usual_offer_card.dart' show usualItemText;

class UsualChip extends StatelessWidget {
  const UsualChip({
    super.key,
    required this.offer,
    this.busy = false,
    this.onUse,
    this.onReview,
  });

  final UsualOffer offer;

  /// Use is being written: the button waits.
  final bool busy;
  final VoidCallback? onUse;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final large = isLargeText(context);
    final single = offer.items.length == 1;
    final item = offer.items.first;
    final text = single
        ? usualItemText(l, item, item.learnedName)
        : l.usualChipMany(offer.items.length);
    final icon = MediaQuery.textScalerOf(context).scale(14).clamp(14.0, 28.0);
    final label = Text(
      text,
      key: const Key('usualChipText'),
      style: theme.textTheme.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      // Never cut: the number at its end is what Use writes, so the words
      // take the lines they need at every size.
    );
    final button = single
        ? TextButton(
            key: const Key('usualChipUse'),
            onPressed: busy ? null : onUse,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            // A screen reader hears which food it changes, not a bare "Use".
            child: Text(
              l.usualChipUse,
              semanticsLabel: l.usualChipUseLabel(item.learnedName),
            ),
          )
        : TextButton(
            key: const Key('usualChipReview'),
            onPressed: onReview,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text(l.usualChipReview),
          );
    final lead = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.history, size: icon, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(child: label),
      ],
    );
    return Container(
      key: const Key('usualChip'),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      // At large text the button goes under the words; side by side they
      // would leave the words a few glyphs a line. At the standard sizes it
      // sits beside them when both fit on one line, and under them when
      // they do not (a long name, a narrow phone).
      child: large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 6), child: lead),
                button,
              ],
            )
          : Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: lead,
                ),
                button,
              ],
            ),
    );
  }
}
