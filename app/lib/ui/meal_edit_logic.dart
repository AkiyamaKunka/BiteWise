/// Pure logic behind the meal editor (no widgets, no I/O) so every rule is
/// unit-testable: field parsing/bounds, totals derived from items, and the
/// analysis-map merge that decides what actually gets persisted.
///
/// Editing rules that matter downstream:
///   - the merge PRESERVES unknown keys from the original analysis
///     (analyzed_by, notes, anything a future model adds): the editor knows
///     about calories and macros, and must not silently drop the rest.
///   - a saved edit is always `is_food: true`. Every read path filters on
///     is_food (format.isFoodMeal), so keeping a false/absent flag would
///     hide the meal the user just typed numbers into.
///   - blank means ZERO, not "unknown": a blank protein field on a meal the
///     user is explicitly curating should read 0 g in totals, and the
///     display helpers render a stored 0 as 0 (calories included — see
///     format.displayTotalCalories), so card and day total agree.
library;

import '../core/coerce.dart';
import '../core/contracts.dart';
import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';
import 'format.dart' show isoDate;

/// UI bounds. Deliberately generous — the point is to reject typos and
/// hostile input (1e9 breaks the coercion layer's accumulation guarantees),
/// not to police unusual meals.
const num maxMealCalories = 20000;
const num maxMacroGrams = 2000;
const int maxDescriptionChars = 300;
const int maxItemsPerMeal = 40;

/// One parsed numeric field: [value] null means the field was blank.
class FieldParse {
  const FieldParse(this.value, this.error);
  final num? value;
  final String? error;

  bool get ok => error == null;
}

/// Parse a user-typed number: blank → null (caller treats as 0), negative /
/// non-numeric / over-max → an error message naming the field, in the app
/// language when the screen passes [l] (the zh UI showed English rejections;
/// found 2026-10-07). The English default is byte-identical to the old
/// literals, so callers and tests without a locale read exactly as before.
FieldParse parseNumberField(String raw,
    {required String label, required num max, AppLocalizations? l}) {
  final t = raw.trim();
  if (t.isEmpty) return const FieldParse(null, null);
  final v = num.tryParse(t);
  final msg = l ?? AppLocalizationsEn();
  if (v == null || v.isNaN || v.isInfinite) {
    return FieldParse(null, msg.editorErrNotNumber(label));
  }
  if (v < 0) return FieldParse(null, msg.editorErrNegative(label));
  if (v > max) return FieldParse(null, msg.editorErrTooLarge(label, '$max'));
  return FieldParse(v, null);
}

/// A food item row in the editor.
class MealItemDraft {
  MealItemDraft({
    this.name = '',
    this.calories = '',
    this.protein = '',
    this.carbs = '',
    this.fat = '',
  });

  String name;
  String calories;
  String protein;
  String carbs;
  String fat;

  static MealItemDraft fromMap(Map<String, dynamic> m) => MealItemDraft(
        name: (m['name'] ?? '').toString(),
        calories: _numText(m['estimated_calories']),
        protein: _numText(m['protein_g']),
        carbs: _numText(m['carbs_g']),
        fat: _numText(m['fat_g']),
      );

  bool get isBlank =>
      name.trim().isEmpty &&
      calories.trim().isEmpty &&
      protein.trim().isEmpty &&
      carbs.trim().isEmpty &&
      fat.trim().isEmpty;

  Map<String, dynamic> toMap() => {
        'name': name.trim(),
        'estimated_calories': parseNumberField(calories,
                    label: 'Item calories', max: maxMealCalories)
                .value ??
            0,
        'protein_g':
            parseNumberField(protein, label: 'Item protein', max: maxMacroGrams)
                    .value ??
                0,
        'carbs_g':
            parseNumberField(carbs, label: 'Item carbs', max: maxMacroGrams)
                    .value ??
                0,
        'fat_g': parseNumberField(fat, label: 'Item fat', max: maxMacroGrams)
                .value ??
            0,
      };
}

/// Field text for a stored value. Numeric STRINGS must parse: the analyzer
/// stores model output raw (no response schema), so "450" is a real stored
/// shape — and loading it as blank made a no-op save persist 0 and wipe
/// every number on the meal.
String _numText(dynamic v) {
  var n = safeNumberOr(v, null);
  if (n == null && v is String) n = safeNumberOr(num.tryParse(v.trim()), null);
  if (n == null) return '';
  return n == n.roundToDouble() ? n.round().toString() : n.toString();
}

/// Item sums are user-facing numbers, not accumulator internals: 0.1+0.2
/// must read 0.3, and calories are whole. Two decimals for grams.
num _tidy(num v) {
  if (v == v.roundToDouble()) return v.round();
  return num.parse(v.toStringAsFixed(2));
}

/// The editable state of one meal (existing or new).
class MealDraft {
  MealDraft({
    required this.description,
    required this.dateIso,
    required this.time,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.items,
    this.base = const {},
  });

  String description;
  String dateIso; // YYYY-MM-DD
  String time; // hh:mm AM/PM, server display parity
  String calories;
  String protein;
  String carbs;
  String fat;
  List<MealItemDraft> items;

  /// The analysis map this draft started from; unknown keys survive the save.
  final Map<String, dynamic> base;

  static MealDraft fromMeal(Meal meal) => MealDraft(
        description: mealDescriptionRaw(meal.analysis),
        dateIso: meal.date,
        time: meal.time,
        calories: _numText(meal.analysis['total_calories']),
        protein: _numText(meal.analysis['total_protein_g']),
        carbs: _numText(meal.analysis['total_carbs_g']),
        fat: _numText(meal.analysis['total_fat_g']),
        items: [
          for (final m in safeFoodItems(meal.analysis)) MealItemDraft.fromMap(m)
        ],
        base: Map<String, dynamic>.from(meal.analysis),
      );

  static MealDraft blank(DateTime now) => MealDraft(
        description: '',
        dateIso: isoDate(now),
        time: formatClock(now),
        calories: '',
        protein: '',
        carbs: '',
        fat: '',
        items: [],
      );

  /// Append an item row and return it. The FIRST row inherits the totals
  /// typed above it: with no rows those totals were the only source of
  /// truth, and the editor's derive-from-items rule would otherwise sum one
  /// empty row and zero them the moment the user tapped "Add item" (found
  /// 2026-10-07: a hand-entered 450 kcal meal read 0 right after the tap).
  /// Later rows start blank — by then the totals belong to the rows, and a
  /// seeded row would double them.
  MealItemDraft addItem() {
    final it = items.isEmpty
        ? MealItemDraft(
            calories: calories, protein: protein, carbs: carbs, fat: fat)
        : MealItemDraft();
    items.add(it);
    return it;
  }

  /// Sum of the item rows, for the "use item totals" action.
  ({num calories, num protein, num carbs, num fat}) itemTotals() {
    num c = 0, p = 0, cb = 0, f = 0;
    for (final it in items.where((i) => !i.isBlank)) {
      final m = it.toMap();
      c += safeNumber(m['estimated_calories']);
      p += safeNumber(m['protein_g']);
      cb += safeNumber(m['carbs_g']);
      f += safeNumber(m['fat_g']);
    }
    return (
      calories: _tidy(c),
      protein: _tidy(p),
      carbs: _tidy(cb),
      fat: _tidy(f)
    );
  }

  /// Every problem the user must fix before saving, in field order, in the
  /// app language when the screen passes [l] (English otherwise).
  List<String> validate([AppLocalizations? l]) {
    final msg = l ?? AppLocalizationsEn();
    final errors = <String>[];
    if (description.trim().length > maxDescriptionChars) {
      errors.add(msg.editorErrDescTooLong('$maxDescriptionChars'));
    }
    if (!isRealIsoDate(dateIso)) {
      errors.add(msg.editorErrDate);
    }
    if (parseClock(time) == null) {
      errors.add(msg.editorErrTime);
    }
    for (final f in [
      (calories, msg.editorFieldCalories, maxMealCalories),
      (protein, msg.macroProtein, maxMacroGrams),
      (carbs, msg.macroCarbs, maxMacroGrams),
      (fat, msg.macroFat, maxMacroGrams),
    ]) {
      final p = parseNumberField(f.$1, label: f.$2, max: f.$3, l: msg);
      if (!p.ok) errors.add(p.error!);
    }
    if (items.where((i) => !i.isBlank).length > maxItemsPerMeal) {
      errors.add(msg.editorErrTooManyItems('$maxItemsPerMeal'));
    }
    // Number by the row position on SCREEN (blank rows included) — numbering
    // only the filled ones points the user at the wrong row.
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isBlank) continue;
      final n = i + 1;
      for (final f in [
        (it.calories, msg.editorItemFieldCalories(n), maxMealCalories),
        (it.protein, msg.editorItemFieldProtein(n), maxMacroGrams),
        (it.carbs, msg.editorItemFieldCarbs(n), maxMacroGrams),
        (it.fat, msg.editorItemFieldFat(n), maxMacroGrams),
      ]) {
        final p = parseNumberField(f.$1, label: f.$2, max: f.$3, l: msg);
        if (!p.ok) errors.add(p.error!);
      }
    }
    return errors;
  }

  /// The analysis map to persist. Call only when [validate] is empty.
  Map<String, dynamic> toAnalysis() {
    final out = Map<String, dynamic>.from(base);
    num field(String raw, num max) =>
        parseNumberField(raw, label: 'x', max: max).value ?? 0;
    final desc = description.trim();
    out['meal_description'] = desc.isEmpty ? 'Meal' : desc;
    out['total_calories'] = field(calories, maxMealCalories);
    out['total_protein_g'] = field(protein, maxMacroGrams);
    out['total_carbs_g'] = field(carbs, maxMacroGrams);
    out['total_fat_g'] = field(fat, maxMacroGrams);
    // A hand-curated meal is food by definition — see the library note.
    out['is_food'] = true;
    out['food_items'] = [
      for (final it in items.where((i) => !i.isBlank)) it.toMap()
    ];
    return out;
  }
}

/// Description without the display fallback (the editor shows an empty field
/// rather than the literal word "Meal" for an unset description).
String mealDescriptionRaw(Map<String, dynamic> analysis) {
  final d = analysis['meal_description'];
  return d is String ? d.trim() : '';
}

/// True only for a calendar date that actually exists. DateTime.parse is NOT
/// enough: Dart ROLLS OVER out-of-range components ('2026-13-40' parses to
/// 2027-02-09, '2026-02-30' to March 2), which would silently file a meal on
/// a day the user never picked.
bool isRealIsoDate(String raw) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw.trim());
  if (m == null) return false;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return false;
  final dt = DateTime(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

/// 12-hour zero-padded clock, matching the stored/server format.
String formatClock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '${h.toString().padLeft(2, '0')}:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Parse the stored 12-hour clock back to (hour, minute); null when unusable.
({int hour, int minute})? parseClock(String raw) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*([AaPp])\.?[Mm]\.?\s*$')
      .firstMatch(raw);
  if (m == null) return null;
  var h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h < 1 || h > 12 || min > 59) return null;
  final pm = m.group(3)!.toLowerCase() == 'p';
  if (h == 12) h = 0;
  return (hour: pm ? h + 12 : h, minute: min);
}
