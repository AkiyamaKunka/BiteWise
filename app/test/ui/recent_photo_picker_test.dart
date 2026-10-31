// The production picker behind + Log › From photos and the leftover photo
// step (di.dart): the grid listing must not wait for 30 file-name look-ups
// that only the ONE picked photo needs (run 7, P6).
import 'dart:typed_data';

import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/ui/di.dart' show recentPhotoPickerFor;
import 'package:calorie_tracker/ui/services.dart' show RecentAsset;
import 'package:flutter_test/flutter_test.dart';

class _Asset implements LibraryAsset {
  _Asset(this.id, this.createDateTime, this._name, {this.fails = false});
  @override
  final String id;
  @override
  final DateTime createDateTime;
  final String _name;
  final bool fails;
  int nameCalls = 0;

  @override
  Future<String> fileName() async {
    nameCalls++;
    if (fails) throw StateError('PhotoKit');
    return _name;
  }

  @override
  Future<Uint8List?> originBytes() async => Uint8List.fromList([1, 2, 3]);
}

class _Library implements PhotoLibrary {
  _Library(this.assets);
  final List<_Asset> assets;
  final originReads = <String>[];

  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<List<LibraryAsset>> recentImages(int limit) async => assets;
  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) async {
    originReads.add(assetId);
    return Uint8List.fromList(List.filled(32, 9));
  }

  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId, {int size = 160}) =>
      throw UnimplementedError();
  @override
  Future<bool> hasFullAccess() async => true;
  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
          {int limit = 500}) =>
      throw UnimplementedError();
  @override
  Future<void> startChangeNotify(void Function() onChange) =>
      throw UnimplementedError();
  @override
  Future<void> stopChangeNotify() => throw UnimplementedError();
}

String _two(int v) => v.toString().padLeft(2, '0');

/// IMG_YYYYMMDD_HHMMSS.jpg for [t] (the camera-name dating rule).
String _cameraName(DateTime t) => 'IMG_${t.year}${_two(t.month)}'
    '${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}.jpg';

void main() {
  // Relative to now: the dating rule rejects stale or future times.
  final now = DateTime.now();
  final shot = DateTime(now.year, now.month, now.day, now.hour, now.minute,
          now.second)
      .subtract(const Duration(hours: 1));
  final created = shot.subtract(const Duration(hours: 2));

  List<_Asset> thirty({bool fails = false}) => [
        for (var i = 0; i < 30; i++)
          _Asset('id$i', created, i == 7 ? _cameraName(shot) : 'IMG_$i.HEIC',
              fails: fails),
      ];

  test('the listing asks for no file names', () async {
    final assets = thirty();
    final picker = recentPhotoPickerFor(_Library(assets));
    final listed = await picker.recentAssets();
    expect(listed, hasLength(30));
    expect(listed.map((a) => a.id), [for (var i = 0; i < 30; i++) 'id$i']);
    expect(listed.every((a) => a.createdAt == created), isTrue);
    expect(assets.fold<int>(0, (n, a) => n + a.nameCalls), 0);
  });

  test('the picked photo gets its name, once, and is dated by it',
      () async {
    final assets = thirty();
    final library = _Library(assets);
    final picker = recentPhotoPickerFor(library);
    final listed = await picker.recentAssets();

    final photo = await picker.loadOriginal(listed[7]);

    expect(photo, isNotNull);
    expect(photo!.fileName, _cameraName(shot));
    expect(photo.assetId, 'id7');
    expect(photo.capturedAt, shot,
        reason: 'the camera name, not the create date, dates the meal');
    expect(photo.deliberate, isTrue);
    expect(assets[7].nameCalls, 1);
    expect(assets.fold<int>(0, (n, a) => n + a.nameCalls), 1);
    expect(library.originReads, ['id7']);
  });

  test('a failing name look-up still loads the photo, dated by its create '
      'date', () async {
    final assets = thirty(fails: true);
    final picker = recentPhotoPickerFor(_Library(assets));
    final listed = await picker.recentAssets();

    final photo = await picker.loadOriginal(listed[7]);

    expect(photo, isNotNull);
    expect(photo!.fileName, '');
    expect(photo.capturedAt, created);
  });

  test('a caller that already has the name is not asked again', () async {
    final assets = thirty();
    final picker = recentPhotoPickerFor(_Library(assets));
    final listed = await picker.recentAssets();
    final named = await picker.loadOriginal(
        RecentAsset(listed[3].id, _cameraName(shot), listed[3].createdAt));
    expect(named!.fileName, _cameraName(shot));
    expect(assets[3].nameCalls, 0);
  });
}
