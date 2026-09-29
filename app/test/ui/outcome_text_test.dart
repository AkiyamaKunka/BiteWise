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
}
