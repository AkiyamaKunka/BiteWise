// A meal photo's position for the place query (lib/services/photo/
// photo_location.dart, design R4): read from the library's record of the
// asset and never from its bytes; a missing or junk location is none; a
// share-sheet photo (no asset) and Android ask nothing; nothing throws.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/photo_location.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _LatLng = ({double latitude, double longitude});

/// A library whose every byte-reading path fails the test: the reader may
/// only ask for the location.
class _LocationOnlyLibrary implements PhotoLibrary, AssetLocationSource {
  _LocationOnlyLibrary(this.answer);

  Future<_LatLng?> Function(String id) answer;
  final List<String> asked = [];

  @override
  Future<_LatLng?> assetLatLng(String assetId) {
    asked.add(assetId);
    return answer(assetId);
  }

  Never _bytes(String what) =>
      fail('the location reader read $what — it must never read bytes');

  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) =>
      _bytes('originBytesByAssetId');

  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId, {int size = 160}) =>
      _bytes('thumbnailByAssetId');

  @override
  Future<Map<String, LibraryAsset?>> imagesByIds(List<String> ids) =>
      _bytes('imagesByIds');

  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
          {int limit = 500}) =>
      _bytes('imagesCreatedAfter');

  @override
  Future<List<LibraryAsset>> recentImages(int limit) => _bytes('recentImages');

  @override
  Future<bool> hasFullAccess() async => true;

  @override
  Future<bool> requestPermission() =>
      fail('the location reader must never ask for a permission');

  @override
  Future<void> startChangeNotify(void Function() onChange) async {}

  @override
  Future<void> stopChangeNotify() async {}
}

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

void main() {
  group('PhotoPoint.tryCreate', () {
    test('a position in range is a point', () {
      final p = PhotoPoint.tryCreate(43.0747, -89.3842)!;
      expect(p.lat, 43.0747);
      expect(p.lon, -89.3842);
      expect(PhotoPoint.tryCreate(-90, 180), isNotNull);
      expect(PhotoPoint.tryCreate(90, -180), isNotNull);
      expect(PhotoPoint.tryCreate(0, 12.5), isNotNull, reason: 'the equator');
      expect(PhotoPoint.tryCreate(51.48, 0), isNotNull, reason: 'Greenwich');
    });

    test('missing, non-finite, out of range and (0, 0) are none', () {
      for (final (lat, lon) in <(double?, double?)>[
        (null, 1),
        (1, null),
        (null, null),
        (double.nan, 1),
        (1, double.infinity),
        (-double.infinity, 1),
        (90.0001, 1),
        (-91, 1),
        (1, 180.5),
        (1, -181),
        (0, 0),
        (-0.0, 0),
      ]) {
        expect(PhotoPoint.tryCreate(lat, lon), isNull, reason: '($lat, $lon)');
      }
    });

    test('its text never carries the numbers', () {
      final p = PhotoPoint.tryCreate(43.0747, -89.3842)!;
      expect('$p', isNot(contains('43')));
      expect('$p', isNot(contains('89')));
      expect('$p', contains('redacted'));
    });
  });

  group('PhotoLocationReader.forAsset', () {
    test('the library\'s location becomes a point, read by id only', () async {
      final library = _LocationOnlyLibrary(
          (_) async => (latitude: 40.758, longitude: -73.9855));
      final reader = PhotoLocationReader(library, enabled: true);
      final p = await reader.forAsset('A1/L0/001');
      expect(p, isNotNull);
      expect((p!.lat, p.lon), (40.758, -73.9855));
      expect(library.asked, ['A1/L0/001']);
      // Surrounding whitespace is not part of an identifier.
      await reader.forAsset('  A1/L0/001 ');
      expect(library.asked.last, 'A1/L0/001');
    });

    test('nil (no location, or "No Location" chosen in Photos) is none',
        () async {
      final library = _LocationOnlyLibrary((_) async => null);
      final reader = PhotoLocationReader(library, enabled: true);
      expect(await reader.forAsset('A1'), isNull);
      expect(library.asked, ['A1']);
    });

    test('junk coordinates are none', () async {
      for (final at in <_LatLng>[
        (latitude: 0, longitude: 0),
        (latitude: double.nan, longitude: 2),
        (latitude: 95, longitude: 2),
        (latitude: 2, longitude: -200),
      ]) {
        final reader = PhotoLocationReader(
            _LocationOnlyLibrary((_) async => at),
            enabled: true);
        expect(await reader.forAsset('A1'), isNull, reason: '$at');
      }
    });

    test('a share-sheet photo has no asset: none, without asking', () async {
      final library = _LocationOnlyLibrary(
          (_) async => (latitude: 1.0, longitude: 1.0));
      final reader = PhotoLocationReader(library, enabled: true);
      expect(await reader.forAsset(''), isNull);
      expect(await reader.forAsset('   '), isNull);
      expect(library.asked, isEmpty);
    });

    test('disabled (Android, or not iOS) is none, without asking', () async {
      final library = _LocationOnlyLibrary(
          (_) async => (latitude: 1.0, longitude: 1.0));
      final reader = PhotoLocationReader(library, enabled: false);
      expect(await reader.forAsset('A1'), isNull);
      expect(library.asked, isEmpty);
      // The default follows the platform: the test host is not iOS.
      expect(PhotoLocationReader(library).enabled, Platform.isIOS);
    });

    test('a failing or hanging read is none, never an exception', () async {
      final throwing = PhotoLocationReader(
          _LocationOnlyLibrary((_) async => throw StateError('gone')),
          enabled: true);
      expect(await throwing.forAsset('A1'), isNull);

      final hanging = PhotoLocationReader(
          _LocationOnlyLibrary((_) => Completer<_LatLng?>().future),
          enabled: true,
          timeout: const Duration(milliseconds: 20));
      expect(await hanging.forAsset('A1'), isNull);
    });
  });

  // The production source (PhotoManagerLibrary.assetLatLng): iOS only, and
  // the asset's record only — its body opens no original, file or
  // thumbnail, and Android's location path (EXIF, which needs
  // ACCESS_MEDIA_LOCATION) is never taken.
  test('PhotoManagerLibrary reads the location from the asset record only, '
      'and only on iOS', () {
    final source = File(
            '${_appRoot().path}/lib/services/photo/photo_library.dart')
        .readAsStringSync();
    final body = RegExp(
            r'Future<\(\{double latitude, double longitude\}\)\?> '
            r'assetLatLng\(\s*String assetId\) async \{(.*?)\n  \}',
            dotAll: true)
        .firstMatch(source)
        ?.group(1);
    expect(body, isNotNull, reason: 'PhotoManagerLibrary.assetLatLng missing');
    expect(body, contains('if (!Platform.isIOS || assetId.isEmpty) return '
        'null;'));
    expect(body, contains('AssetEntity.fromId(assetId)'));
    expect(body, contains('latlngAsync()'));
    for (final bytes in [
      'originBytes',
      'originFile',
      '.file',
      'thumbnail',
      'loadFile',
      'getMediaUrl',
    ]) {
      expect(body, isNot(contains(bytes)), reason: bytes);
    }
    expect(source, contains('class PhotoManagerLibrary implements '
        'PhotoLibrary, AssetLocationSource'));
    // And Android is still asked for no media location.
    expect(source, contains('AndroidPermission(type: RequestType.image, '
        'mediaLocation: false)'));
  });
}
