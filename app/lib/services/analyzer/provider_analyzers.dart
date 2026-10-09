/// OpenAI + Anthropic vision backends behind the same [AnalyzerService]
/// seam as Gemini, plus the per-call delegating switch.
///
/// Design: GeminiAnalyzer is spec-pinned and untouched; these mirror its
/// behavioral contract (normalize → prompt(+dietary) → bounded retries on
/// transient classes → parseAiJson → coerceIsFood; validateKey = 1-token
/// real generation where quota-class responses count as ACCEPTED because
/// they prove the key authenticated). The shared prompts from shared/ are
/// provider-agnostic text, so server↔app parity is unaffected — the golden
/// vectors guard everything downstream of the model reply.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import '../../core/leftover_logic.dart' show formatRecentMealsBlock;
import '../../core/prompts.dart';
import '../settings/app_settings.dart';
import 'gemini_analyzer.dart' show createAnalyzer;
import 'platform_decode.dart';

/// Transient failure classes shared by both providers: HTTP 429 (rate or
/// spend limits), 5xx/overloaded, client deadline, transport errors.
bool _isTransientStatus(int status) =>
    status == 429 || status == 529 || (status >= 500 && status < 600);

/// Pure-Dart decode in an isolate, then the platform codec for what Dart
/// cannot read (HEIC — i.e. every iPhone camera photo).
Future<Uint8List?> _computeNormalize(Uint8List bytes) =>
    normalizeAnyForAnalysis(bytes);

/// Common skeleton: subclasses supply the endpoint request and reply-text
/// extraction; everything else (normalize, retries, coercion, validate
/// semantics) is identical across providers.
abstract class _HttpVisionAnalyzer
    implements AnalyzerService, TextIntentExplainer {
  _HttpVisionAnalyzer(
    this.settings, {
    http.Client? client,
    Future<void> Function(Duration)? sleep,
    Future<Uint8List?> Function(Uint8List)? normalizer,
  })  : client = client ?? http.Client(),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _normalize = normalizer ?? _computeNormalize;

  final AppSettings settings;
  final http.Client client;
  final Future<void> Function(Duration) _sleep;
  final Future<Uint8List?> Function(Uint8List) _normalize;

  static const int maxAttempts = 3; // parity with spec §3.3
  static const Duration httpDeadline = Duration(seconds: 90); // spec §3.2

  /// Per-provider wall clock. Direct model APIs keep the §3.2 90 s; a
  /// provider fronting slower work (a CLI run on the user's server) must
  /// allow more, or the client gives up while the server is still working
  /// and the retry only meets its own busy lock.
  Duration get deadline => httpDeadline;
  static const int maxOriginalFallbackBytes = 5 * 1024 * 1024; // spec §3.1

  /// See [analyzePhoto] — the current call's recent-meal compacts.
  List<Map<String, dynamic>> recentMealsForRequest = const [];

  /// Provider hooks.
  String? get apiKey;
  String get model;
  String get providerLabel;

  /// Verbatim message for an HTTP 404, or null for the generic bucket.
  /// The compat providers override this: a 404 there almost always means
  /// a wrong / retired / not-yet-activated MODEL id, not a bad key — and
  /// the generic message left users regenerating a key that worked.
  String? get notFoundMessage => null;

  /// Verbatim message for an HTTP 503, built from the response [body];
  /// null for the generic transient bucket. ServerAnalyzer overrides this:
  /// its 503 carries a `reason` (busy CLI vs "no key (GLM_PLAN_KEY)") that
  /// the generic 'network or service issue' message hid — a refused
  /// backend looked identical to a hiccup and cost an hour of debugging
  /// on 2026-07-31.
  String? unavailableMessage(String body) => null;

  /// The server's own verdict on a 503: true = busy (retry helps), false =
  /// the run already answered (terminal), null = it did not say (an old
  /// server, or a configuration refusal). Overridden by ServerAnalyzer.
  bool? unavailableRetry(String body) => null;

  /// A 400 the provider EXPLAINS (`{"error": code}` from the user's own
  /// server): a terminal message carrying the code, or null for the
  /// generic path. Vendor 400s stay generic — their bodies are prose.
  String? rejectedMessage(String body) => null;
  http.Request buildRequest(String key,
      {required String prompt, Uint8List? jpegBytes, required int maxTokens});
  String extractText(Map<String, dynamic> body);

  /// One POST. Returns the reply text; throws [_ProviderException] with a
  /// transient/permanent classification otherwise. [extract] false skips
  /// text extraction entirely (validateKey: an HTTP 200 proves the key
  /// regardless of reply shape — a 1-token reply may contain no text
  /// block at all, same rule as Gemini's MAX_TOKENS case).
  Future<String> _post(
      {required String prompt,
      Uint8List? jpegBytes,
      String? apiKeyOverride,
      int maxTokens = 2048,
      bool extract = true}) async {
    final key = (apiKeyOverride ?? apiKey ?? '').trim();
    if (key.isEmpty) {
      // User state, not a photo defect: the photo stays eligible
      // (retryable) but re-attempting in place is pointless.
      throw _ProviderException(
          'No $providerLabel API key — add one in Settings.',
          transient: true,
          retryInPlace: false,
          verbatimMessage: true);
    }
    final req = buildRequest(key,
        prompt: prompt, jpegBytes: jpegBytes, maxTokens: maxTokens);
    // The BODY read must sit inside the same timeout and the same catch as
    // the send: a connection dropped after headers throws a raw
    // ClientException that every caller's `on _ProviderException` clause
    // would leak (breaking the "AnalyzerService never throws" contract),
    // and a stalled body — routine on flaky mainland networks and GLM's
    // free tier — would hang FOREVER, freezing the serialized photo
    // pipeline behind it. One deadline covers headers + body.
    final http.Response resp;
    try {
      resp = await client
          .send(req)
          .then(http.Response.fromStream)
          .timeout(deadline);
    } on TimeoutException {
      throw const _ProviderException('client deadline hit', transient: true);
    } catch (e) {
      throw _ProviderException('connection error: $e', transient: true);
    }
    if (resp.statusCode != 200) {
      // Exhausted-billing signatures, checked BEFORE the auth
      // classification because the providers disagree on the status code:
      //   OpenAI    429 insufficient_quota
      //   Zhipu GLM 429 code "1113" (余额不足 — also NOT a rate limit)
      //   Ark/Doubao 403 AccountOverdueError — a 403 that is NOT auth;
      //     treating it as "key rejected" burned the photo non-retryably
      //     and told the user to fix a key that works (review 2026-07-29)
      //   DashScope 400 Arrearage — a 400 that is NOT a client bug
      //   Anthropic 400 "credit balance is too low" — likewise
      // All mean "the key authenticated but the account needs money":
      // transient (the photo stays eligible; a recharge fixes it) and
      // quota-classed (validateKey accepts — the key itself is proven).
      final body = resp.body;
      final billingDead = (resp.statusCode == 429 &&
              (body.contains('insufficient_quota') ||
                  body.contains('"1113"'))) ||
          (resp.statusCode == 403 && body.contains('AccountOverdue')) ||
          // 402 Payment Required: DeepSeek "Insufficient Balance" and
          // OpenRouter's out-of-credits answer. Never an auth failure.
          resp.statusCode == 402 ||
          (resp.statusCode == 400 &&
              (body.contains('Arrearage') ||
                  body.contains('credit balance is too low')));
      if (billingDead) {
        throw _ProviderException(
            'Provider balance or credits exhausted — check your '
            '$providerLabel billing.',
            transient: true,
            quotaClass: true,
            billing: true,
            verbatimMessage: true);
      }
      if (resp.statusCode == 401 ||
          resp.statusCode == 403 ||
          // xAI reports a bad key as HTTP 400 "Incorrect API key provided".
          (resp.statusCode == 400 && body.contains('Incorrect API key'))) {
        throw const _ProviderException('key rejected',
            transient: false, auth: true);
      }
      final notFound = notFoundMessage;
      if (resp.statusCode == 404 && notFound != null) {
        throw _ProviderException(notFound,
            transient: false, verbatimMessage: true, modelError: true);
      }
      if (resp.statusCode == 503) {
        final custom = unavailableMessage(resp.body);
        if (custom != null) {
          // Three cases, deliberately distinct:
          //   true  → the CLI was BUSY: retry in place, photo survives.
          //   false → the run HAPPENED and produced nothing usable:
          //           TERMINAL, or the watcher re-spends a full CLI run on
          //           this photo every single scan.
          //   null  → no verdict (old server, or a config refusal like a
          //           missing plan key): keep the photo, but do NOT spin —
          //           seconds cannot add a plan key.
          final verdict = unavailableRetry(resp.body);
          throw _ProviderException(custom,
              transient: verdict != false,
              retryInPlace: verdict == true,
              serverBusy: verdict == true,
              verbatimMessage: true);
        }
      }
      if (resp.statusCode == 400) {
        final custom = rejectedMessage(resp.body);
        if (custom != null) {
          // Terminal: the REQUEST is wrong (an app/server version drift,
          // typically), so retrying reproduces it. The bare 'HTTP 400'
          // this used to throw left the owner's 2026-09-29 failure with
          // no code on either end.
          throw _ProviderException(custom,
              transient: false, verbatimMessage: true);
        }
        // A wrong / retired model id answered as a 400, not a 404: Zhipu
        // GLM code "1211" (模型不存在). Matched on the documented code
        // only, like "1113" above — the vendor's prose never reaches the
        // message.
        if (body.contains('"1211"')) {
          throw _ProviderException(
              notFound ??
                  '$providerLabel model not found — check the model name '
                      'in Settings.',
              transient: false,
              verbatimMessage: true,
              modelError: true);
        }
      }
      throw _ProviderException('HTTP ${resp.statusCode}',
          transient: _isTransientStatus(resp.statusCode),
          quotaClass: resp.statusCode == 429,
          // OpenAI / Anthropic post to one fixed endpoint, so a bare 404
          // there is the MODEL (OpenAI model_not_found, Anthropic
          // not_found_error "model: …"). ServerAnalyzer overrides probeKey,
          // the only reader of this flag.
          modelError: resp.statusCode == 404);
    }
    if (!extract) return '';
    try {
      return extractText(jsonDecode(resp.body) as Map<String, dynamic>);
    } on _ProviderException {
      rethrow; // extractText may classify precisely — keep its message
    } catch (_) {
      throw const _ProviderException('unexpected response shape',
          transient: false);
    }
  }

  @override
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals}) async {
    final sw = Stopwatch()..start();
    // Stashed for ServerAnalyzer.buildRequest (which sends DATA, not
    // prompt text). Safe as a field: the app's photo pipeline is
    // strictly serialized, so no two analyzePhoto calls overlap.
    recentMealsForRequest = recentMeals ?? const [];
    if (settings.isQuotaPaused) {
      return AnalysisOutcome(
          error: 'Analysis paused (quota) — retrying later.',
          retryable: true,
          wall: sw.elapsed);
    }
    Uint8List? sendBytes = await _normalize(originalBytes);
    if (sendBytes == null) {
      // Spec §3.1 step 6, NARROWED 2026-09-30: an unprocessed original may
      // go out only if it IS a small JPEG — the upload is labelled
      // image/jpeg. Raw HEIC sent this way came back "not food" for every
      // iPhone camera photo; failing visibly beats a confident wrong answer.
      sendBytes = unprocessedFallback(originalBytes,
          maxBytes: maxOriginalFallbackBytes);
      if (sendBytes == null) {
        return AnalysisOutcome(
            error: looksLikeJpeg(originalBytes)
                ? 'Could not process this photo (decode failed and it is '
                    'too large to send unprocessed).'
                : 'Could not process this photo (decode failed and it is '
                    'not a JPEG).',
            wall: sw.elapsed);
      }
    }
    final prompt =
        withDietaryProfile(foodDetectionPrompt, settings.dietaryProfile) +
            formatRecentMealsBlock(recentMeals ?? const []);
    for (var attempt = 1;; attempt++) {
      String text;
      try {
        text = await _post(prompt: prompt, jpegBytes: sendBytes);
      } on _ProviderException catch (e) {
        if (attempt < maxAttempts &&
            e.transient &&
            e.retryInPlace &&
            !e.quotaClass) {
          await _sleep(Duration(seconds: 5 * attempt));
          continue;
        }
        return AnalysisOutcome(
            error: e.userMessage, retryable: e.transient, wall: sw.elapsed);
      }
      dynamic parsed;
      try {
        parsed = parseAiJson(text);
      } on FormatException {
        return AnalysisOutcome(
            error: "Couldn't understand the AI response.", wall: sw.elapsed);
      }
      if (parsed is! Map) {
        return AnalysisOutcome(
            error: 'The AI returned an unusable analysis.', wall: sw.elapsed);
      }
      final analysis = Map<String, dynamic>.from(parsed);
      final isFood = coerceIsFood(analysis);
      if (isFood == null) {
        return AnalysisOutcome(
            error: 'The AI returned an unusable analysis.', wall: sw.elapsed);
      }
      analysis['is_food'] = isFood;
      return AnalysisOutcome(
          analysis: analysis, isFood: isFood, wall: sw.elapsed);
    }
  }

  /// Waits for a text request that met the server's busy verdict: 5, 10,
  /// 15, 20, 25 and 30 s (~105 s), enough for one 20-60 s photo run plus
  /// the gap before the pipeline uploads the next photo.
  static const int textBusyAttempts = 7;

  @override
  Future<Map<String, dynamic>?> textIntent(String prompt) async =>
      (await textIntentOutcome(prompt)).json;

  /// [textIntent] plus the failure's [_ProviderException.userMessage], so
  /// the chat can name a rejected key or model instead of "retry".
  @override
  Future<TextIntentOutcome> textIntentOutcome(String prompt) async {
    String text;
    for (var attempt = 1;; attempt++) {
      try {
        text = await _post(prompt: prompt);
        break;
      } on _ProviderException catch (e) {
        // Only the server's explicit busy verdict waits: the server answers
        // /api/text_intent with an instant 503 {retry: true} while a photo
        // holds its CLI lock, which the auto-scan does every time the app
        // opens — and a single attempt turned the owner's corrections into
        // "联系 AI 失败". Every other failure stays single-attempt (spec §4
        // step 4: the text handler surfaces errors directly).
        if (e.serverBusy && attempt < textBusyAttempts) {
          await _sleep(Duration(seconds: 5 * attempt));
          continue;
        }
        return TextIntentOutcome(null, error: e.userMessage);
      }
    }
    dynamic parsed;
    try {
      parsed = parseAiJson(text);
    } on FormatException {
      return const TextIntentOutcome(null);
    }
    if (parsed is Map) {
      return TextIntentOutcome(Map<String, dynamic>.from(parsed));
    }
    if (parsed is List) {
      return TextIntentOutcome({'actions': parsed}); // §4.1 bare-array rule
    }
    return const TextIntentOutcome(null);
  }

  @override
  Future<Map<String, dynamic>?> leftoverIntent(
      Uint8List originalBytes, String originalCompact) async {
    // Direct-API path: the leftover prompt is composed HERE from the
    // shared template — the server provider overrides this and ships the
    // compact analysis instead (its prompt is composed server-side).
    final sendBytes = await _normalize(originalBytes) ??
        unprocessedFallback(originalBytes, maxBytes: maxOriginalFallbackBytes);
    if (sendBytes == null) return null;
    final prompt = sharedLeftoverPrompt(originalAnalysis: originalCompact);
    String text;
    try {
      text = await _post(prompt: prompt, jpegBytes: sendBytes);
    } on _ProviderException {
      return null;
    }
    dynamic parsed;
    try {
      parsed = parseAiJson(text);
    } on FormatException {
      return null;
    }
    return parsed is Map ? Map<String, dynamic>.from(parsed) : null;
  }

  @override
  Future<String?> validateKey(String apiKey) async {
    try {
      // extract:false — HTTP 200 alone proves the key; a 1-token reply may
      // legitimately carry no text block (Gemini MAX_TOKENS parity).
      await _post(
          prompt: 'ping', apiKeyOverride: apiKey, maxTokens: 1, extract: false);
      return null;
    } on _ProviderException catch (e) {
      // Same rule as Gemini: a REAL HTTP quota-class response proves the
      // key authenticated → accepted. Auth/permanent → error message.
      if (e.quotaClass) return null;
      return e.userMessage;
    }
  }

  @override
  Future<KeyProbe> probeKey(String apiKey) async {
    try {
      await _post(
          prompt: 'ping', apiKeyOverride: apiKey, maxTokens: 1, extract: false);
      return const KeyProbe(KeyProbeResult.ok);
    } on _ProviderException catch (e) {
      // The distinction validateKey CANNOT make: both of these accept the
      // key, but only one is a "wait it out" situation.
      if (e.billing) {
        return KeyProbe(KeyProbeResult.outOfCredit, message: e.userMessage);
      }
      // A transient transport failure (timeout, dropped connection) is NOT
      // a rejected key — reporting "The key was not accepted" for a flaky
      // network sends the user to regenerate a fine key. Only a genuine
      // auth refusal rejects; everything transient is "try again".
      if (e.quotaClass || (e.transient && !e.auth)) {
        return KeyProbe(KeyProbeResult.rateLimited, message: e.userMessage);
      }
      // A wrong / retired model id is not a rejected key either: the
      // "re-copy the key" fix sent users to regenerate a key that worked.
      if (e.modelError) {
        return KeyProbe(KeyProbeResult.modelNotFound, message: e.userMessage);
      }
      // A genuine auth refusal carries no message: the diagnostics page
      // shows the message as its raw-evidence line, and the generic English
      // 'The provider rejected the API key' only restated the localized
      // summary under it (loop find 2026-10-08). Any other permanent
      // failure keeps its verbatim evidence.
      return KeyProbe(KeyProbeResult.rejected,
          message: e.auth ? null : e.userMessage);
    }
  }
}

class _ProviderException implements Exception {
  const _ProviderException(this.message,
      {required this.transient,
      this.auth = false,
      this.quotaClass = false,
      this.billing = false,
      this.retryInPlace = true,
      this.verbatimMessage = false,
      this.modelError = false,
      this.serverBusy = false});
  final String message;
  final bool transient;
  final bool auth;
  final bool quotaClass;

  /// The provider answered, but about the MODEL id (not found, retired,
  /// not activated) — never about the key. Permanent like any other
  /// non-transient failure; only probeKey reads it, to keep diagnostics
  /// from calling a model problem a rejected key.
  final bool modelError;

  /// The key authenticated but the ACCOUNT cannot pay. A subset of
  /// [quotaClass] (both accept the key) with a completely different
  /// remedy: recharge, not wait.
  final bool billing;

  /// False for conditions that cannot change within this call (missing
  /// key): still retryable at the OUTCOME level, but in-place sleeps are
  /// pointless.
  final bool retryInPlace;

  /// The user's own server said its analyzer is BUSY (503 with a reason
  /// and retry:true) — another run holds the CLI lock, so waiting helps.
  /// Narrower than [retryInPlace] (which is also true for connection
  /// errors and deadlines): only textIntent reads it, to wait out a photo
  /// run instead of failing the user's chat request at once.
  final bool serverBusy;

  /// True when [message] is already user-facing (skip the generic bucket).
  final bool verbatimMessage;

  String get userMessage {
    if (verbatimMessage) return message;
    if (auth) return 'The provider rejected the API key. Check Settings.';
    if (quotaClass) {
      return 'Provider rate/spend limit hit — will retry later.';
    }
    if (transient) {
      return 'Error contacting the provider (network or service issue).';
    }
    return 'Provider request failed: $message';
  }
}

/// OpenAI chat-completions vision backend.
class OpenAiAnalyzer extends _HttpVisionAnalyzer {
  OpenAiAnalyzer(super.settings,
      {super.client, super.sleep, super.normalizer});

  static final Uri _endpoint =
      Uri.parse('https://api.openai.com/v1/chat/completions');

  @override
  String? get apiKey => settings.openaiApiKey;
  @override
  String get model => settings.openaiModel;
  @override
  String get providerLabel => 'OpenAI';

  @override
  http.Request buildRequest(String key,
      {required String prompt, Uint8List? jpegBytes, required int maxTokens}) {
    final content = <Map<String, Object?>>[
      {'type': 'text', 'text': prompt},
      if (jpegBytes != null)
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/jpeg;base64,${base64Encode(jpegBytes)}'
          }
        },
    ];
    final req = http.Request('POST', _endpoint)
      ..headers['Authorization'] = 'Bearer $key'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': content}
        ],
        // Our shared prompts already instruct JSON; json_object mode makes
        // the syntax guarantee explicit (schema stays the coercers' job).
        if (jpegBytes != null) 'response_format': {'type': 'json_object'},
        // NOT 'max_tokens': newer models (o-series, gpt-5 family) reject it
        // with 400; max_completion_tokens is accepted across current models.
        'max_completion_tokens': maxTokens,
      });
    return req;
  }

  @override
  String extractText(Map<String, dynamic> body) =>
      ((body['choices'] as List).first as Map)['message']['content'] as String;
}

/// Any OpenAI-compatible chat-completions vision backend, parameterized by
/// endpoint. This is how the mainland-China providers (Alibaba Qwen,
/// ByteDance Doubao, Zhipu GLM — all of which expose OpenAI-compatible
/// APIs) ride the exact request/retry/coercion contract OpenAI already
/// gets, without three copies of the class.
///
/// Differences from [OpenAiAnalyzer] kept deliberately:
/// - `max_tokens`, not `max_completion_tokens`: the compat layers accept
///   the classic field; several reject the newer one with 400.
/// - `response_format` json_object only when [supportsJsonMode] — Zhipu's
///   API reference marks the field TEXT-models-only ("仅文本模型支持此字段"),
///   so vision calls there must rely on the prompt + fence-stripping parse.
/// - [extraBody] for provider extension fields — Doubao and GLM vision
///   models THINK by default; `thinking: {type: disabled}` cuts the cost
///   and latency of a fixed-schema extraction task (researched 2026-07-29).
class OpenAiCompatAnalyzer extends _HttpVisionAnalyzer {
  OpenAiCompatAnalyzer(
    super.settings, {
    required this.endpoint,
    required this.label,
    required this.keyOf,
    required this.modelOf,
    this.supportsJsonMode = true,
    this.extraBody = const {},
    this.extraHeaders = const {},
    this.notFoundHint,
    super.client,
    super.sleep,
    super.normalizer,
  });

  final Uri endpoint;
  final String label;
  final String? Function(AppSettings) keyOf;
  final String Function(AppSettings) modelOf;
  final bool supportsJsonMode;
  final Map<String, Object?> extraBody;

  /// Static request headers beyond auth/content-type (OpenRouter's
  /// attribution pair). Auth and content-type are set AFTER these, so a
  /// config entry can never clobber the bearer.
  final Map<String, String> extraHeaders;

  /// Per-provider HTTP-404 explanation (see [notFoundMessage]).
  final String? notFoundHint;

  @override
  String? get apiKey => keyOf(settings);
  @override
  String get model => modelOf(settings);
  @override
  String get providerLabel => label;
  @override
  String? get notFoundMessage => notFoundHint;

  @override
  http.Request buildRequest(String key,
      {required String prompt, Uint8List? jpegBytes, required int maxTokens}) {
    final content = <Map<String, Object?>>[
      {'type': 'text', 'text': prompt},
      if (jpegBytes != null)
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/jpeg;base64,${base64Encode(jpegBytes)}'
          }
        },
    ];
    // The model field is free text: a user-typed *thinking* model id
    // (doubao-seed-*-thinking-*, glm-4.1v-thinking-*) REQUIRES thinking,
    // and sending {type: disabled} to one is a hard 400 on every call.
    final extras = Map<String, Object?>.of(extraBody);
    if (model.contains('thinking')) extras.remove('thinking');
    return http.Request('POST', endpoint)
      ..headers.addAll(extraHeaders)
      ..headers['Authorization'] = 'Bearer $key'
      ..headers['Content-Type'] = 'application/json'
      // extras spread FIRST: on a key collision the computed core fields
      // must win, or a config entry could silently clobber model/messages
      // or validateKey's 1-token cap (jsonEncode keeps the LAST value —
      // no error would ever surface).
      ..body = jsonEncode({
        ...extras,
        'model': model,
        'messages': [
          {'role': 'user', 'content': content}
        ],
        if (supportsJsonMode && jpegBytes != null)
          'response_format': {'type': 'json_object'},
        'max_tokens': maxTokens,
      });
  }

  @override
  String extractText(Map<String, dynamic> body) =>
      ((body['choices'] as List).first as Map)['message']['content'] as String;
}

/// Anthropic messages-API vision backend.
class AnthropicAnalyzer extends _HttpVisionAnalyzer {
  AnthropicAnalyzer(super.settings,
      {super.client, super.sleep, super.normalizer});

  static final Uri _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  @override
  String? get apiKey => settings.anthropicApiKey;
  @override
  String get model => settings.anthropicModel;
  @override
  String get providerLabel => 'Anthropic';

  @override
  http.Request buildRequest(String key,
      {required String prompt, Uint8List? jpegBytes, required int maxTokens}) {
    final content = <Map<String, Object?>>[
      if (jpegBytes != null)
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/jpeg',
            'data': base64Encode(jpegBytes),
          }
        },
      {'type': 'text', 'text': prompt},
    ];
    final req = http.Request('POST', _endpoint)
      ..headers['x-api-key'] = key
      ..headers['anthropic-version'] = '2023-06-01'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'messages': [
          {'role': 'user', 'content': content}
        ],
      });
    return req;
  }

  @override
  String extractText(Map<String, dynamic> body) {
    // Content may lead with thinking blocks (claude-sonnet-5's adaptive
    // thinking) — the answer is the FIRST TEXT block, not content.first.
    for (final block in body['content'] as List) {
      if (block is Map && block['type'] == 'text') {
        return block['text'] as String;
      }
    }
    throw const FormatException('no text block in reply');
  }
}

/// Per-call delegation on [AppSettings.provider]: switching providers in
/// Settings takes effect on the NEXT request — no DI rewiring, no restart.
/// The user's OWN CalorieTracker server as an analyzer: photos and prompts
/// go to its /api/analyze_photo and /api/text_intent endpoints, which run
/// the Claude Code CLI under the owner's Claude SUBSCRIPTION — so analyses
/// cost no API money.
///
/// Why the phone does NOT carry a subscription token directly: Claude
/// subscription credentials authorize Claude Code itself, not arbitrary
/// third-party clients, and an APK is a shipping container for whatever is
/// baked into it (this build gets handed to other people). The server
/// already holds that credential legitimately and runs the real CLI, so the
/// device only ever stores the server's own upload key.
///
/// Reachability caveat worth knowing: this points at a plain-HTTP endpoint
/// on the user's VM, so the upload key and photo bytes cross the network
/// unencrypted — same exposure the existing Termux watcher already accepts.
/// TLS in front of Flask is the fix; the app is ready for an https:// base
/// URL the moment the server has one.
class ServerAnalyzer extends _HttpVisionAnalyzer {
  ServerAnalyzer(super.settings, {super.client, super.sleep, super.normalizer});

  @override
  String? get apiKey => settings.serverApiKey;
  @override
  String get model => 'server';
  @override
  String get providerLabel => 'server';

  @override
  String? unavailableMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final reason = decoded['reason'];
        if (reason is String && reason.isNotEmpty) {
          // retry:true (busy CLI) — seconds fix it, so let the normal
          // in-place retry run. Anything else is terminal for this photo:
          // the run HAPPENED and produced nothing usable, and three more
          // 120 s CLI runs would spend the subscription for the same
          // answer (review 2026-07-31).
          return 'The server cannot analyze right now: $reason.';
        }
      }
    } on FormatException {
      // fall through to the generic transient message
    }
    return null;
  }

  @override
  bool? unavailableRetry(String body) {
    try {
      final decoded = jsonDecode(body);
      // Bools only, ON PURPOSE. The server's "retry": "later" (a closed
      // Claude-plan usage window, a CLI timeout — 2026-10-07) lands on
      // the null branch below: keep the photo for the next scan, but do
      // not spend three in-place attempts on a window that is still
      // closed. Server-side fix; this reader needed no change.
      if (decoded is Map && decoded['retry'] is bool) {
        return decoded['retry'] as bool;
      }
    } on FormatException {
      // fall through
    }
    return null; // old server / configuration refusal / "later"
  }

  /// The server's own 400 codes (no_image, bad_recent_meals, bad_model,
  /// bad_effort, bad_backend, …): repeat the code so the outcome names
  /// WHICH contract broke. Anything without a string `error` (an old
  /// server, a proxy page) keeps the generic path.
  @override
  String? rejectedMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        final code = (decoded['error'] as String).trim();
        if (code.isNotEmpty && RegExp(r'^[a-z_]{1,40}$').hasMatch(code)) {
          return 'The server rejected this request ($code).';
        }
      }
    } on FormatException {
      // fall through
    }
    return null;
  }

  /// The server runs a Claude CLI analysis (up to ~120 s, and up to ~240 s
  /// across its internal stream→file fallback) behind a synchronous Flask
  /// handler, so the 90 s API default would abandon work that is still
  /// running — and the retry would only meet the server's own
  /// single-flight lock, turning a slow success into a hard failure.
  @override
  Duration get deadline => const Duration(minutes: 5);

  Uri _uri(String path) => Uri.parse('${settings.serverBaseUrl}$path');

  /// The user's Claude-plan model/effort choice (2026-08-05). Sent ONLY
  /// on the claude backend ('' = omit = server default): the vendor plans
  /// map model names server-side and the API 400s overrides for them.
  Map<String, String> _planChoice() {
    if (settings.serverBackend != 'claude') return const {};
    return {
      if (settings.serverModel.isNotEmpty) 'model': settings.serverModel,
      if (settings.serverEffort.isNotEmpty) 'effort': settings.serverEffort,
    };
  }

  @override
  Future<Map<String, dynamic>?> leftoverIntent(
      Uint8List originalBytes, String originalCompact) async {
    // Server path: ship the COMPACT ORIGINAL ANALYSIS, never a prompt —
    // the server re-sanitizes it and composes the leftover prompt from
    // its own shared/ copy (same posture as analyze_photo).
    final key = (apiKey ?? '').trim();
    if (key.isEmpty || settings.serverBaseUrl.isEmpty) return null;
    final sendBytes = await _normalize(originalBytes) ??
        unprocessedFallback(originalBytes,
            maxBytes: _HttpVisionAnalyzer.maxOriginalFallbackBytes);
    if (sendBytes == null) return null;
    final body = jsonEncode({
      'image_b64': base64Encode(sendBytes),
      'original_analysis': originalCompact,
      'backend': settings.serverBackend,
      ..._planChoice(),
    });
    try {
      http.Response resp;
      for (var attempt = 1;; attempt++) {
        resp = await client
            .post(_uri('/api/analyze_leftover'),
                headers: {
                  'content-type': 'application/json',
                  'X-API-Key': key,
                  'X-Client-Platform': 'app',
                },
                body: body)
            .timeout(deadline);
        // Same busy wait as textIntent: the server answers an instant 503
        // {reason, retry: true} while a photo run holds its CLI lock — the
        // auto-scan's run on every app open — and one attempt showed the
        // leftover screen's "couldn't estimate" error exactly then. Only
        // that verdict waits (the screen's spinner is up and its re-entry
        // guard blocks a second tap); retry: false (the run happened) and
        // "later" (a closed usage window) stay single-attempt, like every
        // other non-200.
        if (resp.statusCode == 503 &&
            unavailableMessage(resp.body) != null &&
            unavailableRetry(resp.body) == true &&
            attempt < _HttpVisionAnalyzer.textBusyAttempts) {
          await _sleep(Duration(seconds: 5 * attempt));
          continue;
        }
        break;
      }
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is Map && decoded['leftover'] is Map) {
        // Same receipt rule as the photo path: a pre-upgrade server
        // ignores the backend field and answers analyzed_by:'claude' —
        // accepting that reply silently bills the wrong plan forever
        // (pressure-test find).
        final paidBy = decoded['analyzed_by'];
        if (paidBy is String && paidBy != settings.serverBackend) {
          return null;
        }
        return (decoded['leftover'] as Map).cast<String, dynamic>();
      }
    } catch (_) {
      // null = "couldn't estimate" — the flow surfaces a friendly error.
    }
    return null;
  }

  @override
  http.Request buildRequest(String key,
      {required String prompt, Uint8List? jpegBytes, required int maxTokens}) {
    if (settings.serverBaseUrl.isEmpty) {
      // Retryable at the OUTCOME level (the user may add the address later)
      // but nothing to retry in place.
      throw const _ProviderException(
          'Add your server address in Settings to use the subscription path.',
          transient: true,
          retryInPlace: false,
          verbatimMessage: true);
    }
    final isPhoto = jpegBytes != null;
    return http.Request(
        'POST', _uri(isPhoto ? '/api/analyze_photo' : '/api/text_intent'))
      ..headers['content-type'] = 'application/json'
      ..headers['X-API-Key'] = key
      ..headers['X-Client-Platform'] = 'app'
      // PHOTO: send only the dietary PROFILE, never a whole prompt. The
      // server composes the analysis prompt from its own shared/ copy — a
      // caller-authored prompt is an instruction channel into the CLI, and
      // the CLI's image path necessarily has the Read tool enabled.
      // TEXT: the prompt IS the user's request, and that endpoint runs
      // with tools disabled.
      ..body = jsonEncode(isPhoto
          ? {
              'image_b64': base64Encode(jpegBytes),
              'dietary_profile': settings.dietaryProfile ?? '',
              // Whose subscription pays on the server: 'claude' (default),
              // 'glm' (coding plan) or 'doubao' (agent plan). The plan
              // keys live in the SERVER's .env — never on the phone.
              'backend': settings.serverBackend,
              if (recentMealsForRequest.isNotEmpty)
                'recent_meals': recentMealsForRequest,
              ..._planChoice(),
            }
          : {
              'prompt': prompt,
              'backend': settings.serverBackend,
              ..._planChoice(),
            });
  }

  @override
  String extractText(Map<String, dynamic> body) {
    // Photos answer {ok, analysis}, text answers {ok, result}. The base
    // layer wants TEXT to parseAiJson, so hand the payload back as JSON —
    // that keeps every downstream rule (coerceIsFood, bare-array handling)
    // identical to the direct-API providers.
    //
    // analyzed_by is the payer receipt: a pre-upgrade server IGNORES the
    // request's backend field, answers analyzed_by:'claude', and would
    // silently spend the Claude plan forever while the user believes GLM
    // or Doubao is paying. Refuse the mismatch loudly — permanent, since
    // only a server update fixes it (a retry would spend the WRONG plan
    // again and discard the result again).
    final by = body['analyzed_by'];
    if (by is String && by.isNotEmpty && by != settings.serverBackend) {
      throw _ProviderException(
          'The server analyzed with "$by", not the selected '
          '"${settings.serverBackend}" — update the server so it '
          'understands backend selection.',
          transient: false,
          verbatimMessage: true);
    }
    final payload = body['analysis'] ?? body['result'];
    if (payload == null) throw const FormatException('no payload');
    return jsonEncode(payload);
  }

  /// Begin the server's Claude OAuth re-connect (the server spawns its own
  /// `claude setup-token`): returns the OFFICIAL Anthropic authorize URL
  /// for the system browser, or an error message. No credential is
  /// involved on this side beyond the server upload key.
  Future<({String? url, String? error})> startClaudeAuth() async {
    final base = settings.serverBaseUrl;
    final key = (settings.serverApiKey ?? '').trim();
    if (base.isEmpty || key.isEmpty) {
      return (url: null, error: 'Set the server address and key first.');
    }
    try {
      final req = http.Request('POST', _uri('/api/claude_auth/start'))
        ..headers['content-type'] = 'application/json'
        ..headers['X-API-Key'] = key
        ..body = '{}';
      final resp = await http.Response.fromStream(
          await client.send(req).timeout(deadline));
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && body['url'] is String) {
        return (url: body['url'] as String, error: null);
      }
      return (
        url: null,
        error: (body['reason'] ?? 'Server answered HTTP ${resp.statusCode}.')
            .toString()
      );
    } catch (e) {
      return (url: null, error: 'Could not reach the server.');
    }
  }

  /// Hand the pasted authorization code to the waiting server flow.
  /// Null = connected; otherwise a user-facing error.
  Future<String?> completeClaudeAuth(String code) async {
    final key = (settings.serverApiKey ?? '').trim();
    try {
      final req = http.Request('POST', _uri('/api/claude_auth/complete'))
        ..headers['content-type'] = 'application/json'
        ..headers['X-API-Key'] = key
        ..body = jsonEncode({'code': code.trim()});
      final resp = await http.Response.fromStream(
          await client.send(req).timeout(deadline));
      if (resp.statusCode == 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return (body['reason'] ?? 'Server answered HTTP ${resp.statusCode}.')
          .toString();
    } catch (e) {
      return 'Could not reach the server.';
    }
  }

  /// The server's probe is its FREE /api/auth_check — never the inherited
  /// one. The base probeKey sends a 'ping' prompt, which for this provider
  /// means POST /api/text_intent: a full CLI run under the owner's
  /// subscription (up to the 5-minute deadline) whose prose reply then
  /// fails the JSON contract, so a perfectly good setup was reported as
  /// "The key was not accepted" — and the readiness verdicts this class
  /// exists to produce were lost (regression caught 2026-07-31).
  @override
  Future<KeyProbe> probeKey(String apiKey) async {
    final error = await validateKey(apiKey);
    if (error == null) return const KeyProbe(KeyProbeResult.ok);
    // "backend not ready" / "predates backend selection" are SERVER-side
    // configuration facts, not a rejected upload key: the key reached the
    // server and was accepted. Rate-limited is the closest non-rejecting
    // class, and it carries the verbatim message.
    final serverConfigured =
        error.contains('not ready') || error.contains('update the server');
    return KeyProbe(
        serverConfigured ? KeyProbeResult.rateLimited : KeyProbeResult.rejected,
        message: error);
  }

  /// Whether the SERVER already holds a Claude-plan sign-in — the fact a
  /// freshly provisioned phone needs, so it stops implying "Connect Claude"
  /// is required (2026-09-28). 'token' | 'none' from the server;
  /// 'unreachable' / 'rejected' when it could not be asked (the page shows
  /// "could not check"); null ONLY for a 200 without the field — an older
  /// server — where the page hides the row rather than guess.
  Future<String?> serverLoginState() async {
    final base = settings.serverBaseUrl;
    final key = (settings.serverApiKey ?? '').trim();
    if (base.isEmpty || key.isEmpty) return null;
    try {
      final req = http.Request('POST', _uri('/api/auth_check'))
        ..headers['content-type'] = 'application/json'
        ..headers['X-API-Key'] = key
        ..headers['X-Client-Platform'] = 'app'
        ..body = '{}';
      // A short cap, NOT the 5-minute analysis deadline: this row is read
      // while the page is open, and against an unreachable host it sat on
      // "checking…" for the whole deadline (seen on the simulator).
      final resp = await client
          .send(req)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 401 || resp.statusCode == 403) return 'rejected';
      if (resp.statusCode != 200) return 'unreachable';
      final decoded = jsonDecode(resp.body);
      final v = decoded is Map ? decoded['claude_login'] : null;
      return (v == 'token' || v == 'none') ? v as String : null;
    } catch (_) {
      return 'unreachable';
    }
  }

  /// /api/auth_check proves "address reachable + key accepted" with no side
  /// effects and no CLI run. Deliberately NOT /ping: that is the Termux
  /// watcher's liveness channel, and stamping it from here would forge
  /// watcher liveness and mute the stale-watcher outage alert.
  @override
  Future<String?> validateKey(String apiKey) async {
    final base = settings.serverBaseUrl;
    if (base.isEmpty) return 'Add your server address first.';
    final key = apiKey.trim();
    if (key.isEmpty) return 'Enter your server upload key.';
    final req = http.Request('POST', _uri('/api/auth_check'))
      ..headers['content-type'] = 'application/json'
      ..headers['X-API-Key'] = key
      ..headers['X-Client-Platform'] = 'app'
      ..body = '{}';
    try {
      // Body read inside the timeout, as in _post — a stalled body would
      // otherwise hang the Test-connection button forever.
      final resp = await client
          .send(req)
          .then(http.Response.fromStream)
          .timeout(deadline);
      if (resp.statusCode == 200) {
        // The server reports per-backend readiness — surface a chosen
        // backend whose plan key is missing NOW, at test time, instead of
        // as a 503 on tonight's dinner photo. `is`-checks, not casts: a
        // JSON-but-not-object body must not fall into the generic catch
        // and lie "could not reach" about a server that answered.
        final backend = settings.serverBackend;
        if (backend != 'claude') {
          Object? decoded;
          try {
            decoded = jsonDecode(resp.body);
          } on FormatException {
            return null; // non-JSON 200 (proxy page?) — nothing to infer
          }
          if (decoded is Map) {
            final backends = decoded['backends'];
            if (backends is Map) {
              final status = backends[backend]?.toString();
              if (status != null && status != 'ready') {
                return 'Server reachable, but its $backend backend is not '
                    'ready: $status.';
              }
            } else {
              // A real auth_check reply WITHOUT a backends map is the
              // pre-upgrade server — which ignores the backend field and
              // silently analyzes on the CLAUDE plan. The user chose a
              // different payer; say so here, not never.
              return 'Server reachable, but it predates backend selection '
                  '— update the server, or analyses will use the Claude '
                  'plan instead of $backend.';
            }
          }
        }
        return null;
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return 'Your server rejected that key.';
      }
      return 'Server answered HTTP ${resp.statusCode}.';
    } on TimeoutException {
      return 'Server did not respond (timeout).';
    } catch (e) {
      return 'Could not reach $base.';
    }
  }
}

/// The mainland-China providers, as [OpenAiCompatAnalyzer] configurations.
/// Endpoints are the providers' OpenAI-compatible chat-completions URLs —
/// mainland regions, reachable there without a VPN. Facts verified against
/// current provider docs 2026-07-29 (see the workflow research notes).
OpenAiCompatAnalyzer createQwenAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    OpenAiCompatAnalyzer(settings,
        // The MAINLAND (Beijing) platform. dashscope-intl (Singapore) is a
        // separate platform with separate keys — a mainland key gets 401
        // there. This app targets mainland users; intl users have the
        // other four providers.
        endpoint: Uri.parse(
            'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions'),
        label: 'Qwen',
        keyOf: (s) => s.qwenApiKey,
        modelOf: (s) => s.qwenModel,
        // json_object works on the stable qwen3-vl/qwen-vl IDs and needs
        // the word "json" in a message — both shared prompts say JSON.
        // qwen3-vl defaults to thinking OFF in compat mode: send nothing.
        notFoundHint: 'Qwen model not found — check the model name in '
            'Settings (stable IDs like qwen3-vl-flash; -latest snapshots '
            'lack JSON mode).',
        client: client);

OpenAiCompatAnalyzer createDoubaoAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    OpenAiCompatAnalyzer(settings,
        endpoint: Uri.parse(
            'https://ark.cn-beijing.volces.com/api/v3/chat/completions'),
        label: 'Doubao',
        keyOf: (s) => s.doubaoApiKey,
        modelOf: (s) => s.doubaoModel,
        // Seed models deep-think by default and bill the reasoning as
        // output tokens — pointless for a fixed-schema extraction.
        extraBody: const {
          'thinking': {'type': 'disabled'}
        },
        // Ark 404s both wrong ids AND not-yet-activated models; the
        // versioned-ID rule makes this the most common Doubao failure.
        notFoundHint: 'Doubao model not found — Ark needs the EXACT '
            'versioned ID from its model list, and the model must be '
            'activated (开通管理) in the Volcengine console.',
        client: client);

OpenAiCompatAnalyzer createGlmAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    OpenAiCompatAnalyzer(settings,
        endpoint: Uri.parse(
            'https://open.bigmodel.cn/api/paas/v4/chat/completions'),
        label: 'GLM',
        keyOf: (s) => s.glmApiKey,
        modelOf: (s) => s.glmModel,
        // Zhipu's reference marks response_format TEXT-models-only; a
        // vision call must not send it (prompt + fence-stripping parse
        // carry the JSON contract, same as Anthropic).
        supportsJsonMode: false,
        extraBody: const {
          'thinking': {'type': 'disabled'}
        },
        notFoundHint: 'GLM model not found — check the model name in '
            'Settings (glm-4.6v family; older glm-4v IDs are retired).',
        client: client);

/// The providers added 2026-09-30, as [OpenAiCompatAnalyzer]
/// configurations. Every endpoint, model id and parameter below was read
/// from the vendor's own documentation that day.
OpenAiCompatAnalyzer createDeepseekAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    OpenAiCompatAnalyzer(settings,
        endpoint: Uri.parse('https://api.deepseek.com/chat/completions'),
        label: 'DeepSeek',
        keyOf: (s) => s.deepseekApiKey,
        modelOf: (s) => s.deepseekModel,
        // response_format json_object is documented; thinking DEFAULTS to
        // enabled and bills the reasoning as output — pointless for a
        // fixed-schema extraction, so switch it off.
        extraBody: const {
          'thinking': {'type': 'disabled'}
        },
        notFoundHint: 'DeepSeek model not found — check the model name in '
            'Settings. Only deepseek-flash accepts photos; '
            'deepseek-v4-pro is text-only.',
        client: client);

OpenAiCompatAnalyzer createXaiAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    OpenAiCompatAnalyzer(settings,
        // xAI calls this endpoint "legacy" next to its Responses API, but
        // documents it as supported, with image_url data URLs.
        endpoint: Uri.parse('https://api.x.ai/v1/chat/completions'),
        label: 'xAI',
        keyOf: (s) => s.xaiApiKey,
        modelOf: (s) => s.xaiModel,
        // JSON mode on the image path is not documented: let the prompt
        // and the fence-stripping parser carry the contract (as for
        // Anthropic and GLM) rather than risk a 400 on every photo.
        supportsJsonMode: false,
        notFoundHint: 'xAI model not found — check the model name in '
            'Settings (for example grok-4.7).',
        client: client);

OpenAiCompatAnalyzer createOpenRouterAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    OpenAiCompatAnalyzer(settings,
        endpoint: Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        label: 'OpenRouter',
        keyOf: (s) => s.openrouterApiKey,
        modelOf: (s) => s.openrouterModel,
        // One key fronts hundreds of models with different parameter
        // support; json_object is not universal, so it is never sent.
        supportsJsonMode: false,
        // Optional attribution headers from OpenRouter's quickstart.
        extraHeaders: const {
          'HTTP-Referer': 'https://github.com/AkiyamaKunka/BiteWise',
          'X-OpenRouter-Title': 'BiteWise',
        },
        notFoundHint: 'OpenRouter model not found — use the full slug from '
            'openrouter.ai/models (vendor/model, for example '
            'google/gemini-3.8-flash) and pick one that accepts images.',
        client: client);

class MultiProviderAnalyzer implements AnalyzerService, TextIntentExplainer {
  MultiProviderAnalyzer(this._settings, {http.Client? client})
      : _gemini = createAnalyzer(_settings, client: client),
        _openai = OpenAiAnalyzer(_settings, client: client),
        _anthropic = AnthropicAnalyzer(_settings, client: client),
        _server = ServerAnalyzer(_settings, client: client),
        _qwen = createQwenAnalyzer(_settings, client: client),
        _doubao = createDoubaoAnalyzer(_settings, client: client),
        _glm = createGlmAnalyzer(_settings, client: client),
        _deepseek = createDeepseekAnalyzer(_settings, client: client),
        _xai = createXaiAnalyzer(_settings, client: client),
        _openrouter = createOpenRouterAnalyzer(_settings, client: client);

  final AppSettings _settings;
  final AnalyzerService _gemini;
  final OpenAiAnalyzer _openai;
  final AnthropicAnalyzer _anthropic;
  final ServerAnalyzer _server;
  final OpenAiCompatAnalyzer _qwen;
  final OpenAiCompatAnalyzer _doubao;
  final OpenAiCompatAnalyzer _glm;
  final OpenAiCompatAnalyzer _deepseek;
  final OpenAiCompatAnalyzer _xai;
  final OpenAiCompatAnalyzer _openrouter;

  AnalyzerService get _active => switch (_settings.provider) {
        AiProvider.gemini => _gemini,
        AiProvider.openai => _openai,
        AiProvider.anthropic => _anthropic,
        AiProvider.server => _server,
        AiProvider.qwen => _qwen,
        AiProvider.doubao => _doubao,
        AiProvider.glm => _glm,
        AiProvider.deepseek => _deepseek,
        AiProvider.xai => _xai,
        AiProvider.openrouter => _openrouter,
      };

  /// Phone-side credential check BEFORE any transport. Without it a
  /// key-less Gemini call still went out and came back as "rejected the
  /// API key" — the wrong remedy for a user who simply has not set one up
  /// (and, for a subscription user, the wrong provider name entirely) —
  /// seen on a fresh simulator 2026-09-28. Retryable: user state, not a
  /// photo defect, so automated intake keeps the photo eligible.
  AnalysisOutcome? _missingCredential() {
    if ((_settings.activeApiKey ?? '').trim().isNotEmpty) return null;
    final msg = _settings.provider == AiProvider.server
        ? 'No server address or upload key is set — add them in Settings.'
        : 'No ${_settings.providerDisplayName} API key — add one in '
            'Settings.';
    return AnalysisOutcome(error: msg, retryable: true, wall: Duration.zero);
  }

  @override
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals}) async {
    final missing = _missingCredential();
    if (missing != null) return missing;
    return _active.analyzePhoto(originalBytes, recentMeals: recentMeals);
  }

  @override
  Future<Map<String, dynamic>?> textIntent(String prompt) =>
      _active.textIntent(prompt);

  /// Forwarded, or the executor would only ever see the reason-less
  /// fallback and keep telling a rejected key to "retry".
  @override
  Future<TextIntentOutcome> textIntentOutcome(String prompt) =>
      askTextIntent(_active, prompt);

  @override
  Future<Map<String, dynamic>?> leftoverIntent(
          Uint8List originalBytes, String originalCompact) =>
      _active.leftoverIntent(originalBytes, originalCompact);

  @override
  Future<String?> validateKey(String apiKey) => _active.validateKey(apiKey);

  @override
  Future<KeyProbe> probeKey(String apiKey) => _active.probeKey(apiKey);
}

/// Integration seam for di.dart — replaces the direct Gemini factory.
AnalyzerService createMultiProviderAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    MultiProviderAnalyzer(settings, client: client);
