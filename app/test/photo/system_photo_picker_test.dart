// The Dart half of Android's system Photo Picker (Play's photo policy):
// the pickImages contract on dev.calorietracker/files, the copies it reads
// and deletes (and only those), the photo it builds, and the md5 identity
// that keeps a picked photo from being logged again by Watch Camera Roll.
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/backup/file_pick_channel.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/system_photo_picker.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _channel = MethodChannel(filesChannelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime(2026, 11, 13, 19, 30);

  late Directory cache; // stands in for the app's cache directory
  late String folder;
  late List<MethodCall> calls;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('picker_');
    folder = '${cache.path}/$androidPickedPhotoFolderName';
    Directory(folder).createSync();
    calls = [];
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    cache.deleteSync(recursive: true);
  });

  /// The native side answering [reply] (or throwing it).
  void answer(Object? Function(MethodCall call) reply) =>
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return reply(call);
      });

  /// A copy where MainActivity puts one: its own folder under [folder].
  File copy(String name, List<int> bytes, {String id = 'u1'}) =>
      File('$folder/$id/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  SystemPhotoPicker picker({Future<Uint8List?> Function(String)? read}) =>
      SystemPhotoPicker(
          pickedFolder: () async => folder, readBytes: read, clock: () => now);

  group('the pickImages contract', () {
    test('asks for pickImages with max, and builds the photo the grid and '
        'the share sheet build', () async {
      final f = copy('PXL_20261113_013000000.jpg', [1, 2, 3]);
      final taken = DateTime(2026, 11, 12, 19, 30);
      answer((_) => {
            'status': 'ok',
            'items': [
              {
                'path': f.path,
                'name': 'PXL_20261113_013000000.jpg',
                'dateTakenMs': taken.millisecondsSinceEpoch,
              }
            ],
            'tooBig': 0,
            'failed': 0,
          });

      final pick = await picker().pick();
      expect(calls.single.method, pickImagesMethod);
      expect(calls.single.arguments, {'max': 1});
      expect(pick.status, SystemPickStatus.ok);
      final photo = pick.photos.single;
      expect(photo.bytes, [1, 2, 3]);
      expect(photo.fileName, 'PXL_20261113_013000000.jpg');
      expect(photo.assetId, '', reason: 'a picker URI is no library asset');
      expect(photo.deliberate, isTrue,
          reason: 'user-picked: reclaims failed/skipped rows (spec §2.3)');
      // Pixel names are UTC (filenameCaptureInstant): the name wins over
      // DATE_TAKEN, as in the grid's rule.
      expect(photo.capturedAt, DateTime.utc(2026, 11, 13, 1, 30).toLocal());
      expect(photo.capture, isNotNull, reason: 'design G2a');
    });

    test('without a dated name, DATE_TAKEN dates it', () async {
      final f = copy('lunch.jpg', [4]);
      final taken = DateTime(2026, 11, 13, 12, 5);
      answer((_) => {
            'status': 'ok',
            'items': [
              {
                'path': f.path,
                'name': 'lunch.jpg',
                'dateTakenMs': taken.millisecondsSinceEpoch
              }
            ],
          });
      final photo = (await picker().pick()).photos.single;
      expect(photo.capturedAt, taken);
      expect(photo.capture!.createDate, taken);
    });

    test('each copy AND its folder are deleted once read; the picked_photos '
        'folder stays', () async {
      final f = copy('a.jpg', [1]);
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': f.path, 'name': 'a.jpg'}
            ],
          });
      await picker().pick();
      expect(f.existsSync(), isFalse);
      expect(f.parent.existsSync(), isFalse);
      expect(Directory(folder).existsSync(), isTrue);
    });

    test('over 25 MB is refused, counted and deleted, never handed on',
        () async {
      final f = copy('big.jpg', [1]);
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': f.path, 'name': 'big.jpg'}
            ],
            'tooBig': 1, // one more the native side refused itself
          });
      final pick = await picker(
              read: (_) async => Uint8List(maxPhotoBytes + 1))
          .pick();
      expect(pick.photos, isEmpty);
      expect(pick.tooBig, 2);
      expect(f.existsSync(), isFalse);
    });

    test('an unreadable or empty copy is counted as failed and deleted',
        () async {
      final empty = copy('empty.jpg', [], id: 'u1');
      final gone = '$folder/u2/gone.jpg';
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': empty.path, 'name': 'empty.jpg'},
              {'path': gone, 'name': 'gone.jpg'},
            ],
            'failed': 1,
          });
      final pick = await picker().pick(max: 2);
      expect(pick.photos, isEmpty);
      expect(pick.failed, 3);
      expect(empty.existsSync(), isFalse);
    });

    test('a path outside picked_photos is never read or deleted', () async {
      final db = File('${cache.path}/../databases/calorie_tracker.db');
      final private = File('${cache.path}/private.jpg')
        ..writeAsBytesSync([5]);
      final inside = copy('ok.jpg', [6]);
      final read = <String>[];
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': private.path, 'name': 'private.jpg'},
              {'path': '$folder/u1/../../private.jpg', 'name': 'x.jpg'},
              {'path': db.path, 'name': 'db.jpg'},
              {'path': 'relative/a.jpg', 'name': 'a.jpg'},
              {'path': inside.path, 'name': 'ok.jpg'},
            ],
          });
      final pick = await picker(read: (p) async {
        read.add(p);
        return File(p).readAsBytes();
      }).pick(max: 5);
      expect(read, [inside.path]);
      expect(pick.photos.single.bytes, [6]);
      expect(pick.failed, 4);
      expect(private.existsSync(), isTrue);
    });

    test('a folder that cannot be found reads and deletes nothing', () async {
      final f = copy('a.jpg', [1]);
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': f.path, 'name': 'a.jpg'}
            ],
          });
      final pick = await SystemPhotoPicker(
              pickedFolder: () async => throw const FileSystemException('x'))
          .pick();
      expect(pick.photos, isEmpty);
      expect(f.existsSync(), isTrue);
    });

    test('a name with folders keeps its last part only', () async {
      final f = copy('a.jpg', [1]);
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': f.path, 'name': '../../evil/IMG_20261113_120000.jpg'}
            ],
          });
      expect((await picker().pick()).photos.single.fileName,
          'IMG_20261113_120000.jpg');
    });

    test('no more than max photos; the extra copies are still deleted',
        () async {
      final a = copy('a.jpg', [1], id: 'u1');
      final b = copy('b.jpg', [2], id: 'u2');
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': a.path, 'name': 'a.jpg'},
              {'path': b.path, 'name': 'b.jpg'},
            ],
          });
      final pick = await picker().pick();
      expect(pick.photos.map((p) => p.fileName), ['a.jpg']);
      expect(b.existsSync(), isFalse);
    });

    test('cancelled, busy and unavailable pass through', () async {
      for (final (status, want) in const [
        ('cancelled', SystemPickStatus.cancelled),
        ('busy', SystemPickStatus.busy),
        ('unavailable', SystemPickStatus.unavailable),
        ('something new', SystemPickStatus.unavailable),
      ]) {
        answer((_) => {'status': status});
        final pick = await picker().pick();
        expect(pick.status, want, reason: status);
        expect(pick.photos, isEmpty);
      }
    });

    test('a reply that is not a map is unavailable', () async {
      answer((_) => 'ok');
      expect((await picker().pick()).status, SystemPickStatus.unavailable);
    });

    test('a native error is unavailable, never the old permission flow',
        () async {
      answer((_) => throw PlatformException(code: 'boom'));
      expect((await picker().pick()).status, SystemPickStatus.unavailable);
    });

    test('a build without the method is unavailable too: never the old '
        'grid flow, whose library request is a dead end on the Play build',
        () async {
      // No handler: MissingPluginException, as notImplemented() gives.
      expect((await picker().pick()).status, SystemPickStatus.unavailable);
      answer((_) => throw MissingPluginException());
      expect((await picker().pick()).status, SystemPickStatus.unavailable);
    });
  });

  group('full access is read strictly', () {
    test('only a full grant is full; an error is not', () async {
      expect(await SystemPhotoPicker(broadAccess: () async => true)
              .hasBroadAccess(),
          isTrue);
      expect(await SystemPhotoPicker(broadAccess: () async => false)
              .hasBroadAccess(),
          isFalse);
      expect(
          await SystemPhotoPicker(
                  broadAccess: () async => throw PlatformException(code: 'x'))
              .hasBroadAccess(),
          isFalse,
          reason: 'unknown must not open the grid, whose listing asks for '
              'the permission');
    });

    test('the production probe asks photo_manager without a prompt, and '
        'with no answer it is not full', () async {
      const pm = MethodChannel('com.fluttercandies/photo_manager');
      final methods = <String>[];
      messenger.setMockMethodCallHandler(pm, (call) async {
        methods.add(call.method);
        throw PlatformException(code: 'no');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(pm, null));
      expect(await SystemPhotoPicker().hasBroadAccess(), isFalse);
      expect(methods, ['getPermissionState'],
          reason: 'never requestPermissionExtend: that would prompt');
    });
  });

  test('the platform picker is Android-only (null on iOS and in tests)', () {
    expect(platformSystemPhotoPicker(), Platform.isAndroid ? isNotNull : null);
  });

  test('the folder is picked_photos in the cache directory', () async {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const cacheDir = '/data/user/0/dev.calorietracker.calorie_tracker/cache';
    messenger.setMockMethodCallHandler(pathChannel,
        (call) async => call.method == 'getTemporaryDirectory' ? cacheDir : null);
    addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));
    expect(await androidPickedPhotoFolder(), '$cacheDir/picked_photos');
  });

  // md5 identity (spec §6.2): a photo logged through the picker carries no
  // library asset id, so Watch Camera Roll cannot skip it by id. It reads
  // the same photo's bytes from the library later, and the ledger must
  // answer "already logged" — not a second meal, not a second model call.
  // On a phone both reads pass MediaProvider's location redaction (device
  // QA confirms the bytes match); here they are the same bytes.
  group('a photo logged through the picker, later seen by the watcher', () {
    late Database db;
    late SqfliteMealsDao dao;
    late _Library library;
    late _Analyzer analyzer;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await openAppDatabase(path: inMemoryDatabasePath);
      dao = SqfliteMealsDao(db, clock: () => now);
      library = _Library();
      analyzer = _Analyzer();
    });
    tearDown(() async => db.close());

    PhotoPipeline pipeline() => PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        hasher: (b) async => originalBytesMd5(b),
        thumbnailer: (_) async => null,
        clock: () => now);

    Future<IntakePhoto> pickLunch(Uint8List bytes) async {
      final f = copy('PXL_20261113_180500000.jpg', bytes);
      answer((_) => {
            'status': 'ok',
            'items': [
              {'path': f.path, 'name': 'PXL_20261113_180500000.jpg'}
            ],
          });
      return (await picker().pick()).photos.single;
    }

    Future<List<Meal>> meals() => dao.mealsBetween('2026-11-01', '2026-11-30');

    test('is not analyzed or logged a second time', () async {
      final bytes = _bytes(3);
      final out = await pipeline().enqueue(await pickLunch(bytes));
      expect(out.kind, PhotoOutcomeKind.saved);
      expect(analyzer.calls, 1);

      // The same photo in the library, as the watcher's catch-up lists it.
      library.assets.add(_Asset('1000000042', DateTime(2026, 11, 13, 12, 5),
          Uint8List.fromList(bytes)));
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => now);
      final outcomes = <PhotoOutcome>[];
      final p = pipeline();
      intake.attachSink((photo, _) async {
        final o = await p.enqueue(photo);
        outcomes.add(o);
        return !o.retryable;
      });
      await intake.backfillScan();

      expect(outcomes.single.kind, PhotoOutcomeKind.alreadyTracked);
      expect(analyzer.calls, 1, reason: 'no second model call');
      expect(await meals(), hasLength(1), reason: 'one photo, one meal');
    });

    test('counts as logged, not missing, in Photo Coverage', () async {
      final bytes = _bytes(5);
      await pipeline().enqueue(await pickLunch(bytes));
      library.assets.add(_Asset('1000000043', DateTime(2026, 11, 13, 12, 5),
          Uint8List.fromList(bytes)));
      final report = await CoverageAuditor(
              library: library,
              dao: dao,
              hasher: (b) async => originalBytesMd5(b),
              clock: () => now)
          .audit(lookbackDays: 2);
      expect(report.missing, isEmpty,
          reason: '"Log all" would have logged it a second time');
      expect(report.logged.map((i) => i.assetId), ['1000000043']);
    });
  });
}

Uint8List _bytes(int seed) =>
    Uint8List.fromList(List.generate(64, (i) => (i * seed + seed) % 256));

class _Asset implements LibraryAsset {
  _Asset(this.id, this.createDateTime, this.bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  final String id;
  @override
  final DateTime createDateTime;
  final Uint8List bytes;
  @override
  Future<String> fileName() async => 'PXL_20261113_180500000.jpg';
  @override
  Future<Uint8List?> originBytes() async => bytes;
}

class _Library implements PhotoLibrary {
  final List<_Asset> assets = [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId,
          {int size = 160}) async =>
      null;
  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) async =>
      assets.where((a) => a.id == assetId).firstOrNull?.bytes;
  @override
  Future<bool> hasFullAccess() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
          {int limit = 500}) async =>
      assets
          .where((a) => !a.createDateTime.isBefore(cutoff))
          .take(limit)
          .toList();
  @override
  Future<List<LibraryAsset>> recentImages(int limit) async =>
      assets.take(limit).toList();
  @override
  Future<Map<String, LibraryAsset?>> imagesByIds(List<String> ids) async => {
        for (final id in ids) id: assets.where((a) => a.id == id).firstOrNull
      };
  @override
  Future<void> startChangeNotify(void Function() onChange) async {}
  @override
  Future<void> stopChangeNotify() async {}
}

class _Analyzer implements AnalyzerService {
  int calls = 0;
  @override
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals}) async {
    calls++;
    return const AnalysisOutcome(
        analysis: {
          'is_food': true,
          'meal_description': 'Beef noodle soup',
          'total_calories': 650,
        },
        isFood: true,
        wall: Duration.zero);
  }

  @override
  Future<Map<String, dynamic>?> textIntent(String prompt) async => null;
  @override
  Future<String?> validateKey(String apiKey) async => null;
  @override
  Future<Map<String, dynamic>?> leftoverIntent(
          Uint8List originalBytes, String originalCompact) async =>
      null;
  @override
  Future<KeyProbe> probeKey(String apiKey) async =>
      const KeyProbe(KeyProbeResult.ok);
}
