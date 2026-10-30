// HTTP failure classification: the lookup clients must read a provider's
// answer exactly as the photo analyzers do. The parity group runs ONE
// status/body matrix through classifyHttpFailure and through the real
// analyzers' probeKey (whose result is a pure function of the analyzers'
// private classification), so a rule changed on one side alone fails here.
import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/assist/clients/http_failure.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

String _err(String type, String message, {String? code}) => jsonEncode({
      'error': {
        'type': type,
        'message': message,
        'code': ?code,
      }
    });

/// (status, body, expected code, expected transient)
final List<(int, String, LookupFailureCode, bool)> matrix = [
  (401, _err('authentication_error', 'invalid x-api-key'),
      LookupFailureCode.auth, false),
  (403, _err('permission_error', 'no access'), LookupFailureCode.auth, false),
  (401, '<html>Sign in to Wi-Fi</html>', LookupFailureCode.captivePortal,
      true),
  (400, _err('invalid_request_error', 'Incorrect API key provided'),
      LookupFailureCode.auth, false),
  (402, _err('payment_required', 'Insufficient credits'),
      LookupFailureCode.billing, true),
  (429, _err('insufficient_quota', 'quota', code: 'insufficient_quota'),
      LookupFailureCode.billing, true),
  (400,
      _err('invalid_request_error',
          'Your credit balance is too low to access the Anthropic API.'),
      LookupFailureCode.billing, true),
  (403, _err('forbidden', 'Country not supported',
          code: 'unsupported_country_region_territory'),
      LookupFailureCode.regionBlocked, true),
  (404, _err('not_found_error', 'model: claude-haiku-9'),
      LookupFailureCode.modelNotFound, false),
  (429, _err('rate_limit_error', 'slow down'), LookupFailureCode.rateLimited,
      true),
  (500, _err('api_error', 'internal'), LookupFailureCode.server, true),
  (529, _err('overloaded_error', 'Overloaded'), LookupFailureCode.server,
      true),
  (503, 'upstream connect error', LookupFailureCode.server, true),
  (302, '', LookupFailureCode.captivePortal, true),
  (400, _err('invalid_request_error', 'max_tokens: must be positive'),
      LookupFailureCode.badRequest, false),
  (422, _err('unprocessable', 'nope'), LookupFailureCode.badRequest, false),
];

KeyProbeResult _expectedProbe(LookupFailureCode code, bool transient) =>
    switch (code) {
      LookupFailureCode.billing => KeyProbeResult.outOfCredit,
      LookupFailureCode.regionBlocked => KeyProbeResult.regionBlocked,
      LookupFailureCode.modelNotFound => KeyProbeResult.modelNotFound,
      LookupFailureCode.auth => KeyProbeResult.rejected,
      _ when transient => KeyProbeResult.rateLimited,
      _ => KeyProbeResult.rejected,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classifyHttpFailure', () {
    for (final (status, body, code, transient) in matrix) {
      test('$status ${body.length > 40 ? body.substring(0, 40) : body}', () {
        final f = classifyHttpFailure(status, body, providerLabel: 'Anthropic');
        expect(f.code, code);
        expect(f.transient, transient);
      });
    }

    test('web search disabled by an org admin is its own permanent code', () {
      final f = classifyHttpFailure(
          400,
          _err('invalid_request_error',
              'Web search is not enabled for this organization.'),
          providerLabel: 'Anthropic');
      expect(f.code, LookupFailureCode.searchDisabled);
      expect(f.transient, isFalse);
    });

    test('messages never echo the body (it can quote the request)', () {
      for (final (status, body, _, _) in matrix) {
        final f = classifyHttpFailure(status, body, providerLabel: 'X');
        if (body.length > 12) {
          expect(f.message.contains(body), isFalse, reason: '$status');
        }
      }
    });

    test('an error object inside a 200 is classified by its code', () {
      expect(
          classifyHttpFailureFromErrorObject(
                  402, {'code': 402, 'message': 'credits'})
              .code,
          LookupFailureCode.billing);
      expect(
          classifyHttpFailureFromErrorObject(
                  502, {'code': 502, 'message': 'Provider returned error'})
              .code,
          LookupFailureCode.server);
    });

    test('outcome kinds', () {
      LookupOutcomeKind k(LookupFailureCode c) =>
          outcomeKindFor(LookupFailure(c, transient: true));
      expect(k(LookupFailureCode.rateLimited), LookupOutcomeKind.rateLimited);
      expect(k(LookupFailureCode.dailyCap), LookupOutcomeKind.rateLimited);
      expect(k(LookupFailureCode.network), LookupOutcomeKind.offline);
      expect(k(LookupFailureCode.captivePortal), LookupOutcomeKind.offline);
      expect(k(LookupFailureCode.timeout), LookupOutcomeKind.failed);
      expect(k(LookupFailureCode.auth), LookupOutcomeKind.failed);
      expect(k(LookupFailureCode.costCap), LookupOutcomeKind.failed);
    });
  });

  group('parity with the photo analyzers (probeKey)', () {
    Future<AppSettings> settings() async {
      SharedPreferences.setMockInitialValues({});
      return AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _Keys());
    }

    for (final (status, body, code, transient) in matrix) {
      test('$status → ${code.name}', () async {
        final s = await settings();
        final client = MockClient((_) async => http.Response(body, status));
        for (final analyzer in <AnalyzerService>[
          OpenAiAnalyzer(s, client: client),
          AnthropicAnalyzer(s, client: client),
          createOpenRouterAnalyzer(s, client: client),
        ]) {
          final probe = await analyzer.probeKey('test-key');
          expect(probe.result, _expectedProbe(code, transient),
              reason: '${analyzer.runtimeType} on $status');
        }
      });
    }
  });
}
