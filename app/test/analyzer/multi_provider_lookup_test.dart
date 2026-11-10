// MultiProviderAnalyzer as the restaurant lookup seam (design R5a): lookups
// go to the ACTIVE provider's lookup client (the owner's server through its
// job client), and analyzerBusy counts the foreground analyzer calls a
// lookup waits for — raised for every photo, leftover and text call, and
// always lowered again, on success, failure or a throw.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import 'server_analyzer_test.dart' show serverSettings;

/// Settings that fail on any read: the analyzer call throws.
class _ExplodingSettings implements AppSettings {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('settings unavailable');
}

final LookupRequest _bowl = LookupRequest.compose({
  'items': [
    {'name': 'Chicken burrito bowl', 'qty': 1, 'unit': 'bowl', 'brand': 'Chipotle'}
  ],
  'chains': ['chipotle'],
});

Uint8List _jpeg() =>
    Uint8List.fromList(img.encodeJpg(img.Image(width: 16, height: 16)));

http.Response _ok(http.Request req) => switch (req.url.path) {
      '/api/analyze_photo' => http.Response(
          jsonEncode({
            'ok': true,
            'analysis': {'is_food': true, 'total_calories': 500},
            'analyzed_by': 'claude',
          }),
          200),
      '/api/analyze_leftover' => http.Response(
          jsonEncode({
            'ok': true,
            'leftover': {'same_meal': true, 'leftover_fraction': 0.5},
            'analyzed_by': 'claude',
          }),
          200),
      _ => http.Response(
          jsonEncode({'ok': true, 'result': {'intent': 'query'}}), 200),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('analyzerBusy', () {
    test('each foreground call holds it while in flight, then lets go',
        () async {
      final s = await serverSettings();
      var gate = Completer<void>();
      final analyzer = MultiProviderAnalyzer(s, client: MockClient((req) async {
        await gate.future;
        return _ok(req);
      }));
      expect(analyzer.analyzerBusy.value, 0);
      final calls = <String, Future<Object?> Function()>{
        'photo': () => analyzer.analyzePhoto(_jpeg()),
        'leftover': () => analyzer.leftoverIntent(_jpeg(), '{}'),
        'text': () => analyzer.textIntent('what did I eat'),
        'text with reason': () => analyzer.textIntentOutcome('what did I eat'),
      };
      for (final e in calls.entries) {
        gate = Completer<void>();
        final f = e.value();
        await pumpEventQueue();
        expect(analyzer.analyzerBusy.value, 1, reason: '${e.key} in flight');
        gate.complete();
        await f;
        expect(analyzer.analyzerBusy.value, 0, reason: '${e.key} done');
      }
      // Two at once count as two.
      gate = Completer<void>();
      final a = analyzer.textIntent('a');
      final b = analyzer.analyzePhoto(_jpeg());
      await pumpEventQueue();
      expect(analyzer.analyzerBusy.value, 2);
      gate.complete();
      await Future.wait([a, b]);
      expect(analyzer.analyzerBusy.value, 0);
    });

    test('a failed call lets go', () async {
      final s = await serverSettings();
      final analyzer = MultiProviderAnalyzer(s,
          client: MockClient((_) async => http.Response('nope', 500)));
      final seen = <int>[];
      analyzer.analyzerBusy.addListener(() => seen.add(analyzer.analyzerBusy.value));
      expect(await analyzer.textIntent('x'), isNull);
      expect(await analyzer.leftoverIntent(_jpeg(), '{}'), isNull);
      expect(analyzer.analyzerBusy.value, 0);
      expect(seen, [1, 0, 1, 0]);
    });

    test('a call that throws lets go', () async {
      final analyzer = MultiProviderAnalyzer(_ExplodingSettings());
      await expectLater(analyzer.textIntent('x'), throwsStateError);
      await expectLater(analyzer.textIntentOutcome('x'), throwsStateError);
      await expectLater(
          analyzer.leftoverIntent(_jpeg(), '{}'), throwsStateError);
      expect(analyzer.analyzerBusy.value, 0);
    });

    test('a missing credential never reaches the provider and is not '
        'counted; key checks are not counted', () async {
      final s = await serverSettings(key: null);
      final analyzer = MultiProviderAnalyzer(s,
          client: MockClient((_) async => fail('no network expected')));
      final seen = <int>[];
      analyzer.analyzerBusy.addListener(() => seen.add(analyzer.analyzerBusy.value));
      await analyzer.analyzePhoto(_jpeg());
      await analyzer.validateKey('');
      expect(seen, isEmpty);
    });

    test('a lookup is not an analyzer call', () async {
      final s = await serverSettings(url: 'https://srv.example');
      final analyzer = MultiProviderAnalyzer(s,
          client: MockClient((_) async => http.Response(
              '{"state":"queued","job_id":"job_abcdefgh01"}', 202)));
      final seen = <int>[];
      analyzer.analyzerBusy.addListener(() => seen.add(analyzer.analyzerBusy.value));
      final support = analyzer.lookupSupport();
      await analyzer.submit(_bowl,
          expectedRecipient: support.recipient,
          expectedRecipientStamp: support.recipientStamp);
      await analyzer.poll('job_abcdefgh01');
      expect(seen, isEmpty);
    });
  });

  group('lookups follow the active provider', () {
    test('the owner server: its job client, with the https gate and '
        'the daily ledger', () async {
      final s = await serverSettings(url: 'https://srv.example');
      final requests = <http.Request>[];
      final budget = DailyLookupBudget(maxLookupsPerDay: 1);
      final analyzer = MultiProviderAnalyzer(s,
          lookupBudget: budget,
          client: MockClient((req) async {
            requests.add(req);
            return http.Response(
                '{"state":"queued","job_id":"job_abcdefgh01"}', 202);
          }));
      final support = analyzer.lookupSupport();
      expect(support.supported, isTrue);
      expect(support.recipient, LookupRecipient.claudePlan);
      expect(support.locationAllowed, isTrue);
      expect(support.recipientStamp, startsWith('claude_plan:'));
      final o = await analyzer.submit(_bowl,
          expectedRecipient: support.recipient,
          expectedRecipientStamp: support.recipientStamp);
      expect(o.kind, LookupOutcomeKind.pending);
      expect(o.jobId, 'job_abcdefgh01');
      expect(requests.single.url.path, '/api/restaurant_lookup');
      final again = await analyzer.submit(_bowl,
          expectedRecipient: support.recipient,
          expectedRecipientStamp: support.recipientStamp);
      expect(again.failure!.code, LookupFailureCode.dailyCap);
      expect(requests, hasLength(1));

      await s.setServerBaseUrl('http://10.0.0.5');
      expect(analyzer.lookupSupport().locationAllowed, isFalse);
    });

    test('a provider switch after the consent check: nothing is sent',
        () async {
      final s = await serverSettings(url: 'https://srv.example');
      await s.setAnthropicApiKey('ak');
      final requests = <http.Request>[];
      final analyzer = MultiProviderAnalyzer(s, client: MockClient((req) async {
        requests.add(req);
        return http.Response('{}', 500);
      }));
      final consented = analyzer.lookupSupport();
      await s.setProvider(AiProvider.anthropic);
      final o = await analyzer.submit(_bowl,
          expectedRecipient: consented.recipient,
          expectedRecipientStamp: consented.recipientStamp);
      expect(o.failure!.code, LookupFailureCode.consentChanged);
      expect(requests, isEmpty);
    });

    test('Claude Plan on the glm backend: unsupported, zero calls', () async {
      final s = await serverSettings(url: 'https://srv.example');
      await s.setServerBackend('glm');
      final analyzer = MultiProviderAnalyzer(s,
          client: MockClient((_) async => fail('no network expected')));
      final support = analyzer.lookupSupport();
      expect(support.supported, isFalse);
      expect(support.reason, LookupUnsupportedReason.serverBackendNotClaude);
      final o = await analyzer.submit(_bowl,
          expectedRecipient: support.recipient,
          expectedRecipientStamp: support.recipientStamp);
      expect(o.kind, LookupOutcomeKind.unsupported);
    });
  });
}
