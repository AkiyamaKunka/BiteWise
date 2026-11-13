/// Android lists photos by when they joined the library, not when they were
/// taken (review 171, C4). photo_manager 3.10.0's Android side filters a
/// createDate window on MediaStore DATE_ADDED (CommonFilterOption.kt) and
/// orders by it (ConvertUtils.kt), but reports each photo's createDateTime
/// from DATE_TAKEN, or DATE_ADDED when there is none (CursorExtensions.kt).
/// A file copied onto the phone (a phone transfer, a USB copy, a saved
/// original) joins the library now with its old DATE_TAKEN, so the
/// automatic scans listed years-old photos as new ones: uploaded to the AI,
/// and logged as eaten today once older than 45 days. iOS lists by creation
/// date and is left as it was.
library;

import 'dart:math' as math;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// photo_manager's own channel (its PMMethodChannel only adds a cancelToken
/// key to the argument map).
const _channel = MethodChannel('com.fluttercandies/photo_manager');

/// One MediaStore image row.
class _Row {
  _Row(this.id, {required this.added, this.taken});
  final String id;

  /// DATE_ADDED: when the file joined the library.
  final DateTime added;

  /// DATE_TAKEN: when it was taken; null when the file says nothing.
  final DateTime? taken;

  int get addedSec => added.millisecondsSinceEpoch ~/ 1000;

  /// What photo_manager reports as createDateTime, in seconds.
  int get createDt {
    final t = taken;
    final s = t == null ? 0 : t.millisecondsSinceEpoch ~/ 1000;
    return s == 0 ? addedSec : s;
  }
}

/// Answers photo_manager's listing calls over [rows] the way its Android
/// side does: the createDate window filters DATE_ADDED, newest added first.
void _answerLikeAndroid(List<_Row> rows) {
  List<_Row> listed(Object? option) {
    final child = (option as Map)['child'] as Map;
    final date = child['createDate'] as Map;
    final min = (date['min'] as int) ~/ 1000;
    final max = (date['max'] as int) ~/ 1000;
    return [
      for (final r in rows)
        if (r.addedSec >= min && r.addedSec <= max) r,
    ]..sort((a, b) => b.addedSec.compareTo(a.addedSec));
  }

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    final args = call.arguments as Map;
    switch (call.method) {
      case 'getAssetPathList':
        return {
          'data': [
            {
              'id': 'isAll',
              'name': 'Recent',
              'assetCount': listed(args['option']).length,
              'isAll': true,
            },
          ],
        };
      case 'getAssetCountFromPath':
        return listed(args['option']).length;
      case 'getAssetListRange':
        final all = listed(args['option']);
        final start = math.min(args['start'] as int, all.length);
        final end = math.min(math.max(args['end'] as int, start), all.length);
        return {
          'data': [
            for (final r in all.sublist(start, end))
              {
                'id': r.id,
                'type': 1,
                'width': 4032,
                'height': 3024,
                'createDt': r.createDt,
                'modifiedDt': r.addedSec,
                'title': '${r.id}.jpg',
              },
          ],
        };
    }
    throw MissingPluginException(call.method);
  });
}

/// The real adapter's listing, with bytes and names served from memory
/// (reading an original goes through files the test host does not have).
class _ReadableLibrary implements PhotoLibrary {
  _ReadableLibrary(this.real);
  final PhotoManagerLibrary real;
  void Function()? onChange;

  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
          {int limit = 500}) async =>
      [
        for (final a in await real.imagesCreatedAfter(cutoff, limit: limit))
          _ReadableAsset(a),
      ];

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> startChangeNotify(void Function() onChange) async =>
      this.onChange = onChange;

  @override
  Future<void> stopChangeNotify() async => onChange = null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ReadableAsset implements LibraryAsset {
  _ReadableAsset(this._listed);
  final LibraryAsset _listed;

  @override
  String get id => _listed.id;

  @override
  DateTime get createDateTime => _listed.createDateTime;

  @override
  Future<String> fileName() async => '$id.jpg';

  @override
  Future<Uint8List?> originBytes() async =>
      Uint8List.fromList(id.codeUnits);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  // A fixed day in the past: the adapter caps its window at the real clock.
  final now = DateTime(2026, 7, 17, 13, 0);
  final today = DateTime(2026, 7, 17);

  // Taken today and added the moment it was taken.
  _Row lunch() => _Row('lunch',
      added: DateTime(2026, 7, 17, 12, 0, 5),
      taken: DateTime(2026, 7, 17, 12, 0, 3));
  // Taken and added yesterday: inside a 2-day window.
  _Row dinner() => _Row('dinner',
      added: DateTime(2026, 7, 16, 19, 0, 1),
      taken: DateTime(2026, 7, 16, 19, 0));
  // Copied onto the phone this morning, taken long before.
  _Row copied2024() => _Row('PXL_20240302_183000000',
      added: DateTime(2026, 7, 17, 11, 50),
      taken: DateTime(2024, 3, 2, 12, 30));
  _Row copied20DaysAgo() => _Row('IMG_20260627_130000',
      added: DateTime(2026, 7, 17, 11, 51),
      taken: DateTime(2026, 6, 27, 13, 0));
  // No date taken (EXIF stripped): dated by when it joined, as iOS does.
  _Row noTakenDate() =>
      _Row('saved_no_exif', added: DateTime(2026, 7, 17, 11, 52));

  group('PhotoManagerLibrary.imagesCreatedAfter', () {
    test('Android: lists only photos taken at/after the cutoff, not old '
        'ones copied onto the phone after it', () async {
      _answerLikeAndroid([
        lunch(),
        dinner(),
        copied2024(),
        copied20DaysAgo(),
        noTakenDate(),
      ]);
      final listed = await PhotoManagerLibrary(isAndroid: true)
          .imagesCreatedAfter(today, limit: 2000);
      expect(listed.map((a) => a.id).toSet(), {'lunch', 'saved_no_exif'});
    });

    test('Android: a photo taken in the same second as a cutoff with '
        'milliseconds still counts (both dates are whole seconds there)',
        () async {
      _answerLikeAndroid([
        _Row('snap',
            added: DateTime(2026, 7, 17, 12, 0, 1),
            taken: DateTime(2026, 7, 17, 12, 0, 0, 800)),
      ]);
      final listed = await PhotoManagerLibrary(isAndroid: true)
          .imagesCreatedAfter(DateTime(2026, 7, 17, 12, 0, 0, 600));
      expect(listed.map((a) => a.id), ['snap']);
    });

    test('iOS: the listing is returned as the library gave it', () async {
      _answerLikeAndroid([lunch(), copied2024()]);
      final listed = await PhotoManagerLibrary(isAndroid: false)
          .imagesCreatedAfter(today, limit: 2000);
      expect(listed.map((a) => a.id).toSet(),
          {'lunch', 'PXL_20240302_183000000'});
    });
  });

  group('the automatic scans over the Android library', () {
    late List<_Row> rows;
    late _ReadableLibrary library;
    late LibraryPhotoIntake intake;
    late List<IntakePhoto> offered;

    setUp(() {
      rows = [];
      _answerLikeAndroid(rows);
      library = _ReadableLibrary(PhotoManagerLibrary(isAndroid: true));
      intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => now);
      offered = [];
      intake.photos.listen(offered.add);
    });

    test('the catch-up offers the window\'s photos, none copied in from '
        'before it, and still covers the whole window', () async {
      rows.addAll([
        lunch(),
        dinner(),
        copied2024(),
        copied20DaysAgo(),
        noTakenDate(),
      ]);
      final frontier = await intake.backfillScan();
      await pumpEventQueue();
      expect(offered.map((p) => p.assetId),
          ['dinner', 'saved_no_exif', 'lunch']);
      expect(frontier, DateTime(2026, 7, 17, 12, 0, 3),
          reason: 'a photo left out is not one left unread: the frontier '
              'reaches the newest photo in the window');
    });

    test('the live watcher offers a photo just taken, not an old one '
        'copied in after it started', () async {
      await intake.start();
      rows.addAll([
        _Row('copied_in',
            added: now.add(const Duration(seconds: 10)),
            taken: DateTime(2025, 1, 5, 8, 0)),
        _Row('snack',
            added: now.add(const Duration(seconds: 21)),
            taken: now.add(const Duration(seconds: 20))),
      ]);
      library.onChange!();
      await pumpEventQueue(times: 50);
      expect(offered.map((p) => p.assetId), ['snack']);
      await intake.stop();
    });
  });
}
