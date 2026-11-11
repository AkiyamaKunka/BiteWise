// Fuzz: usual-foods marks, the index, offers, Use and its undo, the My
// usual foods list and the re-log whitelist (usual-foods spec §3.1-§3.5,
// §4.2, §4.4; core/usual_foods_logic.dart).
//
// Seeded-random meal histories (usual_history.dart) are checked against
// oracles that restate the spec on their own: which rows teach, which
// rename is confirmed, which items of which meals are offered and with
// what numbers, what Use writes and what its undo restores, which meals
// are listed and what a re-log may contain. A failure prints the seed of
// its case and the history cut down to the meals that still fail.
import 'dart:math';

import 'package:calorie_tracker/core/coerce.dart'
    show cleanShortText, cleanUnit;
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fuzz_support.dart';
import 'usual_history.dart';

const List<String> _numberKeys = [
  'estimated_calories',
  'protein_g',
  'carbs_g',
  'fat_g',
];

const List<String> _totalKeys = [
  'total_calories',
  'total_protein_g',
  'total_carbs_g',
  'total_fat_g',
];

History _shrink(History h, bool Function(History) fails) =>
    h.withMeals(shrinkList(h.meals, (kept) => fails(h.withMeals(kept))));

String _show(History h) => dump(h.toJson());

/// What a run of cases saw, so a property that held for no case fails.
class _Seen {
  int offers = 0;
  int offeredItems = 0;
  int kcalOnly = 0;
  int viaAlias = 0;
  int manyItems = 0;
  int macroOnly = 0;
  int unmarkedTyped = 0;
  int amongNonMaps = 0;
  int reordered = 0;
  int records = 0;
  int aliases = 0;
  int rows = 0;
  int around = 0;
  int hiddenRows = 0;
  int capped = 0;
  int mergedHidden = 0;
  int substituted = 0;
  int copiedMarks = 0;
  int relogs = 0;
}

// ─── Offers: the checks ────────────────────────────────────────────────

void _checkIndex(
  History h,
  UsualIndex index,
  List<Teach> rows,
  Map<String, Teach> latest,
  Map<String, String> aliases,
  _Seen seen,
) {
  expect(index.today, h.today);
  expect(index.aliases, aliases, reason: 'confirmed aliases');
  expect(
    index.records.keys.toSet(),
    latest.keys.toSet(),
    reason: 'the keys with a record',
  );
  for (final e in latest.entries) {
    final rec = index.records[e.key]!;
    final t = e.value;
    final why = 'record ${e.key}: want $t';
    expect((rec.mealId, rec.itemIndex), (t.meal.id, t.itemIndex), reason: why);
    expect(rec.key, t.key, reason: why);
    expect(rec.numbers, t.numbers, reason: why);
    expect(rec.at, t.at, reason: why);
    expect(rec.kcalOnly, t.kcalOnly, reason: why);
    expect(rec.aiName, t.aiName, reason: why);
    expect(rec.date, t.meal.date, reason: why);
    // Where the numbers may come from (the property, stated outright):
    // a trusted meal in the window, never a published row or a leftover
    // meal, a count of 1, at least 10 kcal.
    final from = t.meal;
    final item = oItems(from.analysis)[t.itemIndex];
    expect(oInWindow(from, h.now), isTrue, reason: why);
    expect(from.analysis['leftover'] is Map, isFalse, reason: why);
    expect(item['published'] == true, isFalse, reason: why);
    expect(rec.numbers.kcal, greaterThanOrEqualTo(10), reason: why);
    final marked = oMarkValid(item, h.now) && oTrusted(from);
    final typed =
        (from.source == 'app_manual' || from.source == 'app_manual_photo') &&
        !from.corrected &&
        item['user'] is! Map;
    expect(marked || typed, isTrue, reason: why);
    if (!marked) seen.unmarkedTyped++;
  }
  seen.records += latest.length;
  seen.aliases += aliases.length;
}

void _checkOffer(
  History h,
  Meal meal,
  UsualOffer offer,
  Map<String, Teach> latest,
  Map<String, String> aliases,
  _Seen seen,
) {
  final a = meal.analysis;
  final items = oItems(a);
  // "An offer only ever exists for a photo meal of now's calendar day
  // that is not corrected."
  expect(oPhoto(meal), isTrue, reason: 'source ${meal.source}');
  expect(meal.date, h.today);
  expect(meal.corrected, isFalse);
  expect(offer.mealId, meal.id);
  expect(offer.items, isNotEmpty);
  num dk = 0;
  var last = -1;
  for (final o in offer.items) {
    expect(o.index, greaterThan(last));
    last = o.index;
    final item = items[o.index];
    final pick = oItemPick(h, item, latest, aliases)!;
    final t = pick.row;
    final why = 'meal ${meal.id} item ${o.index}: want $t';
    expect(o.ai, pick.ai, reason: why);
    expect(o.mine, pick.mine, reason: why);
    expect(o.kcalOnly, t.kcalOnly, reason: why);
    expect(o.viaAlias, pick.viaAlias, reason: why);
    expect(o.key, usualNameKey(item['name']), reason: why);
    expect(o.fromMealId, t.meal.id, reason: why);
    expect(o.fromMealId, isNot(meal.id), reason: why);
    expect(o.mineAt, t.at, reason: why);
    expect(o.fromDate, t.meal.date, reason: why);
    // The gates, stated outright.
    expect(o.ai.kcal >= 10 && o.mine.kcal >= 10, isTrue, reason: why);
    final ratio = o.mine.kcal / o.ai.kcal;
    expect(ratio >= 0.4 && ratio <= 2.5, isTrue, reason: '$why ratio $ratio');
    final kcalDiff =
        (o.mine.kcal - o.ai.kcal).abs() >= max(20, 0.10 * o.ai.kcal);
    final macroDiff =
        (o.mine.p - o.ai.p).abs() >= 5 ||
        (o.mine.c - o.ai.c).abs() >= 5 ||
        (o.mine.f - o.ai.f).abs() >= 5;
    expect(kcalDiff || (!o.kcalOnly && macroDiff), isTrue, reason: why);
    expect(o.macroOnly, !kcalDiff, reason: why);
    if (o.kcalOnly) {
      expect(
        (o.mine.p, o.mine.c, o.mine.f),
        (o.ai.p, o.ai.c, o.ai.f),
        reason: 'a kcal-only offer keeps the AI macros',
      );
      seen.kcalOnly++;
    }
    if (o.viaAlias) seen.viaAlias++;
    if (!kcalDiff) seen.macroOnly++;
    dk += o.mine.kcal - o.ai.kcal;
  }
  expect(offer.beforeKcal, oNum(a['total_calories']));
  expect(offer.afterKcal, (offer.beforeKcal + dk).round());
  seen.offers++;
  seen.offeredItems += offer.items.length;
  if (offer.items.length > 1) seen.manyItems++;
}

/// Use, its undo, and the second look.
void _checkUse(
  History h,
  Meal meal,
  UsualOffer offer,
  UsualIndex index,
  _Seen seen,
) {
  final now = h.now;
  final a = meal.analysis;
  final frozen = dump(a);
  final applied = applyUsualOffer(a, offer, now: now);
  expect(dump(a), frozen, reason: 'Use changed its input');
  expect(applied, isNotNull, reason: 'a fresh offer must apply');
  applied!;
  final was = a['food_items'] as List;
  final isNow = applied['food_items'] as List;
  expect(isNow.length, was.length);
  final positions = [
    for (var i = 0; i < was.length; i++)
      if (was[i] is Map) i,
  ];
  if (positions.length != was.length) seen.amongNonMaps++;
  final offeredAt = {for (final o in offer.items) positions[o.index]: o};
  final delta = <num>[0, 0, 0, 0];
  var droppedUser = false;
  for (var p = 0; p < was.length; p++) {
    final o = offeredAt[p];
    if (o == null) {
      // "applyUsualOffer changes only the offered indices."
      expect(
        sameBytes(isNow[p], was[p]),
        isTrue,
        reason: 'row $p was not offered and changed',
      );
      continue;
    }
    final before = was[p] as Map;
    final after = isNow[p] as Map;
    for (final k in {...before.keys, ...after.keys}) {
      if (_numberKeys.contains(k) || k == 'user') continue;
      expect(
        after.containsKey(k) && before.containsKey(k),
        isTrue,
        reason: 'row $p key $k',
      );
      expect(sameBytes(after[k], before[k]), isTrue, reason: 'row $p key $k');
    }
    expect(after['estimated_calories'], o.mine.kcal);
    final oldUser = before['user'];
    final oldName = oldUser is Map ? oldUser['ai_name'] : null;
    final keepName = oldName is String && oldName.trim().isNotEmpty;
    if (o.kcalOnly) {
      // "A kcal-only offer never changes macros."
      for (final k in _numberKeys.skip(1)) {
        expect(after.containsKey(k), before.containsKey(k), reason: k);
        expect(sameBytes(after[k], before[k]), isTrue, reason: k);
      }
      if (keepName) {
        expect(after['user'], {'qty': 1, 'ai_name': oldName});
      } else {
        expect(after.containsKey('user'), isFalse);
        if (before.containsKey('user')) droppedUser = true;
      }
      expect(
        oMarkValid(after, now),
        isFalse,
        reason: 'mixed numbers must not be vouched for',
      );
    } else {
      expect(after['protein_g'], o.mine.p);
      expect(after['carbs_g'], o.mine.c);
      expect(after['fat_g'], o.mine.f);
      final user = after['user'] as Map;
      expect(user.keys.toSet(), {
        'set',
        'at',
        'n',
        'qty',
        if (keepName) 'ai_name',
      });
      expect(user['set'], true);
      expect(user['at'], usualStamp(now));
      expect(
        DateTime.parse(user['at'] as String).isAtSameMomentAs(now),
        isTrue,
      );
      expect(user['n'], [o.mine.kcal, o.mine.p, o.mine.c, o.mine.f]);
      expect(user['qty'], 1);
      if (keepName) expect(user['ai_name'], oldName);
      expect(
        oMarkValid(after, now),
        isTrue,
        reason: 'the mark Use wrote must vouch for the numbers it wrote',
      );
    }
    delta[0] += o.mine.kcal - o.ai.kcal;
    delta[1] += o.mine.p - o.ai.p;
    delta[2] += o.mine.c - o.ai.c;
    delta[3] += o.mine.f - o.ai.f;
  }
  for (final k in {...a.keys, ...applied.keys}) {
    if (k == 'food_items' || _totalKeys.contains(k)) continue;
    expect(applied.containsKey(k) && a.containsKey(k), isTrue, reason: k);
    expect(sameBytes(applied[k], a[k]), isTrue, reason: k);
  }
  // "Totals after apply equal totals before plus the item deltas (kcal
  // whole, macros to 0.1 g)"; an absent total with nothing to add stays
  // absent.
  for (var i = 0; i < 4; i++) {
    final k = _totalKeys[i];
    final raw = a[k];
    final total = raw is num && raw.isFinite && raw.abs() < 1e9 ? raw : null;
    if (total == null && delta[i].abs() < 1e-9) {
      expect(applied.containsKey(k), a.containsKey(k), reason: k);
      expect(sameBytes(applied[k], a[k]), isTrue, reason: k);
      continue;
    }
    final want = (total ?? 0) + delta[i];
    expect(
      applied[k],
      i == 0 ? want.round() : (want * 10).round() / 10,
      reason: '$k: $raw moved by ${delta[i]}',
    );
  }
  expect(oNum(applied['total_calories']), offer.afterKcal);

  // "revertUsualOffer(apply(x)) restores x's items and totals exactly."
  final frozenApplied = dump(applied);
  final undo = UsualUndo(
    before: a,
    after: applied,
    indices: [for (final o in offer.items) o.index],
  );
  final back = revertUsualOffer(applied, undo);
  expect(dump(applied), frozenApplied, reason: 'the undo changed its input');
  expect(back, isNotNull, reason: 'an undo right after Use must work');
  expect(
    sameValue(back, a),
    isTrue,
    reason: 'undo gave ${dump(back)}\nwanted ${dump(a)}',
  );
  if (!sameBytes(back, a)) {
    // The values are back; only the ORDER of keys may differ, and only
    // where a kcal-only Use removed a `user` map (it comes back last).
    expect(
      droppedUser,
      isTrue,
      reason: 'undo gave ${dump(back)}\nwanted ${dump(a)}',
    );
    seen.reordered++;
  }

  // "After apply, the same meal gets no second offer": as stored
  // (corrected), and even if the flag were lost.
  for (final corrected in const [true, false]) {
    expect(
      usualOfferFor(
        mealWith(meal, analysis: applied, corrected: corrected),
        index,
        now: now,
        lookupTakesIt: false,
        choices: h.choices,
      ),
      isNull,
      reason: 'a second offer (corrected: $corrected)',
    );
  }

  // A meal that moved since is not written, and not undone.
  final first = offer.items.first;
  final moved = deepCopy(a) as Map<String, dynamic>;
  final movedItem =
      (moved['food_items'] as List)[positions[first.index]] as Map;
  movedItem['estimated_calories'] = first.ai.kcal + 1;
  expect(
    applyUsualOffer(moved, offer, now: now),
    isNull,
    reason: 'the AI number changed after the offer was shown',
  );
  expect(
    applyUsualOffer(
      {
        ...a,
        'leftover': {'original': {}},
      },
      offer,
      now: now,
    ),
    isNull,
    reason: 'a leftover block',
  );
  final edited = deepCopy(applied) as Map<String, dynamic>;
  final editedItem =
      (edited['food_items'] as List)[positions[first.index]] as Map;
  editedItem['estimated_calories'] = first.mine.kcal + 1;
  expect(
    revertUsualOffer(edited, undo),
    isNull,
    reason: 'the number changed after Use',
  );
}

void _checkOffers(History h, _Seen seen) {
  final now = h.now;
  final index = buildUsualIndex(h.meals, now: now);
  final rows = oTeaching(h.meals, now);
  final latest = oLatest(rows);
  final aliases = oAliases(rows);
  _checkIndex(h, index, rows, latest, aliases, seen);
  for (final meal in h.meals) {
    final takes = h.takes.contains(meal.id);
    final offer = usualOfferFor(
      meal,
      index,
      now: now,
      lookupTakesIt: takes,
      choices: h.choices,
    );
    final gates = oMealGates(h, meal);
    expect(
      usualOfferCandidate(
        meal,
        now: now,
        lookupTakesIt: takes,
        choices: h.choices,
      ),
      gates,
      reason: 'meal gates of meal ${meal.id}',
    );
    final items = oItems(meal.analysis);
    final want = <int>{
      if (gates)
        for (var i = 0; i < items.length; i++)
          if (oItemPick(h, items[i], latest, aliases) != null) i,
    };
    expect(
      {for (final o in offer?.items ?? const <UsualOfferItem>[]) o.index},
      want,
      reason: 'offered items of meal ${meal.id}',
    );
    if (offer == null) continue;
    _checkOffer(h, meal, offer, latest, aliases, seen);
    _checkUse(h, meal, offer, index, seen);
  }
}

// ─── My usual foods: the oracle and the checks ─────────────────────────

/// Spec §4.2 "Order", More: days in 30, days in 90, recency, title.
int _moreOrder(OGroup a, OGroup b) {
  if (a.dates30.length != b.dates30.length) {
    return b.dates30.length.compareTo(a.dates30.length);
  }
  if (a.dates.length != b.dates.length) {
    return b.dates.length.compareTo(a.dates.length);
  }
  final day = b.newest.date.compareTo(a.newest.date);
  if (day != 0) return day;
  final clock = oClock(b.newest.time).compareTo(oClock(a.newest.time));
  if (clock != 0) return clock;
  return a.title.compareTo(b.title);
}

int _aroundOrder(OGroup a, OGroup b) => a.around.length != b.around.length
    ? b.around.length.compareTo(a.around.length)
    : _moreOrder(a, b);

/// The meal keys this case hides: a quarter of the keys in the history,
/// with and without aliases, and two ids that match nothing.
Set<String> _hiddenFor(History h, Map<String, String> aliases) {
  final ids = <String>{};
  for (final m in h.meals) {
    if (!oInWindow(m, h.now)) continue;
    for (final k in [
      oMealKey(m.analysis, aliases),
      oMealKey(m.analysis, const {}),
    ]) {
      if (k != null) ids.add(usualHideId(k));
    }
  }
  return {
    for (final id in ids)
      if ((int.parse(id.substring(0, 6), radix: 16) + h.salt) % 4 == 0) id,
    'zz',
    '0123456789abcdef',
  };
}

num _clamp(num v, num max) => v < 0 ? 0 : (v > max ? max : v);

ONumbers _clamped(ONumbers n) => (
  kcal: _clamp(n.kcal, 20000),
  p: _clamp(n.p, 2000),
  c: _clamp(n.c, 2000),
  f: _clamp(n.f, 2000),
);

const Set<String> _logKeys = {
  'is_food', 'meal_description', 'food_items', 'total_calories', //
  'total_protein_g', 'total_carbs_g', 'total_fat_g', 'logged_again',
};

const Set<String> _logItemKeys = {
  'name', 'estimated_calories', 'protein_g', 'carbs_g', 'fat_g', 'qty', //
  'unit', 'user',
};

const Set<String> _markKeys = {'set', 'at', 'n', 'qty', 'ai_name'};

/// Every key at any depth of [v].
Set<String> _allKeys(Object? v) {
  final out = <String>{};
  void walk(Object? x) {
    if (x is Map) {
      for (final e in x.entries) {
        out.add('${e.key}');
        walk(e.value);
      }
    } else if (x is List) {
      x.forEach(walk);
    }
  }

  walk(v);
  return out;
}

/// The re-log of [row] (spec §4.4): the whitelist, the numbers, the marks,
/// the totals.
void _checkLog(
  History h,
  UsualMeal row,
  UsualIndex index,
  Map<String, Teach> latest,
  Map<String, String> aliases,
  _Seen seen,
) {
  final now = h.now;
  final template = row.template;
  final frozen = dump(template.analysis);
  final out = usualLogAnalysis(row, index, now: now);
  expect(dump(template.analysis), frozen, reason: 'the template was changed');
  final why = 're-log of meal ${template.id}: ${dump(out)}';
  // "Only whitelisted keys: no assist block, no fetched_on, no leftover
  // block, no model claims" — at any depth.
  expect(out.keys.toSet(), _logKeys, reason: why);
  expect(
    _allKeys(out).difference({..._logKeys, ..._logItemKeys, ..._markKeys}),
    isEmpty,
    reason: why,
  );
  expect(out['is_food'], true, reason: why);
  final desc = out['meal_description'];
  expect(
    desc is String && desc.isNotEmpty && desc.runes.length <= 300,
    isTrue,
    reason: why,
  );
  expect(out['logged_again'], usualStamp(now), reason: why);
  final src = oItems(template.analysis).take(40).toList();
  final items = out['food_items'] as List;
  expect(items.length, src.length, reason: why);
  num k = 0, p = 0, c = 0, f = 0;
  for (var i = 0; i < items.length; i++) {
    final o = items[i] as Map;
    final t = src[i];
    final at = '$why\nitem $i';
    expect(_logItemKeys.containsAll(o.keys), isTrue, reason: at);
    // As the template wrote it: full-width punctuation is kept.
    expect(
      o['name'],
      cleanShortText(t['name'], 300, keepWidth: true),
      reason: at,
    );
    for (final key in _numberKeys) {
      final v = o[key];
      expect(v is num && v.isFinite, isTrue, reason: '$at $key');
      // "No item is under 0 kcal", nor over the editor's bounds.
      expect(
        (v as num) >= 0 && v <= (key == _numberKeys[0] ? 20000 : 2000),
        isTrue,
        reason: '$at $key',
      );
    }
    final q = oQty(t);
    expect(o.containsKey('qty'), q != 1, reason: at);
    if (q != 1) expect(o['qty'], q, reason: at);
    final unit = cleanUnit(t['unit']);
    expect(o.containsKey('unit'), unit.isNotEmpty, reason: at);
    if (unit.isNotEmpty) expect(o['unit'], unit, reason: at);

    // The numbers: the user's from the latest teaching row under the
    // item's key (directly or through a confirmed alias, the newer of the
    // two) when the count is 1 and the portions agree — kcal alone from a
    // kcal-only row — else the template's own.
    final got = oNumbers(o);
    final own = _clamped(oNumbers(t));
    final ck = oCanonical(t, aliases);
    final direct = ck == null ? null : latest[ck];
    final via = ck == null || aliases[ck] == null ? null : latest[aliases[ck]];
    final pick = via != null && (direct == null || via.laterThan(direct))
        ? via
        : direct;
    final tUser = t['user'];
    final tAiName = tUser is Map ? tUser['ai_name'] : null;
    final portionName = tAiName is String && tAiName.trim().isNotEmpty
        ? tAiName
        : t['name'];
    final replaced =
        pick != null &&
        q == 1 &&
        usualPortionsCompatible(
          usualPortion(portionName),
          usualPortion(pick.aiName ?? pick.name),
        );
    final ONumbers want = !replaced
        ? own
        : pick.kcalOnly
        ? (kcal: _clamp(pick.numbers.kcal, 20000), p: own.p, c: own.c, f: own.f)
        : _clamped(pick.numbers);
    expect(
      got,
      want,
      reason: '$at: numbers (from ${replaced ? pick : 'itself'})',
    );
    if (replaced) seen.substituted++;

    // The row's `user`, exactly (spec §4.4 and the whitelist inside it):
    //   * numbers replaced: a mark for them with the record's own `at`
    //     and a count of 1 — none for a kcal-only record, whose mixed
    //     numbers nothing vouches for; the AI's old name of the row, else
    //     the record's when the row bears the record's name;
    //   * else the row's own map cut to a mark's parts: set, at and n
    //     only on a trusted meal and only while they vouch for the
    //     numbers as written; its count (when not 1, or beside set); its
    //     AI name.
    final ownAiName = tAiName is String && tAiName.trim().isNotEmpty
        ? tAiName
        : null;
    Map<String, dynamic>? wantUser;
    if (replaced) {
      if (pick.kcalOnly) {
        if (ownAiName != null) wantUser = {'qty': 1, 'ai_name': ownAiName};
      } else {
        final aiName =
            ownAiName ??
            (usualNameKey(t['name']) == pick.key ? pick.aiName : null);
        wantUser = {
          'set': true,
          'at': usualStamp(pick.at),
          'n': [want.kcal, want.p, want.c, want.f],
          'qty': 1,
          'ai_name': ?aiName,
        };
      }
    } else if (tUser is Map) {
      final vouches =
          oTrusted(template) &&
          oMarkValid({
            'estimated_calories': own.kcal,
            'protein_g': own.p,
            'carbs_g': own.c,
            'fat_g': own.f,
            'user': tUser,
          }, now);
      final count = tUser['qty'];
      wantUser = {
        if (vouches) ...{'set': true, 'at': tUser['at'], 'n': tUser['n']},
        if (count is num && (vouches || count != 1)) 'qty': count,
        'ai_name': ?ownAiName,
      };
      if (wantUser.isEmpty) wantUser = null;
    }
    expect(
      o.containsKey('user'),
      wantUser != null,
      reason: '$at: want user $wantUser',
    );
    if (wantUser != null) {
      expect(
        sameValue(o['user'], wantUser),
        isTrue,
        reason: '$at: want user ${dump(wantUser)}',
      );
      final user = o['user'] as Map;
      // The properties, stated outright. "Only whitelisted keys":
      expect(_markKeys.containsAll(user.keys), isTrue, reason: at);
      if (user['set'] == true) {
        // "Every copied user mark is valid for its row's numbers", and
        // it is the user's own.
        expect(
          oMarkValid(o, now),
          isTrue,
          reason: '$at: the mark does not vouch for the numbers written',
        );
        expect(
          replaced || oTrusted(template),
          isTrue,
          reason: '$at: a mark nobody set was copied',
        );
        seen.copiedMarks++;
      } else {
        expect(
          user.containsKey('at') || user.containsKey('n'),
          isFalse,
          reason: '$at: a mark that sets nothing vouches for nothing',
        );
      }
    }
    k += o['estimated_calories'] as num;
    p += o['protein_g'] as num;
    c += o['carbs_g'] as num;
    f += o['fat_g'] as num;
  }
  // "Its totals equal the sum of its items."
  if (items.isEmpty) {
    final a = template.analysis;
    expect(
      out['total_calories'],
      _clamp(oNum(a['total_calories']), 20000).round(),
      reason: why,
    );
    for (final key in _totalKeys.skip(1)) {
      expect(
        out[key],
        (_clamp(oNum(a[key]), 2000) * 10).round() / 10,
        reason: '$why $key',
      );
    }
  } else {
    expect(out['total_calories'], k.round(), reason: why);
    expect(out['total_protein_g'], (p * 10).round() / 10, reason: why);
    expect(out['total_carbs_g'], (c * 10).round() / 10, reason: why);
    expect(out['total_fat_g'], (f * 10).round() / 10, reason: why);
  }
  expect(row.numbers, (
    kcal: out['total_calories'],
    p: out['total_protein_g'],
    c: out['total_carbs_g'],
    f: out['total_fat_g'],
  ), reason: 'the row shows what a log writes');
  seen.relogs++;
}

void _checkList(History h, _Seen seen) {
  final now = h.now;
  final index = buildUsualIndex(h.meals, now: now);
  final rows = oTeaching(h.meals, now);
  final latest = oLatest(rows);
  final aliases = oAliases(rows);
  expect(index.aliases, aliases);
  final hidden = _hiddenFor(h, aliases);
  final choices = UsualChoicesView(
    hidden: hidden,
    declined: h.choices.declined,
  );
  final groups = oGroups(h, aliases, hidden);
  final list = usualMealList(index, now: now, choices: choices);
  final hiddenMeals = usualHiddenMeals(index, now: now, choices: choices);

  final listable = [
    for (final g in groups.values)
      if (g.listable) g,
  ];
  final visible = {
    for (final g in listable)
      if (!g.hidden) g.key: g,
  };
  final listed = [...list.around, ...list.more];

  // "hiddenCount equals the number of meals usualHiddenMeals returns."
  expect(hiddenMeals.length, list.hiddenCount);
  expect(
    {for (final m in hiddenMeals) m.key},
    {
      for (final g in listable)
        if (g.hidden) g.key,
    },
    reason: 'the hidden meals',
  );
  // "At most 20 rows", and no fewer than there are to show.
  expect(listed.length, lessThanOrEqualTo(20));
  expect(listed.length, min(20, visible.length));
  // "No meal is in both around and more."
  expect(
    {for (final m in listed) m.key}.length,
    listed.length,
    reason: 'a meal listed twice',
  );

  for (final row in [...listed, ...hiddenMeals]) {
    final g = groups[row.key];
    expect(g, isNotNull, reason: 'row ${row.key} matches no meals');
    g!;
    final why = 'row ${row.key}';
    // "Listed meals appear on at least 2 distinct days within 90."
    expect(g.dates.length, greaterThanOrEqualTo(2), reason: why);
    expect(row.days90, g.dates.length, reason: why);
    expect(row.days30, g.dates30.length, reason: why);
    expect(row.aroundDays, g.around.length, reason: why);
    expect(row.lastDate, g.newest.date, reason: why);
    expect(row.lastTime, g.newest.time, reason: why);
    expect(row.template.id, g.template!.id, reason: why);
    expect(row.template.analysis['leftover'] is Map, isFalse, reason: why);
    final todays = [
      for (final m in g.meals)
        if (m.date == h.today) m,
    ];
    expect(
      row.loggedTodayTime,
      todays.isEmpty
          ? null
          : todays.reduce((a, b) => oNewer(a, b) >= 0 ? a : b).time,
      reason: why,
    );
    expect(row.hiddenIn(choices), g.hidden, reason: why);
    _checkLog(h, row, index, latest, aliases, seen);
  }
  for (final row in listed) {
    // "A hidden meal is never listed."
    final g = visible[row.key];
    expect(g, isNotNull, reason: 'row ${row.key} is hidden or not listable');
    expect(hidden.contains(row.hideId), isFalse);
  }
  // The sections: around this time first, each in its order, and nothing
  // left out that belongs before a listed row.
  for (final row in list.around) {
    expect(visible[row.key]!.around.length, greaterThanOrEqualTo(2));
  }
  for (final row in list.more) {
    expect(visible[row.key]!.around.length, lessThan(2));
  }
  for (var i = 1; i < list.around.length; i++) {
    expect(
      _aroundOrder(
        visible[list.around[i - 1].key]!,
        visible[list.around[i].key]!,
      ),
      lessThanOrEqualTo(0),
      reason: 'around order at $i',
    );
  }
  for (var i = 1; i < list.more.length; i++) {
    expect(
      _moreOrder(visible[list.more[i - 1].key]!, visible[list.more[i].key]!),
      lessThanOrEqualTo(0),
      reason: 'more order at $i',
    );
  }
  final shown = {for (final m in listed) m.key};
  for (final g in visible.values) {
    if (shown.contains(g.key)) continue;
    expect(listed.length, 20, reason: '${g.key} is missing');
    if (g.around.length >= 2) {
      expect(list.more, isEmpty, reason: '${g.key} belongs in around');
      expect(
        _aroundOrder(visible[list.around.last.key]!, g),
        lessThanOrEqualTo(0),
        reason: '${g.key} was cut before a later row',
      );
    } else if (list.more.isNotEmpty) {
      expect(
        _moreOrder(visible[list.more.last.key]!, g),
        lessThanOrEqualTo(0),
        reason: '${g.key} was cut before a later row',
      );
    }
  }
  seen.rows += listed.length;
  seen.around += list.around.length;
  seen.hiddenRows += hiddenMeals.length;
  if (visible.length > 20) seen.capped++;
  seen.mergedHidden += hiddenMeals
      .where((m) => !hidden.contains(m.hideId) && m.hiddenIn(choices))
      .length;
}

void main() {
  const seed = 20261110;

  test('the vocabulary: each food\'s names share one key, and no two foods '
      'share one', () {
    final keys = <String>{};
    for (final names in kFoods) {
      final own = {for (final n in names) usualNameKey(n)};
      expect(own.length, 1, reason: '$names');
      expect(own.single, isNotNull, reason: '$names');
      expect(keys.add(own.single!), isTrue, reason: '$names');
    }
    for (final junk in kJunkNames) {
      expect(usualNameKey(junk), isNull, reason: '$junk');
    }
  });

  test('usualMarkValid agrees with the spec on any item, and never throws '
      '(6000 items)', () {
    var valid = 0;
    var invalid = 0;
    forAll<(Object?, DateTime)>(
      seed: seed,
      cases: 6000,
      gen: (r) {
        final g = HistoryGen(r, wild: 0.3);
        final Object? item = r.chance(0.05)
            ? r.pick(<Object?>[
                null,
                7,
                'x',
                <Object?>[],
                {'user': 1},
              ])
            : g.item(g.today, marked: 0.9);
        return (item, g.now);
      },
      show: (x) => '${dump(x.$1)} at ${x.$2}',
      check: (x) {
        final (item, now) = x;
        final got = usualMarkValid(item, now);
        expect(got, oMarkValid(item, now));
        got ? valid++ : invalid++;
        usualItemQty(item);
        if (!got || item is! Map) return;
        // The mark vouches for THESE numbers: one kcal more and it is void,
        // and so is a tenth of a gram.
        final n = oNumbers(item);
        expect(
          usualMarkValid({...item, 'estimated_calories': n.kcal + 1}, now),
          isFalse,
        );
        expect(usualMarkValid({...item, 'fat_g': n.f + 0.11}, now), isFalse);
        // And only up to a day ahead of the clock.
        expect(
          usualMarkValid(item, now.subtract(const Duration(days: 800))),
          isFalse,
        );
      },
    );
    expect(valid, greaterThan(1500));
    expect(invalid, greaterThan(1500));
  });

  test('the index, offers, Use and its undo hold on any history '
      '(700 histories)', () {
    final seen = _Seen();
    forAll<History>(
      seed: seed + 10000,
      cases: 700,
      gen: (r) => HistoryGen(r).history(),
      shrink: _shrink,
      show: _show,
      check: (h) => _checkOffers(h, seen),
    );
    // None of the properties held for want of cases.
    expect(seen.records, greaterThan(3000), reason: 'records');
    expect(seen.unmarkedTyped, greaterThan(100), reason: 'hand-typed rows');
    expect(seen.aliases, greaterThan(40), reason: 'confirmed aliases');
    expect(seen.offers, greaterThan(400), reason: 'offers');
    expect(seen.kcalOnly, greaterThan(40), reason: 'kcal-only offers');
    expect(seen.viaAlias, greaterThan(15), reason: 'offers through an alias');
    expect(seen.manyItems, greaterThan(15), reason: 'offers of 2+ items');
    expect(seen.macroOnly, greaterThan(15), reason: 'offers on macros alone');
    expect(
      seen.amongNonMaps,
      greaterThan(3),
      reason: 'offers on a list with entries that are not items',
    );
  });

  test('nothing throws on histories of malformed meals (300 histories)', () {
    forAll<History>(
      seed: seed + 20000,
      cases: 300,
      gen: (r) => HistoryGen(r, wild: 0.6).history(),
      shrink: _shrink,
      show: _show,
      check: (h) {
        final seen = _Seen();
        _checkOffers(h, seen);
        _checkList(h, seen);
      },
    );
  });

  test('My usual foods and the re-log whitelist hold on any history '
      '(500 histories)', () {
    final seen = _Seen();
    forAll<History>(
      seed: seed + 30000,
      cases: 500,
      gen: (r) => HistoryGen(r).history(),
      shrink: _shrink,
      show: _show,
      check: (h) => _checkList(h, seen),
    );
    expect(seen.rows, greaterThan(1500), reason: 'rows');
    expect(seen.around, greaterThan(100), reason: 'rows around this time');
    expect(seen.hiddenRows, greaterThan(200), reason: 'hidden rows');
    expect(seen.capped, greaterThan(10), reason: 'lists cut at 20');
    expect(
      seen.mergedHidden,
      greaterThan(2),
      reason: 'rows hidden through a key an alias merged',
    );
    expect(seen.relogs, greaterThan(1500), reason: 're-logs');
    expect(
      seen.substituted,
      greaterThan(300),
      reason: 're-logged items with the user\'s numbers',
    );
    expect(seen.copiedMarks, greaterThan(300), reason: 'copied marks');
  });
}
