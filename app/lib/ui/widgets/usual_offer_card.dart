/// The meal editor's "Your usual numbers" card (usual foods §3.4), and the
/// snackbar Use shows on Today and in the editor (§3.5).
///
/// A photo meal of today whose foods the user set numbers for before gets
/// one card: per food, "{food}: AI {ai} → your usual {mine} kcal" and where
/// those numbers came from ("From your {food} on {date}."). Use my numbers
/// writes every offered food at once (all or nothing: no checkboxes, D34);
/// Keep AI estimate writes nothing and records that the offer was turned
/// down. Both wait while the form has unsaved typing.
///
/// Everything shown was worked out on the phone from the user's own meal
/// log; nothing here sends anything.
library;

import 'package:flutter/material.dart';

import '../../services/usual/usual_foods.dart';
import '../format.dart' show formatKcal;
import '../l10n.dart';

class UsualOfferCard extends StatelessWidget {
  const UsualOfferCard({
    super.key,
    required this.offer,
    this.busy = false,
    this.editFirst = false,
    this.onUse,
    this.onKeepAi,
  });

  final UsualOffer offer;

  /// A write is running: both buttons wait.
  final bool busy;

  /// The form has unsaved changes: both buttons wait for a save, and the
  /// card says so.
  final bool editFirst;

  final VoidCallback? onUse;
  final VoidCallback? onKeepAi;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final locked = busy || editFirst;
    return Card(
      key: const Key('usualOfferCard'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.history, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.usualCardTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            for (final item in offer.items) ...[
              const SizedBox(height: 8),
              Text(
                l.usualItemLine(
                  item.name,
                  formatKcal(item.ai.kcal),
                  formatKcal(item.mine.kcal),
                ),
                key: Key('usualOfferItem${item.index}'),
                style: theme.textTheme.bodyMedium,
              ),
              Text(l.usualCardFrom(item.learnedName, item.fromDate),
                  style: muted),
            ],
            if (editFirst) ...[
              const SizedBox(height: 8),
              Text(
                l.assistEditFirst,
                key: const Key('usualEditFirst'),
                style: muted,
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonal(
                  key: const Key('usualUseMine'),
                  onPressed: locked ? null : onUse,
                  child: Text(l.usualUseMine),
                ),
                OutlinedButton(
                  key: const Key('usualKeepAi'),
                  onPressed: locked ? null : onKeepAi,
                  child: Text(l.usualKeepAi),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// After Use wrote the user's numbers: the meal totals before → after,
/// as assistAppliedSnack does, with Undo on [messenger] (the app's own, so
/// it outlives the screen that showed the offer). Undo puts the earlier
/// numbers back while the meal still holds exactly what Use wrote, and
/// otherwise says nothing was undone; [onUndone] runs after an Undo that
/// wrote.
void showUsualUsedSnack(
  ScaffoldMessengerState messenger,
  AppLocalizations l,
  UsualFoods usual,
  UsualAcceptResult result, {
  VoidCallback? onUndone,
}) {
  messenger.showSnackBar(
    SnackBar(
      key: const Key('usualUsedSnack'),
      content: Text(
        l.usualUsedSnack(
          formatKcal(result.beforeKcal),
          formatKcal(result.afterKcal),
        ),
      ),
      action: SnackBarAction(
        label: l.assistUndo,
        onPressed: () async {
          var undone = false;
          try {
            undone = await usual.undoAccept(result);
          } catch (_) {}
          if (undone) {
            onUndone?.call();
          } else {
            messenger.showSnackBar(
              SnackBar(
                key: const Key('usualUndoStale'),
                content: Text(l.usualUndoStale),
              ),
            );
          }
        },
      ),
    ),
  );
}
