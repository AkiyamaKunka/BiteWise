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
///   - an item row the user did not touch keeps every key it was stored
///     with (design R6a): the printed brand, qty and unit the photo model
///     read, a restaurant lookup's `published` flag, a leftover fraction.
///     Fixing a meal's date or name must not strip what the row says about
///     itself. A row the user changed is rebuilt from what the editor shows
///     — a user-curated row makes no printed-brand claim, and its numbers
///     are no longer anyone's published ones.
///   - the rows of a leftover deduction 1.5.0 stored kept the whole
///     plate's protein, carbs and fat (only their kcal was the eaten
///     part); the form shows those rows' eaten part and the save writes
///     it, so the totals derived from the rows never put the uneaten part
///     back (leftover_logic.legacyLeftoverMacroScale).
///   - a draft of a STORED meal carries [MealDraft.expectedRaw], the
///     analysis text it was loaded from: the save is a compare-and-set
///     against it (MealsDao.updateMealFieldsIfUnchanged).
///   - the save is the one moment that knows which rows the USER set, so
///     it writes the usual-foods mark there (usual-foods spec §3.1): a row
///     added here, or a stored row whose numbers the user changed, gains
///     `user {set, at, n, qty}`; a rename keeps the AI's old name as
///     `user.ai_name`. The mark is self-validating (usualMarkValid): it
///     counts only while the row's numbers still equal `n`. A meal typed
///     by hand before 1.6.0 has no marks and taught only while it was
///     never corrected; the save sets `corrected`, so its unchanged rows
///     gain the mark at the meal's own `timestamp` and still teach.
library;

import '../core/coerce.dart';
import '../core/contracts.dart';
import '../core/leftover_logic.dart';
import '../core/usual_foods_logic.dart';
import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';

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
  })  : stored = null,
        _seed = null,
        _loaded = null,
        _macroScale = null;

  /// The first row "Add item" adds to a stored meal with no rows
  /// ([MealDraft.addItem]): its fields are the totals above it, and [_seed]
  /// holds the meal's stored totals.
  MealItemDraft._seeded(
    List<num> this._seed, {
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  })  : name = '',
        stored = null,
        _loaded = null,
        _macroScale = null;

  MealItemDraft._fromStored(Map<String, dynamic> m, [this._macroScale])
      : name = (m['name'] ?? '').toString(),
        calories = _numText(m['estimated_calories']),
        protein = _macroText(m['protein_g'], _macroScale),
        carbs = _macroText(m['carbs_g'], _macroScale),
        fat = _macroText(m['fat_g'], _macroScale),
        stored = m,
        _seed = null,
        _loaded = null {
    _loaded = (name, calories, protein, carbs, fat);
  }

  String name;
  String calories;
  String protein;
  String carbs;
  String fat;

  /// The stored item this row was loaded from; null for a row the user
  /// added.
  final Map<String, dynamic>? stored;

  /// For the first row added to a STORED meal with no rows: the meal's
  /// stored totals (kcal, protein, carbs, fat) the row was seeded with —
  /// the AI's, not the user's. The row is the user's only once one of its
  /// numbers differs from them. Null for every other row.
  final List<num>? _seed;

  /// The five field texts as loaded, to tell an untouched row.
  (String, String, String, String, String)? _loaded;

  /// For a row of a leftover deduction 1.5.0 stored, whose protein, carbs
  /// and fat are still the whole plate's (legacyLeftoverMacroScale): the
  /// share eaten, which the macro fields show and the save writes (the
  /// block is then stamped, [MealDraft.toAnalysis]). Null for every other
  /// row.
  final double? _macroScale;

  /// [macroScale]: see [_macroScale].
  static MealItemDraft fromMap(Map<String, dynamic> m, {double? macroScale}) =>
      MealItemDraft._fromStored(m, macroScale);

  /// A stored row whose five fields still read exactly as loaded.
  bool get untouched =>
      stored != null && _loaded == (name, calories, protein, carbs, fat);

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

  /// The item to persist (usual-foods spec §3.1 for `user`):
  ///   * an [untouched] stored row keeps every key it was stored with,
  ///     `user` included byte for byte, its name and four numbers
  ///     normalized exactly as [toMap] writes them (a numeric string
  ///     becomes the number it already read as);
  ///   * a row the user ADDED is [toMap] plus `user {set: true, at: now,
  ///     n: its four numbers, qty: 1}`: every number on it is the user's —
  ///     except the first row seeded from a loaded meal's totals
  ///     ([MealDraft.addItem]) while it still holds them, and a row under
  ///     [kUsualMinKcal] kcal (one left blank reads 0), which get no
  ///     `user`;
  ///   * a stored row the user TOUCHED is [toMap] plus a `user` map: a new
  ///     `set`/`at`/`n` when any number differs numerically from the
  ///     stored row ("450" equals 450), else the stored ones while they
  ///     are still valid ([usualMarkValid]); `qty` from the stored mark or
  ///     the stored row (toMap drops `qty`); `ai_name` from the stored
  ///     mark, else the stored name when the name changed. `user` is
  ///     written only when it says something: `set`, `ai_name`, or a
  ///     count other than 1.
  /// [now] stamps `at` (UTC, ms); null reads the device clock.
  ///
  /// [typedAt]: the row is of a meal typed by hand before 1.6.0 and never
  /// corrected since ([MealDraft.fromMeal]); its unmarked rows taught
  /// through that alone, and this save sets `corrected`. A stored row
  /// with no `user` map whose numbers did not change gains
  /// `user {set: true, at: typedAt, n, qty: 1}` when it taught that way
  /// (qty 1, not published, at least [kUsualMinKcal] kcal), so a save
  /// with the numbers as typed keeps them the user's.
  Map<String, dynamic> toStoredMap([DateTime? now, String? typedAt]) {
    final src = stored;
    if (src != null && untouched) {
      final out = {
        for (final e in src.entries) e.key: e.value,
        ...toMap(),
      };
      if (typedAt != null && _typedRowTaught(src, out)) {
        out['user'] = {
          'set': true,
          'at': typedAt,
          'n': _numbersOf(out),
          'qty': 1,
        };
      }
      return out;
    }
    final out = toMap();
    final when = now ?? DateTime.now();
    final numbers = [
      out['estimated_calories'] as num,
      out['protein_g'] as num,
      out['carbs_g'] as num,
      out['fat_g'] as num,
    ];
    if (src == null) {
      final seed = _seed;
      // A row seeded from a stored meal's totals and never changed holds
      // the meal's numbers, not the user's.
      if (seed != null && !_differs(numbers, seed)) return out;
      // A row whose numbers were left blank (all four read 0), or that is
      // under the usual-foods minimum, says no number of the user's: a
      // name-only "Toast" row must never teach 0 kcal toast.
      if (numbers[0] < kUsualMinKcal) return out;
      out['user'] = {
        'set': true,
        'at': usualStamp(when),
        'n': numbers,
        'qty': 1,
      };
      return out;
    }
    final user = <String, dynamic>{};
    // A legacy leftover row is compared with the eaten macros it showed:
    // a rename alone sets no number of the user's.
    final scale = _macroScale;
    final storedNumbers = [
      _storedNumber(src['estimated_calories']),
      _scaledMacro(src['protein_g'], scale),
      _scaledMacro(src['carbs_g'], scale),
      _scaledMacro(src['fat_g'], scale),
    ];
    final changed = _differs(numbers, storedNumbers);
    final storedUser = src['user'];
    if (changed) {
      user['set'] = true;
      user['at'] = usualStamp(when);
      user['n'] = numbers;
    } else if (storedUser is Map && usualMarkValid(src, when)) {
      user['set'] = true;
      user['at'] = storedUser['at'];
      user['n'] = List<Object?>.from(storedUser['n'] as List);
    } else if (typedAt != null && _typedRowTaught(src, out)) {
      user['set'] = true;
      user['at'] = typedAt;
      user['n'] = numbers;
    }
    final qty = usualItemQty(src);
    user['qty'] = qty;
    final storedAiName = storedUser is Map ? storedUser['ai_name'] : null;
    if (storedAiName is String && storedAiName.trim().isNotEmpty) {
      user['ai_name'] = storedAiName;
    } else {
      final storedName = src['name'] is String ? src['name'] as String : '';
      final aiName = cleanShortText(storedName, kUsualAiNameMax);
      if (name.trim() != storedName.trim() && aiName.isNotEmpty) {
        user['ai_name'] = aiName;
      }
    }
    if (user.containsKey('set') || user.containsKey('ai_name') || qty != 1) {
      out['user'] = user;
    }
    return out;
  }
}

/// The four numbers of a row as [MealItemDraft.toMap] writes them.
List<num> _numbersOf(Map<String, dynamic> row) => [
      row['estimated_calories'] as num,
      row['protein_g'] as num,
      row['carbs_g'] as num,
      row['fat_g'] as num,
    ];

/// A stored row of a hand-typed meal that taught its numbers with no mark
/// (usual_foods_logic _recordOf, the unmarked hand-typed path): no `user`
/// map, not published, a count of exactly 1, and [written]'s kcal at
/// least [kUsualMinKcal].
bool _typedRowTaught(Map<String, dynamic> src, Map<String, dynamic> written) =>
    src['user'] is! Map &&
    src['published'] != true &&
    coerceQty(src['qty']) == 1 &&
    (written['estimated_calories'] as num) >= kUsualMinKcal;

/// Longest kept `user.ai_name`, in code points.
const int kUsualAiNameMax = 80;

/// Some of the four numbers differ numerically ("450" equals 450).
bool _differs(List<num> a, List<num> b) {
  for (var i = 0; i < 4; i++) {
    if ((a[i] - b[i]).abs() > 1e-9) return true;
  }
  return false;
}

/// A stored number as the editor loaded it ([_numText]): a number, or a
/// numeric string; anything else is 0, like a blank field.
num _storedNumber(dynamic v) {
  var n = safeNumberOr(v, null);
  if (n == null && v is String) n = safeNumberOr(num.tryParse(v.trim()), null);
  return n ?? 0;
}

/// A stored macro times [scale] (a legacy leftover row's eaten share) to
/// 0.1 g, as its field shows it; [scale] null is [_storedNumber].
num _scaledMacro(dynamic v, double? scale) {
  final n = _storedNumber(v);
  if (scale == null) return n;
  return double.parse((n * scale).toStringAsFixed(1));
}

/// Field text for a stored macro, scaled as [_scaledMacro] says; a value
/// the field would show blank stays blank.
String _macroText(dynamic v, double? scale) {
  final t = _numText(v);
  if (scale == null || t.isEmpty) return t;
  return _numText(_scaledMacro(v, scale));
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

  /// The stored analysis TEXT [base] was decoded from (MealSnapshot
  /// .rawAnalysis), once the editor has read it: what the save of an
  /// existing meal compares against, so a meal that changed while it was
  /// open is never overwritten with this older copy. Null for a new meal,
  /// and until the read confirmed the row still matches this draft.
  String? expectedRaw;

  /// The totals the meal was loaded with ([fromMeal]: a stored meal, or the
  /// describe preview's model estimate), as the editor reads them; null for
  /// a new hand-typed meal ([blank]), whose totals are all the user's.
  List<num>? _loadedTotals;

  /// For a stored meal typed by hand (app_manual / app_manual_photo),
  /// never corrected, with no leftover block: its `timestamp`, the moment
  /// its unmarked rows were the user's numbers ([MealItemDraft
  /// .toStoredMap] `typedAt`). Null for every other draft, the describe
  /// preview's (id 0, manual_text) included.
  DateTime? _typedAt;

  static MealDraft fromMeal(Meal meal) => MealDraft(
        description: mealDescriptionRaw(meal.analysis),
        dateIso: meal.date,
        time: meal.time,
        calories: _numText(meal.analysis['total_calories']),
        protein: _numText(meal.analysis['total_protein_g']),
        carbs: _numText(meal.analysis['total_carbs_g']),
        fat: _numText(meal.analysis['total_fat_g']),
        items: [
          for (final m in safeFoodItems(meal.analysis))
            MealItemDraft.fromMap(m,
                macroScale: legacyLeftoverMacroScale(meal.analysis, m))
        ],
        base: Map<String, dynamic>.from(meal.analysis),
      )
        .._loadedTotals = [
          for (final k in const [
            'total_calories',
            'total_protein_g',
            'total_carbs_g',
            'total_fat_g',
          ])
            _storedNumber(meal.analysis[k]),
        ]
        .._typedAt = meal.id > 0 &&
                (meal.source == MealSource.appManual ||
                    meal.source == MealSource.appManualPhoto) &&
                !meal.corrected &&
                meal.analysis['leftover'] is! Map
            ? DateTime.tryParse(meal.timestamp)
            : null;

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
  ///
  /// The seeded row is the user's (a usual-foods mark at save) on a new
  /// hand-typed meal; on a loaded meal only once one of its numbers
  /// differs from the totals the meal was loaded with, which are the AI's
  /// (or the stored meal's), never typed in this session.
  MealItemDraft addItem() {
    final loaded = _loadedTotals;
    final it = items.isNotEmpty
        ? MealItemDraft()
        : loaded != null
            ? MealItemDraft._seeded(loaded,
                calories: calories, protein: protein, carbs: carbs, fat: fat)
            : MealItemDraft(
                calories: calories, protein: protein, carbs: carbs, fat: fat);
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
  /// [now] stamps the usual-foods marks of the rows the user set
  /// ([MealItemDraft.toStoredMap]); null reads the device clock.
  Map<String, dynamic> toAnalysis({DateTime? now}) {
    final when = now ?? DateTime.now();
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
    // A typed meal's moment, as a mark's `at`, unless it is more than a
    // day ahead (it taught nothing yet: usualMarkValid would void it).
    final typed = _typedAt;
    final typedAt =
        typed == null || typed.isAfter(when.add(const Duration(days: 1)))
            ? null
            : usualStamp(typed);
    final kept = items.where((i) => !i.isBlank).toList();
    out['food_items'] = [
      for (final it in kept) it.toStoredMap(when, typedAt)
    ];
    // A leftover deduction 1.5.0 stored kept the rows' macros whole; the
    // form showed (and these rows now hold) the eaten part, so the block
    // says so and the next load does not scale them again.
    final leftover = out['leftover'];
    if (leftover is Map && kept.any((i) => i._macroScale != null)) {
      out['leftover'] = Map<String, dynamic>.from(leftover)
        ..[kLeftoverItemMacrosScaled] = true;
    }
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
