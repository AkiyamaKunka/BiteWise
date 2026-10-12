// The automatic-scan pause (AppSettings.analysis_blocked_*) end to end,
// with the REAL settings, analyzers and pipeline: the pause must be armed
// by nothing but a genuine credential refusal, and anything that proves
// the credentials work must lift it (second adversarial review of the
// latch, 2026-10-12).
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart' show FakeDao;

class _MemKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

IntakePhoto _auto(int n) =>
    IntakePhoto(Uint8List.fromList([n, n, n]), 'a$n', 'IMG_$n.jpg');

void main() {
  group('a web filter / captive portal answering 401/403', () {
    // The owner's Claude Plan server is plain HTTP; its own 401 is JSON
    // {"error":"Unauthorized"}. An HTML/text 401/403 is something on the
    // path answering instead, and read as "key rejected" it parked the
    // automatic scan for 24 h on a key that works (probes A1/A2).
    final pages = {
      'HTML 403': () => http.Response(
          '<html><body><h1>403 Forbidden</h1>Access denied by web filter'
          '</body></html>',
          403,
          headers: {'content-type': 'text/html'}),
      'text 401': () => http.Response('Login required', 401),
    };
    for (final entry in pages.entries) {
      test('${entry.key}: no pause, the photo is released for the next scan',
          () async {
        SharedPreferences.setMockInitialValues({});
        final s = await AppSettings.load(
            prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
        await s.setProvider(AiProvider.server);
        await s.setServerBaseUrl('http://10.0.0.5');
        await s.setServerApiKey('k');
        final analyzer = ServerAnalyzer(s,
            normalizer: (b) async => b,
            sleep: (_) async {},
            client: MockClient((_) async => entry.value()));
        final dao = FakeDao();
        final out = await PhotoPipeline(
                dao: dao, analyzer: analyzer, latch: autoScanLatchFor(s))
            .process(_auto(1));
        expect(out.kind, PhotoOutcomeKind.failed);
        expect(out.retryable, isTrue, reason: '${out.detail}');
        expect(out.errorKind, AnalysisErrorKind.network,
            reason: '${out.detail}');
        expect(dao.ledger, isEmpty, reason: 'released, not burned');
        expect(s.isAnalysisBlocked, isFalse);
        expect(s.canAutoAnalyze, isTrue);
      });
    }

    test('a JSON 401 from the server itself still pauses the scan', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('http://10.0.0.5');
      await s.setServerApiKey('k');
      final analyzer = ServerAnalyzer(s,
          normalizer: (b) async => b,
          sleep: (_) async {},
          client: MockClient(
              (_) async => http.Response('{"error": "Unauthorized"}', 401)));
      final out = await PhotoPipeline(
              dao: FakeDao(), analyzer: analyzer, latch: autoScanLatchFor(s))
          .process(_auto(1));
      expect(out.errorKind, AnalysisErrorKind.rejectedKey);
      expect(s.analysisBlockedKind, 'rejectedKey');
    });
  });
}
