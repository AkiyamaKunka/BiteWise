/// Renders NlExecutor replies: snackbars/dialogs for text, and THE delete
/// confirmation modal (spec §4.5 — nothing is deleted until the user
/// confirms; the modal dialog replaces the server's nonce/TTL machinery).
library;

import 'package:flutter/material.dart';

import '../core/contracts.dart';
import 'l10n.dart';

/// Present each reply in order. Delete confirmations block on the modal;
/// plain replies use a snackbar (short) or dialog (long).
///
/// Returns whether anything was actually changed: a reply the executor
/// marked [NlReply.applied], or a delete the user confirmed. A refusal, an
/// error, chat, or a cancelled delete changes nothing.
Future<bool> presentNlReplies(
  BuildContext context,
  NlExecutor executor,
  List<NlReply> replies,
) async {
  var changed = replies.any((r) => r.applied);
  for (final reply in replies) {
    if (!context.mounted) return changed;
    if (reply.needsDeleteConfirmation) {
      if (await showDeleteConfirmation(context, executor, reply)) {
        changed = true;
      }
    } else if (reply.text.length <= 120) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(reply.text)));
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: SingleChildScrollView(child: Text(reply.text)),
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
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.nlDeleteTitle),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The executor's prose repeats the labels and the warning (and
            // the model's reasoning) in English — on this modal the labels
            // ARE the content; the prose is only a fallback when there are
            // none (loop find 2026-10-07).
            if (reply.pendingDeleteLabels.isEmpty && reply.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(reply.text),
              ),
            for (final label in reply.pendingDeleteLabels)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• $label'),
              ),
            const SizedBox(height: 8),
            Text(
              ctx.l10n.nlCannotUndo,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('nlDeleteCancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l10n.cancel),
        ),
        FilledButton(
          key: const Key('nlDeleteConfirm'),
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
