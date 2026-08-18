/// Provider diagnostics (user request 2026-07-31): "a page that user can
/// test the API, and know what's wrong" — quota, dead key, unreachable
/// endpoint, unsupported reply format, all named precisely.
///
/// Design: SIX staged checks, each mapping a failure class the provider
/// feedback matrix proved distinct, streamed as they complete so the UI
/// fills in live. Seam-clean (SettingsStore + AnalyzerService + injected
/// http.Client) so every stage is fake-testable.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../core/contracts.dart';
import '../l10n/app_localizations.dart';
import 'services.dart';

enum DiagStatus { pass, warn, fail }

class DiagResult {
  const DiagResult(this.stage, this.status, this.summary,
      {this.detail, this.fix});
  final String stage;
  final DiagStatus status;
  final String summary; // one line, plain language
  final String? detail; // the raw evidence (verbatim error, host probed)
  final String? fix; // what the USER does next
}

/// Providers whose endpoints sit outside the mainland-China firewall.
const Set<String> _vpnNeeded = {'gemini', 'openai', 'anthropic'};

const Map<String, String> _probeUrls = {
  'gemini': 'https://generativelanguage.googleapis.com/',
  'openai': 'https://api.openai.com/',
  'anthropic': 'https://api.anthropic.com/',
  'qwen': 'https://dashscope.aliyuncs.com/',
  'doubao': 'https://ark.cn-beijing.volces.com/',
  'glm': 'https://open.bigmodel.cn/',
};

/// A real 64x64 JPEG (orange disc on white) generated with the same
/// library the analyzers use. The vision stage checks the CONTRACT — the
/// model answers the food-JSON schema — not the verdict; "not food" for an
/// orange disc is a PASS.
Uint8List defaultDiagnosticImage() {
  final image = img.Image(width: 64, height: 64);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  img.fillCircle(image,
      x: 32, y: 32, radius: 20, color: img.ColorRgb8(230, 126, 34));
  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}

class ProviderDiagnostics {
  ProviderDiagnostics({
    required this.settings,
    required this.analyzer,
    required this.l10n,
    http.Client? client,
    Uint8List Function()? testImage,
  })  : client = client ?? http.Client(),
        _testImage = testImage ?? defaultDiagnosticImage;

  final SettingsStore settings;
  final AnalyzerService analyzer;

  /// Every line this page shows is user-facing prose, so it goes through
  /// the same l10n as the rest of the app. Passed in rather than read from
  /// a BuildContext so the stages stay fake-testable (the page was the last
  /// screen still hardcoded to English — reported 2026-08-18).
  final AppLocalizations l10n;
  final http.Client client;
  final Uint8List Function() _testImage;

  /// Runs the staged checks, yielding each result as it lands. Stops early
  /// when a stage makes the rest meaningless (no key → nothing to test).
  Stream<DiagResult> run() async* {
    final l = l10n;
    final provider = settings.provider;
    final isServer = provider == 'server';

    // 1 ── Configuration ────────────────────────────────────────────────
    if (isServer && settings.serverBaseUrl.isEmpty) {
      yield DiagResult(l.diagStageConfiguration, DiagStatus.fail,
          l.diagNoServerAddress,
          fix: l.diagFixEnterServer);
      return;
    }
    if (settings.apiKey.trim().isEmpty) {
      yield DiagResult(l.diagStageConfiguration, DiagStatus.fail,
          isServer ? l.diagNoUploadKey : l.diagNoApiKey,
          fix: l.diagFixPasteKey);
      return;
    }
    yield DiagResult(
        l.diagStageConfiguration,
        DiagStatus.pass,
        isServer
            ? l.diagServerConfigured(settings.serverBackend)
            : l.diagProviderConfigured(provider, settings.model));

    // 2 ── Endpoint reachability ────────────────────────────────────────
    final probeUrl =
        isServer ? settings.serverBaseUrl : _probeUrls[provider];
    if (probeUrl != null) {
      try {
        // ANY HTTP answer (404 included) proves the network path; only
        // transport failures mean unreachable.
        await client
            .get(Uri.parse(probeUrl))
            .timeout(const Duration(seconds: 10));
        yield DiagResult(
            l.diagStageEndpoint,
            DiagStatus.pass,
            l.diagEndpointAnswered(
                isServer ? l.diagTargetServer : provider),
            detail: probeUrl);
      } catch (e) {
        yield DiagResult(
            l.diagStageEndpoint,
            DiagStatus.fail,
            l.diagEndpointUnreachable(
                isServer ? l.diagTargetYourServer : provider),
            detail: '$probeUrl — $e',
            fix: _vpnNeeded.contains(provider)
                ? l.diagFixVpn
                : isServer
                    ? l.diagFixServerUnreachable
                    : l.diagFixNetwork);
        return;
      }
    }

    // 3 ── Authentication & account ─────────────────────────────────────
    // probeKey, NOT validateKey: validateKey deliberately ACCEPTS a
    // quota-class reply (it proves the key authenticated), so an empty
    // account looked identical to a healthy one and this stage could
    // never name the out-of-credit case the page promises to name.
    final probe = await analyzer.probeKey(settings.apiKey);
    switch (probe.result) {
      case KeyProbeResult.ok:
        yield DiagResult(
            l.diagStageAuth, DiagStatus.pass, l.diagKeyAccepted);
      case KeyProbeResult.outOfCredit:
        yield DiagResult(
            l.diagStageAuth, DiagStatus.warn, l.diagOutOfCredit,
            detail: probe.message, fix: l.diagFixTopUp);
      case KeyProbeResult.rateLimited:
        yield DiagResult(
            l.diagStageAuth, DiagStatus.warn, l.diagRateLimited,
            detail: probe.message, fix: l.diagFixWaitRateLimit);
      case KeyProbeResult.rejected:
        yield DiagResult(
            l.diagStageAuth, DiagStatus.fail, l.diagKeyRejected,
            detail: probe.message, fix: l.diagFixRecopyKey);
        return;
    }

    // 4 ── Text round-trip ──────────────────────────────────────────────
    final text = await analyzer.textIntent(
        'Respond with ONLY this exact JSON object: {"ok": true}');
    yield text != null
        ? DiagResult(l.diagStageText, DiagStatus.pass, l.diagTextOk)
        : DiagResult(l.diagStageText, DiagStatus.warn, l.diagTextBad,
            detail: l.diagTextBadDetail, fix: l.diagFixPickModel);

    // 5 ── Photo round-trip ─────────────────────────────────────────────
    final photo = await analyzer.analyzePhoto(_testImage());
    if (photo.analysis != null) {
      yield DiagResult(l.diagStagePhoto, DiagStatus.pass, l.diagPhotoOk,
          detail: photo.isFood
              ? l.diagPhotoThoughtFood
              : l.diagPhotoNotFood);
    } else {
      yield DiagResult(
          l.diagStagePhoto,
          DiagStatus.fail,
          photo.retryable ? l.diagPhotoTempFail : l.diagPhotoPermFail,
          detail: photo.error,
          fix: photo.retryable
              ? l.diagFixPhotoTemp
              : l.diagFixPhotoPerm);
    }

    // 6 ── Quota state ──────────────────────────────────────────────────
    if (settings.isQuotaPaused) {
      final until = settings.quotaPauseUntil;
      yield DiagResult(
          l.diagStageQuota, DiagStatus.warn, l.diagQuotaPaused,
          detail: until != null
              ? l.diagQuotaPausedUntil(until.toString())
              : null,
          fix: l.diagFixQuota);
    } else {
      yield DiagResult(
          l.diagStageQuota, DiagStatus.pass, l.diagQuotaOk);
    }
  }
}
