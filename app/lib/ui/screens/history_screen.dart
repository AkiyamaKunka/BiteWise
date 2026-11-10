/// History: 30-day per-day calorie totals (spec §5.3 — inclusive window
/// [today−29, today], days sorted descending, average over days WITH data).
library;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../meal_in_use.dart';
import '../meal_thumbs.dart';
import '../refresh_signal.dart';
import '../restaurant_assist_controls.dart';
import '../services.dart' show SettingsStore;
import '../l10n.dart';
import '../large_text.dart';
import '../theme/tokens.dart';
import '../widgets/grouped.dart';
import '../widgets/macro_chart.dart';
import '../widgets/states.dart';
import 'day_detail_screen.dart';

class HistoryScreen extends StatefulWidget {
  final MealsDao dao;
  final int days;
  final MealThumbResolver? thumbs;

  /// Handed to the day's editor (design R6a); null in tests.
  final MealInUseRegistry? mealInUse;

  /// Handed to the day's editor for its restaurant source card (design
  /// R7b), with the assist's mode and consent; null in tests.
  final RestaurantAssistControls? restaurantAssist;
  final SettingsStore? settings;
  const HistoryScreen(
      {super.key,
      required this.dao,
      this.days = 30,
      this.thumbs,
      this.mealInUse,
      this.restaurantAssist,
      this.settings});

  @override
  State<HistoryScreen> createState() => HistoryScreenState();
}

/// Public so the shell can trigger [reload] when the tab is (re)selected:
/// this screen lives in an IndexedStack, so initState runs once at app
/// launch — without an external reload it would show launch-time data
/// forever (and the empty state has no RefreshIndicator to recover with).
class HistoryScreenState extends State<HistoryScreen> {
  bool _loading = true;
  String? _error;
  Map<String, num> _perDay = const {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final now = DateTime.now();
    try {
      final meals = await widget.dao.mealsBetween(
        isoDate(now.subtract(Duration(days: widget.days - 1))),
        isoDate(now),
      );
      if (!mounted) return;
      setState(() {
        _perDay = dailyCalorieTotals(meals);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      // The raw error is for the log; the screen shows a sentence.
      debugPrint('History: load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load history: $e';
      });
    }
  }

  /// Day drill-down. Always reloads on return: edits, adds and deletes all
  /// change this list, and a local query is far cheaper than plumbing a
  /// result back through a system back-gesture.
  Future<void> _openDay(String date) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          DayDetailScreen(
              dao: widget.dao,
              date: date,
              thumbs: widget.thumbs,
              mealInUse: widget.mealInUse,
              restaurantAssist: widget.restaurantAssist,
              settings: widget.settings),
    ));
    // Same reason for the signal: today's meals edited from here must
    // reach Today and the iOS OS card, not only this list.
    signalMealsChanged();
    if (mounted) await reload();
  }

  num _maxDayKcal = 0;

  /// Weekday span w600, remainder quiet — same string, richer weight.
  /// Today's label stands where a weekday would, so it takes the weight.
  Widget _dayTitle(BuildContext context, String date, {required bool dimmed}) {
    final colors = context.colors;
    final base =
        Theme.of(context).textTheme.bodyLarge?.copyWith(color: colors.label);
    const strong = TextStyle(fontWeight: FontWeight.w600);
    final text = context.friendlyDay(date);
    if (dimmed) {
      return Text(text, style: base?.copyWith(color: colors.secondaryLabel));
    }
    if (date == isoDate(DateTime.now())) {
      return Text(text, style: base?.merge(strong));
    }
    final comma = text.indexOf(', ');
    if (comma < 0) return Text(text, style: base);
    return Text.rich(TextSpan(style: base, children: [
      TextSpan(text: text.substring(0, comma), style: strong),
      TextSpan(
          text: text.substring(comma),
          style: TextStyle(color: colors.secondaryLabel)),
    ]));
  }

  /// The thin magnitude track under a logged day. The track is
  /// decorative; the accent fill carries the contrast against it (4.57:1
  /// light, 5.62:1 dark). The old note here claimed the track itself
  /// cleared 3:1 against the cell; it measured about 1.7:1 (A13).
  Widget _magnitudeBar(BuildContext context, double frac) {
    final colors = context.colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: ColoredBox(
        color: colors.track,
        child: SizedBox(
          height: 4,
          width: double.infinity,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: frac,
              heightFactor: 1,
              child: ColoredBox(color: colors.accent),
            ),
          ),
        ),
      ),
    );
  }

  /// '~1,585 kcal'. Stacked (large text) it may need two lines: the
  /// break then falls between the number and the unit only — as one Text,
  /// zh broke INSIDE the unit at AX5 ('~1,751 千' / '卡').
  Widget _kcalValue(BuildContext context, num kcal, {required bool stacked}) {
    final style = context.nums.value.copyWith(color: context.colors.label);
    final number = formatKcal(kcal);
    final full = '~${context.l10n.kcalAmount(number)}';
    final at = full.indexOf(number);
    if (!stacked || at < 0) return Text(full, style: style);
    final head = full.substring(0, at + number.length).trim();
    final unit = full.substring(at + number.length).trim();
    return Semantics(
      label: full,
      excludeSemantics: true,
      child: Wrap(
        spacing: MediaQuery.textScalerOf(context).scale(4),
        children: [
          Text(head, style: style),
          if (unit.isNotEmpty) Text(unit, style: style),
        ],
      ),
    );
  }

  /// One day: value + a thin magnitude track beneath it (research: a
  /// number-only list hides the week's shape; MacroFactor/Cronometer put a
  /// visual scale in every row). Gap days stay dimmed text-only.
  ///
  /// At accessibility text sizes the value moves UNDER the date (A3): as
  /// a trailing value it kept its full width, so the date got 11 pt in zh
  /// on an SE ('今/天' one glyph a line, rows 570 pt tall), and a gap
  /// day's 'no meals logged' left the date no width at all.
  Widget _dayRow(BuildContext context, String date) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final l = context.l10n;
    final has = _perDay.containsKey(date);
    final kcal = _perDay[date];
    final frac = (!has || _maxDayKcal <= 0)
        ? 0.0
        : (kcal! / _maxDayKcal).clamp(0.0, 1.0).toDouble();
    final stacked = isLargeText(context);
    final Widget value = has
        ? _kcalValue(context, kcal!, stacked: stacked)
        : Text(l.historyNoMeals,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.secondaryLabel));
    return GroupedRow.custom(
      key: Key('historyDay$date'),
      // Gap rows open the day too — its + FAB is the remedy.
      onTap: () => _openDay(date),
      showChevron: true,
      trailing: stacked ? null : value,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Weekday emphasized, rest quiet (research: the week's rhythm
          // should be scannable). String content unchanged — split, not
          // reworded.
          _dayTitle(context, date, dimmed: !has),
          if (stacked)
            Padding(padding: const EdgeInsets.only(top: 2), child: value),
          if (has)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _magnitudeBar(context, frac),
            ),
        ],
      ),
    );
  }

  Widget _withTitle(List<Widget> slivers, {bool scrollable = true}) {
    return CustomScrollView(
      physics: scrollable
          ? const AlwaysScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      slivers: [
        appLargeTitleBar(context, title: context.l10n.tabHistory),
        ...slivers,
      ],
    );
  }

  /// 'Average: ~1,909 kcal / day' with the number as the headline. The
  /// PLAIN text stays exactly the pinned string (spec §5.3).
  Widget _average(BuildContext context, int avg) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final number = formatKcal(avg);
    final full = context.l10n.historyAverage(number);
    final quiet =
        theme.textTheme.bodySmall?.copyWith(color: colors.secondaryLabel);
    final at = full.indexOf(number);
    if (at < 0) return Text(full, key: const Key('historyAverage'), style: quiet);
    return Text.rich(
      key: const Key('historyAverage'),
      TextSpan(style: quiet, children: [
        TextSpan(text: full.substring(0, at)),
        TextSpan(
            text: number,
            style: context.nums.value.copyWith(color: colors.label)),
        TextSpan(text: full.substring(at + number.length)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_loading) {
      return _withTitle(
          [const SliverFillRemaining(hasScrollBody: false, child: LoadingState())],
          scrollable: false);
    }
    if (_error != null) {
      return _withTitle([
        SliverToBoxAdapter(
          child: InlineError(
              key: const Key('historyError'),
              message: l.historyLoadFailed,
              onRetry: reload,
              retryKey: const Key('historyRetry')),
        ),
      ]);
    }
    if (_perDay.isEmpty) {
      return _withTitle([
        // Empty copy per spec §5.3.
        EmptyState.sliver(
          key: const Key('historyEmpty'),
          icon: Icons.bar_chart_rounded,
          title: l.historyEmpty(widget.days),
        ),
      ]);
    }
    // Interior GAP days are rendered too (dimmed, "no meals logged"):
    // a day the watcher missed used to simply vanish, and spotting it
    // required mentally diffing dates across rows. Leading/trailing empty
    // spans stay collapsed so a new user never sees 29 empty rows. The
    // newest edge extends to TODAY: "nothing logged yet today/yesterday"
    // is exactly the gap worth noticing.
    final logged = _perDay.keys.toList()..sort();
    final today = DateTime.now();
    var end = DateTime(today.year, today.month, today.day);
    // The §5.3 query window ends at today, so logged.last can exceed
    // `end` only through clock skew between reload and this build — the
    // guard keeps the span covering the data even then.
    final newest = DateTime.parse(logged.last);
    if (newest.isAfter(end)) end = newest;
    final dates = <String>[];
    final start = DateTime.parse(logged.first);
    // Day+1 through the CONSTRUCTOR, not Duration(days: 1): a 24h add
    // drifts across DST in locales that have it and could duplicate or
    // skip an isoDate.
    for (var d = start;
        !d.isAfter(end);
        d = DateTime(d.year, d.month, d.day + 1)) {
      dates.add(isoDate(d));
    }
    dates.sort((a, b) => b.compareTo(a));
    // Average over days that have data, int truncation (spec §5.3).
    final sum = _perDay.values.fold<num>(0, (a, b) => a + b);
    final avg = (sum / _perDay.length).truncate();
    _maxDayKcal = _perDay.values
        .fold<num>(0, (a, b) => a > b ? a : b); // row magnitude track scale
    return RefreshIndicator(
      onRefresh: reload,
      child: _withTitle([
        SliverList.list(children: [
          GroupedCard(
            padding: const EdgeInsets.all(AppSpace.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Spec-pinned string + key, as the card's headline.
                _average(context, avg),
                const SizedBox(height: AppSpace.s12),
                // Bars in ascending date order with the average as a
                // dashed reference; tapping a bar opens that day (same
                // target as the rows below). The chart gets the SAME
                // span as the rows, gap days as 0: fed only `_perDay`,
                // five logged days over four weeks became five adjacent
                // bars — a lie of continuity the list right below
                // contradicted. A 0 slot paints nothing (an empty gap)
                // and taps through to that day like its gap row. The
                // dashed line keeps the headline's days-with-data mean
                // (spec §5.3) instead of diluting it over the gaps.
                CalorieTrendChart(
                  dayTotals: {for (final d in dates) d: _perDay[d] ?? 0},
                  average: sum / _perDay.length,
                  onDayTap: (date) => _openDay(date),
                ),
              ],
            ),
          ),
          // Day rows as ONE inset grouped section — the same cells as
          // Settings, one tab away; separators align with the text.
          GroupedSection(
            separatorInset: AppSpace.separatorInset,
            children: [for (final d in dates) _dayRow(context, d)],
          ),
          const SizedBox(height: AppSpace.s32),
        ]),
      ]),
    );
  }
}
