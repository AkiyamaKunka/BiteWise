/// The Body tab's log sheet: logs or edits one day's weight and girth
/// measurements (waist / chest / hip). Split out of body_screen.dart.
///
/// Shown inside a GroupedSheet, which draws the title ('Log body ·
/// Oct 30' / 'Edit Oct 30'), scrolls, and lifts the content above the
/// keyboard — this widget adds none of that itself.
///
/// The date row at the top does not change the date here (U18): it hands
/// what the user typed to [LogBodySheet.onChangeDate], and the Body screen
/// picks the date and builds a NEW sheet for it, prefilled with that day.
/// One sheet is always one day, so the prefill that guards the full-row
/// measurements upsert and "cleared means delete" can never belong to
/// another day.
library;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../core/shared_generated.dart';
import '../l10n.dart';
import '../large_text.dart';
import '../theme/tokens.dart';
import '../units.dart';
import '../widgets/grouped.dart' show GroupedCard, GroupedRow, cellColor;

/// App-only sanity bounds for girth values (cm). Weight uses the shared
/// parity bounds [SharedConstants.weightMinKg]/[SharedConstants.weightMaxKg].
const double kGirthMinCm = 20;
const double kGirthMaxCm = 300;

/// What the user typed and has not saved: each field's text where it
/// differs from the day's stored value, null where it does not. Carried to
/// a newly picked day that has no data, so changing the date does not
/// throw away a weight typed for the wrong day.
@immutable
class BodySheetDraft {
  const BodySheetDraft({this.weight, this.waist, this.chest, this.hip});
  final String? weight;
  final String? waist;
  final String? chest;
  final String? hip;

  /// Nothing typed: changing the date loses nothing.
  bool get isEmpty =>
      weight == null && waist == null && chest == null && hip == null;
}

/// Sheet body for logging or editing one day. Prefilled with the day's
/// existing values, so the DAO's full-row upsert preserves what the user
/// didn't touch — and clearing a field really clears it.
class LogBodySheet extends StatefulWidget {
  const LogBodySheet({
    super.key,
    required this.dao,
    required this.date,
    this.existingWeight,
    this.existing,
    this.imperial = false,
    this.onDelete,
    this.draft,
    this.dateLabel,
    this.onChangeDate,
  });
  final MealsDao dao;
  final String date;
  final double? existingWeight;
  final BodyMeasurements? existing;

  /// Typed values carried over from another day: a non-null field starts
  /// with this text instead of the stored value.
  final BodySheetDraft? draft;

  /// [date] for display ('Oct 30'), shown in the date row.
  final String? dateLabel;

  /// The date row's tap, with what the user typed. Null (or no
  /// [dateLabel]) hides the row.
  final ValueChanged<BodySheetDraft>? onChangeDate;

  /// Display/input unit system; values are STORED metric either way.
  final bool imperial;

  /// For a day that already has data: asks, deletes the whole day and
  /// resolves true when it did (the sheet then closes). A delete that
  /// failed throws: the sheet says so and stays open. Null hides the
  /// Delete button. It is also the accessible way to delete a day.
  final Future<bool> Function()? onDelete;

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

  /// The stored values as the fields first show them: the baseline that
  /// tells typed text from an untouched prefill.
  late final String _storedWeight =
      _fmt(widget.existingWeight, weightForDisplay);
  late final String _storedWaist =
      _fmt(widget.existing?.waistCm, girthForDisplay);
  late final String _storedChest =
      _fmt(widget.existing?.chestCm, girthForDisplay);
  late final String _storedHip = _fmt(widget.existing?.hipCm, girthForDisplay);

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    _weight = TextEditingController(text: draft?.weight ?? _storedWeight);
    _waist = TextEditingController(text: draft?.waist ?? _storedWaist);
    _chest = TextEditingController(text: draft?.chest ?? _storedChest);
    _hip = TextEditingController(text: draft?.hip ?? _storedHip);
  }

  /// The fields whose text is not the day's stored value.
  BodySheetDraft _typed() {
    String? typed(TextEditingController c, String stored) =>
        c.text.trim() == stored ? null : c.text.trim();
    return BodySheetDraft(
      weight: typed(_weight, _storedWeight),
      waist: typed(_waist, _storedWaist),
      chest: typed(_chest, _storedChest),
      hip: typed(_hip, _storedHip),
    );
  }

  void _changeDate() {
    // The keyboard would sit over the date picker. Unfocus the FIELD (its
    // scope then forgets it): FocusScope.of(context).unfocus() let the
    // sheet route remember the field and re-focus it, keyboard and all,
    // when the picker or the switch question closed.
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onChangeDate!(_typed());
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
    try {
      // Weight: save or (when this edit cleared a previously present
      // value) delete — leaving the stale row would resurrect it on next
      // load.
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
    } catch (e) {
      // The sheet keeps what was typed, says so and can save again: it
      // stayed on 'Saving…' with Save and Delete disabled, and said
      // nothing. The log gets the error's type, never its text: sqflite's
      // text carries the statement's arguments, which are the weight and
      // girths just typed, and debugPrint stays in release builds.
      debugPrint('Body: save failed (${e.runtimeType})');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = l.bodySaveFailed;
      });
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final l = context.l10n;
    final bool deleted;
    try {
      deleted = await widget.onDelete!();
    } catch (_) {
      // Logged by the screen, which shows what is left. Said here, where
      // the user is looking: a snackbar would sit under the sheet.
      if (mounted) setState(() => _error = l.bodyDeleteFailed);
      return;
    }
    // The page reloaded already; false tells it not to reload again.
    if (deleted && mounted) Navigator.pop(context, false);
  }

  Widget _field(
          TextEditingController controller, String key, String label,
          String unit) =>
      TextField(
        key: Key(key),
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: unit,
          // In-sheet cell colour: the theme's page-cell fill is the dark
          // sheet's own colour, so a field there showed no fill at all.
          fillColor: cellColor(context),
        ),
      );

  /// [fields] [perRow] to a row with 12-pt gaps both ways.
  static Widget _grid(List<Widget> fields, int perRow) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var r = 0; r < fields.length; r += perRow) ...[
            if (r > 0) const SizedBox(height: AppSpace.s12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < perRow; c++) ...[
                  if (c > 0) const SizedBox(width: AppSpace.s12),
                  Expanded(
                    child: r + c < fields.length
                        ? fields[r + c]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final l = context.l10n;
    final girthUnit = girthUnitLabel(widget.imperial);
    final fields = [
      _field(_weight, 'bodyWeightField', l.bodyFieldWeight,
          weightUnitLabel(widget.imperial)),
      _field(_waist, 'bodyWaistField', l.bodyWaist, girthUnit),
      _field(_chest, 'bodyChestField', l.bodyChest, girthUnit),
      _field(_hip, 'bodyHipField', l.bodyHip, girthUnit),
    ];
    final onDelete = widget.onDelete;
    final dateLabel = widget.dateLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter, 0, AppSpace.gutter, AppSpace.s8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.onChangeDate != null && dateLabel != null) ...[
            // An in-sheet cell like the fields below it. GroupedRow reads
            // as one button, 'Date, Oct 30', and stacks the date under
            // the label at accessibility sizes.
            GroupedCard(
              margin: EdgeInsets.zero,
              child: GroupedRow(
                key: const Key('bodySheetDateRow'),
                icon: Icons.calendar_today_rounded,
                title: l.bodySheetDate,
                value: dateLabel,
                onTap: _saving ? null : _changeDate,
              ),
            ),
            const SizedBox(height: AppSpace.s12),
          ],
          Text(
            l.bodySheetHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: colors.secondaryLabel),
          ),
          const SizedBox(height: AppSpace.s16),
          // Two fields a row; ONE at accessibility sizes, where a half-width
          // field cut its label to 'We…' and hid the typed weight behind
          // its unit (A7).
          _grid(fields, isLargeText(context) ? 1 : 2),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.s12),
            Semantics(
              liveRegion: true,
              child: Text(_error!,
                  key: const Key('bodySheetError'),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: colors.danger)),
            ),
          ],
          const SizedBox(height: AppSpace.s20),
          FilledButton(
            key: const Key('bodySheetSave'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? l.saving : l.save),
          ),
          if (onDelete != null) ...[
            const SizedBox(height: AppSpace.s8),
            TextButton(
              key: const Key('bodySheetDelete'),
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.pressed)
                        ? colors.danger.withValues(alpha: 0.4)
                        : colors.danger),
              ),
              onPressed: _saving ? null : _delete,
              child: Text(l.delete),
            ),
          ],
        ],
      ),
    );
  }
}
