/// Renders NlExecutor replies: snackbars/dialogs for text, and THE delete
/// confirmation modal (spec §4.5 — nothing is deleted until the user
/// confirms; the modal dialog replaces the server's nonce/TTL machinery).
library;

import 'package:flutter/material.dart';

import '../core/contracts.dart';
import 'l10n.dart';

/// Present each reply in order. Delete confirmations block on the modal;
/// plain replies use a snackbar (short) or dialog (long).
Future<void> presentNlReplies(
  BuildContext context,
  NlExecutor executor,
  List<NlReply> replies,
) async {
  for (final reply in replies) {
    if (!context.mounted) return;
    if (reply.needsDeleteConfirmation) {
      await showDeleteConfirmation(context, executor, reply);
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
}

/// The modal delete confirmation (spec §4.5): lists every staged meal label,
/// warns "This cannot be undone.", and only the Delete button triggers
/// confirmPendingDelete. Cancel (or dismissing) deletes nothing.
Future<void> showDeleteConfirmation(
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
  if (confirmed != true) return; // cancel/dismiss must not delete (spec §4.5)
  final result = await executor.confirmPendingDelete(reply.pendingDeleteIds);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
}
