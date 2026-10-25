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

import '../core/coerce.dart'
    show EstimateConfidence, isFoodTruthy, mealContextFields;
import '../core/contracts.dart';
import '../l10n/app_localizations.dart';
import '../services/assist/assist_local_state.dart' show AssistDecisionEntry;
import '../services/photo/glasses_check.dart';
import 'assist_view.dart' show assistProviderLabel;
import 'format.dart' show formatKcal;
import 'provider_names.dart';
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
const Set<String> _vpnNeeded = {'gemini', 'openai', 'anthropic', 'xai'};

const Map<String, String> _probeUrls = {
  'gemini': 'https://generativelanguage.googleapis.com/',
  'openai': 'https://api.openai.com/',
  'anthropic': 'https://api.anthropic.com/',
  'qwen': 'https://dashscope.aliyuncs.com/',
  'doubao': 'https://ark.cn-beijing.volces.com/',
  'glm': 'https://open.bigmodel.cn/',
  'deepseek': 'https://api.deepseek.com/',
  'xai': 'https://api.x.ai/',
  'openrouter': 'https://openrouter.ai/',
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
            // Display names, never the raw ids: the Chinese page read
            // '服务“qwen”' and '后端：claude' (loop find 2026-10-08).
            ? l.diagServerConfigured(
                providerDisplayLabel(l, 'server', settings.serverBackend))
            : l.diagProviderConfigured(
                providerLabel(provider), settings.model));

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
                isServer ? l.diagTargetServer : providerLabel(provider)),
            detail: probeUrl);
      } catch (e) {
        yield DiagResult(
            l.diagStageEndpoint,
            DiagStatus.fail,
            l.diagEndpointUnreachable(
                isServer ? l.diagTargetYourServer : providerLabel(provider)),
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
        // The credentials work: lift an automatic-scan pause a rejected
        // key armed (the owner may have fixed the account at the
        // provider's console without editing anything here). A region
        // pause only when the probe went through the generation endpoint
        // — every direct provider's does; the server's is /api/auth_check.
        try {
          await settings.credentialsProven(reachedGeneration: !isServer);
        } catch (_) {}
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
      case KeyProbeResult.modelNotFound:
        // The key is fine; the text and photo stages would fail on the
        // same model id, so stop here with the one fix that helps.
        yield DiagResult(l.diagStageAuth, DiagStatus.fail,
            l.diagModelNotFound(settings.model),
            detail: probe.message, fix: l.diagFixPickModel);
        return;
      case KeyProbeResult.regionBlocked:
        // Every later stage fails the same way; "re-copy the key" would
        // be the wrong fix for a key the provider never looked at.
        yield DiagResult(l.diagStageAuth, DiagStatus.fail,
            l.errRegionBlocked(providerLabel(provider)),
            detail: probe.message,
            fix: l.diagFixVpnRegion(providerLabel(provider)));
        return;
      case KeyProbeResult.rejected:
        yield DiagResult(
            l.diagStageAuth, DiagStatus.fail, l.diagKeyRejected,
            detail: probe.message, fix: l.diagFixRecopyKey);
        return;
    }

    // 4 ── Text round-trip ──────────────────────────────────────────────
    // textIntent returns null for EVERY failure — busy server, closed
    // usage window, timeout, rate limit, and a real no-JSON reply alike —
    // so this row cannot know the cause on its own. It used to blame the
    // model's JSON, say "photo analysis can still work" and prescribe a
    // model change; on a closed Claude window the photo row below then
    // failed for the same reason and the page contradicted itself. A
    // failed text row now waits for the photo round-trip and words its
    // detail and fix by that outcome (the yield order is unchanged).
    final text = await analyzer.textIntent(
        'Respond with ONLY this exact JSON object: {"ok": true}');
    if (text != null) {
      yield DiagResult(l.diagStageText, DiagStatus.pass, l.diagTextOk);
    }

    // 5 ── Photo round-trip ─────────────────────────────────────────────
    final photo = await analyzer.analyzePhoto(_testImage());
    if (text == null) {
      final photoWorks = photo.analysis != null;
      yield DiagResult(l.diagStageText, DiagStatus.warn, l.diagTextBad,
          detail: photoWorks
              ? l.diagTextBadDetail
              : l.diagTextBadPhotoAlsoFailed,
          fix: photoWorks
              ? l.diagFixTextPickModel
              : l.diagFixTextFollowPhoto);
    }
    if (photo.analysis != null) {
      // A full photo analysis answered: key and region both work.
      try {
        await settings.credentialsProven(reachedGeneration: true);
      } catch (_) {}
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
              ? l.diagQuotaPausedUntil(localStamp(until))
              : null,
          fix: l.diagFixQuota);
    } else {
      yield DiagResult(
          l.diagStageQuota, DiagStatus.pass, l.diagQuotaOk);
    }
  }
}

/// Local 'yyyy-MM-dd HH:mm' for the quota-pause detail and the background
/// scan history. It was DateTime.toString(), which printed seconds and
/// milliseconds ('2026-10-06 23:00:00.000'). The date stays because a pause
/// can run past midnight. Built by hand so the digits are ASCII in any
/// locale.
String localStamp(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}

/// A span of [seconds] as the Glasses check card says it: '<1 min',
/// '32 min', '2 h 5 min', '3 d'; a negative one with a leading '-'.
String diagDuration(AppLocalizations l, int seconds) {
  final sign = seconds < 0 ? '-' : '';
  final s = seconds.abs();
  if (s < 60) return '$sign${l.diagDurationUnderMinute}';
  final minutes = s ~/ 60;
  if (minutes < 60) return '$sign${l.diagDurationMinutes(minutes)}';
  final hours = minutes ~/ 60;
  if (hours < 48) return '$sign${l.diagDurationHours(hours, minutes % 60)}';
  return '$sign${l.diagDurationDays(hours ~/ 24)}';
}

/// [seconds] as a signed clock difference: '+0:20', '-12:05', '+1:02:03'.
String signedClock(int seconds) {
  final sign = seconds < 0 ? '-' : '+';
  final s = seconds.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0 ? '$sign$h:${two(m)}:${two(sec)}' : '$sign$m:${two(sec)}';
}

/// How a glasses photo was recognized, in the app language.
String glassesSignalLabel(AppLocalizations l, String? signal) =>
    switch (signal) {
      'filename' => l.diagGlassesSignalFilename,
      'album' => l.diagGlassesSignalAlbum,
      'exif' => l.diagGlassesSignalExif,
      _ => '—',
    };

/// A [GlassesCheckOutcome] in the app language.
String glassesOutcomeLabel(AppLocalizations l, String outcome) =>
    switch (outcome) {
      GlassesCheckOutcome.logged => l.diagGlassesOutcomeLogged,
      GlassesCheckOutcome.notFood => l.diagGlassesOutcomeNotFood,
      GlassesCheckOutcome.notFoodAi => l.diagGlassesOutcomeNotFoodAi,
      GlassesCheckOutcome.duplicate => l.diagGlassesOutcomeDuplicate,
      GlassesCheckOutcome.previewWait => l.diagGlassesOutcomePreviewWait,
      GlassesCheckOutcome.excluded => l.diagGlassesOutcomeExcluded,
      GlassesCheckOutcome.appWait => l.diagGlassesOutcomeAppWait,
      GlassesCheckOutcome.queued => l.diagGlassesOutcomeQueued,
      GlassesCheckOutcome.retry => l.diagGlassesOutcomeRetry,
      _ => l.diagGlassesOutcomeFailed,
    };

/// One Glasses check row, as three lines: when and what happened; how it
/// was recognized and the camera's Make / Model; the import lag, GPS
/// (yes or no, and the fix's difference from the shutter) and the food
/// score. No coordinate exists to show.
({String title, String device, String details}) glassesCheckLines(
    AppLocalizations l, GlassesCheckEntry e) {
  final lag = e.lagSeconds;
  final fix = e.gpsFixDeltaSeconds;
  final food = e.foodScore;
  return (
    title: '${localStamp(e.at)} · ${glassesOutcomeLabel(l, e.outcome)}',
    device: '${l.diagGlassesSignal(glassesSignalLabel(l, e.signal))} · '
        '${e.make ?? '—'} / ${e.model ?? '—'}',
    details: [
      lag == null
          ? l.diagGlassesLagUnknown
          : l.diagGlassesLag(diagDuration(l, lag)),
      e.hasGps ? l.diagGlassesGpsYes : l.diagGlassesGpsNo,
      if (fix != null) l.diagGlassesGpsTime(signedClock(fix)),
      food == null
          ? l.diagGlassesFoodNone
          : l.diagGlassesFood(food.toStringAsFixed(2)),
    ].join(' · '),
  );
}

/// The window of Diagnostics' AI-confidence counts (design R7b).
const int diagConfidenceDays = 14;

/// How sure the AI said it was (analysis.estimate_confidence, stage R1)
/// about each photo meal among [meals]: food meals from the camera roll or
/// a picked photo; a meal whose reply did not say (an older server or
/// model) counts as unknown. Counts only — no meal is named.
({int low, int medium, int high, int unknown}) confidenceCounts(
    Iterable<Meal> meals) {
  var low = 0, medium = 0, high = 0, unknown = 0;
  for (final m in meals) {
    if (m.source != MealSource.appWatch && m.source != MealSource.appPhoto) {
      continue;
    }
    if (!isFoodTruthy(m.analysis['is_food'])) continue;
    switch (mealContextFields(m.analysis).estimateConfidence) {
      case EstimateConfidence.low:
        low++;
      case EstimateConfidence.medium:
        medium++;
      case EstimateConfidence.high:
        high++;
      case null:
        unknown++;
    }
  }
  return (low: low, medium: medium, high: high, unknown: unknown);
}

/// One restaurant decision as Diagnostics lists it: when, the reason code,
/// the covered items' kcal before → after, and who answered. The entry
/// holds nothing else — no chain, item, place or meal (design R7b).
String restaurantDecisionLine(AppLocalizations l, AssistDecisionEntry e) {
  final before = e.oldKcal, after = e.newKcal;
  final provider = assistProviderLabel(l, e.provider);
  return [
    localStamp(e.at),
    e.code,
    if (before != null && after != null)
      '${formatKcal(before)} → ${l.kcalAmount(formatKcal(after))}',
    if (provider.isNotEmpty) provider,
  ].join(' · ');
}
