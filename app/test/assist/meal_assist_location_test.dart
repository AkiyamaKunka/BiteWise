/// services/assist/meal_assist.dart — the location path, job polling,
/// retries and the on-device cache (design R6c), with fakes for the photo
/// location, Apple Maps' places and the learned-places store:
///   * the location is read only for a RESTAURANT meal with GPS, the
///     'Use photo location' sub-toggle on, a recipient that may receive
///     location-derived chains (never an http:// own server) and a reader
///     (iOS) — never for home, packaged or unknown; a TAKEOUT meal's only
///     for the meal country (Apple Maps is not asked);
///   * the meal country (core/meal_country.dart): a photo taken outside
///     the US — or Apple Maps' places filed outside it — is not looked up
///     (no places query, no cache, no suggestion); without a position the
///     phone's region decides; with none, nothing is looked up; the
///     request's country and the decision's are always the same, US;
///   * a 'Not from a restaurant' zone asks Apple Maps nothing;
///   * a dense spot sends its candidates and gets a suggestion at most; a
///     chain the user confirmed at a lone spot can apply on location alone;
///   * the request names at most 3 chains, 1 when one was auto-picked;
///   * the coordinates leave nothing behind (nothing stored, sent or
///     logged holds them; the source keeps them inside _where);
///   * a pending job is polled every 10 s for 2 minutes, a lost one is
///     resubmitted, neither reads the location again;
///   * busy / rate limited / timeout / 5xx: retried after 5 min, 30 min
///     and 2 h, then 'unavailable'; offline and the app leaving the
///     foreground are not tries;
///   * a cached answer makes zero lookup calls and lands on the right items.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/meal_country.dart';
import 'package:calorie_tracker/core/place_match.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/assist_places_store.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/photo_location.dart';
import 'package:calorie_tracker/services/places/places.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/fakes.dart';

final DateTime _now = DateTime(2026, 10, 24, 13, 0);
final DateTime _consentAt = DateTime(2026, 10, 24, 8, 0);
const String _today = '2026-10-24';
const String _url = 'https://www.mcdonalds.com/us/en-us/product/big-mac.html';

/// Where the photo was taken (Times Square). Their digits must never show
/// up anywhere the assist writes, sends or logs.
const double _lat = 40.758896;
const double _lon = -73.985130;
const List<String> _coordinateDigits = ['40.75', '40.76', '73.98', '73.99'];

/// Where else a photo can be taken (run 6, the meal country).
const ({double latitude, double longitude}) _shanghai = (
  latitude: 31.2304,
  longitude: 121.4737,
);
const ({double latitude, double longitude}) _madison = (
  latitude: 43.0731,
  longitude: -89.4012,
);
const ({double latitude, double longitude}) _detroit = (
  latitude: 42.3314,
  longitude: -83.0458,
);

const LookupSupport _anthropic = LookupSupport(
  supported: true,
  recipient: LookupRecipient.anthropic,
  locationAllowed: true,
);
const LookupSupport _claudePlanHttps = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: true,
  recipientHostTag: 'abcd1234',
);
const LookupSupport _claudePlanHttp = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: false,
  recipientHostTag: 'abcd1234',
);

Map<String, dynamic> _capture({
  int? accuracy = 10,
  int? fixDelta = 3,
  bool hasGps = true,
  bool glasses = false,
}) => {
  if (glasses) 'device': 'meta_glasses',
  if (glasses) 'signal': 'filename',
  'has_gps': hasGps,
  'gps_acc_m': ?accuracy,
  'gps_fix_delta_s': ?fixDelta,
};

/// An unbranded Big Mac photographed at a restaurant: only the location
/// can name its chain.
Map<String, dynamic> _bigMac({
  String? confidence = 'low',
  String? context = 'restaurant',
  String brand = '',
  Map<String, dynamic>? capture,
  String name = 'Big Mac',
}) => {
  'is_food': true,
  'food_items': [
    {
      'name': name,
      'estimated_calories': 540,
      'protein_g': 24,
      'carbs_g': 44,
      'fat_g': 30,
      'brand': brand,
      'qty': 1,
      'unit': 'sandwich',
    },
  ],
  'total_calories': 540,
  'total_protein_g': 24,
  'total_carbs_g': 44,
  'total_fat_g': 30,
  'meal_description': 'A burger on a tray',
  'estimate_confidence': ?confidence,
  'restaurant_context': ?context,
  'portion_state': 'whole',
  'order_merchant': '',
  'capture': capture ?? _capture(),
};

Map<String, dynamic> _found({
  String chainKey = 'mcdonalds',
  List<Map<String, dynamic>>? matches,
}) => {
  'status': 'found',
  'chain_key': chainKey,
  'restaurant_name': "McDonald's",
  'matches':
      matches ??
      [
        {
          'item_index': 0,
          'menu_item': 'Big Mac',
          'match_type': 'exact_item',
          'is_drink': false,
          'components': <Object>[],
          'options': [
            {
              'label': '',
              'serving': '1 sandwich',
              'unit': 'sandwich',
              'calories': 590,
              'calories_range': null,
              'protein_g': 25,
              'carbs_g': 46,
              'fat_g': 34,
            },
          ],
        },
      ],
  'source_url': _url,
  'source_title': 'Big Mac: Calories & Nutrition',
  'source_type': 'official_site',
  'source_year': 2026,
  'match_confidence': 0.9,
  'notes': '',
};

const String _evidenceText =
    'Big Mac 590 Cal. 25 g protein, 46 g carbs, 34 g fat. '
    'Medium French Fries 320 Cal. 5 g protein, 43 g carbs, 15 g fat.';

LookupOutcome _done({
  Map<String, dynamic>? json,
  LookupRecipient provider = LookupRecipient.anthropic,
  bool verbatim = true,
  String? jobId,
}) => LookupOutcome(
  kind: LookupOutcomeKind.done,
  provider: provider,
  jobId: jobId,
  result: LookupResult.parse(json ?? _found(), itemCount: 12),
  citedUrls: const [_url, 'https://example.com/unrelated'],
  evidence: [
    LookupEvidence(url: _url, text: _evidenceText, verbatim: verbatim),
    const LookupEvidence(
      url: 'https://example.com/unrelated',
      text: 'Something else entirely',
      verbatim: true,
    ),
  ],
);

LookupOutcome _pending(String jobId) => LookupOutcome(
  kind: LookupOutcomeKind.pending,
  provider: LookupRecipient.claudePlan,
  jobId: jobId,
);

LookupOutcome _failure(
  LookupOutcomeKind kind,
  LookupFailureCode code, {
  bool transient = true,
}) => LookupOutcome(
  kind: kind,
  provider: LookupRecipient.anthropic,
  failure: LookupFailure(code, transient: transient),
);

NearbyPlace _poi(
  String name,
  int distanceM, {
  String category = 'restaurant',
  String? country,
}) => NearbyPlace(
  name: name,
  category: PlaceCategory.fromWire(category),
  distanceM: distanceM,
  countryCode: country,
);

/// A lone McDonald's 8 m away: auto-picked.
final List<NearbyPlace> _loneMcDonalds = [
  _poi("McDonald's", 8),
  _poi("Joe's Diner", 30),
];

/// Four table chains 25–38 m away, none clear: candidates, no pick.
final List<NearbyPlace> _fourChains = [
  _poi('Chipotle Mexican Grill', 25),
  _poi('Qdoba Mexican Eats', 30),
  _poi('Subway', 35),
  _poi('Panera Bread', 38),
];

/// Times Square (the live MapKit probe, lane_places/ts_60.txt): dense.
final List<NearbyPlace> _timesSquare = [
  _poi('Anita Gelato', 6, category: 'cafe'),
  _poi('Edawy Bro', 11),
  _poi("McDonald's", 15),
  _poi('Cbre 1540 Broadway', 19),
  _poi('Starbucks Coffee Company', 24, category: 'cafe'),
  _poi('Asian Street Eats', 28),
  _poi('Popeyes Louisiana Kitchen', 33),
  _poi("I'm donut ?", 37, category: 'bakery'),
  _poi('Tenders', 46),
];

class _Lookups implements LookupClient {
  LookupSupport support = _anthropic;
  final List<LookupRequest> submits = [];
  final List<String> polls = [];
  Future<LookupOutcome> Function(LookupRequest request)? onSubmit;
  Future<LookupOutcome> Function(String jobId)? onPoll;

  @override
  LookupSupport lookupSupport() => support;

  @override
  Future<LookupOutcome> submit(
    LookupRequest request, {
    List<String> chainDomains = const [],
    LookupCancelToken? cancel,
    LookupRecipient? expectedRecipient,
    String? expectedRecipientStamp,
  }) async {
    submits.add(request);
    final f = onSubmit;
    return f == null ? _done() : f(request);
  }

  @override
  Future<LookupOutcome> poll(String jobId) async {
    polls.add(jobId);
    final f = onPoll;
    return f == null ? _done(provider: LookupRecipient.claudePlan) : f(jobId);
  }
}

/// The library's record of where each asset was taken. Byte reads are not
/// part of this seam at all (photo_location_test pins that).
class _Source implements AssetLocationSource {
  final List<String> asked = [];
  ({double latitude, double longitude})? at = (latitude: _lat, longitude: _lon);

  @override
  Future<({double latitude, double longitude})?> assetLatLng(
    String assetId,
  ) async {
    asked.add(assetId);
    return at;
  }
}

class _Places implements PlaceResolver {
  final List<int> radii = [];
  NearbyFood answer = NearbyFood(PlacesStatus.ok, places: _loneMcDonalds);

  /// The point of the last call, compared and dropped by the test.
  final List<String> points = [];

  @override
  Future<NearbyFood> nearbyFood(
    PhotoPoint point, {
    int radiusM = 100,
    Set<PlaceCategory> categories = defaultFoodCategories,
  }) async {
    radii.add(radiusM);
    points.add('${point.lat},${point.lon}');
    return answer;
  }
}

class _Harness {
  _Harness(this.root, this.prefs);

  final Directory root;
  final SharedPreferences prefs;
  final FakeDao dao = FakeDao();
  final _Lookups lookups = _Lookups();
  final _Source source = _Source();
  final _Places places = _Places();
  final ValueNotifier<int> busy = ValueNotifier<int>(0);
  final ValueNotifier<int> settingsChanges = ValueNotifier<int>(0);
  final List<AssistAppliedNotice> notices = [];
  bool foreground = true;
  bool readerEnabled = true;

  /// The phone's region (MealAssist's deviceRegion).
  String? region = 'US';
  DateTime now = _now;
  AssistSettingsView settings = AssistSettingsView(
    mode: AssistMode.auto,
    useLocation: true,
    consentAt: _consentAt,
    consentRecipient: 'anthropic',
  );

  late final LocalNoBackupStore store = LocalNoBackupStore(
    root: () async => root,
    createMissingDirectory: true,
    clock: () => now,
  );
  late final AssistDailyBudget budget = AssistDailyBudget(
    prefs,
    clock: () => now,
  );
  late final AssistLocalState state = AssistLocalState(store, clock: () => now);
  late final AssistPlacesStore placesStore = AssistPlacesStore(
    store,
    clock: () => now,
  );

  late final MealAssist assist = build();

  MealAssist build({
    DateTime Function()? clock,
    Duration pollInterval = kAssistPollInterval,
    Duration pollWindow = kAssistPollWindow,
  }) => MealAssist(
    dao: dao,
    lookups: lookups,
    analyzerBusy: busy,
    pipelineIdle: () => true,
    inUse: (_) => false,
    budget: budget,
    state: state,
    settings: () => settings,
    settingsChanges: settingsChanges,
    onApplied: notices.add,
    inForeground: () => foreground,
    country: () => region,
    location: PhotoLocationReader(source, enabled: readerEnabled),
    places: places,
    placesStore: placesStore,
    clock: clock ?? () => now,
    settleDelay: const Duration(milliseconds: 10),
    busyRetry: const Duration(milliseconds: 20),
    pollInterval: pollInterval,
    pollWindow: pollWindow,
  );

  int add(
    Map<String, dynamic> analysis, {
    String timestamp = '2026-10-24T12:30:00.000',
    String fileId = 'asset-1',
  }) => dao.put(
    Meal(
      id: 0,
      date: _today,
      time: '12:30 PM',
      timestamp: timestamp,
      source: MealSource.appWatch,
      fileId: fileId,
      analysis: analysis,
    ),
  );

  Map<String, dynamic> analysisOf(int id) => dao.byId(id).analysis;
  Map<String, dynamic>? blockOf(int id) =>
      analysisOf(id)['assist'] as Map<String, dynamic>?;

  PlaceCell get cell => PlaceCell.fromLatLon(_lat, _lon)!;

  /// Every byte the assist keeps on the phone.
  String everythingStored() {
    final dir = Directory('${root.path}/$localStoreDirName');
    if (!dir.existsSync()) return '';
    return [
      for (final f in dir.listSync().whereType<File>())
        if (!f.path.endsWith('assist_places.json')) f.readAsStringSync(),
    ].join('\n');
  }

  Map<String, Object?> document(String name) {
    final f = File('${root.path}/$localStoreDirName/$name.json');
    if (!f.existsSync()) return {};
    return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  }
}

Future<void> _until(bool Function() done, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir.path;
}

/// The text of the async method whose signature starts with [signature],
/// braces matched from its body (past any named parameters).
String _body(String source, String signature) {
  final from = source.indexOf(signature);
  expect(from, isNot(-1), reason: signature);
  var depth = 0;
  final open = source.indexOf(') async {', from) + ') async '.length;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(from, i + 1);
  }
  fail('unbalanced: $signature');
}

void main() {
  late Directory root;
  late _Harness h;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('meal_assist_location_test');
    SharedPreferences.setMockInitialValues({});
    h = _Harness(root, await SharedPreferences.getInstance());
  });
  tearDown(() {
    h.assist.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('when the location is read', () {
    test('a low-confidence restaurant meal with GPS: the position, one '
        'places query at the fix\'s radius, the chain sent', () async {
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.source.asked, ['asset-1']);
      expect(h.places.radii, [40], reason: 'clamp(2 × 10 m, 40, 150)');
      final request = h.lookups.submits.single;
      expect(request.chainKeys, ['mcdonalds']);
      expect(h.blockOf(id)?['evidence'], 'location');
      expect(
        h.blockOf(id)?['status'],
        AssistStatus.suggested,
        reason: 'a first visit is always a one-tap suggestion',
      );
      expect(h.blockOf(id)?['reason'], AssistReason.locationUnconfirmed);
    });

    test('home, packaged or unknown: the location is never read — not even '
        'in Always, not even with a printed brand', () async {
      h.settings = AssistSettingsView(
        mode: AssistMode.always,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      for (final context in ['home', 'packaged', 'unknown', null]) {
        h.add(_bigMac(context: context));
        h.add(
          _bigMac(context: context, brand: "McDonald's"),
          timestamp: '2026-10-24T12:00:00.000',
        );
      }
      await h.assist.sweep();
      expect(h.source.asked, isEmpty);
      expect(h.places.radii, isEmpty);
      // The branded ones took the brand path; nothing location-derived.
      expect(h.lookups.submits, isNotEmpty);
      for (final r in h.lookups.submits) {
        expect(r.chainKeys, ['mcdonalds']);
      }
    });

    test(
      'takeout takes the brand path only: its position is read for the '
      'meal country alone (the branded one), Apple Maps is not asked',
      () async {
        h.add(_bigMac(context: 'takeout', brand: "McDonald's"));
        h.add(
          _bigMac(context: 'takeout'),
          timestamp: '2026-10-24T12:10:00.000',
          fileId: 'asset-2',
        );
        await h.assist.sweep();
        expect(h.source.asked, [
          'asset-1',
        ], reason: 'nothing to ask about the other');
        expect(h.places.radii, isEmpty);
        expect(h.lookups.submits, hasLength(1));
        expect(h.lookups.submits.single.body['country'], 'US');
      },
    );

    test('the sub-toggle off: brand only, nothing read', () async {
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      h.add(_bigMac());
      h.add(_bigMac(brand: "McDonald's"), timestamp: '2026-10-24T12:10:00.000');
      await h.assist.sweep();
      expect(h.source.asked, isEmpty);
      expect(h.lookups.submits.single.chainKeys, ['mcdonalds']);
    });

    test('an http:// own server: the location path is skipped (brand-only), '
        'https:// takes it', () async {
      h.lookups.support = _claudePlanHttp;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      h.lookups.onSubmit = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      final plain = h.add(_bigMac());
      final branded = h.add(
        _bigMac(brand: "McDonald's"),
        timestamp: '2026-10-24T12:10:00.000',
      );
      await h.assist.sweep();
      expect(h.source.asked, isEmpty);
      expect(h.places.radii, isEmpty);
      expect(h.lookups.submits.single.chainKeys, ['mcdonalds']);
      expect(h.blockOf(plain), isNull);
      expect(h.blockOf(branded)?['evidence'], 'item_brand');

      h.lookups.support = _claudePlanHttps;
      await h.assist.sweep();
      expect(h.source.asked, ['asset-1']);
    });

    test('no GPS, no library asset, or a reader that is off (Android): '
        'nothing is read', () async {
      h.add(_bigMac(capture: _capture(hasGps: false)));
      h.add(_bigMac(), fileId: '', timestamp: '2026-10-24T12:10:00.000');
      h.add(
        {..._bigMac()}..remove('capture'),
        timestamp: '2026-10-24T12:20:00.000',
      );
      await h.assist.sweep();
      expect(h.source.asked, isEmpty);
      expect(h.lookups.submits, isEmpty);

      h.readerEnabled = false;
      final android = h.build();
      h.add(_bigMac(), timestamp: '2026-10-24T12:25:00.000');
      await android.sweep();
      android.dispose();
      expect(h.source.asked, isEmpty);
      expect(h.places.radii, isEmpty);
      expect(h.lookups.submits, isEmpty);
    });

    test('a coarse or stale fix is never read', () async {
      h.add(_bigMac(capture: _capture(accuracy: 150)));
      h.add(
        _bigMac(capture: _capture(fixDelta: 3600)),
        timestamp: '2026-10-24T12:10:00.000',
      );
      await h.assist.sweep();
      expect(h.source.asked, isEmpty);
      expect(h.lookups.submits, isEmpty);
      final codes = [for (final e in await h.state.decisions()) e.code];
      // Newest meal first.
      expect(codes, ['place_inaccurate', 'place_stale']);
    });
  });

  group('the place step', () {
    test('a zone: Apple Maps is not asked, nothing is looked up, and the '
        'meal is not asked again', () async {
      await h.placesStore.addZone(h.cell);
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.source.asked, hasLength(1));
      expect(h.places.radii, isEmpty);
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull, reason: 'nothing location-shaped exported');
      expect((await h.state.decisions()).single.code, 'place_zone');
      await h.assist.sweep();
      expect(h.source.asked, hasLength(1), reason: 'denylisted');
    });

    test("'Clear learned places' also forgets the answer cache and the "
        'jobs with what their location found', () async {
      h.lookups.support = _claudePlanHttps;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: _claudePlanHttps.recipientStamp,
      );
      h.lookups.onSubmit = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      h.add(_bigMac());
      await h.assist.sweep();
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      h.add(
        _bigMac(name: 'Quarter Pounder'),
        timestamp: '2026-10-24T12:40:00.000',
        fileId: 'a2',
      );
      await h.assist.sweep();
      expect(h.document(assistCacheDocument), isNot(isEmpty));
      expect(await h.state.jobs(), hasLength(1));
      expect(await h.assist.clearLearnedPlaces(), isTrue);
      expect(h.document(assistCacheDocument), isEmpty);
      expect(await h.state.jobs(), isEmpty);
    });

    test("'Clear learned places' (R7a) forgets every zone, confirmation "
        'and block, through the store the place step reads', () async {
      await h.placesStore.addZone(h.cell);
      await h.placesStore.confirm('mcdonalds', h.cell);
      expect((await h.placesStore.read()).zones, isNotEmpty);
      expect(await h.assist.clearLearnedPlaces(), isTrue);
      final left = await h.placesStore.read();
      expect(left.zones, isEmpty);
      expect(left.confirmed, isEmpty);
      expect(left.blocked, isEmpty);
      // The zone is gone: Apple Maps is asked again for this spot.
      h.add(_bigMac());
      await h.assist.sweep();
      expect(h.places.radii, isNotEmpty);
    });

    test('a zone next door (the 3×3 neighbourhood) counts too', () async {
      await h.placesStore.addZone(PlaceCell.fromLatLon(_lat + 0.001, _lon)!);
      h.add(_bigMac());
      await h.assist.sweep();
      expect(h.places.radii, isEmpty);
    });

    test('dense: the candidates are sent, the answer is a suggestion at '
        'most — even where the user confirmed that chain', () async {
      await h.placesStore.confirm('mcdonalds', h.cell);
      h.places.answer = NearbyFood(PlacesStatus.ok, places: _timesSquare);
      final id = h.add(_bigMac(capture: _capture(accuracy: 30)));
      await h.assist.sweep();
      final request = h.lookups.submits.single;
      expect(request.chainKeys.length, inInclusiveRange(2, 3));
      expect(request.chainKeys.first, 'mcdonalds');
      expect(request.chainKeys, contains('starbucks'));
      final block = h.blockOf(id)!;
      expect(block['status'], AssistStatus.suggested);
      expect(block['evidence'], 'location');
      expect(h.analysisOf(id)['total_calories'], 540);
      expect(h.notices, isEmpty);
    });

    test('confirmed at a lone spot: location alone applies', () async {
      await h.placesStore.confirm('mcdonalds', h.cell);
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits.single.chainKeys, ['mcdonalds']);
      final block = h.blockOf(id)!;
      expect(block['status'], AssistStatus.applied);
      expect(block['evidence'], 'location_confirmed');
      expect(h.analysisOf(id)['total_calories'], 590);
      expect(h.notices.single.brandName, "McDonald's");
    });

    test('a glasses photo without a fix time is unverified: a suggestion, '
        'even where confirmed', () async {
      await h.placesStore.confirm('mcdonalds', h.cell);
      final id = h.add(
        _bigMac(
          capture: _capture(accuracy: null, fixDelta: null, glasses: true),
        ),
      );
      await h.assist.sweep();
      expect(h.places.radii, [130], reason: 'glasses default 65 m');
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
    });

    test('the request names at most 3 chains, and only 1 when one was '
        'auto-picked', () async {
      h.places.answer = NearbyFood(PlacesStatus.ok, places: _fourChains);
      h.add(_bigMac());
      h.lookups.onSubmit = (_) async =>
          _done(json: {..._found(), 'status': 'no_match', 'chain_key': null});
      await h.assist.sweep();
      final ambiguous = h.lookups.submits.single;
      expect(ambiguous.chainKeys, ['chipotle', 'qdoba', 'subway']);
      expect((ambiguous.body['chains'] as List), hasLength(3));

      h.places.answer = NearbyFood(PlacesStatus.ok, places: _loneMcDonalds);
      h.add(_bigMac(), timestamp: '2026-10-24T12:40:00.000', fileId: 'a2');
      await h.assist.sweep();
      final picked = h.lookups.submits.last;
      expect(picked.chainKeys, ['mcdonalds']);
      expect((picked.body['chains'] as List), hasLength(1));
    });

    test(
      'a printed brand leads; the location adds its chains after it',
      () async {
        h.places.answer = NearbyFood(PlacesStatus.ok, places: _fourChains);
        h.add(_bigMac(brand: "McDonald's"));
        await h.assist.sweep();
        expect(h.lookups.submits.single.chainKeys, [
          'mcdonalds',
          'chipotle',
          'qdoba',
        ]);
      },
    );

    test('a blocked chain is no candidate', () async {
      await h.placesStore.block('mcdonalds', h.cell);
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull);
      expect(
        (await h.state.decisions()).single.code,
        PlaceMatchReason.chainBlocked.wire,
      );
    });

    test(
      'no chain nearby: nothing looked up or written; not asked again',
      () async {
        h.places.answer = NearbyFood(
          PlacesStatus.ok,
          places: [_poi("Joe's Diner", 12)],
        );
        final id = h.add(_bigMac());
        await h.assist.sweep();
        await h.assist.sweep();
        expect(h.places.radii, hasLength(1));
        expect(h.lookups.submits, isEmpty);
        expect(h.blockOf(id), isNull);
        expect(
          (await h.state.decisions()).single.code,
          PlaceMatchReason.noChain.wire,
        );
      },
    );

    test('Apple Maps throttled: tried again later, not given up', () async {
      h.places.answer = const NearbyFood(PlacesStatus.throttled);
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect((await h.state.misses())[id], isNull);
      // Held: the position is not even read while Maps asks us to wait.
      await h.assist.sweep();
      expect(h.source.asked, hasLength(1));
      h.now = _now.add(placesThrottleBackoff + const Duration(seconds: 1));
      h.places.answer = NearbyFood(PlacesStatus.ok, places: _loneMcDonalds);
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test('a failed places query: the brand path goes on alone; without a '
        'brand the meal gets one more chance', () async {
      h.places.answer = const NearbyFood(
        PlacesStatus.error,
        errorCode: 'timeout',
      );
      final branded = h.add(_bigMac(brand: "McDonald's"));
      final plain = h.add(_bigMac(), timestamp: '2026-10-24T12:10:00.000');
      await h.assist.sweep();
      expect(h.lookups.submits.single.chainKeys, ['mcdonalds']);
      expect(h.blockOf(branded)?['evidence'], 'item_brand');
      expect((await h.state.misses())[plain], 1);
      await h.assist.sweep();
      expect((await h.state.misses())[plain], assistMissesBeforeDenylist);
      await h.assist.sweep();
      expect(h.places.radii, hasLength(3), reason: 'then never again');
    });

    test('the editor\'s lookup: "Use location" takes the path, "Brand '
        'only" reads nothing', () async {
      h.settings = AssistSettingsView(
        mode: AssistMode.off,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      final id = h.add(_bigMac());
      final brandOnly = await h.assist.lookupNow(id);
      expect(brandOnly.code, AssistSkip.noBrand);
      expect(h.source.asked, isEmpty);
      final located = await h.assist.lookupNow(id, useLocation: true);
      expect(h.source.asked, ['asset-1']);
      expect(located.wrote, isTrue);
      expect(h.blockOf(id)?['trigger'], 'manual');
    });
  });

  group('the meal country (run 6)', () {
    // The owner travels between the US and China; the phone's region
    // stays US. A McDonald's in Shanghai is not a US McDonald's.

    test('the China trip: a US-region phone, a branded photo taken in '
        'Shanghai: no lookup, no places query, not asked again', () async {
      h.source.at = _shanghai;
      final id = h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.source.asked, ['asset-1'], reason: 'read once, on the phone');
      expect(h.places.radii, isEmpty, reason: 'Apple Maps is not asked');
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull, reason: 'not even a suggestion');
      expect(h.assist.lookupsToday, 0, reason: 'no plan usage');
      expect(
        [for (final e in await h.state.decisions()) e.code],
        [AssistSkip.outsideUs],
      );
      expect((await h.state.misses())[id], assistMissesBeforeDenylist);
      await h.assist.sweep();
      expect(h.source.asked, hasLength(1), reason: 'not read again');
      // Nothing about where it was is kept: a code only.
      for (final digits in ['31.23', '121.47']) {
        expect(h.everythingStored(), isNot(contains(digits)));
      }
    });

    test('the China trip, takeout: the bag\'s brand is not enough, the '
        'photo\'s position decides', () async {
      h.source.at = _shanghai;
      final id = h.add(_bigMac(context: 'takeout', brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.source.asked, ['asset-1']);
      expect(h.places.radii, isEmpty);
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull);
    });

    test('the China trip: an answer cached in the US is not used', () async {
      h.source.at = _madison;
      final us = h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.blockOf(us), isNotNull);
      h.source.at = _shanghai;
      final cn = h.add(
        _bigMac(brand: "McDonald's"),
        timestamp: '2026-10-24T12:40:00.000',
        fileId: 'asset-2',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1), reason: 'no new lookup');
      expect(h.blockOf(cn), isNull, reason: 'and no cached numbers');
    });

    test('the China trip, the editor: "Use location" says outside the US; '
        '"Brand only" reads nothing and goes by the region', () async {
      h.settings = AssistSettingsView(
        mode: AssistMode.off,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      h.source.at = _shanghai;
      final id = h.add(_bigMac(brand: "McDonald's"));
      final located = await h.assist.lookupNow(id, useLocation: true);
      expect(located.code, AssistSkip.outsideUs);
      expect(located.wrote, isFalse);
      expect(h.lookups.submits, isEmpty);
      expect(h.source.asked, ['asset-1']);
      expect(await h.state.decisions(), isEmpty, reason: 'shown, not logged');
      // Brand only reads no location at all: the phone's region (US) is
      // all it knows.
      final brandOnly = await h.assist.lookupNow(id);
      expect(h.source.asked, hasLength(1));
      expect(brandOnly.wrote, isTrue);
      expect(h.lookups.submits.single.body['country'], 'US');
    });

    test('no GPS in the photo, a US region: looked up as before', () async {
      final id = h.add(
        _bigMac(brand: "McDonald's", capture: _capture(hasGps: false)),
      );
      await h.assist.sweep();
      expect(h.source.asked, isEmpty);
      expect(h.lookups.submits.single.body['country'], 'US');
      expect(h.blockOf(id)?['status'], AssistStatus.applied);
    });

    test('no region (a locale without one) and no GPS: nothing is looked '
        'up, automatically or from the editor', () async {
      h.region = null;
      final id = h.add(
        _bigMac(brand: "McDonald's", capture: _capture(hasGps: false)),
      );
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull);
      expect(h.assist.lookupsToday, 0);
      // Not logged and not denylisted: a region set later can still tell.
      expect(await h.state.decisions(), isEmpty);
      expect((await h.state.misses())[id], isNull);
      final manual = await h.assist.lookupNow(id, useLocation: true);
      expect(manual.code, AssistSkip.regionUnknown);
      expect(h.lookups.submits, isEmpty);
    });

    test('no region, a photo taken in the US: the position decides', () async {
      h.region = null;
      final id = h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.lookups.submits.single.body['country'], 'US');
      expect(h.blockOf(id), isNotNull);
    });

    test('another region and no position: outside the US', () async {
      h.region = 'CN';
      final id = h.add(
        _bigMac(brand: "McDonald's", capture: _capture(hasGps: false)),
      );
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull);
      expect(
        [for (final e in await h.state.decisions()) e.code],
        [AssistSkip.outsideUs],
      );
    });

    test('near a border (downtown Detroit): too close to tell, so not the '
        'US — Apple Maps is not asked', () async {
      h.source.at = _detroit;
      h.add(_bigMac());
      h.add(
        _bigMac(brand: "McDonald's"),
        timestamp: '2026-10-24T12:10:00.000',
        fileId: 'asset-2',
      );
      await h.assist.sweep();
      expect(h.places.radii, isEmpty);
      expect(h.lookups.submits, isEmpty);
    });

    test('Apple Maps files the nearest places outside the US: a veto, even '
        'for a position inside the outline', () async {
      h.places.answer = NearbyFood(
        PlacesStatus.ok,
        places: [
          _poi("McDonald's", 8, country: 'CA'),
          _poi("Joe's Diner", 30, country: 'CA'),
        ],
      );
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.places.radii, hasLength(1));
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull);
      expect(
        [for (final e in await h.state.decisions()) e.code],
        [AssistSkip.outsideUs],
      );

      // Filed in the US: looked up as before.
      h.places.answer = NearbyFood(
        PlacesStatus.ok,
        places: [
          _poi("McDonald's", 8, country: 'US'),
          _poi("Joe's Diner", 30),
        ],
      );
      final other = h.add(
        _bigMac(name: 'Quarter Pounder'),
        timestamp: '2026-10-24T12:10:00.000',
        fileId: 'asset-2',
      );
      await h.assist.sweep();
      expect(h.lookups.submits.single.chainKeys, ['mcdonalds']);
      expect(h.blockOf(other), isNotNull);
    });

    test('an http:// own server: no position is read, not even for the '
        'meal country — the region decides', () async {
      h.lookups.support = _claudePlanHttp;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      h.lookups.onSubmit = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      h.source.at = _shanghai;
      h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.source.asked, isEmpty);
      expect(h.lookups.submits.single.body['country'], 'US');
    });

    test('a job keeps the country it was submitted with: polls read '
        'nothing', () async {
      h.lookups.support = _claudePlanHttps;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      final id = h.add(_bigMac(context: 'takeout', brand: "McDonald's"));
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      await h.assist.sweep();
      expect((await h.state.jobs())[id]?.country, 'US');
      expect(h.source.asked, hasLength(1));
      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      await h.assist.sweep();
      expect(h.lookups.polls, ['job_abcdef12']);
      expect(h.source.asked, hasLength(1), reason: 'not read again');
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
    });

    test('property: the request\'s country and the decision\'s are one '
        'value — US — and a lookup happens exactly when the meal country '
        'is the US', () async {
      final rng = math.Random(20261025);
      const positions = <({double latitude, double longitude})?>[
        null,
        _madison,
        (latitude: _lat, longitude: _lon),
        _shanghai,
        (latitude: 43.6532, longitude: -79.3832), // Toronto
        _detroit,
        (latitude: 21.3069, longitude: -157.8583), // Honolulu
        (latitude: 18.4655, longitude: -66.1057), // San Juan
        (latitude: 32.5149, longitude: -117.0382), // Tijuana
      ];
      const regions = [null, 'US', 'PR', 'CN', 'CA', 'us'];
      const contexts = ['restaurant', 'takeout', 'home'];
      const placeCountries = [null, 'US', 'CA'];
      for (var i = 0; i < 160; i++) {
        final dir = Directory.systemTemp.createTempSync('meal_country_prop');
        SharedPreferences.setMockInitialValues({});
        final t = _Harness(dir, await SharedPreferences.getInstance());
        try {
          final position = positions[rng.nextInt(positions.length)];
          final region = regions[rng.nextInt(regions.length)];
          final context = contexts[rng.nextInt(contexts.length)];
          final branded = rng.nextBool();
          final useLocation = rng.nextBool();
          final http = rng.nextInt(4) == 0;
          final placeCountry = placeCountries[rng.nextInt(3)];
          t.region = region;
          t.source.at = position;
          t.places.answer = NearbyFood(
            PlacesStatus.ok,
            places: [
              _poi("McDonald's", 8, country: placeCountry),
              _poi("Joe's Diner", 30, country: placeCountry),
            ],
          );
          t.lookups.support = http ? _claudePlanHttp : _anthropic;
          if (http) {
            t.lookups.onSubmit = (_) async =>
                _done(provider: LookupRecipient.claudePlan, verbatim: false);
          }
          t.settings = AssistSettingsView(
            mode: AssistMode.always,
            useLocation: useLocation,
            consentAt: _consentAt,
            consentRecipient: http ? 'claude_plan:abcd1234' : 'anthropic',
          );
          final id = t.add(
            _bigMac(
              context: context,
              brand: branded ? "McDonald's" : '',
              capture: _capture(hasGps: position != null),
            ),
          );
          await t.assist.sweep();

          final why =
              '#$i at=$position region=$region $context branded=$branded '
              'useLocation=$useLocation http=$http places=$placeCountry';
          final pointRead =
              useLocation &&
              !http &&
              position != null &&
              (context == 'restaurant' || context == 'takeout');
          final locating = pointRead && context == 'restaurant';
          final askedMaps = t.places.radii.isNotEmpty;
          if (askedMaps) {
            expect(locating, isTrue, reason: why);
            expect(
              pointInUs(position!.latitude, position.longitude),
              isTrue,
              reason: 'Apple Maps only hears of US photos: $why',
            );
          }
          final expected = decideMealCountry(
            lat: pointRead ? position.latitude : null,
            lon: pointRead ? position.longitude : null,
            accuracyM: 10,
            placeCountries: askedMaps ? [placeCountry, placeCountry] : const [],
            deviceRegion: region,
          );
          final askable = branded || locating;
          final submitted = t.lookups.submits.isNotEmpty;
          expect(submitted, expected == kMealCountryUs && askable, reason: why);
          if (submitted) {
            expect(t.lookups.submits.single.body['country'], 'US', reason: why);
            final block = t.blockOf(id);
            expect(block, isNotNull, reason: why);
            expect(block?['reason'], isNot(AssistReason.notUs), reason: why);
          } else {
            expect(t.blockOf(id), isNull, reason: why);
          }
        } finally {
          t.assist.dispose();
          dir.deleteSync(recursive: true);
        }
      }
    });
  });

  group('privacy', () {
    test('the coordinates leave nothing behind: not in the request, the '
        'meal, the jobs, the cache or the decision log', () async {
      h.lookups.support = _claudePlanHttps;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      final a = h.add(_bigMac());
      final b = h.add(
        _bigMac(name: 'Quarter Pounder'),
        timestamp: '2026-10-24T12:10:00.000',
        fileId: 'asset-2',
      );
      await h.assist.sweep();
      expect(h.places.points, hasLength(2), reason: 'Apple Maps got them');
      expect(await h.state.jobs(), hasLength(2));

      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      await h.assist.sweep();

      final sent = [for (final r in h.lookups.submits) r.toJson()].join('\n');
      final written = jsonEncode([h.analysisOf(a), h.analysisOf(b)]);
      final kept = h.everythingStored();
      expect(kept, contains('mcdonalds'), reason: 'the chain key is kept');
      for (final text in [sent, written, kept]) {
        for (final digits in _coordinateDigits) {
          expect(text, isNot(contains(digits)));
        }
        expect(text, isNot(contains(h.cell.wire)));
        expect(text, isNot(contains("Joe's Diner")));
      }
    });

    test('the position lives only inside _where (and, for the editor\'s '
        'feedback, _photoCell, which returns a cell): no field, no other '
        'method, no place text', () {
      final src = File(
        '${_appRoot()}/lib/services/assist/meal_assist.dart',
      ).readAsStringSync();
      final body = _body(src, 'Future<_Where> _where(');
      expect(body, contains('? await reader.forAsset(meal.fileId)'));
      // What it tells about the position is a country code.
      expect(
        body,
        contains(
          'final country = decideMealCountry(\n        lat: point?.lat,',
        ),
      );
      final cell = _body(
        src,
        'Future<PlaceCell?> _photoCell(Meal meal) async {',
      );
      expect(cell, contains('final point = await reader.forAsset('));
      expect(
        cell,
        contains('return PlaceCell.fromLatLon(point.lat, point.lon);'),
      );
      expect('point'.allMatches(cell), hasLength(4));
      final rest = src.replaceFirst(body, '').replaceFirst(cell, '');
      for (final banned in [
        'forAsset(',
        'nearbyFood(',
        'PlaceCell.fromLatLon(',
        'matchPlaces(',
        'PhotoPoint',
        'NearbyPlace',
        'NearbyFood',
      ]) {
        expect(rest, isNot(contains(banned)), reason: banned);
      }
      expect(RegExp(r'\.(lat|lon)\b').hasMatch(rest), isFalse);
      // What leaves it is chain keys and flags.
      expect(
        body,
        contains(
          'place: AssistPlaceContext(\n          chains: match.lookupChainKeys,',
        ),
      );
    });
  });

  group('Claude Plan jobs', () {
    setUp(() {
      h.lookups.support = _claudePlanHttps;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
    });

    test('pending → polled every 10 s → done → recorded; the location is '
        'read once, the job keeps what it found', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      await h.assist.sweep();
      final job = (await h.state.jobs())[id]!;
      expect(job.jobId, 'job_abcdef12');
      expect(job.place?.chains, ['mcdonalds']);
      expect(job.place?.picked, 'mcdonalds');
      expect(job.nextAt, _now.add(kAssistPollInterval).toUtc());
      final stored = jsonEncode(h.document(assistJobsDocument));
      expect(stored, isNot(contains(h.cell.wire)));

      // Not due yet.
      h.now = _now.add(const Duration(seconds: 5));
      await h.assist.sweep();
      expect(h.lookups.polls, isEmpty);

      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async => _pending('job_abcdef12');
      await h.assist.sweep();
      expect(h.lookups.polls, ['job_abcdef12']);

      // As built the server's text is a search summary (verbatim:false):
      // a suggestion; with page text the same poll applies (next test).
      h.now = _now.add(kAssistPollInterval * 2);
      h.lookups.onPoll = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      await h.assist.sweep();
      expect(h.lookups.polls, hasLength(2));
      expect(h.lookups.submits, hasLength(1), reason: 'polled, not resent');
      expect(h.source.asked, hasLength(1), reason: 'read once');
      expect(h.places.radii, hasLength(1));
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
      expect(h.blockOf(id)?['provider'], 'claude_plan');
      expect(await h.state.jobs(), isEmpty);
    });

    test(
      'a polled answer with page text and a confirmed spot is applied',
      () async {
        await h.placesStore.confirm('mcdonalds', h.cell);
        final id = h.add(_bigMac());
        h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
        await h.assist.sweep();
        h.now = _now.add(kAssistPollInterval);
        h.lookups.onPoll = (_) async =>
            _done(provider: LookupRecipient.claudePlan);
        await h.assist.sweep();
        expect(h.blockOf(id)?['status'], AssistStatus.applied);
        expect(h.blockOf(id)?['evidence'], 'location_confirmed');
        expect(h.notices, hasLength(1));
      },
    );

    test('a job the server lost is resubmitted with the same chains, '
        'without reading the position again', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      await h.assist.sweep();
      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
      );
      h.lookups.onSubmit = (_) async => _pending('job_second_99');
      await h.assist.sweep();
      expect(h.lookups.polls, ['job_abcdef12']);
      expect(h.lookups.submits, hasLength(2));
      expect(h.lookups.submits.last.toJson(), h.lookups.submits.first.toJson());
      expect(h.source.asked, hasLength(1));
      expect((await h.state.jobs())[id]?.jobId, 'job_second_99');
    });

    test('the location turned off meanwhile: the job is not polled, the '
        'meal is asked again brand-only (here: nothing to ask)', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      await h.assist.sweep();
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      h.now = _now.add(kAssistPollInterval);
      await h.assist.sweep();
      expect(h.lookups.polls, isEmpty);
      expect(h.lookups.submits, hasLength(1));
      expect(h.blockOf(id), isNull);
      expect(await h.state.jobs(), isEmpty, reason: 'the job answers nothing');
    });

    test('in the foreground a pending job is polled by itself every '
        'interval, for the window only', () async {
      final start = DateTime.now();
      final assist = h.build(
        clock: () => _now.add(DateTime.now().difference(start)),
        pollInterval: const Duration(milliseconds: 40),
        pollWindow: const Duration(milliseconds: 300),
      );
      addTearDown(assist.dispose);
      h.add(_bigMac());
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      h.lookups.onPoll = (_) async => _pending('job_abcdef12');
      await assist.sweep();
      await _until(() => h.lookups.polls.length >= 3);
      // Past the window: no more polls until the next sweep.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final polled = h.lookups.polls.length;
      expect(polled, lessThanOrEqualTo(9));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.lookups.polls.length, polled);
      expect(h.lookups.submits, hasLength(1));
    });

    test('the editor\'s lookup that came back pending is polled by the '
        'sweep whatever the triggers say, and answered as manual', () async {
      // High confidence: never an automatic trigger.
      final id = h.add(_bigMac(confidence: 'high'));
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      final run = await h.assist.lookupNow(id, useLocation: true);
      expect(run.code, AssistSkip.pending);
      final job = (await h.state.jobs())[id]!;
      expect(job.manual, isTrue);
      expect(job.place?.chains, ['mcdonalds']);

      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      await h.assist.sweep();
      expect(h.lookups.polls, ['job_abcdef12']);
      expect(h.source.asked, hasLength(1));
      expect(h.blockOf(id)?['trigger'], 'manual');
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
      expect(h.notices, isEmpty);
      expect(await h.state.jobs(), isEmpty);
    });

    test('Off forgets the job and what its location found', () async {
      h.add(_bigMac());
      h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
      await h.assist.sweep();
      expect(await h.state.jobs(), hasLength(1));
      await h.assist.turnOff();
      expect(await h.state.jobs(), isEmpty);
      expect(h.document(assistJobsDocument), isEmpty);
    });
  });

  group('retries', () {
    LookupOutcome busy() =>
        _failure(LookupOutcomeKind.busy, LookupFailureCode.server);

    test('busy: retried after 5 min, 30 min and 2 h, then written '
        'unavailable', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => busy();
      await h.assist.sweep();
      var job = (await h.state.jobs())[id]!;
      expect((job.jobId, job.attempts), (null, 1));
      expect(job.nextAt, _now.add(const Duration(minutes: 5)).toUtc());
      expect(job.place?.chains, ['mcdonalds']);

      // Not due before then.
      h.now = _now.add(const Duration(minutes: 4));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));

      h.now = _now.add(const Duration(minutes: 5));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2));
      job = (await h.state.jobs())[id]!;
      expect(job.attempts, 2);
      expect(job.nextAt, h.now.add(const Duration(minutes: 30)).toUtc());
      expect(h.source.asked, hasLength(1), reason: 'the retry reuses it');

      h.now = h.now.add(const Duration(minutes: 30));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(3));
      job = (await h.state.jobs())[id]!;
      expect(job.attempts, 3);
      expect(job.nextAt, h.now.add(const Duration(hours: 2)).toUtc());
      expect(h.blockOf(id), isNull);

      h.now = h.now.add(const Duration(hours: 2));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(4));
      final block = h.blockOf(id)!;
      expect(block['status'], AssistStatus.unavailable);
      expect(block['reason'], 'lookup_server');
      expect(block['provider'], 'anthropic');
      expect(block.containsKey('chain_key'), isFalse);
      expect(h.analysisOf(id)['total_calories'], 540);
      expect(h.dao.byId(id).corrected, isFalse);
      expect(await h.state.jobs(), isEmpty);

      h.now = h.now.add(const Duration(hours: 3));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(4), reason: 'terminal');
    });

    test(
      'a timeout, a rate limit (queue full) and a 5xx count as tries',
      () async {
        final id = h.add(_bigMac(brand: "McDonald's"));
        final answers = [
          _failure(LookupOutcomeKind.offline, LookupFailureCode.timeout),
          _failure(
            LookupOutcomeKind.rateLimited,
            LookupFailureCode.rateLimited,
          ),
          _failure(LookupOutcomeKind.failed, LookupFailureCode.server),
          _failure(LookupOutcomeKind.busy, LookupFailureCode.server),
        ];
        h.lookups.onSubmit = (_) async => answers[h.lookups.submits.length - 1];
        for (var i = 0; i < 4; i++) {
          await h.assist.sweep();
          h.now = h.now.add(const Duration(hours: 3));
        }
        expect(h.lookups.submits, hasLength(4));
        expect(h.blockOf(id)?['status'], AssistStatus.unavailable);
        expect(h.blockOf(id)?['reason'], 'lookup_server');
      },
    );

    test('offline is not a try', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async =>
          _failure(LookupOutcomeKind.offline, LookupFailureCode.network);
      for (var i = 0; i < 5; i++) {
        await h.assist.sweep();
        h.now = h.now.add(const Duration(minutes: 6));
      }
      expect(h.lookups.submits, hasLength(5));
      final job = (await h.state.jobs())[id]!;
      expect(job.attempts, 0);
      expect(h.blockOf(id), isNull);
      expect(h.source.asked, hasLength(1), reason: 'kept with the record');
    });

    test('a failure because the app left the foreground is not a try, and '
        'does not hold the next sweep back', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async {
        h.foreground = false;
        return _failure(LookupOutcomeKind.offline, LookupFailureCode.timeout);
      };
      await h.assist.sweep();
      expect((await h.state.jobs())[id]?.attempts, 0);
      h.foreground = true;
      h.lookups.onSubmit = null;
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2));
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
    });

    test('the app leaving mid-call (and coming back) is seen by the '
        'lifecycle too', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async {
        h.assist.onBackgrounded();
        return busy();
      };
      await h.assist.sweep();
      expect((await h.state.jobs())[id]?.attempts, 0);
    });

    test('the daily cap is not a try: tomorrow', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async =>
          _failure(LookupOutcomeKind.rateLimited, LookupFailureCode.dailyCap);
      await h.assist.sweep();
      expect((await h.state.jobs())[id], isNull);
      h.now = _now.add(const Duration(hours: 3));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test(
      'a polled job that failed counts a try; the next try submits again',
      () async {
        h.lookups.support = _claudePlanHttps;
        h.settings = AssistSettingsView(
          mode: AssistMode.auto,
          useLocation: true,
          consentAt: _consentAt,
          consentRecipient: 'claude_plan:abcd1234',
        );
        final id = h.add(_bigMac());
        h.lookups.onSubmit = (_) async => _pending('job_abcdef12');
        await h.assist.sweep();
        h.now = _now.add(kAssistPollInterval);
        h.lookups.onPoll = (_) async => const LookupOutcome(
          kind: LookupOutcomeKind.busy,
          provider: LookupRecipient.claudePlan,
          jobId: 'job_abcdef12',
          failure: LookupFailure(LookupFailureCode.server, transient: true),
        );
        await h.assist.sweep();
        final job = (await h.state.jobs())[id]!;
        expect((job.jobId, job.attempts), (null, 1));
        h.now = h.now.add(const Duration(minutes: 5));
        await h.assist.sweep();
        expect(h.lookups.polls, hasLength(1));
        expect(h.lookups.submits, hasLength(2));
      },
    );

    test('a manual lookup that fails is shown, not retried', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => busy();
      final run = await h.assist.lookupNow(id, useLocation: true);
      expect(run.code, 'lookup_server');
      expect(await h.state.jobs(), isEmpty);
    });
  });

  group('the on-device cache', () {
    test('names as the cache compares them; the key ignores order and '
        'assumed weights', () {
      expect(assistCacheItemName('Big Mac (220 g)'), 'big mac');
      expect(assistCacheItemName('Fries [约117克]'), 'fries');
      expect(assistCacheItemName('Chicken (spicy)'), 'chicken (spicy)');
      expect(assistCacheItemName('  Large   Fries  '), 'large fries');
      expect(
        assistCacheKey('mcdonalds', ['big mac', 'fries']),
        assistCacheKey('mcdonalds', ['fries', 'big mac']),
      );
      expect(
        assistCacheKey('mcdonalds', ['big mac']),
        isNot(assistCacheKey('burger_king', ['big mac'])),
      );
      expect(assistCacheKey('mcdonalds', ['a']), matches(r'^[0-9a-f]{32}$'));
    });

    test('remapCachedLookup moves each match onto the same name here, the '
        'k-th onto the k-th', () {
      const lookup = AssistLookup(
        result: {
          'chain_key': 'mcdonalds',
          'matches': [
            {'item_index': 0, 'menu_item': 'Big Mac'},
            {'item_index': 1, 'menu_item': 'Fries'},
            {'item_index': 2, 'menu_item': 'Fries'},
            {'item_index': 9, 'menu_item': 'Ghost'},
          ],
        },
        provider: 'anthropic',
      );
      final moved = remapCachedLookup(
        lookup,
        from: ['big mac', 'fries', 'fries'],
        to: ['fries', 'big mac', 'fries'],
      )!;
      final matches = (moved.result! as Map)['matches'] as List;
      expect([for (final m in matches) (m as Map)['item_index']], [1, 0, 2]);
      expect(
        remapCachedLookup(lookup, from: ['big mac'], to: ['whopper']),
        isNull,
      );
    });

    test('a hit makes zero lookup calls, and its numbers land on the right '
        'items of the other meal', () async {
      Map<String, dynamic> meal(List<(String, int)> items) => {
        ..._bigMac(brand: "McDonald's"),
        'food_items': [
          for (final (name, kcal) in items)
            {
              'name': name,
              'estimated_calories': kcal,
              'protein_g': name.contains('Fries') ? 4 : 24,
              'carbs_g': name.contains('Fries') ? 44 : 44,
              'fat_g': name.contains('Fries') ? 16 : 30,
              'brand': "McDonald's",
              'qty': 1,
              'unit': name.contains('Fries') ? 'serving' : 'sandwich',
            },
        ],
        'total_calories': items.fold<int>(0, (s, e) => s + e.$2),
      };
      final fries = {
        'item_index': 1,
        'menu_item': 'Medium French Fries',
        'match_type': 'exact_item',
        'is_drink': false,
        'components': <Object>[],
        'options': [
          {
            'label': 'Medium',
            'serving': '1 serving',
            'unit': 'serving',
            'calories': 320,
            'calories_range': null,
            'protein_g': 5,
            'carbs_g': 43,
            'fat_g': 15,
          },
        ],
      };
      h.lookups.onSubmit = (_) async => _done(
        json: _found(
          matches: [
            (_found()['matches'] as List).first as Map<String, dynamic>,
            fries,
          ],
        ),
        // Suggestions, so the second meal is not held by the 6 h rule.
        verbatim: false,
      );
      final first = h.add(meal([('Big Mac (220 g)', 540), ('Fries', 340)]));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.blockOf(first)?['status'], AssistStatus.suggested);

      final second = h.add(
        meal([('Fries (117 g)', 340), ('Big Mac', 540)]),
        timestamp: '2026-10-24T12:45:00.000',
      );
      await h.assist.sweep();
      expect(
        h.lookups.submits,
        hasLength(1),
        reason: 'answered from the cache',
      );
      final block = h.blockOf(second)!;
      expect(block['status'], AssistStatus.suggested);
      final byItem = {
        for (final m in block['matches'] as List)
          (m as Map)['item_index']: m['menu_item'],
      };
      expect(byItem, {1: 'Big Mac', 0: 'Medium French Fries'});
    });

    test('kept: the answer and the source\'s text only; 30 days', () async {
      h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      final doc = h.document(assistCacheDocument);
      final entry = (doc['entries'] as List).single as Map;
      expect(entry['chain_key'], 'mcdonalds');
      expect(entry['names'], ['big mac']);
      expect(entry['evidence'], [
        {'url': _url, 'text': _evidenceText, 'verbatim': true},
      ]);
      expect(jsonEncode(entry), isNot(contains('Something else entirely')));

      h.now = _now.add(const Duration(days: 31));
      expect(
        await h.state.cachedLookup(entry['key'] as String),
        isNull,
        reason: 'past 30 days',
      );
    });

    test('a cache hit needs no lookup call even where the location named '
        'the chain', () async {
      h.add(_bigMac());
      await h.assist.sweep();
      h.add(_bigMac(), timestamp: '2026-10-24T12:45:00.000', fileId: 'a2');
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.places.radii, hasLength(2));
    });
  });

  group("the editor's answers (R7b)", () {
    Future<String> raw(int id) async =>
        (await h.dao.mealSnapshot(id))!.rawAnalysis;

    /// Meal [id] changed in place by another writer, corrected kept.
    void rewrite(
      int id,
      Map<String, dynamic> Function(Map<String, dynamic>) change,
    ) {
      final i = h.dao.meals.indexWhere((m) => m.id == id);
      final m = h.dao.meals[i];
      h.dao.meals[i] = Meal(
        id: m.id,
        date: m.date,
        time: m.time,
        timestamp: m.timestamp,
        source: m.source,
        imageHash: m.imageHash,
        fileId: m.fileId,
        analysis: change(Map<String, dynamic>.from(m.analysis)),
        corrected: m.corrected,
      );
    }

    /// A first-visit location suggestion at the lone McDonald's.
    Future<int> suggested() async {
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
      return id;
    }

    test('Use published numbers: applied as the user\'s change, the chain '
        'confirmed at the spot; Use AI estimate restores exactly', () async {
      final id = await suggested();
      final before = Map<String, dynamic>.from(h.analysisOf(id));
      final accepted = await h.assist.act(
        id,
        AssistUserAction.acceptSuggestion,
        expectedRaw: await raw(id),
      );
      expect(accepted.status, AssistActionStatus.done);
      expect(accepted.placeLearned, isTrue);
      expect(h.analysisOf(id)['total_calories'], 590);
      expect(h.blockOf(id)?['status'], AssistStatus.applied);
      expect(h.blockOf(id)?['reason'], AssistReason.userAccepted);
      expect(h.dao.byId(id).corrected, isTrue);
      final learned = await h.placesStore.read();
      expect(learned.confirmed.single.chainKey, 'mcdonalds');
      expect(learned.confirmed.single.cell.wire, h.cell.wire);

      final reverted = await h.assist.act(
        id,
        AssistUserAction.useEstimate,
        expectedRaw: await raw(id),
      );
      expect(reverted.status, AssistActionStatus.done);
      final after = h.analysisOf(id);
      expect(after['food_items'], before['food_items']);
      expect(after['total_calories'], 540);
      expect(after['assist']['status'], AssistStatus.reverted);

      final codes = [for (final e in await h.assist.decisions()) e.code];
      expect(codes, containsAllInOrder(['user_accepted', 'user_reverted']));
      final log = await h.assist.decisions();
      expect(log.last.oldKcal, 590);
      expect(log.last.newKcal, 540);
      final stored = h.everythingStored();
      for (final digits in _coordinateDigits) {
        expect(stored, isNot(contains(digits)));
      }
    });

    test('Wrong restaurant: the suggestion declined, the chain blocked at '
        'the spot; the picked chain is looked up with no location read, '
        'and can only be suggested', () async {
      final id = await suggested();
      final wrong = await h.assist.act(
        id,
        AssistUserAction.wrongRestaurant,
        expectedRaw: await raw(id),
      );
      expect(wrong.status, AssistActionStatus.done);
      expect(wrong.placeLearned, isTrue);
      expect(h.blockOf(id)?['status'], AssistStatus.declined);
      expect(h.blockOf(id)?['reason'], AssistReason.userWrongRestaurant);
      expect(h.blockOf(id)?.containsKey('matches'), isFalse);
      expect(h.dao.byId(id).corrected, isTrue);
      final learned = await h.placesStore.read();
      expect(learned.blocked.single.chainKey, 'mcdonalds');

      final asked = h.source.asked.length;
      final radii = h.places.radii.length;
      h.lookups.onSubmit = (request) async => _done(
        json: _found(chainKey: 'burger_king')
          ..['source_url'] = 'https://www.bk.com/menu/item-big-burger',
      );
      final run = await h.assist.lookupNow(id, chainKey: 'burger_king');
      expect(h.lookups.submits.last.chainKeys, ['burger_king']);
      expect(h.source.asked, hasLength(asked), reason: 'no location read');
      expect(h.places.radii, hasLength(radii));
      expect(run.wrote, isTrue);
      final block = h.blockOf(id)!;
      expect(block['status'], AssistStatus.suggested);
      expect(block['evidence'], 'user_picked');
      expect(block['chain_key'], 'burger_king');
      // The meal was corrected by the decline: the result went through the
      // user's own compare-and-set, not applyAssist.
      expect(h.dao.updates.last.$2['assist']['chain_key'], 'burger_king');
    });

    test('an answer for another chain than the pick writes nothing — not '
        'even for the chain a printed brand names', () async {
      final id = h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.blockOf(id)?['status'], AssistStatus.applied);
      await h.assist.act(
        id,
        AssistUserAction.wrongRestaurant,
        expectedRaw: await raw(id),
      );
      expect(h.analysisOf(id)['total_calories'], 540);
      final before = await raw(id);
      h.lookups.onSubmit = (request) async => _done();
      final run = await h.assist.lookupNow(id, chainKey: 'burger_king');
      expect(
        h.lookups.submits.last.chainKeys,
        ['mcdonalds', 'burger_king'],
        reason: 'the composer lists a printed brand\'s chain first',
      );
      expect(run.wrote, isFalse);
      expect(run.code, AssistReason.chainNotPicked);
      expect(await raw(id), before);

      // A chain the request never named is no answer either.
      h.lookups.onSubmit = (request) async =>
          _done(json: _found(chainKey: 'wendys'));
      final other = await h.assist.lookupNow(id, chainKey: 'burger_king');
      expect(other.wrote, isFalse);
      expect(await raw(id), before);
    });

    test('the editor\'s lookup never answers from the cache — a picked '
        'chain or not', () async {
      // McDonald's is cached for these items by the first lookup.
      final id = await suggested();
      final calls = h.lookups.submits.length;
      await h.assist.lookupNow(id, useLocation: true);
      expect(h.lookups.submits, hasLength(calls + 1));
      await h.assist.act(
        id,
        AssistUserAction.wrongRestaurant,
        expectedRaw: await raw(id),
      );
      h.lookups.onSubmit = (request) async =>
          _done(json: _found(chainKey: 'burger_king'));
      await h.assist.lookupNow(id, chainKey: 'burger_king');
      expect(h.lookups.submits, hasLength(calls + 2));
    });

    test('over http to the owner\'s server a picked chain is not sent: its '
        'https gate would strip it', () async {
      h.lookups.support = _claudePlanHttp;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: _claudePlanHttp.recipientStamp,
      );
      final id = h.add(_bigMac(brand: "McDonald's", context: 'takeout'));
      final run = await h.assist.lookupNow(id, chainKey: 'burger_king');
      expect(run.code, AssistSkip.pickNeedsHttps);
      expect(run.wrote, isFalse);
      expect(h.lookups.submits, isEmpty);
      expect(h.blockOf(id), isNull);
    });

    // Review 2026-10-25 (PROBE5): Correct on an item_brand application
    // confirmed the chain at the spot, so later unbranded meals there were
    // applied by themselves.
    test('Correct or Use published numbers on a printed brand\'s numbers '
        'teaches nothing about the spot, and reads no location', () async {
      final id = h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.blockOf(id)?['status'], AssistStatus.applied);
      expect(h.blockOf(id)?['evidence'], 'item_brand');
      final asked = h.source.asked.length;
      final r = await h.assist.act(
        id,
        AssistUserAction.correct,
        expectedRaw: await raw(id),
      );
      expect(r.status, AssistActionStatus.done);
      expect(r.placeLearned, isFalse);
      expect(h.source.asked, hasLength(asked), reason: 'no position read');
      expect((await h.placesStore.read()).confirmed, isEmpty);

      // A printed brand's suggestion accepted: the same.
      h.lookups.onSubmit = (_) async => _done(verbatim: false);
      final other = h.add(
        _bigMac(brand: "McDonald's", name: 'Quarter Pounder'),
        timestamp: '2026-10-24T12:40:00.000',
        fileId: 'a2',
      );
      await h.assist.sweep();
      expect(h.blockOf(other)?['status'], AssistStatus.suggested);
      final asked2 = h.source.asked.length;
      final accepted = await h.assist.act(
        other,
        AssistUserAction.acceptSuggestion,
        expectedRaw: await raw(other),
      );
      expect(accepted.status, AssistActionStatus.done);
      expect(accepted.placeLearned, isFalse);
      expect(h.source.asked, hasLength(asked2));
      expect((await h.placesStore.read()).confirmed, isEmpty);

      // The next unbranded meal there stays a suggestion.
      h.lookups.onSubmit = null;
      final next = h.add(
        _bigMac(name: 'Filet-O-Fish'),
        timestamp: '2026-10-24T12:50:00.000',
        fileId: 'a3',
      );
      await h.assist.sweep();
      expect(h.blockOf(next)?['evidence'], 'location');
      expect(h.blockOf(next)?['status'], AssistStatus.suggested);
    });

    // Review 2026-10-25 (P4): after a switch to Brand only, answering an
    // older location-based result still read the photo's position.
    test('Brand only: no answer to a location-based result reads the '
        'position or teaches the spot', () async {
      final ids = <int>[];
      for (var i = 0; i < 4; i++) {
        ids.add(
          h.add(
            _bigMac(),
            timestamp: '2026-10-24T12:${30 + i}:00.000',
            fileId: 'asset-$i',
          ),
        );
      }
      await h.assist.sweep();
      for (final id in ids) {
        expect(h.blockOf(id)?['status'], AssistStatus.suggested);
        expect(h.blockOf(id)?['evidence'], 'location');
      }
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      final asked = h.source.asked.length;
      final actions = [
        AssistUserAction.correct,
        AssistUserAction.acceptSuggestion,
        AssistUserAction.wrongRestaurant,
        AssistUserAction.notFromRestaurant,
      ];
      for (var i = 0; i < actions.length; i++) {
        expect(h.assist.canLearnPlace(h.dao.byId(ids[i])), isFalse);
        final r = await h.assist.act(
          ids[i],
          actions[i],
          expectedRaw: await raw(ids[i]),
        );
        expect(r.status, AssistActionStatus.done, reason: '${actions[i]}');
        expect(r.placeLearned, isFalse, reason: '${actions[i]}');
      }
      expect(h.source.asked, hasLength(asked), reason: 'no position read');
      final learned = await h.placesStore.read();
      expect(learned.confirmed, isEmpty);
      expect(learned.blocked, isEmpty);
      expect(learned.zones, isEmpty);
    });

    test('no consent for the recipient a lookup would reach now: nothing '
        'is learned', () async {
      final id = await suggested();
      expect(h.assist.canLearnPlace(h.dao.byId(id)), isTrue);
      // Another provider: the assist waits for a consent that names it.
      h.lookups.support = _claudePlanHttps;
      expect(h.assist.canLearnPlace(h.dao.byId(id)), isFalse);
      final asked = h.source.asked.length;
      final r = await h.assist.act(
        id,
        AssistUserAction.notFromRestaurant,
        expectedRaw: await raw(id),
      );
      expect(r.placeLearned, isFalse);
      expect(h.source.asked, hasLength(asked));
      expect((await h.placesStore.read()).zones, isEmpty);
    });

    test('Not from a restaurant: a zone at the spot; the next restaurant '
        'photo there asks Apple Maps nothing', () async {
      final id = await suggested();
      final r = await h.assist.act(
        id,
        AssistUserAction.notFromRestaurant,
        expectedRaw: await raw(id),
      );
      expect(r.status, AssistActionStatus.done);
      expect(r.placeLearned, isTrue);
      expect(h.blockOf(id)?['reason'], AssistReason.userNotRestaurant);
      expect((await h.placesStore.read()).inZone(h.cell), isTrue);
      final radii = h.places.radii.length;
      h.add(_bigMac(), timestamp: '2026-10-24T12:50:00.000', fileId: 'a2');
      await h.assist.sweep();
      expect(h.places.radii, hasLength(radii));
    });

    test('Correct confirms the chain at the spot and writes no meal', () async {
      final id = await suggested();
      final before = await raw(id);
      final r = await h.assist.act(
        id,
        AssistUserAction.correct,
        expectedRaw: before,
      );
      expect(r.status, AssistActionStatus.done);
      expect(r.placeLearned, isTrue);
      expect(await raw(id), before);
      expect(h.dao.byId(id).corrected, isFalse);
      expect(
        (await h.placesStore.read()).confirmed.single.chainKey,
        'mcdonalds',
      );
    });

    test('brand only: no location is read and nothing is learned', () async {
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: false,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      final id = h.add(_bigMac(brand: "McDonald's"));
      await h.assist.sweep();
      expect(h.blockOf(id)?['status'], AssistStatus.applied);
      expect(h.assist.canLearnPlace(h.dao.byId(id)), isFalse);
      final r = await h.assist.act(
        id,
        AssistUserAction.notFromRestaurant,
        expectedRaw: await raw(id),
      );
      expect(r.status, AssistActionStatus.done);
      expect(r.placeLearned, isFalse);
      expect(h.analysisOf(id)['total_calories'], 540);
      expect(h.source.asked, isEmpty);
      expect((await h.placesStore.read()).zones, isEmpty);
    });

    test('Off, an http server or a coarse fix: nothing is learned', () async {
      final id = await suggested();
      final meal = h.dao.byId(id);
      expect(h.assist.canLearnPlace(meal), isTrue);
      h.lookups.support = _claudePlanHttp;
      expect(h.assist.canLearnPlace(meal), isFalse);
      h.lookups.support = _anthropic;
      h.settings = AssistSettingsView(
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      expect(h.assist.canLearnPlace(meal), isFalse);
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      final coarse = h.add(
        _bigMac(capture: _capture(accuracy: 900)),
        fileId: 'a3',
      );
      expect(h.assist.canLearnPlace(h.dao.byId(coarse)), isFalse);
    });

    test('a stale editor copy changes nothing; stale stamps leave nothing '
        'to revert', () async {
      final id = await suggested();
      final old = await raw(id);
      rewrite(id, (a) => a..['meal_description'] = 'edited elsewhere');
      final r = await h.assist.act(
        id,
        AssistUserAction.acceptSuggestion,
        expectedRaw: old,
      );
      expect(r.status, AssistActionStatus.changed);
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
      expect((await h.placesStore.read()).confirmed, isEmpty);

      // The user changed the item after the suggestion: nothing to accept.
      rewrite(
        id,
        (a) => a
          ..['food_items'] = [
            {
              ...(a['food_items'] as List).first as Map,
              'estimated_calories': 700,
            },
          ],
      );
      final stale = await h.assist.act(
        id,
        AssistUserAction.acceptSuggestion,
        expectedRaw: await raw(id),
      );
      expect(stale.status, AssistActionStatus.nothing);
      expect(h.analysisOf(id)['food_items'][0]['estimated_calories'], 700);
    });

    test('a picked-chain job on the owner\'s server: polled by the editor '
        'past the daily cap, and by the sweep once the editor is closed, '
        'on the corrected meal', () async {
      h.lookups.support = _claudePlanHttps;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: true,
        consentAt: _consentAt,
        consentRecipient: _claudePlanHttps.recipientStamp,
      );
      final id = h.add(_bigMac(brand: "McDonald's", context: 'takeout'));
      h.lookups.onSubmit = (request) async => _pending('job_pick_0001');
      await h.assist.sweep();
      // Suggest-only on Claude Plan: make the first answer a suggestion.
      h.lookups.onPoll = (jobId) async => _done(
        provider: LookupRecipient.claudePlan,
        verbatim: false,
        jobId: jobId,
      );
      await h.assist.lookupNow(id);
      expect(h.blockOf(id)?['status'], AssistStatus.suggested);
      await h.assist.act(
        id,
        AssistUserAction.wrongRestaurant,
        expectedRaw: await raw(id),
      );
      expect(h.dao.byId(id).corrected, isTrue);

      h.lookups.onSubmit = (request) async => _pending('job_pick_0002');
      final first = await h.assist.lookupNow(id, chainKey: 'burger_king');
      expect(first.code, AssistSkip.pending);
      final job = (await h.state.jobs())[id]!;
      expect(job.manual, isTrue);
      expect(job.pick, 'burger_king');

      // The day's cap is reached meanwhile: a poll is no new lookup.
      for (var i = 0; i < assistDailyCap; i++) {
        h.budget.tryStartLookup(0);
      }
      expect(h.budget.capReached, isTrue);
      h.lookups.onPoll = (jobId) async => _pending(jobId);
      final again = await h.assist.lookupNow(id, chainKey: 'burger_king');
      expect(again.code, AssistSkip.pending);
      expect(h.lookups.polls.last, 'job_pick_0002');

      // The editor is closed; once the sweep may run again (the cap holds
      // it back, as any lookup), it answers the job with the same pick.
      await h.prefs.remove(assistDailyPrefsKey);
      h.lookups.onPoll = (jobId) async => _done(
        json: _found(chainKey: 'burger_king'),
        provider: LookupRecipient.claudePlan,
        verbatim: false,
        jobId: jobId,
      );
      h.now = h.now.add(const Duration(seconds: 30));
      await h.assist.sweep();
      expect(h.lookups.polls.last, 'job_pick_0002');
      expect(h.blockOf(id)?['chain_key'], 'burger_king');
      expect(h.blockOf(id)?['evidence'], 'user_picked');
      expect((await h.state.jobs())[id], isNull);
    });
  });
}
