// AUTOMATIC leftover detection (2026-08-05): the watcher's own analysis
// call carries today's meals; a confident leftover_of reply ADJUSTS the
// original instead of logging a double-count. These pin the gate, the
// application, and every fall-through.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/leftover_logic.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Meal _meal(int id, String time, num kcal) => Meal(
      id: id,
      date: isoDate(DateTime.now()),
      time: time,
      timestamp: '${isoDate(DateTime.now())}T08:00:0$id',
      source: 'app_watch',
      imageHash: 'orig-$id',
      analysis: {
        'is_food': true,
        'meal_description': 'Cafeteria tray $id',
        'total_calories': kcal,
        'total_protein_g': 40,
        'total_carbs_g': 90,
        'total_fat_g': 40,
        'food_items': [
          {'name': 'Rice (~200 g)', 'estimated_calories': 300},
          {'name': 'Pork (~150 g)', 'estimated_calories': kcal - 300},
        ],
      },
    );

Map<String, dynamic> _leftoverReply(
        {num index = 0, double confidence = 0.9}) =>
    {
      'is_food': true,
      'leftover_of': index,
      'confidence': confidence,
      'leftover_fraction': 0.4,
      'items': [
        {'name': 'Rice (~200 g)', 'left_fraction': 1.0},
        {'name': 'Pork (~150 g)', 'left_fraction': 0.0},
      ],
      'note': 'same tray, rice untouched',
    };

void main() {
  late FakeDao dao;
  late FakeAnalyzer analyzer;
  late PhotoPipeline pipeline;
  final notifications = <PhotoOutcome>[];

  setUp(() {
    dao = FakeDao();
    analyzer = FakeAnalyzer();
    notifications.clear();
    pipeline = PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        hasher: (_) async => 'leftover-hash-1',
        notify: notifications.add);
  });

  IntakePhoto photo() =>
      IntakePhoto(Uint8List.fromList([7]), 'w1', 'IMG_7.jpg');

  test('a confident leftover_of ADJUSTS the original — no new meal',
      () async {
    dao.put(_meal(1, '01:34 PM', 965));
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
    final out = await pipeline.process(photo());
    expect(out.kind, PhotoOutcomeKind.leftoverApplied);
    expect(dao.meals, hasLength(1), reason: 'no double-count row');
    final updated = dao.meals.single;
    expect(updated.analysis['total_calories'], 665); // pork eaten, rice left
    expect(updated.analysis['leftover']['original']['total_calories'], 965);
    expect(dao.ledger['leftover-hash-1'], IngestionStatus.skipped);
    expect(notifications.single.kind, PhotoOutcomeKind.leftoverApplied);
    expect(notifications.single.message, contains('Leftovers deducted'));
    // The prompt data really carried the candidate.
    expect(analyzer.lastRecentMeals, hasLength(1));
    expect(analyzer.lastRecentMeals!.single['meal_description'],
        'Cafeteria tray 1');
  });

  // Write safety (design R6a): the candidate list is as old as the model
  // call; the deduction is re-based on the meal as stored at write time and
  // written compare-and-set.
  group('a meal that changed during the analysis', () {
    /// A restaurant lookup lands: published pork, totals moved with it.
    Future<void> landLookup(int id) async {
      final snap = (await dao.mealSnapshot(id))!;
      final a = snap.meal.analysis;
      final items = [
        for (final it in a['food_items'] as List) Map<String, dynamic>.from(it),
      ];
      items[1]['estimated_calories'] = 865;
      items[1]['published'] = true;
      expect(
          await dao.applyAssist(id, expectedRaw: snap.rawAnalysis, analysis: {
            ...a,
            'food_items': items,
            'total_calories': 1165,
          }),
          isTrue);
    }

    /// Rewrites meal [id] directly, as some other writer would.
    void rewrite(int id, Object marker) {
      final i = dao.meals.indexWhere((m) => m.id == id);
      final m = dao.meals[i];
      dao.meals[i] = Meal(
          id: m.id,
          date: m.date,
          time: m.time,
          timestamp: m.timestamp,
          source: m.source,
          imageHash: m.imageHash,
          analysis: {...m.analysis, 'rewritten': marker});
    }

    test('the deduction is re-based on it, same fractions', () async {
      dao.put(_meal(1, '01:34 PM', 965));
      analyzer
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _leftoverReply(), isFood: true, wall: Duration.zero)
        ..onAnalyze = () => landLookup(1);
      final out = await pipeline.process(photo());
      expect(out.kind, PhotoOutcomeKind.leftoverApplied);
      final m = dao.byId(1);
      expect(m.analysis['total_calories'], 865,
          reason: 'rice left, the published pork eaten');
      expect(m.analysis['leftover']['original']['total_calories'], 1165);
      expect(out.previousAnalysis!['total_calories'], 1165,
          reason: 'the undo restores the meal as this deduction found it');
      expect(out.kcal, '865');
      expect(out.deductedKcal, 300);
      expect(dao.ledger['leftover-hash-1'], IngestionStatus.skipped);
    });

    test('a write between the re-read and the write gets one re-based retry',
        () async {
      dao.put(_meal(1, '01:34 PM', 965));
      analyzer.nextPhotoOutcome = AnalysisOutcome(
          analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
      var landed = false;
      dao.beforeCompareAndSet = (id) async {
        if (landed) return;
        landed = true;
        await landLookup(id);
      };
      final out = await pipeline.process(photo());
      expect(out.kind, PhotoOutcomeKind.leftoverApplied);
      expect(dao.compareMisses, 1);
      expect(dao.byId(1).analysis['total_calories'], 865);
    });

    test('a second miss releases the photo: nothing deducted, no meal '
        'logged, nothing announced', () async {
      dao.put(_meal(1, '01:34 PM', 965));
      analyzer.nextPhotoOutcome = AnalysisOutcome(
          analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
      var n = 0;
      dao.beforeCompareAndSet = (id) async => rewrite(id, ++n);
      final out = await pipeline.process(photo());
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(out.retryable, isTrue,
          reason: 'the next scan asks again, against the day as it is then');
      expect(out.reason, leftoverConflictReason);
      expect(dao.compareMisses, 2);
      expect(dao.meals, hasLength(1), reason: 'never logged as its own meal');
      expect(dao.byId(1).analysis.containsKey('leftover'), isFalse);
      expect(dao.byId(1).analysis['total_calories'], 965);
      expect(dao.ledger.containsKey('leftover-hash-1'), isFalse,
          reason: 'released, not tombstoned');
      expect(notifications, isEmpty);
    });

    test('a meal deleted meanwhile: released, and the leftovers are not '
        'logged as a meal', () async {
      dao.put(_meal(1, '01:34 PM', 965));
      analyzer
        ..nextPhotoOutcome = AnalysisOutcome(
            analysis: _leftoverReply(), isFood: true, wall: Duration.zero)
        ..onAnalyze = () => dao.deleteMeal(1);
      final out = await pipeline.process(photo());
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(out.reason, leftoverConflictReason);
      expect(dao.meals, isEmpty);
      expect(dao.ledger.containsKey('leftover-hash-1'), isFalse);
    });

    test('the add flow says why, in en and zh, and a backed-out pick keeps '
        'the reason', () async {
      dao.put(_meal(1, '01:34 PM', 965));
      analyzer.nextPhotoOutcome = AnalysisOutcome(
          analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
      var n = 0;
      dao.beforeCompareAndSet = (id) async => rewrite(id, ++n);
      final out = await pipeline.process(
          IntakePhoto(Uint8List.fromList([7]), 'w1', 'IMG_7.jpg',
              deliberate: true));
      expect(out.reason, leftoverConflictReason);
      final en = AppLocalizationsEn(), zh = AppLocalizationsZh();
      expect(outcomeBody(en, out, deliberate: true),
          'That meal changed while the leftovers were being estimated, so '
          'nothing was deducted. Try again.');
      expect(outcomeBody(zh, out, deliberate: true),
          '估算剩菜期间那一餐被修改了，所以没有扣除。请重试。');
      final picked = unannouncedOutcome(out, picked: true)!;
      expect(picked.reason, leftoverConflictReason);
      expect(outcomeSnackbar(zh, picked), contains('它所属的那一餐刚被修改'));
      expect(outcomeSnackbar(en, picked),
          contains('the meal it belongs to changed meanwhile'));
    });
  });

  test('low confidence falls through to a NORMAL new meal', () async {
    dao.put(_meal(1, '01:34 PM', 965));
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(confidence: 0.4),
        isFood: true,
        wall: Duration.zero);
    final out = await pipeline.process(photo());
    expect(out.kind, PhotoOutcomeKind.saved);
    expect(dao.meals, hasLength(2),
        reason: 'uncertain verdicts must not silently shrink a real meal');
    expect(dao.meals.first.analysis['total_calories'], 965,
        reason: 'the original is untouched');
  });

  test('the save and the deduction snackbars say 千卡 in Chinese, English '
      'word for word as before', () async {
    // The summary was English inside the zh frame: '已记录：… — ~485 kcal'
    // (simulator 2026-10-12).
    final en = AppLocalizationsEn(), zh = AppLocalizationsZh();
    dao.put(_meal(1, '01:34 PM', 965));
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
    final cut = await pipeline.process(photo());
    expect(cut.kind, PhotoOutcomeKind.leftoverApplied);
    expect(outcomeSnackbar(en, cut), cut.message);
    expect(outcomeSnackbar(zh, cut),
        '已扣除剩菜：Cafeteria tray 1 —— 减 300 千卡，现约 665 千卡');

    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: {
          'is_food': true,
          'meal_description': '红烧肉',
          'total_calories': 485,
        },
        isFood: true,
        wall: Duration.zero);
    final saved = await PhotoPipeline(
            dao: dao, analyzer: analyzer, hasher: (_) async => 'new-hash-2')
        .process(photo());
    expect(saved.kind, PhotoOutcomeKind.saved);
    expect(saved.message, 'Meal logged: 红烧肉 — ~485 kcal');
    expect(outcomeSnackbar(en, saved), saved.message);
    expect(outcomeSnackbar(zh, saved), '已记录：红烧肉 —— 约 485 千卡');
  });

  test('an out-of-range index falls through to a normal meal', () async {
    dao.put(_meal(1, '01:34 PM', 965));
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(index: 7),
        isFood: true,
        wall: Duration.zero);
    final out = await pipeline.process(photo());
    expect(out.kind, PhotoOutcomeKind.saved);
    expect(dao.meals, hasLength(2));
  });

  test('an empty day sends no candidates and a leftover_of reply cannot '
      'match anything', () async {
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
    final out = await pipeline.process(photo());
    expect(analyzer.lastRecentMeals, isEmpty);
    expect(out.kind, PhotoOutcomeKind.saved);
    expect(dao.meals, hasLength(1));
  });

  test('only the LAST five meals ride along, newest last', () async {
    for (var i = 1; i <= 7; i++) {
      dao.put(_meal(i, '0$i:00 AM', 400));
    }
    analyzer.nextPhotoOutcome =
        const AnalysisOutcome(analysis: {'is_food': false}, wall: Duration.zero);
    await pipeline.process(photo());
    expect(analyzer.lastRecentMeals, hasLength(5));
    expect(analyzer.lastRecentMeals!.last['meal_description'],
        'Cafeteria tray 7');
    expect(analyzer.lastRecentMeals!.first['meal_description'],
        'Cafeteria tray 3');
  });

  test('the Dart block format matches the server byte-for-byte', () {
    final block = formatRecentMealsBlock([
      recentMealCompact(time: '08:05 AM', analysis: {
        'meal_description': 'Soy milk',
        'total_calories': 110.4,
        'food_items': [
          {'name': 'Soy milk (~250 mL)', 'estimated_calories': 110},
        ],
      }),
    ]);
    expect(
        block,
        '\nRECENT MEALS (today, for the leftover check):\n'
        '[0] 08:05 AM — Soy milk (~110 kcal): '
        'Soy milk (~250 mL) (~110 kcal)');
  });

  test("candidates come from the PHOTO's day, never from today (loop find "
      '2026-10-07)', () async {
    // A backfilled / re-scanned photo from yesterday used to be offered
    // TODAY's meals as leftover candidates and could deduct from the wrong
    // one. The HEIC repair re-offered ~70 old photos exactly this way.
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final today = _meal(1, '01:34 PM', 965);
    final old = Meal(
      id: 2,
      date: isoDate(yesterday),
      time: '12:10 PM',
      timestamp: '${isoDate(yesterday)}T12:10:00',
      source: 'app_watch',
      imageHash: 'orig-2',
      analysis: {
        ...today.analysis,
        'meal_description': 'Yesterday tray',
      },
    );
    dao.put(today);
    dao.put(old);
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(confidence: 0.4), // falls through to save
        isFood: true,
        wall: Duration.zero);
    final shotYesterday = IntakePhoto(Uint8List.fromList([7]), 'w2', 'y.jpg',
        capturedAt: DateTime(
            yesterday.year, yesterday.month, yesterday.day, 13, 0));
    final out = await pipeline.process(shotYesterday);
    expect(out.kind, PhotoOutcomeKind.saved);
    expect(analyzer.lastRecentMeals!.map((m) => m['meal_description']),
        ['Yesterday tray'],
        reason: "only the photo's own day rides along");
    // And the saved meal lands on that day too.
    expect(dao.meals.last.date, isoDate(yesterday));
  });
  // UNDO (2026-10-09): a wrong automatic verdict used to be permanent —
  // the earlier meal stayed cut until its numbers were retyped, and
  // re-picking the photo repeated the verdict.
  test('the leftoverApplied outcome names the meal and its analysis as '
      'it stood BEFORE the deduction', () async {
    dao.put(_meal(1, '01:34 PM', 965));
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
    final out = await pipeline.process(photo());
    expect(out.kind, PhotoOutcomeKind.leftoverApplied);
    expect(out.mealId, 1);
    expect(out.mealDate, isoDate(DateTime.now()));
    expect(out.previousAnalysis!['total_calories'], 965);
    expect(out.previousAnalysis!.containsKey('leftover'), isFalse);
    expect(out.analysis!['leftover']['leftover_photo_md5'],
        'leftover-hash-1');
  });

  test('undo restores the meal, keeps corrected=1, and keeps an EARLIER '
      'correct deduction', () async {
    dao.put(_meal(1, '01:34 PM', 965));
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
    final first = await pipeline.process(photo());
    expect(dao.byId(1).analysis['total_calories'], 665);

    // A SECOND photo the model wrongly calls leftovers of the same meal.
    final second = PhotoPipeline(
        dao: dao, analyzer: analyzer, hasher: (_) async => 'leftover-hash-2');
    analyzer.nextPhotoOutcome = AnalysisOutcome(analysis: {
      ..._leftoverReply(),
      'items': [
        {'name': 'Rice (~200 g)', 'left_fraction': 0.0},
        {'name': 'Pork (~150 g)', 'left_fraction': 0.5},
      ],
    }, isFood: true, wall: Duration.zero);
    final wrong = await second.process(
        IntakePhoto(Uint8List.fromList([8]), 'w2', 'IMG_8.jpg'));
    expect(wrong.kind, PhotoOutcomeKind.leftoverApplied);
    expect(dao.byId(1).analysis['total_calories'], isNot(665));

    final restored = revertedLeftover(dao.byId(1).analysis,
        applied: wrong.analysis!, before: wrong.previousAnalysis!);
    expect(restored, isNotNull);
    await dao.updateMealAnalysis(1, restored!);
    final meal = dao.byId(1);
    expect(meal.analysis['total_calories'], 665,
        reason: 'only the wrong deduction is undone');
    expect(meal.analysis['leftover']['leftover_photo_md5'], 'leftover-hash-1');
    expect(meal.analysis['leftover']['applied_at'],
        first.analysis!['leftover']['applied_at']);
    expect(meal.corrected, isTrue,
        reason: 'spec §2.4: every analysis rewrite sets corrected=1');
  });

  test('undo is refused once the meal was fixed after the deduction, or '
      'for a different deduction', () async {
    dao.put(_meal(1, '01:34 PM', 965));
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _leftoverReply(), isFood: true, wall: Duration.zero);
    final out = await pipeline.process(photo());
    final deducted = dao.byId(1).analysis;

    // A chat or editor fix after the deduction is the user's newer truth.
    final fixed = {...deducted, 'total_calories': 700};
    expect(
        revertedLeftover(fixed,
            applied: out.analysis!, before: out.previousAnalysis!),
        isNull);

    // Another photo's deduction (or a re-application) is not this one.
    final other = {
      ...out.analysis!,
      'leftover': {
        ...(out.analysis!['leftover'] as Map),
        'leftover_photo_md5': 'someone-else',
      },
    };
    expect(
        revertedLeftover(deducted,
            applied: other, before: out.previousAnalysis!),
        isNull);
    final reapplied = {
      ...deducted,
      'leftover': {
        ...(deducted['leftover'] as Map),
        'applied_at': '2099-01-01T00:00:00',
      },
    };
    expect(
        revertedLeftover(reapplied,
            applied: out.analysis!, before: out.previousAnalysis!),
        isNull);
    // A meal with no deduction at all.
    expect(
        revertedLeftover(out.previousAnalysis!,
            applied: out.analysis!, before: out.previousAnalysis!),
        isNull);

    // Untouched since: allowed.
    expect(
        revertedLeftover(deducted,
            applied: out.analysis!,
            before: out.previousAnalysis!)!['total_calories'],
        965);
  });
}
