/// The owner's server as a restaurant-lookup recipient: Claude Plan's
/// async lookup jobs (design R5a; the server side is R3b, lookup_jobs.py).
///
/// [ServerLookupClient.submit] POSTs the composed request (data_contracts
/// §4) plus `backend: claude` to {base}/api/restaurant_lookup: STRUCTURED
/// fields only. The server rebuilds the request through its whitelist gate
/// and composes the prompt itself (lookup_contract.py), so no prompt text
/// leaves the phone for this recipient, and nothing a direct provider would
/// not get either. A 200 is a finished answer (the server's 24 h cache), a
/// 202 a queued job that [ServerLookupClient.poll] asks
/// /api/restaurant_lookup/status about.
///
/// Answers, one for one with the server (telegram_bot.py, lookup_jobs.py):
///   - 200 `state: done` → done, but only with the payer receipt
///     `analyzed_by: "claude"`;
///   - 202, or `state: queued | running` → pending, with the job id;
///   - `state: unknown` (never seen, expired, lost in a restart) → pending
///     WITHOUT a job id: resubmit ([LookupOutcome.needsResubmit]);
///   - `state: failed` → by its reason: daily_cap and plan_refused →
///     rateLimited, preempted → busy, bad_output and guard_fail → failed
///     for good, anything else → failed, transient;
///   - 404 → serverOutdated (a server without the route answers Flask's
///     own 404 page);
///   - 403 `{reason: disabled}` → disabled (CLAUDE_LOOKUP_ENABLED is off);
///   - 429 → rateLimited (queue_full, daily_cap);
///   - 503 → busy (the claude backend cannot run right now);
///   - 401 → failed (the upload key was rejected), 400 → failed for good;
///   - a portal or proxy answering in the server's place (a 3xx, a
///     non-JSON 200 / 202 / 401 / 403), no network, or the 30 s deadline
///     per HTTP call → offline.
///
/// The https gate (design D17) lives HERE, so no caller can bypass it:
/// chains that came from the photo's location reach the server only when
/// the address the request goes to is https://. Over http the request is
/// recomposed brand-only before it is sent
/// (LookupRequestForClients.withoutLocationChains): only the chains the
/// items' printed brands and the receipt merchant name remain. The address
/// is read ONCE per call, so the gate, the consent stamp and the URL all
/// describe the same server.
///
/// Evidence: the server's text for a URL is its WebSearch tool's summary
/// of the whole search (lookup_jobs.EVIDENCE_PROVENANCE, `verbatim:
/// false`), and only a literal `true` is read as verbatim. So on Claude
/// Plan a found answer is a suggestion at most (design decision 13,
/// amendment 2026-10-24).
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

import '../../settings/app_settings.dart';
import 'http_lookup_client.dart' show LookupAbort, countOf, dedupe, redactRaw;
import 'lookup_client.dart';
import 'lookup_contract_adapter.dart';
import 'lookup_cost.dart';

/// Design R5a: 30 s per HTTP call. The server only enqueues or reads a
/// job, so a call that takes longer is a network problem.
const Duration kServerLookupHttpDeadline = Duration(seconds: 30);

/// The server's job-id shape (telegram_bot.api_restaurant_lookup_status).
final RegExp _jobIdRe = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

/// A server code worth repeating in diagnostics: lowercase words only.
final RegExp _codeRe = RegExp(r'^[a-z_]{1,40}$');

/// The server's `field` on a 400: the caller's own key path, never a value.
final RegExp _fieldRe = RegExp(r'^[A-Za-z0-9_.\[\]]{1,40}$');

final RegExp _controlRe = RegExp(r'[\u0000-\u001f\u007f]');

const int _maxCitedUrls = 20;
const int _maxUrlLength = 2048;
const int _maxEvidence = 20;
const int _maxEvidenceText = 2000;
const int _maxReasonLength = 120;

/// The first 8 hex characters of SHA-256 of [host], lowercased: what a
/// Claude Plan consent is stamped with (design D19). The host itself never
/// leaves this function.
String serverHostTag(String host) =>
    sha256.convert(utf8.encode(host.toLowerCase())).toString().substring(0, 8);

/// One reading of the server address.
class _Server {
  _Server(this.base, this.uri);

  /// settings.serverBaseUrl as read (no trailing slash).
  final String base;
  final Uri uri;

  bool get https => uri.scheme == 'https';

  /// Built like ServerAnalyzer's URLs: the path appended to the address.
  Uri endpoint(String path) => Uri.parse('$base$path');

  static _Server? parse(String base) {
    final u = Uri.tryParse(base);
    if (u == null ||
        u.host.isEmpty ||
        (u.scheme != 'http' && u.scheme != 'https')) {
      return null;
    }
    return _Server(base, u);
  }
}

class ServerLookupClient implements LookupClient {
  ServerLookupClient(
    this._settings, {
    http.Client? client,
    LookupBudget? budget,
    this.perCallDeadline = kServerLookupHttpDeadline,
  })  : _client = client ?? http.Client(),
        _budget = budget ?? const UnlimitedLookupBudget();

  final AppSettings _settings;
  final http.Client _client;
  final LookupBudget _budget;
  final Duration perCallDeadline;

  static const LookupRecipient _recipient = LookupRecipient.claudePlan;

  ({LookupSupport support, _Server? server}) _read() {
    if (_settings.serverBackend != 'claude') {
      return (
        support: const LookupSupport.unsupported(
            LookupUnsupportedReason.serverBackendNotClaude),
        server: null,
      );
    }
    final server = _Server.parse(_settings.serverBaseUrl);
    if (server == null) {
      return (
        support: const LookupSupport.unsupported(
            LookupUnsupportedReason.noServerAddress),
        server: null,
      );
    }
    return (
      support: LookupSupport(
        supported: true,
        recipient: _recipient,
        locationAllowed: server.https,
        recipientHostTag: serverHostTag(server.uri.host),
      ),
      server: server,
    );
  }

  /// Supported on the claude backend with a usable address; location
  /// chains allowed only over https://. A missing upload key is still
  /// "supported" (the submit says what is missing), as a missing key is
  /// for the direct providers.
  @override
  LookupSupport lookupSupport() => _read().support;

  /// [chainDomains] are not sent: the server builds its own search from
  /// the chains in the request. [expectedRecipientStamp] is required (a
  /// null is refused like a stale one) because Claude Plan's consent names
  /// the server host.
  @override
  Future<LookupOutcome> submit(LookupRequest request,
      {List<String> chainDomains = const [],
      LookupCancelToken? cancel,
      LookupRecipient? expectedRecipient,
      String? expectedRecipientStamp}) async {
    final (:support, :server) = _read();
    if (server == null) return LookupOutcome.unsupported(support.reason!);
    if (expectedRecipient != null && expectedRecipient != _recipient) {
      return LookupOutcome.consentChanged(expectedRecipient, _recipient);
    }
    if (expectedRecipientStamp != support.recipientStamp) {
      return LookupOutcome.consentStampChanged(
          expectedRecipientStamp, support.recipientStamp);
    }
    final key = (_settings.serverApiKey ?? '').trim();
    if (key.isEmpty) {
      return _local(const LookupFailure(LookupFailureCode.noKey,
          transient: true,
          message: 'No server upload key — add it in Settings.'));
    }
    if (cancel?.isCancelled ?? false) return _local(_cancelled);
    // The https gate: over http, only chains that printed text names.
    final outgoing = support.locationAllowed
        ? request
        : request.withoutLocationChains(request.chainKeys);
    final unsendable = _unsendable(outgoing, brandOnly: !support.locationAllowed);
    if (unsendable != null) {
      return _local(LookupFailure(LookupFailureCode.badRequest,
          transient: false, message: unsendable));
    }
    if (!_budget.tryStartLookup(0)) {
      return _local(const LookupFailure(LookupFailureCode.dailyCap,
          transient: true, message: 'daily lookup cap reached'));
    }
    final outcome = await _exchange(
      server.endpoint('/api/restaurant_lookup'),
      key,
      {...outgoing.body, 'backend': 'claude'},
      itemCount: outgoing.items.length.clamp(0, kLookupMaxItems),
      cancel: cancel,
    );
    _budget.recordSpend(outcome.cost);
    return outcome;
  }

  /// Sends only the job id. A job id the server could never have issued is
  /// a resubmit with zero calls.
  @override
  Future<LookupOutcome> poll(String jobId) async {
    final (:support, :server) = _read();
    if (server == null) return LookupOutcome.unsupported(support.reason!);
    if (!_jobIdRe.hasMatch(jobId)) return _resubmit();
    final key = (_settings.serverApiKey ?? '').trim();
    if (key.isEmpty) {
      return _local(const LookupFailure(LookupFailureCode.noKey,
          transient: true,
          message: 'No server upload key — add it in Settings.'));
    }
    // The job's request is not known here (a poll can follow a restart):
    // item_index is bounded by the request cap. The server already bounded
    // it by the job's own request, and lane B judges every match against
    // the meal's current items.
    return _exchange(
      server.endpoint('/api/restaurant_lookup/status'),
      key,
      {'job_id': jobId},
      itemCount: kLookupMaxItems,
      polledJobId: jobId,
    );
  }

  /// Why [request] cannot be sent, or null. The server refuses a lookup
  /// without an item name or without a chain from our table (independent
  /// restaurants get no lookup in v1), so neither is sent.
  static String? _unsendable(LookupRequest request, {required bool brandOnly}) {
    final items = request.items;
    if (items.isEmpty) return 'no items to look up';
    final named = items.any((i) => i is Map && i['name'] is String &&
        (i['name'] as String).isNotEmpty);
    if (!named) return 'no item names to look up';
    if (request.chainKeys.isEmpty) {
      return brandOnly
          ? 'chains from the photo location need an https server address, '
              'and no printed brand names a chain'
          : 'no chain to look up';
    }
    return null;
  }

  static const LookupFailure _cancelled = LookupFailure(
      LookupFailureCode.cancelled,
      transient: false,
      message: 'cancelled');

  LookupOutcome _local(LookupFailure f) => _failure(f, LookupCost.zero);

  LookupOutcome _resubmit() =>
      const LookupOutcome(kind: LookupOutcomeKind.pending, provider: _recipient);

  LookupOutcome _failure(LookupFailure f, LookupCost cost,
          {LookupOutcomeKind? kind, String? jobId}) =>
      LookupOutcome(
        kind: kind ??
            switch (f.code) {
              LookupFailureCode.rateLimited ||
              LookupFailureCode.dailyCap =>
                LookupOutcomeKind.rateLimited,
              LookupFailureCode.network ||
              LookupFailureCode.captivePortal ||
              LookupFailureCode.timeout =>
                LookupOutcomeKind.offline,
              _ => LookupOutcomeKind.failed,
            },
        provider: _recipient,
        jobId: jobId,
        failure: f,
        cost: cost,
      );

  /// One POST with the upload key, inside the 30 s deadline (the body read
  /// included) and abortable by [cancel]. Never throws.
  Future<LookupOutcome> _exchange(
      Uri url, String key, Map<String, Object?> body,
      {required int itemCount,
      String? polledJobId,
      LookupCancelToken? cancel}) async {
    const cost = LookupCost(httpCalls: 1);
    final abort = Completer<void>();
    void doAbort() {
      if (!abort.isCompleted) abort.complete();
    }

    final req = http.AbortableRequest('POST', url, abortTrigger: abort.future)
      ..headers['Content-Type'] = 'application/json'
      ..headers['X-API-Key'] = key
      ..headers['X-Client-Platform'] = 'app'
      ..body = jsonEncode(body);
    final http.Response resp;
    try {
      final send = _client.send(req).then(http.Response.fromStream);
      resp = await Future.any<http.Response>([
        send,
        if (cancel != null)
          cancel.whenCancelled
              .then<http.Response>((_) => throw const LookupAbort(_cancelled)),
      ]).timeout(perCallDeadline);
    } on LookupAbort catch (e) {
      doAbort();
      return _failure(e.failure, cost);
    } on TimeoutException {
      doAbort();
      return _failure(
          const LookupFailure(LookupFailureCode.timeout,
              transient: true, message: 'server did not answer in time'),
          cost);
    } catch (e) {
      doAbort();
      if (cancel?.isCancelled ?? false) return _failure(_cancelled, cost);
      // The runtime type only: a transport error's text carries the URL.
      return _failure(
          LookupFailure(LookupFailureCode.network,
              transient: true, message: 'connection error (${e.runtimeType})'),
          cost);
    }
    if (cancel?.isCancelled ?? false) return _failure(_cancelled, cost);
    try {
      return _fromResponse(resp.statusCode, resp.body,
          itemCount: itemCount, polledJobId: polledJobId);
    } catch (e) {
      // A reply shape no branch anticipated: never a throw.
      return _failure(
          LookupFailure(LookupFailureCode.malformedReply,
              transient: false,
              message: 'unexpected reply shape (${e.runtimeType})'),
          cost);
    }
  }

  LookupOutcome _fromResponse(int status, String text,
      {required int itemCount, String? polledJobId}) {
    const cost = LookupCost(httpCalls: 1);
    Object? decoded;
    var isJson = true;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      isJson = false;
    }
    final map = decoded is Map ? Map<String, dynamic>.from(decoded) : null;

    if (status == 200 || status == 202) {
      if (!isJson) {
        return _failure(
            LookupFailure(LookupFailureCode.captivePortal,
                transient: true,
                message: 'HTTP $status non-JSON reply (captive portal or '
                    'proxy page)'),
            cost);
      }
      if (map == null) {
        return _failure(
            const LookupFailure(LookupFailureCode.malformedReply,
                transient: false, message: 'reply is not a JSON object'),
            cost);
      }
      return _fromJob(map, itemCount: itemCount, polledJobId: polledJobId);
    }
    if (status >= 300 && status < 400) {
      return _failure(
          LookupFailure(LookupFailureCode.captivePortal,
              transient: true,
              message: 'HTTP $status redirect (captive portal or proxy)'),
          cost);
    }
    // The server's own 401/403 is JSON; an HTML one is a web filter or a
    // portal on the plain-HTTP path, not the server's verdict.
    if ((status == 401 || status == 403) && map == null) {
      return _failure(
          LookupFailure(LookupFailureCode.captivePortal,
              transient: true,
              message: 'HTTP $status non-JSON reply (captive portal or '
                  'proxy page)'),
          cost);
    }
    final code = _code(map?['error']);
    if (status == 401) {
      return _failure(
          const LookupFailure(LookupFailureCode.auth,
              transient: false, message: 'Your server rejected the upload key.'),
          cost);
    }
    if (status == 403) {
      if (_code(map?['reason']) == 'disabled' || code == 'disabled') {
        return _failure(
            const LookupFailure(LookupFailureCode.searchDisabled,
                transient: false,
                message: 'Restaurant lookup is turned off on your server.'),
            cost,
            kind: LookupOutcomeKind.disabled);
      }
      return _failure(
          LookupFailure(LookupFailureCode.auth,
              transient: false, message: 'HTTP 403${_paren(code)}'),
          cost);
    }
    if (status == 404) {
      return _failure(
          const LookupFailure(LookupFailureCode.badRequest,
              transient: false,
              message: 'Your server predates restaurant lookups (HTTP 404) — '
                  'update the server.'),
          cost,
          kind: LookupOutcomeKind.serverOutdated);
    }
    if (status == 429) {
      return _failure(
          LookupFailure(
              code == 'daily_cap'
                  ? LookupFailureCode.dailyCap
                  : LookupFailureCode.rateLimited,
              transient: true,
              message: 'HTTP 429${_paren(code)}'),
          cost);
    }
    if (status == 503) {
      final reason = _reason(map?['reason']);
      return _failure(
          LookupFailure(LookupFailureCode.server,
              transient: true,
              message: reason == null
                  ? 'HTTP 503'
                  : 'The server cannot look up right now: $reason.'),
          cost,
          kind: LookupOutcomeKind.busy);
    }
    if (status == 400) {
      final f = map?['field'];
      final field = f is String && _fieldRe.hasMatch(f) ? f : null;
      return _failure(
          LookupFailure(LookupFailureCode.badRequest,
              transient: false,
              message: 'The server rejected this lookup'
                  '${_paren([?code, if (field != null) 'field $field'].join(', '))}.'),
          cost);
    }
    if (status >= 500 && status < 600) {
      return _failure(
          LookupFailure(LookupFailureCode.server,
              transient: true, message: 'HTTP $status'),
          cost);
    }
    return _failure(
        LookupFailure(LookupFailureCode.badRequest,
            transient: false, message: 'HTTP $status'),
        cost);
  }

  /// A job body (`{state, job_id, …}`) as an outcome.
  LookupOutcome _fromJob(Map<String, dynamic> body,
      {required int itemCount, String? polledJobId}) {
    const cost = LookupCost(httpCalls: 1);
    final rawId = body['job_id'];
    final jobId =
        rawId is String && _jobIdRe.hasMatch(rawId) ? rawId : polledJobId;
    switch (body['state']) {
      case 'queued' || 'running':
        if (jobId == null) break;
        return LookupOutcome(
            kind: LookupOutcomeKind.pending,
            provider: _recipient,
            jobId: jobId,
            cost: cost);
      case 'done':
        return _done(body, jobId: jobId, itemCount: itemCount);
      case 'failed':
        return _jobFailed(body['reason'], jobId: jobId);
      // Only a poll can learn that the server forgot its job; the same
      // answer to a submit would loop.
      case 'unknown' when polledJobId != null:
        return LookupOutcome(
            kind: LookupOutcomeKind.pending, provider: _recipient, cost: cost);
    }
    return _failure(
        const LookupFailure(LookupFailureCode.malformedReply,
            transient: false, message: 'reply is not a lookup job'),
        cost,
        jobId: jobId);
  }

  LookupOutcome _done(Map<String, dynamic> body,
      {String? jobId, required int itemCount}) {
    const cost = LookupCost(httpCalls: 1);
    // The payer receipt: a done job names the plan that ran it, and only
    // Claude runs lookups (design D18).
    final by = body['analyzed_by'];
    if (by != 'claude') {
      final named = by is String ? _code(by) : null;
      return _failure(
          LookupFailure(LookupFailureCode.malformedReply,
              transient: false,
              message: named == null
                  ? 'the server did not confirm a Claude run (no '
                      'analyzed_by receipt)'
                  : 'the server ran this lookup on "$named", not Claude'),
          cost,
          jobId: jobId);
    }
    final result = LookupResult.parse(body['lookup'], itemCount: itemCount);
    if (result == null) {
      return _failure(
          const LookupFailure(LookupFailureCode.malformedReply,
              transient: false,
              message: "the server's answer is not a lookup result"),
          cost,
          jobId: jobId);
    }
    final searches = countOf(body['searches']) ?? 0;
    return LookupOutcome(
      kind: LookupOutcomeKind.done,
      provider: _recipient,
      jobId: jobId,
      result: result,
      citedUrls: _citedUrls(body['cited_urls']),
      evidence: _evidence(body['evidence']),
      searches: searches,
      cost: LookupCost(searches: searches, httpCalls: 1),
      raw: redactRaw(body),
    );
  }

  LookupOutcome _jobFailed(Object? rawReason, {String? jobId}) {
    const cost = LookupCost(httpCalls: 1);
    final reason = _code(rawReason) ?? 'failed';
    final (kind, failure) = switch (reason) {
      'daily_cap' => (
          LookupOutcomeKind.rateLimited,
          const LookupFailure(LookupFailureCode.dailyCap,
              transient: true, message: "the server's daily lookup cap is "
                  'reached'),
        ),
      'plan_refused' => (
          LookupOutcomeKind.rateLimited,
          const LookupFailure(LookupFailureCode.rateLimited,
              transient: true,
              message: 'the Claude plan refused the run (usage window)'),
        ),
      'preempted' => (
          LookupOutcomeKind.busy,
          const LookupFailure(LookupFailureCode.server,
              transient: true,
              message: 'photos kept the server busy (pre-empted)'),
        ),
      'bad_output' => (
          LookupOutcomeKind.failed,
          const LookupFailure(LookupFailureCode.malformedReply,
              transient: false,
              message: "the server's lookup run produced no usable answer"),
        ),
      'guard_fail' => (
          LookupOutcomeKind.failed,
          const LookupFailure(LookupFailureCode.refused,
              transient: false,
              message: "the server's lookup guard refused the run"),
        ),
      'timeout' => (
          LookupOutcomeKind.failed,
          const LookupFailure(LookupFailureCode.timeout,
              transient: true, message: "the server's lookup run timed out"),
        ),
      _ => (
          LookupOutcomeKind.failed,
          LookupFailure(LookupFailureCode.server,
              transient: true,
              message: "the server's lookup run failed ($reason)"),
        ),
    };
    return _failure(failure, cost, kind: kind, jobId: jobId);
  }

  /// The URLs the server's search returned, as strings (normalized and
  /// screened later by lane B), de-duplicated and capped.
  static List<String> _citedUrls(Object? raw) => dedupe([
        if (raw is List)
          for (final u in raw.take(_maxCitedUrls * 2))
            if (u is String && u.trim().length <= _maxUrlLength) u.trim(),
      ]).take(_maxCitedUrls).toList();

  static List<LookupEvidence> _evidence(Object? raw) => [
        if (raw is List)
          for (final e in raw.take(_maxEvidence))
            if (e is Map &&
                e['url'] is String &&
                (e['url'] as String).trim().isNotEmpty &&
                (e['url'] as String).trim().length <= _maxUrlLength &&
                e['text'] is String)
              LookupEvidence(
                url: (e['url'] as String).trim(),
                text: _cap(e['text'] as String, _maxEvidenceText),
                // Only a literal true: the server labels its search
                // summary false, and anything else is not page text.
                verbatim: e['verbatim'] == true,
                pageAge: e['page_age'] is String
                    ? _cap(e['page_age'] as String, 40)
                    : null,
              ),
      ];

  static String _cap(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  static String? _code(Object? v) =>
      v is String && _codeRe.hasMatch(v.trim()) ? v.trim() : null;

  /// A server `reason` for a diagnostics line: control characters out,
  /// short.
  static String? _reason(Object? v) {
    if (v is! String) return null;
    final s = v.replaceAll(_controlRe, ' ').trim();
    if (s.isEmpty) return null;
    return _cap(s, _maxReasonLength);
  }

  static String _paren(String? s) => s == null || s.isEmpty ? '' : ' ($s)';
}
