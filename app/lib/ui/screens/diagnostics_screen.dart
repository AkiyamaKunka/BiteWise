/// The "why doesn't my AI work" page (user request 2026-07-31). One tap
/// runs the staged checks in ui/diagnostics.dart and renders each verdict
/// with the evidence and the user's next move — the debugging session this
/// replaces took an hour of server-log archaeology.
library;

import 'package:flutter/material.dart';

import '../../services/photo/background_runs.dart';
import '../../services/photo/photo_changes.dart'
    show
        LateImportStats,
        PhotoChangeStatus,
        lateImportRescanning,
        lateImportStatsWindow,
        readLateImportStats;
import '../diagnostics.dart';
import '../l10n.dart';
import '../widgets/small_spinner.dart';

/// How many background runs the page lists (20 are kept).
const int diagBackgroundRunsShown = 5;

class DiagnosticsScreen extends StatefulWidget {
  final ProviderDiagnostics diagnostics;

  /// The background-scan history (background_runs.dart), newest first.
  /// Null reads it from the device (readBackgroundRuns).
  final Future<List<BackgroundRunRecord>> Function()? loadBackgroundRuns;

  /// The late-import record (photo_changes.dart, design G1b); null reads
  /// it from the device (readLateImportStats). No record, no section:
  /// Android never writes one.
  final Future<LateImportStats?> Function()? loadLateImports;

  /// The clock for the "in 7 days" count.
  final DateTime Function() now;
  const DiagnosticsScreen(
      {super.key,
      required this.diagnostics,
      this.loadBackgroundRuns,
      this.loadLateImports,
      this.now = DateTime.now});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final List<DiagResult> _results = [];
  bool _running = false;
  bool _ran = false;
  late final Future<List<BackgroundRunRecord>> _backgroundRuns =
      (widget.loadBackgroundRuns ?? readBackgroundRuns)();
  late final Future<LateImportStats?> _lateImports =
      (widget.loadLateImports ?? readLateImportStats)();

  Future<void> _run() async {
    setState(() {
      _running = true;
      _results.clear();
    });
    try {
      await for (final r in widget.diagnostics.run()) {
        if (!mounted) return;
        setState(() => _results.add(r));
      }
    } catch (e) {
      // A stage that throws must not leave a half-finished run wearing the
      // green "Everything works" verdict — that is the exact false
      // reassurance this page exists to prevent.
      if (mounted) {
        final l = context.l10n;
        setState(() => _results.add(DiagResult(
              l.diagStageTestRun,
              DiagStatus.fail,
              l.diagTestRunFailed,
              detail: '$e',
              fix: l.diagFixTestRun,
            )));
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _ran = true;
        });
      }
    }
  }

  (IconData, Color) _iconFor(DiagStatus s, ThemeData theme) => switch (s) {
        DiagStatus.pass => (Icons.check_circle, Colors.green),
        DiagStatus.warn => (Icons.warning_amber_rounded, Colors.orange),
        DiagStatus.fail => (Icons.error, theme.colorScheme.error),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final problems =
        _results.where((r) => r.status != DiagStatus.pass).length;
    return Scaffold(
      appBar: AppBar(title: Text(l.diagTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l.diagIntro,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('runDiagnostics'),
            onPressed: _running ? null : _run,
            icon: _running
                ? const SmallSpinner()
                : const Icon(Icons.play_arrow),
            label: Text(_running
                ? l.diagRunning
                : _ran
                    ? l.diagRunAgain
                    : l.diagRunChecks),
          ),
          if (_ran && !_running) ...[
            const SizedBox(height: 12),
            Card(
              key: const Key('diagVerdict'),
              color: problems == 0
                  ? theme.colorScheme.secondaryContainer
                  : theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  problems == 0
                      ? l.diagVerdictOk
                      : l.diagVerdictProblems(problems),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          for (final r in _results) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_iconFor(r.status, theme).$1,
                            size: 20, color: _iconFor(r.status, theme).$2),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(r.stage,
                                style: theme.textTheme.titleSmall)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(r.summary, style: theme.textTheme.bodyMedium),
                    if (r.detail != null) ...[
                      const SizedBox(height: 4),
                      Text(r.detail!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                    if (r.fix != null) ...[
                      const SizedBox(height: 6),
                      Text('→ ${r.fix!}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_running) ...[
            const SizedBox(height: 16),
            const Center(
                child: CircularProgressIndicator(
                    key: Key('diagRunning'))),
          ],
          FutureBuilder<List<BackgroundRunRecord>>(
            future: _backgroundRuns,
            builder: (context, snap) => snap.hasData
                ? _BackgroundRuns(snap.data!)
                : const SizedBox.shrink(),
          ),
          FutureBuilder<LateImportStats?>(
            future: _lateImports,
            builder: (context, snap) => snap.data == null
                ? const SizedBox.shrink()
                : _LateImports(snap.data!, now: widget.now()),
          ),
        ],
      ),
    );
  }
}

/// "Late imports": photos other apps added after they were taken, which
/// the change history caught (G1b) — how many this week, when it last
/// looked, and why it is not working when it is not.
class _LateImports extends StatelessWidget {
  const _LateImports(this.stats, {required this.now});
  final LateImportStats stats;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final last = stats.lastAt;
    final status = lateImportStatusLine(l, stats.lastStatus);
    return Column(
      key: const Key('diagLateImports'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Text(l.diagLateImportsTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
            l.diagLateImportsSummary(
                stats.caughtSince(now.subtract(lateImportStatsWindow)),
                last == null ? l.diagBgRunWatermarkNone : localStamp(last)),
            style: theme.textTheme.bodyMedium),
        if (status != null) ...[
          const SizedBox(height: 4),
          Text(status,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// The line under the late-import count, for the states that need one:
/// a rescan by date in progress, or an iPhone without the change history.
String? lateImportStatusLine(AppLocalizations l, String? status) =>
    switch (status) {
      lateImportRescanning => l.diagLateImportsRescanning,
      final s when s == PhotoChangeStatus.unsupported.name =>
        l.diagLateImportsNeedsIos16,
      _ => null,
    };

/// "Recent background scans": what the last runs did, as recorded by the
/// background engine itself — the only view of a run iOS killed part-way
/// (2026-10-18).
class _BackgroundRuns extends StatelessWidget {
  const _BackgroundRuns(this.runs);
  final List<BackgroundRunRecord> runs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      key: const Key('diagBackgroundRuns'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Text(l.diagBgRunsTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(runs.isEmpty ? l.diagBgRunsNone : l.diagBgRunsIntro,
            style: muted),
        for (final r in runs.take(diagBackgroundRunsShown)) ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${localStamp(r.start)} · ${_took(l, r)}',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(backgroundRunVerdict(l, r),
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                      l.diagBgRunCounts(r.enumerated, r.offered, r.analyzed,
                          r.saved, r.released),
                      style: muted),
                  Text(
                      l.diagBgRunWatermark(_stamp(l, r.watermarkBefore),
                          _stamp(l, r.watermarkAfter)),
                      style: muted),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _stamp(AppLocalizations l, DateTime? t) =>
      t == null ? l.diagBgRunWatermarkNone : localStamp(t);

  static String _took(AppLocalizations l, BackgroundRunRecord r) {
    final end = r.end;
    return end == null
        ? l.diagBgRunUnfinished
        : l.diagBgRunSeconds(end.difference(r.start).inSeconds);
  }
}

/// One line on how [r] ended: its stop reason, or — for a run the OS cut
/// short — the step it was on.
String backgroundRunVerdict(AppLocalizations l, BackgroundRunRecord r) {
  if (!r.finished) {
    final step = switch (r.stage) {
      BackgroundRunStage.boot => l.diagBgStageBoot,
      BackgroundRunStage.settings => l.diagBgStageSettings,
      BackgroundRunStage.scan => l.diagBgStageScan,
      BackgroundRunStage.photo => l.diagBgStagePhoto,
      BackgroundRunStage.checkpoint => l.diagBgStageCheckpoint,
      BackgroundRunStage.done => l.diagBgStageDone,
    };
    return l.diagBgRunKilled(step);
  }
  final stop = r.stopReason ?? BackgroundStop.done;
  return switch (stop) {
    BackgroundStop.done => l.diagBgStopDone,
    BackgroundStop.budget => l.diagBgStopBudget,
    BackgroundStop.paused => l.diagBgStopPaused,
    BackgroundStop.noKey => l.diagBgStopNoKey,
    BackgroundStop.watcherOff => l.diagBgStopWatcherOff,
    BackgroundStop.noPermission => l.diagBgStopNoPermission,
    _ => l.diagBgStopError(
        stop.startsWith('error:') ? stop.substring('error:'.length) : stop),
  };
}
