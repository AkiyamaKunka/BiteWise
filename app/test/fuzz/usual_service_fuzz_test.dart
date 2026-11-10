// Fuzz: the usual-foods service under random operation sequences
// (usual-foods spec §3.5-§3.6, §4.3, §5; services/usual/usual_foods.dart).
//
// A real SqfliteMealsDao over an in-memory SQLite database, a UsualChoices
// over mock preferences and one injected clock are driven by seeded-random
// sequences of: a photo saved (stripped as the pipeline strips it, or raw
// as an import leaves it; with or without the meals signal), a meal typed
// in the editor, an editor edit, Use, Use of an offer shown earlier, Undo
// of a Use, Keep AI estimate, Log again, Undo of a log, Hide, Show again,
// a deleted meal, and the clock moving by minutes, hours or days (the
// starts sit just before midnight, a year end and both US daylight-saving
// changes).
//
// After every step: every stored meal decodes; the offers the service
// gives are exactly the spec's (the oracle of usual_history.dart, over
// the rows as stored) and only ever for today's uncorrected photo meals;
// the list never shows a hidden meal or more than 20 rows. Each operation
// checks its own promise (an Undo right after Use puts the stored text
// back, an Undo right after a log removes exactly that meal, a re-log's
// totals are its item sums, ...). A failure prints the seed and the
// operations cut down to the ones that still fail.
import 'dart:convert';
import 'dart:math';

import 'package:calorie_tracker/core/coerce.dart' show isoDate;
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart'
    show dropAssistClaims;
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/data/meals_logic.dart' show mealFromRow;
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:calorie_tracker/ui/meal_edit_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fuzz_support.dart';
import 'usual_history.dart';

// ─── Operations, as data (so a failing sequence can be cut down) ───────

enum Kind {
  photo,
  typed,
  edit,
  use,
  useHeld,
  undoUse,
  decline,
  logAgain,
  undoLog,
  hide,
  unhide,
  delete,
  advance,
}

final class Op {
  const Op(
    this.kind, {
    this.a = 0,
    this.b = 0,
    this.c = 0,
    this.flag = false,
    this.analysis,
    this.rows = const [],
    this.minutes = 0,
    this.target = 0,
  });
  final Kind kind;

  /// Picks, taken modulo what exists when the operation runs.
  final int a, b, c;
  final bool flag;

  /// A photo's analysis.
  final Map<String, dynamic>? analysis;

  /// Rows typed in the editor: name, kcal, protein, carbs, fat.
  final List<(String, num, num, num, num)> rows;
  final int minutes;

  /// An edit's meal: 0 any, 1 the meal of the last Use, 2 the meal logged
  /// last.
  final int target;

  Map<String, dynamic> toJson() => {
    'op': kind.name,
    if (a != 0) 'a': a,
    if (b != 0) 'b': b,
    if (c != 0) 'c': c,
    if (flag) 'flag': true,
    if (analysis != null) 'analysis': analysis,
    if (rows.isNotEmpty) 'rows': [for (final r in rows) '$r'],
    if (minutes != 0) 'minutes': minutes,
    if (target != 0) 'target': target,
  };
}

final class Case {
  Case(this.start, this.seeds, this.ops);
  final DateTime start;
  final List<Meal> seeds;
  final List<Op> ops;

  String show() => dump({
    'start': start.toIso8601String(),
    'seeds': [for (final m in seeds) mealJson(m)],
    'ops': [for (final o in ops) o.toJson()],
  });
}

/// Local clocks a sequence starts at: a plain noon, minutes before
/// midnight, the evenings before both US daylight-saving changes and the
/// EU ones, the last night of a year.
const List<(int, int, int, int, int)> _starts = [
  (2026, 11, 7, 12, 30), (2026, 11, 7, 7, 40), (2026, 11, 6, 23, 50), //
  (2026, 10, 31, 22, 0), (2026, 11, 1, 0, 30), (2027, 3, 13, 21, 0), //
  (2027, 3, 14, 1, 30), (2026, 12, 31, 22, 30), (2026, 10, 24, 23, 0), //
  (2028, 2, 28, 23, 40),
];

const List<int> _spans = [
  1, 1, 2, 5, 5, 15, 30, 45, 90, 120, 200, 600, //
  24 * 60, 2 * 24 * 60, 3 * 24 * 60, 40 * 24 * 60, 95 * 24 * 60,
];

Case anyCase(Random r) {
  final (y, mo, d, h, mi) = r.pick(_starts);
  final start = DateTime(y, mo, d, h, mi + r.nextInt(8), r.nextInt(60));
  final g = HistoryGen(
    r,
    now: start,
    wild: r.pick(const [0.0, 0.0, 0.05, 0.15]),
    count: r.pick(const [0, 3, 8, 15]),
    vocab: r.pick(const [2, 3, 5]),
  );
  final seeds = <Meal>[
    for (var i = 0; i < g.count; i++) g.anyMeal(),
    for (var i = r.pick(const [0, 1, 2]); i > 0; i--) ...g.plantOffer(),
    if (r.chance(0.3)) ...g.plantAlias(),
    if (r.chance(0.5)) ...g.plantRepeats(sizes: const [1, 2, 3]),
  ]..shuffle(r);

  (String, num, num, num, num) row() {
    final food = r.pick(g.foods);
    final kcalOnly = r.chance(0.2);
    return (
      r.chance(0.05) ? r.pick(const ['', 'Snack', 'Pb']) : g.nameOf(food),
      r.chance(0.08)
          ? r.pick(const [0, 5, 9])
          : (g.baseKcal(food) * (0.6 + r.nextDouble())).round(),
      kcalOnly ? 0 : g.grams(),
      kcalOnly ? 0 : g.grams(),
      kcalOnly ? 0 : g.grams(),
    );
  }

  Op photo() {
    final items = <Object?>[
      for (var i = r.pick(const [1, 1, 1, 2, 2, 3]); i > 0; i--)
        g.item(g.today, marked: r.chance(0.2) ? 0.5 : 0.0),
    ];
    return Op(
      Kind.photo,
      a: r.nextInt(1000),
      b: r.nextInt(1000),
      c: r.nextInt(1000),
      // Stripped as the photo pipeline strips a model's claims; else
      // raw, as an import or an older build left it.
      flag: r.chance(0.8),
      analysis: g.analysisOf(items, clean: r.chance(0.8)),
    );
  }

  final ops = <Op>[];
  final n = r.between(10, 45);
  while (ops.length < n) {
    final roll = r.nextInt(100);
    int pick() => r.nextInt(1000);
    if (roll < 20) {
      ops.add(photo());
    } else if (roll < 26) {
      ops.add(
        Op(
          Kind.typed,
          a: pick(),
          flag: r.chance(0.3),
          rows: [for (var i = r.between(1, 3); i > 0; i--) row()],
        ),
      );
    } else if (roll < 40) {
      ops.add(
        Op(
          Kind.edit,
          a: pick(),
          b: pick(),
          c: pick(),
          flag: r.chance(0.7),
          rows: [row()],
        ),
      );
    } else if (roll < 56) {
      ops.add(Op(Kind.use, a: pick(), b: pick()));
      if (r.chance(0.5)) {
        ops.add(Op(Kind.undoUse, flag: true, b: pick()));
      } else if (r.chance(0.4)) {
        // An edit of that meal, then the Undo: refused when the edit
        // moved a number Use wrote.
        ops
          ..add(
            Op(
              Kind.edit,
              b: r.pick(const [0, 0, 1, 2, 5]),
              c: pick(),
              flag: r.chance(0.7),
              rows: [row()],
              target: 1,
            ),
          )
          ..add(const Op(Kind.undoUse, flag: true));
      }
    } else if (roll < 61) {
      ops.add(Op(Kind.useHeld, a: pick()));
    } else if (roll < 66) {
      ops.add(Op(Kind.undoUse, a: pick(), b: pick()));
    } else if (roll < 70) {
      ops.add(Op(Kind.decline, a: pick()));
    } else if (roll < 80) {
      ops.add(Op(Kind.logAgain, a: pick(), flag: r.chance(0.8)));
      if (r.chance(0.4)) {
        ops.add(const Op(Kind.undoLog, flag: true));
      } else if (r.chance(0.2)) {
        ops
          ..add(Op(Kind.edit, b: pick(), c: pick(), rows: [row()], target: 2))
          ..add(const Op(Kind.undoLog, flag: true));
      }
    } else if (roll < 84) {
      ops.add(Op(Kind.undoLog, a: pick()));
    } else if (roll < 87) {
      ops.add(Op(Kind.hide, a: pick()));
    } else if (roll < 90) {
      ops.add(Op(Kind.unhide, a: pick()));
    } else if (roll < 93) {
      ops.add(Op(Kind.delete, a: pick()));
    } else {
      // To a few minutes past the next midnight, or on by a span.
      ops.add(
        Op(
          Kind.advance,
          flag: r.chance(0.25),
          minutes: r.pick(_spans) + r.nextInt(3),
        ),
      );
    }
  }
  return Case(start, seeds, ops);
}

// ─── What a run saw (so no promise held for want of cases) ─────────────

class Seen {
  int steps = 0;
  int offersChecked = 0;
  int offers = 0;
  int written = 0;
  int kcalOnlyWritten = 0;
  int undone = 0;
  int undoneLater = 0;
  int undoRefused = 0;
  int reordered = 0;
  int heldRefused = 0;
  int heldWritten = 0;
  int staleRaw = 0;
  int declined = 0;
  int logged = 0;
  int logsUndone = 0;
  int logUndoRefused = 0;
  int hidden = 0;
  int shownAgain = 0;
  int edits = 0;
  int typed = 0;
  int deleted = 0;
  int midnights = 0;
  int rows = 0;
  int askedAgain = 0;
  int raced = 0;
  int listsChecked = 0;
}

// ─── The world one sequence runs in ────────────────────────────────────

const List<String> _logKeys = [
  'is_food', 'meal_description', 'food_items', 'total_calories', //
  'total_protein_g', 'total_carbs_g', 'total_fat_g', 'logged_again',
];

bool _takes(Map<String, dynamic> a) => a['restaurant_context'] == 'restaurant';

/// The real DAO, with one seam: [beforeCompareAndSet] runs once between a
/// service's read of a meal and its compare-and-set write, as another
/// writer (the editor, a lookup, the background run) would.
class RacingDao extends SqfliteMealsDao {
  RacingDao(super.db, {super.clock});
  Future<void> Function(int mealId)? beforeCompareAndSet;

  @override
  Future<bool> updateMealAnalysisIfUnchanged(
    int mealId, {
    required String expectedRaw,
    required Map<String, dynamic> analysis,
  }) async {
    final race = beforeCompareAndSet;
    beforeCompareAndSet = null;
    if (race != null) await race(mealId);
    return super.updateMealAnalysisIfUnchanged(
      mealId,
      expectedRaw: expectedRaw,
      analysis: analysis,
    );
  }
}

class World {
  World(this.db, this.clock, this.seen) {
    dao = RacingDao(db, clock: () => clock);
  }

  final Database db;
  final Seen seen;
  DateTime clock;
  late final RacingDao dao;
  late final UsualChoices choices;
  late final UsualFoods usual;
  final ValueNotifier<int> signal = ValueNotifier<int>(0);

  /// False while the service may hold an index built before the clock
  /// moved, or before a save that bumped no signal: its offers are then
  /// right for that older moment, not for the rows as they are now.
  bool current = true;
  int _hashes = 0;

  final List<UsualOffer> held = [];
  final List<({UsualAcceptResult result, String rawBefore, String rawAfter})>
  uses = [];
  final List<UsualLogResult> logs = [];
  List<UsualMeal> screen = [];
  final List<String> trace = [];

  Future<void> open() async {
    SharedPreferences.setMockInitialValues({});
    choices = UsualChoices(
      await SharedPreferences.getInstance(),
      clock: () => clock,
    );
    usual = UsualFoods(
      dao: dao,
      choices: choices,
      mealsChanged: signal,
      onMealsChanged: () => signal.value++,
      lookupTakesIt: _takes,
      clock: () => clock,
    );
  }

  String get today => isoDate(clock);

  void bump() {
    signal.value++;
    current = true;
  }

  Future<List<Map<String, Object?>>> stored() =>
      db.query('meals', orderBy: 'id');

  Future<Map<String, Object?>?> row(int id) async {
    final rows = await db.query('meals', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.single;
  }

  // ── The operations ──

  Future<void> photo(Op op) async {
    final a = deepCopy(op.analysis) as Map<String, dynamic>;
    if (op.flag) dropAssistClaims(a);
    final hash = op.b % 3 == 0
        ? (++_hashes).toRadixString(16).padLeft(32, '0')
        : '';
    final id = await dao.saveMeal(
      Meal(
        id: 0,
        date: today,
        time: formatClock(clock),
        timestamp: clock.toIso8601String(),
        source: op.a.isEven ? MealSource.appWatch : MealSource.appPhoto,
        imageHash: hash,
        fileId: hash.isEmpty ? '' : 'asset-$hash',
        analysis: a,
      ),
      markStatus: hash.isEmpty ? null : IngestionStatus.saved,
    );
    // The watcher's background save bumps no signal.
    if (op.c % 4 == 0) {
      current = false;
    } else {
      bump();
    }
    trace.add('photo → meal $id${op.c % 4 == 0 ? ' (no signal)' : ''}');
  }

  Future<void> typed(Op op) async {
    final draft = MealDraft.blank(clock)..description = 'Typed ${op.a}';
    for (final (name, kcal, p, c, f) in op.rows) {
      draft.addItem()
        ..name = name
        ..calories = '$kcal'
        ..protein = '$p'
        ..carbs = '$c'
        ..fat = '$f';
    }
    final sums = draft.itemTotals();
    draft
      ..calories = '${sums.calories}'
      ..protein = '${sums.protein}'
      ..carbs = '${sums.carbs}'
      ..fat = '${sums.fat}';
    expect(draft.validate(), isEmpty);
    final analysis = draft.toAnalysis(now: clock);
    dropAssistClaims(analysis, keepUserMarks: true);
    final id = await dao.saveMeal(
      Meal(
        id: 0,
        date: draft.dateIso,
        time: draft.time,
        timestamp: clock.toIso8601String(),
        source: op.flag ? MealSource.appManualPhoto : MealSource.appManual,
        analysis: analysis,
      ),
    );
    bump();
    seen.typed++;
    trace.add('typed → meal $id');
  }

  Future<void> edit(Op op) async {
    final all = await stored();
    if (all.isEmpty) return;
    var id = all[op.a % all.length]['id'] as int;
    if (op.target == 1 && uses.isNotEmpty) id = uses.last.result.mealId;
    if (op.target == 2 && logs.isNotEmpty) id = logs.last.mealId;
    final snap = await dao.mealSnapshot(id);
    if (snap == null) return;
    final draft = MealDraft.fromMeal(snap.meal)..expectedRaw = snap.rawAnalysis;
    final (name, kcal, p, c, f) = op.rows.single;
    final rows = draft.items;
    final what = op.b % 8;
    MealItemDraft? changed;
    switch (what) {
      case 0 when rows.isNotEmpty:
        changed = rows[op.c % rows.length]..calories = '$kcal';
      case 1 when rows.isNotEmpty:
        changed = rows[op.c % rows.length]
          ..protein = '$p'
          ..carbs = '$c'
          ..fat = '$f';
      case 2 when rows.isNotEmpty:
        rows[op.c % rows.length].name = name;
      case 3:
        draft.addItem()
          ..name = name
          ..calories = '$kcal'
          ..protein = '$p'
          ..carbs = '$c'
          ..fat = '$f';
      case 4 when rows.isNotEmpty:
        rows.removeAt(op.c % rows.length);
      case 6:
        draft.dateIso = op.c.isEven ? today : dayIso(clock, -1);
        draft.time = formatClock(clock);
      case 7 when rows.isNotEmpty:
        // The same number, typed another way: the row is touched, its
        // numbers are not.
        final it = rows[op.c % rows.length];
        if (it.calories.isNotEmpty && !it.calories.contains('.')) {
          it.calories = '${it.calories}.0';
        }
      default:
        break; // a plain Save
    }
    if (op.flag && rows.any((i) => !i.isBlank)) {
      final sums = draft.itemTotals();
      draft
        ..calories = '${sums.calories}'
        ..protein = '${sums.protein}'
        ..carbs = '${sums.carbs}'
        ..fat = '${sums.fat}';
    }
    if (draft.validate().isNotEmpty) {
      trace.add('edit of meal $id refused by the form');
      return;
    }
    final analysis = draft.toAnalysis(now: clock);
    final ok = await dao.updateMealFieldsIfUnchanged(
      id,
      expectedRaw: snap.rawAnalysis,
      analysis: analysis,
      date: draft.dateIso.trim(),
      time: draft.time.trim(),
    );
    expect(ok, isTrue, reason: 'an editor save over an unchanged meal');
    bump();
    final after = (await dao.mealSnapshot(id))!;
    expect(after.corrected, isTrue);
    // A number the user changed is theirs: the row says so with a mark
    // that vouches for it (rows under 10 kcal say nothing).
    if (changed != null && !changed.untouched) {
      final at = draft.items.where((i) => !i.isBlank).toList().indexOf(changed);
      final before = changed.stored;
      final saved = oItems(after.meal.analysis)[at];
      final was = before == null ? null : oNumbers(before);
      final now = oNumbers(saved);
      if (was != null && was != now) {
        expect(
          oMarkValid(saved, clock),
          isTrue,
          reason: 'the edited row carries no valid mark: ${dump(saved)}',
        );
        expect((saved['user'] as Map)['at'], usualStamp(clock));
      }
    }
    seen.edits++;
    trace.add('edit $what of meal $id');
  }

  /// Arms another writer: it rewrites the meal (as an editor save does)
  /// right before the service's next compare-and-set. Returns the text it
  /// will have stored.
  String armRace(Map<String, Object?> row) {
    final other = {
      ...jsonDecode(row['analysis'] as String) as Map<String, dynamic>,
      'meal_description': 'Changed meanwhile ${seen.steps}',
    };
    dao.beforeCompareAndSet = (id) => dao.updateMealAnalysis(id, other);
    return jsonEncode(other);
  }

  Future<Map<int, UsualOffer>> offersNow() async =>
      usual.offersFor([for (final r in await stored()) mealFromRow(r)]);

  /// What every Use must leave behind, whatever it answered.
  Future<void> _afterUse(
    UsualOffer shown,
    UsualAcceptResult r,
    Map<String, Object?>? before, {
    required bool fresh,
  }) async {
    final id = shown.mealId;
    final after = await row(id);
    expect(r.mealId, id);
    if (r.status != UsualAcceptStatus.written) {
      expect(r.undo, isNull);
      expect(
        after?['analysis'],
        before?['analysis'],
        reason: 'a Use that was not written changed the meal',
      );
      expect(after?['corrected'], before?['corrected']);
      if (before == null) expect(r.status, UsualAcceptStatus.gone);
      return;
    }
    // "offersFor never returns an offer whose accept would write a meal
    // that is not today's uncorrected photo meal" — nor does a Use of an
    // offer shown earlier.
    expect(before, isNotNull);
    final was = mealFromRow(before!);
    expect(oPhoto(was), isTrue, reason: 'Use wrote a ${was.source} meal');
    expect(was.corrected, isFalse, reason: 'Use wrote a corrected meal');
    expect(was.date, today, reason: 'Use wrote a meal of another day');
    final isNow = mealFromRow(after!);
    expect(isNow.corrected, isTrue, reason: 'Use sets corrected');
    final undo = r.undo!;
    expect(
      sameBytes(isNow.analysis, jsonDecode(jsonEncode(undo.after))),
      isTrue,
      reason: 'the stored meal is not what Use says it wrote',
    );
    expect(sameBytes(was.analysis, undo.before), isTrue);
    // The items shown are the items written, with the numbers shown.
    final wasItems = oItems(was.analysis);
    final nowItems = oItems(isNow.analysis);
    expect(undo.indices, [for (final i in shown.items) i.index]);
    num dk = 0;
    for (final i in shown.items) {
      expect(
        oNumbers(wasItems[i.index]),
        i.ai,
        reason: 'the AI numbers were not the ones shown',
      );
      final wrote = oNumbers(nowItems[i.index]);
      expect(wrote.kcal, i.mine.kcal);
      if (i.kcalOnly) {
        expect(
          (wrote.p, wrote.c, wrote.f),
          (i.ai.p, i.ai.c, i.ai.f),
          reason: 'a kcal-only Use changed macros',
        );
        expect(oMarkValid(nowItems[i.index], clock), isFalse);
        seen.kcalOnlyWritten++;
      } else {
        expect(wrote, i.mine);
        expect(
          oMarkValid(nowItems[i.index], clock),
          isTrue,
          reason: 'Use left no valid mark',
        );
      }
      dk += i.mine.kcal - i.ai.kcal;
    }
    for (var i = 0; i < wasItems.length; i++) {
      if (undo.indices.contains(i)) continue;
      expect(
        sameBytes(nowItems[i], wasItems[i]),
        isTrue,
        reason: 'Use changed a row it did not offer',
      );
    }
    // The totals moved by the item deltas.
    expect(r.beforeKcal, oNum(was.analysis['total_calories']));
    expect(r.afterKcal, (r.beforeKcal + dk).round());
    expect(oNum(isNow.analysis['total_calories']), r.afterKcal);
    // And the meal is never offered again.
    expect(
      (await offersNow()).containsKey(id),
      isFalse,
      reason: 'a second offer after Use',
    );
    uses.add((
      result: r,
      rawBefore: before['analysis'] as String,
      rawAfter: after['analysis'] as String,
    ));
    current = true; // accept signalled
    fresh ? seen.written++ : seen.heldWritten++;
  }

  Future<void> use(Op op) async {
    final offers = await offersNow();
    if (offers.isEmpty) return;
    final shown = offers.values.elementAt(op.a % offers.length);
    held.add(shown);
    final before = await row(shown.mealId);
    final raw = before!['analysis'] as String;
    final mode = op.b % 6;
    if (mode == 5) {
      // Another writer saves the meal between Use's read and its write:
      // that writer wins, whole.
      final theirs = armRace(before);
      final r = await usual.accept(shown.mealId, shown: shown);
      expect(dao.beforeCompareAndSet, isNull, reason: 'the race was run');
      expect(r.status, UsualAcceptStatus.conflict);
      expect(r.undo, isNull);
      expect(
        (await row(shown.mealId))!['analysis'],
        theirs,
        reason: 'Use wrote over a meal that changed under it',
      );
      bump(); // the other writer's signal
      seen.raced++;
      trace.add('use on meal ${shown.mealId}: lost a race');
      return;
    }
    final r = await usual.accept(
      shown.mealId,
      shown: shown,
      expectedRaw: mode == 3 ? raw : (mode == 4 ? '$raw ' : null),
    );
    if (mode == 4) {
      expect(
        r.status,
        UsualAcceptStatus.conflict,
        reason: 'the editor\'s text was stale',
      );
      seen.staleRaw++;
    } else {
      expect(
        r.status,
        UsualAcceptStatus.written,
        reason: 'an offer just shown must be usable',
      );
    }
    await _afterUse(shown, r, before, fresh: true);
    trace.add('use on meal ${shown.mealId}: ${r.status.name}');
  }

  Future<void> useHeld(Op op) async {
    if (held.isEmpty) return;
    final shown = held[op.a % held.length];
    final before = await row(shown.mealId);
    final r = await usual.accept(shown.mealId, shown: shown);
    if (r.status != UsualAcceptStatus.written) seen.heldRefused++;
    await _afterUse(shown, r, before, fresh: false);
    trace.add(
      'use of an earlier offer on meal ${shown.mealId}: '
      '${r.status.name}',
    );
  }

  Future<void> undoUse(Op op) async {
    if (uses.isEmpty) return;
    final at = op.flag ? uses.length - 1 : op.a % uses.length;
    final u = uses[at];
    final id = u.result.mealId;
    final before = await row(id);
    if (op.b % 4 == 1 && before != null && before['analysis'] == u.rawAfter) {
      // Another writer saves the meal between the Undo's read and its
      // write: nothing of the Undo lands.
      final theirs = armRace(before);
      expect(await usual.undoAccept(u.result), isFalse);
      expect(dao.beforeCompareAndSet, isNull, reason: 'the race was run');
      expect(
        (await row(id))!['analysis'],
        theirs,
        reason: 'Undo wrote over a meal that changed under it',
      );
      bump();
      seen.raced++;
      trace.add('undo of the Use on meal $id: lost a race');
      return;
    }
    final signalBefore = signal.value;
    final ok = await usual.undoAccept(u.result);
    final after = await row(id);
    final untouched = before != null && before['analysis'] == u.rawAfter;
    if (untouched) {
      // "undoAccept right after accept restores the stored analysis":
      // every value, and the text byte for byte — except that a row whose
      // `user` map a kcal-only Use removed gets it back as its last key.
      expect(ok, isTrue, reason: 'an Undo over an unchanged meal');
      final restored = jsonDecode(after!['analysis'] as String);
      final original = jsonDecode(u.rawBefore);
      expect(
        sameValue(restored, original),
        isTrue,
        reason: 'Undo left ${after['analysis']}\nwanted ${u.rawBefore}',
      );
      if (after['analysis'] != u.rawBefore) {
        final rows = oItems(original as Map);
        final dropped = u.result.undo!.indices.any((i) {
          final row = rows[i];
          return row.containsKey('user') && row.keys.last != 'user';
        });
        expect(
          dropped,
          isTrue,
          reason: 'Undo left ${after['analysis']}\nwanted ${u.rawBefore}',
        );
        seen.reordered++;
      }
      expect(after['corrected'], 1, reason: 'corrected stays');
      expect(signal.value, signalBefore + 1);
      // A second Undo finds nothing of the Use left, and writes nothing.
      expect(await usual.undoAccept(u.result), isFalse);
      expect((await row(id))!['analysis'], after['analysis']);
      uses.removeAt(at);
      current = true;
      op.flag ? seen.undone++ : seen.undoneLater++;
    } else if (ok) {
      // The meal changed since, but every row Use wrote still held what
      // it wrote: those rows are back.
      final undo = u.result.undo!;
      final rows = oItems(mealFromRow(after!).analysis);
      final was = oItems(undo.before);
      for (final i in undo.indices) {
        expect(oNumbers(rows[i]), oNumbers(was[i]));
        expect(sameValue(rows[i]['user'], was[i]['user']), isTrue);
      }
      uses.removeAt(at);
      current = true;
      seen.undoneLater++;
    } else {
      expect(
        after?['analysis'],
        before?['analysis'],
        reason: 'a refused Undo changed the meal',
      );
      seen.undoRefused++;
    }
    trace.add('undo of the Use on meal $id: $ok');
  }

  Future<void> decline(Op op) async {
    final offers = await offersNow();
    if (offers.isEmpty) return;
    final offer = offers.values.elementAt(op.a % offers.length);
    held.add(offer);
    final before = await stored();
    await usual.decline(offer);
    expect(
      dump(await stored()),
      dump(before),
      reason: 'Keep AI estimate wrote a meal',
    );
    expect(
      (await offersNow()).containsKey(offer.mealId),
      isFalse,
      reason: 'a declined meal is offered again',
    );
    seen.declined++;
    trace.add('decline on meal ${offer.mealId}');
  }

  Future<void> relist() async {
    usual.invalidate(); // as the screen does when it opens
    current = true;
    final list = await usual.frequentMeals();
    screen = [...list.around, ...list.more];
  }

  Future<void> logAgain(Op op) async {
    if (op.flag) await relist();
    if (screen.isEmpty) return;
    final m = screen[op.a % screen.length];
    final recent = await usual.loggedRecently(m);
    if (recent != null) {
      expect(usualLooselyShares(m.template.analysis, recent.analysis), isTrue);
      final c = parseClock(recent.time)!;
      final day = DateTime.parse(recent.date);
      final at = DateTime(day.year, day.month, day.day, c.hour, c.minute);
      expect(
        clock.difference(at).abs() <= const Duration(hours: 3),
        isTrue,
        reason: 'logged at ${recent.date} ${recent.time}, now $clock',
      );
      seen.askedAgain++;
    }
    final before = {for (final r in await stored()) r['id'] as int};
    final signalBefore = signal.value;
    final r = await usual.logAgain(m);
    expect(r, isNotNull);
    final after = await stored();
    // One more meal, and exactly that one.
    expect({for (final r in after) r['id'] as int}, {...before, r!.mealId});
    expect(before.contains(r.mealId), isFalse);
    expect(signal.value, signalBefore + 1);
    current = true;
    final row = after.singleWhere((x) => x['id'] == r.mealId);
    expect(row['source'], MealSource.appRepeat);
    expect(row['date'], today);
    expect(row['time'], formatClock(clock));
    expect(row['corrected'], 0);
    expect(row['image_hash'], '');
    expect(row['file_id'], '');
    expect(row['analysis'], r.rawAnalysis);
    final a = jsonDecode(row['analysis'] as String) as Map<String, dynamic>;
    expect(a.keys.toList(), _logKeys);
    expect(a['logged_again'], usualStamp(clock));
    // "Totals equal item sums wherever the code promises it."
    final items = oItems(a);
    if (items.isNotEmpty) {
      num k = 0, p = 0, c = 0, f = 0;
      for (final it in items) {
        final n = oNumbers(it);
        expect(n.kcal >= 0 && n.p >= 0 && n.c >= 0 && n.f >= 0, isTrue);
        k += n.kcal;
        p += n.p;
        c += n.c;
        f += n.f;
        if (it['user'] case final Map user when user['set'] == true) {
          expect(
            oMarkValid(it, clock),
            isTrue,
            reason: 'the re-log carries a void mark: ${dump(it)}',
          );
        }
      }
      expect(a['total_calories'], k.round());
      expect(a['total_protein_g'], (p * 10).round() / 10);
      expect(a['total_carbs_g'], (c * 10).round() / 10);
      expect(a['total_fat_g'], (f * 10).round() / 10);
    }
    expect(r.kcal, a['total_calories']);
    if (op.flag) {
      expect(r.kcal, m.numbers.kcal, reason: 'the row showed another number');
    }
    // It is now a meal logged within the last 3 hours that shares a food.
    expect(await usual.loggedRecently(m), isNotNull);
    logs.add(r);
    seen.logged++;
    trace.add('log again "${m.title}" → meal ${r.mealId}');
  }

  Future<void> undoLog(Op op) async {
    if (logs.isEmpty) return;
    final at = op.flag ? logs.length - 1 : op.a % logs.length;
    final r = logs[at];
    final before = await stored();
    final own = before.where((x) => x['id'] == r.mealId).toList();
    final intact =
        own.isNotEmpty &&
        own.single['analysis'] == r.rawAnalysis &&
        own.single['source'] == MealSource.appRepeat;
    final ok = await usual.undoLog(r);
    final after = await stored();
    if (intact) {
      // "undoLog right after logAgain restores the meal count and removes
      // exactly that id."
      expect(ok, isTrue, reason: 'an Undo over the meal as logged');
      expect(
        dump(after),
        dump([
          for (final x in before)
            if (x['id'] != r.mealId) x,
        ]),
      );
      logs.removeAt(at);
      current = true;
      seen.logsUndone++;
    } else {
      expect(ok, isFalse, reason: 'the meal changed since or is gone');
      expect(dump(after), dump(before));
      seen.logUndoRefused++;
    }
    trace.add('undo of the log of meal ${r.mealId}: $ok');
  }

  Future<void> hide(Op op) async {
    await relist();
    if (screen.isEmpty) return;
    final m = screen[op.a % screen.length];
    await usual.hide(m);
    final list = await usual.frequentMeals();
    expect(
      [...list.around, ...list.more].any((x) => x.key == m.key),
      isFalse,
      reason: 'a meal just hidden is listed',
    );
    expect((await usual.hiddenMeals()).any((x) => x.key == m.key), isTrue);
    seen.hidden++;
    trace.add('hide "${m.title}"');
  }

  Future<void> unhide(Op op) async {
    usual.invalidate();
    current = true;
    final hidden = await usual.hiddenMeals();
    if (hidden.isEmpty) return;
    final m = hidden[op.a % hidden.length];
    await usual.unhide(m);
    expect(
      (await usual.hiddenMeals()).any((x) => x.key == m.key),
      isFalse,
      reason: 'a meal shown again is still hidden',
    );
    final list = await usual.frequentMeals();
    final listed = [...list.around, ...list.more];
    expect(
      listed.length == 20 || listed.any((x) => x.key == m.key),
      isTrue,
      reason: 'a meal shown again is not listed',
    );
    seen.shownAgain++;
    trace.add('show "${m.title}" again');
  }

  Future<void> delete(Op op) async {
    final all = await stored();
    if (all.isEmpty) return;
    final id = all[op.a % all.length]['id'] as int;
    await dao.deleteMeal(id);
    bump();
    expect(await row(id), isNull);
    seen.deleted++;
    trace.add('delete meal $id');
  }

  void advance(Op op) {
    final from = clock;
    if (op.flag) {
      clock = DateTime(
        clock.year,
        clock.month,
        clock.day + 1,
        0,
        op.minutes % 7,
      );
    } else {
      clock = clock.add(Duration(minutes: op.minutes));
    }
    if (isoDate(from) != isoDate(clock)) seen.midnights++;
    current = false;
    trace.add('clock ${from.toIso8601String()} → ${clock.toIso8601String()}');
  }

  Future<void> run(Op op) => switch (op.kind) {
    Kind.photo => photo(op),
    Kind.typed => typed(op),
    Kind.edit => edit(op),
    Kind.use => use(op),
    Kind.useHeld => useHeld(op),
    Kind.undoUse => undoUse(op),
    Kind.decline => decline(op),
    Kind.logAgain => logAgain(op),
    Kind.undoLog => undoLog(op),
    Kind.hide => hide(op),
    Kind.unhide => unhide(op),
    Kind.delete => delete(op),
    Kind.advance => Future.sync(() => advance(op)),
  };

  // ── After every step ──

  Future<void> check() async {
    final rows = await stored();
    final meals = <Meal>[];
    for (final row in rows) {
      // "The DB's meals all decode."
      final raw = row['analysis'];
      expect(raw is String, isTrue);
      final decoded = jsonDecode(raw as String);
      expect(
        decoded is Map,
        isTrue,
        reason: 'meal ${row['id']} is stored as $raw',
      );
      final meal = mealFromRow(row);
      expect(sameBytes(meal.analysis, decoded), isTrue);
      meals.add(meal);
    }
    // Every date there is, a malformed one included ('' to '~').
    expect((await dao.mealsBetween('', '~')).length, meals.length);

    // The offers: only for today's uncorrected photo meals...
    final offers = await usual.offersFor(meals);
    final byId = {for (final m in meals) m.id: m};
    for (final o in offers.values) {
      final m = byId[o.mealId]!;
      expect(
        oPhoto(m) && !m.corrected && m.date == today,
        isTrue,
        reason:
            'an offer on meal ${m.id}: ${m.source}, ${m.date}, '
            'corrected ${m.corrected}',
      );
      final items = oItems(m.analysis);
      for (final i in o.items) {
        expect(oNumbers(items[i.index]), i.ai);
      }
    }
    seen.offers += offers.length;
    // ...and, while the service's index is of this moment, exactly the
    // offers the spec gives for the rows as stored.
    if (current) {
      final h = History(clock, meals, choices.view(), {
        for (final m in meals)
          if (_takes(m.analysis)) m.id,
      });
      final teach = oTeaching(meals, clock);
      final latest = oLatest(teach);
      final aliases = oAliases(teach);
      for (final m in meals) {
        final items = oItems(m.analysis);
        final want = <int, OPick>{
          if (oMealGates(h, m))
            for (var i = 0; i < items.length; i++)
              i: ?oItemPick(h, items[i], latest, aliases),
        };
        final got = offers[m.id];
        expect(
          {for (final i in got?.items ?? const <UsualOfferItem>[]) i.index},
          want.keys.toSet(),
          reason: 'offered items of meal ${m.id}',
        );
        for (final i in got?.items ?? const <UsualOfferItem>[]) {
          expect(i.mine, want[i.index]!.mine, reason: 'meal ${m.id}');
          expect(i.fromMealId, want[i.index]!.row.meal.id);
        }
      }
      seen.offersChecked++;
    }

    // My usual foods: at most 20 rows, none twice, none hidden, each on
    // 2+ days; the hidden count is the hidden sheet's length.
    final list = await usual.frequentMeals();
    final hidden = await usual.hiddenMeals();
    final listed = [...list.around, ...list.more];
    final view = choices.view();
    expect(listed.length, lessThanOrEqualTo(20));
    expect({for (final m in listed) m.key}.length, listed.length);
    expect(list.hiddenCount, hidden.length);
    for (final m in listed) {
      expect(m.hiddenIn(view), isFalse, reason: 'a hidden meal is listed');
      expect(m.days90, greaterThanOrEqualTo(2));
    }
    for (final m in hidden) {
      expect(m.hiddenIn(view), isTrue);
    }
    // And, while the service's index is of this moment, the list is the
    // spec's for the rows as stored: the meals on 2+ days, each with its
    // day count, its latest day and the meal a tap would copy.
    if (current) {
      final h = History(clock, meals, view, const {});
      final groups = oGroups(h, oAliases(oTeaching(meals, clock)), view.hidden);
      final visible = {
        for (final g in groups.values)
          if (g.listable && !g.hidden) g.key: g,
      };
      expect(listed.length, min(20, visible.length), reason: 'rows listed');
      for (final m in listed) {
        final g = visible[m.key];
        expect(g, isNotNull, reason: 'row ${m.key} is not a usual meal');
        expect(m.days90, g!.dates.length, reason: 'days of ${m.key}');
        expect(m.lastDate, g.newest.date, reason: 'last day of ${m.key}');
        expect(m.template.id, g.template!.id, reason: 'template of ${m.key}');
      }
      expect(
        {for (final m in hidden) m.key},
        {
          for (final g in groups.values)
            if (g.listable && g.hidden) g.key,
        },
        reason: 'the hidden meals',
      );
      seen.listsChecked++;
    }
    seen.rows += listed.length;
    seen.steps++;
  }
}

/// Runs [c] in a fresh database. Null when every promise held, else what
/// broke and the trace up to it.
Future<String?> runCase(Case c, Seen seen) async {
  final db = await openAppDatabase(path: inMemoryDatabasePath);
  final w = World(db, c.start, seen);
  try {
    await w.open();
    for (final m in c.seeds) {
      await w.dao.saveMeal(m);
    }
    var error = await failureOfAsync(w.check);
    if (error != null) return 'after seeding: $error';
    for (var i = 0; i < c.ops.length; i++) {
      final op = c.ops[i];
      error = await failureOfAsync(() async {
        await w.run(op);
        await w.check();
      });
      if (error != null) {
        return 'at op $i (${op.kind.name}), clock ${w.clock}:\n$error\n'
            'trace:\n  ${w.trace.join('\n  ')}';
      }
    }
    return null;
  } finally {
    await db.close();
  }
}

Future<void> forAllCases({
  required int seed,
  required int cases,
  required Seen seen,
}) async {
  for (var i = 0; i < cases; i++) {
    final c = anyCase(Random(seed + i));
    final error = await runCase(c, seen);
    if (error == null) continue;
    // Cut the sequence down: fewer operations, then fewer seeded meals.
    final quiet = Seen();
    final ops = await shrinkListAsync(
      c.ops,
      (kept) async =>
          await runCase(Case(c.start, c.seeds, kept), quiet) != null,
      budget: 80,
    );
    final seeds = await shrinkListAsync(
      c.seeds,
      (kept) async => await runCase(Case(c.start, kept, ops), quiet) != null,
      budget: 60,
    );
    final small = Case(c.start, seeds, ops);
    fail(
      'seed ${seed + i} (case $i of $cases)\n'
      '${await runCase(small, quiet) ?? error}\n'
      'input: ${small.show()}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const seed = 20261111;

  test(
    'every promise holds after every step of 120 random sequences',
    () async {
      final seen = Seen();
      await forAllCases(seed: seed, cases: 120, seen: seen);
      // No promise held for want of cases.
      expect(seen.steps, greaterThan(2500), reason: 'steps');
      expect(
        seen.offersChecked,
        greaterThan(2000),
        reason: 'steps whose offers were checked against the spec',
      );
      expect(
        seen.listsChecked,
        greaterThan(2000),
        reason: 'steps whose list was checked against the spec',
      );
      expect(seen.offers, greaterThan(1000), reason: 'offers seen');
      expect(seen.written, greaterThan(60), reason: 'Uses written');
      expect(seen.kcalOnlyWritten, greaterThan(8), reason: 'kcal-only Uses');
      expect(seen.undone, greaterThan(25), reason: 'Undo right after Use');
      expect(seen.undoRefused, greaterThan(20), reason: 'refused Undos');
      expect(
        seen.heldRefused,
        greaterThan(35),
        reason: 'refused Uses of an earlier offer',
      );
      expect(seen.staleRaw, greaterThan(10), reason: 'Uses over stale text');
      expect(seen.raced, greaterThan(20), reason: 'writes that lost a race');
      expect(seen.declined, greaterThan(20), reason: 'declines');
      expect(seen.logged, greaterThan(100), reason: 're-logs');
      expect(seen.logsUndone, greaterThan(50), reason: 'undone re-logs');
      expect(seen.logUndoRefused, greaterThan(15), reason: 'refused log Undos');
      expect(seen.hidden, greaterThan(25), reason: 'hides');
      expect(seen.shownAgain, greaterThan(5), reason: 'shown again');
      expect(seen.edits, greaterThan(250), reason: 'editor saves');
      expect(seen.typed, greaterThan(80), reason: 'typed meals');
      expect(seen.deleted, greaterThan(45), reason: 'deleted meals');
      expect(seen.midnights, greaterThan(50), reason: 'midnights crossed');
      expect(seen.rows, greaterThan(2500), reason: 'listed rows');
      expect(seen.askedAgain, greaterThan(80), reason: 'meals logged recently');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
