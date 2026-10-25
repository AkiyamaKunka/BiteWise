/// Food places near a photo's position (design R4, restaurant assist,
/// 2026-10-24).
///
/// On iOS, [MapKitPlaces] asks Apple Maps on the phone
/// (ios/Runner/PlacesPlugin.swift, channel 'dev.calorietracker/places')
/// for the restaurants, cafes, bakeries and bars around a [PhotoPoint].
/// The coordinates go to Apple only, as when using Maps; no location
/// permission is involved. The places come back nearest first and stay in
/// memory for one chain match (R2c): their names are compared with
/// BiteWise's own US chain table, and only that table's canonical name can
/// ever reach an AI recipient. Nothing returned here is stored, exported,
/// logged or shown (Apple developer license, Attachment 6 §2.4–2.5), so
/// [NearbyPlace.toString] leaves the name out.
///
/// Android has no places in v1: [NullPlaces] answers unsupported.
///
/// Every call answers; none throws. A missing plugin, a platform error, a
/// timeout or a reply of the wrong shape all come back as
/// [PlacesStatus.error].
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

import '../../core/place_match.dart' show PlacePoi;
import '../photo/photo_location.dart' show PhotoPoint;

/// ios/Runner/PlacesPlugin.swift.
const String placesChannelName = 'dev.calorietracker/places';

/// What a query found. The native side's strings, one for one.
enum PlacesStatus {
  /// At least one place; [NearbyFood.places] holds them, nearest first.
  ok,

  /// Nothing there (MapKit's placemarkNotFound, MKError 4).
  none,

  /// Too many requests (MapKit's loadingThrottled, MKError 3), or this
  /// side's own limit: try again later.
  throttled,

  /// Anything else that went wrong; [NearbyFood.errorCode] says what.
  error,

  /// No places on this platform, or none of the categories asked for
  /// exists on this OS.
  unsupported,
}

const Map<String, PlacesStatus> _statuses = {
  'ok': PlacesStatus.ok,
  'none': PlacesStatus.none,
  'throttled': PlacesStatus.throttled,
  'error': PlacesStatus.error,
  'unsupported': PlacesStatus.unsupported,
};

/// The MapKit categories the channel searches (placesCategoryTable in the
/// Swift file). [other] is only an answer: a place listed under a category
/// outside this table, or under none.
enum PlaceCategory {
  restaurant('restaurant'),
  cafe('cafe'),
  bakery('bakery'),
  brewery('brewery'),
  winery('winery'),
  nightlife('nightlife'),

  /// iOS 18+; left out of the search on older systems.
  distillery('distillery'),

  /// Food markets, supermarkets, grocery and convenience stores: only when
  /// asked for, since a meal is rarely bought and eaten there.
  foodMarket('food_market'),
  other('other');

  const PlaceCategory(this.wire);

  /// The channel's name for it.
  final String wire;

  static PlaceCategory fromWire(String wire) =>
      values.firstWhere((c) => c.wire == wire, orElse: () => other);
}

/// What [PlaceResolver.nearbyFood] searches unless told otherwise: every
/// category but food markets.
const Set<PlaceCategory> defaultFoodCategories = {
  PlaceCategory.restaurant,
  PlaceCategory.cafe,
  PlaceCategory.bakery,
  PlaceCategory.brewery,
  PlaceCategory.winery,
  PlaceCategory.nightlife,
  PlaceCategory.distillery,
};

/// The search radius' bounds, in metres (NearbyFoodQuery in the Swift
/// file clamps the same way).
const int placesMinRadiusM = 40;
const int placesMaxRadiusM = 300;

/// The most places one answer carries.
const int placesMaxPlaces = 50;

/// One place MapKit listed. Apple's Map Data: kept in memory for one
/// match (core/place_match.dart matchPlaces takes these as they are),
/// never stored, logged or shown.
@immutable
class NearbyPlace implements PlacePoi {
  const NearbyPlace({
    required this.name,
    required this.category,
    required this.distanceM,
    this.urlHost,
  });

  /// As Apple Maps names it, in the phone's language (Starbucks comes back
  /// as 星巴克咖啡公司 under zh-Hans), so chain matching also uses
  /// [urlHost].
  @override
  final String name;
  final PlaceCategory category;

  @override
  String get categoryWire => category.wire;

  /// From the photo's position, whole metres.
  @override
  final int distanceM;

  /// The place's website host, lowercase ASCII (e.g. www.starbucks.com);
  /// null when it lists none.
  @override
  final String? urlHost;

  /// No name: logs and error messages never carry Map Data.
  @override
  String toString() => 'NearbyPlace(${category.wire})';
}

/// A query's answer.
@immutable
class NearbyFood {
  const NearbyFood(this.status, {this.places = const [], this.errorCode});

  final PlacesStatus status;

  /// Nearest first; empty unless [status] is ok.
  final List<NearbyPlace> places;
  final String? errorCode;

  @override
  String toString() => 'NearbyFood(${status.name}, ${places.length}'
      '${errorCode == null ? '' : ', $errorCode'})';
}

/// The error codes this side adds to the native ones (`timeout`,
/// `bad_arguments` and `<NSError domain>:<code>`).
const String placesMalformed = 'malformed';
const String placesMissingPlugin = 'missing_plugin';
const String placesTimeout = 'timeout';

/// [PlacesStatus.throttled] codes for calls this side turned away without
/// asking MapKit.
const String placesRateLimited = 'rate_limited';
const String placesBackoff = 'backoff';

abstract class PlaceResolver {
  /// Food places within [radiusM] metres of [point] (clamped to
  /// [placesMinRadiusM]–[placesMaxRadiusM]), in [categories] (the
  /// defaults when empty). [point] is not kept.
  Future<NearbyFood> nearbyFood(PhotoPoint point,
      {int radiusM = 100, Set<PlaceCategory> categories = defaultFoodCategories});
}

/// Android (and anything else that is not iOS): no places in v1.
class NullPlaces implements PlaceResolver {
  const NullPlaces();

  @override
  Future<NearbyFood> nearbyFood(PhotoPoint point,
          {int radiusM = 100,
          Set<PlaceCategory> categories = defaultFoodCategories}) async =>
      const NearbyFood(PlacesStatus.unsupported);
}

/// Apple Maps on iOS; [NullPlaces] elsewhere.
PlaceResolver platformPlaceResolver({bool? isIOS}) =>
    (isIOS ?? Platform.isIOS) ? MapKitPlaces() : const NullPlaces();

/// How long a call may take before it counts as an error. The native search
/// gives up after 3 s; the rest is the hop back.
const Duration placesCallTimeout = Duration(seconds: 5);

/// This side's own limit, well under MapKit's (about 50 requests a minute
/// before it throttles, live probe 2026-10-23): a bucket of 30 calls that
/// refills at 30 a minute.
const int placesBucketSize = 30;
const Duration placesBucketRefill = Duration(minutes: 1);

/// After MapKit throttles, no call for this long.
const Duration placesThrottleBackoff = Duration(seconds: 60);

/// The channel to PlacesPlugin.swift, with a token bucket in front of it
/// and a back-off after MapKit throttles. One instance per app engine, so
/// the limits are shared by every caller in it.
class MapKitPlaces implements PlaceResolver {
  MapKitPlaces(
      {this._channel = const MethodChannel(placesChannelName),
      DateTime Function()? clock,
      this.timeout = placesCallTimeout})
      : _clock = clock ?? DateTime.now;

  final MethodChannel _channel;
  final DateTime Function() _clock;
  final Duration timeout;

  double _tokens = placesBucketSize.toDouble();
  DateTime? _refilledAt;
  DateTime? _backoffUntil;

  /// Takes one call's token: refills what [placesBucketRefill] gave back
  /// since the last time first. A clock that went backwards refills
  /// nothing and restarts from now.
  bool _takeToken(DateTime now) {
    final last = _refilledAt;
    if (last != null) {
      final elapsed = now.difference(last);
      if (!elapsed.isNegative) {
        _tokens = (_tokens +
                elapsed.inMicroseconds /
                    placesBucketRefill.inMicroseconds *
                    placesBucketSize)
            .clamp(0.0, placesBucketSize.toDouble());
      }
    }
    _refilledAt = now;
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }

  /// Whether a back-off is still running. One further away than a whole
  /// back-off means the clock went backwards: dropped.
  bool _backingOff(DateTime now) {
    final until = _backoffUntil;
    if (until == null) return false;
    if (!now.isBefore(until) ||
        until.difference(now) > placesThrottleBackoff) {
      _backoffUntil = null;
      return false;
    }
    return true;
  }

  @override
  Future<NearbyFood> nearbyFood(PhotoPoint point,
      {int radiusM = 100,
      Set<PlaceCategory> categories = defaultFoodCategories}) async {
    final now = _clock();
    if (_backingOff(now)) {
      return const NearbyFood(PlacesStatus.throttled, errorCode: placesBackoff);
    }
    if (!_takeToken(now)) {
      return const NearbyFood(PlacesStatus.throttled,
          errorCode: placesRateLimited);
    }
    final asked = categories.where((c) => c != PlaceCategory.other).toSet();
    final wire = [
      for (final c in PlaceCategory.values)
        if ((asked.isEmpty ? defaultFoodCategories : asked).contains(c)) c.wire,
    ];
    final (reply, failure) = await _invoke({
      'lat': point.lat,
      'lon': point.lon,
      'radius_m': radiusM.clamp(placesMinRadiusM, placesMaxRadiusM),
      'categories': wire,
    });
    final answer = failure != null
        ? NearbyFood(PlacesStatus.error, errorCode: failure)
        : decodeNearbyFood(reply);
    if (answer.status == PlacesStatus.throttled) {
      _backoffUntil = _clock().add(placesThrottleBackoff);
    }
    return answer;
  }

  /// The raw reply, or the error code for why there is none.
  Future<(Object?, String?)> _invoke(Map<String, Object?> args) async {
    try {
      return await _channel
          .invokeMethod<Object?>('nearbyFood', args)
          .then<(Object?, String?)>((v) => (v, null))
          .timeout(timeout, onTimeout: () => (null, placesTimeout));
    } on MissingPluginException {
      return (null, placesMissingPlugin);
    } on PlatformException catch (e) {
      return (null, 'platform:${e.code}');
    } catch (_) {
      return (null, 'exception');
    }
  }
}

/// A plain lowercase ASCII hostname with at least one dot, as the native
/// side sends it.
final RegExp _hostShape =
    RegExp(r'^(?=.{1,253}$)[a-z0-9-]+(\.[a-z0-9-]+)+$');

const NearbyFood _malformed =
    NearbyFood(PlacesStatus.error, errorCode: placesMalformed);

/// nearbyFood's reply → its answer. Anything off the contract is an error
/// as a whole, never a partial list: a place dropped from the list could
/// make a crowded street look like a lone restaurant to the chain match.
@visibleForTesting
NearbyFood decodeNearbyFood(Object? reply) {
  if (reply is! Map) return _malformed;
  final status = _statuses[reply['status']];
  if (status == null) return _malformed;
  final rawPlaces = reply['places'] ?? const [];
  if (rawPlaces is! List) return _malformed;
  final rawCode = reply['error_code'];
  String? errorCode;
  if (rawCode is String && rawCode.isNotEmpty) {
    errorCode = rawCode.length > 80 ? rawCode.substring(0, 80) : rawCode;
  } else if (rawCode is int) {
    errorCode = '$rawCode';
  } else if (rawCode != null) {
    return _malformed;
  }
  if (status != PlacesStatus.ok) {
    if (rawPlaces.isNotEmpty) return _malformed;
    return NearbyFood(status,
        errorCode: status == PlacesStatus.error ? errorCode : null);
  }
  if (rawPlaces.length > placesMaxPlaces) return _malformed;
  // The native side answers none for an empty area; an empty ok says the
  // same.
  if (rawPlaces.isEmpty) return const NearbyFood(PlacesStatus.none);
  final places = <NearbyPlace>[];
  for (final raw in rawPlaces) {
    final place = _decodePlace(raw);
    if (place == null) return _malformed;
    if (places.isNotEmpty && place.distanceM < places.last.distanceM) {
      return _malformed; // not nearest first
    }
    places.add(place);
  }
  return NearbyFood(PlacesStatus.ok, places: List.unmodifiable(places));
}

NearbyPlace? _decodePlace(Object? raw) {
  if (raw is! Map) return null;
  final name = raw['name'];
  final category = raw['category'];
  final distance = raw['distance_m'];
  final host = raw['url_host'];
  // The native side keeps 120 characters; in UTF-16 units that can be a
  // few times more.
  if (name is! String || name.trim().isEmpty || name.length > 1000) {
    return null;
  }
  if (category is! String) return null;
  if (distance is! int || distance < 0) return null;
  if (host != null && (host is! String || !_hostShape.hasMatch(host))) {
    return null;
  }
  return NearbyPlace(
    name: name,
    category: PlaceCategory.fromWire(category),
    distanceM: distance,
    urlHost: host as String?,
  );
}
