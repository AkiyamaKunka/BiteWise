/// The Glasses check record (design G3): one row per glasses photo, the
/// newest 20 of the last 14 days, in the backup-excluded store — and never
/// a coordinate.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/food_prefilter.dart';
import 'package:calorie_tracker/services/photo/glasses_check.dart';

void main() {
  final now = DateTime(2026, 10, 24, 13);
  final created = DateTime(2026, 10, 24, 12, 10);

  IntakePhoto photo(String id, {CaptureMeta? capture}) => IntakePhoto(
      Uint8List.fromList([1]), id, 'photo-${id}_singular_display.HEIC',
      capture: capture ??
          CaptureMeta(
              device: CaptureDevice.metaGlasses,
              strength: CaptureStrength.strong,
              signal: CaptureSignal.album,
              exif: ExifCapture(
                  make: 'Meta AI',
                  model: 'Ray-Ban Meta Smart Glasses 2',
                  gpsPresent: true,
                  gpsFixUtc: created.toUtc().add(const Duration(seconds: 20))),
              createDate: created,
              addedDate: created.add(const Duration(minutes: 32))));

  group('GlassesCheckEntry.of', () {
    test('what the card shows, from the photo and its check', () {
      final e = GlassesCheckEntry.of(photo('g1'),
          outcome: GlassesCheckOutcome.logged,
          check: const FoodCheck(FoodCheckStatus.ok, score: 0.63),
          at: now);
      expect(e.assetId, 'g1');
      expect(e.at, now);
      expect(e.outcome, 'logged');
      expect(e.signal, 'album');
      expect(e.make, 'Meta AI');
      expect(e.model, 'Ray-Ban Meta Smart Glasses 2');
      expect(e.lagSeconds, 32 * 60);
      expect(e.hasGps, isTrue);
      expect(e.gpsFixDeltaSeconds, 20);
      expect(e.foodScore, 0.63);
    });

    test('a check that did not answer leaves the score blank; unknown '
        'facts stay unknown', () {
      final bare = IntakePhoto(Uint8List(1), 'x', 'x.jpg',
          capture: const CaptureMeta(device: CaptureDevice.metaGlasses));
      for (final check in [
        null,
        FoodCheck.error,
        const FoodCheck(FoodCheckStatus.deferredGpu),
      ]) {
        final e = GlassesCheckEntry.of(bare,
            outcome: GlassesCheckOutcome.appWait, check: check, at: now);
        expect(e.foodScore, isNull);
        expect(e.lagSeconds, isNull);
        expect(e.gpsFixDeltaSeconds, isNull);
        expect(e.hasGps, isFalse);
        expect(e.make, isNull);
        expect(e.signal, isNull);
      }
    });

    test('camera text is shortened and stripped of control characters', () {
      final e = GlassesCheckEntry.of(
          photo('g1',
              capture: CaptureMeta(
                  device: CaptureDevice.metaGlasses,
                  exif: ExifCapture(make: 'Meta\nAI\u0000', model: 'x' * 200))),
          outcome: GlassesCheckOutcome.logged,
          at: now);
      expect(e.make, 'Meta AI');
      expect(e.model, hasLength(glassesCheckMaxText));
    });

    test('a photo whose creation date is only its import time: the lag '
        'runs from the EXIF shutter, not 0 s', () {
      // Shot at lunch yesterday (-05:00), imported 25 h later with
      // creationDate = the import (the case the dating guard re-dates).
      final importedAt = DateTime.utc(2026, 10, 24, 17, 30).toLocal();
      final e = GlassesCheckEntry.of(
          photo('g1',
              capture: CaptureMeta(
                  device: CaptureDevice.metaGlasses,
                  strength: CaptureStrength.strong,
                  signal: CaptureSignal.filename,
                  exif: ExifCapture(
                      make: 'Meta AI',
                      model: 'Ray-Ban Meta Smart Glasses',
                      dateTimeOriginal: DateTime(2026, 10, 23, 11, 30),
                      offsetTimeOriginal: const Duration(hours: -5)),
                  createDate: importedAt,
                  addedDate: importedAt.add(const Duration(seconds: 20)))),
          outcome: GlassesCheckOutcome.logged,
          at: importedAt.add(const Duration(minutes: 1)));
      expect(e.lagSeconds, 25 * 3600 + 20);
    });

    test('a broken clock gives no lag rather than a silly one', () {
      final e = GlassesCheckEntry.of(
          photo('g1',
              capture: CaptureMeta(
                  device: CaptureDevice.metaGlasses,
                  createDate: DateTime(1970),
                  addedDate: now)),
          outcome: GlassesCheckOutcome.logged,
          at: now);
      expect(e.lagSeconds, isNull);
    });
  });

  group('the stored row', () {
    test('round-trips, and holds no coordinate', () {
      final e = GlassesCheckEntry.of(photo('g1'),
          outcome: GlassesCheckOutcome.notFood,
          check: const FoodCheck(FoodCheckStatus.ok, score: 0.04),
          at: now);
      final json = e.toJson();
      final back = GlassesCheckEntry.fromJson(jsonDecode(jsonEncode(json)))!;
      expect(back.toJson(), json);
      expect(back.at, now);
      for (final key in json.keys) {
        expect(key, isNot(matches(RegExp(r'lat|lon|lng|coord|place|addr'))),
            reason: 'no position-shaped field');
      }
    });

    test('anything else is not a row', () {
      final good = GlassesCheckEntry.of(photo('g1'),
              outcome: GlassesCheckOutcome.logged, at: now)
          .toJson();
      for (final raw in <Object?>[
        null,
        'row',
        {...good, 'outcome': 'teleported'},
        {...good, 'at': 'yesterday'},
        {...good, 'asset': 7},
        Map.of(good)..remove('outcome'),
      ]) {
        expect(GlassesCheckEntry.fromJson(raw), isNull, reason: '$raw');
      }
      final odd = GlassesCheckEntry.fromJson(
          {...good, 'food': 7, 'lag_s': '5', 'gps': 'yes'})!;
      expect(odd.foodScore, isNull);
      expect(odd.lagSeconds, isNull);
      expect(odd.hasGps, isFalse);
    });
  });

  group('recordGlassesCheck / readGlassesChecks', () {
    late Directory root;
    late LocalNoBackupStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('glasses_check');
      store = LocalNoBackupStore(
          root: () async => root, createMissingDirectory: true);
    });
    tearDown(() => root.deleteSync(recursive: true));

    GlassesCheckEntry row(String id, DateTime at, String outcome) =>
        GlassesCheckEntry(assetId: id, at: at, outcome: outcome);

    test('newest first; a later verdict replaces the same photo\'s row',
        () async {
      await recordGlassesCheck(
          store, row('a', now.subtract(const Duration(hours: 2)), 'app_wait'),
          now: now);
      await recordGlassesCheck(
          store, row('b', now.subtract(const Duration(hours: 1)), 'logged'),
          now: now);
      await recordGlassesCheck(store, row('a', now, 'logged'), now: now);
      final rows = await readGlassesChecks(store: store, now: now);
      expect([for (final r in rows) (r.assetId, r.outcome)],
          [('a', 'logged'), ('b', 'logged')]);
    });

    test('a later verdict that does not know the import lag (a deliberate '
        're-add) keeps the one the earlier row knew', () async {
      GlassesCheckEntry withLag(String id, DateTime at, String outcome,
              int? lag) =>
          GlassesCheckEntry(
              assetId: id, at: at, outcome: outcome, lagSeconds: lag);
      final earlier = now.subtract(const Duration(hours: 1));
      await recordGlassesCheck(
          store, withLag('a', earlier, 'not_food', 25 * 3600),
          now: now);
      await recordGlassesCheck(store, withLag('a', now, 'logged', null),
          now: now);
      var rows = await readGlassesChecks(store: store, now: now);
      expect([for (final r in rows) (r.outcome, r.lagSeconds)],
          [('logged', 25 * 3600)]);
      // A lag the new verdict knows is the one kept.
      await recordGlassesCheck(store, withLag('a', now, 'logged', 90),
          now: now);
      rows = await readGlassesChecks(store: store, now: now);
      expect(rows.single.lagSeconds, 90);
      // Another photo's lag never carries over, nor a shared file's.
      await recordGlassesCheck(store, withLag('b', now, 'logged', null),
          now: now);
      await recordGlassesCheck(store, withLag('', earlier, 'logged', 60),
          now: now);
      await recordGlassesCheck(store, withLag('', now, 'logged', null),
          now: now);
      rows = await readGlassesChecks(store: store, now: now);
      expect({for (final r in rows) (r.assetId, r.lagSeconds)},
          {('a', 90), ('b', null), ('', 60), ('', null)});
    });

    test('the newest 20 of the last 14 days', () async {
      for (var i = 0; i < 25; i++) {
        await recordGlassesCheck(
            store, row('p$i', now.subtract(Duration(minutes: 25 - i)), 'logged'),
            now: now);
      }
      await recordGlassesCheck(
          store,
          row('old', now.subtract(glassesCheckWindow + const Duration(hours: 1)),
              'logged'),
          now: now);
      final rows = await readGlassesChecks(store: store, now: now);
      expect(rows, hasLength(glassesCheckKept));
      expect(rows.first.assetId, 'p24');
      expect(rows.last.assetId, 'p5');
      expect(rows.any((r) => r.assetId == 'old'), isFalse);
      // A row ages out on read too.
      final later = await readGlassesChecks(
          store: store, now: now.add(glassesCheckWindow));
      expect(later, isEmpty);
    });

    test('shared files (no asset id) never replace each other', () async {
      await recordGlassesCheck(store, row('', now, 'logged'), now: now);
      await recordGlassesCheck(store, row('', now, 'not_food_ai'), now: now);
      expect(await readGlassesChecks(store: store, now: now), hasLength(2));
    });

    test('a store that cannot be written or read never throws', () async {
      final broken = LocalNoBackupStore(
          root: () async => throw const FileSystemException('gone'),
          createMissingDirectory: true);
      await recordGlassesCheck(broken, row('a', now, 'logged'), now: now);
      expect(await readGlassesChecks(store: broken, now: now), isEmpty);
    });

    test('the document is the backup-excluded one', () async {
      await recordGlassesCheck(store, row('a', now, 'logged'), now: now);
      expect(File('${root.path}/$localStoreDirName/$glassesCheckDocument.json')
          .existsSync(), isTrue);
    });
  });
}
