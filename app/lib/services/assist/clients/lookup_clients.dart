/// Which lookup client serves which provider, read per call (switching
/// providers in Settings takes effect on the next lookup, as for photos).
///
/// v1 coverage (design D18 + L2):
///   anthropic  → AnthropicLookupClient (fixed claude-haiku-5-5)
///   openrouter → OpenRouterLookupClient (user's model, Exa pinned)
///   openai     → OpenAiLookupClient   ┐ built and tested, but unsupported
///   xai        → XaiLookupClient      ┘ until the owner signs off on cost
///   server     → R5a's job client (passed in), unsupported without it
///   gemini     → unsupported until L1 (Search Suggestions + no cache)
///   qwen, doubao, glm, deepseek → unsupported: no citable US search
/// Unsupported providers make zero HTTP calls.
library;

import 'package:http/http.dart' as http;

import '../../settings/app_settings.dart';
import 'anthropic_lookup_client.dart';
import 'lookup_client.dart';
import 'lookup_contract_adapter.dart';
import 'lookup_cost.dart';
import 'openrouter_lookup_client.dart';
import 'responses_lookup_client.dart';

class ProviderLookupRouter implements LookupClient {
  ProviderLookupRouter(
    this._settings, {
    http.Client? client,
    LookupBudget? budget,
    LookupCostPolicy policy = const LookupCostPolicy(),
    this.enableResponsesProviders = false,
    LookupClient? serverClient,
    Duration perCallDeadline = const Duration(seconds: 45),
  })  : _server = serverClient ??
            const UnsupportedLookupClient(LookupUnsupportedReason.serverJobs),
        _anthropic = AnthropicLookupClient(
            apiKey: () => _settings.anthropicApiKey,
            client: client,
            budget: budget,
            policy: policy,
            perCallDeadline: perCallDeadline),
        _openrouter = OpenRouterLookupClient(
            apiKey: () => _settings.openrouterApiKey,
            modelOf: () => _settings.openrouterModel,
            client: client,
            budget: budget,
            policy: policy,
            perCallDeadline: perCallDeadline),
        _openai = OpenAiLookupClient(
            apiKey: () => _settings.openaiApiKey,
            client: client,
            budget: budget,
            policy: policy,
            perCallDeadline: perCallDeadline),
        _xai = XaiLookupClient(
            apiKey: () => _settings.xaiApiKey,
            modelOf: () => _settings.xaiModel,
            client: client,
            budget: budget,
            policy: policy,
            perCallDeadline: perCallDeadline);

  final AppSettings _settings;

  /// Design L2: OpenAI and xAI lookups cost per call and need the owner's
  /// sign-off; until then they answer unsupported with zero calls.
  final bool enableResponsesProviders;

  final LookupClient _server;
  final AnthropicLookupClient _anthropic;
  final OpenRouterLookupClient _openrouter;
  final OpenAiLookupClient _openai;
  final XaiLookupClient _xai;

  static const LookupClient _noSearch =
      UnsupportedLookupClient(LookupUnsupportedReason.noSearchTool);
  static const LookupClient _gemini =
      UnsupportedLookupClient(LookupUnsupportedReason.needsL1);
  static const LookupClient _awaitingSignoff =
      UnsupportedLookupClient(LookupUnsupportedReason.awaitingCostSignoff);

  /// The client for the provider selected right now.
  LookupClient get active => switch (_settings.provider) {
        AiProvider.anthropic => _anthropic,
        AiProvider.openrouter => _openrouter,
        AiProvider.openai =>
          enableResponsesProviders ? _openai : _awaitingSignoff,
        AiProvider.xai => enableResponsesProviders ? _xai : _awaitingSignoff,
        AiProvider.server => _server,
        AiProvider.gemini => _gemini,
        AiProvider.qwen ||
        AiProvider.doubao ||
        AiProvider.glm ||
        AiProvider.deepseek =>
          _noSearch,
      };

  @override
  LookupSupport lookupSupport() => active.lookupSupport();

  @override
  Future<LookupOutcome> submit(LookupRequest request,
          {List<String> chainDomains = const [],
          LookupCancelToken? cancel}) =>
      active.submit(request, chainDomains: chainDomains, cancel: cancel);

  @override
  Future<LookupOutcome> poll(String jobId) => active.poll(jobId);
}
