/// core/place_match.dart: which nearby chain a restaurant meal's photo was
/// taken at (restaurant assist, R2c). The fix gate, the radius and σ, the
/// dense guard, the auto-pick, zones, blocks and confirmations — and that a
/// match carries chain keys and a redacted cell only.
///
/// Fixtures follow the live MapKit probe of 2026-10-23 (scratchpad
/// lane_places; research "Live MapKit probe"). The probe kept names and
/// counts, not distances, so every distance below is spread to reproduce
/// the probe's counts (13 places within 60 m at Times Square, 47 at the
/// Mall of America, one place 34 m from a Madison home, one place at
/// 102 m at Chicago Union Station), never copied from Apple's results.
library;

import 'package:calorie_tracker/core/coerce.dart' show RestaurantContext;
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/place_match.dart';
import 'package:calorie_tracker/core/restaurant_lookup_contract.dart'
    show kLookupMaxChains;
import 'package:calorie_tracker/services/photo/glasses.dart'
    show captureAnalysis;
import 'package:calorie_tracker/services/places/places.dart';
import 'package:flutter_test/flutter_test.dart';

NearbyPlace _poi(
  String name,
  int distanceM, {
  String category = 'restaurant',
  String? host,
}) => NearbyPlace(
  name: name,
  category: PlaceCategory.fromWire(category),
  distanceM: distanceM,
  urlHost: host,
);

/// Public landmarks only.
final PlaceCell _timesSquare = PlaceCell.fromLatLon(40.7580, -73.9855)!;
final PlaceCell _mallOfAmerica = PlaceCell.fromLatLon(44.8549, -93.2422)!;
final PlaceCell _unionStation = PlaceCell.fromLatLon(41.8789, -87.6402)!;
final PlaceCell _capitolSquare = PlaceCell.fromLatLon(43.0747, -89.3842)!;

/// The cell [dLat], [dLon] thousandths of a degree from [from].
PlaceCell _shift(PlaceCell from, int dLat, int dLon) {
  final parts = from.wire.split(',');
  final lat = double.parse(parts[0]) + dLat / 1000;
  final lon = double.parse(parts[1]) + dLon / 1000;
  return PlaceCell.fromLatLon(lat, lon)!;
}

/// Times Square: the probe's 13 places within 60 m (lane_places/ts_60.txt).
final List<NearbyPlace> _timesSquare60 = [
  _poi('Anita Gelato', 6, category: 'cafe'),
  _poi('Edawy Bro', 11),
  _poi("McDonald's", 15),
  _poi('Cbre 1540 Broadway', 19), // an office MapKit files as a restaurant
  _poi('Starbucks Coffee Company', 24, category: 'cafe'),
  _poi('Asian Street Eats', 28),
  _poi('Popeyes Louisiana Kitchen', 33),
  _poi("I'm donut ?", 37, category: 'bakery'),
  _poi('Ora’s Market', 41, category: 'food_market'),
  _poi('Tenders', 46),
  _poi('The Lodge', 50, category: 'nightlife'),
  _poi('Wing Squad', 54),
  _poi('The Vieux Restaurante & Lounge en El Hotel Marriot Marquise', 58),
];

/// Mall of America: 47 places, each at its own spot 12–40 m from the next,
/// all sharing one street address (the probe's shape). A typical food
/// court's chains, the rest stalls.
final List<NearbyPlace> _mallOfAmerica47 = [
  _poi('Panda Express', 12),
  _poi('Cinnabon', 16, category: 'bakery'),
  _poi("Auntie Anne's", 21, category: 'bakery'),
  _poi('Starbucks Coffee Company', 26, category: 'cafe'),
  _poi('Shake Shack', 30),
  for (var i = 0; i < 42; i++) _poi('Food court stall $i', 33 + i * 3),
];

/// Union Station, Chicago: 10 places for a 100 m query, one of them at
/// 102 m, just outside (MapKit returned it anyway).
final List<NearbyPlace> _unionStation10 = [
  _poi('Concourse Deli', 18),
  _poi('Great Hall Cafe', 35, category: 'cafe'),
  _poi('Platform Pizza', 47),
  _poi('Canal Street Grill', 58),
  _poi('Station Noodles', 66),
  _poi('Metra Bagels', 73, category: 'bakery'),
  _poi('Track 9 Tavern', 81, category: 'nightlife'),
  _poi('Amtrak Lounge Snacks', 88),
  _poi('Riverside Tacos', 95),
  _poi("Auntie Anne's", 102, category: 'bakery'),
];

PlaceMatch _match(
  List<PlacePoi> places, {
  PhotoGeo geo = const PhotoGeo(accuracyM: 10),
  PlaceCell? cell,
  RestaurantContext? context = RestaurantContext.restaurant,
  LearnedPlaces learned = LearnedPlaces.empty,
}) => matchPlaces(
  geo: geo,
  cell: cell ?? _capitolSquare,
  context: context,
  places: places,
  learned: learned,
);

void main() {
  group('the probe fixtures', () {
    test('Times Square, 13 places within 60 m: dense, never picked', () {
      // A camera photo without a recorded accuracy: 30 m, so σ 30 and a
      // 60 m query.
      final m = _match(
        _timesSquare60,
        geo: const PhotoGeo(),
        cell: _timesSquare,
      );
      expect(m.dense, isTrue);
      expect(m.picked, isNull);
      expect(m.reason, PlaceMatchReason.dense);
      expect(m.candidates, ['mcdonalds', 'starbucks', 'popeyes']);
      expect(
        m.lookupChainKeys,
        m.candidates,
        reason: 'no pick: up to 3 candidates go into the request',
      );
      expect(m.verified, isTrue);

      // A sharp fix (σ 20, 40 m) is just as crowded.
      final sharp = _match(
        _timesSquare60,
        geo: const PhotoGeo(accuracyM: 8),
        cell: _timesSquare,
      );
      expect(sharp.dense, isTrue);
      expect(sharp.picked, isNull);
    });

    test('Mall of America, one shared address: dense', () {
      final m = _match(
        _mallOfAmerica47,
        geo: const PhotoGeo(accuracyM: 35),
        cell: _mallOfAmerica,
      );
      expect(m.dense, isTrue);
      expect(m.picked, isNull);
      expect(m.candidates, hasLength(kLookupMaxChains));
      expect(m.candidates.first, 'panda_express');
    });

    test('a Madison home business 34 m away is no chain: no match', () {
      final m = _match(
        [_poi('curador bitters co', 34, category: 'food_market')],
        geo: const PhotoGeo(),
        cell: _capitolSquare,
      );
      expect(m.reason, PlaceMatchReason.noChain);
      expect(m.candidates, isEmpty);
      expect(m.picked, isNull);
      expect(m.dense, isFalse);
      expect(m.lookupChainKeys, isEmpty);
      // And a meal the photo model calls home-cooked never gets that far.
      expect(
        _match([
          _poi('curador bitters co', 34, category: 'food_market'),
        ], context: RestaurantContext.home).reason,
        PlaceMatchReason.notRestaurant,
      );
    });

    test('Union Station, a place at 102 m is outside a 100 m query', () {
      const geo = PhotoGeo(accuracyM: 50); // radius 100, σ 50
      expect(placeGate(geo).radiusM, 100);
      final m = _match(_unionStation10, geo: geo, cell: _unionStation);
      expect(
        m.candidates,
        isEmpty,
        reason: "Auntie Anne's at 102 m is not a candidate",
      );
      expect(m.reason, PlaceMatchReason.noChain);
      expect(m.dense, isTrue, reason: '3 places within σ = 50 m');

      // The same place at 98 m is inside.
      final inside = _match(
        [
          ..._unionStation10.take(9),
          _poi("Auntie Anne's", 98, category: 'bakery'),
        ],
        geo: geo,
        cell: _unionStation,
      );
      expect(inside.candidates, ['auntie_annes']);
      expect(inside.picked, isNull);
    });
  });

  group('the gate', () {
    test('unknown accuracy: 30 m for a camera photo, 65 m for glasses', () {
      final camera = placeGate(const PhotoGeo());
      expect(camera.accuracyM, kPlaceDefaultAccuracyCameraM);
      expect(camera.radiusM, 60);
      expect(camera.sigmaM, 30);
      expect(camera.passes, isTrue);
      expect(camera.verified, isTrue, reason: 'no fix time: camera is fresh');

      final glasses = placeGate(const PhotoGeo(glasses: true));
      expect(glasses.accuracyM, kPlaceDefaultAccuracyGlassesM);
      expect(glasses.radiusM, 130);
      expect(glasses.sigmaM, 65);
      expect(glasses.passes, isTrue);
      expect(
        glasses.verified,
        isFalse,
        reason: 'no fix time: a glasses photo is unverified',
      );
      expect(
        placeGate(const PhotoGeo(glasses: true, fixDeltaS: 90)).verified,
        isTrue,
      );
    });

    test('radius = clamp(2 × accuracy, 40, 150); σ = max(accuracy, 20)', () {
      for (final (acc, radius, sigma) in [
        (0.0, 40, 20.0),
        (5.0, 40, 20.0),
        (20.0, 40, 20.0),
        (33.0, 66, 33.0),
        (75.0, 150, 75.0),
        (90.0, 150, 90.0),
        (100.0, 150, 100.0),
      ]) {
        final g = placeGate(PhotoGeo(accuracyM: acc));
        expect(g.radiusM, radius, reason: 'accuracy $acc');
        expect(g.sigmaM, sigma, reason: 'accuracy $acc');
        expect(g.passes, isTrue, reason: 'accuracy $acc');
      }
    });

    test('accuracy over 100 m: not used at all', () {
      final g = placeGate(const PhotoGeo(accuracyM: 101));
      expect(g.passes, isFalse);
      expect(g.reason, PlaceMatchReason.inaccurate);
      expect(g.verified, isFalse);
      final m = _match([
        _poi('Chipotle Mexican Grill', 5),
      ], geo: const PhotoGeo(accuracyM: 101));
      expect(m.reason, PlaceMatchReason.inaccurate);
      expect(m.candidates, isEmpty);
      expect(m.picked, isNull);
    });

    test('a fix more than 10 min from the photo: not used at all', () {
      for (final delta in [600, -600]) {
        expect(
          placeGate(PhotoGeo(accuracyM: 10, fixDeltaS: delta)).passes,
          isTrue,
          reason: '$delta s',
        );
      }
      for (final glasses in [false, true]) {
        for (final delta in [601, -601, 5 * 3600]) {
          final g = placeGate(
            PhotoGeo(accuracyM: 10, fixDeltaS: delta, glasses: glasses),
          );
          expect(g.reason, PlaceMatchReason.stale, reason: '$delta s');
          expect(g.verified, isFalse);
        }
      }
      final m = _match([
        _poi('Chipotle Mexican Grill', 5),
      ], geo: const PhotoGeo(accuracyM: 10, fixDeltaS: 900));
      expect(m.reason, PlaceMatchReason.stale);
      expect(m.candidates, isEmpty);
    });

    test('freshness compares UTC instants, not wall clocks', () {
      // 19:30 in Chicago (UTC−5) is 00:30Z the next day. The library's
      // creation date is an instant; the EXIF GPS stamp is UTC.
      final created = DateTime.utc(2026, 10, 25, 0, 30).toLocal();
      Map<String, Object> capture(DateTime fixUtc, {bool glasses = false}) =>
          captureAnalysis(
            CaptureMeta(
              device: glasses
                  ? CaptureDevice.metaGlasses
                  : CaptureDevice.unknown,
              strength: glasses ? CaptureStrength.strong : CaptureStrength.none,
              signal: glasses ? CaptureSignal.filename : null,
              exif: ExifCapture(
                gpsPresent: true,
                gpsAccuracyM: 12.4,
                gpsFixUtc: fixUtc,
              ),
              createDate: created,
            ),
          );

      // Fixed 3 min after the shutter: fresh, whatever this machine's zone.
      final fresh = PhotoGeo.fromCapture(
        capture(DateTime.utc(2026, 10, 25, 0, 33)),
        glasses: true,
      );
      expect(fresh.fixDeltaS, 180);
      expect(fresh.accuracyM, 12);
      expect(placeGate(fresh).verified, isTrue);

      // The same wall clock read as if it were UTC is 5 h off: stale.
      final wallClock = PhotoGeo.fromCapture(
        capture(DateTime.utc(2026, 10, 24, 19, 33)),
        glasses: true,
      );
      expect(wallClock.fixDeltaS, -(4 * 3600 + 57 * 60));
      expect(placeGate(wallClock).reason, PlaceMatchReason.stale);

      // No GPS time: glasses unverified, camera fresh.
      final noFix = captureAnalysis(
        CaptureMeta(
          exif: const ExifCapture(gpsPresent: true),
          createDate: created,
        ),
      );
      expect(
        placeGate(PhotoGeo.fromCapture(noFix, glasses: true)).verified,
        isFalse,
      );
      expect(
        placeGate(PhotoGeo.fromCapture(noFix, glasses: false)).verified,
        isTrue,
      );
    });

    test('analysis.capture is untrusted: anything off-contract is unknown', () {
      for (final capture in [
        null,
        'capture',
        <String, Object?>{},
        {'gps_acc_m': '12', 'gps_fix_delta_s': '30'},
        {'gps_acc_m': -3, 'gps_fix_delta_s': 12.5},
        {'gps_acc_m': double.nan, 'gps_fix_delta_s': double.infinity},
        {'gps_acc_m': true, 'gps_fix_delta_s': false},
      ]) {
        final geo = PhotoGeo.fromCapture(capture, glasses: false);
        expect(geo.accuracyM, isNull, reason: '$capture');
        expect(geo.fixDeltaS, isNull, reason: '$capture');
      }
      final ok = PhotoGeo.fromCapture({
        'has_gps': true,
        'gps_acc_m': 14.0,
        'gps_fix_delta_s': -42.0,
      }, glasses: false);
      expect(ok.accuracyM, 14);
      expect(ok.fixDeltaS, -42);
      // A garbage accuracy handed in directly counts as unknown too.
      expect(
        placeGate(const PhotoGeo(accuracyM: double.nan)).accuracyM,
        kPlaceDefaultAccuracyCameraM,
      );
      expect(
        placeGate(const PhotoGeo(accuracyM: -1)).accuracyM,
        kPlaceDefaultAccuracyCameraM,
      );
    });
  });

  group('restaurant meals only', () {
    test('takeout, packaged, home and unknown never match a place', () {
      for (final context in [
        RestaurantContext.takeout,
        RestaurantContext.packaged,
        RestaurantContext.home,
        null,
      ]) {
        final m = _match([_poi('Chipotle Mexican Grill', 5)], context: context);
        expect(m.reason, PlaceMatchReason.notRestaurant, reason: '$context');
        expect(m.candidates, isEmpty);
        expect(m.picked, isNull);
      }
    });

    test('no place within the radius', () {
      expect(_match(const []).reason, PlaceMatchReason.noPlaces);
      // σ 20 → a 40 m query: 41 m is out.
      expect(
        _match([_poi('Chipotle Mexican Grill', 41)]).reason,
        PlaceMatchReason.noPlaces,
      );
    });
  });

  group('the auto-pick', () {
    test('a lone chain close by is picked, and goes alone', () {
      final m = _match([_poi('Chipotle Mexican Grill', 12)]);
      expect(m.reason, PlaceMatchReason.picked);
      expect(m.picked, 'chipotle');
      expect(m.candidates, ['chipotle']);
      expect(m.lookupChainKeys, ['chipotle']);
      expect(m.dense, isFalse);
      expect(m.verified, isTrue);
    });

    test('a lone chain scoring under 0.6 is only a candidate', () {
      // σ 20: exp(−30² / 800) ≈ 0.32.
      final m = _match([_poi('Chipotle Mexican Grill', 30)]);
      expect(m.picked, isNull);
      expect(m.reason, PlaceMatchReason.ambiguous);
      expect(m.candidates, ['chipotle']);
    });

    test('an independent place almost as close blocks the pick', () {
      // 0.88 vs 0.78: not twice the runner-up.
      final m = _match([
        _poi('Chipotle Mexican Grill', 10),
        _poi('La Taqueria', 14),
      ]);
      expect(m.dense, isFalse);
      expect(m.picked, isNull);
      expect(m.candidates, ['chipotle']);

      // 0.92 vs 0.22: picked.
      final clear = _match([
        _poi('Chipotle Mexican Grill', 8),
        _poi('La Taqueria', 35),
      ]);
      expect(clear.picked, 'chipotle');
    });

    test('a second chain within 2σ blocks the pick', () {
      final m = _match([
        _poi('Chipotle Mexican Grill', 8),
        _poi('Qdoba Mexican Eats', 35),
      ]);
      expect(m.dense, isFalse, reason: 'only one of them within σ');
      expect(m.picked, isNull);
      expect(m.reason, PlaceMatchReason.ambiguous);
      expect(m.candidates, ['chipotle', 'qdoba']);
    });

    test('dense: 3 places, or 2 chains, within σ', () {
      final twoChains = _match([
        _poi('Chipotle Mexican Grill', 8),
        _poi('Qdoba Mexican Eats', 15),
      ]);
      expect(twoChains.dense, isTrue);
      expect(twoChains.picked, isNull);
      expect(twoChains.reason, PlaceMatchReason.dense);

      final threePlaces = _match([
        _poi('Chipotle Mexican Grill', 4),
        _poi('Corner Deli', 16),
        _poi('Juice Bar', 19),
      ]);
      expect(threePlaces.dense, isTrue);
      expect(threePlaces.picked, isNull);
      expect(threePlaces.candidates, ['chipotle']);

      final twoPlaces = _match([
        _poi('Chipotle Mexican Grill', 4),
        _poi('Corner Deli', 19),
      ]);
      expect(twoPlaces.dense, isFalse);
    });

    test('a chain listed twice is not its own rival', () {
      final m = _match([
        _poi('Starbucks Coffee Company', 8, category: 'cafe'),
        _poi('Starbucks', 30, category: 'cafe'),
      ]);
      expect(m.picked, 'starbucks');
      expect(m.candidates, ['starbucks']);
    });

    test('the category weighs in', () {
      expect(placeCategoryWeight('restaurant'), kPlaceWeightPrimary);
      expect(placeCategoryWeight('cafe'), kPlaceWeightPrimary);
      expect(placeCategoryWeight('bakery'), kPlaceWeightPrimary);
      for (final c in ['brewery', 'winery', 'distillery', 'nightlife']) {
        expect(placeCategoryWeight(c), kPlaceWeightSecondary, reason: c);
      }
      expect(placeCategoryWeight('food_market'), kPlaceWeightOther);
      expect(placeCategoryWeight('other'), kPlaceWeightOther);
      expect(placeCategoryWeight('teahouse'), kPlaceWeightOther);

      // σ 20, 16 m: 0.73 as a restaurant, 0.58 as a bar.
      expect(
        _match([_poi('Buffalo Wild Wings', 16)]).picked,
        'buffalo_wild_wings',
      );
      expect(
        _match([_poi('Buffalo Wild Wings', 16, category: 'nightlife')]).picked,
        isNull,
      );
    });

    test('chains are matched by name and website host', () {
      // Apple Maps names Starbucks in the phone's language.
      expect(
        _match([
          _poi('星巴克咖啡公司', 9, category: 'cafe', host: 'www.starbucks.com'),
        ]).picked,
        'starbucks',
      );
      // A name and a host that disagree are no chain.
      expect(
        _match([_poi('Starbucks', 9, host: 'www.dunkindonuts.com')]).reason,
        PlaceMatchReason.noChain,
      );
      // A host alone names the chain.
      expect(
        _match([_poi('Store #2381', 9, host: 'locations.chipotle.com')]).picked,
        'chipotle',
      );
    });

    test(
      'an unverified glasses fix still ranks, but is reported unverified',
      () {
        final m = _match([
          _poi('Chipotle Mexican Grill', 12),
        ], geo: const PhotoGeo(accuracyM: 10, glasses: true));
        expect(m.picked, 'chipotle');
        expect(
          m.verified,
          isFalse,
          reason: 'decideAssist never applies on an unverified fix',
        );
      },
    );

    test('at most 3 candidates, best first', () {
      final m = _match([
        _poi('Shake Shack', 30),
        _poi('Chipotle Mexican Grill', 5),
        _poi('Five Guys', 22),
        _poi('Qdoba Mexican Eats', 12),
        _poi('Panda Express', 38),
      ]);
      expect(m.candidates, ['chipotle', 'qdoba', 'five_guys']);
      expect(m.candidates, hasLength(kLookupMaxChains));
    });
  });

  group('zones, blocks and confirmations', () {
    final cell = _capitolSquare;
    final lone = [_poi('Chipotle Mexican Grill', 12)];

    test('a zone in the photo cell or the 8 around it stops the match', () {
      for (final (dLat, dLon) in [(0, 0), (1, 0), (-1, 1), (1, -1), (0, -1)]) {
        final m = _match(
          lone,
          cell: cell,
          learned: LearnedPlaces(zones: [_shift(cell, dLat, dLon)]),
        );
        expect(m.reason, PlaceMatchReason.zone, reason: '($dLat, $dLon)');
        expect(m.candidates, isEmpty);
        expect(m.picked, isNull);
      }
      for (final (dLat, dLon) in [(2, 0), (0, 2), (-2, -2)]) {
        final m = _match(
          lone,
          cell: cell,
          learned: LearnedPlaces(zones: [_shift(cell, dLat, dLon)]),
        );
        expect(m.picked, 'chipotle', reason: '($dLat, $dLon)');
      }
    });

    test('a blocked chain is out only around its own cell', () {
      final blocked = _match(
        lone,
        cell: cell,
        learned: LearnedPlaces(
          blocked: [LearnedChainCell('chipotle', _shift(cell, 1, 1))],
        ),
      );
      expect(blocked.reason, PlaceMatchReason.chainBlocked);
      expect(blocked.candidates, isEmpty);
      expect(blocked.picked, isNull);
      expect(blocked.blocked, {'chipotle'});

      final elsewhere = _match(
        lone,
        cell: cell,
        learned: LearnedPlaces(
          blocked: [LearnedChainCell('chipotle', _shift(cell, 2, 0))],
        ),
      );
      expect(elsewhere.picked, 'chipotle');
      expect(elsewhere.blocked, isEmpty);

      final otherChain = _match(
        lone,
        cell: cell,
        learned: LearnedPlaces(blocked: [LearnedChainCell('qdoba', cell)]),
      );
      expect(otherChain.picked, 'chipotle');
    });

    test('a block never makes another chain easier to pick', () {
      // Qdoba close by, Chipotle within 2σ: two chains, no pick — and
      // blocking Chipotle here does not change that.
      final places = [
        _poi('Qdoba Mexican Eats', 8),
        _poi('Chipotle Mexican Grill', 35),
      ];
      final unblocked = _match(places, cell: cell);
      expect(unblocked.picked, isNull);
      expect(unblocked.candidates, ['qdoba', 'chipotle']);

      final m = _match(
        places,
        cell: cell,
        learned: LearnedPlaces(blocked: [LearnedChainCell('chipotle', cell)]),
      );
      expect(m.candidates, ['qdoba']);
      expect(
        m.picked,
        isNull,
        reason: 'the blocked Chipotle still stands within 2σ',
      );
      expect(m.reason, PlaceMatchReason.ambiguous);
      expect(m.blocked, {'chipotle'});
    });

    test('a confirmation does not beat dense', () {
      final m = _match(
        _timesSquare60,
        geo: const PhotoGeo(),
        cell: _timesSquare,
        learned: LearnedPlaces(
          confirmed: [LearnedChainCell('mcdonalds', _timesSquare)],
        ),
      );
      expect(m.dense, isTrue);
      expect(m.picked, isNull);
      expect(m.confirmed, {'mcdonalds'});
    });

    test('a confirmation reorders the candidates but never picks', () {
      final places = [
        _poi('Chipotle Mexican Grill', 8),
        _poi('Qdoba Mexican Eats', 30),
      ];
      final m = _match(
        places,
        cell: cell,
        learned: LearnedPlaces(
          confirmed: [LearnedChainCell('qdoba', _shift(cell, 0, 1))],
        ),
      );
      expect(m.candidates, ['qdoba', 'chipotle']);
      expect(m.picked, isNull);
      expect(m.confirmed, {'qdoba'});
    });

    test('a confirmation counts only for its own chain, near its cell', () {
      final confirmedHere = _match(
        lone,
        cell: cell,
        learned: LearnedPlaces(confirmed: [LearnedChainCell('chipotle', cell)]),
      );
      expect(confirmedHere.picked, 'chipotle');
      expect(confirmedHere.confirmed, {'chipotle'});

      final otherChain = _match(
        [_poi('Qdoba Mexican Eats', 12)],
        cell: cell,
        learned: LearnedPlaces(confirmed: [LearnedChainCell('chipotle', cell)]),
      );
      expect(otherChain.picked, 'qdoba');
      expect(otherChain.confirmed, isEmpty);

      final farAway = _match(
        lone,
        cell: cell,
        learned: LearnedPlaces(
          confirmed: [LearnedChainCell('chipotle', _shift(cell, 0, 2))],
        ),
      );
      expect(farAway.confirmed, isEmpty);
    });
  });

  group('PlaceCell', () {
    test('3 decimals each, written canonically', () {
      expect(PlaceCell.fromLatLon(43.07474, -89.38416)!.wire, '43.075,-89.384');
      expect(PlaceCell.fromLatLon(-0.0004, 0.0004)!.wire, '0.000,0.000');
      expect(PlaceCell.fromLatLon(-0.0006, -0.0204)!.wire, '-0.001,-0.020');
      expect(PlaceCell.fromLatLon(90, 180)!.wire, '90.000,180.000');
      expect(PlaceCell.fromLatLon(-12.5, 7.25)!.wire, '-12.500,7.250');
    });

    test('a stored cell round-trips; anything else is null', () {
      for (final wire in [
        '43.075,-89.384',
        '0.000,0.000',
        '-0.001,-0.020',
        '-90.000,180.000',
      ]) {
        expect(PlaceCell.tryParse(wire)!.wire, wire);
      }
      expect(
        PlaceCell.tryParse('43.075,-89.384'),
        PlaceCell.fromLatLon(43.0747, -89.3842),
      );
      for (final bad in [
        null,
        43.075,
        '',
        '43.075',
        '43.07,-89.384',
        '43.0750,-89.384',
        '43.075, -89.384',
        '91.000,0.000',
        '0.000,180.001',
        '+43.075,-89.384',
        '43.075,-89.384,1',
      ]) {
        expect(PlaceCell.tryParse(bad), isNull, reason: '$bad');
      }
      for (final (lat, lon) in [
        (double.nan, 0.0),
        (0.0, double.infinity),
        (90.1, 0.0),
        (0.0, -180.1),
      ]) {
        expect(PlaceCell.fromLatLon(lat, lon), isNull, reason: '$lat,$lon');
      }
    });

    test('−180° and 180° are one meridian; the 3×3 neighbourhood wraps', () {
      final east = PlaceCell.fromLatLon(10, 180)!;
      final west = PlaceCell.fromLatLon(10, -180)!;
      expect(west, east);
      expect(west.wire, '10.000,180.000');
      expect(PlaceCell.fromLatLon(10, -179.999)!.isNear(east), isTrue);
      expect(PlaceCell.fromLatLon(10, -179.998)!.isNear(east), isFalse);
      expect(PlaceCell.fromLatLon(10.001, 179.999)!.isNear(east), isTrue);
      expect(PlaceCell.fromLatLon(10.002, 180)!.isNear(east), isFalse);
    });

    test('logs never carry a cell, a coordinate or a place name', () {
      expect('$_timesSquare', 'PlaceCell(redacted)');
      final m = _match(
        _timesSquare60,
        geo: const PhotoGeo(),
        cell: _timesSquare,
      );
      final text = '$m ${m.cell} ${LearnedChainCell('mcdonalds', m.cell)}';
      expect(text, isNot(contains('40.')));
      expect(text, isNot(contains('73.')));
      expect(text, isNot(contains("McDonald's")));
      expect('${_timesSquare60.first}', isNot(contains('Anita')));
    });
  });
}
