/// Renders NlExecutor replies: snackbars/dialogs for text, and THE delete
/// confirmation modal (spec §4.5 — nothing is deleted until the user
/// confirms; the modal dialog replaces the server's nonce/TTL machinery).
library;

import 'package:flutter/material.dart';

import '../core/contracts.dart';
import 'l10n.dart';
import 'theme/app_dialog.dart';
import 'theme/app_theme.dart' show AppButtonStyles;
import 'theme/tokens.dart';

/// Present each reply in order. Delete confirmations block on the modal;
/// plain replies use a snackbar (short) or dialog (long).
///
/// [onNotApplied], when given, takes the plain replies that changed
/// nothing — a refusal, an error, a question — instead of the snackbar or
/// dialog, so the screen can keep them on the page: as a snackbar, Fix's
/// "The provider rejected the API key…" was gone after 4 s (U11).
///
/// Returns whether anything was actually changed: a reply the executor
/// marked [NlReply.applied], or a delete the user confirmed. A refusal, an
/// error, chat, or a cancelled delete changes nothing.
Future<bool> presentNlReplies(
  BuildContext context,
  NlExecutor executor,
  List<NlReply> replies, {
  void Function(NlReply reply)? onNotApplied,
}) async {
  var changed = replies.any((r) => r.applied);
  for (final reply in replies) {
    if (!context.mounted) return changed;
    if (reply.needsDeleteConfirmation) {
      if (await showDeleteConfirmation(context, executor, reply)) {
        changed = true;
      }
    } else if (!reply.applied && onNotApplied != null) {
      onNotApplied(reply);
    } else if (reply.text.length <= 120) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(reply.text)));
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => appAlertDialog(
          content: Text(reply.text),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(ctx.l10n.okButton),
            ),
          ],
        ),
      );
    }
  }
  return changed;
}

/// The modal delete confirmation (spec §4.5): lists every staged meal label,
/// warns "This cannot be undone.", and only the Delete button triggers
/// confirmPendingDelete. Cancel (or dismissing) deletes nothing. Returns
/// whether the delete ran.
Future<bool> showDeleteConfirmation(
  BuildContext context,
  NlExecutor executor,
  NlReply reply,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    // Scrollable as a whole (A1): a long list of meals at a large text size
    // left the title and actions no room.
    builder: (ctx) => appAlertDialog(
      title: Text(ctx.l10n.nlDeleteTitle),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The executor's prose repeats the labels and the warning (and
          // the model's reasoning) in English — on this modal the labels
          // ARE the content; the prose is only a fallback when there are
          // none (loop find 2026-10-07).
          if (reply.pendingDeleteLabels.isEmpty && reply.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s8),
              child: Text(reply.text),
            ),
          for (final label in reply.pendingDeleteLabels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.s2),
              child: Text('• $label'),
            ),
          const SizedBox(height: AppSpace.s8),
          // The warning is a footnote, in the danger colour.
          Text(
            ctx.l10n.nlCannotUndo,
            style: Theme.of(ctx)
                .textTheme
                .bodySmall
                ?.copyWith(color: ctx.colors.danger),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('nlDeleteCancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l10n.cancel),
        ),
        // iOS's red alert action: a quiet fill with a danger label, so
        // Delete never looks like the accent Save.
        FilledButton(
          key: const Key('nlDeleteConfirm'),
          style: AppButtonStyles.destructive(ctx),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(ctx.l10n.delete),
        ),
      ],
    ),
  );
  // cancel/dismiss must not delete (spec §4.5)
  if (confirmed != true) return false;
  final result = await executor.confirmPendingDelete(reply.pendingDeleteIds);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
  }
  // confirmPendingDelete with no ids deletes nothing (it answers
  // "cancelled"); the executor never stages an empty set, but stay honest.
  return reply.pendingDeleteIds.isNotEmpty;
}
