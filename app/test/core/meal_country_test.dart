/// core/meal_country.dart — the coarse "inside the US" test and the meal
/// country the restaurant assist looks up and applies by (run 6).
library;

import 'dart:math' as math;

import 'package:calorie_tracker/core/meal_country.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Place = ({String name, double lat, double lon});

const List<_Place> _usCities = [
  (name: 'Madison', lat: 43.0731, lon: -89.4012),
  (name: 'New York City', lat: 40.7128, lon: -74.0060),
  (name: 'Los Angeles', lat: 34.0522, lon: -118.2437),
  (name: 'Anchorage', lat: 61.2181, lon: -149.9003),
  (name: 'Honolulu', lat: 21.3069, lon: -157.8583),
  (name: 'San Juan', lat: 18.4655, lon: -66.1057),
  (name: 'Chicago', lat: 41.8781, lon: -87.6298),
  (name: 'Houston', lat: 29.7604, lon: -95.3698),
  (name: 'Miami', lat: 25.7617, lon: -80.1918),
  (name: 'Miami Beach', lat: 25.7907, lon: -80.1300),
  (name: 'Key West', lat: 24.5551, lon: -81.7800),
  (name: 'Atlanta', lat: 33.7490, lon: -84.3880),
  (name: 'Boston', lat: 42.3601, lon: -71.0589),
  (name: 'Seattle', lat: 47.6062, lon: -122.3321),
  (name: 'Bellingham', lat: 48.7519, lon: -122.4787),
  (name: 'San Francisco', lat: 37.7749, lon: -122.4194),
  (name: 'San Diego (downtown)', lat: 32.7157, lon: -117.1611),
  (name: 'Phoenix', lat: 33.4484, lon: -112.0740),
  (name: 'Tucson', lat: 32.2226, lon: -110.9747),
  (name: 'Denver', lat: 39.7392, lon: -104.9903),
  (name: 'Minneapolis', lat: 44.9778, lon: -93.2650),
  (name: 'Duluth', lat: 46.7867, lon: -92.1005),
  (name: 'Marquette', lat: 46.5436, lon: -87.3954),
  (name: 'Milwaukee', lat: 43.0389, lon: -87.9065),
  (name: 'Cleveland', lat: 41.4993, lon: -81.6944),
  (name: 'Rochester NY', lat: 43.1566, lon: -77.6088),
  (name: 'Burlington VT', lat: 44.4759, lon: -73.2121),
  (name: 'Portland ME', lat: 43.6591, lon: -70.2568),
  (name: 'New Orleans', lat: 29.9511, lon: -90.0715),
  (name: 'Dallas', lat: 32.7767, lon: -96.7970),
  (name: 'Corpus Christi', lat: 27.8006, lon: -97.3964),
  (name: 'Las Vegas', lat: 36.1699, lon: -115.1398),
  (name: 'Fairbanks', lat: 64.8378, lon: -147.7164),
  (name: 'Juneau', lat: 58.3019, lon: -134.4197),
  (name: 'Ketchikan', lat: 55.3422, lon: -131.6461),
  (name: 'Kodiak', lat: 57.7900, lon: -152.4072),
  (name: 'Utqiagvik', lat: 71.2906, lon: -156.7886),
  (name: 'Hilo', lat: 19.7071, lon: -155.0885),
  (name: 'Lihue', lat: 21.9811, lon: -159.3711),
  (name: 'Ponce', lat: 18.0111, lon: -66.6141),
];

const List<_Place> _foreign = [
  (name: 'Shanghai', lat: 31.2304, lon: 121.4737),
  (name: 'Beijing', lat: 39.9042, lon: 116.4074),
  (name: 'Toronto', lat: 43.6532, lon: -79.3832),
  (name: 'Vancouver', lat: 49.2827, lon: -123.1207),
  (name: 'Tijuana', lat: 32.5149, lon: -117.0382),
  (name: 'Mexico City', lat: 19.4326, lon: -99.1332),
  (name: 'London', lat: 51.5074, lon: -0.1278),
  (name: 'Montreal', lat: 45.5017, lon: -73.5673),
  (name: 'Victoria BC', lat: 48.4284, lon: -123.3656),
  (name: 'Windsor ON', lat: 42.3149, lon: -83.0364),
  (name: 'Niagara Falls ON', lat: 43.0896, lon: -79.0849),
  (name: 'Sarnia', lat: 42.9745, lon: -82.4066),
  (name: 'Sault Ste. Marie ON', lat: 46.5219, lon: -84.3461),
  (name: 'Thunder Bay', lat: 48.3809, lon: -89.2477),
  (name: 'Winnipeg', lat: 49.8951, lon: -97.1384),
  (name: 'St. Stephen NB', lat: 45.1925, lon: -67.2750),
  (name: 'Whitehorse', lat: 60.7212, lon: -135.0568),
  (name: 'Prince Rupert', lat: 54.3150, lon: -130.3208),
  (name: 'Ciudad Juárez', lat: 31.6904, lon: -106.4245),
  (name: 'Mexicali', lat: 32.6245, lon: -115.4523),
  (name: 'Nogales MX', lat: 31.3086, lon: -110.9422),
  (name: 'Nuevo Laredo', lat: 27.4763, lon: -99.5164),
  (name: 'Reynosa', lat: 26.0508, lon: -98.2979),
  (name: 'Matamoros', lat: 25.8690, lon: -97.5027),
  (name: 'Havana', lat: 23.1136, lon: -82.3666),
  (name: 'Bimini', lat: 25.7271, lon: -79.2789),
  (name: 'Nassau', lat: 25.0443, lon: -77.3504),
  (name: 'Freeport (Grand Bahama)', lat: 26.5333, lon: -78.7000),
  (name: 'Punta Cana', lat: 18.5601, lon: -68.3725),
  (name: 'Tortola', lat: 18.4207, lon: -64.6400),
  (name: 'Big Diomede', lat: 65.7833, lon: -169.0667),
  (name: 'Provideniya', lat: 64.4233, lon: -173.2272),
  (name: 'Anadyr', lat: 64.7337, lon: 177.4968),
  (name: 'Tokyo', lat: 35.6762, lon: 139.6503),
  (name: 'Hong Kong', lat: 22.3193, lon: 114.1694),
  (name: 'Taipei', lat: 25.0330, lon: 121.5654),
  (name: 'Sydney', lat: -33.8688, lon: 151.2093),
  (name: 'Paris', lat: 48.8566, lon: 2.3522),
  (name: 'Bermuda', lat: 32.2949, lon: -64.7814),
  (name: 'Null Island', lat: 0, lon: 0),
  // Right across a border, a strait or a lake from the US.
  (name: 'White Rock BC', lat: 49.0253, lon: -122.8026),
  (name: 'Osoyoos BC', lat: 49.0323, lon: -119.4682),
  (name: 'Saturna Island (East Point)', lat: 48.7830, lon: -123.0450),
  (name: 'Sidney BC', lat: 48.6506, lon: -123.3986),
  (name: 'Race Rocks', lat: 48.2980, lon: -123.5310),
  (name: 'Fort Frances', lat: 48.6091, lon: -93.4000),
  (name: 'Wawa', lat: 47.9940, lon: -84.7740),
  (name: 'Caribou Island', lat: 47.3330, lon: -85.8330),
  (name: 'Michipicoten Island', lat: 47.7500, lon: -85.8000),
  (name: 'Ile Parisienne', lat: 46.6700, lon: -84.7300),
  (name: 'St. Joseph Island', lat: 46.2000, lon: -83.9500),
  (name: 'Cockburn Island', lat: 45.9200, lon: -83.3500),
  (name: 'Manitoulin (Meldrum Bay)', lat: 45.9300, lon: -83.1100),
  (name: 'Kincardine', lat: 44.1770, lon: -81.6360),
  (name: 'Leamington', lat: 42.0530, lon: -82.5990),
  (name: 'Point Pelee', lat: 41.9080, lon: -82.5100),
  (name: 'Pelee Island', lat: 41.7700, lon: -82.6500),
  (name: 'Middle Island ON', lat: 41.6820, lon: -82.6830),
  (name: 'London ON', lat: 42.9849, lon: -81.2453),
  (name: 'Long Point (tip)', lat: 42.5500, lon: -80.0500),
  (name: 'Port Colborne', lat: 42.8860, lon: -79.2500),
  (name: 'Fort Erie', lat: 42.9018, lon: -78.9722),
  (name: 'St. Catharines', lat: 43.1594, lon: -79.2469),
  (name: 'Hamilton ON', lat: 43.2557, lon: -79.8711),
  (name: 'Main Duck Island', lat: 43.9300, lon: -76.6200),
  (name: 'Wolfe Island', lat: 44.1800, lon: -76.4300),
  (name: 'Kingston ON', lat: 44.2312, lon: -76.4860),
  (name: 'Brockville', lat: 44.5895, lon: -75.6843),
  (name: 'Cornwall ON', lat: 45.0213, lon: -74.7303),
  (name: 'Ottawa', lat: 45.4215, lon: -75.6972),
  (name: 'Stanstead QC', lat: 45.0100, lon: -72.1000),
  (name: 'Sherbrooke', lat: 45.4042, lon: -71.8929),
  (name: 'Woburn QC', lat: 45.3800, lon: -70.8700),
  (name: 'Edmundston', lat: 47.3737, lon: -68.3251),
  (name: 'Woodstock NB', lat: 46.1527, lon: -67.6000),
  (name: 'Campobello Island', lat: 44.8800, lon: -66.9300),
  (name: 'Grand Manan', lat: 44.7000, lon: -66.8000),
  (name: 'Stewart BC', lat: 55.9400, lon: -129.9900),
  (name: 'Beaver Creek YT', lat: 62.3800, lon: -140.8700),
  (name: 'Dawson City', lat: 64.0600, lon: -139.4300),
  (name: 'Piedras Negras', lat: 28.7000, lon: -100.5200),
  (name: 'Ciudad Acuña', lat: 29.3200, lon: -100.9300),
  (name: 'Boquillas del Carmen', lat: 29.1800, lon: -102.9500),
  (name: 'Ojinaga', lat: 29.5600, lon: -104.4100),
  (name: 'Agua Prieta', lat: 31.3300, lon: -109.5500),
  (name: 'Sonoyta', lat: 31.8600, lon: -112.8500),
  (name: 'San Luis Río Colorado', lat: 32.4600, lon: -114.7700),
  (name: 'Tecate', lat: 32.5700, lon: -116.6300),
  (name: 'Rosarito', lat: 32.3600, lon: -117.0600),
  (name: 'Islas Coronado', lat: 32.4200, lon: -117.2500),
  (name: 'Cay Sal (Elbow Cay)', lat: 23.9500, lon: -80.4500),
  (name: 'West End (Grand Bahama)', lat: 26.6900, lon: -78.9800),
  (name: 'Cape Chaplino', lat: 64.4000, lon: -172.2400),
  (name: 'Uelen', lat: 66.1600, lon: -169.8100),
];

/// US places within the margin of a land border (or the border itself):
/// not the US for the test, on purpose.
const List<_Place> _borderAmbiguous = [
  (name: 'Detroit (downtown)', lat: 42.3314, lon: -83.0458),
  (name: 'El Paso (downtown)', lat: 31.7619, lon: -106.4850),
  (name: 'San Ysidro', lat: 32.5556, lon: -117.0470),
  (name: 'Buffalo', lat: 42.8864, lon: -78.8784),
  (name: 'Blaine WA', lat: 48.9937, lon: -122.7471),
  (name: 'Point Roberts', lat: 48.9851, lon: -123.0796),
  (name: 'Laredo', lat: 27.5306, lon: -99.4803),
  (name: 'Brownsville', lat: 25.9017, lon: -97.4975),
  (name: 'International Falls', lat: 48.6011, lon: -93.4105),
  (name: 'Sault Ste. Marie MI', lat: 46.4953, lon: -84.3453),
  (name: 'Calais ME', lat: 45.1884, lon: -67.2783),
  (name: 'Derby Line VT', lat: 45.0048, lon: -72.0993),
  (name: 'Yuma', lat: 32.6927, lon: -114.6277),
  (name: 'Nogales AZ', lat: 31.3404, lon: -110.9343),
  (name: 'Little Diomede', lat: 65.7580, lon: -168.9530),
  (name: 'St. Thomas USVI', lat: 18.3381, lon: -64.8941),
  (name: '49th parallel, 1 km south (North Dakota)', lat: 48.991, lon: -100.0),
  (name: '49th parallel, 1 km north (Manitoba)', lat: 49.009, lon: -100.0),
  (name: 'on the 49th parallel', lat: 49.0, lon: -110.0),
  (name: 'the 141st meridian, 2 km west (Alaska)', lat: 64.0, lon: -141.04),
  (name: 'the 141st meridian, 2 km east (Yukon)', lat: 64.0, lon: -140.96),
  (name: 'the land border, 1 km north (Arizona)', lat: 31.342, lon: -110.0),
  (name: 'the land border, 1 km south (Sonora)', lat: 31.322, lon: -110.0),
];

/// The Rio Grande from its mouth to El Paso, through the river towns
/// (lon ascending westward is monotonic along it), as (lat, lon).
const List<(double, double)> _rioGrande = [
  (25.96, -97.15),
  (25.87, -97.50),
  (26.05, -97.74),
  (26.10, -98.26),
  (26.24, -98.56),
  (26.38, -98.82),
  (26.41, -99.00),
  (26.56, -99.17),
  (27.05, -99.43),
  (27.50, -99.50),
  (27.70, -99.75),
  (28.71, -100.50),
  (29.33, -100.93),
  (29.81, -101.56),
  (29.75, -102.30),
  (29.45, -102.82),
  (28.97, -103.15),
  (29.26, -103.78),
  (29.56, -104.37),
  (30.14, -104.68),
  (31.27, -105.87),
  (31.43, -106.16),
  (31.63, -106.30),
  (31.75, -106.49),
];

/// The river's latitude at [lon] (between its mouth and El Paso), by
/// straight lines between the towns above.
double _rioGrandeLat(double lon) {
  if (lon >= _rioGrande.first.$2) return _rioGrande.first.$1;
  for (var i = 1; i < _rioGrande.length; i++) {
    final (lat0, lon0) = _rioGrande[i - 1];
    final (lat1, lon1) = _rioGrande[i];
    if (lon >= lon1) return lat0 + (lat1 - lat0) * (lon - lon0) / (lon1 - lon0);
  }
  return _rioGrande.last.$1;
}

void main() {
  group('pointInUs', () {
    test('US cities, Alaska, Hawaii and Puerto Rico are inside', () {
      for (final p in _usCities) {
        expect(pointInUs(p.lat, p.lon), isTrue, reason: p.name);
      }
    });

    test('foreign cities are outside — including the ones right across '
        'a border', () {
      for (final p in _foreign) {
        expect(pointInUs(p.lat, p.lon), isFalse, reason: p.name);
      }
    });

    test('a point near a land border counts as NOT the US, whichever side '
        'it is on', () {
      for (final p in _borderAmbiguous) {
        expect(pointInUs(p.lat, p.lon), isFalse, reason: p.name);
      }
    });

    test('20 km inside, away from the cities: the US again', () {
      // North Dakota, 40 km south of the 49th parallel.
      expect(pointInUs(48.64, -100.0), isTrue);
      // Arizona, 40 km north of the land border.
      expect(pointInUs(31.70, -110.0), isTrue);
      // Alaska, 40 km west of the 141st meridian.
      expect(pointInUs(64.0, -141.85), isTrue);
    });

    test('not a position: false', () {
      for (final (lat, lon) in [
        (double.nan, -89.4),
        (43.07, double.nan),
        (double.infinity, -89.4),
        (43.07, double.negativeInfinity),
      ]) {
        expect(pointInUs(lat, lon), isFalse);
      }
    });

    test('a sweep of China, Canada south of 52° and Mexico never lands '
        'inside', () {
      // Mainland China and its coast, every 0.5°.
      for (var lat = 18.0; lat <= 53.5; lat += 0.5) {
        for (var lon = 73.5; lon <= 135.0; lon += 0.5) {
          expect(pointInUs(lat, lon), isFalse, reason: '$lat,$lon');
        }
      }
      // Canada's populated south: from 49.1° N (a 10 km band north of the
      // 49th parallel) west of Lake of the Woods.
      for (var lat = 49.1; lat <= 52.0; lat += 0.1) {
        for (var lon = -140.0; lon <= -95.2; lon += 0.25) {
          expect(pointInUs(lat, lon), isFalse, reason: '$lat,$lon');
        }
      }
      // Mexico: south of 31.3° N (the Sonora/Chihuahua line) west of El
      // Paso, south of the Rio Grande (5 km clear of a polyline through
      // its towns) east of it, and Baja California below 32.5° N.
      for (var lat = 14.5; lat <= 31.3; lat += 0.1) {
        for (var lon = -117.0; lon <= -86.7; lon += 0.1) {
          if (lon > -106.49 && lat > _rioGrandeLat(lon) - 0.05) continue;
          expect(pointInUs(lat, lon), isFalse, reason: '$lat,$lon');
        }
      }
      for (var lat = 22.8; lat <= 32.5; lat += 0.1) {
        for (var lon = -117.3; lon <= -114.0; lon += 0.1) {
          if (lat > 31.3 && lon > -114.8) continue; // Sonora/Arizona corner
          expect(pointInUs(lat, lon), isFalse, reason: '$lat,$lon');
        }
      }
    });
  });

  group('utcOffsetInUs: the US keeps UTC−10 (Hawaii) to UTC−4 (Puerto '
      'Rico, eastern daylight time)', () {
    test('every US zone, standard and daylight, is in', () {
      for (final h in [-10, -9, -8, -7, -6, -5, -4]) {
        expect(utcOffsetInUs(Duration(hours: h)), isTrue, reason: '$h');
      }
    });

    test('the zones around it, and the traveller\'s, are out', () {
      for (final d in const [
        Duration(hours: -10, minutes: -30),
        Duration(hours: -11), // American Samoa: outside every outline
        Duration(hours: -12),
        Duration(hours: -3, minutes: -59),
        Duration(hours: -3, minutes: -30), // Newfoundland
        Duration(hours: -3), // Atlantic daylight time
        Duration.zero,
        Duration(hours: 1),
        Duration(hours: 5, minutes: 30),
        Duration(hours: 8), // China Standard Time ("CST", like US Central)
        Duration(hours: 9),
        Duration(hours: 10), // Guam: outside every outline
        Duration(hours: 14),
      ]) {
        expect(utcOffsetInUs(d), isFalse, reason: '$d');
      }
    });

    test('the edges are in, a minute past them out', () {
      expect(utcOffsetInUs(kMealCountryUsOffsetWest), isTrue);
      expect(utcOffsetInUs(kMealCountryUsOffsetEast), isTrue);
      expect(
        utcOffsetInUs(kMealCountryUsOffsetWest - const Duration(minutes: 1)),
        isFalse,
      );
      expect(
        utcOffsetInUs(kMealCountryUsOffsetEast + const Duration(minutes: 1)),
        isFalse,
      );
    });
  });

  group('decideMealCountry: the time zone vetoes first', () {
    const shanghai = Duration(hours: 8);
    const central = Duration(hours: -5);

    test('outside the US\'s zones: XX whatever the position, places or '
        'region say', () {
      expect(
        decideMealCountry(deviceRegion: 'US', utcOffset: shanghai),
        kMealCountryOutside,
        reason: 'the owner in China: region US, phone on +08:00',
      );
      expect(
        decideMealCountry(
          lat: 43.0731,
          lon: -89.4012,
          placeCountries: ['US'],
          deviceRegion: 'US',
          utcOffset: shanghai,
        ),
        kMealCountryOutside,
        reason:
            'a US photo looked up from abroad: may be missed, never '
            'given numbers from the wrong place',
      );
      expect(
        decideMealCountry(placeCountries: ['US'], utcOffset: Duration.zero),
        kMealCountryOutside,
      );
      expect(decideMealCountry(utcOffset: shanghai), kMealCountryOutside);
    });

    test('inside them it changes nothing: the other signals decide', () {
      expect(
        decideMealCountry(deviceRegion: 'US', utcOffset: central),
        kMealCountryUs,
      );
      expect(decideMealCountry(deviceRegion: 'CN', utcOffset: central), 'CN');
      expect(
        decideMealCountry(
          lat: 31.2304,
          lon: 121.4737,
          deviceRegion: 'US',
          utcOffset: central,
        ),
        kMealCountryOutside,
      );
      expect(decideMealCountry(utcOffset: central), isNull);
    });

    test('not given: no veto (the signals alone)', () {
      expect(decideMealCountry(deviceRegion: 'US'), kMealCountryUs);
    });

    test('random inputs: "US" never comes with a zone outside the US\'s', () {
      final rng = math.Random(20261025);
      for (var i = 0; i < 2000; i++) {
        final offset = Duration(minutes: -720 + rng.nextInt(1561));
        final got = decideMealCountry(
          lat: rng.nextBool() ? 20 + rng.nextDouble() * 40 : null,
          lon: -160 + rng.nextDouble() * 100,
          placeCountries: [if (rng.nextBool()) rng.nextBool() ? 'US' : 'CA'],
          deviceRegion: rng.nextBool() ? 'US' : null,
          utcOffset: offset,
        );
        if (!utcOffsetInUs(offset)) {
          expect(got, kMealCountryOutside, reason: '$offset');
        }
      }
    });
  });

  group('decideMealCountry (priority: GPS, places, region, none)', () {
    test('(a) a GPS position decides, over the phone\'s region', () {
      expect(
        decideMealCountry(lat: 31.2304, lon: 121.4737, deviceRegion: 'US'),
        kMealCountryOutside,
        reason: 'a US-region phone in Shanghai',
      );
      expect(
        decideMealCountry(lat: 43.0731, lon: -89.4012, deviceRegion: 'CN'),
        kMealCountryUs,
        reason: 'a China-region phone in Madison',
      );
      expect(
        decideMealCountry(lat: 43.0731, lon: -89.4012),
        kMealCountryUs,
        reason: 'no region needed',
      );
      expect(
        decideMealCountry(lat: 42.3314, lon: -83.0458, deviceRegion: 'US'),
        kMealCountryOutside,
        reason: 'near a border: not the US',
      );
    });

    test('(a) a fix too coarse to trust can only say "not the US"', () {
      expect(
        decideMealCountry(lat: 43.07, lon: -89.40, accuracyM: 9000),
        kMealCountryUs,
      );
      expect(
        decideMealCountry(lat: 43.07, lon: -89.40, accuracyM: 25000),
        kMealCountryOutside,
      );
      expect(
        decideMealCountry(lat: 31.23, lon: 121.47, accuracyM: 25000),
        kMealCountryOutside,
      );
      // A broken accuracy is unknown, not coarse.
      for (final acc in [double.nan, -1.0, double.infinity]) {
        expect(
          decideMealCountry(lat: 43.07, lon: -89.40, accuracyM: acc),
          kMealCountryUs,
          reason: '$acc',
        );
      }
    });

    test('(b) Apple Maps\' country vetoes a US position; alone, it '
        'decides', () {
      expect(
        decideMealCountry(
          lat: 43.07,
          lon: -89.40,
          placeCountries: ['US', null, 'CA'],
        ),
        kMealCountryOutside,
      );
      expect(
        decideMealCountry(lat: 43.07, lon: -89.40, placeCountries: ['US']),
        kMealCountryUs,
      );
      expect(
        decideMealCountry(placeCountries: ['CN'], deviceRegion: 'US'),
        kMealCountryOutside,
      );
      expect(
        decideMealCountry(placeCountries: [null, 'PR'], deviceRegion: 'CN'),
        kMealCountryUs,
        reason: 'Puerto Rico is filed under its own code',
      );
      expect(
        decideMealCountry(placeCountries: [null, 'us', ''], deviceRegion: 'US'),
        kMealCountryUs,
        reason: 'no valid place code: the region decides',
      );
    });

    test('(b) only the nearest places count', () {
      expect(placesCountry(['US', 'US', 'US', 'MX']), kMealCountryUs);
      expect(placesCountry(['US', null, 'US', 'MX']), kMealCountryOutside);
      expect(placesCountry(['MX', 'US', 'US']), kMealCountryOutside);
      expect(placesCountry(const []), isNull);
      expect(placesCountry([null, 'x1', 'USA']), isNull);
    });

    test('(c) the phone\'s region; (d) none at all is unknown', () {
      expect(decideMealCountry(deviceRegion: 'US'), kMealCountryUs);
      expect(decideMealCountry(deviceRegion: 'PR'), kMealCountryUs);
      expect(decideMealCountry(deviceRegion: 'CN'), 'CN');
      expect(decideMealCountry(deviceRegion: 'us'), isNull);
      expect(decideMealCountry(deviceRegion: 'USA'), isNull);
      expect(decideMealCountry(), isNull);
      // Half a position is none.
      expect(decideMealCountry(lat: 43.07, deviceRegion: 'US'), kMealCountryUs);
      expect(decideMealCountry(lon: -89.4), isNull);
      expect(
        decideMealCountry(lat: double.nan, lon: -89.4, deviceRegion: 'CN'),
        'CN',
      );
    });

    test('random inputs: "US" only when every signal that is there allows '
        'it', () {
      final rng = math.Random(20261025);
      const regions = [null, 'US', 'PR', 'CN', 'CA', 'MX', 'GB', 'us', ''];
      const codes = [null, 'US', 'PR', 'CN', 'CA', 'MX', 'xx'];
      for (var i = 0; i < 4000; i++) {
        final hasPoint = rng.nextBool();
        final lat = -60 + rng.nextDouble() * 135;
        final lon = -180 + rng.nextDouble() * 360;
        final region = regions[rng.nextInt(regions.length)];
        final places = [
          for (var k = rng.nextInt(5); k > 0; k--)
            codes[rng.nextInt(codes.length)],
        ];
        final got = decideMealCountry(
          lat: hasPoint ? lat : null,
          lon: hasPoint ? lon : null,
          placeCountries: places,
          deviceRegion: region,
        );
        if (got != kMealCountryUs) continue;
        if (hasPoint) {
          expect(pointInUs(lat, lon), isTrue);
          expect(placesCountry(places), isNot(kMealCountryOutside));
        } else if (placesCountry(places) == null) {
          expect(kMealCountryUsCodes, contains(region));
        } else {
          expect(placesCountry(places), kMealCountryUs);
        }
      }
    });
  });
}
