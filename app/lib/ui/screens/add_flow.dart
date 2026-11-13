/// Add flow (FAB): pick a recent photo (grid → analyzing spinner → meal
/// card, spec §2.3/§3/§6 pipeline with deliberate=true), or DESCRIBE a meal
/// in free text (NlExecutor.describeMeal → estimate → the meal editor as a
/// preview → insert), enter numbers manually, or FIX/delete a logged meal
/// (FixMealScreen → handleText, spec §4). Since 2026-07-31 this sheet is
/// the ONE owner of every meal action — the Today chat bar is gone.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../core/leftover_logic.dart' show revertedLeftover;
import '../../core/outcome_kind.dart';
import '../../services/analyzer/platform_decode.dart';
import '../../services/photo/system_photo_picker.dart';
import '../ai_consent.dart';
import '../outcome_text.dart';
import '../photo_pipeline.dart';
import '../l10n.dart';
import '../large_text.dart';
import '../theme/app_dialog.dart';
import '../theme/tokens.dart';
import '../widgets/grouped.dart';
import '../widgets/reply_note.dart';
import '../widgets/states.dart';
import 'fix_meal_screen.dart';
import 'leftover_flow.dart';
import 'meal_editor_screen.dart';
import 'usual_foods_screen.dart';
import '../services.dart';
import '../widgets/small_spinner.dart';

/// Entry point wired to the FAB. [onChanged] refreshes the Today screen.
Future<void> openAddFlow(BuildContext context, UiServices services,
    {Future<void> Function()? onChanged}) async {
  // Native-ized in loop cycle 2 (interaction lens #1): drag handle, a
  // title, and the same grouped-row language as Settings — the sheet is
  // the app's single logging entry point and looked stock-Material.
  // Run 7: the shared grouped sheet (title2 heading, #1C1C1E sheet with
  // #2C2C2E cells in dark mode, where the hand-passed page colour put
  // #1C1C1E cells on black) and badge roles that say what each row is:
  // the brand for photos, grey for the plain ways in, indigo for Fix —
  // fixing a meal is not a fault, so not red.
  final choice = await showGroupedSheet<String>(
    context,
    title: context.l10n.addSheetTitle,
    // Scrolls inside the sheet since the 5th tile (leftovers, 2026-08-05):
    // on a short viewport the fixed Column overflowed instead of scrolling.
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupedSection(
          children: [
            GroupedRow(
              key: const Key('addFromPhotos'),
              icon: Icons.photo_library_outlined,
              iconColor: Theme.of(ctx).colorScheme.primary,
              title: ctx.l10n.addFromPhotos,
              onTap: () => Navigator.of(ctx).pop('photos'),
            ),
            if (services.usualFoods != null) usualFoodsRow(ctx),
            GroupedRow(
              key: const Key('addLeftover'),
              icon: Icons.restaurant_outlined,
              iconColor: Theme.of(ctx).colorScheme.secondary,
              title: ctx.l10n.addLeftover,
              value: ctx.l10n.addLeftoverNote,
              onTap: () => Navigator.of(ctx).pop('leftover'),
            ),
            GroupedRow(
              key: const Key('addFromText'),
              icon: Icons.edit_note,
              iconColor: Theme.of(ctx).colorScheme.secondary,
              title: ctx.l10n.addDescribe,
              value: ctx.l10n.addDescribeNote,
              onTap: () => Navigator.of(ctx).pop('text'),
            ),
            // The zero-dependency path: the other two options need a
            // working AI key and spend a model call — with no key
            // (first run), a quota pause, or offline, the + button was
            // a dead end.
            GroupedRow(
              key: const Key('addManually'),
              icon: Icons.keyboard_alt_outlined,
              iconColor: Theme.of(ctx).colorScheme.secondary,
              title: ctx.l10n.addManual,
              value: ctx.l10n.addManualNote,
              onTap: () => Navigator.of(ctx).pop('manual'),
            ),
          ],
        ),
        // Corrections lived in a chat bar pinned to Today until
        // 2026-07-31 — the user's verdict: one button owns ALL meal
        // actions, adding and fixing alike.
        GroupedSection(
          footer: ctx.l10n.addFixFooter,
          children: [
            GroupedRow(
              key: const Key('addFixMeal'),
              icon: Icons.build_outlined,
              iconColor: Theme.of(ctx).colorScheme.tertiary,
              title: ctx.l10n.addFix,
              onTap: () => Navigator.of(ctx).pop('fix'),
            ),
          ],
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (choice == 'photos') {
    // Android: the system Photo Picker (Play's photo policy); null on iOS.
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AddPhotoScreen(
            services: services, systemPicker: platformSystemPhotoPicker())));
  } else if (choice == 'leftover') {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => LeftoverScreen(services: services)));
  } else if (choice == 'text') {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AddTextScreen(
            executor: services.executor,
            dao: services.dao,
            settings: services.settings)));
  } else if (choice == 'usual') {
    // Logged again with saved numbers: no model, so no AI consent.
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => UsualFoodsScreen(usual: services.usualFoods!)));
  } else if (choice == 'manual') {
    // Defaults to today/now inside the editor (MealDraft.blank).
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MealEditorScreen(dao: services.dao)));
  } else if (choice == 'fix') {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FixMealScreen(
            executor: services.executor,
            settings: services.settings,
            inUse: services.mealInUse)));
  } else {
    return;
  }
  await onChanged?.call();
}

/// Recent-photos grid → tap → analyzing spinner → result card. On Android
/// without full photo access: the system Photo Picker → the same spinner
/// and card.
class AddPhotoScreen extends StatefulWidget {
  final UiServices services;

  /// Android's system Photo Picker (Google Play's photo policy; the Play
  /// build declares no photo permission at all). Without full access the
  /// screen never asks for the library: it asks for the AI consent and
  /// opens this picker at once. With full access it keeps the grid and
  /// adds a row that opens the picker. Null on iOS: the grid as before.
  final SystemPhotoPicker? systemPicker;
  const AddPhotoScreen({super.key, required this.services, this.systemPicker});

  @override
  State<AddPhotoScreen> createState() => _AddPhotoScreenState();
}

class _AddPhotoScreenState extends State<AddPhotoScreen> {
  late Future<List<RecentAsset>> _assets;
  bool _analyzing = false;
  bool _permissionDenied = false;
  // iOS "limited" / Android "selected photos": the grid holds only the
  // photos picked in that one system dialog, so a meal shot later never
  // appears here. Settings warns when the watcher is switched on; this
  // screen said nothing (2026-10-09).
  bool _limited = false;
  // Future-cached per asset: dedupes in-flight fetches across rebuilds
  // (the same rule the coverage screen learned).
  final Map<String, Future<Uint8List?>> _thumbs = {};

  /// Android without full access: no grid, the system picker is the
  /// screen's one source.
  bool _pickerOnly = false;

  /// Android with full access: the grid, plus a row that opens the picker
  /// (for a photo older than the grid's thirty).
  bool _pickerRow = false;

  /// The picker could not open on this phone.
  bool _pickerUnavailable = false;

  /// Set while the picker is open: one pick at a time.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _assets = _load();
  }

  Future<List<RecentAsset>> _load() async {
    final system = widget.systemPicker;
    if (system == null) return _loadGrid();
    // Play's photo policy: full access is READ, never asked for. The Play
    // build declares no photo permission, so a request there was a silent
    // denial and the "isn't allowed" dead end.
    final full = await system.hasBroadAccess();
    if (!mounted) return const [];
    if (full) {
      _pickerRow = true;
      return widget.services.picker.recentAssets();
    }
    _pickerOnly = true;
    // After the first frame: the consent dialog needs this route on
    // screen.
    WidgetsBinding.instance
      ..addPostFrameCallback(
          (_) => _openSystemPicker(leaveOnCancel: true))
      ..ensureVisualUpdate();
    return const [];
  }

  /// Ask for permission FIRST: the picker returns [] on denial, which
  /// rendered as 'No recent photos found.' — indistinguishable from an
  /// empty camera roll and, once the OS stops re-prompting, a permanent
  /// dead end in the app's headline flow.
  ///
  /// LISTS assets only. The previous version read up to 30 ORIGINALS (25 MB
  /// each) before showing anything and then decoded each 12 MP image
  /// full-res into a 120 px cell — hundreds of MB resident, on a screen
  /// that uses exactly one photo.
  Future<List<RecentAsset>> _loadGrid() async {
    final granted = await widget.services.requestPhotoPermission();
    if (!mounted) return const [];
    if (!granted) {
      setState(() => _permissionDenied = true);
      return const [];
    }
    // Unknown counts as full, the same rule as hasFullAccess itself: the
    // note is advisory, and a false "limited" would nag a full grant.
    var full = true;
    final lib = widget.services.photoLibrary;
    if (lib != null) {
      try {
        full = await lib.hasFullAccess();
      } catch (_) {}
      if (!mounted) return const [];
    }
    _limited = !full;
    return widget.services.picker.recentAssets();
  }

  /// Says why photos are missing and where to grant the rest. Shown above
  /// the grid AND in place of "no recent photos": a limited grant with
  /// nothing selected is not an empty camera roll.
  Widget _limitedNote(BuildContext context) {
    final open = widget.services.openSystemSettings;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        key: const Key('addPhotosLimited'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.photo_library_outlined, size: 16, color: muted),
          const SizedBox(width: 8),
          // Button UNDER the text, not beside it: at large text sizes a
          // side-by-side button would squeeze the sentence to nothing.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.addPhotosLimited,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: muted),
                ),
                if (open != null)
                  TextButton(
                    key: const Key('addPhotosLimitedSettings'),
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact),
                    onPressed: () => open(),
                    child: Text(context.l10n.openSystemSettings),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<Uint8List?> _thumbFor(String assetId) => _thumbs.putIfAbsent(
      assetId, () => widget.services.picker.thumbnail(assetId));

  /// Set while the AI consent dialog is up: a second tap in the same frame
  /// must not open a second one (the same race [_analyzing] guards).
  bool _askingConsent = false;

  Future<void> _pick(RecentAsset asset) async {
    // Guard BEFORE the async gap: onTap reads _analyzing from the last
    // BUILD, so two taps in the same frame both pass that check and run
    // two analyses — two model calls, two ledger reservations, for one
    // meal (review 2026-07-31).
    if (_analyzing || _askingConsent) return;
    // App Store 5.1.2(i): permission for this AI recipient before the
    // photo's bytes are even read. Without the spinner: an animating
    // overlay behind a dialog never settles.
    _askingConsent = true;
    final allowed = await ensureAiConsent(context, widget.services.settings);
    _askingConsent = false;
    if (!allowed || !mounted || _analyzing) return;
    setState(() => _analyzing = true);
    // ORIGINAL bytes for THIS photo only — md5 identity (§6.2) needs the
    // original, but only the chosen one.
    final deliberate = await widget.services.picker.loadOriginal(asset);
    if (!mounted) return;
    if (deliberate == null) {
      setState(() => _analyzing = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.addPhotoUnreadable)));
      return;
    }
    await _analyze(deliberate);
  }

  /// The AI consent, then the system picker, then the same analysis as a
  /// grid tap. [leaveOnCancel]: opened by the screen itself, so Not now or
  /// a cancelled pick closes it — there is nothing else on it to do.
  Future<void> _openSystemPicker({required bool leaveOnCancel}) async {
    final system = widget.systemPicker;
    if (system == null || !mounted) return;
    if (_analyzing || _askingConsent || _picking) return;
    // Consent before any photo is chosen, as for a grid tap (5.1.2(i)).
    _askingConsent = true;
    final allowed = await ensureAiConsent(context, widget.services.settings);
    _askingConsent = false;
    if (!mounted || _analyzing || _picking) return;
    if (!allowed) {
      if (leaveOnCancel) _leave();
      return;
    }
    _picking = true;
    final SystemPick pick;
    try {
      pick = await system.pick(max: 1);
    } finally {
      _picking = false;
    }
    if (!mounted) return;
    switch (pick.status) {
      case SystemPickStatus.missing:
        // A build without the native picker: the grid flow as before.
        setState(() {
          _pickerOnly = false;
          _pickerRow = false;
          _assets = _loadGrid();
        });
        return;
      case SystemPickStatus.unavailable:
        // No library request here: on the Play build it could only fail.
        setState(() => _pickerUnavailable = true);
        return;
      case SystemPickStatus.busy:
        return;
      case SystemPickStatus.cancelled:
        if (leaveOnCancel) _leave();
        return;
      case SystemPickStatus.ok:
        break;
    }
    if (pick.photos.isEmpty) {
      if (pick.tooBig + pick.failed > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.addPhotoUnreadable)));
      } else if (leaveOnCancel) {
        _leave(); // nothing chosen: a cancel
      }
      return;
    }
    await _analyze(pick.photos.first);
  }

  /// Closes this screen (never the route under it: maybePop leaves a lone
  /// root route alone).
  void _leave() => Navigator.of(context).maybePop();

  /// "Choose from all photos…": the picker on request.
  Widget _pickerButton(BuildContext context) => FilledButton.tonalIcon(
        key: const Key('addChooseAllPhotos'),
        onPressed: _analyzing
            ? null
            : () => _openSystemPicker(leaveOnCancel: false),
        icon: const Icon(Icons.photo_library_outlined),
        label: Text(context.l10n.addChooseAllPhotos),
      );

  /// The picker-only screen: what the picker is for, the button, and the
  /// scale tip — or why the picker cannot open.
  Widget _pickerPage(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: muted);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _pickerUnavailable
              ? [
                  Text(
                    context.l10n.addPickerUnavailable,
                    key: const Key('addPickerUnavailable'),
                    textAlign: TextAlign.center,
                  ),
                ]
              : [
                  Icon(Icons.photo_library_rounded, size: 48, color: muted),
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.addPickerNote,
                    key: const Key('addPickerNote'),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  _pickerButton(context),
                  const SizedBox(height: 16),
                  Text(context.l10n.addPhotosTip,
                      textAlign: TextAlign.center, style: small),
                ],
        ),
      ),
    );
  }

  Future<void> _analyze(IntakePhoto deliberate) async {
    if (!_analyzing) setState(() => _analyzing = true);
    // Through the APP'S ONE pipeline (services.processPhoto → enqueue), not
    // a private instance: a second analyzer call concurrent with the
    // watcher self-inflicts rate limits and doubles resident photo bytes.
    final process = widget.services.processPhoto;
    final outcome = process != null
        ? await process(deliberate)
        : await PhotoPipeline(
                dao: widget.services.dao, analyzer: widget.services.analyzer)
            .process(deliberate);
    if (!mounted) {
      // Backed out mid-analysis (the AppBar back stays live under the
      // overlay): the dialog below is gone with the screen, and process()
      // itself announces only saves, leftover deductions and permanent
      // failures — not food, duplicate, already logged, still analyzing
      // and a transient failure were dropped without a word (2026-10-12).
      // Same filter as the share sheet's, so nothing is said twice.
      final say = unannouncedOutcome(outcome, picked: true);
      if (say != null) {
        try {
          widget.services.announceOutcome?.call(say);
        } catch (_) {}
      }
      return;
    }
    setState(() => _analyzing = false);
    // A refused photo must not be a dead end: the model saying "not food"
    // (routine for drinks) or failing permanently would otherwise leave the
    // user with no way to log that photo AT ALL — re-picking it just
    // repeats the same verdict.
    // Still analyzing too: the run holding the photo may be one iOS cut
    // off, and until its row goes stale (up to 30 min) OK was the only way
    // out of a meal the user is looking at right now (2026-10-12).
    final canLogManually = outcome.kind == PhotoOutcomeKind.skipped ||
        outcome.kind == PhotoOutcomeKind.failed ||
        outcome.kind == PhotoOutcomeKind.inFlight;
    // A WRONG automatic leftover verdict was a dead end too: the earlier
    // meal stayed cut, and re-picking the photo repeats the verdict. The
    // escape puts that meal back and logs the photo as its own meal.
    final canUndoLeftover =
        outcome.kind == PhotoOutcomeKind.leftoverApplied &&
            outcome.mealId != null &&
            outcome.previousAnalysis != null &&
            outcome.analysis != null;
    final failed = outcome.kind == PhotoOutcomeKind.failed;
    // No key (or no server) is setup that is missing, not an analysis that
    // failed: the title said "Analysis failed" for a photo nothing ever
    // looked at (U2). The body names where to add it.
    // A saved server address that will not parse also reports noServerKey,
    // but the server IS set up: "AI isn't set up yet" over a body saying
    // the address has a typo contradicted itself. It is not retryable
    // either: Retry fails again at once on the same address.
    final badAddress = failed &&
        outcome.errorKind == AnalysisErrorKind.noServerKey &&
        isBadServerAddress(outcome.message);
    final notSetUp = failed &&
        !badAddress &&
        (outcome.errorKind == AnalysisErrorKind.noApiKey ||
            outcome.errorKind == AnalysisErrorKind.noServerKey);
    // The daily-quota pause sends nothing until it lifts (up to 12 h):
    // Retry got the same verdict at once, and the body said "tap Retry"
    // (B8).
    final quotaPaused =
        failed && outcome.errorKind == AnalysisErrorKind.quotaPaused;
    // A transient failure RELEASED the photo, and nothing re-offers a
    // picked photo by itself (the automatic scan is off by default and
    // never looks past its window): the dialog offers the retry instead of
    // promising one. Not for a missing key — Settings is the fix there.
    final canRetry = failed &&
        outcome.retryable &&
        !notSetUp &&
        !quotaPaused &&
        !badAddress;
    final l = context.l10n;
    final String body;
    if (quotaPaused) {
      final until = widget.services.settings.quotaPauseUntil;
      body = until == null
          ? l.outcomeQuotaPausedPickMsgNoTime
          : l.outcomeQuotaPausedPickMsg(dayTimeLabel(l, until.toLocal()));
    } else {
      body = outcomeBody(l, outcome, deliberate: true);
    }
    // "If this IS food" answers a not-food verdict only. A failed photo
    // had no verdict (no key, network, rate limit…), and an in-flight one
    // has not had it yet (U12). The quota body already says to log it.
    final hint = switch (outcome.kind) {
      PhotoOutcomeKind.skipped => l.outcomeLogManuallyHint,
      PhotoOutcomeKind.failed when !quotaPaused =>
        l.outcomeLogManuallyFailedHint,
      _ => null,
    };
    final choice = await showDialog<String>(
      context: context,
      // Scrollable (A1): at the largest text sizes the title and the
      // stacked actions left the body no room.
      builder: (ctx) => appAlertDialog(
        title: Text(switch (outcome.kind) {
          PhotoOutcomeKind.saved => l.outcomeSaved,
          PhotoOutcomeKind.skipped => l.outcomeSkipped,
          PhotoOutcomeKind.duplicate => l.outcomeDuplicate,
          PhotoOutcomeKind.alreadyTracked => l.outcomeAlreadyTracked,
          PhotoOutcomeKind.inFlight => l.outcomeInFlight,
          PhotoOutcomeKind.failed => badAddress
              ? l.outcomeCheckServer
              : (notSetUp ? l.outcomeNotSetUp : l.outcomeFailed),
          PhotoOutcomeKind.leftoverApplied => l.outcomeLeftoverApplied,
        }),
        content: Text(hint == null ? body : '$body\n\n$hint'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('ok'),
            child: Text(l.okButton),
          ),
          if (canRetry)
            TextButton(
              key: const Key('retryAnalysisButton'),
              onPressed: () => Navigator.of(ctx).pop('retry'),
              child: Text(l.retry),
            ),
          if (canLogManually)
            FilledButton(
              key: const Key('logManuallyButton'),
              onPressed: () => Navigator.of(ctx).pop('manual'),
              child: Text(l.logManually),
            ),
          if (canUndoLeftover)
            FilledButton(
              key: const Key('undoLeftoverButton'),
              onPressed: () => Navigator.of(ctx).pop('undoLeftover'),
              child: Text(l.outcomeUndoLeftover),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'retry') {
      // The consent first, as for the pick itself: the recipient may have
      // been stopped or switched since (that is one reason a photo comes
      // back unsent — photo_pipeline.dart AiSendGate), and a Retry that
      // did not ask would only be refused again. Already allowed: no
      // dialog.
      if (!await ensureAiConsent(context, widget.services.settings) ||
          !mounted) {
        return;
      }
      // Same photo, same shared FIFO: the hash was released, so this is a
      // fresh reservation, never a second one.
      await _analyze(deliberate);
      return;
    }
    if (choice == 'undoLeftover') {
      final undone = await _undoLeftover(outcome);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(undone
              ? l.outcomeUndoLeftoverDone
              : l.outcomeUndoLeftoverStale)));
    }
    if (choice == 'manual' || choice == 'undoLeftover') {
      final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => MealEditorScreen(
          dao: widget.services.dao,
          fromPhoto: deliberate,
          makeThumb: makeMealThumbAny,
        ),
      ));
      if (saved == true && mounted) {
        Navigator.of(context).pop();
        return;
      }
    }
    if (outcome.kind == PhotoOutcomeKind.saved && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Puts the cut meal back as it was before THIS deduction. Re-reads the
  /// row first and writes only while it still shows that deduction
  /// (revertedLeftover) — a deleted meal or a later fix is left alone —
  /// and compare-and-set against the text it read (design R6a), so a write
  /// landing in between (a restaurant lookup, a chat fix) is never undone
  /// with it. The write keeps corrected=1 (spec §2.4); the photo's ledger
  /// row stays 'skipped', which the editor's photo save turns into
  /// 'saved'.
  Future<bool> _undoLeftover(PhotoOutcome outcome) async {
    final dao = widget.services.dao;
    final id = outcome.mealId!;
    final current = await dao.mealSnapshot(id);
    if (current == null) return false;
    final restored = revertedLeftover(current.meal.analysis,
        applied: outcome.analysis!, before: outcome.previousAnalysis!);
    if (restored == null) return false;
    return dao.updateMealAnalysisIfUnchanged(id,
        expectedRaw: current.rawAnalysis, analysis: restored);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.addPhotosTitle)),
      body: Stack(
        children: [
          FutureBuilder<List<RecentAsset>>(
            future: _assets,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const LoadingState();
              }
              if (snap.hasError) {
                return Center(
                    child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(context.l10n.addPhotosLoadFailed('${snap.error}')),
                ));
              }
              final assets = snap.data ?? const <RecentAsset>[];
              if (_pickerOnly || (_pickerRow && assets.isEmpty)) {
                return _pickerPage(context);
              }
              if (_permissionDenied) {
                final open = widget.services.openSystemSettings;
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          context.l10n.photoPermissionDenied,
                          key: const Key('photoPermissionDenied'),
                          textAlign: TextAlign.center,
                        ),
                        if (open != null) ...[
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            key: const Key('openSystemSettings'),
                            onPressed: () => open(),
                            child: Text(context.l10n.openSystemSettings),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }
              if (assets.isEmpty) {
                if (_limited) {
                  return Align(
                      alignment: Alignment.topCenter,
                      child: _limitedNote(context));
                }
                return EmptyState(
                    icon: Icons.photo_library_rounded,
                    title: context.l10n.addNoPhotos);
              }
              final header = <Widget>[
                if (_limited) _limitedNote(context),
                if (_pickerRow)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _pickerButton(context)),
                  ),
                // Portion accuracy is the model's weakest link, and a scale
                // reference in frame is the cheapest fix the USER controls.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    key: const Key('scaleReferenceTip'),
                    // Top-aligned: at large text the tip wraps to several
                    // lines and a centred icon floated beside the middle.
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpace.s2),
                        child: Icon(Icons.straighten,
                            size: 16,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.l10n.addPhotosTip,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ];
              final grid = GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
                itemCount: assets.length,
                itemBuilder: (context, i) => GestureDetector(
                  key: Key('recentPhoto$i'),
                  onTap: _analyzing ? null : () => _pick(assets[i]),
                  // VoiceOver/TalkBack read thirty identical unlabeled
                  // 'image's — no way to find the photo of a given meal.
                  // Position + shot time name the cell; the label sits
                  // INSIDE the gesture widget so the tap action stays on
                  // the same node, and covers the placeholder too.
                  child: Semantics(
                    image: true,
                    label: context.l10n.photoCellLabel(i + 1, assets.length,
                        context.photoTakenAt(assets[i].createdAt)),
                    child: ExcludeSemantics(
                      child: FutureBuilder<Uint8List?>(
                        future: _thumbFor(assets[i].id),
                        builder: (context, snap) {
                          final bytes = snap.data;
                          final placeholder =
                              ColoredBox(color: context.colors.fill);
                          if (bytes == null || bytes.isEmpty) {
                            return placeholder;
                          }
                          // The bytes are already a bounded PhotoKit
                          // thumbnail, never the 12 MP original: a
                          // cacheWidth cap would only re-soften it (U28).
                          // Bytes that do not decode keep the placeholder.
                          return Image.memory(bytes,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => placeholder);
                        },
                      ),
                    ),
                  ),
                ),
              );
              // With a "selected photos" grant the note and the tip took the
              // whole height at large text and no photo could be picked
              // (review 1.7.0). There the screen scrolls, and the grid keeps
              // a full screen of its own below them.
              return LayoutBuilder(
                builder: (context, box) => isLargeText(context)
                    ? SingleChildScrollView(
                        key: const Key('addPhotoScroll'),
                        child: Column(children: [
                          ...header,
                          SizedBox(height: box.maxHeight, child: grid),
                        ]),
                      )
                    : Column(children: [...header, Expanded(child: grid)]),
              );
            },
          ),
          if (_analyzing)
            // Live region inside: a slow round-trip is otherwise silent
            // to a screen reader until the outcome dialog.
            AnalyzingOverlay(
              label: context.l10n.analyzing,
              labelKey: const Key('photoAnalyzingText'),
              spinnerKey: const Key('photoAnalyzing'),
            ),
        ],
      ),
    );
  }
}

/// Top padding for the Describe and Fix pages: a field's floating label
/// sits on its top border, half above the field, and at the largest text
/// sizes that half (about 20 pt at AX5) is more than the usual 16-pt
/// padding, so the scroll view clipped the label's top.
double _topInset(BuildContext context) =>
    isLargeText(context) ? AppSpace.s24 : AppSpace.gutter;

/// Describe-a-meal entry: free text (any language) → describeMeal's
/// new-meal-only estimate → the meal editor as a PREVIEW → insert with
/// source 'manual_text' (spec §4.6 parity). Nothing is written until the
/// user saves from the editor, so a model guess about food it never saw
/// cannot silently enter the day's totals.
class AddTextScreen extends StatefulWidget {
  final NlExecutor executor;
  final MealsDao dao;

  /// For the AI consent before the text leaves the phone (with today's
  /// date only: describeMeal sends no other meals). Required, so a call site cannot drop the question
  /// silently (a merge keeping another branch's constructor call fails to
  /// compile instead); tests that are about something else pass a
  /// FakeSettings, which allows every recipient.
  final SettingsStore settings;
  const AddTextScreen(
      {super.key,
      required this.executor,
      required this.dao,
      required this.settings});

  @override
  State<AddTextScreen> createState() => _AddTextScreenState();
}

class _AddTextScreenState extends State<AddTextScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;
  bool _askingConsent = false;
  String? _error;

  /// On the error note, to scroll it into view (A15).
  final GlobalKey _errorKey = GlobalKey();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The error is inserted where the button was, which with the keyboard
  /// up (and more so at large text) is under the keyboard: only its first
  /// words showed (A15). Scroll its top into view; the scroll clamps, so a
  /// short error on a page that fits moves nothing. Focus stays put — the
  /// fix is often to edit the text.
  void _revealError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _errorKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(target,
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.curve);
    });
  }

  /// Describe → PREVIEW → save. The analysis opens in the meal editor
  /// instead of being written straight to the log: a text estimate is the
  /// model's guess about a meal it never saw, so the numbers deserve a look
  /// before they enter the day's totals (and the editor already owns all the
  /// validation).
  Future<void> _describe() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || _askingConsent) return;
    // App Store 5.1.2(i): the description (and today's date — describeMeal
    // sends no other meals) goes to the AI — permission for this recipient
    // first.
    _askingConsent = true;
    final allowed = await ensureAiConsent(context, widget.settings);
    _askingConsent = false;
    if (!allowed || !mounted || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await widget.executor.describeMeal(text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!outcome.ok) {
      setState(() => _error = outcome.error);
      _revealError();
      return;
    }
    final warning = outcome.warning;
    if (warning != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(warning)));
    }
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => MealEditorScreen(
        dao: widget.dao,
        initialAnalysis: outcome.analysis,
        newMealSource: MealSource.manualText, // spec §4.6 parity
      ),
    ));
    if (saved == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.describeTitle)),
      // SCROLLABLE: the field is autofocused (keyboard up on entry) and the
      // inline messages can run several lines — the quota-pause refusal is
      // four paragraphs. In a fixed Column that pushed the primary button
      // off-screen, where it is not even hit-testable (measured at 390x844
      // and smaller by the review probes).
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(AppSpace.gutter, _topInset(context),
            AppSpace.gutter, AppSpace.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('addTextField'),
              controller: _controller,
              maxLines: 4,
              autofocus: true,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                labelText: context.l10n.describeLabel,
                hintText: context.l10n.describeHint,
              ),
            ),
            const SizedBox(height: AppSpace.s8),
            Text(
              context.l10n.describeHelp,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: context.colors.secondaryLabel),
            ),
            if (error != null) ...[
              const SizedBox(height: AppSpace.s12),
              ReplyNote(
                key: _errorKey,
                message: error,
                textKey: const Key('addTextError'),
              ),
            ],
            const SizedBox(height: AppSpace.s16),
            FilledButton.icon(
              key: const Key('addTextSend'),
              onPressed: _sending ? null : _describe,
              icon: _sending
                  ? const SmallSpinner()
                  : const Icon(Icons.auto_awesome),
              label: Text(_sending
                  ? context.l10n.describeEstimating
                  : context.l10n.describeEstimate),
            ),
          ],
        ),
      ),
    );
  }
}
