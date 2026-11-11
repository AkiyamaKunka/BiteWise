/// The shared empty, error, loading and analyzing states.
///
/// Before run 7 every screen drew its own: Today's empty state had no
/// icon, History's was a bare Center(Text) with no padding, the two photo
/// overlays differed, and spinners were Material rings on iOS (U31).
library;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/tokens.dart';

/// A centred empty state: icon, title, optional message and action.
///
/// [EmptyState.sliver] fills the rest of a CustomScrollView (and still
/// scrolls when the text is taller than the screen).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.actionLabel,
    this.onAction,
  }) : _sliver = false;

  const EmptyState.sliver({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.actionLabel,
    this.onAction,
  }) : _sliver = true;

  final IconData icon;
  final String title;
  final String? message;

  /// A custom action widget; or pass [actionLabel] + [onAction] for the
  /// standard tonal button.
  final Widget? action;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool _sliver;

  @override
  Widget build(BuildContext context) {
    if (!_sliver) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: _body(context),
        ),
      );
    }
    // SliverFillRemaining(hasScrollBody: false) sizes itself from the
    // child's INTRINSIC height, and a ConstrainedBox's intrinsics ignore
    // its own max width — the text was measured at the full width and
    // overflowed by 280 px at AX5. Side padding measures what it lays out.
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final side = ((constraints.crossAxisExtent - _maxWidth) / 2)
            .clamp(0.0, double.infinity);
        return SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: Center(child: _body(context)),
          ),
        );
      },
    );
  }

  static const double _maxWidth = 320;

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final type = AppTypography.of(context);
    final button = action ??
        (actionLabel != null && onAction != null
            ? FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!))
            : null);
    return Padding(
      padding: const EdgeInsets.all(AppSpace.s32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: 44, color: colors.secondaryLabel),
          ),
          const SizedBox(height: AppSpace.s12),
          Semantics(
            header: true,
            child: Text(title,
                textAlign: TextAlign.center,
                style: type.title3.copyWith(color: colors.label)),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: colors.secondaryLabel)),
          ],
          if (button != null) ...[
            const SizedBox(height: AppSpace.s20),
            button,
          ],
        ],
      ),
    );
  }
}

/// A one-line failure with a Retry button. The raw error belongs in the
/// debug log, not here: [message] is the user's sentence.
class InlineError extends StatelessWidget {
  const InlineError({
    super.key,
    required this.message,
    this.onRetry,
    this.retryKey,
  });

  final String message;
  final VoidCallback? onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpace.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: ExcludeSemantics(
                  child: Icon(Icons.error_outline_rounded,
                      size: 20, color: colors.danger),
                ),
              ),
              const SizedBox(width: AppSpace.s8),
              Expanded(
                child: Text(message,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colors.label)),
              ),
            ],
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpace.s12),
            FilledButton.tonal(
              key: retryKey,
              onPressed: onRetry,
              child: Text(context.l10n.retry),
            ),
          ],
        ],
      ),
    );
  }
}

/// The platform's own spinner, centred (iOS: the activity indicator).
class LoadingState extends StatelessWidget {
  const LoadingState({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator.adaptive());
}

/// The scrim + capsule shown over a screen while a photo is analysed.
/// The label is a live region: a slow round trip is otherwise silent to a
/// screen reader until the outcome dialog.
class AnalyzingOverlay extends StatelessWidget {
  const AnalyzingOverlay({
    super.key,
    required this.label,
    this.labelKey,
    this.spinnerKey,
  });

  final String label;

  /// On the label Text (callers keep Key('photoAnalyzingText')).
  final Key? labelKey;

  /// On the spinner (callers keep Key('photoAnalyzing')).
  final Key? spinnerKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return ColoredBox(
      color: colors.scrim,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.s32),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.elevated,
              borderRadius: BorderRadius.circular(AppRadius.snack),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.s16, vertical: AppSpace.s12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator.adaptive(
                        key: spinnerKey, strokeWidth: 2.5),
                  ),
                  const SizedBox(width: AppSpace.s12),
                  Flexible(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(label,
                          key: labelKey,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: colors.label)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
