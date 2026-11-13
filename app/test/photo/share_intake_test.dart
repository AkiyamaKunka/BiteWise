// Deliberate intake (spec §6, §2.3): share-sheet stream + pickFromRecent,
// all deliberate=true; §6.1 extension filter; §8 25 MB cap.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/share_intake.dart';
import 'package:flutter_test/flutter_test.dart';

import 'watcher_test.dart' show FakeAsset, FakePhotoLibrary;

class FakeShareSource implements SharedMediaSource {
  final StreamController<List<String>> controller =
      StreamController<List<String>>();
  List<String> initial = [];

  @override
  Stream<List<String>> imagePathBatches() => controller.stream;

  @override
  Future<List<String>> initialImagePaths() async => initial;
}

void main() {
  final now = DateTime(2026, 7, 17, 12, 0, 0);
  final files = <String, Uint8List>{};

  Future<Uint8List?> readBytes(String path) async => files[path];

  final cleaned = <String>[];

  ShareIntake build(FakeShareSource source, FakePhotoLibrary library) =>
      ShareIntake(
          source: source,
          library: library,
          readBytes: readBytes,
          cleanup: (path) async => cleaned.add(path),
          clock: () => now);

  setUp(() {
    files.clear();
    cleaned.clear();
  });

  group('share stream', () {
    test('shared image becomes a deliberate IntakePhoto with filename date',
        () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      files['/shared/IMG_20260716_193042.jpg'] =
          Uint8List.fromList([1, 2, 3]);

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add(['/shared/IMG_20260716_193042.jpg']);
      await pumpEventQueue();

      expect(emitted, hasLength(1));
      final photo = emitted.single;
      expect(photo.deliberate, isTrue); // §2.3 deliberate re-send policy
      expect(photo.fileName, 'IMG_20260716_193042.jpg');
      expect(photo.capturedAt, DateTime(2026, 7, 16, 19, 30, 42));
      expect(photo.bytes, [1, 2, 3]);
      // Plugin contract: the container copy is deleted once consumed —
      // without this every shared photo leaks in the app group forever.
      expect(cleaned, ['/shared/IMG_20260716_193042.jpg']);
      await sub.cancel();
    });

    test('rejected shares (bad extension / oversized) still clean up the copy',
        () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      files['/shared/notes.txt'] = Uint8List.fromList([1]);
      files['/shared/IMG_big.jpg'] =
          Uint8List.fromList(List.filled(maxPhotoBytes + 1, 0));

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add(['/shared/notes.txt', '/shared/IMG_big.jpg']);
      await pumpEventQueue();

      expect(emitted, isEmpty);
      expect(cleaned,
          containsAll(['/shared/notes.txt', '/shared/IMG_big.jpg']));
      await sub.cancel();
    });

    test('cold-start (initial) share is delivered first', () async {
      final source = FakeShareSource()
        ..initial = ['/shared/launch_meal.png'];
      files['/shared/launch_meal.png'] = Uint8List.fromList([9]);
      final intake = build(source, FakePhotoLibrary());

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      await pumpEventQueue();
      expect(emitted.map((p) => p.fileName), ['launch_meal.png']);
      // No filename timestamp and no asset date → capturedAt null (§6.3
      // fallback: intake-time dating happens downstream).
      expect(emitted.single.capturedAt, isNull);
      await sub.cancel();
    });

    test('unsupported extensions and unreadable/oversized files are skipped',
        () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      files['/shared/notes.txt'] = Uint8List.fromList([1]);
      files['/shared/huge.jpg'] = Uint8List(maxPhotoBytes + 1);
      // '/shared/gone.jpg' unreadable: not in the map.
      files['/shared/ok.HEIC'] = Uint8List.fromList([5]); // case-insensitive

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add([
        '/shared/notes.txt',
        '/shared/huge.jpg',
        '/shared/gone.jpg',
        '/shared/ok.HEIC',
      ]);
      await pumpEventQueue();
      expect(emitted.map((p) => p.fileName), ['ok.HEIC']);
      await sub.cancel();
    });
  });

  // Review 171, C5: on Android the plugin hands over whatever path it
  // made of the share — a sender-chosen name could climb out of the cache,
  // and a share with no stream handed over its text — and the intake read
  // it when it looked like a photo, then deleted it in every case. Only
  // MainActivity's own copies may be read or deleted there.
  group('Android: only the share folder\'s copies are read or deleted', () {
    late Directory app; // stands in for the app's private data directory
    late String folder;

    setUp(() {
      app = Directory.systemTemp.createTempSync('share_c5_');
      folder = '${app.path}/cache/$androidShareFolderName';
      Directory('$folder/1').createSync(recursive: true);
    });
    tearDown(() => app.deleteSync(recursive: true));

    File appFile(String relative, List<int> bytes) =>
        File('${app.path}/$relative')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);

    test('a path outside the folder is left alone; the copy inside is read '
        'and deleted', () async {
      final db = appFile('databases/calorie_tracker.db', [1, 2, 3]);
      final prefs =
          appFile('shared_prefs/FlutterSharedPreferences.xml', [4]);
      final private = appFile('files/private.jpg', [5]);
      final copy = File('$folder/1/IMG_20260716_193042.jpg')
        ..writeAsBytesSync([7, 7]);
      final source = FakeShareSource()
        ..initial = [
          db.path, // a share with no stream: its text became the path
          '$folder/1/../../../shared_prefs/FlutterSharedPreferences.xml',
          '$folder/1/../../../files/private.jpg',
          copy.path,
        ];
      final read = <String>[];
      final intake = ShareIntake(
          source: source,
          library: FakePhotoLibrary(),
          readBytes: (path) async {
            read.add(path);
            return File(path).readAsBytes();
          },
          // The production cleanup: a real delete.
          sharedFolder: () async => folder,
          clock: () => now);

      final photo = await intake.photos().first;
      expect(photo.fileName, 'IMG_20260716_193042.jpg');
      expect(read, [copy.path]);
      expect(copy.existsSync(), isFalse,
          reason: 'the copy is still deleted once read');
      expect(db.existsSync(), isTrue);
      expect(prefs.existsSync(), isTrue);
      expect(private.existsSync(), isTrue);
    });

    test('a folder that cannot be found reads and deletes nothing',
        () async {
      final copy = File('$folder/1/IMG_1.jpg')..writeAsBytesSync([7]);
      final source = FakeShareSource()..initial = [copy.path];
      final read = <String>[];
      final intake = ShareIntake(
          source: source,
          library: FakePhotoLibrary(),
          readBytes: (path) async {
            read.add(path);
            return File(path).readAsBytes();
          },
          cleanup: (path) async => cleaned.add(path),
          sharedFolder: () async => throw const FileSystemException('none'),
          clock: () => now);

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      await pumpEventQueue();
      expect(emitted, isEmpty);
      expect(read, isEmpty);
      expect(cleaned, isEmpty);
      await sub.cancel();
    });

    test('isWithinFolder resolves . and .. and never matches a sibling',
        () {
      const f = '/data/user/0/app/cache/shared_photos';
      expect(isWithinFolder('$f/123/a.jpg', f), isTrue);
      expect(isWithinFolder('$f/./123/a.jpg', f), isTrue);
      expect(isWithinFolder('$f/123/../456/a.jpg', f), isTrue);
      expect(isWithinFolder(f, f), isFalse);
      expect(isWithinFolder('$f/..', f), isFalse);
      expect(isWithinFolder('$f/../../databases/x.db', f), isFalse);
      expect(isWithinFolder('${f}_x/a.jpg', f), isFalse);
      expect(isWithinFolder('/data/user/0/app/cache/a.jpg', f), isFalse);
      expect(isWithinFolder('shared_photos/a.jpg', f), isFalse);
      expect(isWithinFolder('/../$f/a.jpg', f), isFalse);
    });

    // The Kotlin side copies into this folder and refuses what Dart would
    // refuse by size, before the plugin sees the launch intent (read while
    // super.onCreate attaches it) or a later one.
    test('MainActivity.kt copies into the same folder, under the same cap, '
        'before the plugin sees any intent', () {
      final kotlin = File('android/app/src/main/kotlin/dev/calorietracker/'
              'calorie_tracker/MainActivity.kt')
          .readAsStringSync();
      expect(kotlin,
          contains('const val SHARE_FOLDER = "$androidShareFolderName"'));
      expect(maxPhotoBytes, 25 * 1024 * 1024);
      expect(kotlin, contains('const val MAX_SHARE_BYTES = 25L * 1024 * 1024'));
      final create = RegExp(r'override fun onCreate\(.*?\n    \}', dotAll: true)
          .firstMatch(kotlin)
          ?.group(0);
      expect(create, isNotNull);
      final copy = create!.indexOf('setIntent(withSafeShares(it))');
      expect(copy, greaterThanOrEqualTo(0));
      expect(create.indexOf('super.onCreate('), greaterThan(copy));
      expect(kotlin, contains('super.onNewIntent(withSafeShares(intent))'));
    });
  });

  group('§6.1 extension filter', () {
    test('accepts jpg/jpeg/png/heic/heif/tiff, rejects the rest', () {
      for (final name in [
        'a.jpg', 'a.JPEG', 'a.png', 'a.heic', 'a.HEIF', 'a.tiff'
      ]) {
        expect(hasSupportedPhotoExtension(name), isTrue, reason: name);
      }
      for (final name in ['a.gif', 'a.mp4', 'a.txt', 'noext', 'a.']) {
        expect(hasSupportedPhotoExtension(name), isFalse, reason: name);
      }
    });
  });

  group('pickFromRecent', () {
    test('returns deliberate photos, newest first, honoring the limit',
        () async {
      final library = FakePhotoLibrary()
        ..assets = [
          FakeAsset('p1', 'IMG_20260717_080000.jpg',
              DateTime(2026, 7, 17, 8, 0), Uint8List.fromList([1])),
          FakeAsset('p2', 'IMG_20260716_080000.jpg',
              DateTime(2026, 7, 16, 8, 0), Uint8List.fromList([2])),
          FakeAsset('p3', 'IMG_20260715_080000.jpg',
              DateTime(2026, 7, 15, 8, 0), Uint8List.fromList([3])),
        ];
      final intake = build(FakeShareSource(), library);

      final picked = await intake.pickFromRecent(2);
      expect(picked.map((p) => p.assetId), ['p1', 'p2']);
      expect(picked.every((p) => p.deliberate), isTrue); // §2.3 reclaim rule
      expect(picked.first.capturedAt, DateTime(2026, 7, 17, 8, 0, 0));
    });

    test('permission denied → empty result', () async {
      final library = FakePhotoLibrary()..permissionGranted = false;
      final intake = build(FakeShareSource(), library);
      expect(await intake.pickFromRecent(5), isEmpty);
    });

    test('non-positive limit → empty without touching the library', () async {
      final library = FakePhotoLibrary();
      final intake = build(FakeShareSource(), library);
      expect(await intake.pickFromRecent(0), isEmpty);
      expect(library.permissionRequests, 0);
    });
  });

  // Design G2a: a shared or picked photo carries how it was taken, read
  // from its own bytes — the badge works for those too.
  group('capture (G2a)', () {
    test('a shared glasses file: recognized by its name; no asset, so no '
        'creation date and no album', () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      const path = '/shared/photo-77_singular_display_fullPicture.HEIC';
      files[path] = Uint8List.fromList([1, 2, 3]);
      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add([path]);
      await pumpEventQueue();
      final capture = emitted.single.capture!;
      expect(capture.device, CaptureDevice.metaGlasses);
      expect(capture.signal, CaptureSignal.filename);
      expect(capture.createDate, isNull);
      await sub.cancel();
    });

    test('a picked photo keeps its creation date', () async {
      final created = DateTime(2026, 7, 17, 8, 0);
      final library = FakePhotoLibrary()
        ..assets = [
          FakeAsset('p1', 'IMG_1.HEIC', created, Uint8List.fromList([1])),
        ];
      final picked =
          await build(FakeShareSource(), library).pickFromRecent(1);
      expect(picked.single.capture!.createDate, created);
      expect(picked.single.capture!.device, CaptureDevice.unknown);
    });
  });
}
