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

String outcomeBody(AppLocalizations l, PhotoOutcome o) {
  final d = o.detail;
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
        AnalysisErrorKind.rateLimited => l.errRateLimited,
        AnalysisErrorKind.quotaPaused => l.errQuotaPaused,
        AnalysisErrorKind.billing => l.errBilling,
        AnalysisErrorKind.network => l.errNetwork,
        AnalysisErrorKind.badModel => badModelText(l, o.message),
        AnalysisErrorKind.badResponse => l.errBadResponse,
        AnalysisErrorKind.badPhoto => l.errBadPhoto,
        AnalysisErrorKind.serverBusy => l.errServerBusy,
        AnalysisErrorKind.serverError => l.errServerFailed,
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
/// logged, still analyzing (bindStream, 2026-10-10). English is
/// byte-identical to the strings the pipeline used to hand the snackbar.
String outcomeSnackbar(AppLocalizations l, PhotoOutcome o) {
  final body = outcomeBody(l, o);
  return o.kind == PhotoOutcomeKind.failed
      ? l.outcomeFailedKeptMsg(body)
      : body;
}

/// The `(code)` a server rejection carries, e.g. `bad_model` out of
/// "The server rejected this request (bad_model)."; '?' when absent.
String rejectionCode(String message) =>
    RegExp(r'\(([a-z_]+)\)').firstMatch(message)?.group(1) ?? '?';

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
