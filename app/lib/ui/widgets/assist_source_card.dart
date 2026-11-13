/// The meal editor's restaurant source card (design R7b, "EDITOR SOURCE
/// CARD"): where a chain's published numbers came from, and the user's
/// answers to them.
///
/// Per covered item: the menu item, its option and serving, and the
/// published kcal/P/C/F — all plain text; on a suggestion, every size the
/// chain publishes when there are several, and a line saying why the
/// numbers were not used by themselves (a shared or partly eaten plate, an
/// unclear size, a combo, the closest menu item, another unit, numbers the
/// user turned down before). Then 'Source: {host}' (the
/// normalized https address only, opened in the browser on tap; anything
/// else is never a link), 'via {provider} · {date}' (for a saved lookup
/// answer, 'via {provider} · saved answer from {date}', the day it was
/// fetched), whether the number was found on the source page, and the
/// lookup's notes as plain text (at most 200 characters, never links).
/// Everything shown is the chain's name from the app's own table and what
/// the lookup returned — nothing from Apple Maps exists to show. A lookup
/// that found nothing names no restaurant (a saved one says when it was
/// fetched).
///
/// Buttons: Use AI estimate (a note replaces it once the meal changed
/// after the numbers were used), Wrong restaurant, Not from a restaurant,
/// Correct (only where it can teach the spot: the place step named the
/// chain there); on a suggestion, Use published numbers (the editor asks
/// first, with the new total, when the reason says the numbers may not fit
/// what was eaten); with no result, Look up restaurant nutrition. On a
/// block decided on a saved answer, Search again asks for a fresh one: an
/// extra button on applied and suggested cards, and in place of Look up on
/// stale suggestions and context-only cards. A null callback hides its
/// button; [busy] disables them all.
library;

import 'package:flutter/material.dart';

import '../assist_view.dart';
import '../format.dart' show formatKcal, formatOneDecimal;
import '../l10n.dart';
import 'small_spinner.dart';

class AssistSourceCard extends StatelessWidget {
  const AssistSourceCard({
    super.key,
    required this.view,
    this.busy = false,
    this.lookingUp = false,
    this.editFirst = false,
    this.onUseEstimate,
    this.onAccept,
    this.onWrongRestaurant,
    this.onNotRestaurant,
    this.onCorrect,
    this.onLookUp,
    this.onSearchAgain,
    this.onOpenSource,
  });

  /// The meal's assist block as shown (AssistView.of).
  final AssistView view;

  /// An answer or a lookup is being written: every button waits.
  final bool busy;

  /// A manual lookup is running: its progress replaces the Look up button.
  final bool lookingUp;

  /// The form has unsaved changes: the buttons wait for a save.
  final bool editFirst;

  final VoidCallback? onUseEstimate;
  final VoidCallback? onAccept;
  final VoidCallback? onWrongRestaurant;
  final VoidCallback? onNotRestaurant;
  final VoidCallback? onCorrect;
  final VoidCallback? onLookUp;

  /// Search again (usual foods §2.4): a fresh lookup over a block decided
  /// on a saved answer ([AssistView.fetchedOn]). Shown only on such a
  /// block, and not while a lookup runs.
  final VoidCallback? onSearchAgain;

  /// Opens a normalized https source URL in the browser.
  final void Function(String url)? onOpenSource;

  bool get _locked => busy || lookingUp || editFirst;

  VoidCallback? _gate(VoidCallback? f) => _locked ? null : f;

  /// Search again shows: the block came from a saved answer, the editor
  /// can look up, and no lookup is running.
  bool get _searchAgain =>
      view.fetchedOn.isNotEmpty && onSearchAgain != null && !lookingUp;

  Widget _searchAgainButton(BuildContext context) => OutlinedButton.icon(
    key: const Key('assistSearchAgain'),
    onPressed: _gate(onSearchAgain),
    icon: const Icon(Icons.refresh, size: 18),
    label: Text(context.l10n.assistSearchAgain),
  );

  @override
  Widget build(BuildContext context) {
    if (view.hasSource) return _sourceCard(context);
    if (view.kind == AssistViewKind.contextOnly) return _contextOnly(context);
    return _lookUpOnly(context);
  }

  Widget _lookUpOnly(BuildContext context) {
    if (lookingUp) return _progress(context);
    if (onLookUp == null) return const SizedBox.shrink();
    return _withEditFirst(
      context,
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          key: const Key('assistLookUp'),
          onPressed: _gate(onLookUp),
          icon: const Icon(Icons.storefront_outlined, size: 18),
          label: Text(context.l10n.assistLookUp),
        ),
      ),
    );
  }

  /// [button], greyed while the form has unsaved typing, with the line
  /// saying why under it, as the source card's buttons have: alone, it
  /// was disabled with no reason given.
  Widget _withEditFirst(BuildContext context, Widget button) {
    if (!editFirst) return button;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        button,
        const SizedBox(height: 4),
        Text(
          context.l10n.assistEditFirst,
          key: const Key('assistEditFirst'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const Key('assistLookingUp'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SmallSpinner(size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.l10n.assistLookingUp,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _contextOnly(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('assistContextOnly'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.assistContextOnly,
              style: theme.textTheme.bodyMedium,
            ),
            if (view.fetchedOn.isNotEmpty)
              Text(
                context.l10n.assistContextSaved(view.fetchedOn),
                key: const Key('assistContextSaved'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            // Search again replaces Look up on a saved answer's record.
            if (_searchAgain) ...[
              const SizedBox(height: 8),
              _withEditFirst(
                context,
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _searchAgainButton(context),
                ),
              ),
            ] else if (lookingUp || onLookUp != null) ...[
              const SizedBox(height: 8),
              _lookUpOnly(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sourceCard(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final applied =
        view.kind == AssistViewKind.applied ||
        view.kind == AssistViewKind.appliedStale;
    final provider = assistProviderLabel(l, view.provider);
    final url = view.sourceUrl;
    final host = view.sourceHost;
    final buttons = <Widget>[
      if (view.kind == AssistViewKind.applied && onUseEstimate != null)
        FilledButton.tonal(
          key: const Key('assistUseEstimate'),
          onPressed: _gate(onUseEstimate),
          child: Text(l.assistUseEstimate),
        ),
      if (view.kind == AssistViewKind.suggested && onAccept != null)
        FilledButton.tonal(
          key: const Key('assistUsePublished'),
          onPressed: _gate(onAccept),
          child: Text(l.assistUsePublished),
        ),
      if (view.kind != AssistViewKind.suggestedStale) ...[
        if (onWrongRestaurant != null)
          OutlinedButton(
            key: const Key('assistWrongRestaurant'),
            onPressed: _gate(onWrongRestaurant),
            child: Text(l.assistWrongRestaurant),
          ),
        if (onNotRestaurant != null)
          OutlinedButton(
            key: const Key('assistNotRestaurant'),
            onPressed: _gate(onNotRestaurant),
            child: Text(l.assistNotRestaurant),
          ),
        if (applied && onCorrect != null)
          OutlinedButton(
            key: const Key('assistCorrect'),
            onPressed: _gate(onCorrect),
            child: Text(l.assistCorrect),
          ),
      ],
      // A saved answer's block: Search again, which on a stale suggestion
      // replaces Look up.
      if (_searchAgain)
        _searchAgainButton(context)
      else if (view.kind == AssistViewKind.suggestedStale &&
          onLookUp != null &&
          !lookingUp)
        OutlinedButton.icon(
          key: const Key('assistLookUp'),
          onPressed: _gate(onLookUp),
          icon: const Icon(Icons.storefront_outlined, size: 18),
          label: Text(l.assistLookUp),
        ),
    ];
    return Card(
      key: const Key('assistSourceCard'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.storefront_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    view.brandLabel(l),
                    key: const Key('assistBrand'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              applied ? l.assistCardApplied : l.assistCardSuggested,
              style: muted,
            ),
            if (view.whyText(l) case final why?) ...[
              const SizedBox(height: 6),
              Text(
                why,
                key: const Key('assistWhy'),
                style: theme.textTheme.bodyMedium,
              ),
            ],
            for (final item in view.items) ...[
              const SizedBox(height: 10),
              _ItemLines(
                item: item,
                showSizes: view.kind == AssistViewKind.suggested,
              ),
            ],
            const SizedBox(height: 10),
            if (url != null && host != null)
              // Its own node, announced as a link (VoiceOver read it as
              // plain text inside the card's text); the label replaces
              // the visible text so the host is read once.
              Semantics(
                key: const Key('assistSourceLink'),
                container: true,
                link: onOpenSource != null,
                label: onOpenSource == null
                    ? l.assistSourceHost(host)
                    : l.assistSourceLinkLabel(host),
                child: InkWell(
                  onTap: onOpenSource == null ? null : () => onOpenSource!(url),
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        l.assistSourceHost(host),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.primary,
                          decoration: TextDecoration.underline,
                          decorationColor: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (url != null && !view.sourceOfficial)
              Text(
                l.assistSourceNotOfficial,
                key: const Key('assistSourceNotOfficial'),
                style: muted,
              ),
            Text(
              view.fetchedOn.isNotEmpty
                  ? l.assistViaSaved(
                      provider.isEmpty ? '—' : provider,
                      view.fetchedOn,
                    )
                  : l.assistVia(
                      provider.isEmpty ? '—' : provider,
                      view.decidedOn.isEmpty ? '—' : view.decidedOn,
                    ),
              key: const Key('assistVia'),
              style: muted,
            ),
            Text(
              view.grounded ? l.assistGrounded : l.assistNotGrounded,
              key: const Key('assistGrounding'),
              style: muted,
            ),
            if (view.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              // Plain text, never a link: notes come from a web search.
              Text(
                view.notes,
                key: const Key('assistNotes'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (view.kind == AssistViewKind.appliedStale ||
                view.kind == AssistViewKind.suggestedStale) ...[
              const SizedBox(height: 8),
              Text(
                view.kind == AssistViewKind.appliedStale
                    ? l.assistStale
                    : l.assistSuggestionStale,
                key: const Key('assistStale'),
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (editFirst && buttons.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l.assistEditFirst,
                key: const Key('assistEditFirst'),
                style: muted,
              ),
            ],
            if (lookingUp) ...[const SizedBox(height: 4), _progress(context)],
            if (buttons.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 4, children: buttons),
            ],
          ],
        ),
      ),
    );
  }
}

/// One covered item: its menu name, option and serving, and the published
/// numbers.
class _ItemLines extends StatelessWidget {
  const _ItemLines({required this.item, this.showSizes = false});

  final AssistItemView item;

  /// A suggestion: every published size is listed (the user decides).
  final bool showSizes;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final c = item.calories;
    final r = item.caloriesRange;
    final kcal = c != null
        ? l.kcalAmount(formatKcal(c))
        : r != null
        ? l.kcalAmount('${formatKcal(r[0])}–${formatKcal(r[1])}')
        : null;
    final numbers = [
      ?kcal,
      if (item.proteinG != null)
        '${l.macroProteinShort} ${formatOneDecimal(item.proteinG!)} g',
      if (item.carbsG != null)
        '${l.macroCarbsShort} ${formatOneDecimal(item.carbsG!)} g',
      if (item.fatG != null)
        '${l.macroFatShort} ${formatOneDecimal(item.fatG!)} g',
    ].join(' · ');
    final detail = [
      if (item.option.isNotEmpty) item.option,
      if (item.serving.isNotEmpty) item.serving,
    ].join(' · ');
    final qty = item.qty == 1
        ? ''
        : ' × ${item.qty == item.qty.roundToDouble() ? item.qty.round() : item.qty}';
    final sizes = showSizes ? assistSizesText(l, item) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.menuItem.isNotEmpty)
          Text(item.menuItem, style: theme.textTheme.titleSmall),
        if (detail.isNotEmpty) Text(detail, style: muted),
        if (numbers.isNotEmpty)
          Text('$numbers$qty', style: theme.textTheme.bodyMedium),
        if (sizes != null)
          Text(sizes, key: const Key('assistSizes'), style: muted),
      ],
    );
  }
}
