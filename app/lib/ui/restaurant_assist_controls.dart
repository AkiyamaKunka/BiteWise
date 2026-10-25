/// The restaurant assist as Settings and its consent sheets see it (design
/// R7a). di.dart builds the one instance from the app engine's analyzer
/// (who a lookup would reach now), its MealAssist (the consent prompt, the
/// learned places) and the owner's server (what it says it supports);
/// widget tests pass fakes. The background engine never builds one.
library;

import 'package:flutter/foundation.dart' show ValueListenable;

import '../services/analyzer/provider_analyzers.dart' show ServerFeatures;
import '../services/assist/clients/lookup_client.dart' show LookupSupport;

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

class RestaurantAssistControls {
  const RestaurantAssistControls({
    required this.lookupSupport,
    required this.clearLearnedPlaces,
    this.consentNeeded,
    this.serverState,
    this.locationSupported = false,
    this.now = DateTime.now,
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

  /// The consent's time stamp.
  final DateTime Function() now;
}
