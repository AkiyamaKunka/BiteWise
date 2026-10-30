// The glasses dating guard (design G2b, 'Dating guard v2'): a Meta glasses
// photo whose creation date is only the time it was imported is dated by
// its EXIF shutter clock — and nothing else ever is. Every condition is
// pinned on its own: the evidence (addedDate, else the late-import pass),
// agreement within 2 min, the time-zone shape without an offset tag, the
// instants with one, the 45-day and +1 h window.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/capture_dating.dart';
import 'package:flutter_test/flutter_test.dart';

/// A glasses capture: created at [created] (the library's creationDate),
/// EXIF DateTimeOriginal [shutter] (wall clock) with [offset], and the
/// import-time evidence an intake found.
CaptureMeta glasses(
        {required DateTime created,
        required DateTime? shutter,
        Duration? offset,
        DateTime? added,
        DateTime? importPassAt,
        CaptureDevice device = CaptureDevice.metaGlasses}) =>
    CaptureMeta(
        device: device,
        strength: device == CaptureDevice.metaGlasses
            ? CaptureStrength.strong
            : CaptureStrength.none,
        signal: device == CaptureDevice.metaGlasses
            ? CaptureSignal.filename
            : null,
        exif: ExifCapture(
            make: 'Meta AI',
            model: 'Ray-Ban Meta Smart Glasses',
            dateTimeOriginal: shutter,
            subSec: '120',
            offsetTimeOriginal: offset),
        createDate: created,
        addedDate: added,
        importPassAt: importPassAt);

void main() {
  // Saturday 2026-10-24, 22:00 on the phone's clock: an import that night.
  final imported = DateTime(2026, 10, 24, 22, 0);
  final now = imported.add(const Duration(minutes: 5));
  // Lunch, 9 h 23 min earlier by the camera's wall clock: no zone is 9 h
  // 23 min away, so without an offset tag the difference is not a zone.
  final lunch = DateTime(2026, 10, 24, 12, 37);
  final addedThen = imported.add(const Duration(seconds: 40));

  DateTime? guard(CaptureMeta c) => glassesCapturedAt(c, now: now);

  group('import-time evidence', () {
    test('none: the creation date stands, however far the EXIF is', () {
      expect(guard(glasses(created: imported, shutter: lunch)), isNull);
      expect(glassesExifRedate(glasses(created: imported, shutter: lunch),
              now: now),
          lunch,
          reason: 'the watcher still learns the guard COULD apply, so it '
              'looks for the evidence');
    });

    test('addedDate within 2 min of the creation date: dated by the shutter',
        () {
      expect(
          guard(glasses(created: imported, shutter: lunch, added: addedThen)),
          lunch);
      expect(
          guard(glasses(
              created: imported,
              shutter: lunch,
              added: imported.subtract(const Duration(minutes: 2)))),
          lunch,
          reason: '2 min is still the same moment');
    });

    test('addedDate far from the creation date: PhotoKit dated it already',
        () {
      // What the simulator probe saw: creationDate = the EXIF instant,
      // addedDate = the import. Here createDate is 3 min off addedDate.
      expect(
          guard(glasses(
              created: imported,
              shutter: lunch,
              added: imported.add(const Duration(minutes: 3)))),
          isNull);
    });

    test('addedDate, when known, is the only evidence: the late-import pass '
        'does not override it', () {
      expect(
          guard(glasses(
              created: imported,
              shutter: lunch,
              added: imported.add(const Duration(hours: 1)),
              importPassAt: imported.add(const Duration(minutes: 1)))),
          isNull);
    });

    test('without addedDate: the late-import pass ran at most 10 min after '
        'the creation date', () {
      CaptureMeta at(Duration afterCreated) => glasses(
          created: imported,
          shutter: lunch,
          importPassAt: imported.add(afterCreated));
      expect(guard(at(const Duration(minutes: 5))), lunch);
      expect(guard(at(const Duration(minutes: 10))), lunch);
      expect(guard(at(const Duration(minutes: 11))), isNull,
          reason: 'carried from an earlier pass: no evidence of anything');
      expect(guard(at(const Duration(minutes: -1))), lunch,
          reason: 'a creation date a minute past the pass is clock jitter');
      expect(guard(at(const Duration(minutes: -3))), isNull);
    });
  });

  group('how far apart', () {
    test('a 90 s difference: the two agree, nothing to fix', () {
      expect(
          guard(glasses(
              created: imported,
              shutter: imported.subtract(const Duration(seconds: 90)),
              added: addedThen)),
          isNull);
    });

    test('a 5 h difference without an offset tag is a zone: kept', () {
      // A glasses clock in UTC, read on a phone in Chicago.
      expect(
          guard(glasses(
              created: imported,
              shutter: imported.subtract(const Duration(hours: 5)),
              added: addedThen)),
          isNull);
      expect(
          guard(glasses(
              created: imported,
              shutter: imported.add(const Duration(hours: 5, seconds: 100))
                  .subtract(const Duration(hours: 10)),
              added: addedThen)),
          isNull,
          reason: 'within 2 min of a quarter hour is still zone-shaped');
      expect(
          guard(glasses(
              created: imported,
              shutter: imported.subtract(const Duration(hours: 5, minutes: 3)),
              added: addedThen)),
          imported.subtract(const Duration(hours: 5, minutes: 3)),
          reason: '3 min off any zone: a real delay');
    });

    test('with OffsetTimeOriginal the two are compared as instants', () {
      // Lunch at 12:30 in Chicago (-05:00) = 17:30Z; imported 5 h later.
      final createdAt = DateTime.utc(2026, 10, 24, 22, 30).toLocal();
      final shutter = DateTime(2026, 10, 24, 12, 30);
      const cdt = Duration(hours: -5);
      final when = glassesCapturedAt(
          glasses(
              created: createdAt,
              shutter: shutter,
              offset: cdt,
              added: createdAt.add(const Duration(seconds: 30))),
          now: createdAt.add(const Duration(minutes: 1)));
      expect(when, shutter,
          reason: 'a whole 5 h between two instants is a real delay, and '
              'the meal keeps the clock it was eaten by');
      // The same instant: they agree, whatever the phone's zone.
      expect(
          glassesCapturedAt(
              glasses(
                  created: DateTime.utc(2026, 10, 24, 17, 31).toLocal(),
                  shutter: shutter,
                  offset: cdt,
                  added: DateTime.utc(2026, 10, 24, 17, 31).toLocal()),
              now: createdAt),
          isNull);
    });

    test('a difference wider than any two zones is never a zone', () {
      final twoDaysEarlier = imported.subtract(const Duration(days: 2));
      expect(
          guard(glasses(
              created: imported, shutter: twoDaysEarlier, added: addedThen)),
          twoDaysEarlier);
    });

    test('zoneShapedDifference', () {
      const cases = <(Duration, bool)>[
        (Duration.zero, false),
        (Duration(seconds: 90), false),
        (Duration(minutes: 13), true), // within 2 min of 15
        (Duration(minutes: 30), true),
        (Duration(minutes: 45, seconds: 120), true),
        (Duration(minutes: 45, seconds: 121), false),
        (Duration(hours: 5), true),
        (Duration(hours: -5), true),
        (Duration(hours: 9, minutes: 23), false),
        (Duration(hours: 26), true),
        (Duration(hours: 26, minutes: 15), false),
        (Duration(hours: 48), false),
      ];
      for (final (d, shaped) in cases) {
        expect(zoneShapedDifference(d), shaped, reason: '$d');
      }
    });
  });

  group('the EXIF time must be valid (45-day window, up to 1 h ahead)', () {
    CaptureMeta at(DateTime shutter) =>
        glasses(created: now, shutter: shutter, added: now);

    test('the 45-day bound', () {
      final inside = now.subtract(const Duration(days: 45, minutes: -7));
      expect(guard(at(inside)), inside);
      expect(
          guard(at(now.subtract(const Duration(days: 45, minutes: 1)))),
          isNull);
    });

    test('the +1 h bound', () {
      final ahead = now.add(const Duration(minutes: 50));
      expect(guard(at(ahead)), ahead);
      expect(guard(at(now.add(const Duration(minutes: 67)))), isNull);
    });

    test('with an offset tag the window applies to the instant', () {
      // 06:00 at +14:00 is 16:00Z the day before.
      final created = DateTime.utc(2026, 10, 24, 23).toLocal();
      final shutter = DateTime(2026, 9, 7, 6);
      expect(
          glassesCapturedAt(
              glasses(
                  created: created,
                  shutter: shutter,
                  offset: const Duration(hours: 14),
                  added: created),
              now: created),
          isNull,
          reason: 'older than 45 days as an instant');
    });
  });

  group('only Meta glasses photos', () {
    test('everything else is dated exactly as before, evidence or not', () {
      for (final c in [
        glasses(
            created: imported,
            shutter: lunch,
            added: addedThen,
            importPassAt: imported,
            device: CaptureDevice.unknown),
        CaptureMeta(
            exif: ExifCapture(make: 'Apple', dateTimeOriginal: lunch),
            createDate: imported,
            addedDate: addedThen,
            importPassAt: imported),
        const CaptureMeta(),
      ]) {
        expect(guard(c), isNull);
        expect(glassesExifRedate(c, now: now), isNull,
            reason: 'and the watcher looks for no evidence');
      }
      expect(glassesCapturedAt(null, now: now), isNull);
      expect(glassesExifRedate(null, now: now), isNull);
    });

    test('a glasses photo without a creation date or a shutter time', () {
      expect(guard(glasses(created: imported, shutter: null, added: addedThen)),
          isNull);
      final shared = CaptureMeta(
          device: CaptureDevice.metaGlasses,
          strength: CaptureStrength.medium,
          signal: CaptureSignal.exif,
          exif: ExifCapture(dateTimeOriginal: lunch, make: 'Meta AI'),
          importPassAt: imported);
      expect(guard(shared), isNull, reason: 'a shared file has no asset');
    });
  });

  test('createDateLooksImported reads only the evidence', () {
    expect(createDateLooksImported(const CaptureMeta()), isFalse);
    expect(
        createDateLooksImported(
            CaptureMeta(createDate: imported, addedDate: addedThen)),
        isTrue);
    expect(createDateLooksImported(CaptureMeta(createDate: imported)), isFalse);
    expect(
        createDateLooksImported(CaptureMeta(
            createDate: imported,
            importPassAt: imported.add(const Duration(minutes: 2)))),
        isTrue);
  });

  test('withImportEvidence keeps the reading and adds only the evidence', () {
    final base = glasses(created: imported, shutter: lunch);
    final more = base.withImportEvidence(addedDate: addedThen);
    expect(more.device, base.device);
    expect(more.strength, base.strength);
    expect(more.signal, base.signal);
    expect(more.exif, same(base.exif));
    expect(more.createDate, base.createDate);
    expect(more.addedDate, addedThen);
    expect(more.importPassAt, isNull);
    final both = more.withImportEvidence(importPassAt: imported);
    expect(both.addedDate, addedThen, reason: 'what it had is kept');
    expect(both.importPassAt, imported);
  });

  group('glassesImportLag (the Glasses check card)', () {
    Duration? lag(CaptureMeta c) => glassesImportLag(c, now: now);

    test('a creation date at the shutter: addedDate minus it', () {
      final shotAt = imported.subtract(const Duration(hours: 3));
      expect(
          lag(glasses(created: shotAt, shutter: shotAt, added: addedThen)),
          addedThen.difference(shotAt));
    });

    test('a creation date that is only the import time: measured from the '
        'EXIF shutter the meal is dated by, not 0 s', () {
      // Lunch 12:37 by the camera, imported 22:00, added 40 s later.
      expect(lag(glasses(created: imported, shutter: lunch, added: addedThen)),
          addedThen.difference(lunch));
      // With the zone tag: lunch at 12:30 in Chicago, imported 25 h later.
      final createdAt = DateTime.utc(2026, 10, 25, 18, 30).toLocal();
      expect(
          glassesImportLag(
              glasses(
                  created: createdAt,
                  shutter: DateTime(2026, 10, 24, 12, 30),
                  offset: const Duration(hours: -5),
                  added: createdAt.add(const Duration(seconds: 30))),
              now: createdAt.add(const Duration(minutes: 1))),
          const Duration(hours: 25, seconds: 30));
    });

    test('where the guard keeps the creation date, so does the lag', () {
      // A UTC glasses clock 5 h off: zone-shaped, createDate stands.
      expect(
          lag(glasses(
              created: imported,
              shutter: imported.subtract(const Duration(hours: 5)),
              added: addedThen)),
          const Duration(seconds: 40));
      // Not a glasses photo: never re-dated.
      expect(
          lag(glasses(
              created: imported,
              shutter: lunch,
              added: addedThen,
              device: CaptureDevice.unknown)),
          const Duration(seconds: 40));
    });

    test('no addedDate or no creation date: unknown', () {
      expect(lag(glasses(created: imported, shutter: lunch)), isNull);
      expect(glassesImportLag(null, now: now), isNull);
      expect(lag(CaptureMeta(addedDate: addedThen)), isNull);
    });
  });
}
