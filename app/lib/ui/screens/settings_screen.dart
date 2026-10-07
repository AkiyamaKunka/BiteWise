/// Onboarding/Settings (spec §8 knobs), in six section builders: AI
/// provider + key + curated model picker + one "Test this provider"
/// action (the diagnostics page), photo intake (watcher, coverage audit,
/// backfill window), daily-report time, dietary profile, and the data
/// section (export to a file, import by merge).
library;

import 'dart:async' show unawaited;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/contracts.dart';

import '../../services/analyzer/platform_decode.dart';
import '../../services/photo/coverage.dart';
import '../../services/photo/photo_library.dart';
import '../photo_pipeline.dart';
import '../format.dart' show isoDate;
import '../services.dart';
import '../l10n.dart';
import '../widgets/grouped.dart';
import 'coverage_screen.dart';
import 'meal_editor_screen.dart';
import 'settings/profile_page.dart';
import 'settings/provider_page.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsStore settings;
  final AnalyzerService analyzer;
  final MealsDao dao;
  final Future<bool> Function() requestPhotoPermission;
  final PhotoIntake? photoIntake; // started/stopped on watcher toggle

  /// Claude OAuth re-connect (server provider). Nulls in tests hide the
  /// button; [openUrl] is injectable so widget tests need no url_launcher.
  final Future<({String? url, String? error})> Function()? startClaudeAuth;
  final Future<String?> Function(String code)? completeClaudeAuth;
  final Future<String?> Function()? serverLoginState;
  final Future<bool> Function(Uri url)? openUrl;

  /// Opens the OS app-settings page — the only remedy once the system
  /// stops re-showing the photo-permission dialog. Null hides the action.
  final Future<void> Function()? openSystemSettings;

  /// Whether the OS will deliver notifications; null = unknown / not
  /// probed (tests). False surfaces the daily-summary remedy row.
  final Future<bool?> Function()? notificationsEnabled;

  /// The slot the daily summary is armed for; null = nothing armed. A
  /// null PROBE hides the row (tests, older wiring).
  final Future<DateTime?> Function()? nextSummaryAt;

  /// When the OS last launched the background photo scan; null = never.
  /// A null PROBE hides the row.
  final Future<DateTime?> Function()? lastBackgroundScan;

  /// iOS Background App Refresh; false turns the background-scan row into
  /// the remedy ("off in Settings", opens system settings).
  final Future<bool?> Function()? backgroundRefreshEnabled;

  /// Coverage-audit pieces; all three null in tests → the tile is hidden.
  final CoverageAuditor? coverage;
  final Future<PhotoOutcome> Function(IntakePhoto photo)? processPhoto;
  final PhotoLibrary? photoLibrary;

  const SettingsScreen({
    super.key,
    required this.settings,
    required this.analyzer,
    required this.dao,
    required this.requestPhotoPermission,
    this.photoIntake,
    this.coverage,
    this.processPhoto,
    this.photoLibrary,
    this.startClaudeAuth,
    this.completeClaudeAuth,
    this.serverLoginState,
    this.openUrl,
    this.openSystemSettings,
    this.notificationsEnabled,
    this.nextSummaryAt,
    this.lastBackgroundScan,
    this.backgroundRefreshEnabled,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _profileController;
  final TextEditingController _importController = TextEditingController();
  late int _lookbackDays;
  late String _reportTime;
  late bool _watcherEnabled;
  bool _exporting = false;
  bool _importing = false;

  /// True only when the OS says notifications are OFF for this app. On iOS
  /// a declined permission makes every scheduled summary vanish silently,
  /// so the report section says so and offers the only remedy (system
  /// settings). Unknown/null keeps the row hidden.
  bool _notificationsOff = false;

  /// The armed daily-summary slot; null once probed = nothing armed.
  DateTime? _nextSummary;
  bool _nextSummaryProbed = false;

  /// The OS's last background launch; null once probed = never ran.
  DateTime? _lastBackgroundScan;
  bool _lastBackgroundProbed = false;

  /// True only when iOS says Background App Refresh is OFF for this app.
  bool _backgroundRefreshOff = false;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _profileController = TextEditingController(text: s.dietaryProfile);
    _lookbackDays = s.lookbackDays.clamp(1, 30); // spec §6.4 range
    _reportTime = s.reportTime.isEmpty ? '21:00' : s.reportTime;
    _watcherEnabled = s.watcherEnabled;
    WidgetsBinding.instance.addObserver(this);
    _probeNotifications();
    _probeNextSummary();
    _probeBackgroundScan();
  }

  Future<void> _probeBackgroundScan() async {
    final probe = widget.lastBackgroundScan;
    if (probe == null) return;
    DateTime? when;
    bool? refresh;
    try {
      when = await probe();
      refresh = await widget.backgroundRefreshEnabled?.call();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _lastBackgroundScan = when;
      _lastBackgroundProbed = true;
      _backgroundRefreshOff = refresh == false;
    });
  }

  /// "Next summary: today 21:30" — or "not scheduled", which is the whole
  /// point: on iOS the card is armed ahead of time, and a phone that shows
  /// nothing at the slot should be able to say WHY in Settings.
  Future<void> _probeNextSummary() async {
    final probe = widget.nextSummaryAt;
    if (probe == null) return;
    DateTime? when;
    try {
      when = await probe();
    } catch (_) {
      return; // unknown: leave the row as it was
    }
    if (!mounted) return;
    setState(() {
      _nextSummary = when;
      _nextSummaryProbed = true;
    });
  }

  String _nextSummaryLabel(DateTime? when) =>
      when == null ? context.l10n.nextSummaryNone : _dayTime(when);

  String _lastBackgroundLabel(DateTime? when) =>
      when == null ? context.l10n.backgroundScanNever : _dayTime(when);

  /// "Today 21:30" / "Tomorrow 07:00" / "Yesterday 14:02" / "09-28 14:02".
  String _dayTime(DateTime when) {
    final l = context.l10n;
    final hhmm = '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(when.year, when.month, when.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return l.timeToday(hhmm);
    if (diff == 1) return l.timeTomorrow(hhmm);
    if (diff == -1) return l.timeYesterday(hhmm);
    return '${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')} $hhmm';
  }

  /// Re-probe on resume: the user comes BACK from system settings to this
  /// very screen (it lives in the IndexedStack), so the row must clear
  /// itself without a restart.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _probeNotifications();
      _probeNextSummary();
      _probeBackgroundScan();
    }
  }

  Future<void> _probeNotifications() async {
    final probe = widget.notificationsEnabled;
    if (probe == null) return;
    bool? enabled;
    try {
      enabled = await probe();
    } catch (_) {
      return; // unknown: keep the row hidden rather than cry wolf
    }
    if (!mounted) return;
    final off = enabled == false;
    if (off != _notificationsOff) setState(() => _notificationsOff = off);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _profileController.dispose();
    _importController.dispose();
    super.dispose();
  }

  Future<void> _toggleWatcher(bool enable) async {
    // Captured BEFORE the first await: every snackbar below fires after a
    // permission / photo-library round trip, and reading l10n off a
    // context that may have gone away is the use-after-await the lint
    // exists for. (The strings themselves were English literals until
    // 2026-10-07 — the Chinese UI showed them verbatim.)
    final l10n = context.l10n;
    if (enable) {
      final granted = await widget.requestPhotoPermission();
      if (!granted) {
        if (!mounted) return;
        final open = widget.openSystemSettings;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.watcherPermissionDenied),
            // Once the OS stops re-prompting, the in-app request above is
            // a silent no-op — without this action the toggle is a
            // forever dead end.
            action: open == null
                ? null
                : SnackBarAction(
                    label: l10n.openSystemSettings,
                    onPressed: () => open())));
        return; // leave the switch off
      }
      if (!mounted) return;
      // The watcher arms fine without a usable key — it just never logs
      // anything. Flipping a switch that silently does nothing needs a
      // sentence, not silence.
      if (!widget.settings.canAnalyze) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(widget.settings.isQuotaPaused
                ? l10n.watcherOnQuotaPaused
                : l10n.watcherOnNoKey)));
      }
      await widget.photoIntake?.start();
      // A "selected photos" (limited) grant is a TRAP: the watcher can
      // only ever see the photos picked in that one dialog, so a meal
      // shot later is invisible forever — and the toggle used to turn on
      // regardless, silently. Say so, with a path to fix it.
      final lib = widget.photoLibrary;
      if (lib != null && !await lib.hasFullAccess()) {
        if (!mounted) return;
        final open = widget.openSystemSettings;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 8),
            content: Text(l10n.watcherLimitedAccess),
            action: open == null
                ? null
                : SnackBarAction(
                    label: l10n.fixAction, onPressed: () => open())));
      }
      // Instant feedback on enable: sweep the lookback window right away
      // instead of waiting for the next change event / background run.
      // Only when analyses can actually succeed (key present, no quota
      // pause) — otherwise the sweep reads bytes for nothing.
      if (widget.settings.canAnalyze) {
        unawaited(widget.photoIntake
            ?.backfillScan()
            .then((_) {}, onError: (Object _) {}));
      }
    } else {
      await widget.photoIntake?.stop();
    }
    if (!mounted) return;
    setState(() => _watcherEnabled = enable);
    await widget.settings.update(watcherEnabled: enable);
  }

  Future<void> _pickReportTime() async {
    final parts = _reportTime.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 21,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final formatted = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    setState(() => _reportTime = formatted);
    await widget.settings.update(reportTime: formatted);
    await _probeNextSummary(); // the store re-armed the card for the new slot
  }

  /// Import via PASTE, deliberately: adding a file-picker plugin for a
  /// once-a-year action costs a platform dependency on both OSes, while
  /// every transfer route the owner actually uses (WeChat/AirDrop/email/
  /// Termux) can put text on the clipboard. The parser refuses anything
  /// that is not a CalorieTracker export, so a mis-paste is a message,
  /// never a corrupted log.
  Future<void> _import() async {
    final l10n = context.l10n; // before the dialog await, as in _toggleWatcher
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
    final l10n = context.l10n; // before the awaits, as in _toggleWatcher
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


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Apple grouped anatomy (2026-08-02 restructure): inset sections on a
    // grouped background, disclosure to subpages, footers as helper text.
    // Section builders keep features findable — the wall is gone.
    return Container(
      color: groupedBackground(theme.colorScheme),
      child: CustomScrollView(
        slivers: [
          SliverAppBar.large(title: Text(context.l10n.tabSettings)),
          SliverList.list(children: [
            ..._aiSection(theme),
            ..._photoSection(theme),
            ..._reportSection(theme),
            ..._profileSection(theme),
            ..._languageSection(theme),
            ..._dataSection(theme),
            const SizedBox(height: 32),
          ]),
        ],
      ),
    );
  }

  /// One row of STATE (Apple progressive disclosure): choosing and
  /// configuring the provider lives on its own page.
  List<Widget> _aiSection(ThemeData theme) => [
        // First-run: the shell deliberately lands a key-less install here.
        // Everything a mainland user needs to know is one tap away on the
        // provider page; this card just points there.
        if (widget.settings.apiKey.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Card(
              key: const Key('firstRunCard'),
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.settingsWelcomeTitle,
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.settingsWelcomeBody,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        GroupedSection(
          header: context.l10n.settingsSectionAi,
          footer: widget.settings.isQuotaPaused
              ? context.l10n.settingsAiFooterPaused
              : context.l10n.settingsAiFooter,
          children: [
            GroupedRow(
              key: const Key('aiProviderRow'),
              icon: Icons.auto_awesome,
              iconColor: theme.colorScheme.primary,
              title: context.l10n.settingsRowAiProvider,
              value: providerDisplayLabel(widget.settings.provider,
                  widget.settings.serverBackend),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ProviderSettingsPage(
                    settings: widget.settings,
                    analyzer: widget.analyzer,
                    startClaudeAuth: widget.startClaudeAuth,
                    completeClaudeAuth: widget.completeClaudeAuth,
                    serverLoginState: widget.serverLoginState,
                    openUrl: widget.openUrl,
                  ),
                ));
                if (mounted) setState(() {}); // provider label refresh
              },
            ),
          ],
        ),
  ];

  /// Camera-roll watching, coverage audit, backfill window.
  List<Widget> _photoSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsSectionPhotos,
          footer: context.l10n.settingsPhotosFooter,
          children: [
            GroupedToggleRow(
              switchKey: const Key('watcherToggle'),
              icon: Icons.photo_camera_outlined,
              iconColor: theme.colorScheme.primary,
              title: context.l10n.settingsRowWatch,
              value: _watcherEnabled,
              onChanged: (v) => _toggleWatcher(v),
            ),
            GroupedRow(
              icon: Icons.history,
              iconColor: theme.colorScheme.tertiary,
              title: context.l10n.settingsRowLookback,
              value: context.l10n.lookbackDays(_lookbackDays),
              onTap: _pickLookback,
            ),
            // The OS's last background launch — on iOS the only visible
            // proof that Background App Refresh runs for this app at all.
            if (widget.lastBackgroundScan != null)
              GroupedRow(
                key: const Key('backgroundScanRow'),
                icon: Icons.update,
                iconColor: _backgroundRefreshOff
                    ? theme.colorScheme.error
                    : theme.colorScheme.secondary,
                title: context.l10n.settingsRowBackgroundScan,
                // Off in iOS settings beats any timestamp: nothing can be
                // scheduled until the user turns it back on.
                value: _backgroundRefreshOff
                    ? context.l10n.backgroundScanDisabled
                    : _lastBackgroundProbed
                        ? _lastBackgroundLabel(_lastBackgroundScan)
                        : '…',
                onTap: _backgroundRefreshOff && widget.openSystemSettings != null
                    ? () => widget.openSystemSettings!()
                    : null,
                showChevron: _backgroundRefreshOff &&
                    widget.openSystemSettings != null,
              ),
            if (widget.coverage != null && widget.processPhoto != null)
              GroupedRow(
                key: const Key('coverageCheckTile'),
                icon: Icons.fact_check_outlined,
                iconColor: theme.colorScheme.secondary,
                title: context.l10n.settingsRowCoverage,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CoverageScreen(
                    auditor: widget.coverage!,
                    processPhoto: widget.processPhoto!,
                    requestPhotoPermission: widget.requestPhotoPermission,
                    initialLookbackDays: _lookbackDays,
                    // A closure, not a snapshot: the quota latch can arm
                    // while the coverage screen's bulk run is mid-batch.
                    canAnalyze: () => widget.settings.canAnalyze,
                    library: widget.photoLibrary,
                    logManually: (photo) async =>
                        await Navigator.of(context)
                            .push<bool>(MaterialPageRoute(
                          builder: (_) => MealEditorScreen(
                            dao: widget.dao,
                            fromPhoto: photo,
                            makeThumb: makeMealThumbAny,
                          ),
                        )) ==
                        true,
                  ),
                )),
              ),
          ],
        ),
  ];

  /// Apple's compact-value pattern: the row shows the state; a sheet
  /// adjusts it (the old always-visible slider gave a rarely-touched
  /// setting permanent screen space).
  Future<void> _pickLookback() async {
    var days = _lookbackDays;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ctx.l10n.lookbackSheetTitle,
                  style: Theme.of(ctx).textTheme.titleMedium),
              Text(ctx.l10n.lookbackSheetHint,
                  style: Theme.of(ctx).textTheme.bodySmall),
              Slider(
                key: const Key('lookbackSlider'),
                value: days.toDouble(),
                min: 1,
                max: 30, // spec §6.4 clamp 1–30
                divisions: 29,
                label: '$days',
                onChanged: (v) => setSheet(() => days = v.round()),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, days),
                  child: Text(ctx.l10n.lookbackSet(days)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _lookbackDays = picked);
    await widget.settings.update(lookbackDays: picked);
  }

  /// Daily-report time.
  List<Widget> _reportSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsSectionReport,
          footer: context.l10n.goalFooter,
          children: [
            GroupedRow(
              key: const Key('reportTimeTile'),
              icon: Icons.schedule,
              iconColor: theme.colorScheme.primary,
              title: context.l10n.settingsRowReportTime,
              value: _reportTime,
              onTap: _pickReportTime,
            ),
            if (_notificationsOff) _notificationsOffRow(theme),
            if (widget.nextSummaryAt != null)
              GroupedRow(
                key: const Key('nextSummaryRow'),
                icon: Icons.notifications_active_outlined,
                iconColor: _nextSummaryProbed && _nextSummary == null
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                title: context.l10n.settingsRowNextSummary,
                value: _nextSummaryProbed ? _nextSummaryLabel(_nextSummary) : '…',
                showChevron: false,
              ),
            GroupedRow(
              key: const Key('calorieGoalTile'),
              icon: Icons.flag_outlined,
              iconColor: theme.colorScheme.secondary,
              title: context.l10n.settingsRowGoal,
              value: widget.settings.calorieGoal > 0
                  ? context.l10n.kcalAmount('${widget.settings.calorieGoal}')
                  : context.l10n.goalNotSet,
              onTap: _pickCalorieGoal,
            ),
          ],
        ),
  ];

  /// Shown only when the OS reports notifications OFF: without this the
  /// daily summary simply never arrives and nothing on the phone says why.
  Widget _notificationsOffRow(ThemeData theme) {
    final open = widget.openSystemSettings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.notifications_off_outlined,
                  size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.notificationsOffHint,
                  key: const Key('notificationsOffHint'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
          if (open != null) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(
              key: const Key('notificationsOffOpenSettings'),
              onPressed: () => open(),
              child: Text(context.l10n.openSystemSettings),
            ),
          ],
        ],
      ),
    );
  }

  /// The daily goal the coach notification measures against; empty clears
  /// it and the summary falls back to the typical-day median.
  Future<void> _pickCalorieGoal() async {
    final ctrl = TextEditingController(
        text: widget.settings.calorieGoal > 0
            ? '${widget.settings.calorieGoal}'
            : '');
    final saved = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.goalSheetTitle),
        content: TextField(
          key: const Key('calorieGoalField'),
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: ctx.l10n.goalFieldLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              key: const Key('calorieGoalClear'),
              onPressed: () => Navigator.pop(ctx, 0),
              child: Text(ctx.l10n.goalClear)),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
            key: const Key('calorieGoalSave'),
            onPressed: () => Navigator.pop(
                ctx, int.tryParse(ctrl.text.trim()) ?? 0),
            child: Text(ctx.l10n.save),
          ),
        ],
      ),
    );
    if (saved == null || !mounted) return;
    await widget.settings.update(calorieGoal: saved);
    if (mounted) setState(() {});
  }

  /// Dietary profile appended to the photo prompt (§1.3).
  List<Widget> _profileSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsSectionProfile,
          children: [
            GroupedRow(
              key: const Key('dietaryProfileRow'),
              icon: Icons.person_outline,
              iconColor: theme.colorScheme.secondary,
              title: context.l10n.settingsRowDietaryProfile,
              value: widget.settings.dietaryProfile.trim().isEmpty
                  ? context.l10n.profileNotSet
                  : context.l10n.profileSet,
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      ProfileSettingsPage(settings: widget.settings),
                ));
                if (mounted) setState(() {}); // Set/Not set refresh
              },
            ),
          ],
        ),
  ];

  String _languageLabel(BuildContext context) =>
      switch (widget.settings.appLanguage) {
        'en' => 'English',
        'zh' => '中文',
        _ => context.l10n.languageSystem,
      };

  Future<void> _pickLanguage() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: groupedBackground(Theme.of(context).colorScheme),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(ctx.l10n.languageSheetTitle,
                    style: Theme.of(ctx)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            GroupedSection(
              separatorInset: 16,
              children: [
                for (final (value, label) in [
                  ('system', ctx.l10n.languageSystem),
                  ('en', 'English'),
                  ('zh', '中文'),
                ])
                  GroupedRow(
                    key: Key('language-$value'),
                    title: label,
                    showChevron: false,
                    trailing: widget.settings.appLanguage == value
                        ? Icon(Icons.check,
                            size: 20,
                            color: Theme.of(ctx).colorScheme.primary)
                        : const SizedBox(width: 20),
                    onTap: () => Navigator.pop(ctx, value),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await widget.settings.update(appLanguage: picked);
    if (mounted) setState(() {});
  }

  List<Widget> _languageSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsRowLanguage,
          // The Units row rides the language section and only exists in
          // the ENGLISH UI: the Chinese UI is always metric (user
          // decision 2026-08-03), so offering the choice there would be
          // a lie — the zh screens ignore it.
          footer: _showUnitsRow ? context.l10n.unitsFooter : null,
          children: [
            GroupedRow(
              key: const Key('languageRow'),
              icon: Icons.translate,
              iconColor: theme.colorScheme.tertiary,
              title: context.l10n.settingsRowLanguage,
              value: _languageLabel(context),
              onTap: _pickLanguage,
            ),
            if (_showUnitsRow)
              GroupedRow(
                key: const Key('unitsRow'),
                icon: Icons.straighten,
                iconColor: theme.colorScheme.secondary,
                title: context.l10n.settingsRowUnits,
                value: widget.settings.units == 'imperial'
                    ? context.l10n.unitsImperial
                    : context.l10n.unitsMetric,
                onTap: _pickUnits,
              ),
          ],
        ),
  ];

  bool get _showUnitsRow =>
      Localizations.maybeLocaleOf(context)?.languageCode != 'zh';

  Future<void> _pickUnits() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: groupedBackground(Theme.of(context).colorScheme),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(ctx.l10n.unitsSheetTitle,
                    style: Theme.of(ctx)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            GroupedSection(
              separatorInset: 16,
              children: [
                for (final (value, label) in [
                  ('metric', ctx.l10n.unitsMetricDetail),
                  ('imperial', ctx.l10n.unitsImperialDetail),
                ])
                  GroupedRow(
                    key: Key('units-$value'),
                    title: label,
                    showChevron: false,
                    trailing: widget.settings.units == value
                        ? Icon(Icons.check,
                            size: 20,
                            color: Theme.of(ctx).colorScheme.primary)
                        : const SizedBox(width: 20),
                    onTap: () => Navigator.pop(ctx, value),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await widget.settings.update(units: picked);
    if (mounted) setState(() {});
  }

  /// Export and import — the food log is the user's.
  List<Widget> _dataSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsSectionData,
          footer: context.l10n.settingsDataFooter,
          children: [
            GroupedRow(
              key: const Key('exportButton'),
              icon: Icons.ios_share,
              iconColor: theme.colorScheme.primary,
              title: context.l10n.settingsRowExport,
              trailing: _exporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
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
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
              showChevron: false,
              onTap: _importing ? null : _import,
            ),
          ],
        ),
  ];
}

