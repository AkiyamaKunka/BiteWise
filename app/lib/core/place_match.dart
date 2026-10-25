/// Which nearby chain a restaurant meal's photo was taken at, if any —
/// stage R2c of the restaurant assist (design "Chain-first data
/// minimization", "Location-only APPLY", "Feedback actions"; data_contracts
/// §8–§9).
///
/// Pure. The caller (MealAssist's location path, R6c) reads the photo's
/// position on the phone, turns it into a [PlaceCell] (about 100 m), asks
/// Apple Maps for the food places around it (services/places/places.dart),
/// and hands this file the places, the fix quality from analysis.capture
/// ([PhotoGeo]) and the user's [LearnedPlaces]. Nothing here ever sees a
/// coordinate: the places carry only their distance from the photo, and
/// nothing here keeps them.
///
/// Steps:
///   1. The gate ([placeGate]) on the fix:
///      * accuracy ≤ 100 m; unknown counts as 30 m for a camera photo and
///        65 m for a glasses import;
///      * |GPS fix − photo creation| ≤ 10 min (both UTC instants: G2a stores
///        only their difference, analysis.capture.gps_fix_delta_s).
///      A missing fix time leaves a glasses photo UNVERIFIED (the Meta AI
///      app may stamp the phone's position at import; an unverified fix
///      only ever suggests, design decision 6) and a camera photo fresh. A
///      fix that fails either check is not used at all: a coarse or stale
///      position names the wrong street, and the chains around it would
///      tell the AI recipient about a place the user may never have been.
///   2. Only a restaurant meal (not takeout, packaged, home or unknown),
///      and nothing inside a 'Not from a restaurant' zone.
///   3. The places within the query radius, clamp(2 × accuracy, 40, 150) m,
///      are scored categoryWeight × exp(−d² / 2σ²), σ = max(accuracy,
///      20 m). A place is a chain only when chain_match maps its name (and
///      website host) onto BiteWise's own table.
///   4. Dense: 3+ places within σ, or 2+ different chains within σ — a food
///      court, a mall, Times Square. Distance cannot tell those apart.
///   5. Candidates: the table's chains among the places, minus those the
///      user blocked here ('Wrong restaurant'); at most 3, best first, a
///      chain the user confirmed here ahead of the rest.
///   6. Auto-pick one chain only when the spot is not dense, it is the only
///      chain within 2σ, and its score is ≥ 0.6 and at least twice the
///      next place's (any place, chain or not). The pick is geometry alone:
///      a confirmation reorders the candidates but never picks, never beats
///      the dense guard, and only ever counts for its own chain
///      (decideAssist applies a location-only match only for an
///      auto-picked chain the user confirmed here).
///
/// A block never makes another chain easier to pick: the blocked chain is
/// no candidate, but it still stands on the street for the dense, 2σ and
/// runner-up checks.
///
/// "Here" is the photo's [PlaceCell] and the 8 cells around it, so a fix
/// that wobbles across a cell edge still finds what the user taught.
///
/// The thresholds are reasoned guesses (design R2c), so each is a named
/// constant, and every match carries a [PlaceMatchReason] code for the
/// assist's decision log.
library;

import 'dart:math' as math;

import 'chain_match.dart' show matchChain;
import 'coerce.dart' show RestaurantContext;
import 'restaurant_lookup_contract.dart' show kLookupMaxChains;

// ─── Thresholds ────────────────────────────────────────────────────────

/// A fix less accurate than this (metres) is not used.
const double kPlaceMaxAccuracyM = 100;

/// The accuracy assumed when the photo does not record one: a phone camera
/// photo, and a glasses import (the Meta AI app geotags it from the phone,
/// possibly with the phone in a pocket).
const double kPlaceDefaultAccuracyCameraM = 30;
const double kPlaceDefaultAccuracyGlassesM = 65;

/// A fix further than this from the photo's creation instant is stale.
const int kPlaceMaxFixDeltaS = 10 * 60;

/// The query radius: [kPlaceRadiusFactor] × accuracy, clamped to
/// [kPlaceMinRadiusM]–[kPlaceMaxRadiusM]. A place further away is ignored.
const double kPlaceRadiusFactor = 2;
const int kPlaceMinRadiusM = 40;
const int kPlaceMaxRadiusM = 150;

/// σ never drops below this: neither a phone fix nor MapKit's own place
/// coordinates are better than that.
const double kPlaceMinSigmaM = 20;

/// Dense: at least this many places within σ …
const int kPlaceDenseMinPlaces = 3;

/// … or at least this many different chains within σ.
const int kPlaceDenseMinChains = 2;

/// An auto-picked chain is the only chain within this many σ.
const double kPlacePickUniqueSigmas = 2;

/// An auto-picked chain scores at least this …
const double kPlacePickMinScore = 0.6;

/// … and at least this many times the next place.
const double kPlacePickMinLead = 2;

/// Category weights: where meals are bought and eaten (restaurant, cafe,
/// bakery) …
const double kPlaceWeightPrimary = 1.0;

/// … bars and tap rooms (brewery, winery, distillery, nightlife) …
const double kPlaceWeightSecondary = 0.8;

/// … and food markets or anything MapKit files elsewhere.
const double kPlaceWeightOther = 0.5;

/// The places channel's category names (data_contracts §8;
/// services/places/places.dart PlaceCategory.wire).
const Set<String> _primaryCategories = {'restaurant', 'cafe', 'bakery'};
const Set<String> _secondaryCategories = {
  'brewery',
  'winery',
  'distillery',
  'nightlife',
};

/// The weight of a place filed under the places channel's [categoryWire].
double placeCategoryWeight(String categoryWire) =>
    _primaryCategories.contains(categoryWire)
    ? kPlaceWeightPrimary
    : _secondaryCategories.contains(categoryWire)
    ? kPlaceWeightSecondary
    : kPlaceWeightOther;

// ─── Inputs ────────────────────────────────────────────────────────────

/// One place a places query listed (services/places/places.dart
/// NearbyPlace implements it). Apple's Map Data: read here for one match,
/// never stored, logged or shown.
abstract interface class PlacePoi {
  /// As Apple Maps names it.
  String get name;

  /// The places channel's category name (restaurant, cafe, bakery,
  /// brewery, winery, nightlife, distillery, food_market, other).
  String get categoryWire;

  /// From the photo's position, whole metres.
  int get distanceM;

  /// The place's website host, lowercase ASCII; null when it lists none.
  String? get urlHost;
}

/// The photo's fix quality, from the meal's analysis.capture block (G2a,
/// data_contracts §2). No coordinates and no timestamps.
final class PhotoGeo {
  const PhotoGeo({this.accuracyM, this.fixDeltaS, this.glasses = false});

  /// analysis.capture: gps_acc_m and gps_fix_delta_s, read as untrusted
  /// stored data (anything off-contract is unknown). [glasses]: the meal's
  /// photo came from Meta glasses (glasses.dart isMetaGlassesAnalysis).
  factory PhotoGeo.fromCapture(Object? capture, {required bool glasses}) {
    final c = capture is Map ? capture : const {};
    final acc = c['gps_acc_m'];
    final delta = c['gps_fix_delta_s'];
    return PhotoGeo(
      accuracyM: acc is num && acc.isFinite && acc >= 0 ? acc.toDouble() : null,
      fixDeltaS: delta is int
          ? delta
          : delta is double && delta.isFinite && delta == delta.truncate()
          ? delta.toInt()
          : null,
      glasses: glasses,
    );
  }

  /// The fix's horizontal accuracy (GPSHPositioningError), metres; null
  /// when the photo does not record it.
  final double? accuracyM;

  /// GPS fix time minus the photo's creation instant, seconds; null when
  /// the photo has no fix time.
  final int? fixDeltaS;

  /// A Meta glasses import.
  final bool glasses;

  @override
  String toString() =>
      'PhotoGeo(acc: $accuracyM, Δ: $fixDeltaS, '
      'glasses: $glasses)';
}

/// What [placeGate] makes of a fix.
final class PlaceGate {
  const PlaceGate._({
    required this.reason,
    required this.verified,
    required this.accuracyM,
    required this.radiusM,
    required this.sigmaM,
  });

  /// Null when the fix may be used; [PlaceMatchReason.inaccurate] or
  /// [PlaceMatchReason.stale] when not.
  final PlaceMatchReason? reason;

  bool get passes => reason == null;

  /// The fix is trusted: it passes, and it is fresh (or a camera photo
  /// without a fix time). An unverified fix only ever suggests.
  final bool verified;

  /// The accuracy used: the photo's, or the default for its kind.
  final double accuracyM;

  /// The places query radius (metres) — what the caller asks
  /// PlaceResolver.nearbyFood for.
  final int radiusM;

  /// σ for the distance score, metres.
  final double sigmaM;

  @override
  String toString() =>
      'PlaceGate(${reason?.wire ?? 'ok'}, '
      'verified: $verified, r: $radiusM, σ: $sigmaM)';
}

/// The gate on [geo] (see the library doc). An accuracy that is not a
/// finite, non-negative number counts as unknown.
PlaceGate placeGate(PhotoGeo geo) {
  final given = geo.accuracyM;
  final acc = given != null && given.isFinite && given >= 0
      ? given
      : geo.glasses
      ? kPlaceDefaultAccuracyGlassesM
      : kPlaceDefaultAccuracyCameraM;
  final radius = (kPlaceRadiusFactor * acc)
      .clamp(kPlaceMinRadiusM.toDouble(), kPlaceMaxRadiusM.toDouble())
      .round();
  final sigma = math.max(acc, kPlaceMinSigmaM);
  final delta = geo.fixDeltaS;
  final PlaceMatchReason? reason = acc > kPlaceMaxAccuracyM
      ? PlaceMatchReason.inaccurate
      : delta != null && delta.abs() > kPlaceMaxFixDeltaS
      ? PlaceMatchReason.stale
      : null;
  return PlaceGate._(
    reason: reason,
    verified: reason == null && (delta != null || !geo.glasses),
    accuracyM: acc,
    radiusM: radius,
    sigmaM: sigma,
  );
}

/// A ~100 m cell: latitude and longitude rounded to 3 decimals (about
/// 111 m north–south, less east–west away from the equator). The only form
/// in which a place the user taught is kept, and only in the
/// backup-excluded store (services/assist/assist_places_store.dart). Never
/// exported, sent or shown; its [toString] says nothing.
final class PlaceCell {
  const PlaceCell._(this._latE3, this._lonE3);

  /// Thousandths of a degree.
  final int _latE3;
  final int _lonE3;

  static const int _fullTurnE3 = 360000;
  static const int _halfTurnE3 = 180000;
  static const int _quarterTurnE3 = 90000;

  /// −180° and 180° are the same meridian: always written as 180.
  static PlaceCell _of(int latE3, int lonE3) =>
      PlaceCell._(latE3, lonE3 == -_halfTurnE3 ? _halfTurnE3 : lonE3);

  /// The cell holding [lat], [lon] (degrees); null when they are not a
  /// position.
  static PlaceCell? fromLatLon(double lat, double lon) {
    if (!lat.isFinite || !lon.isFinite) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return _of((lat * 1000).round(), (lon * 1000).round());
  }

  static final RegExp _wireRe = RegExp(
    r'^(-?)(\d{1,2})\.(\d{3}),(-?)(\d{1,3})\.(\d{3})$',
  );

  /// A stored cell ([wire]); null for anything else.
  static PlaceCell? tryParse(Object? wire) {
    if (wire is! String) return null;
    final m = _wireRe.firstMatch(wire);
    if (m == null) return null;
    int e3(String sign, String whole, String frac) =>
        (sign == '-' ? -1 : 1) * (int.parse(whole) * 1000 + int.parse(frac));
    final lat = e3(m[1]!, m[2]!, m[3]!);
    final lon = e3(m[4]!, m[5]!, m[6]!);
    if (lat.abs() > _quarterTurnE3 || lon.abs() > _halfTurnE3) return null;
    return _of(lat, lon);
  }

  static String _e3(int v) {
    final a = v.abs();
    return '${v < 0 ? '-' : ''}${a ~/ 1000}.'
        '${(a % 1000).toString().padLeft(3, '0')}';
  }

  /// The stored form: "lat,lon" with 3 decimals each ("43.075,-89.384").
  String get wire => '${_e3(_latE3)},${_e3(_lonE3)}';

  /// This cell or one of the 8 around it (across the 180° meridian too).
  bool isNear(PlaceCell other) {
    if ((_latE3 - other._latE3).abs() > 1) return false;
    var dLon = (_lonE3 - other._lonE3).abs();
    if (dLon > _halfTurnE3) dLon = _fullTurnE3 - dLon;
    return dLon <= 1;
  }

  @override
  bool operator ==(Object other) =>
      other is PlaceCell && other._latE3 == _latE3 && other._lonE3 == _lonE3;

  @override
  int get hashCode => Object.hash(_latE3, _lonE3);

  /// No numbers: a cell that reaches a log says nothing about where.
  @override
  String toString() => 'PlaceCell(redacted)';
}

/// A chain the user confirmed or blocked in a cell.
final class LearnedChainCell {
  const LearnedChainCell(this.chainKey, this.cell);

  final String chainKey;
  final PlaceCell cell;

  @override
  String toString() => 'LearnedChainCell($chainKey)';
}

/// What the user taught the assist about places (the 'assist_places'
/// document, read through AssistPlacesStore).
final class LearnedPlaces {
  const LearnedPlaces({
    this.zones = const [],
    this.confirmed = const [],
    this.blocked = const [],
  });

  static const LearnedPlaces empty = LearnedPlaces();

  /// 'Not from a restaurant': no place match near these cells.
  final List<PlaceCell> zones;

  /// 'Correct', or an accepted location suggestion.
  final List<LearnedChainCell> confirmed;

  /// 'Wrong restaurant'.
  final List<LearnedChainCell> blocked;

  bool get isEmpty => zones.isEmpty && confirmed.isEmpty && blocked.isEmpty;

  /// [cell] is in, or next to, a 'Not from a restaurant' zone.
  bool inZone(PlaceCell cell) => zones.any(cell.isNear);

  /// The chains confirmed in or next to [cell].
  Set<String> confirmedNear(PlaceCell cell) => {
    for (final e in confirmed)
      if (e.cell.isNear(cell)) e.chainKey,
  };

  /// The chains blocked in or next to [cell].
  Set<String> blockedNear(PlaceCell cell) => {
    for (final e in blocked)
      if (e.cell.isNear(cell)) e.chainKey,
  };
}

// ─── The match ─────────────────────────────────────────────────────────

/// Why a match came out as it did. [wire] is the decision log's code
/// (prefixed so it never reads as one of decideAssist's reasons).
enum PlaceMatchReason {
  /// One chain auto-picked.
  picked('place_picked'),

  /// Chain candidates, none clear enough to pick.
  ambiguous('place_ambiguous'),

  /// Chain candidates in a dense spot: never picked.
  dense('place_dense'),

  /// Places, but none is a chain in the table.
  noChain('place_no_chain'),

  /// The only chains here are ones the user blocked here.
  chainBlocked('place_chain_blocked'),

  /// No place within the radius.
  noPlaces('place_no_places'),

  /// Inside a 'Not from a restaurant' zone.
  zone('place_zone'),

  /// The fix is less accurate than [kPlaceMaxAccuracyM].
  inaccurate('place_inaccurate'),

  /// The fix is more than [kPlaceMaxFixDeltaS] from the photo.
  stale('place_stale'),

  /// Not a restaurant meal: the location says nothing about it.
  notRestaurant('place_not_restaurant');

  const PlaceMatchReason(this.wire);
  final String wire;
}

/// The outcome of [matchPlaces]. Chain keys and a cell only: no place
/// names, distances or coordinates.
final class PlaceMatch {
  const PlaceMatch._({
    required this.reason,
    required this.cell,
    required this.verified,
    this.picked,
    this.candidates = const [],
    this.dense = false,
    this.confirmed = const {},
    this.blocked = const {},
  });

  final PlaceMatchReason reason;

  /// The auto-picked chain (AssistContext.placeChainKey), or null.
  final String? picked;

  /// Table chain keys, best first, at most [kLookupMaxChains]
  /// (AssistContext.locationChainKeys).
  final List<String> candidates;

  /// The dense-area guard tripped (AssistContext.dense).
  final bool dense;

  /// The fix is trusted (AssistContext.placeVerified).
  final bool verified;

  /// The photo's cell: where a 'Correct', 'Wrong restaurant' or 'Not from
  /// a restaurant' answer about this meal is recorded.
  final PlaceCell cell;

  /// Of [candidates], those the user confirmed here
  /// (AssistContext.confirmedChainKeys).
  final Set<String> confirmed;

  /// Chains the user blocked here (AssistContext.blockedChainKeys).
  final Set<String> blocked;

  /// The chains a lookup request may name from the location
  /// (data_contracts §4): the pick alone when there is one, else the
  /// candidates.
  List<String> get lookupChainKeys => picked != null ? [picked!] : candidates;

  @override
  String toString() =>
      'PlaceMatch(${reason.wire}, '
      '${candidates.length} candidate(s), dense: $dense, '
      'verified: $verified)';
}

final class _Scored {
  const _Scored(this.chainKey, this.distanceM, this.score);
  final String? chainKey;
  final int distanceM;
  final double score;
}

/// Matches a restaurant meal's photo against the food [places] around it
/// (see the library doc). [cell] is the photo's cell, [geo] its fix
/// quality, [context] the meal's restaurant_context, [learned] what the
/// user taught. Neither [places] nor anything derived from them beyond
/// chain keys outlives the call.
PlaceMatch matchPlaces({
  required PhotoGeo geo,
  required PlaceCell cell,
  required RestaurantContext? context,
  required Iterable<PlacePoi> places,
  LearnedPlaces learned = LearnedPlaces.empty,
}) {
  final gate = placeGate(geo);
  final blockedHere = learned.blockedNear(cell);
  PlaceMatch none(PlaceMatchReason reason, {bool dense = false}) =>
      PlaceMatch._(
        reason: reason,
        cell: cell,
        verified: gate.verified,
        dense: dense,
        blocked: blockedHere,
      );

  if (context != RestaurantContext.restaurant) {
    return none(PlaceMatchReason.notRestaurant);
  }
  if (!gate.passes) return none(gate.reason!);
  if (learned.inZone(cell)) return none(PlaceMatchReason.zone);

  final sigma = gate.sigmaM;
  final scored = <_Scored>[
    for (final p in places)
      if (p.distanceM >= 0 && p.distanceM <= gate.radiusM)
        _Scored(
          matchChain(p.name, urlHost: p.urlHost),
          p.distanceM,
          placeCategoryWeight(p.categoryWire) *
              math.exp(-(p.distanceM * p.distanceM) / (2 * sigma * sigma)),
        ),
  ];
  if (scored.isEmpty) return none(PlaceMatchReason.noPlaces);

  final withinSigma = [
    for (final s in scored)
      if (s.distanceM <= sigma) s,
  ];
  final chainsWithinSigma = {for (final s in withinSigma) ?s.chainKey};
  final dense =
      withinSigma.length >= kPlaceDenseMinPlaces ||
      chainsWithinSigma.length >= kPlaceDenseMinChains;

  // Each chain at its best-scoring entry (MapKit can list one twice).
  final best = <String, _Scored>{};
  for (final s in scored) {
    final key = s.chainKey;
    if (key == null) continue;
    final b = best[key];
    if (b == null ||
        s.score > b.score ||
        (s.score == b.score && s.distanceM < b.distanceM)) {
      best[key] = s;
    }
  }
  if (best.isEmpty) return none(PlaceMatchReason.noChain, dense: dense);

  // The pick: geometry alone; blocked chains still count as rivals.
  String? picked;
  if (!dense) {
    final near = {
      for (final s in scored)
        if (s.distanceM <= kPlacePickUniqueSigmas * sigma) ?s.chainKey,
    };
    if (near.length == 1 && !blockedHere.contains(near.single)) {
      final key = near.single;
      final top = best[key]!.score;
      var runnerUp = 0.0;
      for (final s in scored) {
        if (s.chainKey != key && s.score > runnerUp) runnerUp = s.score;
      }
      if (top >= kPlacePickMinScore && top >= kPlacePickMinLead * runnerUp) {
        picked = key;
      }
    }
  }

  final confirmedHere = learned.confirmedNear(cell);
  int rank(String key) => key == picked
      ? 0
      : confirmedHere.contains(key)
      ? 1
      : 2;
  final ranked =
      [
        for (final key in best.keys)
          if (!blockedHere.contains(key)) key,
      ]..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        final sa = best[a]!, sb = best[b]!;
        final byScore = sb.score.compareTo(sa.score);
        if (byScore != 0) return byScore;
        final byDistance = sa.distanceM.compareTo(sb.distanceM);
        return byDistance != 0 ? byDistance : a.compareTo(b);
      });
  if (ranked.isEmpty) {
    return none(PlaceMatchReason.chainBlocked, dense: dense);
  }
  final candidates = List<String>.unmodifiable(ranked.take(kLookupMaxChains));
  return PlaceMatch._(
    reason: picked != null
        ? PlaceMatchReason.picked
        : dense
        ? PlaceMatchReason.dense
        : PlaceMatchReason.ambiguous,
    cell: cell,
    verified: gate.verified,
    picked: picked,
    candidates: candidates,
    dense: dense,
    confirmed: Set.unmodifiable({
      for (final key in candidates)
        if (confirmedHere.contains(key)) key,
    }),
    blocked: Set.unmodifiable(blockedHere),
  );
}
