// Backup and export files as written to disk (1.7.0): each is an export
// envelope 1.6.0 can read, its header reads back from the first 16 KB, its
// size and SHA-256 are those of the bytes on disk, pictures are cleaned,
// and a full export restores the log and its pictures on a fresh phone.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/data/meals_logic.dart';
import 'package:calorie_tracker/services/backup/backup_files.dart';
import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '0123456789abcdef0123456789abcdef';

Uint8List _exifJpeg(int shade) {
  final src = img.Image(width: 12, height: 12);
  img.fill(src, color: img.ColorRgb8(shade, 80, 40));
  src.exif.imageIfd['Make'] = 'TestCam';
  return Uint8List.fromList(img.encodeJpg(src));
}

bool _hasAscii(List<int> b, String s) {
  final n = s.codeUnits;
  outer:
  for (var i = 0; i + n.length <= b.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (b[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final now = DateTime.utc(2026, 11, 11, 9);
  late Directory tmp;
  late Database dbA, dbB;
  late SqfliteMealsDao a, b;
  late BackupFileWriter writer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_backup_files');
    dbA = await openAppDatabase(path: '${tmp.path}/a.db');
    dbB = await openAppDatabase(path: '${tmp.path}/b.db');
    a = SqfliteMealsDao(dbA, clock: () => now);
    b = SqfliteMealsDao(dbB, clock: () => now);
    writer = BackupFileWriter(dao: a, platform: 'ios', clock: () => now);
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tmp.delete(recursive: true);
  });

  Future<int> seed(String date, {String hash = ''}) => a.saveMeal(
      Meal(
        id: 0,
        date: date,
        time: '12:00 PM',
        timestamp: '${date}T12:00:00.000',
        source: hash.isEmpty ? MealSource.manualText : MealSource.appWatch,
        imageHash: hash,
        analysis: {'is_food': true, 'total_calories': 400, 'meal_description': 'Noodles'},
      ),
      markStatus: hash.isEmpty ? null : IngestionStatus.saved);

  Future<void> expectHonest(WrittenBackupFile f) async {
    final bytes = await File(f.path).readAsBytes();
    expect(f.bytes, bytes.length);
    expect(f.sha256, sha256.convert(bytes).toString());
    final h = parseBackupHeader(bytes.sublist(0, bytes.length.clamp(0, kBackupHeaderLimit)))!;
    expect(h.kind, f.header.kind);
    expect(h.installId, f.header.installId);
    expect(h.seq, f.header.seq);
    // 1.6.0's parser takes it.
    parseExportEnvelope(utf8.decode(bytes));
  }

  test('kAppVersion is the pubspec version', () {
    var dir = Directory.current;
    while (!File('${dir.path}/pubspec.yaml').existsSync()) {
      dir = dir.parent;
    }
    final line = File('${dir.path}/pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':').last.trim().split('+').first, kAppVersion);
  });

  test('the records file holds the export tables and no pictures', () async {
    final id = await seed('2026-10-03', hash: 'h1');
    await seed('2026-11-09');
    await a.saveMealThumb(id, _exifJpeg(10));
    await a.saveBodyWeight('2026-11-09', 70);
    final f = await writer.writeRecords('${tmp.path}/out/records.json',
        installId: _me, seq: 7, months: {'2026-10': 1});
    await expectHonest(f);
    final env = jsonDecode(await File(f.path).readAsString()) as Map;
    expect((env['tables'] as Map).keys, kExportTables);
    expect(f.header.meals, 2);
    expect(f.header.thumbs, 1);
    expect(f.header.firstDate, '2026-10-03');
    expect(f.header.lastDate, '2026-11-09');
    expect(f.header.months, {'2026-10': 1});
    expect(f.header.appVersion, kAppVersion);
    // No user text in the header: the meal description is only in tables.
    final head = (await File(f.path).readAsString())
        .split(',"tables":')
        .first;
    expect(head, isNot(contains('Noodles')));
    final s = await b.importJson(await File(f.path).readAsString());
    expect(s.added['meals'], 2);
    expect(s.added['body_weight'], 1);
  });

  test('a pictures file holds one month, cleaned', () async {
    final oct = await seed('2026-10-03', hash: 'h1');
    final nov = await seed('2026-11-01', hash: 'h2');
    await a.saveMealThumb(oct, _exifJpeg(10));
    await a.saveMealThumb(nov, _exifJpeg(20));
    final f = await writer.writePictures('${tmp.path}/2026-10.json',
        installId: _me, seq: 8, month: '2026-10');
    await expectHonest(f);
    expect(f.header.kind, BackupKind.pictures);
    expect(f.header.month, '2026-10');
    expect(f.header.thumbs, 1);
    final env = jsonDecode(await File(f.path).readAsString()) as Map;
    final rows = (env['tables'] as Map)['meal_thumbs'] as List;
    expect(rows, hasLength(1));
    expect((rows.single as Map)['image_hash'], 'h1');
    final jpeg = base64Decode((rows.single as Map)['jpeg_b64'] as String);
    expect(_hasAscii(jpeg, 'Exif'), isFalse);
    expect(_hasAscii(jpeg, 'TestCam'), isFalse);
    expect(img.decodeJpg(jpeg), isNotNull);
  });

  test('a picture that cannot be cleaned is left out and counted', () async {
    final id = await seed('2026-10-03', hash: 'h1');
    final id2 = await seed('2026-10-04', hash: 'h2');
    await a.saveMealThumb(id, Uint8List.fromList([0xFF, 0xD8, 1, 2, 3]));
    await a.saveMealThumb(id2, _exifJpeg(30));
    final f = await writer.writePictures('${tmp.path}/p.json',
        installId: _me, seq: 1, month: '2026-10');
    expect(f.header.thumbs, 1);
    expect(f.header.thumbsSkipped, 1);
  });

  test('a full export restores meals and pictures on a fresh phone',
      () async {
    final oct = await seed('2026-10-03', hash: 'h1');
    final nov = await seed('2026-11-01', hash: 'h2');
    await seed('2026-11-02');
    await a.saveMealThumb(oct, _exifJpeg(10));
    await a.saveMealThumb(nov, _exifJpeg(20));
    final f =
        await writer.writeFull('${tmp.path}/chopstats.json', installId: _me);
    await expectHonest(f);
    expect(f.header.kind, BackupKind.full);
    expect(f.header.seq, 0);
    expect(f.header.months, {'2026-10': 1, '2026-11': 1});
    final s = await b.importJson(await File(f.path).readAsString());
    expect(s.added['meals'], 3);
    expect(s.thumbsAdded, 2);
    final restored = await b.mealsBetween('2026-10-01', '2026-11-30');
    final photo = restored.firstWhere((m) => m.imageHash == 'h2');
    final thumb = (await b.mealThumb(photo.id))!;
    expect(_hasAscii(thumb, 'TestCam'), isFalse);
    // Importing the same file again changes nothing.
    final again = await b.importJson(await File(f.path).readAsString());
    expect(again.totalAdded, 0);
    expect(again.thumbsAdded, 0);
  });

  test('an empty log still writes a valid file', () async {
    final f = await writer.writeRecords('${tmp.path}/empty.json',
        installId: _me, seq: 1, months: const {});
    await expectHonest(f);
    expect(f.header.meals, 0);
    expect(f.header.firstDate, isNull);
  });
}
