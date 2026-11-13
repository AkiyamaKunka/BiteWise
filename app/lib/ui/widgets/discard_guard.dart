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

/// 'Discard changes?': true = Discard, false (Keep editing, a tap outside
/// or back) = stay.
Future<bool> confirmDiscardChanges(BuildContext context) async {
  final discard = await showDialog<bool>(
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
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.discardChangesKeep)),
          FilledButton(
              key: const Key('discardChangesDiscard'),
              style: AppButtonStyles.destructive(ctx),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.discardChangesDiscard)),
        ],
      );
    },
  );
  return discard == true;
}

/// Holds the route's pop while [dirty] and asks [confirmDiscardChanges];
/// Discard pops the route (with no result, like a plain back). While
/// [busy] (a save or delete under way) a held pop is ignored: the
/// screen's own pop when that finishes would otherwise close the question
/// instead of the screen.
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
  /// The question is open: a second back while it is up asks nothing more.
  bool _asking = false;

  Future<void> _held() async {
    if (_asking || widget.busy) return;
    _asking = true;
    final bool discard;
    try {
      discard = await confirmDiscardChanges(context);
    } finally {
      _asking = false;
    }
    if (!discard || !mounted) return;
    // Still the route on top (nothing else popped it meanwhile): leave.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    Navigator.of(context).pop();
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
