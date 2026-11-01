/// The Body tab: weight history + girth measurements (waist / chest / hip).
///
/// Weight rides the parity `body_weight` table (spec §7.1 — one canonical
/// weigh-in per day, which the NL executor has been writing all along with
/// no UI to show for it). Measurements are app-only (spec §9): the server
/// tracks weight, not girth.
///
/// Design rules follow the app's chart idiom (macro_chart.dart): hand-drawn
/// CustomPainter, one hue per series, recessive axes, selective labels
/// (min / max / latest), identity never colour-alone. Dates are shown
/// short ('Oct 30' / '10月30日'); storage keeps ISO.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../core/coerce.dart' show isoDate;
import '../../core/contracts.dart';
import '../app_formats.dart';
import '../l10n.dart';
import '../large_text.dart';
import '../meal_edit_logic.dart' show isRealIsoDate;
import '../services.dart' show SettingsStore;
import '../theme/app_dialog.dart';
import '../theme/app_theme.dart' show AppButtonStyles;
import '../theme/tokens.dart';
import '../units.dart';
import '../widgets/grouped.dart';
import '../widgets/pickers.dart';
import '../widgets/states.dart';
import '../widgets/weight_trend_painter.dart';
import 'log_body_sheet.dart';

/// How far back the Log sheet's date picker reaches at least (U18); it
/// reaches further when an older entry exists, so every entry can be
/// opened. The page therefore loads ALL body data up to today, not a
/// window: every day the picker can reach must be loaded, so its prefill
/// guards the full-row measurements upsert, and a back-filled day shows
/// up in History and the chart. (It was a 365-day window; nothing hides
/// that the last entry is old either way. One row per day, and P2 keeps
/// each history row's lookups O(1).)
const int kBodyBackfillYears = 2;

/// The lower bound that loads everything (ISO dates compare as strings).
const String _kAllTime = '0000-01-01';

class BodyScreen extends StatefulWidget {
  const BodyScreen({super.key, required this.dao, this.settings, this.clock});
  final MealsDao dao;

  /// For the units preference; null (tests that predate it) means metric.
  final SettingsStore? settings;

  /// Test seam; defaults to [DateTime.now].
  final DateTime Function()? clock;

  @override
  State<BodyScreen> createState() => BodyScreenState();
}

class BodyScreenState extends State<BodyScreen> {
  List<WeightEntry> _weights = const [];
  List<BodyMeasurements> _measurements = const [];

  /// Every date carrying any data, newest first, and the per-date lookups.
  /// Computed once per reload (P2): a getter rebuilt and re-sorted the
  /// date set about six times per history row, so a year of weigh-ins
  /// cost 2,191 sorts per build. One row per date (UNIQUE per day) makes
  /// the maps equal to the old first-match scans.
  List<String> _dates = const [];
  Map<String, WeightEntry> _weightBy = const {};
  Map<String, BodyMeasurements> _measurementsBy = const {};
  bool _loading = true;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Re-query both tables. Public: the shell calls this on tab selection,
  /// same as the other data tabs (IndexedStack keeps stale state alive).
  Future<void> reload() async {
    final end = isoDate(_now);
    final weights = await widget.dao.listBodyWeights(_kAllTime, end);
    final measurements = await widget.dao.listBodyMeasurements(_kAllTime, end);
    if (!mounted) return;
    setState(() {
      _weights = weights;
      _measurements = measurements;
      _weightBy = {for (final w in weights) w.date: w};
      _measurementsBy = {for (final m in measurements) m.date: m};
      _dates = {..._weightBy.keys, ..._measurementsBy.keys}.toList()
        ..sort((a, b) => b.compareTo(a));
      _loading = false;
    });
  }

  WeightEntry? _weightOn(String date) => _weightBy[date];

  BodyMeasurements? _measurementsOn(String date) => _measurementsBy[date];

  /// Whether THIS build renders imperial (en UI + imperial preference).
  bool get _imperial => widget.settings != null &&
      useImperial(context, widget.settings!);

  String _short(BuildContext context, String iso) =>
      AppFormats.shortDate(context, iso, now: _now);

  /// The date picker's first day: [kBodyBackfillYears] back, or the
  /// earliest entry when that is older.
  DateTime _firstLoggable() {
    final now = _now;
    var first = DateTime(now.year - kBodyBackfillYears, now.month, now.day);
    // _dates is newest first; poison rows (not real dates) are skipped.
    for (final d in _dates.reversed) {
      if (!isRealIsoDate(d)) continue;
      final earliest = DateTime.parse(d.trim());
      if (earliest.isBefore(first)) first = earliest;
      break;
    }
    return first;
  }

  /// Opens the Log sheet on [date] (today from the Log button). The sheet's
  /// date row can move it to another day; the sheet then rebuilds for that
  /// day (see [_BodySheetHost]).
  Future<void> _openSheet({String? date}) async {
    final imperial = _imperial; // resolved before the sheet detaches
    final now = _now;
    // showGroupedSheet's title is fixed when the sheet opens, and this one
    // follows the picked date, so the route builds the same GroupedSheet
    // itself (with showGroupedSheet's route settings).
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BodySheetHost(
        dao: widget.dao,
        initialDate: date ?? isoDate(now),
        imperial: imperial,
        now: now,
        firstDate: _firstLoggable(),
        weightOn: (day) => _weightOn(day)?.kg,
        measurementsOn: _measurementsOn,
        onDelete: _confirmDelete,
      ),
    );
    if (saved == true) await reload();
  }

  /// Asks, then deletes [date]'s weight and measurements. True when
  /// deleted (the page has already reloaded).
  Future<bool> _confirmDelete(String date) async {
    final hasWeight = _weightOn(date) != null;
    final hasMeasurements = _measurementsOn(date) != null;
    final l = context.l10n;
    final what = hasWeight && hasMeasurements
        ? l.bodyDeleteBoth
        : hasWeight
            ? l.bodyDeleteWeight
            : l.bodyDeleteMeasurements;
    final title = l.bodyDeleteTitle(_short(context, date));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => appAlertDialog(
        title: Text(title),
        content: Text(l.bodyDeleteBody(what)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel)),
          FilledButton(
              key: const Key('confirmDeleteBodyDay'),
              style: AppButtonStyles.destructive(context),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.delete)),
        ],
      ),
    );
    if (ok != true) return false;
    if (hasWeight) await widget.dao.deleteBodyWeight(date);
    if (hasMeasurements) await widget.dao.deleteBodyMeasurements(date);
    await reload();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final imperial = _imperial;
    final empty = _weights.isEmpty && _measurements.isEmpty;
    final now = _now;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // No Log button until the page has loaded: the sheet prefills from
      // the day's values, and one opened before them would save today's
      // measurements as a whole row with the untouched ones blank.
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              key: const Key('logBodyButton'),
              // The IndexedStack keeps Today's FAB alive at the same time;
              // the default shared hero tag makes route animations throw.
              heroTag: 'bodyLogFab',
              onPressed: () => _openSheet(),
              icon: const Icon(Icons.add),
              label: Text(l.fabLog),
            ),
      body: CustomScrollView(slivers: [
        appLargeTitleBar(context, title: l.tabBody),
        if (_loading)
          const SliverFillRemaining(
              hasScrollBody: false, child: LoadingState())
        else if (empty)
          // EmptyState.sliver keeps growing to the hint's height, so at
          // the largest text sizes it scrolls instead of overflowing. At
          // those sizes the bottom padding lets the hint's last line scroll
          // clear of the Log button (at AX5 it ended underneath it); at
          // normal sizes the centred block never reaches the button, and
          // the padding would only make an empty page scroll.
          SliverPadding(
            padding: EdgeInsets.only(
                bottom: isLargeText(context) ? AppSpace.fabClearance : 0),
            sliver: EmptyState.sliver(
              key: const Key('bodyEmpty'),
              icon: Icons.monitor_weight_rounded,
              title: l.bodyEmptyTitle,
              message: imperial ? l.bodyEmptyHintImperial : l.bodyEmptyHint,
            ),
          )
        else
          SliverList.list(children: [
            if (_weights.isNotEmpty)
              _WeightCard(weights: _weights, imperial: imperial, now: now),
            if (_measurements.isNotEmpty)
              _MeasurementsCard(
                measurements: _measurements,
                imperial: imperial,
                now: now,
                top: _weights.isNotEmpty ? AppSpace.cardGap : 0,
              ),
            GroupedSection(
              header: l.bodyHistoryHeader,
              separatorInset: AppSpace.separatorInset,
              children: [
                for (final date in _dates) _historyRow(context, date, imperial),
              ],
            ),
            const SizedBox(height: AppSpace.fabClearance),
          ]),
      ]),
    );
  }

  Widget _historyRow(BuildContext context, String date, bool imperial) {
    final l = context.l10n;
    return Dismissible(
      key: ValueKey('dismiss$date'),
      direction: DismissDirection.endToStart,
      // Swipe-to-delete (Apple's per-item idiom). The red is the danger
      // FILL under a white glyph (5.38:1 light, 3.41:1 dark); the old
      // error-role tone measured 1.70:1 in dark.
      background: ColoredBox(
        key: const Key('bodyDeleteBackground'),
        color: context.colors.dangerFill,
        child: const Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: AppSpace.s20),
            child: Icon(Icons.delete_rounded, color: Color(0xFFFFFFFF)),
          ),
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(date),
      // A named 'Delete' in VoiceOver's actions rotor: the swipe is only a
      // three-finger scroll to a screen-reader user (A11).
      child: Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: l.delete): () => _confirmDelete(date),
        },
        child: GroupedRow.custom(
          key: Key('bodyDay$date'),
          onTap: () => _openSheet(date: date),
          child: _HistoryRowContent(
            date: _short(context, date),
            weight: _weightOn(date),
            measurements: _measurementsOn(date),
            imperial: imperial,
          ),
        ),
      ),
    );
  }
}

// ─── log sheet ──────────────────────────────────────────────────────

/// The Log body sheet and the day it logs (U18). The screen owns the date:
/// picking another day in the date row builds a NEW [LogBodySheet] for it
/// (keyed by the date), prefilled with that day's values, and the title
/// follows — 'Edit Oct 28' for a day with data, 'Log body · Oct 26' for
/// one without. A sheet never edits a day it was not prefilled for.
///
/// What the user typed is not dropped silently: it moves to a day with no
/// data, and switching to a day WITH data asks first (that day's own values
/// replace it).
class _BodySheetHost extends StatefulWidget {
  const _BodySheetHost({
    required this.dao,
    required this.initialDate,
    required this.imperial,
    required this.now,
    required this.firstDate,
    required this.weightOn,
    required this.measurementsOn,
    required this.onDelete,
  });
  final MealsDao dao;
  final String initialDate;
  final bool imperial;
  final DateTime now;

  /// The picker's first day; its last is today (no future weigh-ins).
  final DateTime firstDate;

  /// The screen's loaded values for a day (it loads every day).
  final double? Function(String date) weightOn;
  final BodyMeasurements? Function(String date) measurementsOn;

  /// The screen's delete confirm for a day; true when it deleted.
  final Future<bool> Function(String date) onDelete;

  @override
  State<_BodySheetHost> createState() => _BodySheetHostState();
}

class _BodySheetHostState extends State<_BodySheetHost> {
  late String _day;

  /// [_day]'s stored values, read when the day is chosen — the sheet is
  /// prefilled from these and its title says Edit when there are any.
  double? _weight;
  BodyMeasurements? _measurements;

  /// Typed values carried over from the previous day.
  BodySheetDraft? _draft;

  @override
  void initState() {
    super.initState();
    _load(widget.initialDate);
  }

  void _load(String day) {
    _day = day;
    _weight = widget.weightOn(day);
    _measurements = widget.measurementsOn(day);
  }

  bool get _hasData =>
      _weight != null || (_measurements != null && !_measurements!.isEmpty);

  bool _dayHasData(String day) {
    final m = widget.measurementsOn(day);
    return widget.weightOn(day) != null || (m != null && !m.isEmpty);
  }

  Future<void> _changeDate(BodySheetDraft typed) async {
    final today = DateUtils.dateOnly(widget.now);
    final parsed = isRealIsoDate(_day) ? DateTime.parse(_day.trim()) : null;
    var initial = parsed ?? today;
    if (initial.isAfter(today)) initial = today;
    if (initial.isBefore(widget.firstDate)) initial = widget.firstDate;
    final picked = await showAppDatePicker(
      context: context,
      initialDate: initial,
      firstDate: widget.firstDate,
      lastDate: today,
      currentDate: today,
    );
    if (picked == null || !mounted) return;
    final day = isoDate(picked);
    if (day == _day) return;
    final targetHasData = _dayHasData(day);
    if (targetHasData && !typed.isEmpty && !await _confirmSwitch(day)) return;
    if (!mounted) return;
    setState(() {
      _load(day);
      _draft = targetHasData || typed.isEmpty ? null : typed;
    });
  }

  /// Typed values and a picked day that has its own: ask before they go.
  Future<bool> _confirmSwitch(String day) async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => appAlertDialog(
        title: Text(l.bodySheetSwitchTitle(
            AppFormats.shortDate(context, day, now: widget.now))),
        content: Text(l.bodySheetSwitchBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel)),
          FilledButton(
              key: const Key('bodySheetConfirmSwitch'),
              style: AppButtonStyles.destructive(context),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.bodySheetDiscard)),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final day = _day;
    final shown = AppFormats.shortDate(context, day, now: widget.now);
    final hasData = _hasData;
    return GroupedSheet(
      // 'Edit' only when the day already has data — the Log button on a
      // day that was logged earlier edits it too, and a day without data
      // is a new log whichever way it was opened.
      title: hasData ? l.bodySheetEditTitle(shown) : l.bodySheetLogTitle(shown),
      children: [
        LogBodySheet(
          key: ValueKey(day),
          dao: widget.dao,
          date: day,
          existingWeight: _weight,
          existing: _measurements,
          imperial: widget.imperial,
          draft: _draft,
          dateLabel: shown,
          onChangeDate: _changeDate,
          onDelete: hasData ? () => widget.onDelete(day) : null,
        ),
      ],
    );
  }
}

// ─── weight card ────────────────────────────────────────────────────

class _WeightCard extends StatelessWidget {
  const _WeightCard(
      {required this.weights, required this.imperial, required this.now});
  final List<WeightEntry> weights; // ascending
  final bool imperial;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final latest = weights.last;
    final previous = weights.length > 1 ? weights[weights.length - 2] : null;
    String short(String iso) => AppFormats.shortDate(context, iso, now: now);
    // Delta CONVERTS-then-subtracts (not subtract-then-convert): both give
    // the same number for a linear unit, but rounding happens per-value on
    // screen, so the chip must match what the two headlines imply.
    final delta = previous == null
        ? null
        : weightForDisplay(latest.kg, imperial) -
            weightForDisplay(previous.kg, imperial);
    final unit = weightUnitLabel(imperial);
    // The hero numeral stops growing at 2x (68 pt): linear Dynamic Type
    // took a 34-pt number to 105 pt at AX5, wider than an iPhone SE card
    // for '102.4'. iOS's own large numerals stop well short of that too.
    final number = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 2.0,
      child: Text(fmtBodyValue(weightForDisplay(latest.kg, imperial)),
          key: const Key('bodyWeightHeadline'),
          style: context.nums.hero.copyWith(color: colors.label)),
    );
    final unitText = Text(unit,
        key: const Key('bodyWeightUnit'),
        style: theme.textTheme.bodyLarge
            ?.copyWith(color: colors.secondaryLabel));
    final chip = delta == null
        ? null
        : _DeltaChip(
            key: const Key('bodyWeightDelta'),
            delta: delta,
            unit: unit,
            since: short(previous!.date));
    // Accessibility sizes: the number and unit wrap, and the chip takes
    // its own line — side by side they overflowed the card by 185 px at
    // AX5 (stress shot 40, A5).
    final Widget value = isLargeText(context)
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MergeSemantics(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: AppSpace.s4,
                  children: [number, unitText],
                ),
              ),
              if (chip != null) ...[
                const SizedBox(height: AppSpace.s8),
                chip,
              ],
            ],
          )
        : Row(
            children: [
              MergeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    number,
                    const SizedBox(width: AppSpace.s4),
                    unitText,
                  ],
                ),
              ),
              const Spacer(),
              ?chip,
            ],
          );
    final labelScaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 2.0);
    final labelStyle = context.type.caption2;
    return GroupedCard(
      key: const Key('bodyWeightCard'),
      margin: const EdgeInsets.symmetric(horizontal: kGroupInset),
      padding: const EdgeInsets.all(AppSpace.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.bodyWeightHeader,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: colors.secondaryLabel)),
          const SizedBox(height: AppSpace.s4),
          value,
          const SizedBox(height: AppSpace.s2),
          Text(context.l10n.bodyOnDate(short(latest.date)),
              key: const Key('bodyWeightDate'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.secondaryLabel)),
          if (weights.length >= 2) ...[
            const SizedBox(height: AppSpace.s16),
            SizedBox(
              height: WeightTrendPainter.preferredHeight(
                  labelStyle, labelScaler),
              width: double.infinity,
              child: CustomPaint(
                key: const Key('weightTrendChart'),
                painter: WeightTrendPainter(
                  entries: weights,
                  // Weight is its own entity — it wears the accent, not
                  // protein's borrowed blue (one hue per entity).
                  line: colors.accent,
                  axis: colors.separator,
                  label: colors.secondaryLabel,
                  dotRing: cellColor(context),
                  labelStyle: labelStyle,
                  textScaler: labelScaler,
                  textDirection: Directionality.of(context),
                  startLabel: short(weights.first.date),
                  endLabel: short(latest.date),
                  imperial: imperial,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DeltaChip extends StatelessWidget {
  const _DeltaChip(
      {super.key,
      required this.delta,
      required this.unit,
      required this.since});
  final double delta;
  final String unit;

  /// The previous weigh-in's date, already short.
  final String since;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    // Direction glyph + sign carried in TEXT (never colour-alone); colour is
    // deliberately neutral — for weight, neither direction is universally
    // "good", so green/red would editorialize.
    final sign = delta > 0 ? '▲ +' : (delta < 0 ? '▼ ' : '· ');
    // No-change is judged at DISPLAY precision: a 0.02 delta rendered
    // '▲ +0.0' contradicts itself (arrow says gain, number says none).
    final magnitude = delta.abs().toStringAsFixed(1);
    final text = magnitude == '0.0'
        ? context.l10n.bodyNoChange
        : '$sign$magnitude $unit';
    return Tooltip(
      message: context.l10n.bodySince(since),
      child: DecoratedBox(
        decoration:
            ShapeDecoration(color: colors.fill, shape: const StadiumBorder()),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.s8, vertical: AppSpace.s4),
          child: Text(text,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.label,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ),
    );
  }
}

// ─── measurements card ──────────────────────────────────────────────

/// One girth metric's latest and previous NON-NULL values — days that
/// logged only the other metrics must not break a series.
class _Metric {
  _Metric(this.label, this.keyName, List<BodyMeasurements> all,
      double? Function(BodyMeasurements) pick)
      : series = [
          for (final m in all)
            if (pick(m) != null) (m.date, pick(m)!),
        ];
  final String label;

  /// 'bodyWaist' → keys bodyWaistLatest (the value) and bodyWaistRow.
  final String keyName;
  final List<(String, double)> series;

  (String, double)? get latest => series.isEmpty ? null : series.last;
  (String, double)? get previous =>
      series.length > 1 ? series[series.length - 2] : null;
}

class _MeasurementsCard extends StatelessWidget {
  const _MeasurementsCard({
    required this.measurements,
    required this.imperial,
    required this.now,
    required this.top,
  });
  final List<BodyMeasurements> measurements; // ascending
  final bool imperial;
  final DateTime now;

  /// Space above the card (the gap under the weight card).
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final metrics = [
      _Metric(l.bodyWaist, 'bodyWaist', measurements, (m) => m.waistCm),
      _Metric(l.bodyChest, 'bodyChest', measurements, (m) => m.chestCm),
      _Metric(l.bodyHip, 'bodyHip', measurements, (m) => m.hipCm),
    ];
    // Usually all three are taken together: then one 'as of Oct 28'
    // footnote replaces three identical dates on the rows.
    final dates = {
      for (final m in metrics)
        if (m.latest != null) m.latest!.$1,
    };
    final shared = dates.length == 1 ? dates.single : null;
    return GroupedCard(
      key: const Key('bodyMeasurementsCard'),
      margin: EdgeInsets.fromLTRB(kGroupInset, top, kGroupInset, 0),
      padding: const EdgeInsets.all(AppSpace.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.bodyMeasurementsHeader,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: context.colors.secondaryLabel)),
          const SizedBox(height: AppSpace.s4),
          for (final m in metrics)
            _metricRow(context, m, showDate: shared == null),
          if (shared != null) ...[
            const SizedBox(height: AppSpace.s4),
            Text(
                l.bodyAsOf(AppFormats.shortDate(context, shared, now: now)),
                key: const Key('bodyMeasurementsAsOf'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: context.colors.secondaryLabel)),
          ],
        ],
      ),
    );
  }

  Widget _metricRow(BuildContext context, _Metric m,
      {required bool showDate}) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final labelText = Text(m.label,
        maxLines: 1,
        softWrap: false,
        style: theme.textTheme.bodyLarge?.copyWith(color: colors.label));
    final latest = m.latest;
    final previous = m.previous;
    final Widget valueText = latest == null
        ? Text('—',
            key: Key('${m.keyName}Latest'),
            style: context.nums.value.copyWith(color: colors.secondaryLabel))
        : Text(
            '${fmtBodyValue(girthForDisplay(latest.$2, imperial))} '
            '${girthUnitLabel(imperial)}',
            key: Key('${m.keyName}Latest'),
            style: context.nums.value.copyWith(color: colors.label));
    final delta = latest == null || previous == null
        ? null
        : girthForDisplay(latest.$2, imperial) -
            girthForDisplay(previous.$2, imperial);
    // Display-precision gate: a sub-0.05 delta must not render the
    // self-contradictory '▲ +0.0' (same rule as the weight chip). The
    // ▲/▼ carries the direction in text, so it is never the part cut.
    final deltaText =
        delta == null || delta.abs().toStringAsFixed(1) == '0.0'
            ? null
            : Text(
                '${delta > 0 ? '▲ +' : '▼ '}${delta.abs().toStringAsFixed(1)}',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.secondaryLabel,
                    fontFeatures: const [FontFeature.tabularFigures()]));
    final dateString = latest == null || !showDate
        ? null
        : context.l10n.bodyOnDate(
            AppFormats.shortDate(context, latest.$1, now: now));
    final dateStyle =
        theme.textTheme.bodySmall?.copyWith(color: colors.secondaryLabel);

    // Accessibility sizes: the label on its own line, then value, date and
    // delta wrapping as whole pieces — in one row the delta and the unit
    // were clipped at AX4/AX5 (A5).
    if (isLargeText(context)) {
      return Padding(
        key: Key('${m.keyName}Row'),
        padding: const EdgeInsets.symmetric(vertical: AppSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            labelText,
            Wrap(
              spacing: AppSpace.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                valueText,
                if (dateString != null) Text(dateString, style: dateStyle),
                ?deltaText,
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      key: Key('${m.keyName}Row'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.s8),
      child: Row(
        children: [
          // The name column: at least 64 pt so the values line up, never
          // narrower than the word itself (a fixed box broke 'Waist'
          // mid-word at 2x text).
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 2 * AppSpace.s32),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: AppSpace.s8),
              child: labelText,
            ),
          ),
          valueText,
          // The date is the one part that may give way (ellipsis); with a
          // shared footnote there is no date and the delta still sits at
          // the right edge.
          Expanded(
            child: dateString == null
                ? const SizedBox.shrink()
                : Padding(
                    padding:
                        const EdgeInsetsDirectional.only(start: AppSpace.s8),
                    child: Text(dateString,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: dateStyle),
                  ),
          ),
          if (deltaText != null) ...[
            const SizedBox(width: AppSpace.s4),
            deltaText,
          ],
        ],
      ),
    );
  }
}

// ─── history row ────────────────────────────────────────────────────

class _HistoryRowContent extends StatelessWidget {
  const _HistoryRowContent({
    required this.date,
    required this.weight,
    required this.measurements,
    required this.imperial,
  });

  /// Already short ('Oct 30').
  final String date;
  final WeightEntry? weight;
  final BodyMeasurements? measurements;
  final bool imperial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    String girth(double cm) => fmtBodyValue(girthForDisplay(cm, imperial));
    // Short labels come from the ARB (zh 腰/胸/臀) — literal 'W'/'C'/'H'
    // put Latin initials into the Chinese UI.
    final l = context.l10n;
    final m = measurements;
    // A no-break space keeps each short label with its number: at AX5 the
    // zh row broke '胸' from '98.5' across lines.
    const nb = '\u00A0';
    final parts = <String>[
      if (weight != null)
        '${weightForDisplay(weight!.kg, imperial).toStringAsFixed(1)} '
            '${weightUnitLabel(imperial)}',
      if (m?.waistCm != null) '${l.bodyWaistShort}$nb${girth(m!.waistCm!)}',
      if (m?.chestCm != null) '${l.bodyChestShort}$nb${girth(m!.chestCm!)}',
      if (m?.hipCm != null) '${l.bodyHipShort}$nb${girth(m!.hipCm!)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(date,
            style: theme.textTheme.bodyLarge?.copyWith(color: colors.label)),
        if (parts.isNotEmpty) ...[
          const SizedBox(height: AppSpace.s2),
          Text(parts.join('  ·  '),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.secondaryLabel)),
        ],
      ],
    );
  }
}
