/// The data section of Settings: export the whole food log to a file and
/// import one back by merge. The privacy-policy row shares this section,
/// but its tap stays with the Settings screen, which owns the injectable
/// URL opener.
///
/// Export on Android offers Save to Device… (the system's save screen,
/// save_file_channel.dart) before Share…: Android's share sheet has no
/// "Save to Files", and the Android footer tells people to export before
/// changing phones.
library;

import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, HapticFeedback;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/contracts.dart';
import '../../../services/backup/backup_coordinator.dart';
import '../../../services/backup/backup_files.dart';
import '../../../services/backup/backup_format.dart';
import '../../../services/backup/file_pick_channel.dart';
import '../../../services/backup/save_file_channel.dart';
import '../../backup_sheets.dart';
import '../../format.dart' show isoDate;
import '../../l10n.dart';
import '../../theme/app_dialog.dart';
import '../../theme/tokens.dart';
import '../../widgets/grouped.dart';
import '../../widgets/small_spinner.dart';

/// The shared export's file name: 'chopstats-2026-10-31.json' (it was
/// still 'calorietracker-…' after the Chopstats rename).
String exportFileName(DateTime now) => 'chopstats-${isoDate(now)}.json';

/// Whether [name] is an export this app wrote: today's name or the one
/// from before the rename (the sweep before each export removes both).
bool isExportFileName(String name) =>
    name.startsWith('chopstats-') || name.startsWith('calorietracker-');

/// Hands the export file at [path] to the share sheet.
typedef ShareExportFile = Future<void> Function(String path, String subject);

Future<void> _shareWithSharePlus(String path, String subject) async {
  await SharePlus.instance
      .share(ShareParams(files: [XFile(path)], subject: subject));
}

/// Where Export sends the file on Android.
enum _ExportTo { device, share }

class DataSection extends StatefulWidget {
  const DataSection({
    super.key,
    required this.dao,
    required this.onOpenPrivacyPolicy,
    this.privacyPolicyUrl,
    this.backup,
    this.filePicker = const PlatformFilePicker(),
    this.platform = 'ios',
    this.androidBackupNote = false,
    this.onImported,
    this.fileSaver = const PlatformFileSaver(),
    this.shareFile = _shareWithSharePlus,
    this.tempDir = getTemporaryDirectory,
  });

  final MealsDao dao;

  /// iCloud Backup (iPhone; 1.7.0). Null hides its rows: Android, and the
  /// tests that do not test it.
  final BackupCoordinator? backup;

  /// Import › Choose File… (both platforms).
  final FilePicker filePicker;

  /// 'ios' | 'android', written into an export's header.
  final String platform;

  /// Android: the footer says what Android's own backup does and to
  /// export a file before changing phones.
  final bool androidBackupNote;

  /// After an import added rows: the screens reload and cached thumbnails
  /// are dropped.
  final VoidCallback? onImported;

  /// Export › Save to Device… (Android).
  final FileSaver fileSaver;

  /// Export › Share… (and Export on iPhone).
  final ShareExportFile shareFile;

  /// Where the export is written: the app's cache folder, the only one
  /// the native save accepts.
  final Future<Directory> Function() tempDir;

  /// The 隐私政策 / Privacy Policy row's tap.
  final VoidCallback onOpenPrivacyPolicy;

  /// Where that row goes, so screen readers announce it as a link.
  final Uri? privacyPolicyUrl;

  @override
  State<DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<DataSection> {
  final TextEditingController _importController = TextEditingController();
  bool _exporting = false;
  bool _importing = false;

  /// This build cannot save to the device (no `saveFile` in MainActivity):
  /// Export goes straight to Share for the rest of the session.
  bool _saveUnavailable = false;

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  /// Import by FILE or by PASTE. Choose File… (1.7.0) opens the system
  /// picker through the app's own channels (no file-picker plugin: the
  /// iCloud Backup plugin on iOS, MainActivity on Android), because a full
  /// export with pictures is tens of MB and the clipboard cannot carry it.
  /// Paste stays for every transfer route that puts text on the clipboard
  /// (WeChat/AirDrop/email/Termux). The parser refuses anything that is
  /// not a CalorieTracker export, so a mis-paste is a message, never a
  /// corrupted log.
  ///
  /// A year of meals is 1–2 MB of JSON. Pasted into the field, that much
  /// text froze the first frame for a second or two and cost hundreds of
  /// MB on iOS, so 从剪贴板导入 reads the clipboard straight into the
  /// import and shows only its size; the field stays for small pastes.
  Future<void> _import() async {
    final l10n = context.l10n; // read before the dialog await
    // The controller is owned by the STATE, not the dialog closure: a
    // locally-created one gets disposed while the dialog's exit animation
    // is still rebuilding the field ("A TextEditingController was used
    // after being disposed" — caught by the new test).
    _importController.clear();
    String? clipboardPayload; // never put in the field
    String? clipboardNote;
    var chooseFile = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
          builder: (ctx, setDialog) => appAlertDialog(
        title: Text(l10n.importDialogTitle),
        // The dialog scrolls title and content together (A1): an
        // AlertDialog's content is laid out against the available height,
        // and an unbounded Column here once overflowed by ~97000 px.
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.importDialogBody),
            const SizedBox(height: 12),
            // A file from Files / iCloud Drive / the Android file picker
            // (1.7.0): several at once, records before pictures.
            FilledButton.icon(
              key: const Key('importChooseFile'),
              icon: const Icon(Icons.folder_open_rounded),
              label: Text(l10n.importChooseFile),
              onPressed: () {
                chooseFile = true;
                Navigator.of(ctx).pop(false);
              },
            ),
            const SizedBox(height: 8),
            // The clipboard is THE path for a real export (MB of
            // text): first, and a real button. Below the field it sat
            // under the keyboard on an SE, and the field took focus by
            // itself, so people pasted MBs into it (U20).
            FilledButton.tonalIcon(
                key: const Key('importFromClipboard'),
                // The tonal fill is the elevated dialog's own colour in
                // dark mode (#2C2C2E): one step up, or the button has no
                // edge at all.
                style: Theme.of(ctx).brightness == Brightness.dark
                    ? FilledButton.styleFrom(
                        backgroundColor: ctx.colors.highlight)
                    : null,
                icon: const Icon(Icons.content_paste_rounded),
                label: Text(l10n.importFromClipboard),
                onPressed: () async {
                  String? text;
                  Object? error;
                  try {
                    text = (await Clipboard.getData(Clipboard.kTextPlain))
                        ?.text;
                  } catch (e) {
                    error = e;
                  }
                  if (!ctx.mounted) return;
                  setDialog(() {
                    if (error != null) {
                      clipboardPayload = null;
                      clipboardNote = l10n.importFailed('$error');
                    } else if (text == null || text.trim().isEmpty) {
                      clipboardPayload = null;
                      clipboardNote = l10n.importClipboardEmpty;
                    } else {
                      clipboardPayload = text;
                      // What 从剪贴板导入 shows instead of the text.
                      clipboardNote = l10n.importClipboardRead(
                          backupSizeLabel(utf8.encode(text).length));
                    }
                  });
                },
              ),
            if (clipboardNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(clipboardNote!,
                    key: const Key('importClipboardSize')),
              ),
            if (clipboardPayload == null) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('importField'),
                controller: _importController,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: l10n.importFieldHint,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancel)),
          FilledButton(
              key: const Key('importConfirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.importAction)),
        ],
      )),
    );
    final payload = clipboardPayload ?? _importController.text;
    if (chooseFile && mounted) return _importFiles();
    if (go != true || !mounted) return;
    setState(() => _importing = true);
    try {
      final summary = await widget.dao.importJson(payload);
      if (!mounted) return;
      _imported(summary);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(importSummaryText(l10n, summary))));
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_refusalText(l10n, e))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.importFailed('$e'))));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Rows came in: the screens reload, the thumbnail cache is dropped, and
  /// iCloud Backup runs (an import is a change worth backing up now).
  void _imported(ImportSummary s) {
    if (s.totalAdded == 0 && s.thumbsAdded == 0) return;
    widget.onImported?.call();
    widget.backup?.afterImport();
  }

  /// Import › Choose File…: records and full files first, then pictures
  /// by month, each merged; the picked copies are deleted afterwards. A
  /// file over 100 MB is refused before it is read (its 16 KB header
  /// decides the order); one that could not be copied is reported as
  /// such.
  Future<void> _importFiles() async {
    final l10n = context.l10n;
    // Android answers only once it has copied the picked files (seconds
    // for a large one from a cloud drive), after its picker closed: the
    // row is busy from the start, so no second pick runs meanwhile
    // (MainActivity.kt holds its own call busy too). iOS answers after
    // its picker's own copy, and a picker swiped away is reported not to
    // answer on some iOS versions: the row stays usable while it is up.
    final busyFirst = widget.platform == 'android';
    if (busyFirst) setState(() => _importing = true);
    final PickedFiles picked;
    try {
      picked = await widget.filePicker.pickJsonFiles();
    } finally {
      // Set again below when there is something to import.
      if (busyFirst && mounted) setState(() => _importing = false);
    }
    if (!mounted) return;
    if (picked.unavailable) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.importPickUnavailable)));
      return;
    }
    if (picked.cancelled ||
        (picked.paths.isEmpty && picked.tooBig == 0 && picked.failed == 0)) {
      return;
    }
    setState(() => _importing = true);
    var tooBig = picked.tooBig;
    final summaries = <ImportSummary>[];
    String? refusal;
    try {
      final order = <(int, String, String)>[];
      for (final p in picked.paths) {
        final f = File(p);
        if (await f.length() > kMaxImportFileBytes) {
          tooBig++;
          continue;
        }
        final raf = await f.open();
        final head = await raf.read(kBackupHeaderLimit);
        await raf.close();
        final h = parseBackupHeader(head);
        order.add((h?.kind == BackupKind.pictures ? 1 : 0, h?.month ?? '', p));
      }
      order.sort((a, b) =>
          a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
      for (final (_, _, path) in order) {
        try {
          summaries.add(
              await widget.dao.importJson(await File(path).readAsString()));
        } on FormatException catch (e) {
          refusal = _refusalText(l10n, e);
        }
      }
    } catch (e) {
      refusal = l10n.importFailed('$e');
    } finally {
      for (final p in picked.paths) {
        try {
          File(p).deleteSync();
        } catch (_) {}
      }
      if (mounted) setState(() => _importing = false);
    }
    if (!mounted) return;
    final total = combineImportSummaries(summaries);
    _imported(total);
    final lines = [
      if (summaries.isNotEmpty) importSummaryText(l10n, total),
      ?refusal,
      if (tooBig > 0) l10n.importTooBig,
      // Never "over 100 MB" for a file that could not be read at all.
      if (picked.failed > 0) l10n.importPickUnavailable,
    ];
    if (lines.isEmpty) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(lines.join(' '))));
  }

  /// The parser's refusal in the user's language. [ExportFormatException]
  /// carries WHY; a plain FormatException (nothing throws one today, but
  /// the DAO contract allows it) gets the generic failure line with its
  /// own message rather than a silent swallow.
  static String _refusalText(AppLocalizations l10n, FormatException e) {
    if (e is! ExportFormatException) return l10n.importFailed(e.message);
    return switch (e.refusal) {
      ExportRefusal.notJson => l10n.importErrNotJson,
      ExportRefusal.notExport => l10n.importErrNotExport,
      ExportRefusal.wrongFormatTag => l10n.importErrWrongFormatTag,
      ExportRefusal.badVersion => l10n.importErrBadVersion,
      ExportRefusal.noTables => l10n.importErrNoTables,
    };
  }

  /// Android: Save to Device… first, Share… second, asked once the file
  /// is written (null = cancelled). iPhone, and a build without the save:
  /// Share, as before.
  Future<_ExportTo?> _exportTarget(AppLocalizations l10n) async {
    if (widget.platform != 'android' || _saveUnavailable) {
      return _ExportTo.share;
    }
    final theme = Theme.of(context);
    // No spinner on the row behind the sheet.
    setState(() => _exporting = false);
    final to = await showGroupedSheet<_ExportTo>(
      context,
      title: l10n.exportSheetTitle,
      builder: (ctx) => GroupedSection(
        children: [
          GroupedRow(
            key: const Key('exportSaveToDevice'),
            icon: Icons.save_alt_rounded,
            iconColor: theme.colorScheme.primary,
            title: l10n.exportSaveToDevice,
            showChevron: false,
            onTap: () => Navigator.of(ctx).pop(_ExportTo.device),
          ),
          GroupedRow(
            key: const Key('exportShare'),
            icon: Icons.share_rounded,
            iconColor: theme.colorScheme.secondary,
            title: l10n.exportShare,
            showChevron: false,
            onTap: () => Navigator.of(ctx).pop(_ExportTo.share),
          ),
          GroupedRow(
            key: const Key('exportCancel'),
            title: l10n.cancel,
            showChevron: false,
            onTap: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
    if (mounted) setState(() => _exporting = true);
    return to;
  }

  /// Save to Device… with the export at [file]. The temp export is deleted
  /// afterwards whatever the answer (the native side never deletes it),
  /// except on [SaveFileStatus.unavailable]: then it is shared instead,
  /// and the share target still has to read it.
  Future<void> _saveToDevice(File file, AppLocalizations l10n) async {
    final name = file.path.split('/').last;
    final status = await widget.fileSaver
        .saveFile(path: file.path, name: name, mime: exportMimeType);
    if (status == SaveFileStatus.unavailable) {
      _saveUnavailable = true;
      await widget.shareFile(file.path, l10n.exportShareSubject);
      return;
    }
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    final line = switch (status) {
      SaveFileStatus.ok => l10n.exportSaved,
      SaveFileStatus.busy => l10n.exportSaveBusy,
      SaveFileStatus.failed => l10n.exportSaveFailed,
      // Closed by the user: nothing to say.
      SaveFileStatus.cancelled || SaveFileStatus.unavailable => null,
    };
    if (line != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(line)));
    }
  }

  Future<void> _export() async {
    final l10n = context.l10n; // read before the awaits
    setState(() => _exporting = true);
    try {
      // The data first (a database failure is said as one), then the disk.
      final writer =
          BackupFileWriter(dao: widget.dao, platform: widget.platform);
      final snapshot = await writer.snapshotFull();
      // A FILE, not intent text: Android delivers EXTRA_TEXT through one
      // binder transaction with a ~1 MB hard cap, so a year of meals used
      // to kill the share (often the app) with
      // TransactionTooLargeException — and the import feature makes a
      // real FILE the thing the user actually wants to keep.
      final dir = await widget.tempDir();
      // Sweep older exports first: each is a FULL copy of the food log,
      // and the cache dir is readable by anything with the app's storage
      // — keeping a year of them there is a privacy cost with no upside.
      try {
        for (final f in dir.listSync()) {
          if (f is File && isExportFileName(f.path.split('/').last)) {
            f.deleteSync();
          }
        }
      } catch (_) {}
      // 1.7.0: the full export — the records AND every meal picture,
      // streamed one month at a time (kind `full`), so a file moved to
      // another phone brings the pictures too.
      final file = File('${dir.path}/${exportFileName(DateTime.now())}');
      await writer.writeFull(file.path,
          // Without iCloud Backup's own id, a fresh one: the header needs a
          // valid id, and the importer reads only the kind.
          installId: widget.backup?.installIdOrNull ?? newInstallId(),
          snapshot: snapshot);
      // Written first, so a failure is said before any choice; then where
      // it goes (no spinner behind the sheet). Cancel deletes it again.
      if (!mounted) return;
      final to = await _exportTarget(l10n);
      if (to == null) {
        try {
          if (file.existsSync()) file.deleteSync();
        } catch (_) {}
        return;
      }
      if (to == _ExportTo.device) {
        await _saveToDevice(file, l10n);
      } else {
        // Left in the cache folder: the app it is shared to may read it
        // after the share sheet closes (a Drive upload does). The sweep
        // above removes it at the next export.
        await widget.shareFile(file.path, l10n.exportShareSubject);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.exportFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Export and import — the food log is the user's — and on iPhone the
  /// iCloud Backup rows above them.
  ///
  /// Under them, on both platforms, the health reminder: Google Play's
  /// Health Content and Services policy asks apps to remind users to
  /// consult a healthcare professional (the full not-a-medical-device
  /// disclaimer is in the store description).
  @override
  Widget build(BuildContext context) {
    final backup = widget.backup;
    final section = backup == null
        ? _section(context, null)
        : ValueListenableBuilder<BackupStatus>(
            valueListenable: backup.status,
            builder: (context, status, _) => _section(context, status),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section,
        GroupedSection(
          key: const Key('healthReminder'),
          footer: context.l10n.settingsHealthReminder,
          children: const [],
        ),
      ],
    );
  }

  Widget _section(BuildContext context, BackupStatus? status) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final backup = widget.backup;
    final footer = status != null
        ? backupFooter(l, status)
        : widget.androidBackupNote
            ? l.backupAndroidFooter
            : l.settingsDataFooter;
    return GroupedSection(
      header: l.settingsSectionData,
      footer: status != null ? '$footer\n\n${l.settingsDataFooter}' : footer,
      children: [
        if (backup != null && status != null)
          ..._backupRows(context, backup, status),
        GroupedRow(
          key: const Key('exportButton'),
          icon: Icons.ios_share,
          iconColor: theme.colorScheme.primary,
          title: context.l10n.settingsRowExport,
          trailing: _exporting
              ? const SmallSpinner()
              : null,
          showChevron: false,
          onTap: _exporting ? null : _export,
        ),
        GroupedRow(
          key: const Key('importButton'),
          icon: Icons.file_download_outlined,
          iconColor: theme.colorScheme.secondary,
          title: context.l10n.settingsRowImport,
          trailing: _importing
              ? const SmallSpinner()
              : null,
          showChevron: false,
          onTap: _importing ? null : _import,
        ),
        GroupedRow(
          key: const Key('privacyPolicyRow'),
          icon: Icons.privacy_tip_outlined,
          iconColor: theme.colorScheme.tertiary,
          title: context.l10n.settingsRowPrivacy,
          onTap: widget.onOpenPrivacyPolicy,
          linkUrl: widget.privacyPolicyUrl,
        ),
      ],
    );
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<int> _localMeals() async => (await widget.dao.backupCounts()).meals;

  /// The iCloud Backup rows (design §9): the switch with the status line,
  /// Back Up Now, then only the rows the state calls for.
  List<Widget> _backupRows(
      BuildContext context, BackupCoordinator backup, BackupStatus s) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final on = s.state != BackupState.off;
    final busy = s.busy;
    return [
      MergeSemantics(
        child: GroupedRow(
          key: const Key('backupToggleRow'),
          icon: Icons.cloud_outlined,
          iconColor: theme.colorScheme.primary,
          title: l.backupRowICloud,
          subtitle: Text(backupStatusLine(context, s),
              key: const Key('backupStatusLine')),
          showChevron: false,
          trailing: Switch.adaptive(
            key: const Key('backupSwitch'),
            value: on,
            onChanged: busy
                ? null
                : (v) {
                    HapticFeedback.selectionClick();
                    _toggle(backup, v);
                  },
          ),
          onTap: busy ? null : () => _toggle(backup, !on),
        ),
      ),
      if (on)
        GroupedRow(
          key: const Key('backupNowRow'),
          icon: Icons.cloud_upload_outlined,
          iconColor: theme.colorScheme.primary,
          title: l.backupRowBackUpNow,
          trailing: busy ? const SmallSpinner() : null,
          showChevron: false,
          onTap: busy
              ? null
              : () async {
                  var state = await backup.backUpNow();
                  // Nothing uploads before the notice is answered (G1),
                  // and one dismissed at launch is not asked again until
                  // the next: it is asked here, and Keep On backs up.
                  if (state == BackupState.needsNotice) {
                    if (!context.mounted) return;
                    await showBackupNotice(context, backup);
                    final now = backup.status.value.state;
                    if (now == BackupState.needsNotice ||
                        now == BackupState.off) {
                      return;
                    }
                    state = await backup.backUpNow();
                  }
                  if (state == BackupState.uploading ||
                      state == BackupState.ok) {
                    _say(l.backupDone);
                  }
                },
        ),
      if (s.restorable.isNotEmpty)
        GroupedRow(
          key: const Key('backupRestoreRow'),
          icon: Icons.cloud_download_outlined,
          iconColor: theme.colorScheme.secondary,
          title: l.backupRowRestore,
          onTap: busy
              ? null
              : () async {
                  final local = await _localMeals();
                  if (!context.mounted) return;
                  // The newest backup; another install's older one waits.
                  final c = [...s.restorable]..sort((a, b) =>
                      (b.header.exportedAt ?? '')
                          .compareTo(a.header.exportedAt ?? ''));
                  await showRestoreOffer(context, backup, c.first, local);
                },
        ),
      if (on && s.canTakeOver)
        GroupedRow(
          key: const Key('backupTakeOverRow'),
          icon: Icons.phone_iphone_rounded,
          iconColor: theme.colorScheme.secondary,
          title: l.backupRowTakeOver,
          onTap: busy
              ? null
              : () async {
                  final local = await _localMeals();
                  if (!context.mounted) return;
                  await showTakeOverSheet(context, backup, localMeals: local);
                },
        ),
      if (on && s.state == BackupState.twoCopies)
        GroupedRow(
          key: const Key('backupCombineRow'),
          icon: Icons.merge_type_rounded,
          iconColor: theme.colorScheme.secondary,
          title: l.backupRowCombine,
          showChevron: false,
          onTap: busy
              ? null
              : () async {
                  final ok = await backup.combine();
                  _say(ok ? l.backupCombineDone : l.backupActionFailed);
                },
        ),
      if (on && s.state == BackupState.missing)
        GroupedRow(
          key: const Key('backupAgainRow'),
          title: l.backupRowBackUpAgain,
          showChevron: false,
          onTap: busy
              ? null
              : () async {
                  final state = await backup.backUpAgain();
                  _say(state == BackupState.uploading
                      ? l.backupDone
                      : l.backupActionFailed);
                },
        ),
      if (on && s.state == BackupState.shrink)
        GroupedRow(
          key: const Key('backupAnywayRow'),
          title: l.backupRowBackUpAnyway,
          showChevron: false,
          onTap: busy
              ? null
              : () async {
                  final state = await backup.backUpAnyway();
                  _say(state == BackupState.uploading
                      ? l.backupDone
                      : l.backupActionFailed);
                },
        ),
      // The empty log, or the switch off with this install's files still
      // in iCloud (turning it on to reach the turn-off sheet would upload
      // first).
      if (s.state == BackupState.emptyLog ||
          (s.state == BackupState.off && s.ownsFiles))
        GroupedRow(
          key: const Key('backupDeleteRow'),
          title: l.backupRowDelete,
          destructive: true,
          showChevron: false,
          onTap: busy ? null : () => confirmDeleteBackup(context, backup),
        ),
    ];
  }

  Future<void> _toggle(BackupCoordinator backup, bool on) async {
    if (on) {
      await backup.setEnabled(true);
    } else {
      await showTurnOffSheet(context, backup);
    }
  }
}

/// What an import says: the meals and rows it added (or that nothing was
/// new), the pictures, and what it deliberately left out.
String importSummaryText(AppLocalizations l, ImportSummary s) {
  final meals = s.added['meals'] ?? 0;
  final kept = s.totalSkipped;
  // Two whole sentences rather than one with a glued-on "; N already
  // here" suffix: a translator needs the full sentence to order it.
  final rows = s.totalAdded == 0
      ? (s.noMatchingMeals
          ? l.importNoMatchingMeals
          : s.thumbsAdded > 0
              ? l.importPicturesAdded(s.thumbsAdded)
              : l.importNothingNew)
      : kept > 0
          ? l.importDoneKept(meals, s.totalAdded, kept)
          : l.importDone(meals, s.totalAdded);
  return [
    rows,
    if (s.totalAdded > 0 && s.thumbsAdded > 0)
      l.importPicturesAdded(s.thumbsAdded),
    if (s.mealsSkippedDeleted > 0) l.importDeletedLeftOut(s.mealsSkippedDeleted),
  ].join(' ');
}

/// Several picked files' summaries as one.
ImportSummary combineImportSummaries(List<ImportSummary> all) {
  final added = <String, int>{};
  final skipped = <String, int>{};
  var thumbsAdded = 0, thumbsSkipped = 0, deleted = 0;
  for (final s in all) {
    s.added.forEach((k, v) => added[k] = (added[k] ?? 0) + v);
    s.skipped.forEach((k, v) => skipped[k] = (skipped[k] ?? 0) + v);
    thumbsAdded += s.thumbsAdded;
    thumbsSkipped += s.thumbsSkipped;
    deleted += s.mealsSkippedDeleted;
  }
  return ImportSummary(added, skipped,
      thumbsAdded: thumbsAdded,
      thumbsSkipped: thumbsSkipped,
      mealsSkippedDeleted: deleted,
      // Only when every file was pictures with no meal here.
      noMatchingMeals: all.isNotEmpty && all.every((s) => s.noMatchingMeals));
}
