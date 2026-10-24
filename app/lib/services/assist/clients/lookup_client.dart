/// The direct-provider restaurant lookup interface (design R5b + L2).
///
/// Method names and outcome kinds follow data_contracts §7
/// (`RestaurantLookup {lookupSupport(); submit(LookupRequest);
/// poll(jobId)}`, `LookupOutcome{kind, jobId, result, citedUrls, evidence,
/// provider, searches}`), so R5a's `RestaurantLookup` in core/contracts.dart
/// can be implemented by these clients as they are. Direct clients are
/// synchronous: [LookupClient.submit] answers done or a failure, never
/// pending, and [LookupClient.poll] is unsupported.
library;

import 'dart:async';

import 'lookup_contract_adapter.dart';

/// Who receives the lookup request (the consent recipient, design D13).
enum LookupRecipient {
  claudePlan('claude_plan'),
  anthropic('anthropic'),
  openrouter('openrouter'),
  openai('openai'),
  xai('xai'),
  none('none');

  const LookupRecipient(this.wire);

  /// The `analysis.assist.provider` value.
  final String wire;
}

/// Why a provider makes zero lookup calls.
abstract final class LookupUnsupportedReason {
  /// The provider has no web search that returns citable URLs for US
  /// restaurant pages (DeepSeek, Qwen, GLM, Doubao — research 2026-10).
  static const String noSearchTool = 'no_search_tool';

  /// Gemini: google_search grounding needs the Search Suggestions UI and a
  /// no-cache path (design L1), not built yet.
  static const String needsL1 = 'needs_l1_gemini_grounding';

  /// The owner's server answers lookups as async jobs (R5a), not here.
  static const String serverJobs = 'server_jobs_r5a';

  /// OpenAI / xAI clients exist but stay off until the owner signs off on
  /// their per-call cost (design L2).
  static const String awaitingCostSignoff = 'awaiting_owner_cost_signoff';
}

class LookupSupport {
  const LookupSupport({
    required this.supported,
    required this.recipient,
    required this.locationAllowed,
    this.reason,
  });

  const LookupSupport.unsupported(String this.reason)
      : supported = false,
        recipient = LookupRecipient.none,
        locationAllowed = false;

  final bool supported;
  final LookupRecipient recipient;

  /// Whether location-derived chains may be in the request. A direct
  /// provider is reached over https from the phone, so the client allows
  /// it; consent and the iOS-only location path are the caller's gates.
  final bool locationAllowed;
  final String? reason;
}

/// data_contracts §7 kinds. Direct clients use done, unsupported,
/// rateLimited, failed and offline.
enum LookupOutcomeKind {
  done,
  pending,
  busy,
  unsupported,
  serverOutdated,
  disabled,
  rateLimited,
  failed,
  offline,
}

/// Why a lookup failed, classified like the photo analyzers classify the
/// same HTTP answers (see http_failure.dart).
enum LookupFailureCode {
  noKey,
  auth,
  billing,
  rateLimited,
  regionBlocked,
  captivePortal,
  modelNotFound,
  badRequest,
  searchDisabled,
  server,
  timeout,
  network,
  malformedReply,
  searchError,
  refused,
  truncated,
  costCap,
  dailyCap,
  cancelled,

  /// The caller's consent names a different recipient than the one the
  /// lookup would go to now (the provider changed in Settings between the
  /// consent check and the send). Nothing was sent.
  consentChanged,
}

class LookupFailure {
  const LookupFailure(this.code, {required this.transient, this.message = ''});
  final LookupFailureCode code;

  /// True when the same lookup may succeed later without the user changing
  /// anything (network, rate limit, server error). The caller decides
  /// whether and when to retry; clients never retry in place, because an
  /// abandoned search call is still billed.
  final bool transient;

  /// English diagnostics line. Never contains a key or a response body.
  final String message;

  @override
  String toString() => 'LookupFailure(${code.name}, transient: $transient'
      '${message.isEmpty ? '' : ', $message'})';
}

/// One piece of grounding text for one URL.
class LookupEvidence {
  const LookupEvidence({
    required this.url,
    required this.text,
    required this.verbatim,
    this.pageAge,
    this.title,
  });

  final String url;
  final String text;

  /// True when [text] was extracted FROM THE PAGE by the provider's search
  /// system (Anthropic `cited_text`, OpenRouter/Exa `content`). False when
  /// it is a span of the model's own answer that the provider attributes
  /// to the URL (OpenAI / xAI url_citation indices): that is the model's
  /// claim, not the source's text, and must never satisfy an APPLY
  /// grounding check.
  final bool verbatim;
  final String? pageAge;
  final String? title;
}

/// What one lookup cost (or is estimated to have cost).
class LookupCost {
  const LookupCost({
    this.searches = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.httpCalls = 0,
    this.estimatedUsd = 0,
    this.reportedUsd,
  });

  static const LookupCost zero = LookupCost();

  final int searches;
  final int inputTokens;
  final int outputTokens;
  final int httpCalls;

  /// From our price table (lookup_cost.dart). A request that was sent but
  /// never answered (timeout, cancel, dropped connection, a non-JSON reply)
  /// is charged its WORST case here: it may have run, and been billed for,
  /// its searches.
  final double estimatedUsd;

  /// From the provider's own usage report when it gives one (OpenRouter
  /// `usage.cost`, xAI `usage.cost_in_usd_ticks`).
  final double? reportedUsd;

  double get usd => reportedUsd ?? estimatedUsd;

  LookupCost operator +(LookupCost o) => LookupCost(
        searches: searches + o.searches,
        inputTokens: inputTokens + o.inputTokens,
        outputTokens: outputTokens + o.outputTokens,
        httpCalls: httpCalls + o.httpCalls,
        estimatedUsd: estimatedUsd + o.estimatedUsd,
        reportedUsd: reportedUsd == null && o.reportedUsd == null
            ? null
            : (reportedUsd ?? 0) + (o.reportedUsd ?? 0),
      );

  @override
  String toString() => 'LookupCost(searches: $searches, in: $inputTokens, '
      'out: $outputTokens, calls: $httpCalls, '
      'usd: ${usd.toStringAsFixed(5)})';
}

/// Cancels an in-flight lookup (Settings → Off). The HTTP request is
/// aborted where the client supports it and the result is discarded.
class LookupCancelToken {
  final Completer<void> _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

class LookupOutcome {
  const LookupOutcome({
    required this.kind,
    required this.provider,
    this.jobId,
    this.result,
    this.citedUrls = const [],
    this.evidence = const [],
    this.searches = 0,
    this.cost = LookupCost.zero,
    this.failure,
    this.model = '',
    this.rawText,
    this.raw,
  });

  factory LookupOutcome.unsupported(String reason) => LookupOutcome(
        kind: LookupOutcomeKind.unsupported,
        provider: LookupRecipient.none,
        failure: LookupFailure(LookupFailureCode.badRequest,
            transient: false, message: reason),
      );

  /// Nothing sent: the caller consented to [expected] (or named no one),
  /// and the lookup would go to [actual]. Permanent until the user answers
  /// the consent sheet for [actual].
  factory LookupOutcome.consentChanged(
          LookupRecipient? expected, LookupRecipient actual) =>
      LookupOutcome(
        kind: LookupOutcomeKind.unsupported,
        provider: LookupRecipient.none,
        failure: LookupFailure(LookupFailureCode.consentChanged,
            transient: false,
            message: expected == null
                ? 'no consented recipient named; provider is ${actual.wire}'
                : 'consent covers ${expected.wire}; provider is now '
                    '${actual.wire}'),
      );

  final LookupOutcomeKind kind;
  final LookupRecipient provider;
  final String? jobId;

  /// Present only for [LookupOutcomeKind.done].
  final LookupResult? result;

  /// Every URL the provider's SEARCH returned, as sent — normalize before
  /// comparing: Anthropic `web_search_result`s, OpenAI
  /// `action.sources`, xAI's top-level `citations`, OpenRouter annotations
  /// that carry Exa `content`. Never a URL that only the model's own answer
  /// names (an inline marker, a markdown link, a bare annotation): the
  /// model can invent those.
  final List<String> citedUrls;
  final List<LookupEvidence> evidence;
  final int searches;
  final LookupCost cost;
  final LookupFailure? failure;

  /// The model id that answered (fixed per provider for lookups, or the
  /// user's own for OpenRouter / xAI).
  final String model;

  /// The model's final answer text (diagnostics).
  final String? rawText;

  /// The provider's last decoded reply, with opaque encrypted fields
  /// removed (diagnostics; never contains a key — keys are only headers).
  final Map<String, dynamic>? raw;

  bool get isDone => kind == LookupOutcomeKind.done && result != null;

  /// Every [evidence] text for [url] (exact string match after the
  /// caller's normalization is the caller's business; this is raw).
  Iterable<LookupEvidence> evidenceFor(String url) =>
      evidence.where((e) => e.url == url);
}

/// The client interface (data_contracts §7, direct-provider subset).
abstract class LookupClient {
  LookupSupport lookupSupport();

  /// One lookup. [chainDomains] are the matched chains' OFFICIAL domains
  /// from our chain table: when given, the provider's search is restricted
  /// to them (and they are what the source check calls official). They are
  /// derived from the same chains the request already names, so they add
  /// nothing to what the provider learns.
  ///
  /// [expectedRecipient] is the recipient the caller's consent covers (the
  /// `lookupSupport().recipient` it checked). When it is not who this
  /// client would send to, the outcome is [LookupFailureCode.consentChanged]
  /// with zero HTTP calls. A direct client's recipient is fixed, so for it
  /// the argument is a cross-check; `ProviderLookupRouter` follows Settings
  /// and REQUIRES it (a null is refused the same way), because the provider
  /// can change between the consent check and the send. Claude Plan's
  /// consent also names the server host; binding that is the server job
  /// client's job (R5a).
  Future<LookupOutcome> submit(LookupRequest request,
      {List<String> chainDomains = const [],
      LookupCancelToken? cancel,
      LookupRecipient? expectedRecipient});

  /// Async jobs exist only on the owner's server (R5a).
  Future<LookupOutcome> poll(String jobId);
}

/// A provider without a usable search tool: zero HTTP calls, ever.
class UnsupportedLookupClient implements LookupClient {
  const UnsupportedLookupClient(this.reason);
  final String reason;

  @override
  LookupSupport lookupSupport() => LookupSupport.unsupported(reason);

  @override
  Future<LookupOutcome> submit(LookupRequest request,
          {List<String> chainDomains = const [],
          LookupCancelToken? cancel,
          LookupRecipient? expectedRecipient}) async =>
      LookupOutcome.unsupported(reason);

  @override
  Future<LookupOutcome> poll(String jobId) async =>
      LookupOutcome.unsupported(reason);
}
