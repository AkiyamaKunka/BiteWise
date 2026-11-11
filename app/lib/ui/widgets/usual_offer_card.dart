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
///
/// A grouped card in run 7's token colours; the buttons take the theme's
/// tonal and grey-pill styles, as the editor's other controls do.
library;

import 'package:flutter/material.dart';

import '../../services/usual/usual_foods.dart';
import '../format.dart' show formatKcal;
import '../l10n.dart';
import '../theme/tokens.dart';
import 'grouped.dart' show GroupedCard;

/// Grams as the meal card writes them: whole, else to 0.1 g.
String _grams(num v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// The three macros of [n] on one line: "P 10g · C 54g · F 6g".
String _macros(AppLocalizations l, UsualNumbers n) =>
    '${l.macroProteinShort} ${_grams(n.p)}g · '
    '${l.macroCarbsShort} ${_grams(n.c)}g · '
    '${l.macroFatShort} ${_grams(n.f)}g';

/// The line that says what Use changes for [item], named [name]: the AI's
/// kcal and yours, or, when the kcal hardly moves (an offer on the macros
/// alone), the AI's macros and yours. The chip and the card both say it.
String usualItemText(AppLocalizations l, UsualOfferItem item, String name) =>
    item.macroOnly
        ? l.usualItemLineMacros(name, _macros(l, item.ai), _macros(l, item.mine))
        : l.usualItemLine(
            name, formatKcal(item.ai.kcal), formatKcal(item.mine.kcal));

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
    final colors = context.colors;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.secondaryLabel,
    );
    final locked = busy || editFirst;
    return GroupedCard(
      key: const Key('usualOfferCard'),
      // The editor's list already keeps the gutter.
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(AppSpace.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.history, size: 20, color: colors.secondaryLabel),
              const SizedBox(width: AppSpace.s8),
              Expanded(
                child: Text(
                  l.usualCardTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.label,
                  ),
                ),
              ),
            ],
          ),
          for (final item in offer.items) ...[
            const SizedBox(height: AppSpace.s8),
            Text(
              usualItemText(l, item, item.name),
              key: Key('usualOfferItem${item.index}'),
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.label),
            ),
            Text(l.usualCardFrom(item.learnedName, item.fromDate),
                style: muted),
          ],
          if (editFirst) ...[
            const SizedBox(height: AppSpace.s8),
            Text(
              l.assistEditFirst,
              key: const Key('usualEditFirst'),
              style: muted,
            ),
          ],
          const SizedBox(height: AppSpace.s12),
          Wrap(
            spacing: AppSpace.s8,
            runSpacing: AppSpace.s4,
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
    );
  }
}

/// After Use wrote the user's numbers: the meal totals before → after,
/// as assistAppliedSnack does (or, when the total kcal did not move, only
/// that they were used), with Undo on [messenger] (the app's own, so
/// it outlives the screen that showed the offer). Undo puts the earlier
/// numbers back while the meal still holds exactly what Use wrote, and
/// otherwise says nothing was undone; [onUndone] runs after an Undo that
/// wrote.
/// How long a usual-foods snackbar with Undo stays up. A snackbar with an
/// action never times out by default (SnackBar.persist), so each one says
/// this duration and [usualUndoPersists].
const Duration kUsualUndoSnackDuration = Duration(seconds: 8);

/// `SnackBar.persist` for a usual-foods snackbar with Undo on [messenger].
///
/// Only with a screen reader on (VoiceOver / TalkBack), where reaching
/// Undo takes longer than [kUsualUndoSnackDuration]. The framework does
/// not hold an action snackbar there by itself any more: its timer looks
/// at `persist` alone, so a flat `persist: false` took Undo away from
/// exactly the users who need the time.
bool usualUndoPersists(ScaffoldMessengerState messenger) =>
    messenger.mounted && MediaQuery.accessibleNavigationOf(messenger.context);

/// Shows [bar] in place of the snackbar that is up now. App messages
/// already queued behind that one (main.dart showAppSnackbar: a "Logged"
/// line per photo, a share verdict, a failure) are not dropped: they are
/// shown first, each for its own few seconds, then [bar] with its Undo.
void showUsualSnack(ScaffoldMessengerState messenger, SnackBar bar) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(bar);
}

void showUsualUsedSnack(
  ScaffoldMessengerState messenger,
  AppLocalizations l,
  UsualFoods usual,
  UsualAcceptResult result, {
  VoidCallback? onUndone,
}) {
  final before = formatKcal(result.beforeKcal);
  final after = formatKcal(result.afterKcal);
  showUsualSnack(
    messenger,
    SnackBar(
      key: const Key('usualUsedSnack'),
      duration: kUsualUndoSnackDuration,
      persist: usualUndoPersists(messenger),
      content: Text(
        before == after
            ? l.usualUsedSnackSame
            : l.usualUsedSnack(before, after),
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
            showUsualSnack(
              messenger,
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
