// The one https-only client in front of the user's own server
// (services/server_http_client.dart; review of the privacy lane, findings
// 3 and 4). ServerAnalyzer, ServerLookupClient and the Garmin fetch send
// every request through it: an address the app sends nothing to never
// reaches the network, whatever method sends, and no redirect is ever
// followed (dart:io copies X-API-Key onto the next hop).
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/core/ai_consent.dart' show aiConsentRoute;
import 'package:calorie_tracker/core/server_transport.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/server_lookup_client.dart';
import 'package:calorie_tracker/services/garmin_client.dart';
import 'package:calorie_tracker/services/server_http_client.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;

/// Records what reaches the network, and answers like a server that
/// accepts everything.
class _Recording extends http.BaseClient {
  final seen = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request);
    final body = jsonEncode({
      'ok': true,
      'analysis': {'is_food': true, 'total_calories': 500},
      'result': {'ok': true},
      'analyzed_by': 'claude',
      'url': 'https://claude.ai/oauth/authorize?x=1',
      'claude_login': 'token',
      'backends': {'claude': 'enabled'},
      'features': {'lookup_jobs': true},
      'leftover': {'items': []},
      'available': true,
      'steps': 1,
      'state': 'queued',
      'job_id': 'job_abcdefgh01',
    });
    return http.StreamedResponse(
        Stream.value(utf8.encode(body)), request.url.path.contains('lookup') ? 202 : 200,
        headers: {'content-type': 'application/json'}, request: request);
  }
}

Future<AppSettings> _server(String url) async {
  SharedPreferences.setMockInitialValues({});
  final s = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(), keyStore: MemoryKeyStore());
  await s.setProvider(AiProvider.server);
  await s.setServerBaseUrl(url);
  await s.setServerApiKey('upload-key');
  await s.setAiConsent(aiConsentRoute('server', 'claude'), granted: true);
  return s;
}

final _lookup = LookupRequest.compose({
  'items': [
    {'name': 'Big Mac', 'qty': 1, 'brand': "McDonald's"}
  ],
  'chains': ['mcdonalds'],
});

/// Every method of the three clients that reaches the server.
Future<void> _everything(AppSettings s, http.Client inner) async {
  final a = ServerAnalyzer(s, client: inner, normalizer: (b) async => b,
      sleep: (_) async {});
  await a.analyzePhoto(Uint8List.fromList([1, 2, 3]));
  await a.textIntentOutcome('lunch 500 kcal');
  await a.leftoverIntent(Uint8List.fromList([1, 2, 3]), '{}');
  await a.validateKey('upload-key');
  await a.probeKey('upload-key');
  await a.serverLoginState();
  await a.serverFeatures();
  await a.startClaudeAuth();
  await a.completeClaudeAuth('code#state');
  final lookups = ServerLookupClient(s, client: inner);
  final support = lookups.lookupSupport();
  await lookups.submit(_lookup,
      expectedRecipient: support.recipient,
      expectedRecipientStamp: support.recipientStamp);
  await lookups.poll('job_abcdefgh01');
  await makeGarminDailyFetch(s, client: inner)('2026-11-13');
}

void main() {
  tearDown(() => debugRequireHttpsServerOverride = null);

  group('HttpsOnlyServerClient', () {
    for (final require in [true, false]) {
      test('switch ${require ? 'on' : 'off'}: an http:// request '
          '${require ? 'never reaches the network' : 'is sent'}', () async {
        debugRequireHttpsServerOverride = require;
        final inner = _Recording();
        final c = HttpsOnlyServerClient(inner);
        final send = c.post(Uri.parse('http://10.0.0.5/api/anything'),
            headers: {'X-API-Key': 'upload-key'});
        if (require) {
          await expectLater(send, throwsA(isA<ServerNeedsHttpsException>()));
          expect(inner.seen, isEmpty);
        } else {
          await send;
          expect(inner.seen.single.followRedirects, isFalse);
        }
      });
    }

    test('https:// and, in a debug build, http:// to this device pass, with '
        'redirects off', () async {
      debugRequireHttpsServerOverride = true;
      final inner = _Recording();
      final c = HttpsOnlyServerClient(inner);
      await c.get(Uri.parse('https://h.example/api/auth_check'));
      await c.get(Uri.parse('http://127.0.0.1:5000/api/auth_check'));
      expect(inner.seen.map((r) => r.url.host), ['h.example', '127.0.0.1']);
      expect(inner.seen.every((r) => !r.followRedirects), isTrue);
    });

    test('the refusal is a ClientException carrying the needs-https line',
        () {
      final e = ServerNeedsHttpsException(Uri.parse('http://10.0.0.5'));
      expect(e, isA<http.ClientException>());
      expect(e.message, kServerNeedsHttpsMessage);
    });

    test('wrap is idempotent', () {
      final once = HttpsOnlyServerClient.wrap(_Recording());
      expect(HttpsOnlyServerClient.wrap(once), same(once));
      expect(HttpsOnlyServerClient.wrap(null), isA<HttpsOnlyServerClient>());
    });
  });

  group('every request of the three clients goes through it', () {
    // Only HttpsOnlyServerClient sets followRedirects to false, so a
    // request that reached the network with it true went around it.
    test('https://: everything is sent, none of it with redirects on',
        () async {
      debugRequireHttpsServerOverride = true;
      final inner = _Recording();
      await _everything(await _server('https://h.example'), inner);
      expect(inner.seen.map((r) => r.url.path).toSet(), {
        '/api/analyze_photo',
        '/api/text_intent',
        '/api/analyze_leftover',
        '/api/auth_check',
        '/api/claude_auth/start',
        '/api/claude_auth/complete',
        '/api/restaurant_lookup',
        '/api/restaurant_lookup/status',
        '/api/garmin_daily',
      });
      for (final r in inner.seen) {
        expect(r.followRedirects, isFalse, reason: '${r.url}');
      }
    });

    test('http:// with the switch on: nothing reaches the network', () async {
      debugRequireHttpsServerOverride = true;
      final inner = _Recording();
      await _everything(await _server('http://10.0.0.5'), inner);
      expect(inner.seen, isEmpty);
    });

    test('a server call no method checks (a method added later) is '
        'refused at the client', () async {
      debugRequireHttpsServerOverride = true;
      final inner = _Recording();
      final a = ServerAnalyzer(await _server('http://10.0.0.5'), client: inner);
      expect(a.client, isA<HttpsOnlyServerClient>());
      await expectLater(
          a.client.post(Uri.parse('http://10.0.0.5/api/new_endpoint'),
              headers: {'X-API-Key': 'upload-key'}),
          throwsA(isA<ServerNeedsHttpsException>()));
      expect(inner.seen, isEmpty);
      // The Garmin fetch has no check of its own: the client is it.
      expect(
          await makeGarminDailyFetch(await _server('http://10.0.0.5'),
              client: inner)('2026-11-13'),
          isNull);
      expect(inner.seen, isEmpty);
    });

    test('the lookup client: unsupported first, and the client behind it',
        () async {
      debugRequireHttpsServerOverride = true;
      final inner = _Recording();
      final c = ServerLookupClient(await _server('http://10.0.0.5'),
          client: inner);
      expect(c.lookupSupport().reason, LookupUnsupportedReason.noServerAddress);
      expect((await c.poll('job_abcdefgh01')).kind,
          LookupOutcomeKind.unsupported);
      expect(inner.seen, isEmpty);
    });
  });
}
