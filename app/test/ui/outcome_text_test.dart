// outcomeBody is what the add-flow dialog and the headless meal card show.
// English must stay byte-identical to the pipeline's own prose (older tests
// pin it); Chinese must never leak English for a recognised kind; anything
// unrecognised falls back to the raw line rather than a wrong guess.
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();

  test('English is byte-identical to the pipeline message', () {
    const saved = PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged: Ramen (~600 kcal)',
        detail: 'Ramen (~600 kcal)');
    expect(outcomeBody(en, saved), saved.message);
    const skipped = PhotoOutcome(PhotoOutcomeKind.skipped, 'No food detected in this photo.');
    expect(outcomeBody(en, skipped), skipped.message);
    const dup = PhotoOutcome(PhotoOutcomeKind.duplicate,
        'Looks like a duplicate of a photo logged minutes ago.');
    expect(outcomeBody(en, dup), dup.message);
    const tracked = PhotoOutcome(PhotoOutcomeKind.alreadyTracked, 'This photo was already logged.');
    expect(outcomeBody(en, tracked), tracked.message);
    const inFlight = PhotoOutcome(PhotoOutcomeKind.inFlight,
        'This photo is still being analyzed — check back in a moment.',
        retryable: true);
    expect(outcomeBody(en, inFlight), inFlight.message);
  });

  test('a photo mid-analysis elsewhere is "still analyzing", not "already '
      'logged", in both languages', () {
    // The deliberate add used to answer 已经记录过了 for a photo the watcher
    // (or an iOS run cut off mid-analysis) was still holding (2026-10-07).
    const o = PhotoOutcome(PhotoOutcomeKind.inFlight,
        'This photo is still being analyzed — check back in a moment.',
        retryable: true);
    expect(outcomeBody(zh, o), zh.outcomeInFlightMsg);
    expect(outcomeBody(zh, o), isNot(zh.outcomeAlreadyTrackedMsg));
    expect(RegExp(r'[a-z]{4,}').hasMatch(outcomeBody(zh, o)), isFalse,
        reason: 'no English leaking into the Chinese UI');
    expect(outcomeBody(en, o), isNot(en.outcomeAlreadyTrackedMsg));
    expect(en.outcomeInFlight, isNot(en.outcomeAlreadyTracked));
    expect(zh.outcomeInFlight, isNot(zh.outcomeAlreadyTracked));
  });

  test('Chinese for every recognised failure kind, no English leaking', () {
    for (final kind in AnalysisErrorKind.values) {
      if (kind == AnalysisErrorKind.none || kind == AnalysisErrorKind.unknown) continue;
      final o = PhotoOutcome(PhotoOutcomeKind.failed, 'raw english line',
          errorKind: kind, detail: 'raw english line');
      final body = outcomeBody(zh, o);
      expect(RegExp(r'[a-z]{4,}').hasMatch(body), isFalse,
          reason: '$kind -> $body');
    }
  });

  test('unrecognised failures fall back to the raw message', () {
    const o = PhotoOutcome(PhotoOutcomeKind.failed, 'Provider request failed: 418',
        errorKind: AnalysisErrorKind.unknown, detail: 'Provider request failed: 418');
    expect(outcomeBody(zh, o), o.message);
    expect(outcomeBody(en, o), o.message);
  });

  test('a saved outcome without detail (older callers) keeps its message', () {
    const o = PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged: ok');
    expect(outcomeBody(zh, o), 'Meal logged: ok');
  });

  test('the no-key case names the SERVER path for subscription users', () {
    const o = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
        errorKind: AnalysisErrorKind.noServerKey, detail: 'x');
    expect(outcomeBody(zh, o), contains('服务器'));
    expect(outcomeBody(en, o), contains('server'));
  });

  group('outcomeSnackbar (the pipeline notify in di.dart)', () {
    // The snackbar used to get the pipeline's English sentence verbatim, so
    // every photo the automatic scan saved with the app open said "Meal
    // logged: …" in the Chinese UI (2026-10-08).
    const saved = PhotoOutcome(
        PhotoOutcomeKind.saved, 'Meal logged: Ramen — ~600 kcal',
        detail: 'Ramen — ~600 kcal');
    const leftover = PhotoOutcome(PhotoOutcomeKind.leftoverApplied,
        'Leftovers deducted: Ramen — −180 kcal, now ~420 kcal',
        detail: 'Ramen — −180 kcal, now ~420 kcal');

    test('English is byte-identical to what the snackbar used to show', () {
      expect(outcomeSnackbar(en, saved), 'Meal logged: Ramen — ~600 kcal');
      expect(outcomeSnackbar(en, leftover),
          'Leftovers deducted: Ramen — −180 kcal, now ~420 kcal');
      const failed = PhotoOutcome(PhotoOutcomeKind.failed, 'Provider said no',
          errorKind: AnalysisErrorKind.unknown, detail: 'Provider said no');
      expect(outcomeSnackbar(en, failed),
          'Photo analysis failed — kept for retry. Provider said no');
    });

    test('Chinese frames the save and the deduction in Chinese', () {
      expect(outcomeSnackbar(zh, saved), startsWith('已记录'));
      expect(outcomeSnackbar(zh, saved), isNot(contains('Meal logged')));
      expect(outcomeSnackbar(zh, leftover), startsWith('已扣除剩菜'));
      expect(outcomeSnackbar(zh, leftover),
          isNot(contains('Leftovers deducted')));
    });

    test('a recognised permanent failure has no English in Chinese', () {
      const o = PhotoOutcome(PhotoOutcomeKind.failed, 'raw english line',
          errorKind: AnalysisErrorKind.badPhoto, detail: 'raw english line');
      final body = outcomeSnackbar(zh, o);
      expect(body, startsWith('照片分析失败'));
      expect(body, contains(zh.errBadPhoto));
      expect(RegExp(r'[a-z]{4,}').hasMatch(body), isFalse, reason: body);
    });

    test('the backlog warning is Chinese too', () {
      expect(RegExp(r'[a-z]{4,}').hasMatch(zh.backlogTruncatedWarning),
          isFalse);
      expect(en.backlogTruncatedWarning,
          'Photo library backlog is very large — some older photos may need '
          'to be added manually.');
    });
  });

  test('a server rejection shows the CODE in both languages', () {
    const o = PhotoOutcome(
        PhotoOutcomeKind.failed, 'The server rejected this request (bad_model).',
        errorKind: AnalysisErrorKind.serverRejected,
        detail: 'The server rejected this request (bad_model).');
    expect(outcomeBody(zh, o), contains('bad_model'));
    expect(outcomeBody(en, o), contains('bad_model'));
    expect(rejectionCode('no code here'), '?');
  });
}
