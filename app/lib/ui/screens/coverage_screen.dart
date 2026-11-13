/// Photo-coverage check (spec §9 app-only): a MANUAL audit of "has every
/// photo in the window been through intake?", with one-tap remediation.
///
/// The audit itself never calls a model (it only hashes bytes and reads the
/// ledger); the Log/Retry actions push photos through the app's ONE
/// serialized pipeline, so they queue behind — never race — the watcher.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../core/outcome_kind.dart';
import '../../services/photo/coverage.dart';
import '../../services/photo/photo_library.dart';
import '../outcome_text.dart';
import '../photo_pipeline.dart';
import '../l10n.dart';
import '../large_text.dart';
import '../theme/app_dialog.dart';
import '../theme/tokens.dart';
import '../widgets/grouped.dart';

bool _alwaysCan() => true;

class CoverageScreen extends StatefulWidget {
  const CoverageScreen({
    super.key,
    required this.auditor,
    required this.processPhoto,
    required this.requestPhotoPermission,
    required this.initialLookbackDays,
    this.canAnalyze = _alwaysCan,
    required this.ensureConsent,
    this.library,
    this.logManually,
  });

  final CoverageAuditor auditor;
  final Future<PhotoOutcome> Function(IntakePhoto photo) processPhoto;
  final Future<bool> Function() requestPhotoPermission;
  final int initialLookbackDays;

  /// Live read of AppSettings.canAnalyze: a key for the ACTIVE provider and
  /// no quota latch. Deliberately NOT canAutoAnalyze: Log/Retry here are
  /// the user's own request, and a retry after fixing the key or the VPN
  /// is how the automatic scan's rejected-key/region latch gets lifted —
  /// the loop below stops at the first such refusal instead. A FUNCTION, not a bool — the latch can arm MID-BATCH
  /// (photo 1's daily-quota 429 sets the pause), and a value captured at
  /// construction would wave photos 2..N into the reserve-then-release
  /// shredder that [_processAll] exists to avoid.
  final bool Function() canAnalyze;

  /// Asks for the AI consent (ui/ai_consent.dart ensureAiConsent) before a
  /// bulk Log/Retry sends anything; false = the user said Not now.
  /// Required, so a call site cannot drop the question silently; tests
  /// that are about something else pass one that allows.
  final Future<bool> Function(BuildContext context) ensureConsent;

  /// For missing-photo thumbnails; null degrades to icons.
  final PhotoLibrary? library;

  /// Open the manual editor for a photo the model refused or failed on for
  /// good. Null hides the action (tests / no editor context).
  final Future<bool> Function(IntakePhoto photo)? logManually;

  @override
  State<CoverageScreen> createState() => _CoverageScreenState();
}

enum _Phase { idle, scanning, done, acting }

class _CoverageScreenState extends State<CoverageScreen> {
  static const int _minDays = 1, _maxDays = 30;
  _Phase _phase = _Phase.idle;
  late int _days = widget.initialLookbackDays.clamp(_minDays, _maxDays);
  CoverageReport? _report;
  String? _error;
  int _progressDone = 0;
  int _progressTotal = 0;
  int _actedOn = 0;
  // FUTURE-cached: dedupes in-flight fetches across rebuilds (the bytes
  // cache alternative re-fired a platform call per rebuild until resolve).
  final Map<String, Future<Uint8List?>> _thumbCache = {};

  /// Tiles rendered per section; an audit can return hundreds of missing
  /// photos and building them all eagerly fires that many thumbnail
  /// fetches in one frame.
  static const int _maxTiles = 60;

  Future<void> _runAudit() async {
    final granted = await widget.requestPhotoPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() => _error = context.l10n.covPermissionRequired);
      return;
    }
    setState(() {
      _phase = _Phase.scanning;
      _error = null;
      _report = null;
      _progressDone = 0;
      _progressTotal = 0;
    });
    try {
      final report = await widget.auditor.audit(
        lookbackDays: _days,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progressDone = done;
            _progressTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _phase = _Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _error = context.l10n.covCheckFailed('$e');
      });
    }
  }

  /// Bulk actions are SLOW and spend the user's model budget: each photo is
  /// a full analysis (~20-25 s through the own-server/Claude provider), run
  /// one at a time behind the shared FIFO. Twenty photos is eight minutes.
  /// Ask first, with the real numbers, and let them back out.
  Future<bool> _confirmBulk(List<CoverageItem> items, String verb) async {
    // Refuse when no analysis can succeed. This is not politeness: a paused
    // or key-less run still RESERVES each photo (a deliberate re-add
    // reclaims 'skipped'), then releases it — and releasing a row that
    // reserve had just flipped to 'processing' DELETES it. The tombstones
    // that mark "the model already saw this and said no" would all
    // disappear, without a single model call, and the next full-window
    // catch-up would re-analyze every one of them.
    if (!widget.canAnalyze()) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.covNoAnalysis)));
      return false;
    }
    // App Store 5.1.2(i): these photos go to the AI — permission first.
    if (!await widget.ensureConsent(context)) return false;
    if (!mounted) return false;
    final minutes = (items.length * 22 / 60).ceil();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => appAlertDialog(
        title: Text(ctx.l10n.covBulkTitle(verb, items.length)),
        content: Text(ctx.l10n.covBulkBody(minutes, items.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('confirmBulkAction'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(verb)),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Push [items] through the pipeline one at a time, with progress. The
  /// screen re-audits afterwards so the summary reflects reality, not hope.
  Future<void> _processAll(List<CoverageItem> items, String label) async {
    final l = context.l10n; // captured before the awaits below
    setState(() {
      _phase = _Phase.acting;
      _actedOn = 0;
      _progressDone = 0;
      _progressTotal = items.length;
    });
    var failures = 0;
    var attempted = 0;
    var stopped = false;
    // The failure that ended the run, when one did. The canAnalyze() stop
    // really is "quota pause or missing key"; a retryable failure is not —
    // on the Claude Plan it is usually a busy or unreachable server — so
    // that stop names its own reason instead of sending the user to a key
    // that is fine.
    PhotoOutcome? stopOutcome;
    for (final item in items) {
      // Re-checked EVERY iteration, not once up front: photo 1's daily-quota
      // 429 arms the pause latch mid-batch, and every photo pushed after
      // that is reserved (reclaiming its skipped/failed tombstone), makes
      // zero model calls, then released — and releasing a just-reclaimed row
      // DELETES it. Stopping here is what keeps rows 2..N in the ledger.
      if (!widget.canAnalyze()) {
        stopped = true;
        break;
      }
      final photo = await widget.auditor.loadForProcessing(item);
      attempted++;
      if (photo == null) {
        failures++;
      } else {
        final outcome = await widget.processPhoto(photo);
        if (outcome.kind == PhotoOutcomeKind.failed) {
          failures++;
          // A retryable failure (rate limit, network, quota, missing key)
          // means the NEXT photo cannot succeed either — and its reservation
          // was released, not burned, so this photo's tombstone is already
          // gone. Cap the damage at one row. A rejected key is permanent
          // for a deliberate photo, yet refuses photos 2..N just the same:
          // stop there too rather than upload every one of them for the
          // same verdict.
          if (outcome.retryable ||
              outcome.errorKind == AnalysisErrorKind.rejectedKey) {
            stopOutcome = outcome;
            stopped = true;
            if (mounted) setState(() => _progressDone = attempted);
            break;
          }
        }
      }
      // Keep going even if the user left: the confirmation promised the work
      // continues, and abandoning photos 4..21 mid-run would leave their
      // ledger rows churned for nothing. Only the UI updates need a mounted
      // screen. (Photos already enqueued are the pipeline's business anyway.)
      if (!mounted) continue;
      setState(() {
        _actedOn++;
        _progressDone = _actedOn;
      });
    }
    if (!mounted) return;
    final remaining = items.length - attempted;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(stopOutcome != null
            // Stopped on the LAST photo: nothing remains, so no "the
            // remaining 0 photos … run this again later" (U13).
            ? remaining == 0
                ? l.covStoppedLast(label, attempted, items.length,
                    outcomeBody(l, stopOutcome))
                : l.covStoppedBecause(label, attempted, items.length,
                    outcomeBody(l, stopOutcome), remaining)
            : stopped
                ? l.covStopped(label, attempted, items.length, remaining)
                : failures == 0
                ? l.covDone(label, items.length)
                : l.covDoneFailures(label, failures, items.length))));
    await _runAudit();
  }

  /// A "not food" tombstone or a permanent failure is otherwise a dead end:
  /// re-analysis repeats the verdict, so the only real remedy is letting the
  /// user enter the meal (the add flow offers the same for both).
  Future<void> _logManually(CoverageItem item) async {
    final open = widget.logManually;
    if (open == null) return;
    final photo = await widget.auditor.loadForProcessing(item);
    if (!mounted) return;
    if (photo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.covPhotoUnreadable)));
      return;
    }
    final saved = await open(photo);
    if (saved && mounted) await _runAudit();
  }

  Future<Uint8List?> _thumbFor(CoverageItem item) =>
      _thumbCache.putIfAbsent(item.assetId,
          () => widget.library?.thumbnailByAssetId(item.assetId) ??
              Future.value(null));

  /// One list of photos (never scanned / judged not food / failed): a
  /// header with its bulk action, the tiles in a grouped cell, the help
  /// text and the "…and N more" line under it.
  Widget _tileSection({
    required String title,
    required Widget action,
    String? help,
    required List<CoverageItem> items,
    required bool busy,
    required bool manual,
    String Function(int more)? moreText,
  }) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final shown = items.take(_maxTiles).toList();
    final more = items.length - shown.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          kGroupInset, AppSpace.sectionTop, kGroupInset, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
                left: AppSpace.rowH, bottom: AppSpace.headerToCells),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpace.s8,
              runSpacing: AppSpace.s4,
              children: [
                Semantics(
                  header: true,
                  child: Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: colors.secondaryLabel)),
                ),
                action,
              ],
            ),
          ),
          Material(
            color: colors.cell,
            borderRadius: BorderRadius.circular(kCellRadius),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0)
                    Padding(
                      // Past the 44-pt thumbnail: 16 + 44 + 16.
                      padding: const EdgeInsets.only(left: 76),
                      child: Divider(
                          height: hairlineWidth(context),
                          thickness: hairlineWidth(context),
                          color: colors.separator),
                    ),
                  _PhotoTile(
                    item: shown[i],
                    thumb: _thumbFor(shown[i]),
                    // Not while a bulk run is going: a manual save here
                    // re-ran the audit mid-run and re-enabled Log all /
                    // Retry all under it (B20).
                    onTap: !manual || busy || widget.logManually == null
                        ? null
                        : () => _logManually(shown[i]),
                  ),
                ],
              ],
            ),
          ),
          for (final line in [
            ?help,
            if (more > 0 && moreText != null) moreText(more),
          ])
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.footerSide,
                  AppSpace.cellsToFooter, AppSpace.footerSide, 0),
              child: Text(line,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.secondaryLabel)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final report = _report;
    final busy = _phase == _Phase.scanning || _phase == _Phase.acting;
    final canIncrease = !busy && _days < _maxDays;
    final canDecrease = !busy && _days > _minDays;
    return Scaffold(
      backgroundColor: pageColor(context),
      appBar: AppBar(title: Text(context.l10n.covTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpace.s32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(kGroupInset + AppSpace.rowH,
                AppSpace.s8, kGroupInset + AppSpace.rowH, 0),
            child: Text(
              context.l10n.covIntro(_days),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.secondaryLabel),
            ),
          ),
          GroupedCard(
            padding: const EdgeInsets.all(AppSpace.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      // Read as the window and its days: on its own the
                      // slider said '21%' with no name on an iPhone (the
                      // Cupertino slider has no semantic formatter) and
                      // its value label, '7 d', as its name on Android. A
                      // screen reader's swipe up / down moves it a day, as
                      // the lookback sheet's does (settings_screen.dart).
                      child: Semantics(
                        container: true,
                        excludeSemantics: true,
                        slider: true,
                        enabled: !busy,
                        label: context.l10n.covWindowLabel,
                        value: context.l10n.lookbackDays(_days),
                        increasedValue: canIncrease
                            ? context.l10n.lookbackDays(_days + 1)
                            : null,
                        decreasedValue: canDecrease
                            ? context.l10n.lookbackDays(_days - 1)
                            : null,
                        onIncrease:
                            canIncrease ? () => setState(() => _days++) : null,
                        onDecrease:
                            canDecrease ? () => setState(() => _days--) : null,
                        child: Slider.adaptive(
                          key: const Key('coverageWindowSlider'),
                          value: _days.toDouble(),
                          min: _minDays.toDouble(),
                          max: _maxDays.toDouble(),
                          divisions: _maxDays - _minDays,
                          label: context.l10n.covDaysShort(_days),
                          onChanged: busy
                              ? null
                              : (v) => setState(() => _days = v.round()),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.s8),
                    Text(context.l10n.covDaysShort(_days),
                        style: context.nums.value
                            .copyWith(color: colors.label)),
                  ],
                ),
                const SizedBox(height: AppSpace.s12),
                FilledButton.icon(
                  key: const Key('runCoverageCheck'),
                  onPressed: busy ? null : _runAudit,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(_phase == _Phase.scanning
                      ? context.l10n.covChecking
                      : _phase == _Phase.acting
                          ? context.l10n.working
                          : context.l10n.covRun),
                ),
                if (busy) ...[
                  const SizedBox(height: AppSpace.s12),
                  LinearProgressIndicator(
                    key: const Key('coverageProgress'),
                    value: _progressTotal == 0
                        ? null
                        : _progressDone / _progressTotal,
                  ),
                  const SizedBox(height: AppSpace.s4),
                  Text('$_progressDone / $_progressTotal',
                      style: context.nums.inline
                          .copyWith(color: colors.secondaryLabel)),
                ],
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(kGroupInset + AppSpace.rowH,
                  AppSpace.s12, kGroupInset + AppSpace.rowH, 0),
              child: Text(_error!,
                  key: const Key('coverageError'),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: colors.danger)),
            ),
          if (report != null) ...[
            _SummaryCard(report: report),
            if (report.missing.isNotEmpty)
              _tileSection(
                title: context.l10n.covNeverScanned(report.missing.length),
                action: FilledButton.tonal(
                  key: const Key('logAllMissing'),
                  onPressed: busy
                      ? null
                      : () async {
                          final l = context.l10n; // before the await
                          if (await _confirmBulk(
                              report.missing, l.covVerbLog)) {
                            await _processAll(
                                report.missing, l.covProgLogging);
                          }
                        },
                  child: Text(context.l10n.covLogAll),
                ),
                items: report.missing,
                busy: busy,
                manual: false,
                moreText: context.l10n.covMoreLogAll,
              ),
            if (report.skippedNonFood.isNotEmpty)
              _tileSection(
                title: context.l10n
                    .covJudgedNotFood(report.skippedNonFood.length),
                // A 'skipped' tombstone is permanent for the automated
                // path, so improved rules (e.g. now admitting takeout
                // order screenshots) would never revisit these on their
                // own. A DELIBERATE re-add reclaims skipped rows
                // (spec §2.3) — which is exactly what this does.
                action: FilledButton.tonal(
                  key: const Key('reanalyzeAllSkipped'),
                  onPressed: busy
                      ? null
                      : () async {
                          final l = context.l10n; // before the await
                          if (await _confirmBulk(
                              report.skippedNonFood, l.covAnalyzeAgain)) {
                            await _processAll(
                                report.skippedNonFood, l.covProgReanalyzing);
                          }
                        },
                  child: Text(context.l10n.covAnalyzeAgain),
                ),
                help: context.l10n.covNotFoodHelp,
                items: report.skippedNonFood,
                busy: busy,
                manual: true,
                moreText: context.l10n.covMoreNotFood,
              ),
            // A ledgered 'failed' is a NON-retryable verdict (decode
            // failure, oversize, a coded 400, "no usable result"), so
            // Retry all usually repeats it at another model call each
            // time. Same escape hatch as the add flow's
            // canLogManually = skipped || failed.
            if (report.failed.isNotEmpty)
              _tileSection(
                title: context.l10n.covFailedEarlier(report.failed.length),
                action: FilledButton.tonal(
                  key: const Key('retryAllFailed'),
                  onPressed: busy
                      ? null
                      : () async {
                          final l = context.l10n; // before the await
                          if (await _confirmBulk(
                              report.failed, l.covVerbRetry)) {
                            await _processAll(
                                report.failed, l.covProgRetrying);
                          }
                        },
                  child: Text(context.l10n.covRetryAll),
                ),
                help: context.l10n.covFailedHelp,
                items: report.failed,
                busy: busy,
                manual: true,
                moreText: context.l10n.covMoreRetryAll,
              ),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report});
  final CoverageReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    // A failed photo is not "accounted for": the success check over
    // '… · 1 failed' contradicted itself (U13).
    final ok = report.fullyCovered && report.failed.isEmpty;
    final onlyFailed = report.fullyCovered && report.failed.isNotEmpty;
    final warn = TextStyle(color: colors.danger);
    return GroupedCard(
      key: const Key('coverageSummary'),
      margin: const EdgeInsets.fromLTRB(
          kGroupInset, AppSpace.s16, kGroupInset, 0),
      padding: const EdgeInsets.all(AppSpace.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                    ok ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                    size: 22,
                    color: ok ? colors.success : colors.secondaryLabel),
              ),
              const SizedBox(width: AppSpace.s8),
              Expanded(
                child: Text(
                  ok
                      ? context.l10n.covAllAccounted(report.scanned)
                      : onlyFailed
                          ? context.l10n.covSummaryFailed(
                              report.scanned, report.failed.length)
                          : context.l10n.covSummary(
                              report.scanned, report.missing.length),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: colors.label),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.s8),
          Text(
            [
              context.l10n.covLoggedAsMeals(report.logged.length),
              context.l10n.covNotFoodCount(report.skippedNonFood.length),
              // Read-only: the deduction already lives on the meal, and a
              // re-analysis would log the remains as a second meal.
              if (report.leftoverApplied > 0)
                  context.l10n.covLeftoverCount(report.leftoverApplied),
              if (report.failed.isNotEmpty)
                  context.l10n.covFailedCount(report.failed.length),
              if (report.deleted > 0)
                  context.l10n.covDeletedCount(report.deleted),
              if (report.inFlight > 0)
                  context.l10n.covInFlightCount(report.inFlight),
              if (report.unreadable > 0)
                  context.l10n.covUnreadableCount(report.unreadable),
              if (report.tooLargeToAnalyze > 0)
                  context.l10n.covTooLargeCount(report.tooLargeToAnalyze),
            ].join(' · '),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.secondaryLabel),
          ),
          if (report.limitedAccess)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.s8),
              child: Text(
                context.l10n.covLimitedAccess,
                style: theme.textTheme.bodySmall?.merge(warn),
              ),
            ),
          if (report.truncated)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.s8),
              child: Text(
                context.l10n.covTruncated,
                style: theme.textTheme.bodySmall?.merge(warn),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.item, required this.thumb, this.onTap});
  final CoverageItem item;
  final Future<Uint8List?> thumb;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return ListTile(
      onTap: onTap,
      trailing: onTap == null
          ? null
          : Icon(Icons.edit_outlined, size: 18, color: colors.accent),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.rowH),
      leading: FutureBuilder<Uint8List?>(
        future: thumb,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) {
            return Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.fill,
                borderRadius: BorderRadius.circular(AppRadius.m),
              ),
              child: Icon(Icons.photo_outlined,
                  size: 20, color: colors.secondaryLabel),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.m),
            child: Image.memory(bytes,
                width: 44, height: 44, fit: BoxFit.cover),
          );
        },
      ),
      title: Text(
          item.fileName.isEmpty ? context.l10n.covUnnamedPhoto : item.fileName,
          style: theme.textTheme.bodyLarge?.copyWith(color: colors.label),
          // One line normally; at the accessibility sizes a name of a
          // dozen characters was 'demo_p…', so it wraps there instead.
          overflow: isLargeText(context) ? null : TextOverflow.ellipsis),
      subtitle: Text(
          '${item.createDate.year}-'
          '${item.createDate.month.toString().padLeft(2, '0')}-'
          '${item.createDate.day.toString().padLeft(2, '0')} '
          '${item.createDate.hour.toString().padLeft(2, '0')}:'
          '${item.createDate.minute.toString().padLeft(2, '0')}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: colors.secondaryLabel)),
    );
  }
}
