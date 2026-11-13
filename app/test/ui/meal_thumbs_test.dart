// Thumb resolution (spec §9): stored thumb wins, library backfill persists
// exactly once (for an Android id only from the meal's own photo), text
// meals resolve null, negative results are cached.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart'
    show LibraryAsset, maxPhotoBytes;
import 'package:calorie_tracker/ui/meal_thumbs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;
import 'fakes.dart';

/// An Android MediaStore id: a small integer, which repeats on another
/// phone.
const androidId = '1001';

/// An iOS localIdentifier: it names one photo on one device.
const iosId = 'ED7AC36B-A150-4C38-BB8C-B6D696F4F2ED/L0/001';

Meal photoMeal(int id, {String fileId = androidId, String hash = 'h1'}) =>
    Meal(
      id: id,
      date: '2026-07-26',
      time: '12:00 PM',
      timestamp: 'x',
      source: 'app_watch',
      imageHash: hash,
      fileId: fileId,
      analysis: const {'is_food': true},
    );

Meal textMeal(int id) => Meal(
      id: id,
      date: '2026-07-26',
      time: '12:00 PM',
      timestamp: 'x',
      source: 'manual_text',
      analysis: const {'is_food': true},
    );

/// Test hasher: `h<firstByte>`, so bytesOf(1) is photoMeal's own 'h1'.
Future<String> testHash(Uint8List bytes) async => 'h${bytes.first}';

/// The library photo [photoMeal] was logged from.
FakeAsset ownPhoto({String id = androidId, int n = 1}) =>
    FakeAsset(id, 'IMG_$n.jpg', DateTime(2026, 7, 26), bytesOf(n));

/// A library that also holds non-images, as Android's fromId finds any
/// media by id: thumbnailByAssetId and originBytesByAssetId answer for
/// them, and only imagesByIds says they are not images.
class _LibraryWithVideos extends FakePhotoLibrary {
  final Map<String, FakeAsset> videos = {};

  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) async =>
      videos.containsKey(assetId)
          ? videos[assetId]!.originBytes()
          : super.originBytesByAssetId(assetId);

  @override
  Future<Map<String, LibraryAsset?>> imagesByIds(List<String> ids) async => {
        ...await super.imagesByIds(ids),
        for (final id in ids)
          if (videos.containsKey(id)) id: null,
      };
}

void main() {
  late FakeDao dao;
  late FakePhotoLibrary library;
  late MealThumbResolver resolver;

  setUp(() {
    dao = FakeDao();
    library = FakePhotoLibrary();
    resolver = MealThumbResolver(dao: dao, library: library, hasher: testHash);
  });

  test('stored thumb wins without touching the library', () async {
    dao.thumbs[7] = Uint8List.fromList([9, 9]);
    library.thumbnails[androidId] = Uint8List.fromList([1]);
    expect(await resolver.thumbFor(photoMeal(7)), [9, 9]);
  });

  test('library backfill persists the thumb so it happens once', () async {
    library.thumbnails[androidId] = Uint8List.fromList([5, 5, 5]);
    library.assets = [ownPhoto()];
    final first = await resolver.thumbFor(photoMeal(3));
    expect(first, [5, 5, 5]);
    expect(dao.thumbs[3], [5, 5, 5], reason: 'backfill must persist');

    // Second resolve: cache. Library gone → still served.
    library.thumbnails.clear();
    expect(await resolver.thumbFor(photoMeal(3)), [5, 5, 5]);
  });

  test("another photo with the meal's asset id is neither shown nor saved",
      () async {
    // Android asset ids are small integers that repeat on another phone.
    // After an import or a restored backup, an old meal's id can name an
    // unrelated, maybe private, photo on this one, and it was shown as the
    // meal's picture and saved for good (review 171, C39).
    library.thumbnails[androidId] = Uint8List.fromList([7, 7, 7]);
    library.assets = [ownPhoto(n: 9)]; // the same id, another photo
    expect(await resolver.thumbFor(photoMeal(3)), isNull);
    expect(dao.thumbs, isEmpty);
  });

  test('an iOS id is filled in from the library without reading its '
      'original', () async {
    // An iOS localIdentifier names one photo on one device: the meal's own
    // or none. There the check could only cost: photo_manager copies the
    // original into tmp (and fetches it from iCloud when offloaded), and a
    // photo edited in Photos since it was logged hashes differently, so it
    // lost its picture for good.
    final reads = <String>[];
    library.thumbnails[iosId] = Uint8List.fromList([6, 6]);
    library.assets = [
      // Edited in Photos: its original no longer hashes to the meal's h1.
      FakeAsset(iosId, 'IMG_0042.HEIC', DateTime(2026, 7, 26), bytesOf(9),
          onRead: () => reads.add(iosId)),
    ];
    expect(await resolver.thumbFor(photoMeal(3, fileId: iosId)), [6, 6]);
    expect(dao.thumbs[3], [6, 6], reason: 'saved, so it happens once');
    expect(reads, isEmpty);
    expect(library.lookedUp, isEmpty);
  });

  test('the check is the md5 of the original against the stored hash',
      () async {
    // The production hasher (on a worker isolate), and a stored hash in
    // another case still matches (image hashes are normalized).
    final original = bytesOf(4, 64);
    library.thumbnails[androidId] = Uint8List.fromList([5]);
    library.assets = [
      FakeAsset(androidId, 'IMG_4.jpg', DateTime(2026, 7, 26), original),
    ];
    final real = MealThumbResolver(dao: dao, library: library);
    expect(
        await real.thumbFor(
            photoMeal(3, hash: originalBytesMd5(original).toUpperCase())),
        [5]);
    expect(await real.thumbFor(photoMeal(4, hash: 'f' * 32)), isNull);
    expect(dao.thumbs.keys, [3]);
  });

  test('a thumbnail of what the library does not call an image is not '
      'taken, and its original is never read', () async {
    // On Android another phone's id can name a video, which can be far
    // over the cap: it would be read whole before the size test.
    final reads = <String>[];
    final withVideo = _LibraryWithVideos()
      ..thumbnails[androidId] = Uint8List.fromList([7])
      ..videos[androidId] = FakeAsset(
          androidId, 'VID_1.mp4', DateTime(2026, 7, 26), bytesOf(1),
          onRead: () => reads.add(androidId)); // hashes to the meal's h1
    final r =
        MealThumbResolver(dao: dao, library: withVideo, hasher: testHash);
    expect(await r.thumbFor(photoMeal(3)), isNull);
    expect(reads, isEmpty);
    expect(dao.thumbs, isEmpty);
  });

  test('an original over the intake cap is never the meal photo', () async {
    // Intake refuses those (§8), so no meal was logged from one.
    library.thumbnails[androidId] = Uint8List.fromList([7]);
    library.assets = [
      FakeAsset(androidId, 'IMG_0.jpg', DateTime(2026, 7, 26),
          Uint8List(maxPhotoBytes + 1)),
    ];
    expect(await resolver.thumbFor(photoMeal(3, hash: 'h0')), isNull);
    expect(dao.thumbs, isEmpty);
  });

  test('an original that cannot be read gives no picture rather than a '
      'guess', () async {
    library.thumbnails[androidId] = Uint8List.fromList([7]);
    library.assets = [
      FakeAsset(androidId, 'IMG_1.jpg', DateTime(2026, 7, 26), bytesOf(1),
          throwOnRead: true),
    ];
    expect(await resolver.thumbFor(photoMeal(3)), isNull);
    expect(dao.thumbs, isEmpty);
  });

  test('checks one original at a time', () async {
    // Each check holds a photo's original (up to 25 MB), and a list build
    // asks for every visible meal at once.
    final reads = <String>[];
    final hashing = <Completer<String>>[];
    for (final n in [1, 2]) {
      library.thumbnails['10$n'] = Uint8List.fromList([n]);
      library.assets.add(FakeAsset(
          '10$n', 'IMG_$n.jpg', DateTime(2026, 7, 26), bytesOf(n),
          onRead: () => reads.add('10$n')));
    }
    final slow = MealThumbResolver(
        dao: dao,
        library: library,
        hasher: (_) => (hashing..add(Completer<String>())).last.future);

    final first = slow.thumbFor(photoMeal(1, fileId: '101', hash: 'h1'));
    final second = slow.thumbFor(photoMeal(2, fileId: '102', hash: 'h2'));
    await pumpEventQueue();
    expect(reads, ['101'], reason: 'the second original waits its turn');
    hashing.single.complete('h1');
    await pumpEventQueue();
    expect(reads, ['101', '102']);
    hashing.last.complete('h2');
    expect(await first, [1]);
    expect(await second, [2]);
  });

  test('text meals resolve null and never query the library', () async {
    library.thumbnails[androidId] = Uint8List.fromList([1]);
    expect(await resolver.thumbFor(textMeal(4)), isNull);
  });

  test('photo meal whose asset vanished resolves null (placeholder)',
      () async {
    expect(await resolver.thumbFor(photoMeal(5)), isNull);
  });

  test('evict clears one meal id', () async {
    dao.thumbs[8] = Uint8List.fromList([2]);
    await resolver.thumbFor(photoMeal(8));
    dao.thumbs[8] = Uint8List.fromList([3]);
    // Cached value until evicted.
    expect(await resolver.thumbFor(photoMeal(8)), [2]);
    resolver.evict(8);
    expect(await resolver.thumbFor(photoMeal(8)), [3]);
  });
}
