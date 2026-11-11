// The iCloud Backup header (1.7.0): its key order, the 16 KB limit, the
// way both languages read it back, and the owner rule the Swift writer
// mirrors (CloudFiles.swift checkOwner; RunnerTests cover that copy).
import 'dart:convert';

import 'package:calorie_tracker/data/meals_logic.dart';
import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:flutter_test/flutter_test.dart';

const _me = '0123456789abcdef0123456789abcdef';
const _other = 'fedcba9876543210fedcba9876543210';

BackupHeader _records({int seq = 3, Map<String, int> months = const {}}) =>
    BackupHeader(
      kind: BackupKind.records,
      installId: _me,
      seq: seq,
      platform: 'ios',
      appVersion: '1.7.0',
      meals: 412,
      thumbs: 398,
      thumbsSkipped: 3,
      firstDate: '2025-01-02',
      lastDate: '2026-11-10',
      months: months,
    );

String _file(BackupHeader h, {String tables = '{"meals":[]}'}) =>
    '${h.envelopePrefix(DateTime.utc(2026, 11, 11, 8))}$tables}';

void main() {
  test('the envelope keys come in the pinned order', () {
    final text = _file(_records(months: {'2026-10': 93}));
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded.keys.toList(),
        ['format', 'version', 'exported_at', 'backup', 'tables']);
    expect(decoded['format'], kExportFormat);
    expect(decoded['version'], 2);
    expect((decoded['backup'] as Map).keys.toList(), [
      'kind',
      'install_id',
      'seq',
      'platform',
      'app_version',
      'meals',
      'thumbs',
      'thumbs_skipped',
      'first_date',
      'last_date',
      'months',
    ]);
    // 1.6.0's parser reads it: any version from 1 up, tables by name.
    final parsed = parseExportEnvelope(text);
    expect(parsed.tables.keys, ['meals']);
  });

  test('a pictures header names its month instead of the month list', () {
    final h = BackupHeader(
        kind: BackupKind.pictures, installId: _me, seq: 4, month: '2026-11');
    final b = jsonDecode(_file(h))['backup'] as Map;
    expect(b['month'], '2026-11');
    expect(b.containsKey('months'), isFalse);
  });

  test('fifty years of months still fit in the 16 KB header', () {
    final months = <String, int>{
      for (var y = 2000; y < 2050; y++)
        for (var m = 1; m <= 12; m++)
          '$y-${m.toString().padLeft(2, '0')}': 9999,
    };
    final prefix = _records(months: months)
        .envelopePrefix(DateTime.utc(2026, 11, 11));
    expect(utf8.encode(prefix).length, lessThan(kBackupHeaderLimit));
    final back = parseBackupHeader(utf8.encode(_file(_records(months: months),
        tables: '{"meals":[${List.filled(5000, '{"id":1}').join(',')}]}')));
    expect(back, isNotNull);
    expect(back!.months, hasLength(600));
  });

  test('reading the header needs only the first bytes', () {
    final text = _file(_records(seq: 17, months: {'2026-10': 93}),
        tables: '{"meals":[${List.filled(20000, '{"x":1}').join(',')}]}');
    final bytes = utf8.encode(text);
    expect(bytes.length, greaterThan(kBackupHeaderLimit));
    final h = parseBackupHeader(bytes.sublist(0, kBackupHeaderLimit))!;
    expect(h.kind, BackupKind.records);
    expect(h.installId, _me);
    expect(h.seq, 17);
    expect(h.meals, 412);
    expect(h.months, {'2026-10': 93});
    expect(h.exportedAt, '2026-11-11T08:00:00.000Z');
  });

  group('an unknown owner', () {
    String withBackup(Object? backup, {Object? version = 2}) =>
        '{"format":"calorie_tracker_export","version":${jsonEncode(version)},'
        '"exported_at":"x","backup":${jsonEncode(backup)},"tables":{}}';
    final good = _records().toJson();

    test('a 1.6.0 export has no header', () {
      expect(
          parseBackupHeader(utf8.encode(
              '{"format":"calorie_tracker_export","version":1,'
              '"exported_at":"x","tables":{}}')),
          isNull);
    });
    test('version 1 with a header is not read', () {
      expect(parseBackupHeader(utf8.encode(withBackup(good, version: 1))),
          isNull);
    });
    test('a string version, a bad id, an unknown kind or a string seq', () {
      expect(parseBackupHeader(utf8.encode(withBackup(good, version: '2'))),
          isNull);
      for (final patch in [
        {'install_id': 'ABC'},
        {'install_id': '${_me}0'},
        {'kind': 'everything'},
        {'seq': '3'},
      ]) {
        expect(parseBackupHeader(utf8.encode(withBackup({...good, ...patch}))),
            isNull,
            reason: '$patch');
      }
    });
    test('another format tag, no tables key, or not JSON', () {
      expect(
          parseBackupHeader(utf8.encode(withBackup(good)
              .replaceFirst('calorie_tracker_export', 'other'))),
          isNull);
      expect(parseBackupHeader(utf8.encode('{"format":"calorie_tracker_export"}')),
          isNull);
      expect(parseBackupHeader(utf8.encode('not json,"tables":{}')), isNull);
      expect(parseBackupHeader(const []), isNull);
    });
    test('a header past 16 KB', () {
      final big = withBackup({...good, 'pad': 'x' * kBackupHeaderLimit});
      expect(parseBackupHeader(utf8.encode(big)), isNull);
    });
  });

  test('paths and months', () {
    expect(picturesPath('2026-10'), 'Meal Pictures/2026-10.json');
    expect(monthOfPicturesPath('Meal Pictures/2026-10.json'), '2026-10');
    expect(monthOfPicturesPath('Meal Pictures/notes.json'), isNull);
    expect(monthOfPicturesPath('2026-10.json'), isNull);
    expect(monthOfDate('2026-10-31'), '2026-10');
    expect(monthOfDate(''), isNull);
    expect(monthOfDate('yesterday'), isNull);
    expect(isValidInstallId(_me), isTrue);
    expect(isValidInstallId(_me.toUpperCase()), isFalse);
  });

  group('the owner rule', () {
    BackupHeader mine(int seq) => BackupHeader(
        kind: BackupKind.records, installId: _me, seq: seq);
    final theirs =
        BackupHeader(kind: BackupKind.records, installId: _other, seq: 9);

    test('a missing file only when absence is allowed', () {
      expect(
          checkOwner(
              exists: false,
              header: null,
              expect: const WriteExpect(installId: _me)),
          OwnerVerdict.absentNotAllowed);
      expect(
          checkOwner(
              exists: false,
              header: null,
              expect: const WriteExpect(installId: _me, allowAbsent: true)),
          OwnerVerdict.allowed);
    });

    test('this install only at an expected seq', () {
      const expect5 = WriteExpect(installId: _me, seqs: [5, 6]);
      expect(checkOwner(exists: true, header: mine(5), expect: expect5),
          OwnerVerdict.allowed);
      expect(checkOwner(exists: true, header: mine(6), expect: expect5),
          OwnerVerdict.allowed);
      expect(checkOwner(exists: true, header: mine(7), expect: expect5),
          OwnerVerdict.changedElsewhere);
      expect(
          checkOwner(
              exists: true,
              header: mine(70),
              expect: const WriteExpect(installId: _me)),
          OwnerVerdict.allowed,
          reason: 'null seqs = any (pictures files, deletes)');
    });

    test('another install unless adopted', () {
      const plain = WriteExpect(installId: _me, seqs: [0], allowAbsent: true);
      expect(checkOwner(exists: true, header: theirs, expect: plain),
          OwnerVerdict.ownedByOther);
      expect(
          checkOwner(
              exists: true,
              header: theirs,
              expect: const WriteExpect(
                  installId: _me, seqs: [0], adoptFrom: _other)),
          OwnerVerdict.allowed);
    });

    test('an unreadable header only on the explicit Replace', () {
      expect(
          checkOwner(
              exists: true,
              header: null,
              expect: const WriteExpect(installId: _me, allowAbsent: true)),
          OwnerVerdict.unknownOwner);
      expect(
          checkOwner(
              exists: true,
              header: null,
              expect: const WriteExpect(installId: _me, replaceUnknown: true)),
          OwnerVerdict.allowed);
    });
  });
}
