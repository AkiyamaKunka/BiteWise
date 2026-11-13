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
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/fakes.dart' show FakeDao;

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
/// (reading an original goes through files the test host does not have),
/// and with the count the library listed.
class _ReadableLibrary implements PhotoLibrary {
  _ReadableLibrary(this.real);
  final PhotoManagerLibrary real;
  void Function()? onChange;

  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
      {int limit = 500}) async {
    final listed = await real.imagesCreatedAfter(cutoff, limit: limit);
    return LibraryListing([for (final a in listed) _ReadableAsset(a)],
        listed: listedCount(listed));
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> hasFullAccess() async => true;

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

  // Review 171, C4 second pass: Android finds a photo imported late (the
  // Meta AI app copying glasses photos in hours after they were taken,
  // AirDrop, a WeChat original) because its scans list by DATE_ADDED; iOS
  // reads its change history for them (photo_changes.dart). Keeping only
  // the photos taken since each scan's own cutoff (the live watcher's,
  // the background run's watermark less its hour) left them to the next
  // launch, and lost them once that was after the window. The bound is
  // the lookback window's start, as in iOS's late-import pass.
  group('photos imported late, inside the lookback window', () {
    // 19:00; a 2-day window started yesterday at 00:00.
    final evening = DateTime(2026, 7, 17, 19, 0);
    final windowStart = lookbackCutoff(evening, 2);

    // Lunch, taken on the glasses at 12:00 and imported by the Meta AI app
    // at 18:00.
    _Row glassesLunch() => _Row('photo_glasses_lunch',
        added: DateTime(2026, 7, 17, 18, 0),
        taken: DateTime(2026, 7, 17, 12, 0));
    // Last night's dinner, sent over this evening.
    _Row lateDinner() => _Row('dinner_late',
        added: DateTime(2026, 7, 17, 18, 5),
        taken: DateTime(2026, 7, 16, 19, 30));
    // Taken on the phone at 15:00 and logged then: the watermark.
    _Row phoneSnack() => _Row('phone_snack',
        added: DateTime(2026, 7, 17, 15, 0, 1),
        taken: DateTime(2026, 7, 17, 15, 0));
    // Copied in this evening, taken before the window.
    _Row oldCopy() => _Row('PXL_20240302_183000000',
        added: DateTime(2026, 7, 17, 18, 30),
        taken: DateTime(2024, 3, 2, 12, 30));
    _Row dayBefore() => _Row('IMG_20260715_201500',
        added: DateTime(2026, 7, 17, 18, 31),
        taken: DateTime(2026, 7, 15, 20, 15));

    test('Android: a scan from a later cutoff keeps what was taken since '
        'the window started, and nothing from before it', () async {
      _answerLikeAndroid(
          [glassesLunch(), lateDinner(), phoneSnack(), oldCopy(), dayBefore()]);
      final listed =
          await PhotoManagerLibrary(isAndroid: true, windowStart: () => windowStart)
              .imagesCreatedAfter(DateTime(2026, 7, 17, 14, 0));
      expect(listed.map((a) => a.id).toSet(),
          {'photo_glasses_lunch', 'dinner_late', 'phone_snack'});
    });

    test('Android: a cutoff before the window\'s start is the bound (a scan '
        'asked for more days)', () async {
      _answerLikeAndroid([dayBefore(), oldCopy()]);
      final listed =
          await PhotoManagerLibrary(isAndroid: true, windowStart: () => windowStart)
              .imagesCreatedAfter(DateTime(2026, 7, 10));
      expect(listed.map((a) => a.id), ['IMG_20260715_201500']);
    });

    test('Android: no window start, or one that cannot be read, leaves the '
        'scan\'s own cutoff', () async {
      _answerLikeAndroid([glassesLunch(), phoneSnack()]);
      for (final library in [
        PhotoManagerLibrary(isAndroid: true),
        PhotoManagerLibrary(
            isAndroid: true, windowStart: () => throw StateError('settings')),
      ]) {
        final listed =
            await library.imagesCreatedAfter(DateTime(2026, 7, 17, 14, 0));
        expect(listed.map((a) => a.id), ['phone_snack']);
      }
    });

    test('iOS: the window start changes nothing', () async {
      _answerLikeAndroid([glassesLunch(), oldCopy()]);
      final listed =
          await PhotoManagerLibrary(isAndroid: false, windowStart: () => windowStart)
              .imagesCreatedAfter(DateTime(2026, 7, 17, 14, 0));
      expect(listed.map((a) => a.id).toSet(),
          {'photo_glasses_lunch', 'PXL_20240302_183000000'});
    });

    test('the background run from its watermark offers the glasses lunch '
        'imported after it, not the old copy', () async {
      _answerLikeAndroid([glassesLunch(), phoneSnack(), oldCopy()]);
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: _ReadableLibrary(PhotoManagerLibrary(
              isAndroid: true, windowStart: () => windowStart)),
          clock: () => evening);
      final offered = <IntakePhoto>[];
      intake.photos.listen(offered.add);
      // The watermark is the 15:00 snack; the run scans from an hour
      // before it.
      await intake.backfillScan(since: DateTime(2026, 7, 17, 14, 0));
      await pumpEventQueue();
      expect(offered.map((p) => p.assetId),
          ['photo_glasses_lunch', 'phone_snack']);
    });

    test('the live watcher offers a glasses photo imported after it '
        'started, not an old copy', () async {
      final rows = <_Row>[];
      _answerLikeAndroid(rows);
      final opened = DateTime(2026, 7, 17, 13, 0); // after lunch was taken
      final library = _ReadableLibrary(PhotoManagerLibrary(
          isAndroid: true, windowStart: () => lookbackCutoff(opened, 2)));
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => opened);
      final offered = <IntakePhoto>[];
      intake.photos.listen(offered.add);
      await intake.start();
      rows.addAll([
        _Row('photo_glasses_lunch',
            added: DateTime(2026, 7, 17, 13, 1),
            taken: DateTime(2026, 7, 17, 12, 0)),
        _Row('copied_in',
            added: DateTime(2026, 7, 17, 13, 1, 10),
            taken: DateTime(2025, 1, 5, 8, 0)),
      ]);
      library.onChange!();
      await pumpEventQueue(times: 50);
      expect(offered.map((p) => p.assetId), ['photo_glasses_lunch']);
      await intake.stop();
    });
  });

  // Review 171, C4 second pass: the listing is capped before any photo is
  // left out, so a phone transfer of 2000 old photos, added after the
  // window's own photos, fills it. Judged by what was kept, such a scan
  // read as complete: no "backlog is very large" warning, a watermark free
  // to move, and a green coverage check over a dinner photo nobody looked
  // at. Truncation is judged by what the library listed.
  group('a listing the old copies fill', () {
    final morning = DateTime(2026, 7, 17, 9, 0);
    // Yesterday's dinner: inside the 2-day window, not logged yet.
    _Row dinner() => _Row('dinner',
        added: DateTime(2026, 7, 16, 19, 0, 1),
        taken: DateTime(2026, 7, 16, 19, 0));
    // This morning, from the old phone: added today, taken in 2020.
    List<_Row> copies(int n) => [
          for (var i = 0; i < n; i++)
            _Row('old_$i',
                added: DateTime(2026, 7, 17, 8, 0).add(Duration(seconds: i)),
                taken: DateTime(2020, 5, 1).add(Duration(minutes: i))),
        ];

    test('Android: the listing says how many photos the library listed',
        () async {
      _answerLikeAndroid([dinner(), ...copies(backfillQueryLimit)]);
      final capped = await PhotoManagerLibrary(isAndroid: true)
          .imagesCreatedAfter(lookbackCutoff(morning, 2),
              limit: backfillQueryLimit);
      expect(capped, isEmpty);
      expect(listedCount(capped), backfillQueryLimit);

      _answerLikeAndroid([dinner(), ...copies(3)]);
      final whole = await PhotoManagerLibrary(isAndroid: true)
          .imagesCreatedAfter(lookbackCutoff(morning, 2),
              limit: backfillQueryLimit);
      expect(whole.map((a) => a.id), ['dinner']);
      expect(listedCount(whole), 4);
    });

    test('the catch-up reports the window truncated', () async {
      _answerLikeAndroid([dinner(), ...copies(backfillQueryLimit)]);
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: PhotoManagerLibrary(isAndroid: true),
          clock: () => morning);
      final offered = <IntakePhoto>[];
      intake.photos.listen(offered.add);
      await expectLater(
          intake.backfillScan(), throwsA(isA<BackfillWindowTruncated>()));
      expect(offered, isEmpty, reason: 'no old copy is offered either');
    });

    test('the coverage check reports the window truncated, never fully '
        'covered', () async {
      _answerLikeAndroid([dinner(), ...copies(backfillQueryLimit)]);
      final report = await CoverageAuditor(
              library: PhotoManagerLibrary(isAndroid: true),
              dao: FakeDao(),
              hasher: (bytes) async => 'h${bytes.first}',
              clock: () => morning)
          .audit(lookbackDays: 2);
      expect(report.scanned, 0);
      expect(report.truncated, isTrue);
      expect(report.fullyCovered, isFalse);
    });

    test('a listing under the cap: the dinner photo is still found, and '
        'nothing is truncated', () async {
      // 1998 copies and the dinner: one short of the cap.
      _answerLikeAndroid([dinner(), ...copies(backfillQueryLimit - 2)]);
      final report = await CoverageAuditor(
              library: _ReadableLibrary(PhotoManagerLibrary(isAndroid: true)),
              dao: FakeDao(),
              hasher: (bytes) async => 'h${bytes.first}',
              clock: () => morning)
          .audit(lookbackDays: 2);
      expect(report.truncated, isFalse);
      expect(report.scanned, 1);
      expect(report.missing.map((i) => i.assetId), ['dinner']);
    });

    // The live watcher's own cap (500): a listing the copies fill must not
    // move its cutoff over a photo the cap hid, which it could then never
    // list again.
    test('the live watcher keeps its cutoff behind a photo the copies hid',
        () async {
      final rows = <_Row>[];
      _answerLikeAndroid(rows);
      final library = _ReadableLibrary(PhotoManagerLibrary(isAndroid: true));
      var clock = morning; // the app opens at 9:00
      final intake = LibraryPhotoIntake(
          lookbackDays: () => 2, library: library, clock: () => clock);
      final offered = <IntakePhoto>[];
      intake.photos.listen(offered.add);
      await intake.start();
      clock = morning.add(const Duration(minutes: 30));
      final copied = [
        for (var i = 0; i < 500; i++)
          _Row('old_$i',
              added: morning.add(Duration(minutes: 1, seconds: i)),
              taken: DateTime(2020, 5, 1).add(Duration(minutes: i))),
      ];
      rows.addAll([
        // Taken and added just after the app opened…
        _Row('breakfast',
            added: morning.add(const Duration(seconds: 31)),
            taken: morning.add(const Duration(seconds: 30))),
        // …then 500 old photos copied in, then a snack.
        ...copied,
        _Row('snack',
            added: morning.add(const Duration(minutes: 20, seconds: 1)),
            taken: morning.add(const Duration(minutes: 20))),
      ]);
      library.onChange!();
      await pumpEventQueue(times: 50);
      expect(offered.map((p) => p.assetId), ['snack'],
          reason: 'the cap hid breakfast behind the copies');
      // The copies go again (duplicates the user deletes): the listing is
      // no longer capped, and breakfast is still inside the cutoff.
      rows.removeWhere((r) => r.id.startsWith('old_'));
      library.onChange!();
      await pumpEventQueue(times: 50);
      expect(offered.map((p) => p.assetId), ['snack', 'breakfast']);
      await intake.stop();
    });
  });
}
