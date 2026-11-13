/// Leftover deduction flow (user feature 2026-08-04): photograph what you
/// DIDN'T finish, and the original meal's calories shrink to what you ate.
///
/// Two steps on one screen — pick the meal (today/yesterday), pick the
/// leftover photo — then the model estimates per-item remaining fractions
/// against the original analysis (core/leftover_logic.dart owns all math).
///
/// The WATCHER COLLISION is handled head-on: the leftover photo usually
/// lands in the camera roll, where the watcher may have already logged it
/// as a brand-new meal (the double-count this feature exists to kill).
/// If the photo's hash maps to a saved meal, the confirm step deletes
/// that duplicate in the same breath as applying the deduction; if the
/// watcher hasn't seen it yet, the hash is marked 'skipped' so it never
/// will.
///
/// Write safety (design R6a): the selected meal is held in the
/// [MealInUseRegistry] from the moment it is picked, so the restaurant
/// assist leaves it alone; and the deduction is re-based on the meal as
/// stored when the user confirms (the same model fractions) and written
/// compare-and-set, so it always cuts from the meal as it is — a deduction
/// planned on numbers that changed meanwhile is never written over them.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../core/coerce.dart'
    show addCalendarDays, normalizeImageHash, safeNumber;
import '../../core/contracts.dart';
import '../../core/leftover_logic.dart';
import '../../services/photo/photo_hash.dart' show originalBytesMd5;
import '../../services/photo/system_photo_picker.dart';
import '../ai_consent.dart';
import '../format.dart';
import '../l10n.dart';
import '../large_text.dart';
import '../meal_in_use.dart';
import '../services.dart';
import '../theme/app_dialog.dart';
import '../theme/tokens.dart';
import '../widgets/grouped.dart';
import '../widgets/states.dart';

class LeftoverScreen extends StatefulWidget {
  const LeftoverScreen({super.key, required this.services, this.systemPicker});
  final UiServices services;

  /// Android's system Photo Picker, as on AddPhotoScreen: without full
  /// photo access the photo step never asks for the library — it asks for
  /// the AI consent and opens this picker for one photo. With full access
  /// the grid stays, plus a row that opens the picker. Null on iOS.
  final SystemPhotoPicker? systemPicker;

  @override
  State<LeftoverScreen> createState() => _LeftoverScreenState();
}

class _LeftoverScreenState extends State<LeftoverScreen> {
  List<Meal> _candidates = const [];
  Meal? _selected;
  bool _loading = true;

  /// The last read of the meals failed: the screen says so and offers
  /// Retry. It was a spinner for good (review 171).
  bool _loadFailed = false;
  bool _analyzing = false;
  bool _permissionDenied = false;

  /// Android without full access: the photo step is the system picker.
  bool _pickerOnly = false;

  /// Android with full access: the grid plus a row that opens the picker.
  bool _pickerRow = false;

  /// The picker could not open on this phone.
  bool _pickerUnavailable = false;
  Future<List<RecentAsset>>? _assets;
  final Map<String, Future<Uint8List?>> _thumbs = {};

  /// The selected meal's hold (design R6a), from the pick until the user
  /// changes the meal or leaves.
  MealInUseHold? _hold;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hold?.release();
    super.dispose();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final today = isoDate(now);
    // Yesterday as a CALENDAR day: 24 hours back is still today at 23:xx on
    // the day DST ends (yesterday's meals were not offered for that hour),
    // and two days back at 00:xx on the day after it starts.
    final yesterday = isoDate(addCalendarDays(now, -1));
    try {
      final meals = await widget.services.dao.mealsBetween(yesterday, today);
      if (!mounted) return;
      // Newest first: leftovers are almost always from the LAST meal.
      final food = byMealClock(meals.where(isFoodMeal)).reversed.toList();
      setState(() {
        _candidates = food;
        _loading = false;
      });
    } catch (e) {
      // The raw error is for the log; the screen says one sentence and
      // offers Retry, as Today and History do.
      debugPrint('Leftovers: load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _retryLoad() {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    _load();
  }

  Future<List<RecentAsset>> _loadAssets() async {
    final system = widget.systemPicker;
    if (system == null) return _loadGrid();
    // Play's photo policy: full access is read, never asked for (the Play
    // build declares no photo permission; a request was a silent denial
    // and the "isn't allowed" dead end).
    final full = await system.hasBroadAccess();
    if (!mounted) return const [];
    if (full) {
      _pickerRow = true;
      return widget.services.picker.recentAssets();
    }
    _pickerOnly = true;
    _openPickerAfterFrame();
    return const [];
  }

  /// Opens the picker once the photo step is on screen (the consent
  /// dialog needs the route).
  void _openPickerAfterFrame() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted && _selected != null) _pickPhoto(null);
      })
      ..ensureVisualUpdate();
  }

  Future<List<RecentAsset>> _loadGrid() async {
    final granted = await widget.services.requestPhotoPermission();
    if (!mounted) return const [];
    if (!granted) {
      setState(() => _permissionDenied = true);
      return const [];
    }
    return widget.services.picker.recentAssets();
  }

  Future<Uint8List?> _thumbFor(String assetId) => _thumbs.putIfAbsent(
      assetId, () => widget.services.picker.thumbnail(assetId));

  void _selectMeal(Meal m) {
    _hold?.release();
    _hold = widget.services.mealInUse?.acquire(m.id);
    // The picker is the photo step: it opens with each meal chosen (the
    // first choice opens it from _loadAssets, once access is known).
    final reopen = _pickerOnly && _assets != null;
    setState(() {
      _selected = m;
      _assets ??= _loadAssets();
    });
    if (reopen) _openPickerAfterFrame();
  }

  void _clearSelection() {
    // Not while a photo is estimated against this meal: its hold lasts
    // until the result, and the confirm is for the meal shown.
    if (_busy) return;
    _hold?.release();
    _hold = null;
    setState(() => _selected = null);
  }

  /// Synchronous re-entry guard: [_analyzing] drives the SPINNER and is
  /// cleared before the confirm dialog, so it cannot also police taps —
  /// two taps in the dialog-open gap stacked two estimates and applied an
  /// unseen one (pressure-test find).
  bool _busy = false;

  /// [asset] from the grid, or null: the system picker, after the consent
  /// (Android).
  Future<void> _pickPhoto(RecentAsset? asset) async {
    if (_busy) return;
    final meal = _selected;
    if (meal == null) return;
    // No key, or the quota pause: nothing can be estimated, and "couldn't
    // estimate the leftovers from that photo" sent the user trying other
    // photos. Say which, before any photo is read (run 7, B7).
    final settings = widget.services.settings;
    if (!settings.canAnalyze) {
      final l = context.l10n;
      _snack(settings.isQuotaPaused
          ? l.leftoverQuotaPaused
          : settings.provider == 'server'
              ? l.errNoServerKey
              : l.errNoApiKey);
      return;
    }
    _busy = true;
    // App Store 5.1.2(i): the photo and this meal go to the AI — permission
    // for this recipient before the photo's bytes are read.
    if (!await ensureAiConsent(context, widget.services.settings) ||
        !mounted) {
      _busy = false;
      return;
    }
    final services = widget.services;
    final l = context.l10n;
    try {
      final IntakePhoto? photo;
      if (asset == null) {
        // The spinner only once a photo is chosen: the picker is its own
        // screen, and a cancel analyzed nothing.
        photo = await _systemPick();
        if (photo == null || !mounted) return;
        setState(() => _analyzing = true);
      } else {
        setState(() => _analyzing = true);
        photo = await services.picker.loadOriginal(asset);
        if (!mounted) return;
        if (photo == null) {
          // Nothing was estimated: the add flow's words for the same photo.
          _snack(l.addPhotoUnreadable);
          return;
        }
      }
      final compact = compactOriginalAnalysis(meal.analysis);
      final reply =
          await services.analyzer.leftoverIntent(photo.bytes, compact);
      if (!mounted) return;
      if (reply == null) {
        // leftoverIntent gives no reason, but a call that used up the daily
        // quota armed the pause (Gemini): say that, not "from that photo",
        // which sent the user trying other photos (review 171).
        _snack(services.settings.isQuotaPaused
            ? l.leftoverQuotaPaused
            : l.leftoverFailed);
        return;
      }
      final hash = normalizeImageHash(originalBytesMd5(photo.bytes));
      final appliedAt = DateTime.now().toIso8601String();
      final result = applyLeftover(meal.analysis, reply,
          leftoverPhotoMd5: hash, appliedAtIso: appliedAt);
      if (!mounted) return;
      if (result == null) {
        _snack(l.leftoverFailed);
        return;
      }
      // The estimation is done — the spinner must stop BEFORE any dialog
      // (an animating overlay behind a dialog never settles).
      setState(() => _analyzing = false);
      if (!result.sameMeal) {
        final useAnyway = await showDialog<bool>(
          context: context,
          builder: (ctx) => appAlertDialog(
            title: Text(ctx.l10n.leftoverNotSame),
            content: Text(result.note ?? ''),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(ctx.l10n.cancel)),
              FilledButton(
                  key: const Key('leftoverUseAnyway'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(ctx.l10n.leftoverUseAnyway)),
            ],
          ),
        );
        if (useAnyway != true || !mounted) return;
      }
      await _confirmAndApply(meal, hash, result,
          reply: reply, appliedAt: appliedAt);
    } catch (e) {
      // A read or write that threw said nothing, even with the deduction
      // written and the duplicate still there. Picking the photo again
      // finishes it: the deduction is re-based, never applied twice. The
      // log gets the error's type only: sqflite's text carries the
      // statement's arguments, here the meal's analysis.
      debugPrint('Leftovers: deduction failed (${e.runtimeType})');
      _snack(l.leftoverSaveFailed);
    } finally {
      _busy = false;
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _confirmAndApply(Meal meal, String hash, LeftoverResult result,
      {required Map<String, dynamic> reply, required String appliedAt}) async {
    final services = widget.services;
    // The watcher-collision check: did this leftover photo already become
    // a meal of its own?
    int? duplicateId;
    num duplicateKcal = 0;
    // The photo's existing ledger state decides what we may touch later.
    final status = hash.isEmpty ? null : await services.dao.photoStatus(hash);
    if (status != null) {
      final dupId = status.mealId;
      if (status.status == IngestionStatus.saved &&
          dupId != null &&
          dupId != meal.id) {
        duplicateId = dupId;
        // A generous window: a duplicate can be dated BEFORE the selected
        // meal (clock/EXIF skew, near-midnight capture, an import), and a
        // narrow lookup showed '0 kcal' while deleting a real meal
        // (pressure-test find).
        final now = DateTime.now();
        final rows = await services.dao.mealsBetween(
            isoDate(addCalendarDays(now, -30)), isoDate(now));
        for (final m in rows) {
          if (m.id == dupId) {
            duplicateKcal = safeCal(m);
            break;
          }
        }
      }
    }
    if (!mounted) return;

    final base = leftoverBase(meal.analysis);
    final baseKcal = safeNumber(base['total_calories']).round();
    final newKcal = safeNumber(result.adjusted['total_calories']).round();
    final pct = (result.eatenFraction * 100).round();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => appAlertDialog(
        title: Text(ctx.l10n.leftoverResultTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                mealDescription(meal.analysis,
                    fallback: ctx.l10n.nlUnnamedMeal),
                style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
                ctx.l10n.leftoverResultLine(
                    '$pct', '${baseKcal - newKcal}', '$newKcal'),
                key: const Key('leftoverResultLine')),
            if (result.note != null && result.note!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(result.note!,
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ],
            if (duplicateId != null) ...[
              const SizedBox(height: 8),
              // A meal is deleted with this Save: the danger colour, as
              // the chat's delete warning. The indigo (tertiary) it had is
              // 4.05:1 on the dark dialog, under the 4.5:1 text needs.
              Text(
                  ctx.l10n
                      .leftoverDupRemoved(formatKcal(duplicateKcal)),
                  key: const Key('leftoverDupLine'),
                  style: TextStyle(color: ctx.colors.danger)),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('leftoverConfirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l10n.save)),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    // The meal may have been deleted during the model round-trip: a
    // no-op UPDATE reported success and still burned the photo hash
    // (pressure-test find). Nothing else is touched unless the deduction
    // itself landed.
    final written = await _writeDeduction(meal.id, reply,
        hash: hash, appliedAt: appliedAt);
    if (written != _Deduction.written) {
      if (!mounted) return;
      _snack(written == _Deduction.changed
          ? context.l10n.leftoverConflict
          : context.l10n.leftoverFailed);
      return;
    }
    if (duplicateId != null) {
      // Removes the double-count AND tombstones the photo's ledger row so
      // the backfill scan can never resurrect it (deleteMeal contract).
      await services.dao.deleteMeal(duplicateId);
    } else if (hash.isNotEmpty &&
        (status == null || status.status == IngestionStatus.failed)) {
      // ONLY when the ledger has never seen this photo, or saw it fail.
      // Marking an existing row 'skipped' rewrote the SELECTED meal's own
      // saved row (severing meal_id) when the user re-picked its
      // before-photo, and stomped a live 'processing' reservation out from
      // under the watcher (pressure-test finds). A 'failed' row has
      // neither: it is what an unsure automatic leftover verdict leaves
      // behind, with "Use Leftovers" as the repair — left 'failed', Photo
      // Coverage kept offering Retry on the photo just deducted.
      await services.dao.markPhotoHash(hash, IngestionStatus.skipped);
    }
    if (!mounted) return;
    _snack(context.l10n.leftoverApplied);
    // pop THIS route by name, never 'whatever is topmost'.
    Navigator.of(context).pop(true);
  }

  /// The deduction, compare-and-set (design R6a): the model's fractions
  /// applied to the meal as stored NOW, written only while it still holds
  /// exactly that text. A meal that changes between the read and the write
  /// gets one more re-based try; [_Deduction.changed] after a second miss,
  /// [_Deduction.gone] for a meal deleted meanwhile (or one the reply no
  /// longer fits).
  /// One photo from the system picker, or null (cancelled, unreadable or
  /// unavailable, each said or shown here).
  Future<IntakePhoto?> _systemPick() async {
    final system = widget.systemPicker;
    if (system == null) return null;
    final pick = await system.pick(max: 1);
    if (!mounted) return null;
    switch (pick.status) {
      case SystemPickStatus.missing:
        // A build without the native picker: the grid flow as before.
        setState(() {
          _pickerOnly = false;
          _pickerRow = false;
          _assets = _loadGrid();
        });
        return null;
      case SystemPickStatus.unavailable:
        // No library request here: on the Play build it could only fail.
        setState(() => _pickerUnavailable = true);
        return null;
      case SystemPickStatus.cancelled:
      case SystemPickStatus.busy:
        return null;
      case SystemPickStatus.ok:
        break;
    }
    if (pick.photos.isEmpty) {
      if (pick.tooBig + pick.failed > 0) {
        _snack(context.l10n.addPhotoUnreadable);
      }
      return null;
    }
    return pick.photos.first;
  }

  /// "Choose from all photos…".
  Widget _pickerButton(AppLocalizations l) => FilledButton.tonalIcon(
        key: const Key('leftoverChooseAllPhotos'),
        onPressed: () => _pickPhoto(null),
        icon: const Icon(Icons.photo_library_outlined),
        label: Text(l.addChooseAllPhotos),
      );

  /// The photo step without the grid: what the picker is for and its
  /// button, or why it cannot open.
  Widget _pickerStep(AppLocalizations l) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _pickerUnavailable
                ? [
                    Text(l.addPickerUnavailable,
                        key: const Key('leftoverPickerUnavailable'),
                        textAlign: TextAlign.center),
                  ]
                : [
                    Text(l.addPickerNote,
                        key: const Key('leftoverPickerNote'),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    _pickerButton(l),
                  ],
          ),
        ),
      );

  Future<_Deduction> _writeDeduction(int mealId, Map<String, dynamic> reply,
      {required String hash, required String appliedAt}) async {
    final dao = widget.services.dao;
    for (var attempt = 0; attempt < 2; attempt++) {
      final snap = await dao.mealSnapshot(mealId);
      if (snap == null) return _Deduction.gone;
      final rebased = applyLeftover(snap.meal.analysis, reply,
          leftoverPhotoMd5: hash, appliedAtIso: appliedAt);
      if (rebased == null) return _Deduction.gone;
      // corrected=1, as every deduction (spec §2.4).
      if (await dao.updateMealAnalysisIfUnchanged(mealId,
          expectedRaw: snap.rawAnalysis, analysis: rebased.adjusted)) {
        return _Deduction.written;
      }
    }
    return _Deduction.changed;
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  num safeCal(Meal m) => safeNumber(m.analysis['total_calories']);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.leftoverTitle)),
      body: Stack(children: [
        // The scrim stops a finger, not a screen reader: while a photo is
        // analyzed the step is out of its reach too ('Change' under the
        // spinner let go of the meal mid-estimate; review 171).
        ExcludeSemantics(excluding: _analyzing, child: _step(theme, l)),
        if (_analyzing)
          // The shared overlay: its label is a live region, so the round
          // trip is not silent to a screen reader until the result.
          AnalyzingOverlay(label: l.analyzing),
      ]),
    );
  }

  Widget _step(ThemeData theme, AppLocalizations l) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadFailed) {
      return ListView(children: [
        InlineError(
          key: const Key('leftoverLoadError'),
          message: l.leftoverLoadFailed,
          onRetry: _retryLoad,
          retryKey: const Key('leftoverRetry'),
        ),
      ]);
    }
    return _selected == null ? _mealPicker(theme, l) : _photoPicker(theme, l);
  }

  Widget _mealPicker(ThemeData theme, dynamic l) {
    if (_candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(l.leftoverNoMeals,
              key: const Key('leftoverNoMeals'),
              textAlign: TextAlign.center),
        ),
      );
    }
    // No horizontal padding: GroupedSection already insets 16 (ONE
    // gutter); an extra 16 a side here shrank every cell to 326 px.
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        GroupedSection(
          header: l.leftoverPickMeal,
          separatorInset: 16, // no badges: label-aligned hairlines
          children: [
            for (final m in _candidates)
              _MealPickRow(
                key: Key('leftoverMeal-${m.id}'),
                title: mealDescription(m.analysis,
                    fallback: l.nlUnnamedMeal),
                detail: _pickDetail(m),
                onTap: () => _selectMeal(m),
              ),
          ],
        ),
      ],
    );
  }

  /// A picker row's second line: day + clock + calories. The calories —
  /// the number that tells two 午餐 apart — stay visible, but BELOW the
  /// description: one GroupedRow line held all three and left the
  /// description, the thing that names the meal, 20–90 px (0 px and an
  /// overflow at the largest English text size; loop finds 2026-10-07).
  /// The picker only ever holds today/yesterday.
  String _pickDetail(Meal m) {
    final l = context.l10n;
    final clock = context.clock(m.time);
    final day = m.date == isoDate(DateTime.now())
        ? l.timeToday(clock)
        : l.timeYesterday(clock);
    return '$day · ~${l.kcalAmount(formatKcal(safeCal(m)))}';
  }

  Widget _photoPicker(ThemeData theme, dynamic l) {
    final meal = _selected!;
    final large = isLargeText(context);
    final changeMeal = TextButton(
      key: const Key('leftoverChangeMeal'),
      onPressed: _clearSelection,
      child: Text(l.leftoverChangeMeal),
    );
    final header = <Widget>[
      Padding(
        // GroupedSection insets itself (see _mealPicker).
        padding: const EdgeInsets.only(top: 8),
        child: GroupedSection(
          children: [
            GroupedRow(
              key: const Key('leftoverChosenMeal'),
              title: mealDescription(meal.analysis,
                  fallback: l.nlUnnamedMeal),
              value: '~${l.kcalAmount(formatKcal(safeCal(meal)))}',
              // At accessibility sizes the button squeezed the meal's
              // own row; it goes under the section there instead.
              trailing: large ? null : changeMeal,
              showChevron: false,
            ),
          ],
        ),
      ),
      if (large)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: changeMeal),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 12, 32, 4),
        child: Text(l.leftoverPickPhoto,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    ];
    final photos = FutureBuilder<List<RecentAsset>>(
          future: _assets,
          builder: (context, snap) {
            // A denial is NOT an empty camera roll: 'No recent photos
            // found.' here was the same permanent dead end AddPhotoScreen
            // already fixed (once the OS stops re-prompting, the request
            // above is a silent no-op) — say what is wrong and offer the
            // only way back (loop find 2026-10-07).
            if (_permissionDenied) {
              final open = widget.services.openSystemSettings;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l.photoPermissionDenied,
                        key: const Key('leftoverPhotoPermissionDenied'),
                        textAlign: TextAlign.center,
                      ),
                      if (open != null) ...[
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          key: const Key('leftoverOpenSystemSettings'),
                          onPressed: () => open(),
                          child: Text(l.openSystemSettings),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final assets = snap.data!;
            if (_pickerOnly || (_pickerRow && assets.isEmpty)) {
              return _pickerStep(l);
            }
            if (assets.isEmpty) {
              return Center(child: Text(l.addNoPhotos));
            }
            final grid = GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
              itemCount: assets.length,
              itemBuilder: (context, i) {
                final asset = assets[i];
                return InkWell(
                  key: Key('leftoverPhoto-${asset.id}'),
                  onTap: () => _pickPhoto(asset),
                  // Same screen-reader label as the add grid: position +
                  // shot time, inside the InkWell so its tap stays on the
                  // node.
                  child: Semantics(
                    image: true,
                    label: context.l10n.photoCellLabel(i + 1, assets.length,
                        context.photoTakenAt(asset.createdAt)),
                    child: ExcludeSemantics(
                      child: FutureBuilder<Uint8List?>(
                        future: _thumbFor(asset.id),
                        builder: (context, thumb) => thumb.data == null
                            ? Container(
                                color:
                                    theme.colorScheme.surfaceContainerHighest)
                            : Image.memory(thumb.data!,
                                fit: BoxFit.cover,
                                // A corrupt thumbnail must stay a tappable
                                // tile, never an error spray.
                                errorBuilder: (_, _, _) => Container(
                                    color: theme
                                        .colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.image_outlined))),
                      ),
                    ),
                  ),
                );
              },
            );
            if (!_pickerRow) return grid;
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _pickerButton(l)),
              ),
              Expanded(child: grid),
            ]);
          },
        );
    // At accessibility text sizes the chosen meal and the heading can take
    // the whole height, which left the grid none and no photo to pick
    // (review 1.7.0). There the step scrolls, and the grid keeps a full
    // screen of its own below them.
    return LayoutBuilder(
      builder: (context, box) => large
          ? SingleChildScrollView(
              key: const Key('leftoverPhotoStepScroll'),
              child: Column(children: [
                ...header,
                SizedBox(height: box.maxHeight, child: photos),
              ]),
            )
          : Column(children: [...header, Expanded(child: photos)]),
    );
  }
}

/// How [_LeftoverScreenState._writeDeduction] ended.
enum _Deduction { written, gone, changed }

/// One meal-picker row: the description on its own line(s) at the FULL
/// cell width, day · clock · calories on a quiet line below. Same cell
/// geometry and selection haptic as a GroupedRow; no chevron — a picker
/// row is self-evidently the thing to tap. Grows with the text size
/// instead of overflowing.
class _MealPickRow extends StatelessWidget {
  const _MealPickRow({
    super.key,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A bare InkWell only adds a tap action: VoiceOver read the row as
    // text, never 'button' (the A11 class GroupedRow and GroupedCard
    // fixed), and with one meal it took the section header into the
    // row's node. Its own node, read as a button.
    return Semantics(
      button: true,
      container: true,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
