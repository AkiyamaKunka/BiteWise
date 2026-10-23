/// The shared skeleton of the direct lookup clients: key check, cost
/// pre-flight, daily budget, one-POST transport with a deadline and
/// cancellation, failure classification, spend recording.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/coerce.dart' show parseAiJson;
import 'citation_check.dart';
import 'http_failure.dart';
import 'lookup_client.dart';
import 'lookup_contract_adapter.dart';
import 'lookup_cost.dart';

/// Design R5b: synchronous lookups with a 45 s timeout per HTTP call. A
/// lookup with pause_turn continuations gets at most [kLookupOverallDeadline]
/// in total.
const Duration kLookupHttpDeadline = Duration(seconds: 45);
const Duration kLookupOverallDeadline = Duration(seconds: 90);

/// Thrown inside a lookup run; the skeleton turns it into an outcome.
class LookupAbort implements Exception {
  const LookupAbort(this.failure);
  final LookupFailure failure;
  @override
  String toString() => 'LookupAbort($failure)';
}

/// Mutable state of one lookup: what it has spent so far, its clock, and
/// the provider's last reply (for diagnostics).
class LookupRun {
  LookupRun(this.policy, this.cancel) : watch = Stopwatch()..start();

  final LookupCostPolicy policy;
  final LookupCancelToken? cancel;
  final Stopwatch watch;
  LookupCost cost = LookupCost.zero;
  Map<String, dynamic>? lastRaw;

  void add(LookupCost c) => cost = cost + c;

  /// Refuses the next request when what this lookup already spent plus the
  /// request's [worstCaseUsd] would pass the per-lookup cap.
  void ensureWithinCap(double worstCaseUsd) {
    if (cost.usd + worstCaseUsd > policy.maxUsdPerLookup + 1e-12) {
      throw LookupAbort(LookupFailure(LookupFailureCode.costCap,
          transient: false,
          message: 'next request could cost '
              '\$${worstCaseUsd.toStringAsFixed(4)} on top of '
              '\$${cost.usd.toStringAsFixed(4)}; cap '
              '\$${policy.maxUsdPerLookup.toStringAsFixed(2)}'));
    }
  }

  void ensureNotCancelled() {
    if (cancel?.isCancelled ?? false) {
      throw const LookupAbort(LookupFailure(LookupFailureCode.cancelled,
          transient: false, message: 'cancelled'));
    }
  }
}

/// A raw provider reply with opaque blobs removed: Anthropic's
/// `encrypted_content` / `encrypted_index` and thinking `signature`s are
/// kilobytes of base64 that mean nothing to a reader.
Map<String, dynamic> redactRaw(Map<String, dynamic> body) {
  const drop = {'encrypted_content', 'encrypted_index', 'signature', 'data'};
  Object? walk(Object? v) {
    if (v is Map) {
      return {
        for (final e in v.entries)
          if (!drop.contains(e.key)) e.key as String: walk(e.value),
      };
    }
    if (v is List) return [for (final x in v) walk(x)];
    return v;
  }

  return Map<String, dynamic>.from(walk(body) as Map);
}

/// The JSON object inside a model's answer text: fences stripped, then the
/// outermost `{…}` (parseAiJson's rules).
Object? decodeAnswerJson(String text) {
  try {
    return parseAiJson(text);
  } on FormatException {
    return null;
  }
}

abstract class HttpLookupClient implements LookupClient {
  HttpLookupClient({
    required this.apiKey,
    http.Client? client,
    LookupBudget? budget,
    this.policy = const LookupCostPolicy(),
    this.perCallDeadline = kLookupHttpDeadline,
    this.overallDeadline = kLookupOverallDeadline,
  })  : client = client ?? http.Client(),
        budget = budget ?? const UnlimitedLookupBudget();

  /// Read per call: a key changed in Settings applies to the next lookup.
  final String? Function() apiKey;
  final http.Client client;
  final LookupBudget budget;
  final LookupCostPolicy policy;
  final Duration perCallDeadline;
  final Duration overallDeadline;

  String get providerLabel;
  LookupRecipient get recipient;

  /// The model that will answer (for the outcome and the cost table).
  String get lookupModel;

  /// The worst case of the FIRST request, for the pre-flight checks.
  double worstCaseFirstRequestUsd();

  /// Runs the provider's request(s). Returns the done outcome's pieces;
  /// throws [LookupAbort] for anything else. Must add every reply's cost
  /// to [run] as soon as it is known.
  Future<LookupAnswer> runLookup(String key, LookupRequest request,
      List<String> domains, LookupRun run);

  @override
  LookupSupport lookupSupport() => LookupSupport(
      supported: true, recipient: recipient, locationAllowed: true);

  @override
  Future<LookupOutcome> poll(String jobId) async => LookupOutcome(
      kind: LookupOutcomeKind.unsupported,
      provider: recipient,
      failure: const LookupFailure(LookupFailureCode.badRequest,
          transient: false, message: 'direct lookups have no jobs'));

  @override
  Future<LookupOutcome> submit(LookupRequest request,
      {List<String> chainDomains = const [],
      LookupCancelToken? cancel}) async {
    final run = LookupRun(policy, cancel);
    final key = (apiKey() ?? '').trim();
    if (key.isEmpty) {
      return _failed(
          LookupFailure(LookupFailureCode.noKey,
              transient: true,
              message: 'No $providerLabel API key — add one in Settings.'),
          run);
    }
    if (request.items.isEmpty) {
      return _failed(
          const LookupFailure(LookupFailureCode.badRequest,
              transient: false, message: 'no items to look up'),
          run);
    }
    if (cancel?.isCancelled ?? false) {
      return _failed(
          const LookupFailure(LookupFailureCode.cancelled,
              transient: false, message: 'cancelled'),
          run);
    }
    final worst = worstCaseFirstRequestUsd();
    if (worst > policy.maxUsdPerLookup + 1e-12) {
      // Zero calls: this provider cannot promise to stay under the cap.
      return _failed(
          LookupFailure(LookupFailureCode.costCap,
              transient: false,
              message: 'worst case \$${worst.toStringAsFixed(4)} exceeds the '
                  '\$${policy.maxUsdPerLookup.toStringAsFixed(2)} per-lookup '
                  'cap'),
          run);
    }
    if (!budget.tryStartLookup(worst)) {
      return _failed(
          const LookupFailure(LookupFailureCode.dailyCap,
              transient: true, message: 'daily lookup cap reached'),
          run);
    }
    LookupOutcome outcome;
    try {
      final domains = cleanDomains(chainDomains);
      final a = await runLookup(key, request, domains, run);
      run.ensureNotCancelled(); // Off while the reply was in flight: discard
      outcome = LookupOutcome(
        kind: LookupOutcomeKind.done,
        provider: recipient,
        result: a.result,
        citedUrls: a.citedUrls,
        evidence: a.evidence,
        searches: run.cost.searches,
        cost: run.cost,
        model: lookupModel,
        rawText: a.text,
        raw: run.lastRaw,
      );
    } on LookupAbort catch (e) {
      outcome = _failed(e.failure, run);
    } catch (e) {
      // A reply shape no parser branch anticipated (a cast deep in a
      // vendor's JSON). Lookups never throw: same verdict as the
      // analyzers' 'unexpected response shape' — permanent, because a
      // retry would re-spend a search for the same answer.
      outcome = _failed(
          LookupFailure(LookupFailureCode.malformedReply,
              transient: false,
              message: 'unexpected reply shape (${e.runtimeType})'),
          run);
    }
    budget.recordSpend(run.cost);
    return outcome;
  }

  LookupOutcome _failed(LookupFailure f, LookupRun run) => LookupOutcome(
        kind: outcomeKindFor(f),
        provider: recipient,
        failure: f,
        searches: run.cost.searches,
        cost: run.cost,
        model: lookupModel,
        raw: run.lastRaw,
      );

  /// One POST of [body] as JSON. Returns the decoded reply object; throws
  /// [LookupAbort] with the analyzers' classification otherwise. The body
  /// read sits inside the same deadline as the send (a stalled body must
  /// not hang the caller), and cancellation aborts the socket where the
  /// client supports it.
  Future<Map<String, dynamic>> postJson(
      Uri url, Map<String, String> headers, Map<String, Object?> body,
      LookupRun run) async {
    run.ensureNotCancelled();
    final left = overallDeadline - run.watch.elapsed;
    if (left <= Duration.zero) {
      throw const LookupAbort(LookupFailure(LookupFailureCode.timeout,
          transient: true, message: 'lookup deadline hit'));
    }
    final deadline = left < perCallDeadline ? left : perCallDeadline;
    final abort = Completer<void>();
    void doAbort() {
      if (!abort.isCompleted) abort.complete();
    }

    final req = http.AbortableRequest('POST', url, abortTrigger: abort.future)
      ..headers.addAll(headers)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    final cancel = run.cancel;
    // Counted when attempted: a call that fails still reached (and may
    // have been billed by) the provider.
    run.add(const LookupCost(httpCalls: 1));
    final http.Response resp;
    try {
      final send = client.send(req).then(http.Response.fromStream);
      resp = await Future.any<http.Response>([
        send,
        if (cancel != null)
          cancel.whenCancelled.then<http.Response>((_) =>
              throw const LookupAbort(LookupFailure(
                  LookupFailureCode.cancelled,
                  transient: false,
                  message: 'cancelled'))),
      ]).timeout(deadline);
    } on LookupAbort {
      doAbort();
      rethrow;
    } on TimeoutException {
      doAbort();
      throw const LookupAbort(LookupFailure(LookupFailureCode.timeout,
          transient: true, message: 'client deadline hit'));
    } catch (e) {
      doAbort();
      if (cancel?.isCancelled ?? false) {
        throw const LookupAbort(LookupFailure(LookupFailureCode.cancelled,
            transient: false, message: 'cancelled'));
      }
      // The runtime type only: a transport error's text can carry the URL
      // and proxy details, and diagnostics must stay free of either.
      throw LookupAbort(LookupFailure(LookupFailureCode.network,
          transient: true, message: 'connection error (${e.runtimeType})'));
    }
    if (resp.statusCode != 200) {
      throw LookupAbort(classifyHttpFailure(resp.statusCode, resp.body,
          providerLabel: providerLabel));
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } on FormatException {
      // Every provider answers JSON: a non-JSON 200 is a portal or proxy.
      throw const LookupAbort(LookupFailure(LookupFailureCode.captivePortal,
          transient: true,
          message: 'non-JSON reply (captive portal or proxy page)'));
    }
    if (decoded is! Map<String, dynamic>) {
      throw const LookupAbort(LookupFailure(LookupFailureCode.malformedReply,
          transient: false, message: 'reply is not a JSON object'));
    }
    run.lastRaw = redactRaw(decoded);
    return decoded;
  }

  /// [text] parsed as a §5 result, or a malformed-reply abort.
  LookupResult parseResult(String text, LookupRequest request) {
    final r = LookupResult.parse(decodeAnswerJson(text),
        itemCount: request.items.length.clamp(0, kLookupMaxItems));
    if (r == null) {
      throw const LookupAbort(LookupFailure(LookupFailureCode.malformedReply,
          transient: false, message: 'answer is not a lookup result'));
    }
    return r;
  }
}

/// What a successful run hands back to the skeleton.
class LookupAnswer {
  const LookupAnswer({
    required this.result,
    required this.text,
    required this.citedUrls,
    required this.evidence,
  });
  final LookupResult result;
  final String text;
  final List<String> citedUrls;
  final List<LookupEvidence> evidence;
}

int intOf(Object? v) => v is int ? v : (v is num && v.isFinite ? v.toInt() : 0);

/// [urls] de-duplicated in first-seen order.
List<String> dedupe(Iterable<String> urls) {
  final seen = <String>{};
  return [
    for (final u in urls)
      if (u.isNotEmpty && seen.add(u)) u
  ];
}
