// The phone-side credential check (2026-09-28): with no key configured the
// analyzer must answer BEFORE any transport, name the right remedy for the
// selected path, and keep the photo eligible (retryable).
import 'dart:typed_data';

import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bytes = Uint8List.fromList(List.filled(64, 7));
  // Any network call is a test failure: the whole point is that none happens.
  final noNetwork = MockClient((req) async => fail('network call to ${req.url}'));

  test('API-key provider with no key → noApiKey, retryable, no transport',
      () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load(); // default provider: Gemini
    final analyzer = MultiProviderAnalyzer(settings, client: noNetwork);
    final out = await analyzer.analyzePhoto(bytes);
    expect(out.analysis, isNull);
    expect(out.retryable, isTrue);
    expect(out.error, contains('Gemini'));
    expect(classifyAnalysisError(out.error), AnalysisErrorKind.noApiKey);
  });

  test('subscription/server path with nothing configured → noServerKey',
      () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    await settings.setProvider(AiProvider.server);
    final analyzer = MultiProviderAnalyzer(settings, client: noNetwork);
    final out = await analyzer.analyzePhoto(bytes);
    expect(out.retryable, isTrue);
    expect(classifyAnalysisError(out.error), AnalysisErrorKind.noServerKey,
        reason: 'a Claude-plan user must not be told about a Gemini key');
  });
}
