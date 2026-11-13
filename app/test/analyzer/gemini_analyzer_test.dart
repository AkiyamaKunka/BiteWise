import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/analyzer/gemini_analyzer.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/fakes.dart' show FakeDao;

class MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Gemini 200 body whose candidate text is [text].
String geminiOk(String text) => jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': text}
            ]
          }
        }
      ]
    });

const String dailyQuotaBody =
    '{"error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "message": '
    '"Quota exceeded for quota metric generate_content_free_tier_requests '
    'limit GenerateRequestsPerDayPerProjectPerModel-FreeTier"}}';

const String foodJson = '{"is_food": true, "food_items": '
    '[{"name": "Toast", "estimated_calories": 120}], "total_calories": 120, '
    '"meal_description": "Toast"}';

Future<AppSettings> freshSettings({String? apiKey = 'test-key'}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final s = await AppSettings.load(prefs: prefs, keyStore: MemoryKeyStore());
  if (apiKey != null) await s.setGeminiApiKey(apiKey);
  return s;
}

/// Test harness: records every request and every sleep; identity normalizer
/// by default (normalization itself is covered in normalize_test.dart).
class Harness {
  Harness(this.settings, List<http.Response> responses,
      {Future<Uint8List?> Function(Uint8List)? normalizer}) {
    analyzer = GeminiAnalyzer(
      settings,
      client: MockClient((req) async {
        requests.add(req);
        if (responses.isEmpty) fail('unexpected extra HTTP request');
        return responses.removeAt(0);
      }),
      sleep: (d) async => sleeps.add(d),
      normalizer: normalizer ?? (b) async => b,
    );
  }

  Harness.throwing(this.settings, Object error) {
    analyzer = GeminiAnalyzer(
      settings,
      client: MockClient((req) async {
        requests.add(req);
        throw error; // transport failure: no HTTP response at all
      }),
      sleep: (d) async => sleeps.add(d),
      normalizer: (b) async => b,
    );
  }

  final AppSettings settings;
  final List<http.Request> requests = [];
  final List<Duration> sleeps = [];
  late final GeminiAnalyzer analyzer;
}

http.Response ok(String text) => http.Response(geminiOk(text), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final photo = Uint8List.fromList(List.generate(32, (i) => i));

  group('request shape (spec §3.2)', () {
    test('photo call: endpoint, key, parts, and JSON response mode', () async {
      final s = await freshSettings();
      final h = Harness(s, [ok(foodJson)]);
      final out = await h.analyzer.analyzePhoto(photo);

      expect(out.error, isNull);
      expect(out.isFood, isTrue);
      expect(out.analysis!['total_calories'], 120);

      final req = h.requests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(),
          startsWith('https://generativelanguage.googleapis.com/v1beta/models/'
              '${AppSettings.defaultModel}:generateContent'));
      expect(req.url.queryParameters['key'], 'test-key');

      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['generationConfig'],
          {'response_mime_type': 'application/json'});
      final parts = body['contents'][0]['parts'] as List;
      expect(parts, hasLength(2));
      expect(parts[0]['text'], contains('Analyze this photo'));
      expect(parts[1]['inline_data']['mime_type'], 'image/jpeg');
      expect(parts[1]['inline_data']['data'], base64Encode(photo));
    });

    test('dietary profile appends to the photo prompt only (spec §1.3)',
        () async {
      final s = await freshSettings();
      await s.setDietaryProfile('halal');
      final h = Harness(s, [ok(foodJson)]);
      await h.analyzer.analyzePhoto(photo);
      final prompt =
          jsonDecode(h.requests.single.body)['contents'][0]['parts'][0]['text']
              as String;
      expect(prompt, contains("User's Dietary Profile"));
      expect(prompt, contains('halal'));
    });

    test('no API key configured fails without any HTTP call', () async {
      final s = await freshSettings(apiKey: null);
      final h = Harness(s, []);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.error, contains('key'));
      expect(h.requests, isEmpty);
    });
  });

  group('is_food coercion gate (core/coerce parity)', () {
    test('boolish string is coerced, analysis otherwise untouched', () async {
      final s = await freshSettings();
      final h = Harness(s, [
        ok('{"is_food": "yes", "total_calories": "lots", '
            '"food_items": "junk"}')
      ]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.isFood, isTrue);
      expect(out.analysis!['is_food'], true);
      // No mutation beyond is_food: hostile fields stay raw for consumers.
      expect(out.analysis!['total_calories'], 'lots');
      expect(out.analysis!['food_items'], 'junk');
    });

    test('is_food false is a successful not-food outcome', () async {
      final s = await freshSettings();
      final h = Harness(s, [ok('{"is_food": false}')]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.error, isNull);
      expect(out.isFood, isFalse);
      expect(out.analysis, isNotNull);
    });

    test('uncoercible or missing is_food rejects the analysis', () async {
      for (final text in [
        '{"is_food": "maybe"}',
        '{"total_calories": 500}',
        '[1, 2, 3]',
        '"just a string"',
      ]) {
        final s = await freshSettings();
        final h = Harness(s, [ok(text)]);
        final out = await h.analyzer.analyzePhoto(photo);
        expect(out.analysis, isNull, reason: text);
        expect(out.error, isNotNull, reason: text);
      }
    });

    test('markdown-fenced JSON is parsed (spec §3.4)', () async {
      final s = await freshSettings();
      final h = Harness(s, [ok('```json\n$foodJson\n```')]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.isFood, isTrue);
    });
  });

  group('retry / backoff (spec §3.3)', () {
    test('parse errors are never retried', () async {
      final s = await freshSettings();
      final h = Harness(s, [ok('utter nonsense, no json here')]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.error, contains("Couldn't understand"));
      expect(h.requests, hasLength(1));
    });

    test('503 retries then succeeds; default 5s backoff', () async {
      final s = await freshSettings();
      final h = Harness(s, [
        http.Response('{"error":{"code":503,"status":"UNAVAILABLE"}}', 503),
        http.Response('{"error":{"code":503,"status":"UNAVAILABLE"}}', 503),
        ok(foodJson),
      ]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.isFood, isTrue);
      expect(h.requests, hasLength(3));
      expect(h.sleeps, [const Duration(seconds: 5), const Duration(seconds: 5)]);
    });

    test('persistent 503 stops after 3 attempts', () async {
      final s = await freshSettings();
      final h = Harness(s, List.generate(3,
          (_) => http.Response('{"error":{"status":"UNAVAILABLE"}}', 503)));
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.error, isNotNull);
      expect(h.requests, hasLength(3));
    });

    test('429 honors the server retryDelay hint', () async {
      final s = await freshSettings();
      final h = Harness(s, [
        http.Response(
            '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED",'
            '"details":[{"retryDelay":"12s"}]}}',
            429),
        ok(foodJson),
      ]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.isFood, isTrue);
      expect(h.sleeps, [const Duration(seconds: 12)]);
    });

    test('auth errors are not retried', () async {
      final s = await freshSettings();
      final h = Harness(s, [
        http.Response('{"error":{"code":403,"status":"PERMISSION_DENIED"}}',
            403)
      ]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.error, contains('key'));
      expect(h.requests, hasLength(1));
    });

    test('an HTML 403/401 from a front end or web filter is network, not '
        'a rejected key: one call, photo kept, probe not "rejected"',
        () async {
      // Review 2026-10-12 probe D: bare 401/403 digits anywhere used to
      // read as auth, and a rejected key now parks the automatic scan for
      // a day. Only Google's JSON statuses (or a JSON-bodied 401/403) are
      // a verdict on the key.
      const gfe = "<html><body>Your client does not have permission to get "
          "URL. That's an error.</body></html>";
      expect(classifyGeminiError('HTTP 403: $gfe'),
          GeminiErrorClass.networkService);
      expect(classifyGeminiError('HTTP 401: Login required'),
          GeminiErrorClass.networkService);
      expect(
          classifyGeminiError('HTTP 400: {"error":{"message":"Request payload '
              '4031 bytes invalid","status":"INVALID_ARGUMENT"}}'),
          GeminiErrorClass.modelError);
      expect(classifyGeminiError('HTTP 403: {"error":{"code":403}}'),
          GeminiErrorClass.auth);
      expect(
          classifyGeminiError('HTTP 400: {"error":{"status":"INVALID_ARGUMENT",'
              '"details":[{"reason":"API_KEY_INVALID"}]}}'),
          GeminiErrorClass.auth);
      for (final status in [403, 401]) {
        final s = await freshSettings();
        final h = Harness(s, [
          http.Response(gfe, status, headers: {'content-type': 'text/html'})
        ]);
        final out = await h.analyzer.analyzePhoto(photo);
        expect(out.retryable, isTrue, reason: '$status: ${out.error}');
        expect(classifyAnalysisError(out.error), AnalysisErrorKind.network,
            reason: '$status: ${out.error}');
        expect(h.requests, hasLength(1), reason: '$status');
        expect(h.sleeps, isEmpty, reason: '$status');
        final probe = await GeminiAnalyzer(s,
                client: MockClient((_) async => http.Response(gfe, status)))
            .probeKey('k');
        expect(probe.result, isNot(KeyProbeResult.rejected),
            reason: '$status: ${probe.message}');
        expect(probe.result, isNot(KeyProbeResult.ok), reason: '$status');
      }
    });

    test('classification table matches the spec', () {
      expect(classifyGeminiError('HTTP 429: $dailyQuotaBody'),
          GeminiErrorClass.dailyQuotaExhausted);
      expect(classifyGeminiError('HTTP 429: RATE_LIMIT'),
          GeminiErrorClass.quotaRateLimit);
      expect(classifyGeminiError('HTTP 401: UNAUTHENTICATED'),
          GeminiErrorClass.auth);
      expect(classifyGeminiError('CONNECTION error: socket closed'),
          GeminiErrorClass.networkService);
      expect(classifyGeminiError('DEADLINE: client-side 90s deadline hit'),
          GeminiErrorClass.networkService);
      expect(classifyGeminiError('HTTP 404: MODEL_NOT_FOUND'),
          GeminiErrorClass.modelError);
      expect(classifyGeminiError('weird'), GeminiErrorClass.unknown);
    });

    test('retryable classes per spec: 5xx/network/timeout yes, daily-quota no',
        () {
      expect(isRetryableGeminiError('HTTP 503: UNAVAILABLE'), isTrue);
      expect(isRetryableGeminiError('HTTP 500: internal'), isTrue);
      expect(isRetryableGeminiError('HTTP 429: RESOURCE_EXHAUSTED'), isTrue);
      expect(isRetryableGeminiError('DEADLINE hit'), isTrue);
      expect(isRetryableGeminiError('CONNECTION error: refused'), isTrue);
      expect(isRetryableGeminiError('HTTP 429: $dailyQuotaBody'), isFalse);
      expect(isRetryableGeminiError('HTTP 403: PERMISSION_DENIED'), isFalse);
      expect(isRetryableGeminiError('HTTP 400: INVALID_ARGUMENT'), isFalse);
    });

    test('retryDelay parsing: forms, ceil, clamp [1,60], default 5', () {
      expect(parseRetryDelaySeconds('retryDelay: "7s"'), 7);
      expect(parseRetryDelaySeconds("retryDelay: '2.2s'"), 3); // ceil
      expect(parseRetryDelaySeconds('please retry in 9s'), 9);
      expect(parseRetryDelaySeconds('retry in 1500 ms'), 2);
      expect(parseRetryDelaySeconds('retry in 1 ms'), 1); // clamp low
      expect(parseRetryDelaySeconds('retryDelay: "600s"'), 60); // clamp high
      expect(parseRetryDelaySeconds('no hint at all'), 5);
    });
  });

  group('daily-quota pause latch (spec §3.3)', () {
    test('daily quota error latches ~12h pause, no retry', () async {
      final s = await freshSettings();
      final h = Harness(s, [http.Response(dailyQuotaBody, 429)]);
      final before = DateTime.now();
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.error, contains('paused'));
      expect(h.requests, hasLength(1)); // never retried
      final until = s.quotaPauseUntil!;
      expect(until.difference(before),
          allOf(greaterThan(const Duration(hours: 11, minutes: 59)),
              lessThan(const Duration(hours: 12, minutes: 1))));
    });

    test('while paused, analyzePhoto returns immediately with no HTTP call',
        () async {
      final s = await freshSettings();
      await s.setQuotaPauseUntil(DateTime.now().add(const Duration(hours: 2)));
      final h = Harness(s, []);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.error, contains('paused'));
      expect(h.requests, isEmpty);
    });

    test('an expired pause does not block, and any success clears the latch',
        () async {
      final s = await freshSettings();
      await s.setQuotaPauseUntil(
          DateTime.now().subtract(const Duration(minutes: 1)));
      final h = Harness(s, [ok(foodJson)]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.isFood, isTrue);
      expect(s.quotaPauseUntil, isNull); // spec: later success clears pause
    });

    test('textIntent daily-quota failure latches the pause too', () async {
      final s = await freshSettings();
      final h = Harness(s, [http.Response(dailyQuotaBody, 429)]);
      expect(await h.analyzer.textIntent('hello'), isNull);
      expect(s.isQuotaPaused, isTrue);
    });
  });

  group('normalization fallback (spec §3.1 step 6)', () {
    test('normalize failure with a small JPEG original sends it as-is',
        () async {
      final s = await freshSettings();
      final h = Harness(s, [ok(foodJson)], normalizer: (_) async => null);
      final jpegOriginal = Uint8List.fromList(
          [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, ...photo, 0xFF, 0xD9]);
      final out = await h.analyzer.analyzePhoto(jpegOriginal);
      expect(out.isFood, isTrue);
      final data = jsonDecode(h.requests.single.body)['contents'][0]['parts']
          [1]['inline_data']['data'] as String;
      expect(data, base64Encode(jpegOriginal));
    });

    test('normalize failure with a NON-JPEG original sends nothing', () async {
      // Raw HEIC labelled image/jpeg is unreadable to the model, which then
      // answers "not food" — the owner's iPhone lost every meal that way
      // (2026-09-30). An undecodable non-JPEG fails visibly instead.
      final s = await freshSettings();
      final h = Harness(s, [], normalizer: (_) async => null);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(h.requests, isEmpty);
      expect(out.error, contains('not a JPEG'));
      expect(out.retryable, isFalse);
    });

    test('normalize failure with >=5MB original fails with no HTTP call',
        () async {
      final s = await freshSettings();
      final h = Harness(s, [], normalizer: (_) async => null);
      final big = Uint8List(5 * 1024 * 1024);
      final out = await h.analyzer.analyzePhoto(big);
      expect(out.error, isNotNull);
      expect(out.analysis, isNull);
      expect(h.requests, isEmpty);
    });
  });

  group('textIntent (spec §3.2 text call / §4.1 shape carriage)', () {
    test('sends a single text part and returns the parsed map', () async {
      final s = await freshSettings();
      final h = Harness(
          s, [ok('{"intent": "chat", "reply": "hi"}')]);
      final out = await h.analyzer.textIntent('the prompt');
      expect(out, {'intent': 'chat', 'reply': 'hi'});
      final parts =
          jsonDecode(h.requests.single.body)['contents'][0]['parts'] as List;
      expect(parts, hasLength(1));
      expect(parts[0]['text'], 'the prompt');
    });

    test('bare array survives the Map seam as {actions: [...]}', () async {
      final s = await freshSettings();
      final h = Harness(s, [
        ok('[{"intent": "correction", "meal_index": 0},'
            ' {"intent": "delete", "meal_indices": [1]}]')
      ]);
      final out = await h.analyzer.textIntent('p');
      expect(out!.keys, ['actions']);
      expect((out['actions'] as List), hasLength(2));
    });

    test('transport errors, parse errors, and scalar JSON return null',
        () async {
      final s = await freshSettings();
      for (final resp in [
        http.Response('{"error":{"status":"UNAVAILABLE"}}', 503),
        ok('not json at all'),
        ok('42'),
      ]) {
        final h = Harness(s, [resp]);
        expect(await h.analyzer.textIntent('p'), isNull);
        expect(h.requests, hasLength(1)); // text path: single attempt
      }
    });
  });

  group('validateKey (spec §3: 1-token real generation)', () {
    test('200 → null, uses the candidate key and maxOutputTokens 1', () async {
      final s = await freshSettings(apiKey: null); // no stored key needed
      final h = Harness(s, [ok('')]);
      expect(await h.analyzer.validateKey('candidate-key'), isNull);
      final req = h.requests.single;
      expect(req.url.queryParameters['key'], 'candidate-key');
      expect(jsonDecode(req.body)['generationConfig'], {'maxOutputTokens': 1});
    });

    test('MAX_TOKENS body with no text part still validates', () async {
      final s = await freshSettings(apiKey: null);
      final h = Harness(s, [
        http.Response(
            '{"candidates":[{"finishReason":"MAX_TOKENS","content":{}}]}', 200)
      ]);
      expect(await h.analyzer.validateKey('k'), isNull);
    });

    test('rejected key returns a user-facing error', () async {
      final s = await freshSettings(apiKey: null);
      final h = Harness(s, [
        http.Response(
            '{"error":{"code":400,"status":"INVALID_ARGUMENT",'
            '"message":"API_KEY_INVALID"}}',
            400)
      ]);
      final msg = await h.analyzer.validateKey('bad');
      expect(msg, isNotNull);
      expect(msg, contains('key'));
    });

    test('429 rate limit counts as ACCEPTED — a 429 proves the key authed',
        () async {
      final s = await freshSettings(apiKey: null);
      final h = Harness(s, [
        http.Response(
            '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED",'
            '"message":"You exceeded your current quota"}}',
            429)
      ]);
      // Refusing to persist a valid-but-throttled key locks users out of
      // onboarding until quota reset (live iPhone regression, 2026-07-24).
      expect(await h.analyzer.validateKey('k'), isNull);
    });

    test('quota-looking TRANSPORT errors are NOT accepted (key in URL trap)',
        () async {
      final s = await freshSettings(apiKey: null);
      // Offline: http.Client throws; the exception text embeds the request
      // URL — which contains the typed key. A key containing '429' must not
      // classify as quota and sneak into secure storage.
      final h = Harness.throwing(
          s, Exception('Connection failed: uri=...key=abc429quota...'));
      expect(await h.analyzer.validateKey('abc429quota'), isNotNull);
    });

    test('daily free-tier exhaustion also counts as ACCEPTED', () async {
      final s = await freshSettings(apiKey: null);
      final h = Harness(s, [
        http.Response(
            '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":'
            '"Quota exceeded for quota metric GenerateRequestsPerDayPerProject'
            'PerModel-FreeTier"}}',
            429)
      ]);
      expect(await h.analyzer.validateKey('k'), isNull);
    });
  });

  group('region blocks, 5xx pages and withheld answers (2026-10-12)', () {
    // Gemini does not serve Hong Kong — the usual exit of a mainland VPN.
    const regionBody = '{"error": {"code": 400, "message": "User location '
        'is not supported for the API use.", "status": "FAILED_PRECONDITION"}}';

    test('a region 400 keeps the photo, is not retried in place, and says '
        'VPN', () async {
      final s = await freshSettings();
      final h = Harness(s, [http.Response(regionBody, 400)]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.retryable, isTrue,
          reason: 'a different VPN node fixes it; the photo must survive');
      expect(h.requests, hasLength(1));
      expect(h.sleeps, isEmpty, reason: 'seconds do not move a VPN node');
      expect(classifyAnalysisError(out.error), AnalysisErrorKind.regionBlocked);
      expect(out.error, contains('VPN'));
      expect(s.isQuotaPaused, isFalse);
    });

    test('a key complaint that also says FAILED_PRECONDITION is still auth',
        () {
      expect(
          classifyGeminiError('HTTP 400: {"status": "FAILED_PRECONDITION", '
              '"message": "API_KEY_INVALID"}'),
          GeminiErrorClass.auth);
      expect(classifyGeminiError('HTTP 400: $regionBody'),
          GeminiErrorClass.regionBlocked);
    });

    test('only the region sentences are regionBlocked — any other '
        'FAILED_PRECONDITION stays permanent', () async {
      expect(
          classifyGeminiError('HTTP 400: {"error": {"code": 400, "message": '
              '"Gemini API free tier is not available in your country. '
              'Please enable billing on your project in Google AI Studio.", '
              '"status": "FAILED_PRECONDITION"}}'),
          GeminiErrorClass.regionBlocked);
      const other = '{"error": {"code": 400, "message": "Precondition check '
          'failed.", "status": "FAILED_PRECONDITION"}}';
      expect(classifyGeminiError('HTTP 400: $other'), GeminiErrorClass.unknown);
      final s = await freshSettings();
      final out = await Harness(s, [http.Response(other, 400)])
          .analyzer
          .analyzePhoto(photo);
      expect(out.retryable, isFalse,
          reason: 'no VPN node fixes it: re-uploading every scan is waste');
      expect(classifyAnalysisError(out.error),
          isNot(AnalysisErrorKind.regionBlocked));
    });

    test('probeKey / validateKey never call a region 400 a rejected key',
        () async {
      final s = await freshSettings(apiKey: null);
      final probe = await Harness(s, [http.Response(regionBody, 400)])
          .analyzer
          .probeKey('k');
      expect(probe.result, KeyProbeResult.regionBlocked);
      expect(probe.message, contains('region'));
      final msg = await Harness(s, [http.Response(regionBody, 400)])
          .analyzer
          .validateKey('k');
      expect(msg, isNotNull);
      expect(classifyAnalysisError(msg), AnalysisErrorKind.regionBlocked);
      expect(classifyAnalysisError(msg), isNot(AnalysisErrorKind.rejectedKey));
    });

    test('500 INTERNAL and a 502 HTML page read as network/service trouble',
        () async {
      for (final r in [
        () => http.Response(
            '{"error": {"code": 500, "message": "An internal error has '
            'occurred. Please retry or report in '
            'https://developers.generativeai.google/guide/troubleshooting", '
            '"status": "INTERNAL"}}',
            500),
        () => http.Response(
            '<!DOCTYPE html><html lang=en><title>Error 502 (Server Error)!!1'
            '</title><p><b>502.</b> <ins>That’s an error.</ins><p>The server '
            'encountered a temporary error (ref 4031). Please try again in '
            '30 seconds.</html>',
            502,
            headers: {'content-type': 'text/html; charset=utf-8'}),
      ]) {
        final s = await freshSettings();
        final h = Harness(s, List.generate(3, (_) => r()));
        final out = await h.analyzer.analyzePhoto(photo);
        expect(out.retryable, isTrue);
        expect(classifyAnalysisError(out.error), AnalysisErrorKind.network,
            reason: '${out.error}');
        expect(h.requests, hasLength(3));
        final probe =
            await Harness(s, [r()]).analyzer.probeKey('k');
        expect(probe.result, isNot(KeyProbeResult.rejected),
            reason: 'a 5xx says nothing about the key');
      }
    });

    test('a SAFETY-blocked 200 is permanent and says Gemini declined',
        () async {
      for (final body in [
        '{"candidates": [{"finishReason": "SAFETY", "index": 0, '
            '"safetyRatings": [{"category": "HARM_CATEGORY_DANGEROUS_CONTENT", '
            '"probability": "HIGH"}]}]}',
        '{"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}}',
      ]) {
        final s = await freshSettings();
        final h = Harness(s, [http.Response(body, 200)]);
        final out = await h.analyzer.analyzePhoto(photo);
        expect(out.retryable, isFalse, reason: 'the same photo is refused '
            'again; a retry loops forever');
        expect(h.requests, hasLength(1));
        expect(out.error, 'Gemini declined to analyze this photo.');
        expect(classifyAnalysisError(out.error),
            AnalysisErrorKind.contentBlocked);
      }
    });

    test('a 200 with no text and no block reason is still a shape error',
        () async {
      final s = await freshSettings();
      final h = Harness(s, [http.Response('{"candidates": []}', 200)]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.retryable, isFalse);
      expect(classifyAnalysisError(out.error), AnalysisErrorKind.unknown);
    });
  });

  group('an image Gemini could not read is about the photo, not the model '
      'name (review 171, C28)', () {
    // Gemini answers 400 INVALID_ARGUMENT for an image it could not read.
    // Read as any other INVALID_ARGUMENT, that was "check the model name in
    // Settings" (a setting that was fine), and the photo failed at once
    // although Google's own text asks for a retry.
    const unableBody = '{"error": {"code": 400, "message": "Unable to '
        'process input image. Please retry or report in '
        'https://developers.generativeai.google/guide/troubleshooting", '
        '"status": "INVALID_ARGUMENT"}}';
    const invalidBody = '{"error": {"code": 400, "message": "Provided image '
        'is not valid.", "status": "INVALID_ARGUMENT"}}';

    test('only the two image sentences: any other INVALID_ARGUMENT stays a '
        'model error', () {
      expect(classifyGeminiError('HTTP 400: $unableBody'),
          GeminiErrorClass.imageRejected);
      expect(classifyGeminiError('HTTP 400: $invalidBody'),
          GeminiErrorClass.imageRejected);
      expect(
          classifyGeminiError('HTTP 400: {"error": {"code": 400, "message": '
              '"JSON mode is not enabled for models/gemma-3-27b-it", '
              '"status": "INVALID_ARGUMENT"}}'),
          GeminiErrorClass.modelError);
      expect(isRetryableGeminiError('HTTP 400: $unableBody'), isFalse,
          reason: 'one retry in place, never the transient classes');
    });

    test('"Please retry": one more try in place, then the photo verdict',
        () async {
      final s = await freshSettings();
      final h = Harness(s, [
        http.Response(unableBody, 400),
        http.Response(unableBody, 400),
      ]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(h.requests, hasLength(2));
      expect(h.sleeps, [const Duration(seconds: 5)]);
      expect(out.retryable, isFalse,
          reason: "refused twice: the analyzer's verdict is final (the "
              'pipeline tests below show where it is still sent again)');
      expect(classifyAnalysisError(out.error), AnalysisErrorKind.badPhoto,
          reason: out.error);
      expect(out.error, isNot(contains('model')));
    });

    test('the retry can succeed', () async {
      final s = await freshSettings();
      final h = Harness(s, [http.Response(unableBody, 400), ok(foodJson)]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(out.isFood, isTrue, reason: out.error);
      expect(h.requests, hasLength(2));
    });

    test('"Provided image is not valid." asks for no retry: one call',
        () async {
      final s = await freshSettings();
      final h = Harness(s, [http.Response(invalidBody, 400)]);
      final out = await h.analyzer.analyzePhoto(photo);
      expect(h.requests, hasLength(1));
      expect(h.sleeps, isEmpty);
      expect(out.retryable, isFalse);
      expect(classifyAnalysisError(out.error), AnalysisErrorKind.badPhoto,
          reason: out.error);
    });

    // In the photo pipeline. badPhoto is also its mark of a photo an engine
    // could not turn into upload bytes, which the iOS background run defers
    // to the app (PhotoPipeline.deferUndecodable) rather than failing. The
    // refusal shares the kind for its localized line, so it is deferred
    // there too, and each background run sends it again until
    // DeferredAssets passes it over (background_glue_test pins that count
    // for any retryable badPhoto). Pinned so that changing it is a decision.
    ({GeminiAnalyzer analyzer, List<http.Request> sent}) alwaysRefusing(
        AppSettings s, String body) {
      final sent = <http.Request>[];
      return (
        analyzer: GeminiAnalyzer(s,
            client: MockClient((req) async {
              sent.add(req);
              return http.Response(body, 400);
            }),
            sleep: (_) async {},
            normalizer: (b) async => b),
        sent: sent,
      );
    }

    for (final (name, body, perRun) in [
      ('"Please retry"', unableBody, 2),
      ('"not valid"', invalidBody, 1),
    ]) {
      test('$name in the app (or on Android): failed after $perRun '
          'call(s), and no later automatic scan sends it again', () async {
        final r = alwaysRefusing(await freshSettings(), body);
        final dao = FakeDao();
        final pipeline = PhotoPipeline(dao: dao, analyzer: r.analyzer);
        final first =
            await pipeline.process(IntakePhoto(photo, 'a1', 'IMG_1.jpg'));
        expect(first.kind, PhotoOutcomeKind.failed);
        expect(first.retryable, isFalse, reason: first.message);
        expect(first.errorKind, AnalysisErrorKind.badPhoto);
        expect(dao.ledger.values.single, IngestionStatus.failed);
        expect(r.sent, hasLength(perRun));
        final again =
            await pipeline.process(IntakePhoto(photo, 'a1', 'IMG_1.jpg'));
        expect(again.kind, PhotoOutcomeKind.alreadyTracked);
        expect(r.sent, hasLength(perRun));
      });

      test('$name in an iOS background run: deferred like a photo that '
          'engine cannot decode, $perRun call(s) a run, then failed by the '
          "app's own run", () async {
        final r = alwaysRefusing(await freshSettings(), body);
        final dao = FakeDao();
        final background = PhotoPipeline(
            dao: dao, analyzer: r.analyzer, deferUndecodable: true);
        final deferred =
            await background.process(IntakePhoto(photo, 'a1', 'IMG_1.jpg'));
        expect(deferred.kind, PhotoOutcomeKind.failed);
        // Exactly what background_glue counts as one deferral.
        expect(deferred.retryable, isTrue, reason: deferred.message);
        expect(deferred.errorKind, AnalysisErrorKind.badPhoto);
        expect(dao.ledger, isEmpty, reason: 'released, so offered again');
        expect(r.sent, hasLength(perRun));

        final app = PhotoPipeline(dao: dao, analyzer: r.analyzer);
        final settled =
            await app.process(IntakePhoto(photo, 'a1', 'IMG_1.jpg'));
        expect(settled.retryable, isFalse, reason: settled.message);
        expect(dao.ledger.values.single, IngestionStatus.failed);
        expect(r.sent, hasLength(2 * perRun));
      });
    }
  });
}
