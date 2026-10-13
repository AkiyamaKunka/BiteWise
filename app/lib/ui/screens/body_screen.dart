/// The Body tab: weight history + girth measurements (waist / chest / hip).
///
/// Weight rides the parity `body_weight` table (spec §7.1 — one canonical
/// weigh-in per day, which the NL executor has been writing all along with
/// no UI to show for it). Measurements are app-only (spec §9): the server
/// tracks weight, not girth.
///
/// Design rules follow the app's chart idiom (macro_chart.dart): hand-drawn
/// CustomPainter, one hue per series, recessive axes, selective labels
/// (min / max / latest), identity never colour-alone.
library;

import 'package:flutter/material.dart';

import '../../core/coerce.dart' show isoDate;
import '../../core/contracts.dart';
import '../l10n.dart';
import '../services.dart' show SettingsStore;
import '../units.dart';
import '../widgets/grouped.dart' show cellBackground;
import '../widgets/weight_trend_painter.dart';
import 'log_body_sheet.dart';

/// Chart + list window. A year keeps the page honest for lapsed loggers
/// (a 90-day window would silently hide that the last entry is old).
const int kBodyWindowDays = 365;

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
    final now = _now;
    final start = isoDate(now.subtract(const Duration(days: kBodyWindowDays)));
    final end = isoDate(now);
    final weights = await widget.dao.listBodyWeights(start, end);
    final measurements = await widget.dao.listBodyMeasurements(start, end);
    if (!mounted) return;
    setState(() {
      _weights = weights;
      _measurements = measurements;
      _loading = false;
    });
  }

  /// All dates carrying any data, newest first, for the history list.
  List<String> get _dates {
    final set = <String>{
      for (final w in _weights) w.date,
      for (final m in _measurements) m.date,
    };
    final list = set.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  WeightEntry? _weightOn(String date) {
    for (final w in _weights) {
      if (w.date == date) return w;
    }
    return null;
  }

  BodyMeasurements? _measurementsOn(String date) {
    for (final m in _measurements) {
      if (m.date == date) return m;
    }
    return null;
  }

  /// Whether THIS build renders imperial (en UI + imperial preference).
  bool get _imperial => widget.settings != null &&
      useImperial(context, widget.settings!);

  Future<void> _openSheet({String? date}) async {
    final initialDate = date ?? isoDate(_now);
    final imperial = _imperial; // resolved before the sheet detaches
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => LogBodySheet(
        dao: widget.dao,
        date: initialDate,
        existingWeight: _weightOn(initialDate)?.kg,
        existing: _measurementsOn(initialDate),
        latestDate: date == null ? null : isoDate(_now),
        imperial: imperial,
      ),
    );
    if (saved == true) await reload();
  }

  Future<bool> _confirmDelete(String date) async {
    final hasWeight = _weightOn(date) != null;
    final hasMeasurements = _measurementsOn(date) != null;
    final l = context.l10n;
    final what = hasWeight && hasMeasurements
        ? l.bodyDeleteBoth
        : hasWeight
            ? l.bodyDeleteWeight
            : l.bodyDeleteMeasurements;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.bodyDeleteTitle(date)),
        content: Text(l.bodyDeleteBody(what)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel)),
          FilledButton(
              key: const Key('confirmDeleteBodyDay'),
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
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final empty = _weights.isEmpty && _measurements.isEmpty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('logBodyButton'),
        // The IndexedStack keeps Today's FAB alive at the same time; the
        // default shared hero tag makes route animations throw.
        heroTag: 'bodyLogFab',
        onPressed: () => _openSheet(),
        icon: const Icon(Icons.add),
        label: Text(context.l10n.fabLog),
      ),
      body: empty
          ? CustomScrollView(slivers: [
              SliverAppBar.large(title: Text(context.l10n.tabBody)),
              // hasScrollBody: false lets the sliver grow to the empty
              // state's height: the default pinned it to the remaining
              // viewport, so at the largest text sizes the ~8-line hint
              // overflowed (RenderFlex, 142 px) and no scroll reached its
              // end. It still fills and centers when it fits.
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  key: const Key('bodyEmpty'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.monitor_weight_outlined,
                        size: 48, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text(context.l10n.bodyEmptyTitle,
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      _imperial
                          ? context.l10n.bodyEmptyHintImperial
                          : context.l10n.bodyEmptyHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ))])
          : CustomScrollView(slivers: [
              SliverAppBar.large(title: Text(context.l10n.tabBody)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                sliver: SliverList.list(children: [
                if (_weights.isNotEmpty)
                  _WeightCard(weights: _weights, imperial: _imperial),
                if (_measurements.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _MeasurementsCard(
                      measurements: _measurements, imperial: _imperial),
                ],
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 7),
                  child: Text(context.l10n.bodyHistoryHeader,
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
                ),
                Material(
                  color: cellBackground(theme.colorScheme),
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    for (var i = 0; i < _dates.length; i++) ...[
                      if (i > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Divider(
                              height: 1,
                              thickness: 0.33,
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.6)),
                        ),
                      // Swipe-to-delete (Apple's per-item idiom) replaced
                      // the trailing delete button — the most un-iOS
                      // element the panel found on any main tab.
                      Dismissible(
                        key: ValueKey('dismiss${_dates[i]}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: theme.colorScheme.error,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete,
                              color: Colors.white),
                        ),
                        confirmDismiss: (_) => _confirmDelete(_dates[i]),
                        child: _HistoryRow(
                          key: Key('bodyDay${_dates[i]}'),
                          date: _dates[i],
                          weight: _weightOn(_dates[i]),
                          measurements: _measurementsOn(_dates[i]),
                          imperial: _imperial,
                          onTap: () => _openSheet(date: _dates[i]),
                        ),
                      ),
                    ],
                  ]),
                ),
                ]),
              ),
            ]),
    );
  }
}

// ─── weight card ────────────────────────────────────────────────────

class _WeightCard extends StatelessWidget {
  const _WeightCard({required this.weights, required this.imperial});
  final List<WeightEntry> weights; // ascending
  final bool imperial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = weights.last;
    final previous = weights.length > 1 ? weights[weights.length - 2] : null;
    // Delta CONVERTS-then-subtracts (not subtract-then-convert): both give
    // the same number for a linear unit, but rounding happens per-value on
    // screen, so the chip must match what the two headlines imply.
    final delta = previous == null
        ? null
        : weightForDisplay(latest.kg, imperial) -
            weightForDisplay(previous.kg, imperial);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.bodyWeightHeader,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(fmtBodyValue(weightForDisplay(latest.kg, imperial)),
                    key: const Key('bodyWeightHeadline'),
                    style: theme.textTheme.displaySmall),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(weightUnitLabel(imperial),
                      style: theme.textTheme.titleMedium),
                ),
                const Spacer(),
                if (delta != null)
                  _DeltaChip(
                      key: const Key('bodyWeightDelta'),
                      delta: delta,
                      unit: weightUnitLabel(imperial),
                      sinceDate: previous!.date),
              ],
            ),
            Text(context.l10n.bodyOnDate(latest.date),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (weights.length >= 2) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 140,
                width: double.infinity,
                child: CustomPaint(
                  key: const Key('weightTrendChart'),
                  painter: WeightTrendPainter(
                    entries: weights,
                    // Weight is its own entity — it wears primary, not
                    // protein's borrowed blue (one hue per entity).
                    line: theme.colorScheme.primary,
                    axis: theme.colorScheme.outlineVariant,
                    label: theme.colorScheme.onSurfaceVariant,
                    textDirection: Directionality.of(context),
                    imperial: imperial,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

}

class _DeltaChip extends StatelessWidget {
  const _DeltaChip(
      {super.key,
      required this.delta,
      required this.unit,
      required this.sinceDate});
  final double delta;
  final String unit;
  final String sinceDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      message: context.l10n.bodySince(sinceDate),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: theme.textTheme.labelLarge),
      ),
    );
  }
}

// ─── measurements card ──────────────────────────────────────────────

class _MeasurementsCard extends StatelessWidget {
  const _MeasurementsCard(
      {required this.measurements, required this.imperial});
  final List<BodyMeasurements> measurements; // ascending
  final bool imperial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.bodyMeasurementsHeader,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            _metricRow(context, context.l10n.bodyWaist, (m) => m.waistCm,
                const Key('bodyWaistLatest')),
            _metricRow(context, context.l10n.bodyChest, (m) => m.chestCm,
                const Key('bodyChestLatest')),
            _metricRow(context, context.l10n.bodyHip, (m) => m.hipCm,
                const Key('bodyHipLatest')),
          ],
        ),
      ),
    );
  }

  /// The metric name column: at least 64 px so the values line up at the
  /// default size, but never narrower than the word itself — a fixed 64 px
  /// box broke 'Waist' mid-word at 2× text.
  Widget _label(String label) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 56),
          child: Text(label, maxLines: 1, softWrap: false),
        ),
      );

  Widget _metricRow(BuildContext context, String label,
      double? Function(BodyMeasurements) pick, Key key) {
    final theme = Theme.of(context);
    // Latest + previous NON-NULL values for this metric — days that logged
    // only the other metrics must not break a series.
    final series = [
      for (final m in measurements)
        if (pick(m) != null) (m.date, pick(m)!),
    ];
    if (series.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _label(label),
            Text('—',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    final latest = series.last;
    final previous = series.length > 1 ? series[series.length - 2] : null;
    final delta = previous == null
        ? null
        : girthForDisplay(latest.$2, imperial) -
            girthForDisplay(previous.$2, imperial);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _label(label),
          Text(
              '${fmtBodyValue(girthForDisplay(latest.$2, imperial))} '
              '${girthUnitLabel(imperial)}',
              key: key, style: theme.textTheme.titleMedium),
          // The date is the one part that may give way: at accessibility
          // text sizes the old unflexed date + Spacer pushed the row past
          // the card (RenderFlex overflow, the ▲/▼ delta clipped). Expanded
          // — not Flexible beside a Spacer, which would hand the Spacer
          // half the room and cut the date even at 1.0× — still pushes the
          // delta to the right edge, and ellipsises the date instead. Its
          // 8 px lead sits INSIDE so it collapses with the date at 2×.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(context.l10n.bodyOnDate(latest.$1),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ),
          // Display-precision gate: a sub-0.05 delta must not render the
          // self-contradictory '▲ +0.0' (same rule as the weight chip).
          // Never flexed: the ▲/▼ carries the direction in text, so it is
          // the last thing that may be cut. The 4 px keeps an ellipsised
          // date off the glyph.
          if (delta != null && delta.abs().toStringAsFixed(1) != '0.0') ...[
            const SizedBox(width: 4),
            Text(
              '${delta > 0 ? '▲ +' : '▼ '}${delta.abs().toStringAsFixed(1)}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

}

// ─── history row ────────────────────────────────────────────────────

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.date,
    required this.weight,
    required this.measurements,
    required this.imperial,
    required this.onTap,
  });
  final String date;
  final WeightEntry? weight;
  final BodyMeasurements? measurements;
  final bool imperial;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    String girth(double cm) => _v(girthForDisplay(cm, imperial));
    // Short labels come from the ARB (zh 腰/胸/臀) — literal 'W'/'C'/'H'
    // put Latin initials into the Chinese UI.
    final l = context.l10n;
    final parts = <String>[
      if (weight != null)
        '${weightForDisplay(weight!.kg, imperial).toStringAsFixed(1)} '
            '${weightUnitLabel(imperial)}',
      if (measurements?.waistCm != null)
        '${l.bodyWaistShort} ${girth(measurements!.waistCm!)}',
      if (measurements?.chestCm != null)
        '${l.bodyChestShort} ${girth(measurements!.chestCm!)}',
      if (measurements?.hipCm != null)
        '${l.bodyHipShort} ${girth(measurements!.hipCm!)}',
    ];
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(date, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(parts.join('  ·  '),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Icon(Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.6)),
        ]),
      ),
    );
  }

  static String _v(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}
