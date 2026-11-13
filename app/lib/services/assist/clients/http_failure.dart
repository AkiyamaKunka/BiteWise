/// HTTP failure classification for the lookup clients, in the same order
/// as `_HttpVisionAnalyzer._throwHttpFailure` in
/// services/analyzer/provider_analyzers.dart, and the reply rules both of
/// them read: what a status and body say about billing, the region, the
/// key and the model is written once, below, so a new vendor signature is
/// added in one place. Each ladder keeps its own order, outcomes and
/// messages; test/assist/clients/http_failure_test.dart pins both (the
/// group 'parity with the photo analyzers (probeKey)' runs one status/body
/// matrix through both, and 'every rule of both ladders' each one's whole
/// answer).
library;

import 'dart:convert';

import 'lookup_client.dart';

/// The key authenticated but the account cannot pay. The providers
/// disagree on the status code: OpenAI 429 insufficient_quota, Zhipu GLM
/// 429 code "1113" (余额不足, not a rate limit), Ark/Doubao 403
/// AccountOverdueError (not an auth failure), 402 Payment Required
/// (DeepSeek "Insufficient Balance", OpenRouter's out-of-credits answer),
/// DashScope 400 Arrearage and Anthropic 400 "credit balance is too low"
/// (not client bugs).
bool isBillingExhausted(int status, String body) =>
    (status == 429 &&
        (body.contains('insufficient_quota') || body.contains('"1113"'))) ||
    (status == 403 && body.contains('AccountOverdue')) ||
    status == 402 ||
    (status == 400 &&
        (body.contains('Arrearage') ||
            body.contains('credit balance is too low')));

/// The provider does not serve the network's region (OpenAI's documented
/// code `unsupported_country_region_territory`, at any status): the key was
/// never judged.
bool isRegionBlocked(String body) =>
    body.contains('unsupported_country_region_territory');

/// [body] decodes as a JSON object, as every provider's (and the owner's
/// server's) error reply does.
bool isJsonObjectBody(String body) {
  try {
    return jsonDecode(body) is Map;
  } on FormatException {
    return false;
  }
}

/// The provider rejected the key: a 401 or 403, or xAI's HTTP 400
/// "Incorrect API key provided".
bool isKeyRejected(int status, String body) =>
    status == 401 ||
    status == 403 ||
    (status == 400 && body.contains('Incorrect API key'));

/// Zhipu GLM's code "1211" (模型不存在): a wrong or retired model id, which
/// it answers as a 400. Matched on the documented code only.
bool isModelMissingCode(String body) => body.contains('"1211"');

/// A non-200 answer from [providerLabel], classified.
LookupFailure classifyHttpFailure(int status, String body,
    {required String providerLabel}) {
  // Exhausted billing first: the providers disagree on the status code.
  // The key authenticated; the account cannot pay. Transient: a recharge
  // fixes it.
  if (isBillingExhausted(status, body)) {
    return LookupFailure(LookupFailureCode.billing,
        transient: true,
        message: 'Provider balance or credits exhausted — check your '
            '$providerLabel billing.');
  }
  if (isRegionBlocked(body)) {
    return LookupFailure(LookupFailureCode.regionBlocked,
        transient: true,
        message: '$providerLabel is not available from your current network '
            'region (check the VPN).');
  }
  // A non-JSON 401/403 is a portal or proxy answering for the provider:
  // the key was never judged.
  if ((status == 401 || status == 403) && !isJsonObjectBody(body)) {
    return LookupFailure(LookupFailureCode.captivePortal,
        transient: true,
        message: 'HTTP $status non-JSON reply (captive portal or proxy page)');
  }
  if (isKeyRejected(status, body)) {
    return const LookupFailure(LookupFailureCode.auth,
        transient: false, message: 'key rejected');
  }
  // Every direct provider has one fixed endpoint, so a 404 is the MODEL.
  if (status == 404) {
    return LookupFailure(LookupFailureCode.modelNotFound,
        transient: false,
        message: '$providerLabel model not found (unknown or retired).');
  }
  if (status >= 300 && status < 400) {
    return LookupFailure(LookupFailureCode.captivePortal,
        transient: true,
        message: 'HTTP $status redirect (captive portal or proxy)');
  }
  if (status == 429) {
    return const LookupFailure(LookupFailureCode.rateLimited,
        transient: true, message: 'HTTP 429');
  }
  if (status == 529 || (status >= 500 && status < 600)) {
    return LookupFailure(LookupFailureCode.server,
        transient: true, message: 'HTTP $status');
  }
  if (status == 400) {
    // Anthropic answers a request carrying the web search tool with a 400
    // invalid_request_error when an org admin disabled web search in the
    // Console. Permanent until the admin changes it — not a client bug.
    final lower = body.toLowerCase();
    if (lower.contains('web search') && lower.contains('not enabled')) {
      return LookupFailure(LookupFailureCode.searchDisabled,
          transient: false,
          message: 'Web search is disabled for this $providerLabel '
              'organization.');
    }
    if (isModelMissingCode(body)) {
      return LookupFailure(LookupFailureCode.modelNotFound,
          transient: false,
          message: '$providerLabel model not found (unknown or retired).');
    }
  }
  return LookupFailure(LookupFailureCode.badRequest,
      transient: false, message: 'HTTP $status');
}

/// A failure reported INSIDE a 200 reply as `{"error": {"code": <http
/// status>, "message": …}}` (OpenRouter relays upstream failures this way),
/// classified as if it had arrived with that status.
LookupFailure classifyHttpFailureFromErrorObject(int status, Map error,
        {String providerLabel = 'OpenRouter'}) =>
    classifyHttpFailure(status, jsonEncode({'error': error}),
        providerLabel: providerLabel);

/// The outcome kind a failure maps to: rate limits, daily caps and a
/// transient search-level error (Anthropic's `too_many_requests` /
/// `unavailable`: busy for a moment, try later) are
/// [LookupOutcomeKind.rateLimited]; transport trouble (no network, a portal
/// or proxy answering) is [LookupOutcomeKind.offline]; a provider that is
/// no longer the one the user consented to is
/// [LookupOutcomeKind.unsupported]; everything else is
/// [LookupOutcomeKind.failed].
LookupOutcomeKind outcomeKindFor(LookupFailure f) => switch (f.code) {
      LookupFailureCode.rateLimited ||
      LookupFailureCode.dailyCap =>
        LookupOutcomeKind.rateLimited,
      LookupFailureCode.searchError when f.transient =>
        LookupOutcomeKind.rateLimited,
      LookupFailureCode.network ||
      LookupFailureCode.captivePortal =>
        LookupOutcomeKind.offline,
      LookupFailureCode.consentChanged => LookupOutcomeKind.unsupported,
      _ => LookupOutcomeKind.failed,
    };
