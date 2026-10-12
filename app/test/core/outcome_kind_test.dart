// The classifier runs over OUR OWN analyzer prose (parity-pinned), so each
// exact line the analyzers emit is pinned to its kind here — a reworded
// message that silently fell to `unknown` would show English again.
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cases = <String, AnalysisErrorKind>{
    'No Qwen API key — add one in Settings.': AnalysisErrorKind.noApiKey,
    'No Gemini API key — add one in Settings.': AnalysisErrorKind.noApiKey,
    'No server address or upload key is set — add them in Settings.':
        AnalysisErrorKind.noServerKey,
    'Gemini rejected the API key. Check the key in Settings.':
        AnalysisErrorKind.rejectedKey,
    'The provider rejected the API key. Check Settings.':
        AnalysisErrorKind.rejectedKey,
    'Gemini rate limit hit — please try again shortly.':
        AnalysisErrorKind.rateLimited,
    'Provider rate/spend limit hit — will retry later.':
        AnalysisErrorKind.rateLimited,
    'Gemini daily quota exhausted — analysis paused.':
        AnalysisErrorKind.quotaPaused,
    'Analysis paused (quota) — retrying later.': AnalysisErrorKind.quotaPaused,
    'Error contacting Gemini (network or service issue). Please try again.':
        AnalysisErrorKind.network,
    'Error contacting the provider (network or service issue).':
        AnalysisErrorKind.network,
    'Gemini model error — check the model name in Settings.':
        AnalysisErrorKind.badModel,
    "Couldn't understand the AI response.": AnalysisErrorKind.badResponse,
    'The AI returned an unusable analysis.': AnalysisErrorKind.badResponse,
    'Could not process this photo (decode failed and it is not a JPEG).':
        AnalysisErrorKind.badPhoto,
    'The server cannot analyze right now: analysis failed.':
        AnalysisErrorKind.serverError,
    'Provider request failed: something odd': AnalysisErrorKind.unknown,
  };

  test('every analyzer line lands on its kind', () {
    cases.forEach((line, kind) {
      expect(classifyAnalysisError(line), kind, reason: line);
    });
  });

  test('empty / null is none, not unknown', () {
    expect(classifyAnalysisError(null), AnalysisErrorKind.none);
    expect(classifyAnalysisError('   '), AnalysisErrorKind.none);
  });

  test('the Gemini pause line is a PAUSE even though it mentions the tier',
      () {
    expect(
        classifyAnalysisError(
            'Gemini daily free-tier quota exhausted — analysis paused until '
            '2026-09-29T00:00:00 (~8h 3m left). Photos are kept as failed '
            'and can be retried later.'),
        AnalysisErrorKind.quotaPaused);
  });
}
