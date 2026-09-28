// The phone-side credential check (2026-09-28): with no key configured the
// analyzer must answer BEFORE any transport, name the right remedy for the
// selected path, and keep the photo eligible (retryable).
import 'dart:typed_data';

import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory stand-in for flutter_secure_storage — the real one is a
/// platform channel with no implementation under `flutter test`.
class _MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Future<AppSettings> _fresh() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppSettings.load(prefs: prefs, keyStore: _MemoryKeyStore());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bytes = Uint8List.fromList(List.filled(64, 7));
  // Any network call is a test failure: the whole point is that none happens.
  final noNetwork = MockClient((req) async => fail('network call to ${req.url}'));

  test('API-key provider with no key → noApiKey, retryable, no transport',
      () async {
    final settings = await _fresh(); // default provider: Gemini
    final analyzer = MultiProviderAnalyzer(settings, client: noNetwork);
    final out = await analyzer.analyzePhoto(bytes);
    expect(out.analysis, isNull);
    expect(out.retryable, isTrue);
    expect(out.error, contains('Gemini'));
    expect(classifyAnalysisError(out.error), AnalysisErrorKind.noApiKey);
  });

  test('subscription/server path with nothing configured → noServerKey',
      () async {
    final settings = await _fresh();
    await settings.setProvider(AiProvider.server);
    final analyzer = MultiProviderAnalyzer(settings, client: noNetwork);
    final out = await analyzer.analyzePhoto(bytes);
    expect(out.retryable, isTrue);
    expect(classifyAnalysisError(out.error), AnalysisErrorKind.noServerKey,
        reason: 'a Claude-plan user must not be told about a Gemini key');
  });
}
