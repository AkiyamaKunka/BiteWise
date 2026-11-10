/// One day of history: totals with a macro breakdown, every meal on the day
/// (tap to edit, long-press-free — editing is an explicit screen), and a FAB
/// to add a meal by hand to THIS date.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../l10n.dart';
import '../large_text.dart';
import '../meal_in_use.dart';
import '../meal_thumbs.dart';
import '../restaurant_assist_controls.dart';
import '../services.dart' show SettingsStore;
import '../widgets/macro_chart.dart';
import '../widgets/meal_thumb.dart';
import 'meal_editor_screen.dart';
import '../theme/tokens.dart';
import '../widgets/grouped.dart' show GroupedCard;
import '../widgets/meal_parts.dart';
import '../widgets/states.dart';

class DayDetailScreen extends StatefulWidget {
  const DayDetailScreen({
    super.key,
    required this.dao,
    required this.date,
    this.now,
    this.thumbs,
    this.mealInUse,
    this.restaurantAssist,
    this.settings,
  });

  final MealsDao dao;
  final String date; // YYYY-MM-DD
  final DateTime Function()? now;

  /// Photo thumbnails for the rows; null (tests) renders placeholders.
  final MealThumbResolver? thumbs;

  /// Held while a meal's editor is open (design R6a); null in tests.
  final MealInUseRegistry? mealInUse;

  /// The restaurant assist for the editor's source card (design R7b), and
  /// its mode and consent; null in tests.
  final RestaurantAssistControls? restaurantAssist;
  final SettingsStore? settings;

  @override
  State<DayDetailScreen> createState() => _DayDetailScreenState();
}

class _DayDetailScreenState extends State<DayDetailScreen> {
  bool _loading = true;
  String? _error;
  List<Meal> _meals = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Ordered by the meal's own clock: the DAO sorts by ingestion
      // timestamp, which puts a hand-added or re-dated meal last.
      final meals =
          byMealClock(await widget.dao.mealsBetween(widget.date, widget.date));
      if (!mounted) return;
      setState(() {
        _meals = meals;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.l10n.dayLoadFailed('$e');
      });
    }
  }

  Future<void> _openEditor({Meal? meal}) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => MealEditorScreen(
        dao: widget.dao,
        meal: meal,
        initialDate: widget.date,
        now: widget.now,
        inUse: widget.mealInUse,
        assist: widget.restaurantAssist,
        settings: widget.settings,
      ),
    ));
    if (saved == true) {
      // The editor may have deleted the meal (SQLite can reuse a rowid
      // later) or re-dated it; drop any cached thumb for this id.
      if (meal != null) widget.thumbs?.evict(meal.id);
      await _load();
    } else if (meal != null && mounted) {
      // The source card's answers (design R7b) write without a Save.
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = todayTotals(_meals);
    // The caller reloads on ANY return (cheap local query) — no result
    // plumbing, so a system back-gesture behaves like the back button.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.friendlyDay(widget.date,
              now: (widget.now ?? DateTime.now)())),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                              onPressed: _load, child: Text(context.l10n.retry)),
                        ],
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                          AppSpace.gutter,
                          AppSpace.s12,
                          AppSpace.gutter,
                          AppSpace.fabClearance),
                      children: [
                        // The day's total, its meal count and what it was
                        // made of, as one card (the bare headline over a
                        // divider read as loose text on the page).
                        GroupedCard(
                          margin: EdgeInsets.zero,
                          padding: const EdgeInsets.all(AppSpace.cardPadding),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '~${context.l10n.kcalAmount(formatKcal(totals.cal))}',
                                  key: const Key('dayTotalKcal'),
                                  style: AppNumerals.of(context).large.copyWith(
                                      color: AppColors.of(context).label)),
                              Text(context.l10n.reportMeals(totals.meals),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                      color: AppColors.of(context)
                                          .secondaryLabel)),
                              const SizedBox(height: AppSpace.s12),
                              MacroBreakdownBar(
                                proteinG: totals.protein,
                                carbsG: totals.carbs,
                                fatG: totals.fat,
                              ),
                            ],
                          ),
                        ),
                        if (_meals.isEmpty)
                          EmptyState(
                            key: const Key('dayEmpty'),
                            icon: Icons.no_meals_rounded,
                            title: context.l10n.dayEmpty,
                          )
                        else
                          const SizedBox(
                              height: AppSpace.groupGap - AppSpace.cardGap),
                        for (final m in _meals)
                          _MealRow(
                            // Identity key: element state must follow the
                            // MEAL when the list shifts (a delete above
                            // otherwise leaves this row showing its old
                            // neighbour's resolving photo).
                            key: ValueKey('meal${m.id}'),
                            meal: m,
                            thumb: widget.thumbs?.thumbFor(m),
                            onTap: () => _openEditor(meal: m),
                          ),
                      ],
                    ),
                  ),
        floatingActionButton: FloatingActionButton(
          key: const Key('addMealToDay'),
          // A bare '+' read as just 'button' to a screen reader; the
          // tooltip names it (and shows on long-press). Stays the round
          // FAB: the list's bottom padding is sized for it.
          tooltip: context.l10n.dayAddMealTooltip,
          onPressed: () => _openEditor(),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class _MealRow extends StatelessWidget {
  const _MealRow(
      {super.key, required this.meal, required this.onTap, this.thumb});

  final Meal meal;
  final VoidCallback onTap;
  final Future<Uint8List?>? thumb;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final a = meal.analysis;
    final food = isFoodMeal(meal);
    // At large text the clock beside the title took a fixed slice of the
    // row and squeezed a Chinese title to ~2 glyphs a line; it moves under
    // the title so the title gets the whole width next to the thumbnail.
    final clockBelow = isLargeText(context);
    // A GroupedCard, like Today's meal cards: its press highlight clips to
    // the 18-pt corners (the old InkWell's radius-12 ink ran past them)
    // and VoiceOver announces the row as a button (A11).
    return GroupedCard(
      margin: const EdgeInsets.only(top: AppSpace.cardGap),
      padding: const EdgeInsets.all(AppSpace.cardPadding),
      onTap: onTap,
      child: Column(
        key: Key('mealRow${meal.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MealHeader(
            // As on Today's cards: photo meals only (a text meal's grey
            // placeholder read as a failed image load), and two title
            // lines at standard sizes (a long dinner took seven).
            leading: thumb != null && meal.imageHash.isNotEmpty
                ? MealThumbView(thumb: thumb, isPhotoMeal: true)
                : null,
            title: mealDescription(a, fallback: context.l10n.nlUnnamedMeal),
            titleKey: const Key('mealRowTitle'),
            time: context.clock(meal.time),
            timeKey: const Key('mealRowTime'),
            maxTitleLines: 2,
            stacked: clockBelow,
            showChevron: true,
          ),
          const SizedBox(height: AppSpace.s8),
          Wrap(
            spacing: AppSpace.s8,
            runSpacing: AppSpace.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              MealChip(
                  label:
                      '~${context.l10n.kcalAmount(displayTotalCalories(a))}',
                  emphasized: true),
              if (meal.corrected) const CorrectedMark(),
              if (!food)
                Text(context.l10n.notFoodTag,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colors.secondaryLabel)),
            ],
          ),
          if (food) ...[
            const SizedBox(height: AppSpace.s12),
            MacroBreakdownBar(
              proteinG: safeMacro(a, 'total_protein_g'),
              carbsG: safeMacro(a, 'total_carbs_g'),
              fatG: safeMacro(a, 'total_fat_g'),
              // Thinner than the day total's bar above (the 10-pt default),
              // so the header keeps the heavier weight.
              height: 8,
            ),
          ],
        ],
      ),
    );
  }
}
