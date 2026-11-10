// The owner's server as a lookup recipient (design R5a): Claude Plan's
// async jobs at /api/restaurant_lookup, the https gate for location-derived
// chains, consent bound to the server host, and every server answer mapped
// to one outcome kind. server_request.json and server_done.json are pinned
// to the real server by tests/test_restaurant_lookup_endpoint.py.
import 'dart:async';
import 'dart:convert';

import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:calorie_tracker/services/assist/clients/server_lookup_client.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Future<AppSettings> _settings({
  String url = 'https://bitewise.example.net',
  String? key = 'upload-key',
  String backend = 'claude',
}) async {
  SharedPreferences.setMockInitialValues({});
  final s = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(), keyStore: _Keys());
  await s.setProvider(AiProvider.server);
  await s.setServerBaseUrl(url);
  if (key != null) await s.setServerApiKey(key);
  await s.setServerBackend(backend);
  return s;
}

http.Response _json(int status, Object body) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _queued() =>
    _json(202, {'state': 'queued', 'job_id': 'job_abcdefgh01'});

/// The server's 202 to a new lookup.
http.Response _accepted(http.Request _) => _queued();

/// The Chipotle bowl the server fixtures answer for (its printed brand
/// names the chain).
final LookupRequest _bowl = LookupRequest.compose({
  'items': [
    {
      'name': 'Chicken burrito bowl (~500 g)',
      'qty': 1,
      'unit': 'bowl',
      'brand': 'Chipotle'
    }
  ],
  'chains': ['chipotle'],
});

/// A Big Mac with McDonald's printed on the box, eaten where the photo's
/// location also found a Chipotle: one brand chain, one location chain.
final LookupRequest _mixed = LookupRequest.compose({
  'items': [
    {'name': 'Big Mac', 'qty': 1, 'unit': 'sandwich', 'brand': "McDonald's"},
    {'name': 'burrito bowl'},
  ],
  'chains': ['chipotle'],
});

/// Nothing printed: the only chain came from the photo's location.
final LookupRequest _locationOnly = LookupRequest.compose({
  'items': [
    {'name': 'burrito bowl'}
  ],
  'chains': ['chipotle'],
});

String _tag(String host) =>
    sha256.convert(utf8.encode(host)).toString().substring(0, 8);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ServerLookupClient, ScriptedClient, String)> make(
    List<Reply> replies, {
    String url = 'https://bitewise.example.net',
    String? key = 'upload-key',
    String backend = 'claude',
    LookupBudget? budget,
    Duration deadline = kServerLookupHttpDeadline,
  }) async {
    final s = ScriptedClient(replies);
    final settings = await _settings(url: url, key: key, backend: backend);
    final c = ServerLookupClient(settings,
        client: s.client, budget: budget, perCallDeadline: deadline);
    return (c, s, c.lookupSupport().recipientStamp);
  }

  group('support', () {
    test('https: supported, location allowed, stamped with the host tag',
        () async {
      final (c, s, stamp) = await make([_accepted]);
      final support = c.lookupSupport();
      expect(support.supported, isTrue);
      expect(support.recipient, LookupRecipient.claudePlan);
      expect(support.locationAllowed, isTrue);
      expect(support.recipientHostTag, _tag('bitewise.example.net'));
      expect(stamp, 'claude_plan:${_tag('bitewise.example.net')}');
      expect(stamp.contains('example'), isFalse, reason: 'never the host');
      expect(s.requests, isEmpty);
    });

    test('http: supported, brand-only; the same host keeps its stamp',
        () async {
      final (c, _, stamp) = await make([_accepted],
          url: 'http://BiteWise.Example.net:5000');
      expect(c.lookupSupport().supported, isTrue);
      expect(c.lookupSupport().locationAllowed, isFalse);
      expect(stamp, 'claude_plan:${_tag('bitewise.example.net')}',
          reason: 'moving the same server to https is the same recipient');
    });

    test('another server is another recipient', () async {
      final (_, _, a) = await make([_accepted]);
      final (_, _, b) = await make([_accepted], url: 'https://other.example');
      expect(a, isNot(b));
    });

    test('glm / doubao backends and a missing address: unsupported, '
        'zero calls', () async {
      for (final (backend, url, reason) in [
        ('glm', 'https://h.example', LookupUnsupportedReason.serverBackendNotClaude),
        ('doubao', 'https://h.example', LookupUnsupportedReason.serverBackendNotClaude),
        ('claude', '', LookupUnsupportedReason.noServerAddress),
        ('claude', 'h.example', LookupUnsupportedReason.noServerAddress),
        ('claude', 'ftp://h.example', LookupUnsupportedReason.noServerAddress),
      ]) {
        final (c, s, _) = await make([_accepted], url: url, backend: backend);
        final support = c.lookupSupport();
        expect(support.supported, isFalse, reason: '$backend $url');
        expect(support.reason, reason);
        expect(support.recipient, LookupRecipient.none);
        final o = await c.submit(_bowl,
            expectedRecipient: support.recipient,
            expectedRecipientStamp: support.recipientStamp);
        expect(o.kind, LookupOutcomeKind.unsupported);
        expect((await c.poll('job_abcdefgh01')).kind,
            LookupOutcomeKind.unsupported);
        expect(s.requests, isEmpty);
      }
    });
  });

  group('submit', () {
    test('202: pending with the job id; the request as the server reads it',
        () async {
      final (c, s, stamp) = await make([_accepted]);
      final o = await c.submit(_bowl,
          chainDomains: const ['chipotle.com'],
          expectedRecipient: LookupRecipient.claudePlan,
          expectedRecipientStamp: stamp);
      expect(o.kind, LookupOutcomeKind.pending);
      expect(o.jobId, 'job_abcdefgh01');
      expect(o.needsResubmit, isFalse);
      expect(o.provider, LookupRecipient.claudePlan);
      expect(o.cost.httpCalls, 1);
      final req = s.requests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(),
          'https://bitewise.example.net/api/restaurant_lookup');
      expect(req.headers['X-API-Key'], 'upload-key');
      expect(req.headers['X-Client-Platform'], 'app');
      expect(req.headers['Content-Type'], startsWith('application/json'));
      // The composed request plus the backend: what the server's own test
      // proves it accepts (server_request.json). No prompt, no domains.
      expect(jsonDecode(req.body), fixture('server_request.json'));
    });

    test('200 from the cache: done, read like the server writes it',
        () async {
      final (c, s, stamp) =
          await make([(_) => fixture200('server_done.json')]);
      final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect(o.isDone, isTrue);
      expect(o.jobId, 'fixtureJob_0001');
      expect(o.result!.status, 'found');
      expect(o.result!.chainKey, 'chipotle');
      expect(o.result!.matches.single.matchType, 'components_sum');
      expect(o.result!.matches.single.allFigures, [180, 210, 130]);
      expect(o.citedUrls, ['https://www.chipotle.com/nutrition-calculator']);
      expect(o.evidence.single.url, o.citedUrls.single);
      expect(o.evidence.single.text, '180 calories');
      expect(o.evidence.single.verbatim, isFalse,
          reason: "the server's search summary is never page text");
      expect(o.searches, 1);
      expect(o.cost.searches, 1);
      expect(o.cost.usd, 0);
      final assist = o.toAssistLookup()!;
      expect(assist.provider, 'claude_plan');
      expect(assist.evidence.single.verbatim, isFalse);
      expect(s.requests, hasLength(1));
    });

    test('evidence is verbatim only for a literal true', () async {
      final body = fixture('server_done.json');
      body['evidence'] = [
        for (final v in [true, 'true', 1, null])
          {'url': 'https://www.chipotle.com/n', 'text': 't', 'verbatim': v},
      ];
      final (c, _, stamp) = await make([(_) => _json(200, body)]);
      final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
      expect([for (final e in o.evidence) e.verbatim],
          [true, false, false, false]);
    });

    test('the payer receipt: done without analyzed_by "claude" is refused',
        () async {
      for (final by in [null, 'glm', 'Claude', 42]) {
        final body = fixture('server_done.json');
        if (by == null) {
          body.remove('analyzed_by');
        } else {
          body['analyzed_by'] = by;
        }
        final (c, _, stamp) = await make([(_) => _json(200, body)]);
        final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
        expect(o.kind, LookupOutcomeKind.failed, reason: '$by');
        expect(o.failure!.code, LookupFailureCode.malformedReply);
        expect(o.failure!.transient, isFalse);
        expect(o.result, isNull);
      }
    });

    test('a done job whose answer is not a lookup result: failed', () async {
      final body = fixture('server_done.json')..['lookup'] = {'status': 'ok'};
      final (c, _, stamp) = await make([(_) => _json(200, body)]);
      final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
      expect(o.kind, LookupOutcomeKind.failed);
      expect(o.failure!.code, LookupFailureCode.malformedReply);
    });

    final statuses = <String, (http.Response, LookupOutcomeKind,
        LookupFailureCode, bool)>{
      '404 (no such route)': (
        http.Response('<!doctype html><title>404 Not Found</title>', 404,
            headers: {'content-type': 'text/html'}),
        LookupOutcomeKind.serverOutdated,
        LookupFailureCode.badRequest,
        false,
      ),
      '403 disabled': (
        _json(403, {'error': 'disabled', 'reason': 'disabled'}),
        LookupOutcomeKind.disabled,
        LookupFailureCode.searchDisabled,
        false,
      ),
      '429 queue_full': (
        _json(429, {'error': 'queue_full', 'reason': 'queue_full', 'retry': true}),
        LookupOutcomeKind.rateLimited,
        LookupFailureCode.rateLimited,
        true,
      ),
      '429 daily_cap': (
        _json(429, {'error': 'daily_cap', 'reason': 'daily_cap', 'retry': 'later'}),
        LookupOutcomeKind.rateLimited,
        LookupFailureCode.dailyCap,
        true,
      ),
      '503 claude unavailable': (
        _json(503, {'error': 'claude_unavailable', 'reason': 'not logged in'}),
        LookupOutcomeKind.busy,
        LookupFailureCode.server,
        true,
      ),
      '401 key rejected': (
        _json(401, {'error': 'Unauthorized'}),
        LookupOutcomeKind.failed,
        LookupFailureCode.auth,
        false,
      ),
      '400 bad request': (
        _json(400, {'error': 'bad_request', 'reason': 'bad_request', 'field': 'items[0].name'}),
        LookupOutcomeKind.failed,
        LookupFailureCode.badRequest,
        false,
      ),
      '500': (
        http.Response('oops', 500),
        LookupOutcomeKind.failed,
        LookupFailureCode.server,
        true,
      ),
      '302 portal': (
        http.Response('', 302, headers: {'location': 'http://portal/'}),
        LookupOutcomeKind.offline,
        LookupFailureCode.captivePortal,
        true,
      ),
      'HTML 200 portal': (
        http.Response('<html>Sign in</html>', 200,
            headers: {'content-type': 'text/html'}),
        LookupOutcomeKind.offline,
        LookupFailureCode.captivePortal,
        true,
      ),
      'HTML 403 filter': (
        http.Response('<html>Forbidden</html>', 403,
            headers: {'content-type': 'text/html'}),
        LookupOutcomeKind.offline,
        LookupFailureCode.captivePortal,
        true,
      ),
      'JSON array 200': (
        _json(200, [1, 2]),
        LookupOutcomeKind.failed,
        LookupFailureCode.malformedReply,
        false,
      ),
      '202 without a job id': (
        _json(202, {'state': 'queued'}),
        LookupOutcomeKind.failed,
        LookupFailureCode.malformedReply,
        false,
      ),
      'unknown to a submit (would loop)': (
        _json(200, {'state': 'unknown', 'job_id': 'job_abcdefgh01'}),
        LookupOutcomeKind.failed,
        LookupFailureCode.malformedReply,
        false,
      ),
    };
    for (final e in statuses.entries) {
      test('${e.key} → ${e.value.$2.name}', () async {
        final (reply, kind, code, transient) = e.value;
        final (c, s, stamp) = await make([(_) => reply]);
        final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
        expect(o.kind, kind, reason: '${o.failure}');
        expect(o.failure!.code, code);
        expect(o.failure!.transient, transient);
        expect(o.result, isNull);
        expect(s.requests, hasLength(1), reason: 'never retried in place');
        expect(o.failure!.message.contains('bitewise.example.net'), isFalse);
      });
    }

    test('a 400 names the server code and field, never a value', () async {
      final (c, _, stamp) = await make([
        (_) => _json(400, {
              'error': 'bad_request',
              'field': 'items[0].name',
            })
      ]);
      final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
      expect(o.failure!.message, contains('bad_request'));
      expect(o.failure!.message, contains('items[0].name'));
    });

    test('no network and the 30 s deadline: offline, transient', () async {
      final (c1, _, stamp1) = await make(
          [(_) => throw const SocketLikeException('refused 10.1.2.3')]);
      final o1 = await c1.submit(_bowl, expectedRecipientStamp: stamp1);
      expect(o1.kind, LookupOutcomeKind.offline);
      expect(o1.failure!.code, LookupFailureCode.network);
      expect(o1.failure!.message.contains('10.1.2.3'), isFalse,
          reason: 'a transport error text can carry the address');

      final (c2, _, stamp2) = await make(
          [(_) => Completer<http.Response>().future],
          deadline: const Duration(milliseconds: 50));
      final o2 = await c2.submit(_bowl, expectedRecipientStamp: stamp2);
      expect(o2.kind, LookupOutcomeKind.offline);
      expect(o2.failure!.code, LookupFailureCode.timeout);
      expect(o2.failure!.transient, isTrue);
      expect(kServerLookupHttpDeadline, const Duration(seconds: 30));
    });

    test('no upload key: failed, zero calls', () async {
      final (c, s, stamp) = await make([_accepted], key: null);
      final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
      expect(o.kind, LookupOutcomeKind.failed);
      expect(o.failure!.code, LookupFailureCode.noKey);
      expect(o.failure!.transient, isTrue);
      expect(s.requests, isEmpty);
    });

    test('the daily cap: zero calls once the day is used up', () async {
      final budget = DailyLookupBudget(maxLookupsPerDay: 1);
      final (c, s, stamp) = await make([_accepted], budget: budget);
      expect((await c.submit(_bowl, expectedRecipientStamp: stamp)).kind,
          LookupOutcomeKind.pending);
      final o = await c.submit(_bowl, expectedRecipientStamp: stamp);
      expect(o.kind, LookupOutcomeKind.rateLimited);
      expect(o.failure!.code, LookupFailureCode.dailyCap);
      expect(s.requests, hasLength(1));
      expect(budget.usdToday, 0, reason: 'plan usage, not dollars');
    });

    test('cancelled before the send: zero calls; during it: discarded',
        () async {
      final (c, s, stamp) = await make([_accepted]);
      final before = LookupCancelToken()..cancel();
      final o1 = await c.submit(_bowl,
          cancel: before, expectedRecipientStamp: stamp);
      expect(o1.failure!.code, LookupFailureCode.cancelled);
      expect(s.requests, isEmpty);

      final gate = Completer<http.Response>();
      final (c2, s2, stamp2) = await make([(_) => gate.future]);
      final during = LookupCancelToken();
      final f = c2.submit(_bowl, cancel: during, expectedRecipientStamp: stamp2);
      await pumpEventQueue();
      during.cancel();
      final o2 = await f;
      expect(o2.kind, LookupOutcomeKind.failed);
      expect(o2.failure!.code, LookupFailureCode.cancelled);
      expect(o2.jobId, isNull);
      expect(s2.requests, hasLength(1));
      gate.complete(_queued());
    });
  });

  group('the https gate', () {
    test('https: chains from the location are sent', () async {
      final (c, s, stamp) = await make([_accepted]);
      await c.submit(_mixed, expectedRecipientStamp: stamp);
      final body = jsonDecode(s.requests.single.body) as Map;
      expect([for (final ch in body['chains'] as List) ch['key']],
          ['mcdonalds', 'chipotle']);
    });

    test('http: only the chains printed text names; nothing else changes',
        () async {
      final (c, s, stamp) = await make([_accepted],
          url: 'http://10.0.0.5:5000');
      await c.submit(_mixed, expectedRecipientStamp: stamp);
      final body = jsonDecode(s.requests.single.body) as Map<String, dynamic>;
      expect([for (final ch in body['chains'] as List) ch['key']],
          ['mcdonalds']);
      expect(body['items'], _mixed.body['items']);
      expect(body['order_merchant'], _mixed.body['order_merchant']);
      expect(body['country'], 'US');
      expect(s.requests.single.url.toString(),
          'http://10.0.0.5:5000/api/restaurant_lookup');
    });

    test('http with only a location chain: zero calls', () async {
      final (c, s, stamp) = await make([_accepted],
          url: 'http://10.0.0.5:5000');
      final o = await c.submit(_locationOnly, expectedRecipientStamp: stamp);
      expect(o.kind, LookupOutcomeKind.failed);
      expect(o.failure!.code, LookupFailureCode.badRequest);
      expect(o.failure!.message, contains('https'));
      expect(s.requests, isEmpty);
    });

    test('nothing worth sending is never sent', () async {
      final (c, s, stamp) = await make([_accepted]);
      for (final r in [
        LookupRequest.compose({'items': [], 'chains': ['chipotle']}),
        LookupRequest.compose({
          'items': [
            {'name': ''}
          ],
          'chains': ['chipotle'],
        }),
        itemRequest('burrito bowl'), // no chain at all
      ]) {
        final o = await c.submit(r, expectedRecipientStamp: stamp);
        expect(o.failure!.code, LookupFailureCode.badRequest);
      }
      expect(s.requests, isEmpty);
    });
  });

  group('consent is bound to the server host', () {
    test('no stamp, another recipient, or a stale stamp: zero calls',
        () async {
      final settings = await _settings();
      final s = ScriptedClient([_accepted]);
      final c = ServerLookupClient(settings, client: s.client);
      final consented = c.lookupSupport().recipientStamp;

      final none = await c.submit(_bowl);
      expect(none.kind, LookupOutcomeKind.unsupported);
      expect(none.failure!.code, LookupFailureCode.consentChanged);

      final other = await c.submit(_bowl,
          expectedRecipient: LookupRecipient.anthropic,
          expectedRecipientStamp: consented);
      expect(other.failure!.code, LookupFailureCode.consentChanged);

      // The address changes between the consent check and the send.
      await settings.setServerBaseUrl('https://someone-else.example');
      final stale = await c.submit(_bowl, expectedRecipientStamp: consented);
      expect(stale.failure!.code, LookupFailureCode.consentChanged);
      expect(stale.failure!.transient, isFalse);
      expect(stale.failure!.message.contains('someone-else'), isFalse);
      expect(s.requests, isEmpty);

      // Re-consented for the new server, the same call goes through.
      final again = await c.submit(_bowl,
          expectedRecipient: LookupRecipient.claudePlan,
          expectedRecipientStamp: c.lookupSupport().recipientStamp);
      expect(again.kind, LookupOutcomeKind.pending);
      expect(s.requests.single.url.host, 'someone-else.example');
    });
  });

  group('poll', () {
    Future<LookupOutcome> poll(Reply reply,
        {String id = 'job_abcdefgh01'}) async {
      final (c, s, _) = await make([reply]);
      final o = await c.poll(id);
      expect(s.requests, hasLength(1));
      final req = s.requests.single;
      expect(req.url.path, '/api/restaurant_lookup/status');
      expect(jsonDecode(req.body), {'job_id': id},
          reason: 'a poll sends the job id and nothing else');
      expect(req.headers['X-API-Key'], 'upload-key');
      return o;
    }

    test('queued and running: pending with the same job id', () async {
      for (final state in ['queued', 'running']) {
        final o = await poll(
            (_) => _json(200, {'state': state, 'job_id': 'job_abcdefgh01'}));
        expect(o.kind, LookupOutcomeKind.pending);
        expect(o.jobId, 'job_abcdefgh01');
        expect(o.needsResubmit, isFalse);
      }
    });

    test('done', () async {
      final o = await poll((_) => fixture200('server_done.json'),
          id: 'fixtureJob_0001');
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect(o.result!.chainKey, 'chipotle');
      expect(o.toAssistLookup()!.citedUrls,
          ['https://www.chipotle.com/nutrition-calculator']);
    });

    test('unknown: pending without a job id — resubmit', () async {
      final o = await poll(
          (_) => _json(200, {'state': 'unknown', 'job_id': 'job_abcdefgh01'}));
      expect(o.kind, LookupOutcomeKind.pending);
      expect(o.jobId, isNull);
      expect(o.needsResubmit, isTrue);
    });

    test('a job id the server never issues: resubmit, zero calls', () async {
      final (c, s, _) = await make([_accepted]);
      for (final id in ['', 'short', 'has space in it', 'x' * 65, '../../x']) {
        final o = await c.poll(id);
        expect(o.needsResubmit, isTrue, reason: id);
      }
      expect(s.requests, isEmpty);
    });

    final failed = <String, (LookupOutcomeKind, LookupFailureCode, bool)>{
      'daily_cap': (
        LookupOutcomeKind.rateLimited,
        LookupFailureCode.dailyCap,
        true
      ),
      'plan_refused': (
        LookupOutcomeKind.rateLimited,
        LookupFailureCode.rateLimited,
        true
      ),
      'preempted': (LookupOutcomeKind.busy, LookupFailureCode.server, true),
      'timeout': (LookupOutcomeKind.failed, LookupFailureCode.timeout, true),
      'cli_error': (LookupOutcomeKind.failed, LookupFailureCode.server, true),
      'worker_error': (
        LookupOutcomeKind.failed,
        LookupFailureCode.server,
        true
      ),
      'bad_output': (
        LookupOutcomeKind.failed,
        LookupFailureCode.malformedReply,
        false
      ),
      'guard_fail': (
        LookupOutcomeKind.failed,
        LookupFailureCode.refused,
        false
      ),
      'Some Prose <b>': (
        LookupOutcomeKind.failed,
        LookupFailureCode.server,
        true
      ),
    };
    for (final e in failed.entries) {
      test('failed (${e.key}) → ${e.value.$1.name}', () async {
        final o = await poll((_) => _json(200, {
              'state': 'failed',
              'job_id': 'job_abcdefgh01',
              'reason': e.key,
            }));
        expect(o.kind, e.value.$1);
        expect(o.failure!.code, e.value.$2);
        expect(o.failure!.transient, e.value.$3);
        expect(o.jobId, 'job_abcdefgh01');
        expect(o.failure!.message.contains('<b>'), isFalse);
      });
    }

    test('403 disabled and 404 on a poll', () async {
      expect(
          (await poll((_) => _json(403, {'reason': 'disabled'}))).kind,
          LookupOutcomeKind.disabled);
      expect((await poll((_) => http.Response('nope', 404))).kind,
          LookupOutcomeKind.serverOutdated);
    });
  });
}

/// A transport failure whose text carries an address.
class SocketLikeException implements Exception {
  const SocketLikeException(this.message);
  final String message;
  @override
  String toString() => 'SocketLikeException: $message';
}
