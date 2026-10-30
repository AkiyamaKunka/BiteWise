part of 'provider_analyzers.dart';

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

  /// One fixed endpoint, so a 404 is the MODEL (`model_not_found`): a typed
  /// id persists across upgrades and OpenAI retires ids. The generic
  /// 'HTTP 404' classified as unknown, so the Chinese UI showed the raw
  /// English line with no pointer at Settings (loop find 2026-10-10).
  @override
  String? get notFoundMessage =>
      'OpenAI model "$model" not found (unknown or retired) — check the '
      'model name in Settings.';

  @override
  http.Request buildRequest(String key,
      {required String prompt, Uint8List? jpegBytes, required int maxTokens}) {
    final content = _chatContent(prompt, jpegBytes);
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
  String extractText(Map<String, dynamic> body) => _chatReplyText(body);
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
    final content = _chatContent(prompt, jpegBytes);
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
  String extractText(Map<String, dynamic> body) => _chatReplyText(body);
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

  /// One fixed endpoint, so a 404 is the MODEL (`not_found_error`
  /// "model: …"): claude-3-5-sonnet-* and claude-3-opus answer this today.
  /// Same gap as OpenAI above (loop find 2026-10-10).
  @override
  String? get notFoundMessage =>
      'Anthropic model "$model" not found (unknown or retired) — check the '
      'model name in Settings.';

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
          'X-OpenRouter-Title': 'Chopstats',
        },
        notFoundHint: 'OpenRouter model not found — use the full slug from '
            'openrouter.ai/models (vendor/model, for example '
            'google/gemini-3.8-flash) and pick one that accepts images.',
        client: client);
