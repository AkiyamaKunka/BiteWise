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

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:http/http.dart' as http;

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import '../../core/leftover_logic.dart' show formatRecentMealsBlock;
import '../../core/prompts.dart';
import '../assist/clients/lookup_client.dart';
import '../assist/clients/lookup_clients.dart';
import '../assist/clients/lookup_contract_adapter.dart' show LookupRequest;
import '../assist/clients/lookup_cost.dart' show LookupBudget;
import '../assist/clients/server_lookup_client.dart';
import '../settings/app_settings.dart';
import 'gemini_analyzer.dart' show createAnalyzer;
import 'platform_decode.dart';

part 'openai_style_analyzers.dart';
part 'server_analyzer.dart';

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

  /// Whether this provider appends the reply-language directive to the
  /// prompt itself. ServerAnalyzer does not: it sends `lang` and the
  /// server appends the same directive (no doubled sentence).
  bool get appendsReplyLanguage => true;

  /// [prompt] with the reply-language directive when the app is Chinese
  /// (photo and text-intent prompts only — never the leftover prompt).
  String _withReplyLanguage(String prompt) => appendsReplyLanguage
      ? withReplyLanguage(prompt, chinese: settings.repliesInChinese)
      : prompt;

  http.Request buildRequest(String key,
      {required String prompt, Uint8List? jpegBytes, required int maxTokens});
  String extractText(Map<String, dynamic> body);

  /// One POST. Returns the reply text; throws [_ProviderException] with a
  /// transient/permanent classification otherwise. [extract] false skips
  /// text extraction entirely (validateKey: an HTTP 200 proves the key
  /// regardless of reply shape — a 1-token reply may contain no text
  /// block at all, same rule as Gemini's MAX_TOKENS case). The body must
  /// still be JSON: a non-JSON 200 did not come from the provider.
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
      // A region refusal, checked BEFORE the auth branch for the same
      // reason as billing: OpenAI answers a Hong Kong VPN exit with a 403
      // whose error code is `unsupported_country_region_territory`, and
      // "key rejected" sent the user — every ten minutes — to fix a key
      // that works. Matched on the documented code only. Retryable (a
      // different VPN node fixes it) but never in place.
      if (body.contains('unsupported_country_region_territory')) {
        throw _ProviderException(
            '$providerLabel is not available from your current network '
            'region (check the VPN).',
            transient: true,
            retryInPlace: false,
            regionBlocked: true,
            verbatimMessage: true);
      }
      // Every provider — and the owner's server ({"error":"Unauthorized"})
      // — answers its 401/403 as JSON. An HTML or text 401/403 is a web
      // filter or captive portal answering in its place (the server is
      // plain HTTP): the key was never judged, so it is the same
      // interception as the 3xx below — never 'key rejected', which parks
      // the automatic scan for a day (review 2026-10-12).
      if ((resp.statusCode == 401 || resp.statusCode == 403) &&
          !_isJsonObject(body)) {
        throw _ProviderException(
            'HTTP ${resp.statusCode} non-JSON reply (captive portal or proxy '
            'page)',
            transient: true,
            retryInPlace: false);
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
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        // No provider redirects a POST: a 3xx is a captive portal (hotel /
        // airport / campus Wi-Fi before sign-in) or a proxy answering
        // INSTEAD of the provider. The owner's server is plain HTTP on
        // port 80 — exactly what portals intercept — and the permanent
        // 'HTTP 302' this used to throw tombstoned every backlog photo
        // scanned before the Wi-Fi login, which the automatic scan never
        // reclaims (loop find 2026-10-10). Transient, so the photo stays
        // eligible; NOT retryInPlace — a login page does not change in
        // 15 s, and the sleeps would eat the iOS background-refresh budget
        // on the first photo. dart:io follows only a POST 303 (as a GET),
        // whose HTML 200 is the non-JSON case below.
        throw _ProviderException(
            'HTTP ${resp.statusCode} redirect (captive portal or proxy)',
            transient: true,
            retryInPlace: false);
      }
      throw _ProviderException('HTTP ${resp.statusCode}',
          transient: _isTransientStatus(resp.statusCode),
          quotaClass: resp.statusCode == 429,
          // Every direct provider now explains its 404 via notFoundMessage
          // above; a bare 404 reaches here only from ServerAnalyzer (a
          // wrong server path), which overrides probeKey, the only reader
          // of this flag.
          modelError: resp.statusCode == 404);
    }
    // A 200 whose body is not JSON never came from the provider — every
    // vendor answers JSON, and so does the owner's server. It is the same
    // interception as the 3xx above (a portal's login page, a proxy's
    // error page), classified the same way. Decoded even for
    // extract:false, or validateKey / probeKey would take a portal page
    // as proof of a key. 'unexpected response shape' stays PERMANENT, but
    // only for JSON that lacks the expected keys: that is app/server
    // version drift, and a retry would re-spend a model call (a full CLI
    // run, for the server) for the same answer.
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } on FormatException {
      throw const _ProviderException(
          'non-JSON reply (captive portal or proxy page)',
          transient: true,
          retryInPlace: false);
    }
    if (!extract) return '';
    try {
      return extractText(decoded as Map<String, dynamic>);
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
    // Reply language LAST, after the profile and the recent-meals block —
    // the server's order (telegram_bot.py analyze_photo).
    final prompt = _withReplyLanguage(
        withDietaryProfile(foodDetectionPrompt, settings.dietaryProfile) +
            formatRecentMealsBlock(recentMeals ?? const []));
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
    final sent = _withReplyLanguage(prompt);
    for (var attempt = 1;; attempt++) {
      try {
        text = await _post(prompt: sent);
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
      // The key was never judged: a different VPN node is the fix.
      if (e.regionBlocked) {
        return KeyProbe(KeyProbeResult.regionBlocked, message: e.userMessage);
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

/// True when [body] decodes as a JSON object — what every provider's (and
/// the owner's server's) error reply is.
bool _isJsonObject(String body) {
  try {
    return jsonDecode(body) is Map;
  } on FormatException {
    return false;
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
      this.regionBlocked = false,
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

  /// The provider does not serve the network's region (OpenAI's
  /// `unsupported_country_region_territory`): the key was never judged.
  final bool regionBlocked;

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

/// The user message's content parts for an OpenAI-style chat-completions
/// call: the prompt text, then the photo as a base64 JPEG data URL.
List<Map<String, Object?>> _chatContent(String prompt, Uint8List? jpegBytes) =>
    <Map<String, Object?>>[
      {'type': 'text', 'text': prompt},
      if (jpegBytes != null)
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/jpeg;base64,${base64Encode(jpegBytes)}'
          }
        },
    ];

/// The reply text of an OpenAI-style chat-completions response
/// (`choices[0].message.content`).
String _chatReplyText(Map<String, dynamic> body) =>
    ((body['choices'] as List).first as Map)['message']['content'] as String;

/// Per-call delegation on [AppSettings.provider]: switching providers in
/// Settings takes effect on the NEXT request — no DI rewiring, no restart.
///
/// Also the restaurant lookup seam (design R5a): [LookupClient] calls go to
/// the active provider's lookup client through one [ProviderLookupRouter]
/// (the owner's server through [ServerLookupClient]; providers without a
/// lookup answer unsupported with zero HTTP calls), and [analyzerBusy]
/// counts the foreground analyzer calls a lookup must wait for.
class MultiProviderAnalyzer
    implements AnalyzerService, TextIntentExplainer, LookupClient {
  MultiProviderAnalyzer(this._settings,
      {http.Client? client, this.lookupBudget})
      : _client = client,
        _gemini = createAnalyzer(_settings, client: client),
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
  final http.Client? _client;

  /// The app's daily lookup ledger (design: 20 a day), shared by every
  /// provider's lookup client; null = no daily limit here.
  final LookupBudget? lookupBudget;
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

  final ValueNotifier<int> _busy = ValueNotifier<int>(0);

  /// Analyzer calls in flight on this instance: photos, leftover photos and
  /// text intents (the chat, fix and describe-a-meal paths all ask
  /// through textIntent / textIntentOutcome). Design D7: the restaurant
  /// assist starts a lookup only while this is 0, so a lookup never
  /// competes with the user's own request. Raised before the call and
  /// lowered in `finally`: a failure or a throw cannot leave it up. Key
  /// checks (validateKey, probeKey) are not counted.
  ValueListenable<int> get analyzerBusy => _busy;

  Future<T> _counted<T>(Future<T> Function() call) async {
    _busy.value++;
    try {
      return await call();
    } finally {
      _busy.value--;
    }
  }

  @override
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals}) async {
    final missing = _missingCredential();
    if (missing != null) return missing;
    return _counted(
        () => _active.analyzePhoto(originalBytes, recentMeals: recentMeals));
  }

  @override
  Future<Map<String, dynamic>?> textIntent(String prompt) =>
      _counted(() => _active.textIntent(prompt));

  /// Forwarded, or the executor would only ever see the reason-less
  /// fallback and keep telling a rejected key to "retry".
  @override
  Future<TextIntentOutcome> textIntentOutcome(String prompt) =>
      _counted(() => askTextIntent(_active, prompt));

  @override
  Future<Map<String, dynamic>?> leftoverIntent(
          Uint8List originalBytes, String originalCompact) =>
      _counted(() => _active.leftoverIntent(originalBytes, originalCompact));

  @override
  Future<String?> validateKey(String apiKey) => _active.validateKey(apiKey);

  @override
  Future<KeyProbe> probeKey(String apiKey) => _active.probeKey(apiKey);

  /// Built on first use: the background engine's instance never looks up.
  late final ProviderLookupRouter _lookups = ProviderLookupRouter(_settings,
      client: _client,
      budget: lookupBudget,
      serverClient:
          ServerLookupClient(_settings, client: _client, budget: lookupBudget));

  @override
  LookupSupport lookupSupport() => _lookups.lookupSupport();

  @override
  Future<LookupOutcome> submit(LookupRequest request,
          {List<String> chainDomains = const [],
          LookupCancelToken? cancel,
          LookupRecipient? expectedRecipient,
          String? expectedRecipientStamp}) =>
      _lookups.submit(request,
          chainDomains: chainDomains,
          cancel: cancel,
          expectedRecipient: expectedRecipient,
          expectedRecipientStamp: expectedRecipientStamp);

  @override
  Future<LookupOutcome> poll(String jobId) => _lookups.poll(jobId);
}

/// Integration seam for di.dart — replaces the direct Gemini factory.
AnalyzerService createMultiProviderAnalyzer(AppSettings settings,
        {http.Client? client}) =>
    MultiProviderAnalyzer(settings, client: client);
