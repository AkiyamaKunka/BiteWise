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
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../core/coerce.dart' show normalizeImageHash, safeNumber;
import '../../core/contracts.dart';
import '../../core/leftover_logic.dart';
import '../../services/photo/photo_hash.dart' show originalBytesMd5;
import '../format.dart';
import '../l10n.dart';
import '../services.dart';
import '../widgets/grouped.dart';

class LeftoverScreen extends StatefulWidget {
  const LeftoverScreen({super.key, required this.services});
  final UiServices services;

  @override
  State<LeftoverScreen> createState() => _LeftoverScreenState();
}

class _LeftoverScreenState extends State<LeftoverScreen> {
  List<Meal> _candidates = const [];
  Meal? _selected;
  bool _loading = true;
  bool _analyzing = false;
  bool _permissionDenied = false;
  Future<List<RecentAsset>>? _assets;
  final Map<String, Future<Uint8List?>> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final today = isoDate(now);
    final yesterday = isoDate(now.subtract(const Duration(days: 1)));
    final meals = await widget.services.dao.mealsBetween(yesterday, today);
    if (!mounted) return;
    // Newest first: leftovers are almost always from the LAST meal.
    final food = byMealClock(meals.where(isFoodMeal)).reversed.toList();
    setState(() {
      _candidates = food;
      _loading = false;
    });
  }

  Future<List<RecentAsset>> _loadAssets() async {
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
    setState(() {
      _selected = m;
      _assets ??= _loadAssets();
    });
  }

  /// Synchronous re-entry guard: [_analyzing] drives the SPINNER and is
  /// cleared before the confirm dialog, so it cannot also police taps —
  /// two taps in the dialog-open gap stacked two estimates and applied an
  /// unseen one (pressure-test find).
  bool _busy = false;

  Future<void> _pickPhoto(RecentAsset asset) async {
    if (_busy) return;
    final meal = _selected;
    if (meal == null) return;
    _busy = true;
    setState(() => _analyzing = true);
    final services = widget.services;
    final l = context.l10n;
    try {
      final photo = await services.picker.loadOriginal(asset);
      if (!mounted) return;
      if (photo == null) {
        _snack(l.leftoverFailed);
        return;
      }
      final compact = compactOriginalAnalysis(meal.analysis);
      final reply =
          await services.analyzer.leftoverIntent(photo.bytes, compact);
      if (!mounted) return;
      if (reply == null) {
        _snack(l.leftoverFailed);
        return;
      }
      final hash = normalizeImageHash(originalBytesMd5(photo.bytes));
      final result = applyLeftover(meal.analysis, reply,
          leftoverPhotoMd5: hash,
          appliedAtIso: DateTime.now().toIso8601String());
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
          builder: (ctx) => AlertDialog(
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
      await _confirmAndApply(meal, hash, result);
    } finally {
      _busy = false;
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _confirmAndApply(
      Meal meal, String hash, LeftoverResult result) async {
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
            isoDate(now.subtract(const Duration(days: 30))), isoDate(now));
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
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.leftoverResultTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(mealDescription(meal.analysis),
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
              Text(
                  ctx.l10n
                      .leftoverDupRemoved(formatKcal(duplicateKcal)),
                  key: const Key('leftoverDupLine'),
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.tertiary)),
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
    // (pressure-test find).
    final stillThere = (await services.dao
            .mealsBetween(meal.date, meal.date))
        .any((m) => m.id == meal.id);
    if (!mounted) return;
    if (!stillThere) {
      _snack(context.l10n.leftoverFailed);
      return;
    }

    await services.dao.updateMealAnalysis(meal.id, result.adjusted);
    if (duplicateId != null) {
      // Removes the double-count AND tombstones the photo's ledger row so
      // the backfill scan can never resurrect it (deleteMeal contract).
      await services.dao.deleteMeal(duplicateId);
    } else if (hash.isNotEmpty && status == null) {
      // ONLY when the ledger has never seen this photo. Marking an
      // existing row 'skipped' rewrote the SELECTED meal's own saved row
      // (severing meal_id) when the user re-picked its before-photo, and
      // stomped a live 'processing' reservation out from under the
      // watcher (pressure-test finds).
      await services.dao.markPhotoHash(hash, IngestionStatus.skipped);
    }
    if (!mounted) return;
    _snack(context.l10n.leftoverApplied);
    // pop THIS route by name, never 'whatever is topmost'.
    Navigator.of(context).pop(true);
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
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_selected == null)
          _mealPicker(theme, l)
        else
          _photoPicker(theme, l),
        if (_analyzing)
          Container(
            color: theme.colorScheme.surface.withValues(alpha: 0.7),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(l.analyzing),
                ],
              ),
            ),
          ),
      ]),
    );
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
                title: mealDescription(m.analysis),
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
    return Column(children: [
      Padding(
        // GroupedSection insets itself (see _mealPicker).
        padding: const EdgeInsets.only(top: 8),
        child: GroupedSection(
          children: [
            GroupedRow(
              key: const Key('leftoverChosenMeal'),
              title: mealDescription(meal.analysis),
              value: '~${l.kcalAmount(formatKcal(safeCal(meal)))}',
              trailing: TextButton(
                key: const Key('leftoverChangeMeal'),
                onPressed: () => setState(() => _selected = null),
                child: Text(l.leftoverChangeMeal),
              ),
              showChevron: false,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 12, 32, 4),
        child: Text(l.leftoverPickPhoto,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
      Expanded(
        child: FutureBuilder<List<RecentAsset>>(
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
            if (assets.isEmpty) {
              return Center(child: Text(l.addNoPhotos));
            }
            return GridView.builder(
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
          },
        ),
      ),
    ]);
  }
}

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
    return InkWell(
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
    );
  }
}
