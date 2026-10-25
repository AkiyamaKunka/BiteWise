/// Which country a meal was eaten in, as far as the restaurant assist
/// needs to know (run 6, 2026-10-25).
///
/// The assist knows only US chains, whose published numbers are US menu
/// labeling (FDA, 21 CFR 101.11): a McDonald's in Shanghai sells other
/// portions under the same names. So published numbers are looked up, and
/// applied, only for a meal eaten in the US. MealAssist decides that once
/// per lookup with [decideMealCountry] and uses the ONE value for both the
/// request's "country" and decideAssist's US rule; anything but [kMealCountryUs]
/// means no lookup at all (no plan usage, no suggestion with US numbers).
///
/// The signals, strongest first:
///   (0) the phone's time zone NOW — a veto that needs no consent and
///       keeps nothing: an offset from UTC the US does not keep
///       ([utcOffsetInUs]: UTC−10, Hawaii, through UTC−4, Puerto Rico and
///       eastern daylight time) means "not the US", whatever the position,
///       the places or the region say. iPhones and Android phones set the
///       zone from the network by default, so in Shanghai it reads +08:00
///       while the region setting stays US. Only the offset counts, never
///       the zone's name or abbreviation ("CST" is both China Standard
///       Time and US Central). It is read when the lookup is decided: an
///       automatic lookup runs in the foreground within 24 h of the meal
///       and an APPLY needs the meal to be today's and at most 12 h old,
///       so the phone's zone then is, near enough, where the meal was
///       eaten. Its limits: a zone set by hand, and a meal photographed
///       abroad and first looked at after flying back to the US — there
///       only the photo's position, where it may be read, can tell.
///   (a) where the photo was taken, when its position may be read (the
///       assist's location consent and 'Use photo location'; read on the
///       phone, never stored or sent): [pointInUs], a coarse test against
///       conservative outlines of the contiguous US, Alaska, Hawaii and
///       Puerto Rico. The outlines stay well inside the land borders with
///       Canada and Mexico (about 15–40 km), so a point near a border —
///       Detroit, El Paso, San Diego's south, Buffalo, Bellingham's north —
///       counts as NOT the US: the test may miss a US meal, never call a
///       foreign one American. A fix less precise than
///       [kMealCountryMaxAccuracyM] can only say "not the US".
///   (b) the ISO country Apple Maps gives the nearest places, when the
///       places were fetched: any non-US place among the nearest
///       [kMealCountryNearestPlaces] makes it not the US. Places are only
///       ever fetched for a position, so with (a) this is a veto.
///   (c) the phone's region setting (MealAssist's deviceRegion) — weak:
///       a traveller's phone usually stays set to home.
///   (d) none of them: null, unknown. Nothing could apply, so nothing is
///       looked up.
///
/// Pure Dart: no coordinate is kept, logged or returned — only a code.
library;

/// The meal was eaten in the US (the contiguous states, Alaska, Hawaii or
/// Puerto Rico).
const String kMealCountryUs = 'US';

/// Somewhere that is not the US, or too close to a border to tell (ISO
/// 3166's user-assigned "XX": no country is named).
const String kMealCountryOutside = 'XX';

/// A position whose recorded accuracy is worse than this (metres) cannot
/// say "the US": the outlines' margin from the borders is not much wider.
const double kMealCountryMaxAccuracyM = 10000;

/// How many of the nearest places (that name a country) Apple Maps'
/// country is read from.
const int kMealCountryNearestPlaces = 3;

/// The US's westernmost offset from UTC (Hawaii–Aleutian standard time;
/// American Samoa's UTC−11 is outside every outline anyway).
const Duration kMealCountryUsOffsetWest = Duration(hours: -10);

/// The US's easternmost offset from UTC (Puerto Rico's Atlantic standard
/// time, and eastern daylight time; Guam's UTC+10 is outside every outline
/// anyway).
const Duration kMealCountryUsOffsetEast = Duration(hours: -4);

/// True when [offset], the phone's offset from UTC, is one the US keeps
/// (standard or daylight time): from [kMealCountryUsOffsetWest] to
/// [kMealCountryUsOffsetEast], both included. Shanghai's +08:00, London's
/// +00:00 or +01:00, Newfoundland's −03:30 are not.
bool utcOffsetInUs(Duration offset) =>
    offset >= kMealCountryUsOffsetWest && offset <= kMealCountryUsOffsetEast;

/// Region and place codes that are the US for the assist: Apple files
/// Puerto Rico under its own code.
const Set<String> kMealCountryUsCodes = {'US', 'PR'};

final RegExp _iso2Re = RegExp(r'^[A-Z]{2}$');

/// The meal country from the signals above, strongest first: 'US', another
/// ISO2 code (the phone's region), [kMealCountryOutside], or null when
/// nothing tells. [utcOffset] is the phone's offset from UTC now (null:
/// not given) — outside the US's ([utcOffsetInUs]) it is
/// [kMealCountryOutside] whatever else says; [lat]/[lon] count only as a
/// pair of finite numbers; [placeCountries] are the places' ISO codes
/// nearest first (null for a place that names none); [deviceRegion] is
/// the phone's region (ISO2).
String? decideMealCountry({
  double? lat,
  double? lon,
  double? accuracyM,
  Iterable<String?> placeCountries = const [],
  String? deviceRegion,
  Duration? utcOffset,
}) {
  if (utcOffset != null && !utcOffsetInUs(utcOffset)) {
    return kMealCountryOutside;
  }
  final places = placesCountry(placeCountries);
  if (lat != null && lon != null && lat.isFinite && lon.isFinite) {
    final precise =
        accuracyM == null ||
        !accuracyM.isFinite ||
        accuracyM < 0 ||
        accuracyM <= kMealCountryMaxAccuracyM;
    if (!precise || !pointInUs(lat, lon)) return kMealCountryOutside;
    return places == kMealCountryOutside ? kMealCountryOutside : kMealCountryUs;
  }
  if (places != null) return places;
  final region = deviceRegion;
  if (region != null && _iso2Re.hasMatch(region)) {
    return kMealCountryUsCodes.contains(region) ? kMealCountryUs : region;
  }
  return null;
}

/// What the nearest places say: [kMealCountryUs] when every one of the
/// first [kMealCountryNearestPlaces] that names a country is the US,
/// [kMealCountryOutside] when any is not, null when none names one.
String? placesCountry(Iterable<String?> placeCountries) {
  var seen = 0;
  for (final c in placeCountries) {
    if (c == null || !_iso2Re.hasMatch(c)) continue;
    if (!kMealCountryUsCodes.contains(c)) return kMealCountryOutside;
    if (++seen >= kMealCountryNearestPlaces) break;
  }
  return seen == 0 ? null : kMealCountryUs;
}

/// True when ([lat], [lon]) (degrees, WGS 84) lies inside the conservative
/// outline of the contiguous US, Alaska, Hawaii or Puerto Rico. A point
/// near a land border, on the border, outside every outline, or not a
/// finite position is false.
bool pointInUs(double lat, double lon) {
  if (!lat.isFinite || !lon.isFinite) return false;
  for (final ring in _usOutlines) {
    if (_inRing(ring, lat, lon)) return true;
  }
  return false;
}

/// Even-odd ray casting in the (lon, lat) plane. The outlines' edges are
/// straight lines in that plane, which is how they were drawn.
bool _inRing(List<(double, double)> ring, double lat, double lon) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final (latI, lonI) = ring[i];
    final (latJ, lonJ) = ring[j];
    if ((latI > lat) != (latJ > lat) &&
        lon < (lonJ - lonI) * (lat - latI) / (latJ - latI) + lonI) {
      inside = !inside;
    }
  }
  return inside;
}

// ─── The outlines ──────────────────────────────────────────────────────
//
// (lat, lon) vertices. Along the land borders and the shared lakes,
// rivers and straits each vertex was placed at least ~15 km (mostly
// 20–40 km) on the US side of the border; along open coasts the outline
// runs offshore, keeping clear of the Bahamas, Cuba, Mexico's islands and
// Russia's sea border. Places inside the margin (the Rio Grande Valley,
// downtown Detroit, Buffalo, Laredo, El Paso, Point Roberts, Little
// Diomede, the US Virgin Islands) are left out on purpose: a missed lookup
// costs nothing, a foreign meal given US numbers is wrong.

const List<(double, double)> _contiguous = [
  // The 49th parallel, Lake of the Woods, the boundary waters.
  (48.85, -122.75), (48.85, -95.4), (48.6, -94.7), (48.4, -93.4),
  (48.05, -92.5), (47.8, -91.6), (47.8, -90.7), (47.7, -89.8),
  // Lake Superior, the St. Marys River, Lake Huron.
  (47.7, -88.5), (47.6, -88.0), (47.2, -87.0), (46.85, -86.0),
  (46.5, -85.1), (46.1, -84.6), (45.75, -84.0), (45.1, -83.2),
  (44.0, -82.75), (43.4, -82.65),
  // The St. Clair River, Lake St. Clair, the Detroit River, Lake Erie.
  (43.0, -82.65), (42.6, -82.95), (42.35, -83.25), (41.85, -83.55),
  (41.45, -82.95), (41.45, -82.3), (41.65, -81.5), (41.95, -80.6),
  (42.15, -79.95), (42.4, -79.35), (42.65, -78.85),
  // The Niagara River, Lake Ontario, the St. Lawrence, the 45th parallel.
  (42.75, -78.65), (43.15, -78.7), (43.3, -78.7), (43.45, -76.6),
  (43.75, -76.1), (44.2, -75.6), (44.65, -74.9), (44.8, -74.6),
  (44.8, -71.3),
  // New Hampshire and Maine, the St. Croix, Passamaquoddy Bay.
  (45.3, -70.5), (46.0, -69.6), (46.6, -68.4), (45.9, -68.0),
  (45.3, -67.65), (44.95, -67.55), (44.4, -67.4),
  // The Atlantic, offshore.
  (43.8, -68.5), (42.5, -69.8), (41.2, -69.6), (40.6, -71.8),
  (39.5, -73.8), (38.5, -74.5), (36.5, -75.3), (35.2, -75.2),
  (34.4, -76.3), (33.5, -77.8), (32.5, -79.5), (31.0, -80.9),
  (30.0, -80.9), (28.5, -80.2),
  // Florida: west of the Bahamas, north of Cuba and the Cay Sal Bank.
  (27.5, -79.85), (25.0, -79.85), (24.3, -80.3), (24.3, -83.0),
  // The Gulf of Mexico, offshore.
  (25.5, -83.5), (27.0, -83.6), (28.8, -83.6), (29.4, -84.5),
  (29.4, -85.5), (29.9, -86.6), (29.8, -88.2), (28.7, -89.0),
  (28.7, -90.5), (29.0, -92.5), (29.3, -94.0), (28.6, -95.0),
  (27.6, -96.8), (26.15, -96.9),
  // The Rio Grande.
  (26.25, -97.5), (26.35, -98.3), (26.6, -98.85), (27.2, -99.2),
  (27.55, -99.25), (28.0, -99.65), (28.7, -100.2), (29.6, -100.9),
  (30.1, -101.6), (30.25, -102.3), (30.25, -103.6), (30.4, -104.4),
  (31.0, -105.0), (31.45, -105.85), (31.65, -106.15), (31.95, -106.45),
  // The land border: New Mexico's bootheel, Arizona, California.
  (31.95, -108.45), (31.5, -108.45), (31.5, -111.0), (32.6, -114.45),
  (32.95, -114.45), (32.95, -115.2), (32.85, -116.2), (32.8, -116.7),
  (32.68, -117.05), (32.65, -117.4),
  // The Pacific, offshore; the Strait of Juan de Fuca, Haro Strait.
  (32.6, -119.0), (34.5, -121.3), (36.0, -122.5), (37.7, -123.5),
  (40.4, -125.0), (43.0, -125.0), (47.5, -125.0), (48.15, -124.8),
  (48.05, -123.4), (48.05, -122.75),
];

const List<(double, double)> _alaska = [
  // The Chukchi and Beaufort Seas, the 141st meridian.
  (71.5, -168.0), (71.6, -156.0), (70.5, -141.4), (60.1, -141.4),
  // The Panhandle: inside the border along the Coast Mountains …
  (59.95, -140.2), (59.55, -139.0), (58.85, -137.9), (58.4, -137.0),
  (58.55, -135.0), (58.2, -134.0), (57.3, -133.0), (56.5, -132.4),
  (55.7, -130.6), (54.95, -130.9),
  // … north of Dixon Entrance, then back up the outer coast.
  (54.95, -133.5), (56.5, -136.0), (57.9, -137.2), (58.5, -138.6),
  (59.3, -140.5),
  // The Gulf of Alaska, Kodiak, the Alaska Peninsula, the Aleutians to
  // 179.5° W.
  (59.6, -142.5), (59.5, -146.0), (59.3, -149.0), (58.7, -151.0),
  (57.0, -151.8), (56.3, -153.8), (55.0, -158.0), (53.5, -163.0),
  (53.3, -166.0), (51.5, -172.0), (51.3, -178.0), (51.3, -179.5),
  // The Bering Sea, east of the sea border with Russia; Bering Strait.
  (52.5, -179.5), (55.0, -172.0), (57.6, -171.0), (60.0, -168.5),
  (62.5, -171.0), (63.9, -171.0), (64.5, -169.0), (65.5, -168.4),
  (68.0, -168.0),
];

const List<(double, double)> _hawaii = [
  (18.7, -160.6),
  (22.6, -160.6),
  (22.6, -154.5),
  (18.7, -154.5),
];

/// The main island, Vieques and Culebra; not the US Virgin Islands, a few
/// km from the British ones.
const List<(double, double)> _puertoRico = [
  (17.8, -67.35),
  (18.6, -67.35),
  (18.6, -65.15),
  (17.8, -65.15),
];

const List<List<(double, double)>> _usOutlines = [
  _contiguous,
  _alaska,
  _hawaii,
  _puertoRico,
];
