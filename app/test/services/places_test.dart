// Food places near a photo (lib/services/places/places.dart, design R4):
// every native status decodes, anything off-contract is an error as a
// whole, the channel gets the contract's arguments, and this side's own
// limits (a 30-a-minute bucket, 60 s of back-off after MapKit throttles)
// turn calls away without reaching MapKit.
import 'dart:async';

import 'package:calorie_tracker/services/photo/photo_location.dart';
import 'package:calorie_tracker/services/places/places.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A public landmark (Times Square), the probe's own test point.
final PhotoPoint _point = PhotoPoint.tryCreate(40.7580, -73.9855)!;

Map<String, Object?> _place(String name, int distance,
        {String category = 'restaurant', String? host}) =>
    {
      'name': name,
      'category': category,
      'distance_m': distance,
      'url_host': ?host,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeNearbyFood', () {
    test('ok: the places nearest first, with their categories and hosts', () {
      final r = decodeNearbyFood({
        'status': 'ok',
        'places': [
          _place('McDonald\'s', 12, host: 'www.mcdonalds.com'),
          _place('Starbucks Coffee Company', 30, category: 'cafe'),
          _place('Levain Bakery', 30, category: 'bakery'),
          _place('Some Lounge', 55, category: 'other'),
          _place('A Future Category', 80, category: 'teahouse'),
        ],
      });
      expect(r.status, PlacesStatus.ok);
      expect(r.errorCode, isNull);
      expect(r.places.map((p) => p.name), [
        'McDonald\'s',
        'Starbucks Coffee Company',
        'Levain Bakery',
        'Some Lounge',
        'A Future Category',
      ]);
      expect(r.places.map((p) => p.distanceM), [12, 30, 30, 55, 80]);
      expect(r.places.map((p) => p.category), [
        PlaceCategory.restaurant,
        PlaceCategory.cafe,
        PlaceCategory.bakery,
        PlaceCategory.other,
        PlaceCategory.other, // unknown names are other, never a failure
      ]);
      expect(r.places.first.urlHost, 'www.mcdonalds.com');
      expect(r.places[1].urlHost, isNull);
      expect(() => r.places.add(r.places.first), throwsUnsupportedError,
          reason: 'the answer is read-only');
    });

    test('none, throttled and unsupported carry no places; error its code',
        () {
      for (final (status, expected) in [
        ('none', PlacesStatus.none),
        ('throttled', PlacesStatus.throttled),
        ('unsupported', PlacesStatus.unsupported),
      ]) {
        final r = decodeNearbyFood({'status': status, 'places': []});
        expect(r.status, expected);
        expect(r.places, isEmpty);
        expect(r.errorCode, isNull);
        // places may also be left out.
        expect(decodeNearbyFood({'status': status}).status, expected);
      }
      final timeout = decodeNearbyFood(
          {'status': 'error', 'places': [], 'error_code': 'timeout'});
      expect(timeout.status, PlacesStatus.error);
      expect(timeout.errorCode, 'timeout');
      expect(
          decodeNearbyFood({'status': 'error', 'error_code': 'x' * 200})
              .errorCode,
          hasLength(80));
      expect(decodeNearbyFood({'status': 'error', 'error_code': 7}).errorCode,
          '7');
      expect(decodeNearbyFood({'status': 'error'}).errorCode, isNull);
    });

    test('an empty ok says what none says', () {
      final r = decodeNearbyFood({'status': 'ok', 'places': []});
      expect(r.status, PlacesStatus.none);
      expect(r.places, isEmpty);
    });

    test('anything off-contract is an error as a whole, never a partial '
        'list', () {
      final good = _place('A', 10);
      for (final reply in <Object?>[
        null,
        'ok',
        42,
        ['ok'],
        <String, Object?>{},
        {'status': 'nope'},
        {'status': 4},
        {'status': 'ok', 'places': 'A'},
        {'status': 'ok', 'places': {'A': 1}},
        // Places with any other status.
        {
          'status': 'none',
          'places': [good]
        },
        {
          'status': 'throttled',
          'places': [good]
        },
        {'status': 'error', 'error_code': 1.5},
        {'status': 'error', 'error_code': ['x']},
        // One bad place spoils the list.
        for (final bad in <Object?>[
          null,
          'A',
          {'category': 'cafe', 'distance_m': 1},
          {'name': '', 'category': 'cafe', 'distance_m': 1},
          {'name': '   ', 'category': 'cafe', 'distance_m': 1},
          {'name': 'x' * 1001, 'category': 'cafe', 'distance_m': 1},
          {'name': 'A', 'distance_m': 1},
          {'name': 'A', 'category': 3, 'distance_m': 1},
          {'name': 'A', 'category': 'cafe'},
          {'name': 'A', 'category': 'cafe', 'distance_m': -1},
          {'name': 'A', 'category': 'cafe', 'distance_m': 1.5},
          {'name': 'A', 'category': 'cafe', 'distance_m': '1'},
          for (final host in <Object?>[
            7,
            '',
            'starbucks',
            'WWW.STARBUCKS.COM',
            'www..starbucks.com',
            '.starbucks.com',
            'starbucks.com.',
            'xn--bcher-kva.example/menu',
            'bücher.example',
            'javascript:alert(1)',
            '${'a' * 250}.com',
          ])
            {'name': 'A', 'category': 'cafe', 'distance_m': 1, 'url_host': host},
        ])
          {
            'status': 'ok',
            'places': [good, bad]
          },
        // Not nearest first.
        {
          'status': 'ok',
          'places': [_place('B', 20), _place('A', 10)]
        },
        // More than the native side ever sends.
        {
          'status': 'ok',
          'places': [for (var i = 0; i <= placesMaxPlaces; i++) _place('P$i', i)]
        },
      ]) {
        final r = decodeNearbyFood(reply);
        expect(r.status, PlacesStatus.error, reason: '$reply');
        expect(r.errorCode, placesMalformed, reason: '$reply');
        expect(r.places, isEmpty, reason: '$reply');
      }
      // The largest list the native side sends is fine.
      expect(
          decodeNearbyFood({
            'status': 'ok',
            'places': [
              for (var i = 0; i < placesMaxPlaces; i++) _place('P$i', i)
            ]
          }).places,
          hasLength(placesMaxPlaces));
      // So is an IDN in its ASCII form.
      expect(
          decodeNearbyFood({
            'status': 'ok',
            'places': [_place('A', 1, host: 'xn--bcher-kva.example')]
          }).places.single.urlHost,
          'xn--bcher-kva.example');
    });
  });

  test('toString never carries a place name or a position', () {
    const place = NearbyPlace(
        name: 'Joe\'s Pizza', category: PlaceCategory.restaurant, distanceM: 9);
    expect('$place', isNot(contains('Joe')));
    expect('$place', isNot(contains('9')));
    final food = NearbyFood(PlacesStatus.ok, places: [place]);
    expect('$food', isNot(contains('Joe')));
    expect('$_point', isNot(contains('40')));
    expect('$_point', isNot(contains('73')));
  });

  test('the categories match the Swift table, and food markets are only on '
      'request', () {
    expect(PlaceCategory.values.map((c) => c.wire), [
      'restaurant',
      'cafe',
      'bakery',
      'brewery',
      'winery',
      'nightlife',
      'distillery',
      'food_market',
      'other',
    ]);
    expect(defaultFoodCategories, isNot(contains(PlaceCategory.foodMarket)));
    expect(defaultFoodCategories, isNot(contains(PlaceCategory.other)));
    expect(defaultFoodCategories, hasLength(7));
    expect(PlaceCategory.fromWire('food_market'), PlaceCategory.foodMarket);
    expect(PlaceCategory.fromWire('MKPOICategoryRestaurant'),
        PlaceCategory.other);
  });

  group('platformPlaceResolver', () {
    test('Apple Maps on iOS; nothing elsewhere', () async {
      expect(platformPlaceResolver(isIOS: true), isA<MapKitPlaces>());
      final android = platformPlaceResolver(isIOS: false);
      expect(android, isA<NullPlaces>());
      final r = await android.nearbyFood(_point);
      expect(r.status, PlacesStatus.unsupported);
      expect(r.places, isEmpty);
    });
  });

  group('MapKitPlaces', () {
    const channel = MethodChannel(placesChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var now = DateTime.utc(2026, 10, 24, 12);
    DateTime clock() => now;

    void answer(Future<Object?> Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return handler(call);
      });
    }

    void answerStatus(String status) =>
        answer((_) async => {'status': status, 'places': []});

    setUp(() {
      calls.clear();
      now = DateTime.utc(2026, 10, 24, 12);
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the channel name is the Swift plugin\'s', () {
      expect(placesChannelName, 'dev.calorietracker/places');
    });

    test('sends the point, the radius clamped and the categories in table '
        'order', () async {
      answer((_) async => {
            'status': 'ok',
            'places': [_place('A', 3)]
          });
      final places = MapKitPlaces(clock: clock);

      final r = await places.nearbyFood(_point);
      expect(r.places.single.name, 'A');
      expect(calls.single.method, 'nearbyFood');
      expect(calls.single.arguments, {
        'lat': 40.7580,
        'lon': -73.9855,
        'radius_m': 100,
        'categories': [
          'restaurant',
          'cafe',
          'bakery',
          'brewery',
          'winery',
          'nightlife',
          'distillery',
        ],
      });

      await places.nearbyFood(_point,
          radiusM: 5,
          categories: {PlaceCategory.foodMarket, PlaceCategory.restaurant});
      expect(calls.last.arguments, containsPair('radius_m', placesMinRadiusM));
      expect(calls.last.arguments,
          containsPair('categories', ['restaurant', 'food_market']));

      await places.nearbyFood(_point, radiusM: 5000);
      expect(calls.last.arguments, containsPair('radius_m', placesMaxRadiusM));

      // Nothing searchable asked for → the defaults, as on the Swift side.
      for (final none in [<PlaceCategory>{}, {PlaceCategory.other}]) {
        await places.nearbyFood(_point, categories: none);
        expect((calls.last.arguments as Map)['categories'], hasLength(7));
      }
    });

    test('none and unsupported come back as they are', () async {
      final places = MapKitPlaces(clock: clock);
      answerStatus('none');
      expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
      answerStatus('unsupported');
      expect(
          (await places.nearbyFood(_point)).status, PlacesStatus.unsupported);
      // Neither starts a back-off.
      answerStatus('none');
      expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
      expect(calls, hasLength(3));
    });

    test('MapKit throttling backs every call off for 60 s without asking '
        'again', () async {
      final places = MapKitPlaces(clock: clock);
      answerStatus('throttled');
      final first = await places.nearbyFood(_point);
      expect(first.status, PlacesStatus.throttled);
      expect(first.errorCode, isNull, reason: 'MapKit\'s own verdict');
      expect(calls, hasLength(1));

      answerStatus('none');
      for (final later in [1, 30, 59]) {
        now = DateTime.utc(2026, 10, 24, 12, 0, later);
        final r = await places.nearbyFood(_point);
        expect(r.status, PlacesStatus.throttled, reason: '+${later}s');
        expect(r.errorCode, placesBackoff);
      }
      expect(calls, hasLength(1), reason: 'MapKit was not asked during it');

      now = DateTime.utc(2026, 10, 24, 12, 1);
      expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
      expect(calls, hasLength(2));
    });

    test('a clock that went backwards ends the back-off instead of '
        'stretching it', () async {
      final places = MapKitPlaces(clock: clock);
      answerStatus('throttled');
      await places.nearbyFood(_point);
      answerStatus('none');
      now = DateTime.utc(2026, 10, 24, 11); // an hour back
      expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
    });

    test('the bucket: 30 calls at once, then one more every 2 s', () async {
      answerStatus('none');
      final places = MapKitPlaces(clock: clock);
      for (var i = 0; i < placesBucketSize; i++) {
        expect((await places.nearbyFood(_point)).status, PlacesStatus.none,
            reason: 'call ${i + 1}');
      }
      final over = await places.nearbyFood(_point);
      expect(over.status, PlacesStatus.throttled);
      expect(over.errorCode, placesRateLimited);
      expect(calls, hasLength(placesBucketSize),
          reason: 'a call over the limit never reaches MapKit');

      now = now.add(const Duration(seconds: 1));
      expect((await places.nearbyFood(_point)).errorCode, placesRateLimited,
          reason: 'half a token');
      now = now.add(const Duration(seconds: 1));
      expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
      expect((await places.nearbyFood(_point)).errorCode, placesRateLimited);

      // A full minute refills the whole bucket, and no more than that.
      now = now.add(const Duration(minutes: 5));
      for (var i = 0; i < placesBucketSize; i++) {
        expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
      }
      expect((await places.nearbyFood(_point)).errorCode, placesRateLimited);

      // A clock that went backwards refills nothing.
      now = now.subtract(const Duration(hours: 1));
      expect((await places.nearbyFood(_point)).errorCode, placesRateLimited);
      now = now.add(const Duration(seconds: 2));
      expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
    });

    test('a platform error, a missing plugin, a timeout and a bad reply are '
        'errors, never exceptions', () async {
      final places = MapKitPlaces(
          clock: clock, timeout: const Duration(milliseconds: 50));
      answer((_) async =>
          throw PlatformException(code: 'boom', message: 'native failure'));
      final boom = await places.nearbyFood(_point);
      expect(boom.status, PlacesStatus.error);
      expect(boom.errorCode, 'platform:boom');

      messenger.setMockMethodCallHandler(channel, null);
      expect((await places.nearbyFood(_point)).errorCode, placesMissingPlugin);

      answer((_) => Completer<Object?>().future); // never answers
      final slow = await places.nearbyFood(_point);
      expect(slow.status, PlacesStatus.error);
      expect(slow.errorCode, placesTimeout);

      answer((_) async => {'status': 'ok', 'places': 'A'});
      expect((await places.nearbyFood(_point)).errorCode, placesMalformed);

      // None of these starts a back-off.
      answerStatus('none');
      expect((await places.nearbyFood(_point)).status, PlacesStatus.none);
    });
  });
}
