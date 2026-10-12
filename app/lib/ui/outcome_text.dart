/// One place that turns a [PhotoOutcome] into words in the app language.
///
/// Used by the add-flow dialog AND the headless meal card (which has no
/// BuildContext — pass `localizationsFor(appLanguage)`). English values are
/// byte-identical to the pipeline's own [PhotoOutcome.message], so every
/// test that pins that prose keeps holding; anything the classifier does
/// not recognise falls back to the raw message rather than a wrong guess.
library;

import '../core/outcome_kind.dart';
import '../l10n/app_localizations.dart';
import 'photo_pipeline.dart';

///
/// [deliberate]: the add flow's dialog. Its photo was RELEASED on a
/// transient failure, and only the automatic scan (off by default, and
/// never past its lookback window) could re-offer it — so "照片已保留，稍后
/// 会自动重试" would promise a retry that never comes. Those kinds say
/// what happened and point at the dialog's Retry instead. Snackbars, the
/// headless meal card and the coverage screen (whose rows really are kept)
/// keep the default.
String outcomeBody(AppLocalizations l, PhotoOutcome o,
    {bool deliberate = false}) {
  final d = o.detail;
  if (deliberate && o.kind == PhotoOutcomeKind.failed && o.retryable) {
    final reason = switch (o.errorKind) {
      // These lines promise nothing and name the fix.
      AnalysisErrorKind.noApiKey ||
      AnalysisErrorKind.noServerKey ||
      AnalysisErrorKind.regionBlocked =>
        null,
      _ => retryReason(l, o),
    };
    if (reason != null) return l.outcomeRetryLaterMsg(reason);
  }
  switch (o.kind) {
    case PhotoOutcomeKind.saved:
      return d == null ? o.message : l.outcomeSavedMsg(d);
    case PhotoOutcomeKind.leftoverApplied:
      return d == null ? o.message : l.outcomeLeftoverMsg(d);
    case PhotoOutcomeKind.skipped:
      return l.outcomeNotFoodMsg;
    case PhotoOutcomeKind.duplicate:
      return l.outcomeDuplicateMsg;
    case PhotoOutcomeKind.alreadyTracked:
      return l.outcomeAlreadyTrackedMsg;
    case PhotoOutcomeKind.inFlight:
      return l.outcomeInFlightMsg;
    case PhotoOutcomeKind.failed:
      return switch (o.errorKind) {
        AnalysisErrorKind.noApiKey => l.errNoApiKey,
        AnalysisErrorKind.noServerKey => l.errNoServerKey,
        AnalysisErrorKind.rejectedKey => l.errRejectedKey,
        AnalysisErrorKind.regionBlocked =>
          l.errRegionBlocked(regionProvider(l, o.message)),
        AnalysisErrorKind.contentBlocked => l.errContentBlocked,
        AnalysisErrorKind.rateLimited => l.errRateLimited,
        AnalysisErrorKind.quotaPaused => l.errQuotaPaused,
        AnalysisErrorKind.billing => l.errBilling,
        AnalysisErrorKind.network => l.errNetwork,
        AnalysisErrorKind.badModel => badModelText(l, o.message),
        AnalysisErrorKind.badResponse => l.errBadResponse,
        AnalysisErrorKind.badPhoto => l.errBadPhoto,
        AnalysisErrorKind.serverBusy => l.errServerBusy,
        // retry:false — the photo is marked failed and no scan offers it
        // again, so "稍后会自动重试" would be false: say why, and where to
        // retry by hand. The no-verdict/"later" case stays retryable.
        AnalysisErrorKind.serverError => o.retryable
            ? l.errServerFailed
            : l.errServerFailedFinal(serverReasonText(l, o.message)),
        AnalysisErrorKind.serverRejected =>
          l.errServerRejected(rejectionCode(o.message)),
        AnalysisErrorKind.none || AnalysisErrorKind.unknown => o.message,
      };
  }
}

/// The snackbar line for a pipeline `notify`: on every path a save, a
/// leftover deduction or a PERMANENT failure (kept in 之前失败 for a
/// deliberate retry; transient failures are released silently), and for a
/// share-sheet photo also the refusals — not food, duplicate, already
/// logged, still analyzing (bindStream, 2026-10-10) — and its transient
/// failures, worded below. English is
/// byte-identical to the strings the pipeline used to hand the snackbar.
///
/// A [PhotoOutcome.shared] transient failure says so and asks for a
/// re-share: the share copy is gone and nothing re-offers it, so "kept for
/// retry" would be untrue (2026-10-12).
String outcomeSnackbar(AppLocalizations l, PhotoOutcome o) {
  if (o.shared && o.kind == PhotoOutcomeKind.failed && o.retryable) {
    return l.outcomeShareRetryMsg(retryReason(l, o) ?? _bare(o.message));
  }
  final body = outcomeBody(l, o);
  return o.kind == PhotoOutcomeKind.failed
      ? l.outcomeFailedKeptMsg(body)
      : body;
}

/// A short "why" for a released (retryable) failure, for the lines that
/// wrap it in parentheses; null for a kind without one (the caller falls
/// back to its own wording).
String? retryReason(AppLocalizations l, PhotoOutcome o) =>
    switch (o.errorKind) {
      AnalysisErrorKind.rateLimited => l.reasonRateLimited,
      AnalysisErrorKind.quotaPaused => l.reasonQuotaPaused,
      AnalysisErrorKind.billing => l.reasonBilling,
      AnalysisErrorKind.network => l.reasonNetwork,
      AnalysisErrorKind.serverBusy => l.reasonServerBusy,
      AnalysisErrorKind.serverError => l.reasonServerFailed,
      AnalysisErrorKind.noApiKey => l.reasonNoApiKey,
      AnalysisErrorKind.noServerKey => l.reasonNoServerKey,
      AnalysisErrorKind.regionBlocked =>
        l.reasonRegionBlocked(regionProvider(l, o.message)),
      _ => null,
    };

/// Who refused the network region, out of the analyzers' "`Provider` is
/// not available from your current network region …" (Gemini's region
/// 400, OpenAI's `unsupported_country_region_territory` 403) — the zh line
/// used to say Gemini for every provider.
String regionProvider(AppLocalizations l, String? message) {
  const marker = ' is not available from your current network region';
  final m = message ?? '';
  final at = m.indexOf(marker);
  final name = at > 0 ? m.substring(0, at).trim() : '';
  return name.isEmpty || name.length > 40 ? l.regionProviderFallback : name;
}

/// [message] without its trailing periods, to sit inside parentheses.
String _bare(String message) {
  var m = message.trim();
  while (m.endsWith('.')) {
    m = m.substring(0, m.length - 1).trimRight();
  }
  return m;
}

/// The `(code)` a server rejection carries, e.g. `bad_model` out of
/// "The server rejected this request (bad_model)."; '?' when absent.
String rejectionCode(String message) =>
    RegExp(r'\(([a-z_]+)\)').firstMatch(message)?.group(1) ?? '?';

/// The server's own reason out of "The server cannot analyze right now:
/// `<reason>.`" (ServerAnalyzer.unavailableMessage) — trailing periods off,
/// bounded, since it is the server's (or the Claude CLI's) prose; null
/// when the message carries none.
String? serverReason(String message) {
  const marker = 'cannot analyze right now: ';
  final at = message.indexOf(marker);
  if (at < 0) return null;
  var reason = message.substring(at + marker.length).trim();
  while (reason.endsWith('.')) {
    reason = reason.substring(0, reason.length - 1).trimRight();
  }
  if (reason.isEmpty) return null;
  final runes = reason.runes.toList();
  return runes.length <= 160
      ? reason
      : '${String.fromCharCodes(runes.take(159))}…';
}

/// [serverReason] for display: the server's known "ran but produced no
/// usable result" in the app language, any other reason verbatim (the
/// CLI's own sentence, e.g. "Fable 5 requires usage credits").
String serverReasonText(AppLocalizations l, String message) {
  final reason = serverReason(message);
  if (reason == null) return message;
  if (reason.contains('produced no usable result')) {
    return l.serverReasonNoResult;
  }
  return reason;
}

/// The bad-model line, keeping the provider-specific remedy where the
/// analyzer's 404 hint has one: Doubao needs the versioned id AND the model
/// activated (开通管理); OpenRouter needs the full slug of a model that
/// accepts images. "Check the model name" alone would not fix either.
String badModelText(AppLocalizations l, String? message) {
  final m = message ?? '';
  if (m.startsWith('Doubao model not found')) return l.errBadModelDoubao;
  if (m.startsWith('OpenRouter model not found')) {
    return l.errBadModelOpenRouter;
  }
  return l.errBadModel;
}
