// iCloud Backup's decisions (1.7.0), against real SQLite and an in-memory
// iCloud folder with the Swift owner rule (test/support/
// fake_cloud_transport.dart): the guards G1–G10, the restore offer, the
// takeover, combine, delete, and what the background run may not do.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/backup/backup_coordinator.dart';
import 'package:calorie_tracker/services/backup/backup_files.dart';
import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:calorie_tracker/services/backup/backup_prefs.dart';
import 'package:calorie_tracker/services/backup/cloud_backup_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/fake_cloud_transport.dart';

const _other = 'fedcba9876543210fedcba9876543210';
const _third = 'abcdefabcdefabcdefabcdefabcdefab';

Uint8List _jpeg(int tag) => Uint8List.fromList(
    [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, tag, tag, 0xFF, 0xC0, 0x00, 0x04, 1, 1,
     0xFF, 0xDA, 0x00, 0x04, 0, 0, 1, 2, 3, 0xFF, 0xD9]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db, otherDb;
  late SqfliteMealsDao dao, otherDao;
  late FakeCloudTransport cloud;
  late SharedPreferences prefs;
  late DateTime now;
  late BackupCoordinator c;
  var imported = 0;

  BackupCoordinator make({bool ui = true}) => BackupCoordinator(
        dao: dao,
        transport: cloud,
        prefs: prefs,
        tempDir: () async => tmp,
        uiEngine: ui,
        clock: () => now,
        onDataImported: () => imported++,
        gatherWait: Duration.zero,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_backup_coord');
    db = await openAppDatabase(path: '${tmp.path}/me.db');
    otherDb = await openAppDatabase(path: '${tmp.path}/other.db');
    now = DateTime.utc(2026, 11, 11, 9);
    dao = SqfliteMealsDao(db, clock: () => now);
    otherDao = SqfliteMealsDao(otherDb, clock: () => now);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    cloud = FakeCloudTransport();
    imported = 0;
    c = make();
  });
  tearDown(() async {
    await c.stop();
    await db.close();
    await otherDb.close();
    await tmp.delete(recursive: true);
  });

  Future<int> seed(SqfliteMealsDao d, String date, {String hash = ''}) =>
      d.saveMeal(
          Meal(
            id: 0,
            date: date,
            time: '12:00 PM',
            timestamp: '${date}T12:00:00.${hash.isEmpty ? date.hashCode % 1000 : 0}',
            source: hash.isEmpty ? MealSource.manualText : MealSource.appWatch,
            imageHash: hash,
            analysis: {'is_food': true, 'total_calories': 300, 'meal_description': date},
          ),
          markStatus: hash.isEmpty ? null : IngestionStatus.saved);

  /// The notice answered Keep On (as answerNotice stores it, without the
  /// run it starts) and G4's 24 h passed.
  Future<void> noticeAnswered() async {
    await prefs.setBool(BackupPrefs.kNoticeSeen, true);
    await prefs.setBool(BackupPrefs.kEnabled, true);
  }

  Future<void> ready() async {
    await noticeAnswered();
    await prefs.setString(BackupPrefs.kFirstEmptyAt,
        now.subtract(const Duration(days: 2)).toIso8601String());
  }

  Future<BackupState> run({bool background = false}) =>
      c.runForTest(background: background);

  /// Another phone's backup, written by the real writer into the folder.
  Future<void> otherPhoneBackup({int meals = 3, String path = kRecordsFileName,
      bool withPictures = true}) async {
    for (var i = 0; i < meals; i++) {
      final id = await seed(otherDao, '2026-10-${(i + 1).toString().padLeft(2, '0')}',
          hash: 'o$i');
      if (withPictures) await otherDao.saveMealThumb(id, _jpeg(i));
    }
    final w = BackupFileWriter(dao: otherDao, platform: 'ios', clock: () => now);
    final prints = await otherDao.thumbMonthPrints();
    final f = await w.writeRecords('${tmp.path}/o.json',
        installId: _other,
        seq: 5,
        months: {for (final e in prints.entries) e.key: e.value.count});
    cloud.files[path] = await File(f.path).readAsBytes();
    for (final m in prints.keys) {
      final p = await w.writePictures('${tmp.path}/o-$m.json',
          installId: _other, seq: 5, month: m);
      cloud.files[picturesPath(m)] = await File(p.path).readAsBytes();
    }
  }

  /// The photo hashes a month's pictures file holds, in file order.
  List<String> hashesIn(String month) {
    final b = cloud.files[picturesPath(month)];
    if (b == null) return const [];
    final j = jsonDecode(utf8.decode(b)) as Map;
    return [
      for (final r in (j['tables'] as Map)['meal_thumbs'] as List)
        (r as Map)['image_hash'] as String
    ];
  }

  /// This phone's own photo meal with a picture, dated in October.
  Future<void> myOctoberPicture() async {
    final mine = await seed(dao, '2026-10-15', hash: 'mine');
    await dao.saveMealThumb(mine, _jpeg(7));
  }

  /// The other phone, still in use, backs up again (seq 6): a November
  /// photo meal, so its backup now has a month it did not have.
  Future<void> otherPhoneAddsNovember() async {
    final nov = await seed(otherDao, '2026-11-03', hash: 'o-nov');
    await otherDao.saveMealThumb(nov, _jpeg(4));
    final w = BackupFileWriter(dao: otherDao, platform: 'ios', clock: () => now);
    final prints = await otherDao.thumbMonthPrints();
    final f = await w.writeRecords('${tmp.path}/o6.json',
        installId: _other,
        seq: 6,
        months: {for (final e in prints.entries) e.key: e.value.count});
    cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();
    final p = await w.writePictures('${tmp.path}/o6-nov.json',
        installId: _other, seq: 6, month: '2026-11');
    cloud.files[picturesPath('2026-11')] = await File(p.path).readAsBytes();
  }

  group('G1: nothing uploads before the notice', () {
    test('the default is on, but the notice comes first', () async {
      await seed(dao, '2026-11-10');
      expect(c.status.value.state, BackupState.needsNotice);
      expect(await run(), BackupState.needsNotice);
      expect(cloud.files, isEmpty);
    });

    test('Turn Off on the notice turns it off and never asks again',
        () async {
      await c.answerNotice(keepOn: false);
      expect(c.status.value.state, BackupState.off);
      expect(prefs.getBool(BackupPrefs.kNoticeSeen), isTrue);
      expect(await run(), BackupState.off);
    });
  });

  group('G4: the first write', () {
    test('waits for 60 s of live query and 24 h after the folder was first '
        'seen empty', () async {
      await seed(dao, '2026-11-10');
      await noticeAnswered();
      cloud.live = const Duration(seconds: 30);
      expect(await run(), BackupState.never);
      expect(cloud.files, isEmpty);
      cloud.live = const Duration(minutes: 2);
      expect(await run(), BackupState.never, reason: 'first seen empty now');
      expect(prefs.getString(BackupPrefs.kFirstEmptyAt), isNotNull);
      now = now.add(const Duration(hours: 23));
      expect(await run(), BackupState.never);
      now = now.add(const Duration(hours: 2));
      expect(await run(), BackupState.uploading);
      expect(cloud.headerOf(kRecordsFileName)!.seq, 1);
    });

    test('Back Up Now skips the 24 h, not the query', () async {
      await seed(dao, '2026-11-10');
      await noticeAnswered();
      cloud.gathered = false;
      expect(await c.backUpNow(), BackupState.never);
      cloud.gathered = true;
      expect(await c.backUpNow(), BackupState.uploading);
    });

    test('Back Up Now in the query\'s first minute waits the rest of it out '
        '(Checking iCloud…) rather than doing nothing', () async {
      final query = _QueryWarmingUp(
          () => now = now.add(const Duration(seconds: 10)))
        ..watching = true
        ..live = const Duration(seconds: 30);
      cloud = query;
      c = BackupCoordinator(
          dao: dao,
          transport: cloud,
          prefs: prefs,
          tempDir: () async => tmp,
          clock: () => now,
          gatherWait: const Duration(seconds: 90),
          gatherPoll: Duration.zero);
      await seed(dao, '2026-11-10');
      await noticeAnswered();
      var busySeen = false;
      c.status.addListener(() => busySeen |= c.status.value.busy);
      expect(await c.backUpNow(), BackupState.uploading);
      expect(busySeen, isTrue, reason: 'the line said Checking iCloud…');
      expect(c.status.value.busy, isFalse);
      expect(cloud.headerOf(kRecordsFileName)!.seq, 1);
      // A query that never gathers is waited for 90 s at most.
      await prefs.clear();
      await noticeAnswered();
      cloud.files.clear();
      query.gathered = false;
      final start = now;
      expect(await c.backUpNow(), BackupState.never);
      expect(now.difference(start), lessThan(const Duration(seconds: 120)));
      expect(c.status.value.busy, isFalse);
    });

    test('G8: a background run never writes first', () async {
      await seed(dao, '2026-11-10');
      await ready();
      expect(await run(background: true), BackupState.never);
      expect(make(ui: false).runForTest(background: true),
          completion(isNot(BackupState.uploading)));
      expect(cloud.files, isEmpty);
    });

    test('another phone\'s unanswered backup blocks it', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await otherPhoneBackup(path: 'Chopstats Backup 2.json');
      expect(await run(), BackupState.never);
      expect(cloud.files.containsKey(kRecordsFileName), isFalse);
    });
  });

  group('after the first write', () {
    test('records and a file per month of pictures, owned by this install',
        () async {
      final oct = await seed(dao, '2026-10-03', hash: 'h1');
      final nov = await seed(dao, '2026-11-02', hash: 'h2');
      await dao.saveMealThumb(oct, _jpeg(1));
      await dao.saveMealThumb(nov, _jpeg(2));
      await ready();
      expect(await run(), BackupState.uploading);
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      expect(isValidInstallId(me), isTrue);
      final h = cloud.headerOf(kRecordsFileName)!;
      expect(h.installId, me);
      expect(h.meals, 2);
      expect(h.months, {'2026-10': 1, '2026-11': 1});
      expect(cloud.headerOf(picturesPath('2026-10'))!.installId, me);
      expect(cloud.headerOf(picturesPath('2026-11'))!.thumbs, 1);
      // Nothing changed: nothing written (G6).
      cloud.log.clear();
      expect(await run(), isNot(BackupState.failed));
      expect(cloud.log, isEmpty);
      // A change rewrites the records only; the months are unchanged.
      await dao.saveBodyWeight('2026-11-10', 70);
      await run();
      expect(cloud.log, ['write $kRecordsFileName']);
      expect(cloud.headerOf(kRecordsFileName)!.seq, 2);
    });

    test('the previous copy is rotated at most once a day', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      await seed(dao, '2026-11-11');
      await run();
      expect(cloud.files.containsKey(kPreviousFileName), isFalse,
          reason: 'the first write of the day was the first ever');
      now = now.add(const Duration(days: 1));
      await seed(dao, '2026-11-12');
      await run();
      expect(cloud.headerOf(kPreviousFileName)!.seq, 2);
      await seed(dao, '2026-11-13');
      await run();
      expect(cloud.headerOf(kPreviousFileName)!.seq, 2, reason: 'same day');
      expect(cloud.headerOf(kRecordsFileName)!.seq, 4);
    });

    test('a month with no pictures left is deleted', () async {
      final oct = await seed(dao, '2026-10-03', hash: 'h1');
      await dao.saveMealThumb(oct, _jpeg(1));
      await seed(dao, '2026-11-02');
      await ready();
      await run();
      expect(cloud.files.containsKey(picturesPath('2026-10')), isTrue);
      await dao.deleteMeal(oct);
      await run();
      expect(cloud.files.containsKey(picturesPath('2026-10')), isFalse);
      expect(cloud.headerOf(kRecordsFileName)!.months, isEmpty);
    });

    test('a picture whose meal date names no month is counted as skipped '
        'and never keeps the backup changed', () async {
      final oct = await seed(dao, '2026-10-03', hash: 'h1');
      await dao.saveMealThumb(oct, _jpeg(1));
      final slash = await seed(dao, '2026/10/05', hash: 'odd1');
      await dao.saveMealThumb(slash, _jpeg(2));
      final short = await seed(dao, '2026-1-05', hash: 'odd2');
      await dao.saveMealThumb(short, _jpeg(3));
      await ready();
      expect(await run(), BackupState.uploading);
      final h = cloud.headerOf(kRecordsFileName)!;
      expect(h.months, {'2026-10': 1});
      expect(h.thumbsSkipped, 2);
      expect(cloud.files.keys,
          unorderedEquals([kRecordsFileName, picturesPath('2026-10')]));
      expect(BackupPrefs(prefs).months.keys, ['2026-10']);
      // Nothing changed: nothing written, run after run (G6).
      cloud.log.clear();
      await run();
      await run();
      expect(cloud.log, isEmpty);
    });

    test('a write that landed before the app was killed is still ours',
        () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run(); // seq 1
      // seq 2 landed, but the app died before it recorded it.
      await prefs.setInt(BackupPrefs.kPendingSeq, 2);
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      final w = BackupFileWriter(dao: dao, platform: 'ios', clock: () => now);
      final f = await w.writeRecords('${tmp.path}/s2.json',
          installId: me, seq: 2, months: const {});
      cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.uploading);
      expect(cloud.headerOf(kRecordsFileName)!.seq, 3);
    });

    test('a write that landed unrecorded, then a run that failed after '
        'taking the next seq: the file is still ours', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run(); // seq 1
      // seq 2 landed, but the app died before it recorded it.
      await prefs.setInt(BackupPrefs.kPendingSeq, 2);
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      final w = BackupFileWriter(dao: dao, platform: 'ios', clock: () => now);
      final f = await w.writeRecords('${tmp.path}/s2.json',
          installId: me, seq: 2, months: const {});
      cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();
      // The next run takes seq 3, and iCloud goes away before it lands.
      await seed(dao, '2026-11-11');
      cloud.onWrite = (_) async => cloud.state = CloudState.unavailable;
      expect(await run(), BackupState.unavailable);
      cloud.onWrite = null;
      cloud.state = CloudState.ok;
      expect(cloud.headerOf(kRecordsFileName)!.seq, 2);
      expect(await run(), BackupState.uploading);
      expect(cloud.headerOf(kRecordsFileName)!.seq, greaterThan(2));
      expect(prefs.getInt(BackupPrefs.kLastSeq),
          cloud.headerOf(kRecordsFileName)!.seq);
    });

    test('a pictures file that cannot be written ends the run as failed, '
        'like the records file', () async {
      final oct = await seed(dao, '2026-10-03', hash: 'h1');
      await dao.saveMealThumb(oct, _jpeg(1));
      await ready();
      BackupCoordinator other(MealsDao d, Future<Directory> Function() dir) =>
          BackupCoordinator(
              dao: d,
              transport: cloud,
              prefs: prefs,
              tempDir: dir,
              clock: () => now,
              gatherWait: Duration.zero);
      // The month's pictures cannot be read.
      final noThumbs = other(_ThumbsFailDao(db, clock: () => now),
          () async => tmp);
      expect(await noThumbs.backUpNow(), BackupState.failed);
      expect(noThumbs.status.value.state, BackupState.failed);
      expect(prefs.getString(BackupPrefs.kLastError), 'failed');
      // The temporary file cannot be made (here: its folder is a file).
      final blocked = File('${tmp.path}/blocked')..writeAsStringSync('x');
      final noTemp = other(dao, () async => Directory(blocked.path));
      expect(await noTemp.backUpNow(), BackupState.failed);
      // The temporary file cannot be opened (a folder is in its place): no
      // error escapes the run either, not even one nobody awaits.
      final inTheWay =
          Directory('${tmp.path}/icloud_backup/pictures-2026-10.json')
            ..createSync(recursive: true);
      expect(await c.backUpNow(), BackupState.failed);
      inTheWay.deleteSync();
      expect(cloud.log, isEmpty);
      // Nothing was left half done: the next run writes it all.
      expect(await c.backUpNow(), BackupState.uploading);
      expect(hashesIn('2026-10'), ['h1']);
    });
  });

  group('G3: another install\'s file is never replaced', () {
    test('a different install: otherDevice, untouched', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run(); // ours
      await otherPhoneBackup(); // replaced in the folder by another phone
      final before = cloud.files[kRecordsFileName];
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.otherDevice);
      expect(c.status.value.other!.installId, _other);
      expect(cloud.files[kRecordsFileName], before);
    });

    test('our id at a seq we never wrote: changedElsewhere', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      final w = BackupFileWriter(dao: dao, platform: 'ios', clock: () => now);
      final f = await w.writeRecords('${tmp.path}/x.json',
          installId: me, seq: 40, months: const {});
      cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.changedElsewhere);
      expect(cloud.headerOf(kRecordsFileName)!.seq, 40);
    });

    test('a file whose header cannot be read: unknownFile', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      cloud.put(kRecordsFileName, 'my notes');
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.unknownFile);
      expect(String.fromCharCodes(cloud.files[kRecordsFileName]!), 'my notes');
    });
  });

  group('G3 before the months', () {
    test('a phone that does not own the records file creates no month '
        'file, on its first write too', () async {
      await otherPhoneBackup(meals: 2); // the other phone owns the backup
      final nov = await seed(dao, '2026-11-05', hash: 'b-nov');
      await dao.saveMealThumb(nov, _jpeg(3));
      await ready();
      await prefs.setStringList(BackupPrefs.kOffersAnswered, [_other]);
      cloud.log.clear();
      expect(await run(), BackupState.otherDevice);
      expect(cloud.files.containsKey(picturesPath('2026-11')), isFalse);
      expect(cloud.log, isEmpty);
    });

    test('another install\'s month is skipped and said so, then written '
        'once its file is gone', () async {
      final oct = await seed(dao, '2026-10-03', hash: 'a-oct');
      await dao.saveMealThumb(oct, _jpeg(1));
      await ready();
      expect(await run(), BackupState.uploading);
      // Another install created November (before this fix, the first-write
      // path of a phone that answered Not Now did).
      final w =
          BackupFileWriter(dao: otherDao, platform: 'ios', clock: () => now);
      final bnov = await seed(otherDao, '2026-11-01', hash: 'b-nov');
      await otherDao.saveMealThumb(bnov, _jpeg(2));
      final f = await w.writePictures('${tmp.path}/b.json',
          installId: _other, seq: 1, month: '2026-11');
      cloud.files[picturesPath('2026-11')] = await File(f.path).readAsBytes();
      final nov = await seed(dao, '2026-11-05', hash: 'a-nov');
      await dao.saveMealThumb(nov, _jpeg(3));
      expect(await c.backUpNow(), BackupState.uploading);
      expect(hashesIn('2026-11'), ['b-nov']);
      expect(c.status.value.skippedMonths, 1);
      // The other install's file goes (Start Fresh or Delete over there).
      cloud.files.remove(picturesPath('2026-11'));
      final nov2 = await seed(dao, '2026-11-06', hash: 'a-nov2');
      await dao.saveMealThumb(nov2, _jpeg(4));
      expect(await c.backUpNow(), BackupState.uploading);
      expect(hashesIn('2026-11'), ['a-nov', 'a-nov2']);
      expect(c.status.value.skippedMonths, 0);
      expect(BackupPrefs(prefs).months['2026-11']!.state, MonthState.written);
    });

    test('the background never looks at another install\'s month again',
        () async {
      final oct = await seed(dao, '2026-10-03', hash: 'a-oct');
      await dao.saveMealThumb(oct, _jpeg(1));
      await ready();
      await run();
      final months = BackupPrefs(prefs).months
        ..['2026-11'] = const MonthRecord(MonthState.foreign);
      await BackupPrefs(prefs).setMonths(months);
      final nov = await seed(dao, '2026-11-05', hash: 'a-nov');
      await dao.saveMealThumb(nov, _jpeg(3));
      cloud.log.clear();
      expect(await run(background: true), BackupState.uploading);
      expect(cloud.log, ['write $kRecordsFileName']);
    });
  });

  test('G5: a much smaller record pauses until Back Up Anyway', () async {
    for (var i = 1; i <= 24; i++) {
      await seed(dao, '2026-10-${i.toString().padLeft(2, '0')}');
    }
    await ready();
    await run();
    expect(cloud.headerOf(kRecordsFileName)!.meals, 24);
    final all = await dao.mealsBetween('2026-10-01', '2026-10-31');
    for (final m in all.skip(5)) {
      await dao.deleteMeal(m.id);
    }
    expect(await run(), BackupState.shrink);
    expect(c.status.value.count, 24);
    expect(cloud.headerOf(kRecordsFileName)!.meals, 24);
    expect(await run(), BackupState.shrink, reason: 'paused');
    expect(await c.backUpAnyway(), BackupState.uploading);
    expect(cloud.headerOf(kRecordsFileName)!.meals, 5);
  });

  test('G9: a file this install wrote that is gone pauses until Back Up '
      'Again', () async {
    await seed(dao, '2026-11-10');
    await ready();
    await run();
    cloud.files.remove(kRecordsFileName);
    await seed(dao, '2026-11-11');
    expect(await run(), BackupState.missing);
    expect(cloud.files, isEmpty);
    expect(await run(), BackupState.missing);
    expect(await c.backUpAgain(), BackupState.uploading);
    expect(cloud.headerOf(kRecordsFileName)!.meals, 2);
  });

  test('G10: an empty log on the owner phone writes nothing', () async {
    final id = await seed(dao, '2026-11-10');
    await ready();
    await run();
    final before = cloud.files[kRecordsFileName];
    await dao.deleteMeal(id);
    expect(await run(), BackupState.emptyLog);
    expect(c.status.value.count, 1);
    expect(cloud.files[kRecordsFileName], before);
  });

  group('G7: identity', () {
    test('no vendor id yet: the run is skipped, never read as another phone',
        () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      final me = prefs.getString(BackupPrefs.kInstallId);
      cloud.device = null;
      await seed(dao, '2026-11-11');
      cloud.log.clear();
      await run();
      expect(cloud.log, isEmpty);
      expect(prefs.getString(BackupPrefs.kInstallId), me);
    });

    test('another phone set up from this one\'s device backup is a new '
        'install, and the old file is not overwritten', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      final old = prefs.getString(BackupPrefs.kInstallId);
      cloud.device = 'device-key-2';
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.never,
          reason: 'a new install starts with G4 (the old file is offered)');
      expect(prefs.getString(BackupPrefs.kInstallId), isNot(old));
      expect(prefs.getBool(BackupPrefs.kNoticeSeen), isTrue);
      expect(cloud.headerOf(kRecordsFileName)!.installId, old);
    });

    test('another iCloud account asks the notice again and keeps the id',
        () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      final me = prefs.getString(BackupPrefs.kInstallId);
      cloud.accountChangedOnce = true;
      expect(await run(), BackupState.needsNotice);
      expect(prefs.getString(BackupPrefs.kInstallId), me);
      expect(prefs.getInt(BackupPrefs.kLastSeq), isNull);
    });

    test('signed in to another account and back: this install\'s own file '
        'is still its own', () async {
      await seed(dao, '2026-11-10');
      await ready();
      expect(await run(), BackupState.uploading); // seq 1 in account A
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.uploading); // seq 2
      final inA = Map.of(cloud.files);
      // Account B: its own (empty) folder, the notice again, a backup.
      cloud.accountChangedOnce = true;
      expect(await run(), BackupState.needsNotice);
      cloud.files.clear();
      await noticeAnswered();
      await seed(dao, '2026-11-12');
      expect(await c.backUpNow(), BackupState.uploading);
      // Back to account A, whose file this install wrote at seq 2.
      cloud.accountChangedOnce = true;
      expect(await run(), BackupState.needsNotice);
      cloud.files
        ..clear()
        ..addAll(inA);
      await noticeAnswered();
      await seed(dao, '2026-11-13');
      expect(await c.backUpNow(), BackupState.uploading);
      final seq = cloud.headerOf(kRecordsFileName)!.seq;
      expect(seq, greaterThan(3), reason: 'a seq is never taken twice');
      await seed(dao, '2026-11-14');
      expect(await run(), BackupState.uploading);
      expect(cloud.headerOf(kRecordsFileName)!.seq, seq + 1);
    });

    test('no account / unavailable', () async {
      await seed(dao, '2026-11-10');
      await ready();
      cloud.state = CloudState.noAccount;
      expect(await run(), BackupState.noAccount);
      cloud.state = CloudState.unavailable;
      expect(await run(), BackupState.unavailable);
    });
  });

  group('the launch', () {
    /// Real SQLite answers from another isolate: wait for [done].
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('asks iCloud for its status before the metadata query starts, '
        'then offers the backup', () async {
      await otherPhoneBackup();
      await c.start();
      await until(() => c.prompt.value != null);
      expect(cloud.calls.take(2), ['status', 'startWatching'],
          reason: 'in iOS a query started before the container was fetched '
              'can gather an empty folder: no offer, and G4 says "no backup"');
      expect(cloud.watching, isTrue);
      expect(c.prompt.value, isA<RestoreOfferPrompt>());
    });

    test('starts the metadata query whatever the status says', () async {
      cloud.state = CloudState.noAccount;
      await c.start();
      await until(() => cloud.watching);
      expect(cloud.calls, ['status', 'startWatching']);
      expect(c.status.value.state, BackupState.noAccount);
    });
  });

  group('the photo catch-up and the look for a backup to offer', () {
    Meal lunch(num kcal) => Meal(
        id: 0,
        date: '2026-11-11',
        time: '12:00 PM',
        timestamp: '2026-11-11T12:00:00.000',
        source: MealSource.appWatch,
        imageHash: 'h_lunch',
        analysis: {'is_food': true, 'total_calories': kcal});

    test('asked at init, before the shell starts the launch\'s look, it '
        'answers once the look decided: the offer holds it, and the '
        'backup\'s corrected meal is what the restore brings', () async {
      // The old phone logged lunch at 900 kcal and corrected it to 650.
      final id = await otherDao.saveMeal(lunch(900),
          markStatus: IngestionStatus.saved);
      await otherDao
          .updateMealAnalysis(id, {'is_food': true, 'total_calories': 650});
      final w =
          BackupFileWriter(dao: otherDao, platform: 'ios', clock: () => now);
      final f = await w.writeRecords('${tmp.path}/o.json',
          installId: _other, seq: 4, months: const {});
      cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();

      // di.dart init asks before runApp; the catch-up would analyze the
      // same photo afresh (900 kcal again).
      var caughtUp = false;
      final catchUp = () async {
        if (await c.holdsCatchUp()) return;
        caughtUp = true;
        await dao.saveMeal(lunch(900), markStatus: IngestionStatus.saved);
      }();
      await c.start(); // the shell, after the first frame
      await catchUp;
      // Real SQLite answers from another isolate.
      for (var i = 0; i < 400 && c.prompt.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final offer = c.prompt.value as RestoreOfferPrompt;
      final s = await c.restore(offer.candidate);
      final meals = await dao.mealsBetween('2026-11-11', '2026-11-11');
      expect([for (final m in meals) m.analysis['total_calories']], [650],
          reason: 'the correction survives');
      expect(s.mealsAdded, 1);
      expect(caughtUp, isFalse, reason: 'the offer holds the catch-up');
    });

    test('a look that ends without deciding (no iCloud) lets it go at once',
        () async {
      cloud.state = CloudState.unavailable;
      final held = c.holdsCatchUp();
      await c.start();
      expect(await held.timeout(const Duration(seconds: 5)), isFalse);
    });

    test('a catch-up already running asks before each photo: held from the '
        'moment the offer is raised until it is answered', () async {
      await otherPhoneBackup();
      expect(c.holdsCatchUpNow, isFalse);
      await c.launchCheckForTest();
      expect(c.prompt.value, isA<RestoreOfferPrompt>());
      expect(c.holdsCatchUpNow, isTrue);
      await c.declineOffer((c.prompt.value as RestoreOfferPrompt).candidate);
      expect(c.holdsCatchUpNow, isFalse);
    });

    test('stopped before the look ran, it waits no longer', () async {
      final held = c.holdsCatchUp();
      await c.stop();
      expect(await held.timeout(const Duration(seconds: 5)), isFalse);
    });
  });

  group('the restore offer', () {
    test('a fresh install is offered the backup, the catch-up is held, and '
        'Restore brings back meals and pictures, then adopts the file',
        () async {
      await otherPhoneBackup(meals: 3);
      await c.launchCheckForTest();
      final p = c.prompt.value;
      expect(p, isA<RestoreOfferPrompt>());
      final offer = p as RestoreOfferPrompt;
      expect(offer.candidate.header.meals, 3);
      expect(offer.localMeals, 0);
      expect(backupHoldsCatchUp(prefs, now), isTrue);

      final s = await c.restore(offer.candidate);
      expect(s.ok, isTrue);
      expect(s.mealsAdded, 3);
      expect(s.thumbsAdded, 3);
      expect(imported, 1);
      expect(backupHoldsCatchUp(prefs, now), isFalse);
      expect(prefs.getString(BackupPrefs.kAdoptedFrom), _other);
      // The notice comes after the restore; then the adopted file is
      // replaced with this install's.
      expect(c.prompt.value, isA<NoticePrompt>());
      await c.answerNotice(keepOn: true);
      await c.runForTest();
      await c.backUpNow();
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      expect(cloud.headerOf(kRecordsFileName)!.installId, me);
      expect(cloud.headerOf(kRecordsFileName)!.meals, 3);
      // Unchanged restored months are not rewritten: still the old phone's.
      expect(cloud.headerOf(picturesPath('2026-10'))!.installId, _other);
      // A new picture in that month rewrites it (allowed: adopted).
      final id = await seed(dao, '2026-10-20', hash: 'new');
      await dao.saveMealThumb(id, _jpeg(9));
      await c.backUpNow();
      expect(cloud.headerOf(picturesPath('2026-10'))!.installId, me);
      expect(cloud.headerOf(picturesPath('2026-10'))!.thumbs, 4);
    });

    test('Not Now is not asked again for that install', () async {
      await otherPhoneBackup();
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      await c.declineOffer(offer.candidate);
      expect(backupHoldsCatchUp(prefs, now), isFalse);
      expect(c.prompt.value, isA<NoticePrompt>());
      c.prompt.value = null;
      await c.launchCheckForTest();
      expect(c.prompt.value, isNot(isA<RestoreOfferPrompt>()));
      expect(c.status.value.restorable, hasLength(1),
          reason: 'still in Restore From iCloud…');
    });

    test('Start Fresh deletes the old backup', () async {
      await otherPhoneBackup();
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      expect(await c.startFresh(offer.candidate), BackupDeleteResult.deleted);
      expect(cloud.files, isEmpty);
    });

    test('Start Fresh on a new iPhone: the old backup\'s months are not on '
        'this phone, and all of it is deleted', () async {
      await otherPhoneBackup();
      cloud.notDownloaded.addAll(
          [for (final p in cloud.files.keys) if (p != kRecordsFileName) p]);
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      expect(await c.startFresh(offer.candidate), BackupDeleteResult.deleted);
      expect(cloud.files, isEmpty);
      expect(cloud.log.last, 'delete $kRecordsFileName',
          reason: 'the records file goes last');
    });

    test('Start Fresh that cannot finish deletes no records file, says so, '
        'and the offer comes back', () async {
      await otherPhoneBackup();
      cloud.unreachable.add(picturesPath('2026-10'));
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      expect(await c.startFresh(offer.candidate), BackupDeleteResult.failed);
      expect(cloud.files.keys,
          unorderedEquals([kRecordsFileName, picturesPath('2026-10')]),
          reason: 'nothing orphaned: the records file still names the month');
      expect(prefs.getStringList(BackupPrefs.kOffersAnswered) ?? const [],
          isNot(contains(_other)));
      c.prompt.value = null;
      cloud.unreachable.clear();
      await c.launchCheckForTest();
      final again = c.prompt.value as RestoreOfferPrompt;
      expect(await c.startFresh(again.candidate), BackupDeleteResult.deleted);
      expect(cloud.files, isEmpty);
    });

    test('Restore takes the backup as it is now, not as the offer saw it',
        () async {
      await otherPhoneBackup(meals: 2); // October only
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      expect(offer.candidate.header.months.keys, ['2026-10']);
      await otherPhoneAddsNovember(); // before the user taps Restore
      final mine = await seed(dao, '2026-11-05', hash: 'mine-nov');
      await dao.saveMealThumb(mine, _jpeg(8));
      final s = await c.restore(offer.candidate);
      expect(s.ok, isTrue);
      expect(s.thumbsAdded, 3, reason: 'November came in too');
      expect(BackupPrefs(prefs).months.keys,
          unorderedEquals(['2026-10', '2026-11']));
      await c.answerNotice(keepOn: true);
      await c.backUpNow();
      expect(hashesIn('2026-11'), unorderedEquals(['o-nov', 'mine-nov']),
          reason: 'the other phone\'s November picture is never lost');
    });

    test('Start Fresh deletes the backup as it is now, and nothing once '
        'another install took its file over', () async {
      await otherPhoneBackup(meals: 2);
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      await otherPhoneAddsNovember();
      expect(await c.startFresh(offer.candidate), BackupDeleteResult.deleted);
      expect(cloud.files, isEmpty, reason: 'November is not left orphaned');
      // Offered again, but a third phone wrote the file before Start Fresh.
      await prefs.remove(BackupPrefs.kOffersAnswered);
      await otherPhoneBackup(meals: 1);
      c.prompt.value = null;
      await c.launchCheckForTest();
      final second = c.prompt.value as RestoreOfferPrompt;
      final third = BackupHeader(
          kind: BackupKind.records, installId: _third, seq: 1);
      cloud.put(kRecordsFileName, '${third.envelopePrefix(now)}{}}');
      final before = Map.of(cloud.files);
      expect(await c.startFresh(second.candidate), BackupDeleteResult.failed);
      expect(cloud.files, before);
    });

    test('Start Fresh on a second backup deletes only that install\'s '
        'files, never this install\'s own month', () async {
      // December's file is the other install's; October's is this one's.
      final w =
          BackupFileWriter(dao: otherDao, platform: 'ios', clock: () => now);
      final odec = await seed(otherDao, '2026-12-01', hash: 'o-dec');
      await otherDao.saveMealThumb(odec, _jpeg(5));
      final p = await w.writePictures('${tmp.path}/o-dec.json',
          installId: _other, seq: 5, month: '2026-12');
      cloud.files[picturesPath('2026-12')] = await File(p.path).readAsBytes();
      final oct = await seed(dao, '2026-10-03', hash: 'h1');
      await dao.saveMealThumb(oct, _jpeg(1));
      final dec = await seed(dao, '2026-12-02', hash: 'mine-dec');
      await dao.saveMealThumb(dec, _jpeg(6));
      await ready();
      expect(await run(), BackupState.uploading);
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      expect(cloud.headerOf(picturesPath('2026-10'))!.installId, me);
      expect(BackupPrefs(prefs).months['2026-12']!.state, MonthState.foreign);
      // The other install's records file appears under another name (an
      // iCloud name race, or a copied file), listing October too.
      final f = await w.writeRecords('${tmp.path}/o.json',
          installId: _other,
          seq: 5,
          months: const {'2026-10': 2, '2026-12': 1});
      cloud.files['Chopstats Backup 2.json'] = await File(f.path).readAsBytes();
      c.prompt.value = null;
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      expect(offer.candidate.path, 'Chopstats Backup 2.json');
      expect(await c.startFresh(offer.candidate), BackupDeleteResult.deleted);
      expect(cloud.files.keys,
          unorderedEquals([kRecordsFileName, picturesPath('2026-10')]));
      expect(cloud.headerOf(picturesPath('2026-10'))!.installId, me);
      expect(BackupPrefs(prefs).months.containsKey('2026-12'), isFalse,
          reason: 'its file is gone: written by the next run');
      await c.backUpNow();
      await dao.saveBodyWeight('2026-11-10', 70);
      await c.backUpNow();
      expect(cloud.headerOf(kRecordsFileName)!.months,
          {'2026-10': 1, '2026-12': 1});
      expect(hashesIn('2026-10'), ['h1']);
      expect(hashesIn('2026-12'), ['mine-dec']);
    });

    test('a later scan reads each backup\'s header again', () async {
      await seed(dao, '2026-11-01');
      await otherPhoneBackup(meals: 2); // seq 5
      await c.launchCheckForTest();
      await c.declineOffer((c.prompt.value as RestoreOfferPrompt).candidate);
      c.prompt.value = null;
      await noticeAnswered();
      await otherPhoneAddsNovember(); // seq 6
      expect(await c.backUpNow(), BackupState.otherDevice);
      final r = c.status.value.restorable.single;
      expect(r.header.seq, 6, reason: 'what Restore From iCloud… shows');
      expect(r.header.months, {'2026-10': 2, '2026-11': 1});
    });
  });

  group('the takeover', () {
    test('merge: the other file is imported, then replaced by ours',
        () async {
      await seed(dao, '2026-11-10');
      await ready();
      await otherPhoneBackup(meals: 2);
      expect(await run(), BackupState.never);
      // The user answered the offer Not Now, then chose Back Up From This
      // iPhone…
      await prefs.setStringList(BackupPrefs.kOffersAnswered, [_other]);
      expect(await run(), BackupState.otherDevice);
      expect(await c.takeOver(replace: false), isTrue);
      expect((await dao.backupCounts()).meals, 3);
      final h = cloud.headerOf(kRecordsFileName)!;
      expect(h.installId, prefs.getString(BackupPrefs.kInstallId));
      expect(h.meals, 3);
    });

    test('replace: an unreadable file is replaced only on the explicit '
        'Replace', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      cloud.put(kRecordsFileName, 'garbage');
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.unknownFile);
      expect(await c.takeOver(replace: false), isFalse);
      expect(await c.takeOver(replace: true), isTrue);
      expect(cloud.headerOf(kRecordsFileName)!.meals, 2);
    });

    test('over this install\'s own file changed elsewhere: the seq check '
        'stays on', () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      final w = BackupFileWriter(dao: dao, platform: 'ios', clock: () => now);
      Future<void> ownFileAt(int seq) async {
        final f = await w.writeRecords('${tmp.path}/x$seq.json',
            installId: me, seq: seq, months: const {});
        cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();
      }

      await ownFileAt(40);
      await seed(dao, '2026-11-11');
      expect(await run(), BackupState.changedElsewhere);
      expect(await c.takeOver(replace: false), isTrue);
      expect(cloud.headerOf(kRecordsFileName)!.seq, 41);
      expect(prefs.getString(BackupPrefs.kAdoptedFrom) ?? '', isNot(me),
          reason: 'adopting its own id would turn the check off for good');
      // Changed elsewhere again: still noticed.
      await ownFileAt(90);
      await seed(dao, '2026-11-12');
      expect(await run(), BackupState.changedElsewhere);
      expect(cloud.headerOf(kRecordsFileName)!.seq, 90);
    });
  });

  test('combine: another phone\'s conflicting version is merged in and '
      'resolved', () async {
    await seed(dao, '2026-11-10');
    await ready();
    await run();
    await otherPhoneBackup(meals: 2, path: 'staging.json');
    cloud.conflictVersions[kRecordsFileName] = [cloud.files.remove('staging.json')!];
    await seed(dao, '2026-11-11');
    expect(await run(), BackupState.twoCopies);
    expect(await c.combine(), isTrue);
    expect(cloud.conflictVersions, isEmpty);
    expect((await dao.backupCounts()).meals, 4);
    expect(cloud.headerOf(kRecordsFileName)!.meals, 4);
  });

  test('a restore stays busy when the status is refreshed while it runs',
      () async {
    final gated = _FetchHeld();
    cloud = gated;
    c = make();
    await seed(dao, '2026-11-10');
    await ready();
    expect(await run(), BackupState.uploading);
    const path = 'Chopstats Backup 2.json';
    await otherPhoneBackup(path: path);
    gated.held = path;
    final restoring =
        c.restore(BackupCandidate(path, cloud.headerOf(path)!));
    await gated.entered.future;
    expect(c.status.value.busy, isTrue);
    await c.refresh(); // Settings opened, a resume, the 30 s timer
    expect(c.status.value.busy, isTrue,
        reason: 'the rows stay disabled and the line says Checking iCloud…');
    gated.gate.complete();
    expect((await restoring).ok, isTrue);
    expect(c.status.value.busy, isFalse);
  });

  test('combine is not said as done when the backup after the merge did not '
      'land', () async {
    final failing = _WritesFail();
    cloud = failing;
    c = make();
    await seed(dao, '2026-11-10');
    await ready();
    await run();
    await otherPhoneBackup(meals: 2, path: 'staging.json');
    cloud.conflictVersions[kRecordsFileName] = [cloud.files.remove('staging.json')!];
    await seed(dao, '2026-11-11');
    expect(await run(), BackupState.twoCopies);
    final seq = cloud.headerOf(kRecordsFileName)!.seq;
    failing.fail = CloudResultKind.timeout;
    expect(await c.combine(), isFalse,
        reason: 'the row says "Combined the two copies and backed up." on true');
    expect(c.status.value.state, BackupState.failed);
    expect(cloud.headerOf(kRecordsFileName)!.seq, seq, reason: 'nothing landed');
    expect((await dao.backupCounts()).meals, 4, reason: 'the merge is in');
    failing.fail = null;
    expect(await c.backUpNow(), BackupState.uploading);
    expect(cloud.headerOf(kRecordsFileName)!.meals, 4);
  });

  test('combine when iCloud kept the other phone\'s write as the current '
      'file: both merged, ours written over it', () async {
    await seed(dao, '2026-11-10');
    await ready();
    await run();
    final mine = cloud.files[kRecordsFileName]!;
    await otherPhoneBackup(meals: 2); // now the current file
    cloud.conflictVersions[kRecordsFileName] = [mine];
    expect(await c.combine(), isTrue);
    expect((await dao.backupCounts()).meals, 3);
    final h = cloud.headerOf(kRecordsFileName)!;
    expect(h.installId, prefs.getString(BackupPrefs.kInstallId));
    expect(h.meals, 3);
    expect(cloud.conflictVersions, isEmpty);
  });

  group('adopted months keep this phone\'s own pictures', () {
    test('restore onto a phone that already has pictures in the month',
        () async {
      await myOctoberPicture();
      await otherPhoneBackup(meals: 2);
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      expect((await c.restore(offer.candidate)).ok, isTrue);
      await c.answerNotice(keepOn: true);
      await c.backUpNow();
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      expect(cloud.headerOf(picturesPath('2026-10'))!.installId, me);
      expect(hashesIn('2026-10'), unorderedEquals(['mine', 'o0', 'o1']));
      expect(cloud.headerOf(kRecordsFileName)!.months, {'2026-10': 3});
    });

    test('takeover, combined first', () async {
      await myOctoberPicture();
      await ready();
      await otherPhoneBackup(meals: 2);
      await prefs.setStringList(BackupPrefs.kOffersAnswered, [_other]);
      expect(await run(), BackupState.otherDevice);
      expect(await c.takeOver(replace: false), isTrue);
      await dao.saveBodyWeight('2026-11-10', 70);
      await c.backUpNow();
      expect(hashesIn('2026-10'), unorderedEquals(['mine', 'o0', 'o1']));
    });

    test('takeover, replaced: only this phone\'s pictures stay', () async {
      await myOctoberPicture();
      await seed(dao, '2026-11-01');
      await ready();
      await otherPhoneBackup(meals: 2);
      // The other phone also has a month this phone has no pictures in.
      final dec = await seed(otherDao, '2026-12-01', hash: 'o-dec');
      await otherDao.saveMealThumb(dec, _jpeg(5));
      final w =
          BackupFileWriter(dao: otherDao, platform: 'ios', clock: () => now);
      final f = await w.writeRecords('${tmp.path}/o2.json',
          installId: _other,
          seq: 6,
          months: const {'2026-10': 2, '2026-12': 1});
      cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();
      final p = await w.writePictures('${tmp.path}/o-dec.json',
          installId: _other, seq: 6, month: '2026-12');
      cloud.files[picturesPath('2026-12')] = await File(p.path).readAsBytes();
      await prefs.setStringList(BackupPrefs.kOffersAnswered, [_other]);
      expect(await run(), BackupState.otherDevice);
      expect(await c.takeOver(replace: true), isTrue);
      expect(hashesIn('2026-10'), ['mine']);
      expect(cloud.files.containsKey(picturesPath('2026-12')), isFalse,
          reason: 'the replaced backup\'s month this phone has none in');
      expect(cloud.headerOf(kRecordsFileName)!.months, {'2026-10': 1});
    });

    test('combine, when it adopts the other phone\'s current file',
        () async {
      await myOctoberPicture();
      await ready();
      await run();
      expect(hashesIn('2026-10'), ['mine']);
      final mine = cloud.files[kRecordsFileName]!;
      await otherPhoneBackup(meals: 2); // now the current file and month
      cloud.conflictVersions[kRecordsFileName] = [mine];
      expect(await c.combine(), isTrue);
      expect(hashesIn('2026-10'), unorderedEquals(['mine', 'o0', 'o1']));
    });
  });

  group('a month that could not be read during the restore', () {
    Future<void> restoreWithOctoberUnreachable() async {
      await otherPhoneBackup(meals: 2);
      cloud.unreachable.add(picturesPath('2026-10'));
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      final s = await c.restore(offer.candidate);
      expect(s.ok, isTrue);
      expect(s.failedMonths, 1);
      expect(s.thumbsAdded, 0);
      await c.answerNotice(keepOn: true);
    }

    test('is tried again in the foreground until it comes in, and stays in '
        'this phone\'s backup meanwhile', () async {
      await restoreWithOctoberUnreachable();
      await c.backUpNow();
      final me = prefs.getString(BackupPrefs.kInstallId)!;
      expect(cloud.headerOf(kRecordsFileName)!.installId, me);
      expect(cloud.headerOf(kRecordsFileName)!.months, {'2026-10': 2},
          reason: 'a later restore of this backup still fetches it');
      expect((await dao.backupCounts()).thumbs, 0);
      // The background never downloads.
      await dao.saveBodyWeight('2026-11-10', 70);
      cloud.unreachable.clear();
      await run(background: true);
      expect((await dao.backupCounts()).thumbs, 0);
      // The next foreground run brings it in.
      await c.backUpNow();
      expect((await dao.backupCounts()).thumbs, 2);
      expect(cloud.headerOf(kRecordsFileName)!.months, {'2026-10': 2});
      expect(hashesIn('2026-10'), unorderedEquals(['o0', 'o1']));
      final rec = BackupPrefs(prefs).months['2026-10']!;
      expect(rec.state, MonthState.restored);
    });

    test('is never written over, even when this phone has its own pictures '
        'in it', () async {
      await myOctoberPicture();
      await restoreWithOctoberUnreachable();
      await c.backUpNow();
      expect(hashesIn('2026-10'), unorderedEquals(['o0', 'o1']),
          reason: 'the other phone\'s pictures have not come in yet');
      cloud.unreachable.clear();
      await c.backUpNow();
      expect(hashesIn('2026-10'), unorderedEquals(['mine', 'o0', 'o1']));
      expect((await dao.backupCounts()).thumbs, 3);
    });

    test('is dropped once its file is gone from iCloud', () async {
      await restoreWithOctoberUnreachable();
      cloud.unreachable.clear();
      cloud.files.remove(picturesPath('2026-10'));
      await c.backUpNow();
      expect(BackupPrefs(prefs).months, isEmpty);
      expect(cloud.headerOf(kRecordsFileName)!.months, isEmpty);
    });

    test('a launch retries it even when nothing else changed', () async {
      await restoreWithOctoberUnreachable();
      await c.backUpNow();
      cloud.unreachable.clear();
      // The app is opened again (a new engine).
      final next = make();
      await next.launchCheckForTest();
      expect((await dao.backupCounts()).thumbs, 2);
    });
  });

  test('combine with a version it cannot read leaves it unresolved and '
      'says it did not work', () async {
    await seed(dao, '2026-11-10');
    await ready();
    await run();
    cloud.conflictVersions[kRecordsFileName] = [
      Uint8List.fromList('my notes'.codeUnits)
    ];
    await seed(dao, '2026-11-11');
    expect(await run(), BackupState.twoCopies);
    expect(await c.combine(), isFalse);
    expect(cloud.conflictVersions[kRecordsFileName], hasLength(1));
  });

  test('delete removes this install\'s files and leaves another\'s',
      () async {
    final oct = await seed(dao, '2026-10-03', hash: 'h1');
    await dao.saveMealThumb(oct, _jpeg(1));
    await ready();
    await run();
    cloud.put('Meal Pictures/2026-01.json',
        utf8.decode(jsonEncode({}).codeUnits));
    final theirs = BackupHeader(kind: BackupKind.pictures, installId: _other, seq: 1, month: '2026-02');
    cloud.put(picturesPath('2026-02'), '${theirs.envelopePrefix(now)}{}}');
    // Another phone's month this phone never read is not even downloaded.
    cloud.notDownloaded.add(picturesPath('2026-02'));
    expect(await c.turnOff(deleteFiles: true), BackupDeleteResult.deleted);
    expect(cloud.files.keys,
        unorderedEquals(['Meal Pictures/2026-01.json', picturesPath('2026-02')]));
    expect(c.status.value.state, BackupState.off);
    expect(prefs.getInt(BackupPrefs.kLastSeq), isNull);
  });

  test('turning the switch off stops a run before its next upload',
      () async {
    for (var m = 1; m <= 9; m++) {
      final id = await seed(dao, '2026-0$m-10', hash: 'h$m');
      await dao.saveMealThumb(id, _jpeg(m));
    }
    await ready();
    cloud.onWrite = (path) async {
      if (path == picturesPath('2026-01')) {
        await c.turnOff(deleteFiles: false);
      }
    };
    expect(await run(), BackupState.off);
    expect(cloud.log, ['write ${picturesPath('2026-01')}'],
        reason: 'the write in flight lands; nothing after it');
    expect(c.status.value.state, BackupState.off);
  });

  test('a month with no pictures left that is not on this phone yet is '
      'deleted by a later run', () async {
    final oct = await seed(dao, '2026-10-03', hash: 'h1');
    await dao.saveMealThumb(oct, _jpeg(1));
    await seed(dao, '2026-11-02');
    await ready();
    await run();
    await dao.deleteMeal(oct);
    cloud.notDownloaded.add(picturesPath('2026-10'));
    await run();
    expect(cloud.files.containsKey(picturesPath('2026-10')), isTrue);
    expect(cloud.downloadsStarted, contains(picturesPath('2026-10')));
    expect(BackupPrefs(prefs).months.keys, ['2026-10'],
        reason: 'still to delete');
    cloud.finishDownloads();
    await run();
    expect(cloud.files.containsKey(picturesPath('2026-10')), isFalse);
    expect(BackupPrefs(prefs).months, isEmpty);
  });

  test('a delete that left one of this install\'s files keeps the backup '
      'known, so it can be deleted again', () async {
    final oct = await seed(dao, '2026-10-03', hash: 'h1');
    await dao.saveMealThumb(oct, _jpeg(1));
    await ready();
    await run();
    cloud.unreachable.add(picturesPath('2026-10'));
    expect(await c.deleteBackup(), BackupDeleteResult.failed);
    expect(prefs.getInt(BackupPrefs.kLastSeq), 1);
    cloud.unreachable.clear();
    cloud.notDownloaded.clear();
    expect(await c.deleteBackup(), BackupDeleteResult.deleted);
    expect(cloud.files, isEmpty);
    expect(prefs.getInt(BackupPrefs.kLastSeq), isNull);
  });

  test('turning off with Delete: this phone\'s months not on this phone '
      'are downloaded first and deleted, pictures before the records file',
      () async {
    for (final d in ['2026-09-03', '2026-10-03']) {
      final id = await seed(dao, d, hash: 'h$d');
      await dao.saveMealThumb(id, _jpeg(1));
    }
    await ready();
    await run();
    cloud.notDownloaded.add(picturesPath('2026-09'));
    cloud.log.clear();
    expect(await c.turnOff(deleteFiles: true), BackupDeleteResult.deleted);
    expect(cloud.files, isEmpty);
    expect(cloud.log.last, 'delete $kRecordsFileName');
    expect(prefs.getInt(BackupPrefs.kLastSeq), isNull);
  });

  test('turning off with Delete when one month cannot download: the rest '
      'goes, the records file stays, the partial delete is said, and a retry '
      'finishes', () async {
    for (final d in ['2026-09-03', '2026-10-03']) {
      final id = await seed(dao, d, hash: 'h$d');
      await dao.saveMealThumb(id, _jpeg(1));
    }
    await ready();
    await run();
    cloud.unreachable.add(picturesPath('2026-09'));
    expect(await c.turnOff(deleteFiles: true), BackupDeleteResult.partial);
    expect(cloud.files.keys,
        unorderedEquals([kRecordsFileName, picturesPath('2026-09')]));
    expect(BackupPrefs(prefs).months.keys, ['2026-09']);
    expect(prefs.getInt(BackupPrefs.kLastSeq), 1, reason: 'still known');
    expect(c.status.value.state, BackupState.off);
    cloud.unreachable.clear();
    expect(await c.deleteBackup(), BackupDeleteResult.deleted);
    expect(cloud.files, isEmpty);
    expect(prefs.getInt(BackupPrefs.kLastSeq), isNull);
  });

  test('with the switch off, or paused after a relaunch, the status still '
      'knows this install\'s files are in iCloud', () async {
    await seed(dao, '2026-11-10');
    await ready();
    await run();
    expect(await c.turnOff(deleteFiles: false), isNull);
    expect(c.status.value.state, BackupState.off);
    expect(c.status.value.ownsFiles, isTrue);
    expect(c.status.value.lastOkAt, isNotNull);
    // Relaunched with the switch off.
    final next = make();
    expect(next.status.value.state, BackupState.off);
    expect(next.status.value.ownsFiles, isTrue);
    expect(await next.deleteBackup(), BackupDeleteResult.deleted);
    expect(next.status.value.ownsFiles, isFalse);
    expect(cloud.files, isEmpty);
    expect(cloud.log.where((e) => e.startsWith('write')), hasLength(1),
        reason: 'deleting never uploaded first');
    // Paused (the file went missing), relaunched.
    await prefs.setBool(BackupPrefs.kEnabled, true);
    await prefs.setInt(BackupPrefs.kLastSeq, 3);
    await prefs.setString(BackupPrefs.kPaused, 'missing');
    final paused = make();
    expect(paused.status.value.state, BackupState.missing);
    expect(paused.status.value.ownsFiles, isTrue);
  });

  test('the adopted install that takes its backup back is another install '
      'again: nothing of its newer backup is written over or deleted',
      () async {
    await otherPhoneBackup(meals: 2); // seq 5, October
    await c.launchCheckForTest();
    final offer = c.prompt.value as RestoreOfferPrompt;
    expect((await c.restore(offer.candidate)).ok, isTrue);
    await c.answerNotice(keepOn: true);
    await c.backUpNow();
    final me = prefs.getString(BackupPrefs.kInstallId)!;
    expect(cloud.headerOf(kRecordsFileName)!.installId, me);
    expect(cloud.headerOf(picturesPath('2026-10'))!.installId, _other,
        reason: 'restored and unchanged: still the adopted file');
    // The old phone, still in use, chose Back Up From This iPhone (its
    // next seq is above any it took before): October first...
    final late = await seed(otherDao, '2026-10-25', hash: 'o-late');
    await otherDao.saveMealThumb(late, _jpeg(6));
    final w = BackupFileWriter(dao: otherDao, platform: 'ios', clock: () => now);
    final p = await w.writePictures('${tmp.path}/o9-oct.json',
        installId: _other, seq: 9, month: '2026-10');
    cloud.files[picturesPath('2026-10')] = await File(p.path).readAsBytes();
    final mine = await seed(dao, '2026-10-26', hash: 'mine');
    await dao.saveMealThumb(mine, _jpeg(7));
    expect(await run(), BackupState.uploading);
    expect(hashesIn('2026-10'), unorderedEquals(['o0', 'o1', 'o-late']),
        reason: 'its newer October is not written over');
    expect(BackupPrefs(prefs).months['2026-10']!.state, MonthState.foreign);
    // ...then its records file, with a meal this phone never saw.
    final f = await w.writeRecords('${tmp.path}/o9.json',
        installId: _other, seq: 9, months: const {'2026-10': 3});
    cloud.files[kRecordsFileName] = await File(f.path).readAsBytes();
    final theirs = Map.of(cloud.files);
    await seed(dao, '2026-11-10');
    expect(await run(), BackupState.otherDevice);
    expect(c.status.value.other!.installId, _other);
    expect(await c.backUpNow(), BackupState.otherDevice);
    expect(await c.deleteBackup(), isNot(BackupDeleteResult.failed));
    expect(cloud.files, theirs, reason: 'nothing of it written or deleted');
  });

  group('a restore while this iPhone does not back up takes nothing over',
      () {
    test('the switch off: a plain merge, and Delete never reaches the other '
        'iPhone\'s backup', () async {
      await noticeAnswered();
      await prefs.setBool(BackupPrefs.kEnabled, false);
      await otherPhoneBackup(meals: 3);
      await c.launchCheckForTest();
      expect(c.prompt.value, isNull, reason: 'no offer while off');
      final cand = c.status.value.restorable.single; // Restore From iCloud…
      final takesOver = c.restoreTakesOver(cand);
      final s = await c.restore(cand);
      expect(s.ok, isTrue);
      expect(s.mealsAdded, 3);
      final theirs = Map.of(cloud.files);
      await c.deleteBackup();
      expect(cloud.files, theirs,
          reason: 'the other iPhone still owns its backup, and may write it');
      expect(takesOver, isFalse,
          reason: 'the sheet does not say this iPhone takes it over');
      expect(prefs.getString(BackupPrefs.kAdoptedFrom), isNull);
      expect(c.status.value.ownsFiles, isFalse,
          reason: 'no Delete iCloud Backup… row while off');
      // Turned on later: that backup is in the way like any other
      // install's (Back Up From This iPhone… asks first).
      await c.setEnabled(true);
      expect(await c.backUpNow(), BackupState.otherDevice);
      expect(cloud.files, theirs);
    });

    test('Turn Off on the notice after a restore gives the takeover up',
        () async {
      await otherPhoneBackup(meals: 2);
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      expect(c.restoreTakesOver(offer.candidate), isTrue,
          reason: 'on by default: the sheet says it takes the backup over');
      expect((await c.restore(offer.candidate)).ok, isTrue);
      expect(c.prompt.value, isA<NoticePrompt>());
      await c.answerNotice(keepOn: false);
      final theirs = Map.of(cloud.files);
      await c.deleteBackup();
      expect(cloud.files, theirs,
          reason: 'never written over: still the other iPhone\'s backup');
      expect(c.status.value.state, BackupState.off);
      expect(c.status.value.ownsFiles, isFalse);
      expect(prefs.getString(BackupPrefs.kAdoptedFrom), isNull);
      expect(BackupPrefs(prefs).months, isEmpty);
      await c.setEnabled(true);
      expect(await c.backUpNow(), BackupState.otherDevice);
      expect(cloud.files, theirs, reason: 'not written over without asking');
    });

    test('the switch turned off before this iPhone wrote over the file gives '
        'the takeover up; after it did, the backup is this iPhone\'s',
        () async {
      await noticeAnswered();
      await otherPhoneBackup(meals: 2);
      await c.launchCheckForTest();
      final offer = c.prompt.value as RestoreOfferPrompt;
      cloud.state = CloudState.unavailable; // the run after the restore stops
      expect((await c.restore(offer.candidate)).ok, isTrue);
      expect(await run(), BackupState.unavailable, reason: 'after that run');
      expect(prefs.getString(BackupPrefs.kAdoptedFrom), _other);
      expect(await c.turnOff(deleteFiles: false), isNull);
      cloud.state = CloudState.ok;
      final theirs = Map.of(cloud.files);
      expect(c.status.value.ownsFiles, isFalse);
      expect(prefs.getString(BackupPrefs.kAdoptedFrom), isNull);
      await c.setEnabled(true);
      expect(await c.backUpNow(), BackupState.otherDevice);
      expect(cloud.files, theirs);
      // Taken over on purpose and written: this iPhone's, the switch off.
      expect(await c.takeOver(replace: false), isTrue);
      expect(await c.turnOff(deleteFiles: false), isNull);
      expect(prefs.getString(BackupPrefs.kAdoptedFrom), _other);
      expect(c.status.value.ownsFiles, isTrue);
      expect(await c.deleteBackup(), BackupDeleteResult.deleted);
      expect(cloud.files, isEmpty);
    });
  });

  test('a delete never drops another phone\'s unresolved write to the '
      'records file', () async {
    await seed(dao, '2026-11-10');
    await ready();
    await run();
    await otherPhoneBackup(meals: 2, path: 'staging.json');
    final theirs = cloud.files.remove('staging.json')!;
    for (final p in [...cloud.files.keys]) {
      if (p != kRecordsFileName) cloud.files.remove(p);
    }
    cloud.conflictVersions[kRecordsFileName] = [theirs];
    expect(await c.deleteBackup(), BackupDeleteResult.failed);
    expect(cloud.files.containsKey(kRecordsFileName), isTrue);
    expect(cloud.conflictVersions[kRecordsFileName], [theirs]);
    expect(prefs.getInt(BackupPrefs.kLastSeq), 1, reason: 'still known');
  });

  group('the background', () {
    test('a background run updates our own file without downloading',
        () async {
      await seed(dao, '2026-11-10');
      await ready();
      await run();
      await seed(dao, '2026-11-11');
      cloud.notDownloaded.add(kRecordsFileName);
      cloud.log.clear();
      await run(background: true);
      expect(cloud.log, isEmpty, reason: 'not downloaded: skipped');
      expect(cloud.notDownloaded, contains(kRecordsFileName));
      cloud.notDownloaded.clear();
      expect(await run(background: true), BackupState.uploading);
    });

    test('the headless engine needs 8 s and an id, and creates none',
        () async {
      await seed(dao, '2026-11-10');
      await ready();
      await BackupCoordinator.runHeadless(
          dao: dao,
          prefs: prefs,
          left: const Duration(seconds: 20),
          tempDir: () async => tmp,
          transport: cloud);
      expect(cloud.files, isEmpty);
      expect(prefs.getString(BackupPrefs.kInstallId), isNull);
      await run(); // the app writes first
      await seed(dao, '2026-11-11');
      cloud.log.clear();
      await BackupCoordinator.runHeadless(
          dao: dao,
          prefs: prefs,
          left: const Duration(seconds: 7),
          tempDir: () async => tmp,
          transport: cloud);
      expect(cloud.log, isEmpty);
      await BackupCoordinator.runHeadless(
          dao: dao,
          prefs: prefs,
          left: const Duration(seconds: 20),
          tempDir: () async => tmp,
          transport: cloud);
      expect(cloud.log, ['write $kRecordsFileName']);
    });
  });

  test('the catch-up lease expires on its own', () async {
    await otherPhoneBackup();
    await c.launchCheckForTest();
    expect(backupHoldsCatchUp(prefs, now), isTrue);
    expect(backupHoldsCatchUp(prefs, now.add(const Duration(minutes: 31))),
        isFalse);
  });
}

/// A metadata query in its first minute: each look at it is 10 s later
/// ([onLook] moves the clock as far).
class _QueryWarmingUp extends FakeCloudTransport {
  _QueryWarmingUp(this.onLook);
  final void Function() onLook;

  @override
  Future<CloudListing> list() async {
    live += const Duration(seconds: 10);
    onLook();
    return super.list();
  }
}

/// An iCloud folder whose fetch of [held] waits for [gate] (a long
/// download), [entered] once it does.
class _FetchHeld extends FakeCloudTransport {
  String? held;
  final Completer<void> gate = Completer();
  final Completer<void> entered = Completer();

  @override
  Future<CloudResult> fetch(String path, String destPath,
      {required Duration timeout}) async {
    if (path == held) {
      if (!entered.isCompleted) entered.complete();
      await gate.future;
    }
    return super.fetch(path, destPath, timeout: timeout);
  }
}

/// An iCloud folder whose writes answer [fail] while it is set (a timeout,
/// a full iCloud): nothing lands.
class _WritesFail extends FakeCloudTransport {
  CloudResultKind? fail;

  @override
  Future<CloudResult> write({
    required String path,
    required String sourcePath,
    required int bytes,
    required String sha256,
    required WriteExpect expect,
    String? keepPreviousPath,
    required bool allowDownload,
    required Duration timeout,
  }) async {
    final kind = fail;
    if (kind != null) return CloudResult(kind);
    return super.write(
        path: path,
        sourcePath: sourcePath,
        bytes: bytes,
        sha256: sha256,
        expect: expect,
        keepPreviousPath: keepPreviousPath,
        allowDownload: allowDownload,
        timeout: timeout);
  }
}

/// A database whose month of pictures cannot be read.
class _ThumbsFailDao extends SqfliteMealsDao {
  _ThumbsFailDao(super.db, {super.clock});
  @override
  Future<List<BackupThumb>> thumbsForMonth(String month) async =>
      throw const FileSystemException('No space left on device');
}
