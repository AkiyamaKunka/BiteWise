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
        AnalysisErrorKind.network => l.errNetwork,
        AnalysisErrorKind.badModel => l.errBadModel,
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

/// The `(code)` a server rejection carries, e.g. `bad_model` out of
/// "The server rejected this request (bad_model)."; '?' when absent.
String rejectionCode(String message) =>
    RegExp(r'\(([a-z_]+)\)').firstMatch(message)?.group(1) ?? '?';
