// HTTP failure classification: the lookup clients must read a provider's
// answer exactly as the photo analyzers do. The parity group runs ONE
// status/body matrix through classifyHttpFailure and through the real
// analyzers' probeKey (whose result is a pure function of the analyzers'
// private classification), so a rule changed on one side alone fails here.
// The 'every rule of both ladders' group pins each one's whole answer
// (code, message, retries) for every status/body rule they read.
import 'dart:convert';
import 'dart:typed_data';

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

/// What the photo analyzers make of one reply: analyzePhoto's error, its
/// retryable flag and the HTTP calls it made (3 = retried in place),
/// probeKey's result and message, and validateKey's answer (null = the key
/// is accepted).
typedef _Photo = ({
  String error,
  bool retryable,
  int calls,
  KeyProbeResult probe,
  String? probeMessage,
  String? validate,
});

/// What a lookup client makes of it: classifyHttpFailure.
typedef _Lookup = ({LookupFailureCode code, bool transient, String message});

const String _billingMsg =
    'Provider balance or credits exhausted — check your Vendor billing.';
const String _regionMsg =
    'Vendor is not available from your current network region (check the '
    'VPN).';
const String _netMsg =
    'Error contacting the provider (network or service issue).';
const String _authMsg = 'The provider rejected the API key. Check Settings.';
const String _rateMsg = 'Provider rate/spend limit hit — will retry later.';
const String _hint = 'Vendor model not found — check the hint.';

const _Photo _billingP = (
  error: _billingMsg,
  retryable: true,
  calls: 1,
  probe: KeyProbeResult.outOfCredit,
  probeMessage: _billingMsg,
  validate: null,
);
const _Photo _regionP = (
  error: _regionMsg,
  retryable: true,
  calls: 1,
  probe: KeyProbeResult.regionBlocked,
  probeMessage: _regionMsg,
  validate: _regionMsg,
);

/// A portal or proxy answering (a non-JSON 401/403, a 3xx).
const _Photo _portalP = (
  error: _netMsg,
  retryable: true,
  calls: 1,
  probe: KeyProbeResult.rateLimited,
  probeMessage: _netMsg,
  validate: _netMsg,
);
const _Photo _authP = (
  error: _authMsg,
  retryable: false,
  calls: 1,
  probe: KeyProbeResult.rejected,
  probeMessage: null,
  validate: _authMsg,
);
const _Photo _rateP = (
  error: _rateMsg,
  retryable: true,
  calls: 1,
  probe: KeyProbeResult.rateLimited,
  probeMessage: _rateMsg,
  validate: null,
);
const _Photo _serverP = (
  error: _netMsg,
  retryable: true,
  calls: 3,
  probe: KeyProbeResult.rateLimited,
  probeMessage: _netMsg,
  validate: _netMsg,
);

_Photo _failedP(int status) => (
  error: 'Provider request failed: HTTP $status',
  retryable: false,
  calls: 1,
  probe: KeyProbeResult.rejected,
  probeMessage: 'Provider request failed: HTTP $status',
  validate: 'Provider request failed: HTTP $status',
);

_Photo _modelP(String message) => (
  error: message,
  retryable: false,
  calls: 1,
  probe: KeyProbeResult.modelNotFound,
  probeMessage: message,
  validate: message,
);

const _Lookup _billingL = (
  code: LookupFailureCode.billing,
  transient: true,
  message: _billingMsg,
);
const _Lookup _regionL = (
  code: LookupFailureCode.regionBlocked,
  transient: true,
  message: _regionMsg,
);
const _Lookup _authL = (
  code: LookupFailureCode.auth,
  transient: false,
  message: 'key rejected',
);
const _Lookup _modelL = (
  code: LookupFailureCode.modelNotFound,
  transient: false,
  message: 'Vendor model not found (unknown or retired).',
);
const _Lookup _rateL = (
  code: LookupFailureCode.rateLimited,
  transient: true,
  message: 'HTTP 429',
);

_Lookup _nonJsonL(int status) => (
  code: LookupFailureCode.captivePortal,
  transient: true,
  message: 'HTTP $status non-JSON reply (captive portal or proxy page)',
);
_Lookup _redirectL(int status) => (
  code: LookupFailureCode.captivePortal,
  transient: true,
  message: 'HTTP $status redirect (captive portal or proxy)',
);
_Lookup _serverL(int status) => (
  code: LookupFailureCode.server,
  transient: true,
  message: 'HTTP $status',
);
_Lookup _badRequestL(int status) => (
  code: LookupFailureCode.badRequest,
  transient: false,
  message: 'HTTP $status',
);

String _code(String code) => jsonEncode({
      'error': {'code': code, 'message': 'x'}
    });

/// (status, body, the lookup answer, the photo answer without a 404 hint,
/// and with one when that differs)
final List<(int, String, _Lookup, _Photo, _Photo?)> _ladderRows = [
  // Exhausted billing: each signature, at its own status only.
  (402, '{}', _billingL, _billingP, null),
  (402, '<html>Payment Required</html>', _billingL, _billingP, null),
  (429, _code('insufficient_quota'), _billingL, _billingP, null),
  (429, _code('1113'), _billingL, _billingP, null),
  (403, _code('AccountOverdueError'), _billingL, _billingP, null),
  // Before the non-JSON 401/403 rule.
  (403, 'AccountOverdue', _billingL, _billingP, null),
  (400, _code('Arrearage'), _billingL, _billingP, null),
  (400, _err('invalid_request_error', 'Your credit balance is too low.'),
      _billingL, _billingP, null),
  (401, _code('insufficient_quota'), _authL, _authP, null),
  (403, _code('1113'), _authL, _authP, null),
  (400, _code('1113'), _badRequestL(400), _failedP(400), null),
  (429, _code('Arrearage'), _rateL, _rateP, null),
  (429, _code('AccountOverdueError'), _rateL, _rateP, null),
  (500, _err('api_error', 'credit balance is too low'), _serverL(500),
      _serverP, null),
  // A region refusal: at any status, after billing, before the rest.
  (403, _code('unsupported_country_region_territory'), _regionL, _regionP,
      null),
  (400, _code('unsupported_country_region_territory'), _regionL, _regionP,
      null),
  (401, 'unsupported_country_region_territory', _regionL, _regionP, null),
  (404, _code('unsupported_country_region_territory'), _regionL, _regionP,
      null),
  (302, 'unsupported_country_region_territory', _regionL, _regionP, null),
  (500, _code('unsupported_country_region_territory'), _regionL, _regionP,
      null),
  (429, '{"code": "insufficient_quota unsupported_country_region_territory"}',
      _billingL, _billingP, null),
  // A 401/403 that is not a JSON object: a portal or proxy answering.
  (401, '<html>Sign in to Wi-Fi</html>', _nonJsonL(401), _portalP, null),
  (403, '<html>403 Forbidden</html>', _nonJsonL(403), _portalP, null),
  (401, '', _nonJsonL(401), _portalP, null),
  (401, '[]', _nonJsonL(401), _portalP, null),
  (403, '"Unauthorized"', _nonJsonL(403), _portalP, null),
  // The key rejected.
  (401, '{"error": "Unauthorized"}', _authL, _authP, null),
  (403, _code('forbidden'), _authL, _authP, null),
  (400, '{"error": "Incorrect API key provided: xa***zz."}', _authL, _authP,
      null),
  (400, 'Incorrect API key provided', _authL, _authP, null),
  (400, '{"error": "Incorrect API key", "code": "1211"}', _authL, _authP,
      null),
  // The model.
  (404, _code('model_not_found'), _modelL,
      _modelP('Provider request failed: HTTP 404'), _modelP(_hint)),
  (404, 'Incorrect API key', _modelL,
      _modelP('Provider request failed: HTTP 404'), _modelP(_hint)),
  (400, _code('1211'), _modelL,
      _modelP('Vendor model not found — check the model name in Settings.'),
      _modelP(_hint)),
  (429, _code('1211'), _rateL, _rateP, null),
  // Inside a 400: web search disabled (lookups only) before "1211".
  (400, '{"error": "Web search is not enabled", "code": "1211"}',
      (
        code: LookupFailureCode.searchDisabled,
        transient: false,
        message: 'Web search is disabled for this Vendor organization.',
      ),
      _modelP('Vendor model not found — check the model name in Settings.'),
      _modelP(_hint)),
  (400, _err('invalid_request_error', 'Web search is not enabled.'),
      (
        code: LookupFailureCode.searchDisabled,
        transient: false,
        message: 'Web search is disabled for this Vendor organization.',
      ),
      _failedP(400), null),
  // A redirect: a portal or proxy.
  for (final s in [300, 301, 302, 307, 399])
    (s, '', _redirectL(s), _portalP, null),
  // Rate limits and the provider's own trouble.
  (429, _err('rate_limit_error', 'slow down'), _rateL, _rateP, null),
  for (final s in [500, 502, 503, 529, 599])
    (s, 'upstream error', _serverL(s), _serverP, null),
  // Everything else is a bad request.
  (400, _err('invalid_request_error', 'max_tokens: must be positive'),
      _badRequestL(400), _failedP(400), null),
  for (final s in [201, 418, 422, 600])
    (s, '{}', _badRequestL(s), _failedP(s), null),
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

  // Every status/body rule either ladder reads, with each one's whole
  // answer: the lookup's code, transience and message, and the photo's
  // error, retryability, HTTP calls, key probe and key check.
  group('every rule of both ladders', () {
    final photo = Uint8List.fromList(List.filled(64, 7));
    Future<List<(String, AnalyzerService)>> analyzers(http.Client c) async {
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _Keys());
      OpenAiCompatAnalyzer vendor({String? hint}) => OpenAiCompatAnalyzer(s,
          endpoint: Uri.parse('https://api.vendor.example/v1/chat'),
          label: 'Vendor',
          keyOf: (_) => 'test-key',
          modelOf: (_) => 'vision-1',
          notFoundHint: hint,
          client: c,
          sleep: (_) async {},
          normalizer: (b) async => b);
      return [('no 404 hint', vendor()), ('a 404 hint', vendor(hint: _hint))];
    }

    for (final (status, body, lookup, plain, hinted) in _ladderRows) {
      test('$status ${body.length > 50 ? body.substring(0, 50) : body}',
          () async {
        final f = classifyHttpFailure(status, body, providerLabel: 'Vendor');
        expect((code: f.code, transient: f.transient, message: f.message),
            lookup,
            reason: 'classifyHttpFailure');
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response(body, status);
        });
        for (final (name, analyzer) in await analyzers(client)) {
          calls = 0;
          final out = await analyzer.analyzePhoto(photo);
          final photoCalls = calls;
          final probe = await analyzer.probeKey('test-key');
          final validate = await analyzer.validateKey('test-key');
          expect(
              (
                error: out.error,
                retryable: out.retryable,
                calls: photoCalls,
                probe: probe.result,
                probeMessage: probe.message,
                validate: validate,
              ),
              name == 'a 404 hint' ? hinted ?? plain : plain,
              reason: name);
        }
      });
    }
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
