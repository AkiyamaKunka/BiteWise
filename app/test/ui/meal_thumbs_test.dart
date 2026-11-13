// Thumb resolution (spec §9): stored thumb wins, library backfill persists
// exactly once and only from the meal's own photo, text meals resolve null,
// negative results are cached.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart'
    show maxPhotoBytes;
import 'package:calorie_tracker/ui/meal_thumbs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;
import 'fakes.dart';

Meal photoMeal(int id, {String fileId = 'asset1', String hash = 'h1'}) => Meal(
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
FakeAsset ownPhoto({String id = 'asset1', int n = 1}) =>
    FakeAsset(id, 'IMG_$n.jpg', DateTime(2026, 7, 26), bytesOf(n));

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
    library.thumbnails['asset1'] = Uint8List.fromList([1]);
    expect(await resolver.thumbFor(photoMeal(7)), [9, 9]);
  });

  test('library backfill persists the thumb so it happens once', () async {
    library.thumbnails['asset1'] = Uint8List.fromList([5, 5, 5]);
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
    library.thumbnails['asset1'] = Uint8List.fromList([7, 7, 7]);
    library.assets = [ownPhoto(n: 9)]; // the same id, another photo
    expect(await resolver.thumbFor(photoMeal(3)), isNull);
    expect(dao.thumbs, isEmpty);
  });

  test('the check is the md5 of the original against the stored hash',
      () async {
    // The production hasher (on a worker isolate), and a stored hash in
    // another case still matches (image hashes are normalized).
    final original = bytesOf(4, 64);
    library.thumbnails['asset1'] = Uint8List.fromList([5]);
    library.assets = [
      FakeAsset('asset1', 'IMG_4.jpg', DateTime(2026, 7, 26), original),
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
      'taken', () async {
    // On Android another phone's id can name a video: thumbnailByAssetId
    // answers for it, imagesByIds does not.
    library.thumbnails['asset1'] = Uint8List.fromList([7]);
    expect(await resolver.thumbFor(photoMeal(3)), isNull);
    expect(dao.thumbs, isEmpty);
  });

  test('an original over the intake cap is never the meal photo', () async {
    // Intake refuses those (§8), so no meal was logged from one.
    library.thumbnails['asset1'] = Uint8List.fromList([7]);
    library.assets = [
      FakeAsset('asset1', 'IMG_0.jpg', DateTime(2026, 7, 26),
          Uint8List(maxPhotoBytes + 1)),
    ];
    expect(await resolver.thumbFor(photoMeal(3, hash: 'h0')), isNull);
    expect(dao.thumbs, isEmpty);
  });

  test('an original that cannot be read gives no picture rather than a '
      'guess', () async {
    library.thumbnails['asset1'] = Uint8List.fromList([7]);
    library.assets = [
      FakeAsset('asset1', 'IMG_1.jpg', DateTime(2026, 7, 26), bytesOf(1),
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
      library.thumbnails['a$n'] = Uint8List.fromList([n]);
      library.assets.add(FakeAsset(
          'a$n', 'IMG_$n.jpg', DateTime(2026, 7, 26), bytesOf(n),
          onRead: () => reads.add('a$n')));
    }
    final slow = MealThumbResolver(
        dao: dao,
        library: library,
        hasher: (_) => (hashing..add(Completer<String>())).last.future);

    final first = slow.thumbFor(photoMeal(1, fileId: 'a1', hash: 'h1'));
    final second = slow.thumbFor(photoMeal(2, fileId: 'a2', hash: 'h2'));
    await pumpEventQueue();
    expect(reads, ['a1'], reason: 'the second original waits its turn');
    hashing.single.complete('h1');
    await pumpEventQueue();
    expect(reads, ['a1', 'a2']);
    hashing.last.complete('h2');
    expect(await first, [1]);
    expect(await second, [2]);
  });

  test('text meals resolve null and never query the library', () async {
    library.thumbnails['asset1'] = Uint8List.fromList([1]);
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
