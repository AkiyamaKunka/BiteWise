/// iCloud Backup's words and questions (1.7.0): the status line under the
/// switch, the one-time notice, the restore offer, the takeover, the
/// turn-off choice and the red confirmations. The app shell raises the
/// notice and the restore offer (BackupCoordinator.prompt); Settings ›
/// Your Data raises the rest.
library;

import 'package:flutter/material.dart';

import '../services/backup/backup_coordinator.dart';
import '../services/backup/backup_format.dart';
import 'app_formats.dart';
import 'l10n.dart';
import 'outcome_text.dart' show dayTimeLabel;
import 'theme/app_dialog.dart';
import 'theme/tokens.dart';
import 'widgets/grouped.dart';

/// '1.2 MB' / '84 KB'.
String backupSizeLabel(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The backup's date as the sheets show it ('11-09' style via
/// AppFormats.shortDate), from a header's exported_at.
String backupDateLabel(BuildContext context, BackupHeader h) {
  final stamp = DateTime.tryParse(h.exportedAt ?? '');
  if (stamp == null) return h.lastDate ?? '';
  final local = stamp.toLocal();
  final iso = '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
  return AppFormats.shortDate(context, iso);
}

/// The status line under the iCloud Backup switch. A backup that landed
/// without some months of this iPhone's pictures (their files are another
/// iPhone's) says so instead of reading as complete.
String backupStatusLine(BuildContext context, BackupStatus s,
    {DateTime? now}) {
  final l = context.l10n;
  if (s.busy) return l.backupStatusChecking;
  final line = _statusLine(context, s, now: now);
  final landed =
      s.state == BackupState.ok || s.state == BackupState.uploading;
  return landed && s.skippedMonths > 0
      ? '$line ${l.backupStatusSkippedMonths(s.skippedMonths)}'
      : line;
}

String _statusLine(BuildContext context, BackupStatus s, {DateTime? now}) {
  final l = context.l10n;
  return switch (s.state) {
    BackupState.off => l.backupStatusOff,
    BackupState.needsNotice => l.backupStatusNotStarted,
    BackupState.checking => l.backupStatusChecking,
    BackupState.never => l.backupStatusNever,
    BackupState.ok => s.lastOkAt == null
        ? l.backupStatusNever
        : l.backupStatusLast(
            dayTimeLabel(l, s.lastOkAt!.toLocal(), now: now),
            backupSizeLabel(s.bytes)),
    BackupState.uploading => l.backupStatusUploading,
    BackupState.quota => l.backupStatusQuota,
    BackupState.noAccount => l.backupStatusNoAccount,
    BackupState.unavailable => l.backupStatusUnavailable,
    BackupState.otherDevice => l.backupStatusOtherDevice(
        s.other == null ? '' : backupDateLabel(context, s.other!)),
    BackupState.changedElsewhere => l.backupStatusChangedElsewhere,
    BackupState.unknownFile => l.backupStatusUnknownFile,
    BackupState.twoCopies => l.backupStatusTwoCopies,
    BackupState.missing => l.backupStatusMissing,
    BackupState.shrink => l.backupStatusShrink(s.count),
    BackupState.emptyLog => l.backupStatusEmptyLog(s.count),
    BackupState.failed => l.backupStatusFailed,
  };
}

/// Whether the footer may name the Files app: only once a backup landed.
bool backupHasWritten(BackupStatus s) => s.lastOkAt != null;

/// The Settings › Your Data footer on iPhone, by what iCloud Backup does
/// now: while it is off, or iCloud has no account or is not available,
/// nothing is copied, so the footer says so and points to an export
/// (never "they come back if you reinstall"). Otherwise it names the Files
/// app once a backup landed.
String backupFooter(AppLocalizations l, BackupStatus s) => switch (s.state) {
      BackupState.off ||
      BackupState.noAccount ||
      BackupState.unavailable =>
        l.backupICloudFooterOff,
      _ => backupHasWritten(s) ? l.backupICloudFooter : l.backupICloudFooterBefore,
    };

/// What a delete says: done, done in part (try again), or not done.
String backupDeleteMessage(AppLocalizations l, BackupDeleteResult r) =>
    switch (r) {
      BackupDeleteResult.deleted => l.backupDeleted,
      BackupDeleteResult.partial => l.backupDeletePartial,
      BackupDeleteResult.failed => l.backupActionFailed,
    };

void _snack(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// A red confirmation. True only on the red button.
Future<bool> confirmBackupDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final l = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => appAlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel)),
        TextButton(
          key: const Key('backupConfirmDestructive'),
          style: TextButton.styleFrom(foregroundColor: ctx.colors.danger),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// The one-time notice: Keep On / Turn Off. Dismissing it answers nothing
/// (it comes back at the next launch).
Future<void> showBackupNotice(
    BuildContext context, BackupCoordinator backup) async {
  final l = context.l10n;
  final keep = await showDialog<bool>(
    context: context,
    builder: (ctx) => appAlertDialog(
      key: const Key('backupNotice'),
      title: Text(l.backupNoticeTitle),
      content: Text(l.backupNoticeBody),
      actions: [
        TextButton(
            key: const Key('backupNoticeOff'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.backupNoticeOff)),
        FilledButton(
            key: const Key('backupNoticeKeep'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.backupNoticeKeep)),
      ],
    ),
  );
  if (keep == null) {
    backup.prompt.value = null;
    return;
  }
  await backup.answerNotice(keepOn: keep);
}

enum _OfferChoice { restore, fresh, notNow }

/// The restore offer: Restore (default) / Start Fresh… / Not Now, with
/// the backup's counts and date, a merge note when this phone already has
/// meals, and a note when restoring makes this iPhone take the backup
/// over. Dismissing the sheet is Not Now for this launch only.
Future<void> showRestoreOffer(BuildContext context, BackupCoordinator backup,
    BackupCandidate candidate, int localMeals) async {
  final l = context.l10n;
  final h = candidate.header;
  final choice = await showGroupedSheet<_OfferChoice>(
    context,
    title: l.backupRestoreTitle,
    subtitle: [
      l.backupRestoreBody(h.meals, backupDateLabel(context, h)),
      if (localMeals > 0) l.backupRestoreMergeNote(localMeals),
      if (backup.restoreTakesOver(candidate)) l.backupRestoreTakesOver,
      l.backupRestoreNotIncluded,
    ].join('\n\n'),
    builder: (ctx) => GroupedSection(
      children: [
        GroupedRow(
          key: const Key('backupRestore'),
          icon: Icons.cloud_download_outlined,
          iconColor: Theme.of(ctx).colorScheme.primary,
          title: l.backupRestoreAction,
          showChevron: false,
          onTap: () => Navigator.of(ctx).pop(_OfferChoice.restore),
        ),
        GroupedRow(
          key: const Key('backupStartFresh'),
          title: l.backupStartFresh,
          destructive: true,
          showChevron: false,
          onTap: () => Navigator.of(ctx).pop(_OfferChoice.fresh),
        ),
        GroupedRow(
          key: const Key('backupNotNow'),
          title: l.backupNotNow,
          showChevron: false,
          onTap: () => Navigator.of(ctx).pop(_OfferChoice.notNow),
        ),
      ],
    ),
  );
  if (choice == null) {
    // Not Now for this launch only: the catch-up it held may run.
    await backup.dismissOffer();
    return;
  }
  if (!context.mounted) return;
  switch (choice) {
    case _OfferChoice.restore:
      final s = await backup.restore(candidate);
      if (!context.mounted) return;
      if (!s.ok) {
        _snack(context, l.backupRestoreFailed);
      } else {
        _snack(
            context,
            [
              l.backupRestoreDone(s.mealsAdded, s.thumbsAdded),
              if (s.failedMonths > 0) l.backupRestorePartial(s.failedMonths),
              if (s.mealsSkippedDeleted > 0)
                l.importDeletedLeftOut(s.mealsSkippedDeleted),
            ].join(' '));
      }
    case _OfferChoice.fresh:
      final sure = await confirmBackupDestructive(context,
          title: l.backupStartFreshTitle,
          body: l.backupStartFreshBody(h.meals),
          action: l.backupDeleteAction);
      if (!context.mounted) return;
      if (!sure) {
        // Back to the offer: nothing was answered.
        return showRestoreOffer(context, backup, candidate, localMeals);
      }
      final result = await backup.startFresh(candidate);
      if (context.mounted) _snack(context, backupDeleteMessage(l, result));
    case _OfferChoice.notNow:
      await backup.declineOffer(candidate);
  }
}

enum _TakeOver { merge, replace }

/// Back Up From This iPhone…: Combine, Then Back Up (default) or Replace
/// the Backup… (red, confirmed), with both sides' counts.
Future<void> showTakeOverSheet(BuildContext context, BackupCoordinator backup,
    {required int localMeals}) async {
  final l = context.l10n;
  final s = backup.status.value;
  final other = s.other;
  final unreadable = s.state == BackupState.unknownFile || other == null;
  final choice = await showGroupedSheet<_TakeOver>(
    context,
    title: l.backupTakeOverTitle,
    subtitle: unreadable
        ? l.backupTakeOverUnreadable
        : l.backupTakeOverBody(other.meals, localMeals),
    builder: (ctx) => GroupedSection(
      children: [
        if (!unreadable)
          GroupedRow(
            key: const Key('backupTakeOverMerge'),
            icon: Icons.merge_type_rounded,
            iconColor: Theme.of(ctx).colorScheme.primary,
            title: l.backupTakeOverMerge,
            showChevron: false,
            onTap: () => Navigator.of(ctx).pop(_TakeOver.merge),
          ),
        GroupedRow(
          key: const Key('backupTakeOverReplace'),
          title: l.backupTakeOverReplace,
          destructive: true,
          showChevron: false,
          onTap: () => Navigator.of(ctx).pop(_TakeOver.replace),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == _TakeOver.replace) {
    final sure = await confirmBackupDestructive(context,
        title: l.backupReplaceTitle,
        body: l.backupReplaceBody,
        action: l.backupReplaceAction);
    if (!sure || !context.mounted) return;
  }
  final ok = await backup.takeOver(replace: choice == _TakeOver.replace);
  if (context.mounted) _snack(context, ok ? l.backupDone : l.backupActionFailed);
}

enum _TurnOff { keep, delete }

/// The switch turned off: Keep the Backup in iCloud (default) / Delete
/// It… (red, confirmed; this install's files only) / Cancel (the switch
/// stays on).
Future<void> showTurnOffSheet(
    BuildContext context, BackupCoordinator backup) async {
  final l = context.l10n;
  final choice = await showGroupedSheet<_TurnOff>(
    context,
    title: l.backupTurnOffTitle,
    builder: (ctx) => GroupedSection(
      children: [
        GroupedRow(
          key: const Key('backupTurnOffKeep'),
          title: l.backupTurnOffKeep,
          showChevron: false,
          onTap: () => Navigator.of(ctx).pop(_TurnOff.keep),
        ),
        if (backupHasWritten(backup.status.value) ||
            backup.status.value.ownsFiles)
          GroupedRow(
            key: const Key('backupTurnOffDelete'),
            title: l.backupTurnOffDelete,
            destructive: true,
            showChevron: false,
            onTap: () => Navigator.of(ctx).pop(_TurnOff.delete),
          ),
        GroupedRow(
          key: const Key('backupTurnOffCancel'),
          title: l.cancel,
          showChevron: false,
          onTap: () => Navigator.of(ctx).pop(),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == _TurnOff.keep) {
    await backup.turnOff(deleteFiles: false);
    return;
  }
  final sure = await confirmBackupDestructive(context,
      title: l.backupDeleteTitle,
      body: l.backupDeleteBody,
      action: l.backupDeleteAction);
  if (!sure || !context.mounted) return;
  final result = await backup.turnOff(deleteFiles: true);
  if (result != null && context.mounted) {
    _snack(context, backupDeleteMessage(l, result));
  }
}

/// Delete iCloud Backup… (the empty-log row, and the row shown while the
/// switch is off and this install's files are still in iCloud):
/// confirmed, this install's files only, the switch left as it is.
Future<void> confirmDeleteBackup(
    BuildContext context, BackupCoordinator backup) async {
  final l = context.l10n;
  final sure = await confirmBackupDestructive(context,
      title: l.backupDeleteTitle,
      body: l.backupDeleteBody,
      action: l.backupDeleteAction);
  if (!sure || !context.mounted) return;
  final result = await backup.deleteBackup();
  if (context.mounted) _snack(context, backupDeleteMessage(l, result));
}
