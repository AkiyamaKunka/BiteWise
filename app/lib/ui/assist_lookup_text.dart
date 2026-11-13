/// What the meal editor says after a manual restaurant lookup that wrote
/// nothing ('Look up restaurant nutrition', a chain picked after 'Wrong
/// restaurant', or Search again). Pure: the editor keeps the polling, the
/// writes and the snackbar, and the whole mapping from how a lookup ended
/// to the line shown is one table (test/ui/assist_lookup_text_test.dart).
///
/// Not in outcome_text.dart: assist_view.dart imports that file, and this
/// one needs [AssistViewKind], so it would make an import cycle.
library;

import '../core/restaurant_assist_logic.dart'
    show AssistOutcome, assistDecisionItemsKcal, assistSameNumbers;
import '../l10n/app_localizations.dart';
import '../services/assist/meal_assist.dart' show AssistRun, AssistSkip;
import 'assist_view.dart' show AssistViewKind;
import 'format.dart' show formatKcal;

/// The line for a manual lookup [run] that wrote nothing, or null when
/// there is nothing to say (it was not started).
///
/// [fresh]: the provider was asked, never a saved lookup answer (Search
/// again, or the press right after a saved answer was used). [beforeKind]
/// and [before] are the meal's analysis before the lookup, for what a
/// fresh search over published numbers that stand, or over a suggestion
/// the meal can still take, says when it writes nothing.
String? manualLookupMessage(
  AppLocalizations l,
  AssistRun run, {
  required bool fresh,
  required AssistViewKind beforeKind,
  required Map<String, dynamic> before,
}) {
  if (run.code == AssistSkip.pending ||
      run.code == AssistSkip.working ||
      run.code == AssistSkip.background) {
    return l.assistLookupStillRunning;
  }
  if (fresh &&
      (beforeKind == AssistViewKind.applied ||
          beforeKind == AssistViewKind.suggested)) {
    return _searchAgainText(l, run, before);
  }
  // Answered, but nothing usable to write (another chain, items that
  // changed meanwhile, a malformed answer).
  if (run.decision != null) return l.assistContextOnly;
  return _lookupFailureText(l, run.code);
}

/// A fresh search over published numbers that stand on the meal, or over
/// a suggestion it can still take, wrote nothing (usual foods §2.4; an
/// answer that found nothing never replaces either): what it found. A
/// search that could not run says why instead.
String? _searchAgainText(
    AppLocalizations l, AssistRun run, Map<String, dynamic> before) {
  final d = run.decision;
  if (d == null && _lookupFailed(run.code)) {
    return _lookupFailureText(l, run.code);
  }
  if (d == null ||
      d.outcome == AssistOutcome.reject ||
      d.outcome == AssistOutcome.contextOnly ||
      d.items.isEmpty) {
    return l.assistSearchAgainNoChange;
  }
  if (assistSameNumbers(before, d)) return l.assistSearchAgainSame;
  return l.assistSearchAgainDiffers(formatKcal(assistDecisionItemsKcal(d)));
}

/// [code] says the lookup got no answer (not started, refused, or
/// failed): a code [_lookupFailureText] names, not its "no chain"
/// fallback.
bool _lookupFailed(String code) =>
    code.startsWith('lookup_') ||
    const {
      AssistSkip.consentNeeded,
      AssistSkip.off,
      AssistSkip.cancelled,
      AssistSkip.pickNeedsHttps,
      AssistSkip.outsideUs,
      AssistSkip.regionUnknown,
      AssistSkip.dailyCap,
      AssistSkip.placeThrottled,
      AssistSkip.placeError,
      AssistSkip.error,
      AssistSkip.unsupported,
    }.contains(code);

/// Why a manual lookup wrote nothing, or null when there is nothing to
/// say (it was not started, or already runs).
String? _lookupFailureText(AppLocalizations l, String code) {
  switch (code) {
    case AssistSkip.consentNeeded:
    case AssistSkip.off:
    case AssistSkip.cancelled:
      return null;
    case AssistSkip.working:
    case AssistSkip.background:
      return l.assistLookupStillRunning;
    case AssistSkip.pickNeedsHttps:
      return l.assistLookupPickNeedsHttps;
    case AssistSkip.outsideUs:
      return l.assistLookupOutsideUs;
    case AssistSkip.regionUnknown:
      return l.assistLookupRegionUnknown;
    case AssistSkip.dailyCap:
    case 'lookup_daily_cap':
      return l.assistLookupDailyCap;
    case 'lookup_server_outdated':
      return l.restaurantServerOutdated;
    case 'lookup_disabled':
      return l.restaurantServerDisabled;
    case AssistSkip.placeThrottled:
    case AssistSkip.placeError:
    case AssistSkip.error:
    case AssistSkip.unsupported:
      return l.assistLookupFailed;
  }
  if (code.startsWith('lookup_')) return l.assistLookupFailed;
  // No chain to ask about: nothing printed, none nearby, a zone.
  return l.assistLookupNoChain;
}
