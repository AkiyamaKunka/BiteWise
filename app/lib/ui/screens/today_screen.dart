/// Today: running totals header (spec §5.1), typical-day line, today's meal
/// cards, pull-to-refresh, and the one Meals button (add + fix, spec §4
/// corrections now live in its sheet — the pinned chat bar is gone,
/// 2026-07-31).
library;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../services/garmin_client.dart';
import '../format.dart';
import 'dart:io' show File;
import 'dart:ui' as ui show Image;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n.dart';
import '../widgets/calorie_ring.dart';
import '../widgets/day_report.dart';
import '../widgets/grouped.dart' show GroupedCard, appLargeTitleBar;
import '../widgets/macro_chart.dart' show MacroPalette;
import '../meal_in_use.dart';
import '../meal_thumbs.dart';
import '../refresh_signal.dart';
import '../restaurant_assist_controls.dart';
import '../services.dart' show SettingsStore;
import '../../services/usual/usual_foods.dart';
import '../widgets/usual_chip.dart';
import '../widgets/usual_offer_card.dart'
    show showUsualSnack, showUsualUsedSnack;
import '../widgets/meal_card.dart';
import '../widgets/small_spinner.dart';
import 'meal_editor_screen.dart';
import '../large_text.dart';
import '../theme/tokens.dart';
import '../widgets/states.dart';

class TodayScreen extends StatefulWidget {
  final MealsDao dao;

  /// Photo thumbnails for the cards; null (tests) renders placeholders.
  final MealThumbResolver? thumbs;

  /// Today's Garmin active burn, via the user's server (spec §9). Injected
  /// (null = feature off): Today must not know how the server is reached,
  /// only that a day may have an active-burn number.
  final GarminDailyFetch? garminDaily;

  /// Held while a meal's editor is open (design R6a); null in tests.
  final MealInUseRegistry? mealInUse;

  /// The restaurant assist (design R7b): the cards' 'updated' dot and the
  /// editor's source card. Null (tests) shows neither.
  final RestaurantAssistControls? restaurantAssist;

  /// The assist's mode and consent, for the editor's lookup.
  final SettingsStore? settings;

  /// Usual foods: a chip on a photo meal of today offering the numbers
  /// the user set for a food before (Use / Review), and the editor's card.
  /// Null (tests) shows neither.
  final UsualFoods? usual;

  /// The clock that says which day is today; null is the device's (tests
  /// inject one to cross midnight).
  final DateTime Function()? now;
  const TodayScreen(
      {super.key,
      required this.dao,
      this.thumbs,
      this.garminDaily,
      this.mealInUse,
      this.restaurantAssist,
      this.settings,
      this.usual,
      this.now});

  @override
  State<TodayScreen> createState() => TodayScreenState();
}

class TodayScreenState extends State<TodayScreen> {
  bool _loading = true;
  String? _error;
  List<Meal> _todayMeals = const [];
  Map<String, num> _priorDayTotals = const {};
  GarminDaily? _garmin;

  /// Meals an automatic restaurant lookup changed that were not opened
  /// since (design R7b).
  Set<int> _assistUnseen = const {};

  /// Today's usual-numbers offers by meal id (usual foods §3.4; never
  /// stored), the reply that may still replace them, and the meals whose
  /// Use is being written.
  Map<int, UsualOffer> _usualOffers = const {};
  int _usualGen = 0;
  final Set<int> _usualUsing = {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  DateTime _now() => (widget.now ?? DateTime.now)();

  /// Fire-and-forget: a cosmetic line must never delay the meal list. The
  /// date guard drops a reply that arrives after midnight rolled the day.
  void _refreshGarmin(String today) {
    final fetch = widget.garminDaily;
    if (fetch == null) return;
    fetch(today).then((daily) {
      if (!mounted || isoDate(_now()) != today) return;
      setState(() => _garmin = daily);
    }, onError: (Object _) {});
  }

  Future<void> reload() async {
    final now = _now();
    final today = isoDate(now);
    _refreshGarmin(today);
    try {
      final todayMeals =
          byMealClock(await widget.dao.mealsBetween(today, today));
      final unseen = await _readUnseen();
      // Typical-day window: prior 7 local days EXCLUDING today (spec §5.1).
      final prior = await widget.dao.mealsBetween(
        // Calendar days, matching summaryForDay — a 24 h step goes wrong
        // across a DST change.
        isoDate(DateTime(now.year, now.month, now.day - 7)),
        isoDate(DateTime(now.year, now.month, now.day - 1)),
      );
      if (!mounted) return;
      setState(() {
        _todayMeals = todayMeals;
        _assistUnseen = unseen;
        _priorDayTotals = dailyCalorieTotals(prior);
        _loading = false;
        _error = null;
        // Until the fresh reply: no chip on a meal that is gone or became
        // the user's (corrected) since the offers were worked out.
        _usualOffers = {
          for (final m in todayMeals)
            if (!m.corrected && _usualOffers[m.id] != null)
              m.id: _usualOffers[m.id]!,
        };
      });
      _refreshUsual(todayMeals, today);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load today\'s meals: $e';
      });
    }
  }

  /// Fire-and-forget, like the Garmin line: the list never waits for the
  /// offers, a reply older than the last reload or from before midnight is
  /// dropped, and a failure shows no chip.
  void _refreshUsual(List<Meal> meals, String today) {
    final usual = widget.usual;
    if (usual == null) return;
    final gen = ++_usualGen;
    Future<Map<int, UsualOffer>> offers;
    try {
      offers = usual.offersFor(meals);
    } catch (_) {
      return;
    }
    offers.then((o) {
      if (!mounted || gen != _usualGen || isoDate(_now()) != today) {
        return;
      }
      setState(() => _usualOffers = o);
    }, onError: (Object _) {
      if (!mounted || gen != _usualGen) return;
      setState(() => _usualOffers = const {});
    });
  }

  /// Use on a one-food chip: the user's numbers written through the
  /// compare-and-set (nothing changes without this tap), the meal totals
  /// on the snackbar with Undo. A meal changed since the chip was shown
  /// writes nothing and says so. Past midnight the meal is no longer
  /// today's and is offered nothing: the chip goes with the reload, and
  /// nothing is said (the meal did not change).
  Future<void> _useUsual(Meal meal, UsualOffer offer) async {
    final usual = widget.usual;
    if (usual == null) return;
    if (meal.date != isoDate(_now())) {
      setState(() => _usualOffers = {..._usualOffers}..remove(meal.id));
      await reload();
      return;
    }
    // A second tap that lands after the write but before the frame that
    // removes the chip still carries the used offer: it is not this
    // meal's offer any more, so it does nothing (it used to say "This
    // meal was just updated" over the "Used your usual numbers" line).
    if (!identical(_usualOffers[meal.id], offer)) return;
    if (!_usualUsing.add(meal.id)) return;
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    UsualAcceptResult? result;
    try {
      result = await usual.accept(meal.id, shown: offer);
    } catch (_) {
      result = null;
    } finally {
      _usualUsing.remove(meal.id);
    }
    switch (result?.status) {
      case UsualAcceptStatus.written:
        if (mounted) {
          setState(() => _usualOffers = {..._usualOffers}..remove(meal.id));
        }
        showUsualUsedSnack(messenger, l, usual, result!, onUndone: () {
          if (mounted) reload();
        });
      case UsualAcceptStatus.busy:
        break;
      case UsualAcceptStatus.conflict:
      case UsualAcceptStatus.gone:
      case null:
        showUsualSnack(
            messenger,
            SnackBar(
                key: const Key('usualConflict'),
                content: Text(l.editorSaveConflict)));
    }
    if (mounted) await reload();
  }

  /// The usual-numbers chip for [meal], or null.
  Widget? _usualChip(Meal meal) {
    final offer = _usualOffers[meal.id];
    if (offer == null || widget.usual == null) return null;
    return UsualChip(
      offer: offer,
      busy: _usualUsing.contains(meal.id),
      onUse: () => _useUsual(meal, offer),
      onReview: () => _editMeal(meal),
    );
  }

  /// The 'updated' dots; none when the assist cannot say (never fails
  /// the list).
  Future<Set<int>> _readUnseen() async {
    final read = widget.restaurantAssist?.unseen;
    if (read == null) return const {};
    try {
      return await read();
    } catch (_) {
      return const {};
    }
  }

  /// Tap-through to the editor: correcting a number by hand is often faster
  /// than typing a sentence, and it costs no model call.
  Future<void> _editMeal(Meal meal) async {
    // Opened: its dot goes now (the editor tells the assist too).
    if (_assistUnseen.contains(meal.id)) {
      setState(() => _assistUnseen = {..._assistUnseen}..remove(meal.id));
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MealEditorScreen(
          dao: widget.dao,
          meal: meal,
          inUse: widget.mealInUse,
          assist: widget.restaurantAssist,
          settings: widget.settings,
          usual: widget.usual,
          mealsChanged: mealsChangedSignal,
          now: widget.now),
    ));
    widget.thumbs?.evict(meal.id); // deleted/re-dated: cache must not lie
    // An edit or delete changes the summary the iOS OS card carries; the
    // shell's listener re-arms it (and refreshes History).
    signalMealsChanged();
    if (mounted) await reload();
  }

  @override
  Widget build(BuildContext context) {
    // Today is purely the day's list: the + 记录 button is the shell
    // Scaffold's floatingActionButton (HomeShell, Today tab only), so
    // Material lifts it above snackbars instead of hiding it under them.
    return _body(context);
  }

  /// iOS-style collapsing large title above whatever [child] slivers show.
  Widget _withTitle(BuildContext context, List<Widget> slivers,
      {bool scrollable = true}) {
    return CustomScrollView(
      physics: scrollable
          ? const AlwaysScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      slivers: [
        appLargeTitleBar(
          context,
          title: context.l10n.tabToday,
          actions: [
            // Report-to-my-coach (user request 2026-08-02): the whole day
            // as ONE tall image, straight into the share sheet.
            if (_todayMeals.where(isFoodMeal).isNotEmpty)
              IconButton(
                key: const Key('shareDayButton'),
                icon: _sharing
                    ? const SmallSpinner(size: 18)
                    : const Icon(Icons.ios_share),
                tooltip: context.l10n.shareDayTooltip,
                onPressed: _sharing ? null : _shareDay,
              ),
          ],
        ),
        ...slivers,
      ],
    );
  }

  bool _sharing = false;

  /// Render today as one tall PNG and open the system share sheet.
  Future<void> _shareDay() async {
    setState(() => _sharing = true);
    final theme = Theme.of(context); // captured before any await
    final locale = Localizations.localeOf(context);
    try {
      final today = isoDate(_now());
      final foodMeals = _todayMeals.where(isFoodMeal).toList();
      // Pre-decode every thumbnail so the report paints in one frame.
      final report = <ReportMeal>[];
      for (final meal in foodMeals) {
        ui.Image? thumb;
        if (meal.imageHash.isNotEmpty) {
          thumb = await decodeThumb(await widget.dao.mealThumb(meal.id));
        }
        report.add(ReportMeal(meal: meal, thumb: thumb));
      }
      final png = await renderDayReport(
        date: today,
        meals: report,
        typicalKcal: typicalDayKcal(_priorDayTotals),
        burnKcal: _garmin?.activeCalories ?? 0,
        theme: theme,
        locale: locale,
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/intake_$today.png');
      await file.writeAsBytes(png, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        subject: '${context.l10n.reportTitle} $today',
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.shareDayFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return _withTitle(context,
          [const SliverFillRemaining(child: LoadingState())],
          scrollable: false);
    }
    if (_error != null) {
      return _errorBody(context);
    }
    return _loadedBody(context);
  }

  /// The raw failure as last logged, so a rebuild does not log it again.
  String? _loggedError;

  Widget _errorBody(BuildContext context) {
    // The user reads one translated sentence; the exception text (English,
    // technical) is for the debug log only (L4).
    final raw = _error!;
    if (raw != _loggedError) {
      _loggedError = raw;
      debugPrint(raw);
    }
    return _withTitle(context, [
      // InlineError's own 16-pt padding lines it up with the title.
      SliverToBoxAdapter(
        child: InlineError(
          key: const Key('todayLoadError'),
          message: context.l10n.todayLoadFailed,
          onRetry: reload,
          retryKey: const Key('todayRetry'),
        ),
      ),
    ]);
  }

  Widget _loadedBody(BuildContext context) {
    final foodMeals = _todayMeals.where(isFoodMeal).toList();
    return RefreshIndicator(
      onRefresh: reload,
      child: _withTitle(context, [
        // Room under the last meal for the shell's + 记录 button.
        SliverPadding(
          padding: const EdgeInsets.only(bottom: AppSpace.fabClearance),
          sliver: SliverList.list(children: [
          _totalsHeader(context, foodMeals),
          if (foodMeals.isEmpty)
            // Empty copy per spec §5.1; the hint below is app-only (§9) —
            // the bare sentence was a dead-ish end for a user who just
            // finished setup.
            EmptyState(
              key: const Key('todayEmpty'),
              icon: Icons.restaurant_rounded,
              title: context.l10n.todayEmptyTitle,
              message: context.l10n.todayEmptyHint,
            )
          else
            for (final meal in foodMeals)
              MealCard(
                key: ValueKey('meal${meal.id}'),
                meal: meal,
                onTap: () => _editMeal(meal),
                thumb: widget.thumbs?.thumbFor(meal),
                assistUnseen: _assistUnseen.contains(meal.id),
                usualChip: _usualChip(meal),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _totalsHeader(BuildContext context, List<Meal> foodMeals) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = AppColors.of(context);
    final palette = MacroPalette.of(context);
    final l = context.l10n;
    final totals = todayTotals(foodMeals); // Σ safeNumber, spec §5.1
    final typical = typicalDayKcal(_priorDayTotals);
    final burn = _garmin?.activeCalories ?? 0;
    String? typicalLine;
    if (typical != null) {
      // Context only: what a normal day looks like for you. The old
      // "· ~N kcal headroom / above typical" tail went with the rest of
      // the remaining framing (owner decision 2026-08-06) — this screen
      // reports intake, it does not run a countdown.
      typicalLine = l.typicalDayOnly(formatKcal(typical));
    }
    final footnote = theme.textTheme.bodySmall
        ?.copyWith(color: colors.secondaryLabel);
    // The ring's centre is the ONE hero number (U15): the eaten total used
    // to be printed three times (centre, a 'N kcal' title, the Eaten row).
    // The title line is now the meal count; the Eaten row stays as the
    // result of the arithmetic.
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.mealsToday(totals.meals),
            key: const Key('todayMealCount'),
            style: theme.textTheme.titleMedium?.copyWith(color: colors.label)),
        // MFP's transparent arithmetic — and it RECONCILES: typical + burn
        // frame the arc, eaten IS the ring's centre number. With no
        // typical day yet there is nothing to reconcile, and an Eaten row
        // would only repeat the centre ('0 kcal today' / 'Eaten 0').
        if (typical != null) ...[
          const SizedBox(height: AppSpace.s8),
          ArithmeticRow(
              label: l.rowTypical,
              value: '~${formatKcal(typical)}',
              dot: colors.tertiaryLabel),
          if (burn > 0)
            ArithmeticRow(
                label: l.rowBurn,
                value: '+${formatKcal(burn)}',
                dot: scheme.tertiary),
          // The eaten row is the EMPHASIZED one: it is what the ring's
          // center restates. No remaining row — the owner tracks intake,
          // not a countdown (2026-08-06).
          ArithmeticRow(
              key: const Key('arithmeticResultRow'),
              label: l.rowEaten,
              value: formatKcal(totals.cal.round()),
              dot: colors.accent,
              emphasized: true),
        ],
      ],
    );
    final ring = CalorieRing(
        eatenKcal: totals.cal, typicalKcal: typical, burnKcal: burn);
    // Hero layout (research: MFP arithmetic × Apple ring — see
    // uiux_direction.md): ring answers "how am I doing", the rows beside it
    // show the arithmetic that produced the answer, macro trio beneath. At
    // accessibility sizes the rows beside the ring got a third of the card
    // and broke a number per line (zh stress shot 18): the ring centres on
    // top and the rows take the full width under it.
    final hero = isLargeText(context)
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: ring),
              const SizedBox(height: AppSpace.s16),
              summary,
            ],
          )
        : Row(
            children: [
              ring,
              const SizedBox(width: AppSpace.s16),
              Expanded(child: summary),
            ],
          );
    return GroupedCard(
      key: const Key('todayHero'),
      padding: const EdgeInsets.all(AppSpace.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          hero,
          const SizedBox(height: AppSpace.s16),
          MacroTrio(
            proteinG: totals.protein,
            carbsG: totals.carbs,
            fatG: totals.fat,
            proteinColor: palette.protein,
            carbsColor: palette.carbs,
            fatColor: palette.fat,
          ),
          if (typicalLine != null) ...[
            const SizedBox(height: AppSpace.cardGap),
            Text(typicalLine,
                key: const Key('typicalDayLine'), style: footnote),
          ],
          if (_garmin != null && _garmin!.activeCalories <= 0) ...[
            const SizedBox(height: AppSpace.s4),
            Text(
              l.garminIdleLine,
              key: const Key('garminIdleLine'),
              style: footnote,
            ),
          ],
          if (_garmin != null && _garmin!.activeCalories > 0) ...[
            const SizedBox(height: AppSpace.s4),
            Text(
              _garminLine(context, totals.cal, _garmin!.activeCalories),
              key: const Key('garminBurnLine'),
              style: footnote,
            ),
          ],
        ],
      ),
    );
  }

  /// The Garmin footnote. "net ~N kcal" is intake minus active burn — an
  /// INTAKE figure, so it is only stated while it still is one. On a light
  /// or empty day the burn exceeds what was eaten and the subtraction goes
  /// negative ("净摄入 ~-897 千卡", testing loop 2026-10-07): that is not a
  /// net intake, it is a countdown in disguise, and this screen reports
  /// intake, not a countdown (owner decision 2026-08-06). The line then
  /// states the burn alone — the eaten figure is already the hero above.
  /// Both terms are rounded first so the net reconciles
  /// with the rows as printed; a net of exactly 0 is dropped with the
  /// negatives (no "~0 kcal" noise, same rule as the idle line).
  String _garminLine(BuildContext context, num eaten, double burn) {
    final net = eaten.round() - burn.round();
    return net > 0
        ? context.l10n.garminBurnLine(formatKcal(burn), formatKcal(net))
        : context.l10n.garminBurnOnlyLine(formatKcal(burn));
  }
}
