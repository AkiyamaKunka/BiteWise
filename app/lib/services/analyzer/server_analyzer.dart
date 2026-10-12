part of 'provider_analyzers.dart';

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

  /// The server composes the prompt: it gets `lang` and appends the
  /// directive itself (an old server ignores the field).
  @override
  bool get appendsReplyLanguage => false;

  /// `lang` for /api/analyze_photo and /api/text_intent — never for
  /// /api/analyze_leftover, whose item names must stay verbatim.
  Map<String, String> _replyLanguage() =>
      settings.repliesInChinese ? const {'lang': 'zh'} : const {};

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
              ..._replyLanguage(),
            }
          : {
              'prompt': prompt,
              'backend': settings.serverBackend,
              ..._planChoice(),
              ..._replyLanguage(),
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
    // server and was accepted. A captive portal / proxy page never reached
    // the server at all. Rate-limited is the closest non-rejecting class
    // ("try again"), and it carries the verbatim message.
    final notTheKey = error.contains('not ready') ||
        error.contains('update the server') ||
        error == _interceptedMessage;
    return KeyProbe(
        notTheKey ? KeyProbeResult.rateLimited : KeyProbeResult.rejected,
        message: error);
  }

  /// What validateKey says when something between the phone and the
  /// server answered in its place (a 3xx, or a 200 that is not JSON).
  static const String _interceptedMessage =
      'A captive portal or proxy page answered instead of your server — '
      'sign in to the Wi-Fi (or switch network) and test again.';

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
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return _isJsonObject(resp.body) ? 'rejected' : 'unreachable';
      }
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
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return _interceptedMessage;
      }
      if (resp.statusCode == 200) {
        // auth_check answers JSON. A non-JSON 200 is a captive portal or
        // proxy page answering INSTEAD of the server (plain HTTP on port
        // 80 is exactly what hotel Wi-Fi intercepts) — "null" here said
        // the server was fine while every photo failed on the same page
        // (loop find 2026-10-10). `is`-checks below, not casts: a
        // JSON-but-not-object body must not fall into the generic catch
        // and lie "could not reach" about a server that answered.
        final Object? decoded;
        try {
          decoded = jsonDecode(resp.body);
        } on FormatException {
          return _interceptedMessage;
        }
        // The server reports per-backend readiness — surface a chosen
        // backend whose plan key is missing NOW, at test time, instead of
        // as a 503 on tonight's dinner photo.
        final backend = settings.serverBackend;
        if (backend != 'claude') {
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
        // The server's own 401 is JSON; an HTML/text one is a web filter
        // or portal on the plain-HTTP path, not a verdict on the key.
        return _isJsonObject(resp.body)
            ? 'Your server rejected that key.'
            : _interceptedMessage;
      }
      return 'Server answered HTTP ${resp.statusCode}.';
    } on TimeoutException {
      return 'Server did not respond (timeout).';
    } catch (e) {
      return 'Could not reach $base.';
    }
  }
}
