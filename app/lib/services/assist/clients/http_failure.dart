/// HTTP failure classification for the lookup clients — the SAME rules, in
/// the same order, as `_HttpVisionAnalyzer._post` in
/// services/analyzer/provider_analyzers.dart (that class is library-private,
/// so the rules are mirrored here and pinned to it by
/// test/assist/clients/http_failure_parity_test.dart, which runs one
/// status/body matrix through both).
library;

import 'dart:convert';

import 'lookup_client.dart';

bool _isJsonObject(String body) {
  try {
    return jsonDecode(body) is Map;
  } on FormatException {
    return false;
  }
}

/// A non-200 answer from [providerLabel], classified.
LookupFailure classifyHttpFailure(int status, String body,
    {required String providerLabel}) {
  // Exhausted billing first: the providers disagree on the status code
  // (OpenAI 429 insufficient_quota, DeepSeek/OpenRouter 402, Anthropic 400
  // "credit balance is too low"). The key authenticated; the account
  // cannot pay. Transient: a recharge fixes it.
  final billingDead =
      (status == 429 &&
              (body.contains('insufficient_quota') ||
                  body.contains('"1113"'))) ||
          (status == 403 && body.contains('AccountOverdue')) ||
          status == 402 ||
          (status == 400 &&
              (body.contains('Arrearage') ||
                  body.contains('credit balance is too low')));
  if (billingDead) {
    return LookupFailure(LookupFailureCode.billing,
        transient: true,
        message: 'Provider balance or credits exhausted — check your '
            '$providerLabel billing.');
  }
  if (body.contains('unsupported_country_region_territory')) {
    return LookupFailure(LookupFailureCode.regionBlocked,
        transient: true,
        message: '$providerLabel is not available from your current network '
            'region (check the VPN).');
  }
  // A non-JSON 401/403 is a portal or proxy answering for the provider:
  // the key was never judged.
  if ((status == 401 || status == 403) && !_isJsonObject(body)) {
    return LookupFailure(LookupFailureCode.captivePortal,
        transient: true,
        message: 'HTTP $status non-JSON reply (captive portal or proxy page)');
  }
  if (status == 401 ||
      status == 403 ||
      (status == 400 && body.contains('Incorrect API key'))) {
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
    if (body.contains('"1211"')) {
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

/// The outcome kind a failure maps to: rate limits and daily caps are
/// [LookupOutcomeKind.rateLimited]; transport trouble (no network, a portal
/// or proxy answering) is [LookupOutcomeKind.offline]; everything else is
/// [LookupOutcomeKind.failed].
LookupOutcomeKind outcomeKindFor(LookupFailure f) => switch (f.code) {
      LookupFailureCode.rateLimited ||
      LookupFailureCode.dailyCap =>
        LookupOutcomeKind.rateLimited,
      LookupFailureCode.network ||
      LookupFailureCode.captivePortal =>
        LookupOutcomeKind.offline,
      _ => LookupOutcomeKind.failed,
    };
