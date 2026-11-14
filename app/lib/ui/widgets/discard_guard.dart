/// Asks before a back gesture throws away what the user typed (Android
/// push, 2026-11-13). On Android the edge back gesture is easy to make by
/// accident while editing: one back closed the keyboard, the next closed
/// Edit meal or the Body log sheet, and what had been typed was gone with
/// no question (UX run screenshots 30, 33, 68).
///
/// [DiscardChangesGuard] holds a pop only while [DiscardChangesGuard.dirty]
/// is true. A clean screen pops as before, so iOS keeps its swipe-back
/// there (a held pop disables that gesture; the back button still asks).
/// It covers every pop that asks first: the system back gesture and
/// button, the app bar's back button and a tap outside a sheet
/// (Navigator.maybePop). A screen's own Save or Delete pops with
/// Navigator.pop, which is never held.
library;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/app_dialog.dart';
import '../theme/app_theme.dart' show AppButtonStyles;

/// The two answers of the discard question. Any other result the
/// question's dialog closes with is a screen's own pop that reached the
/// dialog while it was open ([DiscardChangesGuard] hands it on).
enum DiscardAnswer { keep, discard }

/// 'Discard changes?': [DiscardAnswer.discard], [DiscardAnswer.keep], null
/// (a tap outside or back: stay), or whatever a pop meant for the screen
/// under it closed it with.
Future<Object?> _askDiscardChanges(BuildContext context) => showDialog<Object?>(
      context: context,
      builder: (ctx) {
        final l = ctx.l10n;
        return appAlertDialog(
          key: const Key('discardChangesDialog'),
          title: Text(l.discardChangesTitle),
          content: Text(l.discardChangesBody),
          actions: [
            TextButton(
                key: const Key('discardChangesKeep'),
                onPressed: () => Navigator.pop(ctx, DiscardAnswer.keep),
                child: Text(l.discardChangesKeep)),
            FilledButton(
                key: const Key('discardChangesDiscard'),
                style: AppButtonStyles.destructive(ctx),
                onPressed: () => Navigator.pop(ctx, DiscardAnswer.discard),
                child: Text(l.discardChangesDiscard)),
          ],
        );
      },
    );

/// Holds the route's pop while [dirty] and asks 'Discard changes?';
/// Discard pops the route (with no result, like a plain back). While
/// [busy] (a save or delete under way) a held pop is ignored: the screen
/// closes itself when that finishes.
///
/// If the screen pops itself while the question is open anyway (an
/// asynchronous path that is not [busy]), that pop closes the question
/// instead: the guard hands its result on, so the screen still closes
/// and its caller gets what it was given (review 2026-11-13: a Save's
/// `true` read as Discard, and the caller got null).
class DiscardChangesGuard extends StatefulWidget {
  const DiscardChangesGuard({
    super.key,
    required this.dirty,
    this.busy = false,
    required this.child,
  });

  final bool dirty;
  final bool busy;
  final Widget child;

  @override
  State<DiscardChangesGuard> createState() => _DiscardChangesGuardState();
}

class _DiscardChangesGuardState extends State<DiscardChangesGuard> {
  /// The question is open, or about to be: two pops that reach the guard
  /// before its dialog is up ask once.
  bool _asking = false;

  Future<void> _held() async {
    if (_asking || widget.busy) return;
    _asking = true;
    final Object? answer;
    try {
      answer = await _askDiscardChanges(context);
    } finally {
      _asking = false;
    }
    if (!mounted || answer == null || answer == DiscardAnswer.keep) return;
    // Only while this screen is the route on top: a route that came up
    // meanwhile is not popped in its place.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final navigator = Navigator.of(context);
    if (answer == DiscardAnswer.discard) {
      navigator.pop();
    } else {
      navigator.pop(answer); // the screen's own pop, handed on
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
        canPop: !widget.dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _held();
        },
        child: widget.child,
      );
}
