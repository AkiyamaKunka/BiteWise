/// The restaurant assist as Settings, its consent sheets, the meal card,
/// the editor and Diagnostics see it (design R7a, R7b). di.dart builds the
/// one instance from the app engine's analyzer (who a lookup would reach
/// now), its MealAssist (the consent prompt, the learned places, the
/// editor's lookups and answers, the card's dot, the decision log) and the
/// owner's server (what it says it supports); widget tests pass fakes. The
/// background engine never builds one.
library;

import 'package:flutter/foundation.dart' show ValueListenable;

import '../core/contracts.dart' show Meal;
import '../services/analyzer/provider_analyzers.dart' show ServerFeatures;
import '../services/assist/assist_local_state.dart' show AssistDecisionEntry;
import '../services/assist/clients/lookup_client.dart' show LookupSupport;
import '../services/assist/meal_assist.dart'
    show AssistActionResult, AssistRun, AssistUserAction, AssistWhereNow;

/// What the owner's server says about restaurant lookups (its
/// /api/auth_check `features` map). Only Claude Plan asks.
enum AssistServerState {
  /// Not asked, or it could not be asked (no address or key, unreachable,
  /// a rejected key, a page that is not the server's): no hint.
  unknown,

  /// Lookups are on and run as jobs.
  ready,

  /// The server predates lookups (no `features` map, or no job endpoints):
  /// "Your server needs an update for this feature."
  outdated,

  /// The server's CLAUDE_LOOKUP_ENABLED knob is off: "Restaurant lookup is
  /// turned off on your server."
  disabled,
}

/// [features] as a Settings hint. Null (could not ask) is [unknown]; a
/// server without the map, or without the job endpoints, is [outdated];
/// the knob off is [disabled].
AssistServerState assistServerStateOf(ServerFeatures? features) {
  if (features == null) return AssistServerState.unknown;
  if (!features.reported) return AssistServerState.outdated;
  if (!features.restaurantLookup) return AssistServerState.disabled;
  if (!features.lookupJobs) return AssistServerState.outdated;
  return AssistServerState.ready;
}

/// The Diagnostics 'Restaurant lookups' section (design R7b): today's
/// lookups against the cap and the last decisions — reason codes, kcal and
/// providers only.
final class RestaurantLookupsDiagnostics {
  const RestaurantLookupsDiagnostics({
    required this.today,
    required this.cap,
    this.decisions = const [],
  });

  final int today;
  final int cap;

  /// Oldest first, as the log keeps them.
  final List<AssistDecisionEntry> decisions;
}

class RestaurantAssistControls {
  const RestaurantAssistControls({
    required this.lookupSupport,
    required this.clearLearnedPlaces,
    this.consentNeeded,
    this.serverState,
    this.locationSupported = false,
    this.whereNow,
    this.now = DateTime.now,
    this.lookupNow,
    this.act,
    this.canLearnPlace,
    this.unseen,
    this.markSeen,
    this.lookupsDiagnostics,
  });

  /// Who a lookup would reach right now (MultiProviderAnalyzer's lookup
  /// router): the recipient a consent must name, and whether
  /// location-derived chains may go to it (an http:// own server: no).
  final LookupSupport Function() lookupSupport;

  /// 'Clear learned places' (MealAssist.clearLearnedPlaces): true when the
  /// backup-excluded document is gone.
  final Future<bool> Function() clearLearnedPlaces;

  /// Non-null while the assist is paused for a consent that does not name
  /// the current recipient (MealAssist.consentNeeded): the app shell shows
  /// the consent sheet again.
  final ValueListenable<LookupSupport?>? consentNeeded;

  /// What the owner's server says (Claude Plan only); null never asks.
  final Future<AssistServerState> Function()? serverState;

  /// Whether this phone can read a photo's location for a lookup at all:
  /// iOS only in v1 (Android reads no photo location).
  final bool locationSupported;

  /// What the phone's time zone and region say now (MealAssist.whereNow):
  /// Settings says why nothing would be looked up. Null adds no hint.
  final AssistWhereNow Function()? whereNow;

  /// The consent's time stamp.
  final DateTime Function() now;

  /// The editor's 'Look up restaurant nutrition', and the lookup of the
  /// chain the user picked after 'Wrong restaurant' (MealAssist.lookupNow;
  /// R7b). Null hides the editor's lookup.
  final Future<AssistRun> Function(
    int mealId, {
    bool useLocation,
    String? chainKey,
  })?
  lookupNow;

  /// The editor's answers to a result (MealAssist.act; R7b): Use AI
  /// estimate, Use published numbers, Wrong restaurant, Not from a
  /// restaurant, Correct. Null hides the source card's buttons.
  final Future<AssistActionResult> Function(
    int mealId,
    AssistUserAction action, {
    required String expectedRaw,
  })?
  act;

  /// Whether 'Correct' can teach the photo's spot (MealAssist
  /// .canLearnPlace): it does nothing else, so it is offered only then.
  final bool Function(Meal meal)? canLearnPlace;

  /// Meals an automatic apply changed that were not opened since (the
  /// card's dot), and the one that was just opened.
  final Future<Set<int>> Function()? unseen;
  final Future<bool> Function(int mealId)? markSeen;

  /// Diagnostics' 'Restaurant lookups'.
  final Future<RestaurantLookupsDiagnostics> Function()? lookupsDiagnostics;
}
