/// The data section of Settings: export the whole food log to a file and
/// import one back by merge. The privacy-policy row shares this section,
/// but its tap stays with the Settings screen, which owns the injectable
/// URL opener.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/contracts.dart';
import '../../format.dart' show isoDate;
import '../../l10n.dart';
import '../../widgets/grouped.dart';
import '../../widgets/small_spinner.dart';

class DataSection extends StatefulWidget {
  const DataSection({
    super.key,
    required this.dao,
    required this.onOpenPrivacyPolicy,
  });

  final MealsDao dao;

  /// The 隐私政策 / Privacy Policy row's tap.
  final VoidCallback onOpenPrivacyPolicy;

  @override
  State<DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<DataSection> {
  final TextEditingController _importController = TextEditingController();
  bool _exporting = false;
  bool _importing = false;

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  /// Import via PASTE, deliberately: adding a file-picker plugin for a
  /// once-a-year action costs a platform dependency on both OSes, while
  /// every transfer route the owner actually uses (WeChat/AirDrop/email/
  /// Termux) can put text on the clipboard. The parser refuses anything
  /// that is not a CalorieTracker export, so a mis-paste is a message,
  /// never a corrupted log.
  Future<void> _import() async {
    final l10n = context.l10n; // read before the dialog await
    // The controller is owned by the STATE, not the dialog closure: a
    // locally-created one gets disposed while the dialog's exit animation
    // is still rebuilding the field ("A TextEditingController was used
    // after being disposed" — caught by the new test).
    _importController.clear();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.importDialogTitle),
        // Scrollable + bounded: an AlertDialog's content is laid out
        // against the available height, and an unbounded Column here
        // overflowed by ~97000 px on a tall viewport.
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.importDialogBody),
              const SizedBox(height: 12),
              TextField(
                key: const Key('importField'),
                controller: _importController,
                maxLines: 4,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '{"format":"calorie_tracker_export",…',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
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
      ),
    );
    final payload = _importController.text;
    if (go != true || !mounted) return;
    setState(() => _importing = true);
    try {
      final summary = await widget.dao.importJson(payload);
      if (!mounted) return;
      final meals = summary.added['meals'] ?? 0;
      final kept = summary.totalSkipped;
      // Two whole sentences rather than one with a glued-on "; N already
      // here" suffix: a translator needs the full sentence to order it.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(summary.totalAdded == 0
              ? l10n.importNothingNew
              : kept > 0
                  ? l10n.importDoneKept(meals, summary.totalAdded, kept)
                  : l10n.importDone(meals, summary.totalAdded))));
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

  Future<void> _export() async {
    final l10n = context.l10n; // read before the awaits
    setState(() => _exporting = true);
    try {
      final json = await widget.dao.exportJson(); // spec §8 full export
      // A FILE, not intent text: Android delivers EXTRA_TEXT through one
      // binder transaction with a ~1 MB hard cap, so a year of meals used
      // to kill the share (often the app) with
      // TransactionTooLargeException — and the import feature makes a
      // real FILE the thing the user actually wants to keep.
      final dir = await getTemporaryDirectory();
      // Sweep older exports first: each is a FULL copy of the food log,
      // and the cache dir is readable by anything with the app's storage
      // — keeping a year of them there is a privacy cost with no upside.
      try {
        for (final f in dir.listSync()) {
          if (f is File &&
              f.path.split('/').last.startsWith('calorietracker-')) {
            f.deleteSync();
          }
        }
      } catch (_) {}
      final stamp = isoDate(DateTime.now());
      final file = File('${dir.path}/calorietracker-$stamp.json');
      await file.writeAsString(json, flush: true);
      await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path)], subject: l10n.exportShareSubject));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.exportFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Export and import — the food log is the user's.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GroupedSection(
      header: context.l10n.settingsSectionData,
      footer: context.l10n.settingsDataFooter,
      children: [
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
        ),
      ],
    );
  }
}
