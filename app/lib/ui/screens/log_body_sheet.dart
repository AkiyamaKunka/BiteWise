/// The Body tab's log sheet: logs or edits one day's weight and girth
/// measurements (waist / chest / hip). Split out of body_screen.dart.
library;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../core/shared_generated.dart';
import '../l10n.dart';
import '../units.dart';

/// App-only sanity bounds for girth values (cm). Weight uses the shared
/// parity bounds [SharedConstants.weightMinKg]/[SharedConstants.weightMaxKg].
const double kGirthMinCm = 20;
const double kGirthMaxCm = 300;

/// Bottom sheet for logging or editing one day. Prefilled with the day's
/// existing values, so the DAO's full-row upsert preserves what the user
/// didn't touch — and clearing a field really clears it.
class LogBodySheet extends StatefulWidget {
  const LogBodySheet({
    super.key,
    required this.dao,
    required this.date,
    this.existingWeight,
    this.existing,
    this.latestDate,
    this.imperial = false,
  });
  final MealsDao dao;
  final String date;
  final double? existingWeight;
  final BodyMeasurements? existing;

  /// When editing an old day, today's date (for the header hint); null when
  /// already logging today.
  final String? latestDate;

  /// Display/input unit system; values are STORED metric either way.
  final bool imperial;

  @override
  State<LogBodySheet> createState() => _LogBodySheetState();
}

class _LogBodySheetState extends State<LogBodySheet> {
  late final TextEditingController _weight;
  late final TextEditingController _waist;
  late final TextEditingController _chest;
  late final TextEditingController _hip;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _weight = TextEditingController(
        text: _fmt(widget.existingWeight, weightForDisplay));
    _waist = TextEditingController(
        text: _fmt(widget.existing?.waistCm, girthForDisplay));
    _chest = TextEditingController(
        text: _fmt(widget.existing?.chestCm, girthForDisplay));
    _hip = TextEditingController(
        text: _fmt(widget.existing?.hipCm, girthForDisplay));
  }

  String _fmt(double? metric, double Function(double, bool) toDisplay) =>
      metric == null ? '' : fmtBodyValue(toDisplay(metric, widget.imperial));

  @override
  void dispose() {
    _weight.dispose();
    _waist.dispose();
    _chest.dispose();
    _hip.dispose();
    super.dispose();
  }

  /// Parse one field → METRIC: (value, problem). Empty is a valid
  /// "no value". Bounds are metric (the shared parity bounds); the error
  /// message shows them in the DISPLAY unit. [existingMetric] guards
  /// round-trip drift: an untouched prefill keeps the stored value
  /// bit-for-bit instead of lb→kg'ing the rounded display text.
  (double?, String?) _parse(
      TextEditingController c,
      String label,
      double min,
      double max,
      double Function(double, bool) toMetricSpace, // input → metric
      double Function(double, bool) toDisplaySpace, // metric → display
      double? existingMetric) {
    final raw = c.text.trim().replaceAll(',', '.');
    if (raw.isEmpty) return (null, null);
    if (existingMetric != null &&
        raw == fmtBodyValue(toDisplaySpace(existingMetric, widget.imperial))) {
      return (existingMetric, null);
    }
    final typed = double.tryParse(raw);
    // !isFinite: tryParse accepts the literals 'NaN'/'Infinity' (pasteable
    // even past a numeric keyboard). NaN then sails through the bounds
    // check (every comparison false) and clamp() returns the UPPER bound —
    // a fabricated 300 kg weigh-in (pressure-test find, 2026-08-03).
    if (typed == null || !typed.isFinite) {
      return (null, context.l10n.bodyErrNotNumber(label, raw));
    }
    final v = toMetricSpace(typed, widget.imperial);
    // The error message advertises 1-decimal DISPLAY bounds, so accept
    // anything that rounds into them (typing the advertised '66.1' lb
    // must not bounce off 30 kg), then clamp to the exact parity bounds
    // for storage.
    final tol = toMetricSpace(0.05, widget.imperial);
    if (v < min - tol || v > max + tol) {
      return (null,
          context.l10n.bodyErrBounds(
              label,
              fmtBodyValue(toDisplaySpace(min, widget.imperial)),
              fmtBodyValue(toDisplaySpace(max, widget.imperial))));
    }
    return (v.clamp(min, max).toDouble(), null);
  }

  Future<void> _save() async {
    final l = context.l10n;
    final (kg, e1) = _parse(_weight, l.bodyFieldWeight,
        SharedConstants.weightMinKg.toDouble(),
        SharedConstants.weightMaxKg.toDouble(),
        weightFromInput, weightForDisplay, widget.existingWeight);
    final (waist, e2) = _parse(_waist, l.bodyWaist, kGirthMinCm,
        kGirthMaxCm, girthFromInput, girthForDisplay,
        widget.existing?.waistCm);
    final (chest, e3) = _parse(_chest, l.bodyChest, kGirthMinCm,
        kGirthMaxCm, girthFromInput, girthForDisplay,
        widget.existing?.chestCm);
    final (hip, e4) = _parse(_hip, l.bodyHip, kGirthMinCm, kGirthMaxCm,
        girthFromInput, girthForDisplay, widget.existing?.hipCm);
    final problem = e1 ?? e2 ?? e3 ?? e4;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final hadAnything = widget.existingWeight != null ||
        (widget.existing != null && !widget.existing!.isEmpty);
    if (kg == null && waist == null && chest == null && hip == null &&
        !hadAnything) {
      setState(() => _error = context.l10n.bodyErrEmpty);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    // Weight: save or (when this edit cleared a previously present value)
    // delete — leaving the stale row would resurrect it on next load.
    if (kg != null) {
      await widget.dao.saveBodyWeight(widget.date, kg, source: 'manual');
    } else if (widget.existingWeight != null) {
      await widget.dao.deleteBodyWeight(widget.date);
    }
    // Measurements: full-row upsert; all-empty deletes (DAO contract).
    if (waist != null || chest != null || hip != null ||
        widget.existing != null) {
      await widget.dao.saveBodyMeasurements(widget.date,
          waistCm: waist, chestCm: chest, hipCm: hip);
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // Keep the sheet above the keyboard.
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.latestDate == null
                  ? context.l10n.bodySheetLogTitle(widget.date)
                  : context.l10n.bodySheetEditTitle(widget.date),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.bodySheetHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('bodyWeightField'),
                    controller: _weight,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: context.l10n.bodyFieldWeight,
                      suffixText: weightUnitLabel(widget.imperial),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('bodyWaistField'),
                    controller: _waist,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: context.l10n.bodyWaist,
                      suffixText: girthUnitLabel(widget.imperial),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('bodyChestField'),
                    controller: _chest,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: context.l10n.bodyChest,
                      suffixText: girthUnitLabel(widget.imperial),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const Key('bodyHipField'),
                    controller: _hip,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: context.l10n.bodyHip,
                      suffixText: girthUnitLabel(widget.imperial),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  key: const Key('bodySheetError'),
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('bodySheetSave'),
                onPressed: _saving ? null : _save,
                child: Text(
                    _saving ? context.l10n.saving : context.l10n.save),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
