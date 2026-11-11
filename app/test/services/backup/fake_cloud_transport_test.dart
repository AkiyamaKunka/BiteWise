// The in-memory iCloud folder (test/support/fake_cloud_transport.dart)
// keeps the rules of the Swift file layer (ios/Runner/CloudFiles.swift)
// where the coordinator tests lean on them: a header that cannot be read
// is never this install's, and starting a download is not finishing one.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:calorie_tracker/services/backup/cloud_backup_channel.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_cloud_transport.dart';

const _me = '0123456789abcdef0123456789abcdef';

void main() {
  late Directory tmp;
  late FakeCloudTransport cloud;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_fake_cloud');
    cloud = FakeCloudTransport();
  });
  tearDown(() => tmp.delete(recursive: true));

  Uint8List file(int seq) => Uint8List.fromList(
      '${BackupHeader(kind: BackupKind.records, installId: _me, seq: seq).envelopePrefix(DateTime.utc(2026, 11, 11))}{}}'
          .codeUnits);

  Future<CloudResult> write(int seq, WriteExpect expect,
      {String? keepPrevious}) async {
    final bytes = file(seq);
    final src = File('${tmp.path}/src-$seq.json')..writeAsBytesSync(bytes);
    return cloud.write(
        path: kRecordsFileName,
        sourcePath: src.path,
        bytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        expect: expect,
        keepPreviousPath: keepPrevious,
        allowDownload: true,
        timeout: const Duration(seconds: 5));
  }

  test('a conflict version whose header cannot be read stops the write '
      '(settleConflicts: expect.owns(nil) is false)', () async {
    cloud.files[kRecordsFileName] = file(1);
    cloud.conflictVersions[kRecordsFileName] = [
      Uint8List.fromList('my notes'.codeUnits)
    ];
    final r = await write(2, const WriteExpect(installId: _me, seqs: [1]));
    expect(r.kind, CloudResultKind.twoCopies);
    expect(cloud.headerOf(kRecordsFileName)!.seq, 1);
    expect(cloud.conflictVersions[kRecordsFileName], hasLength(1));
  });

  test('a previous copy whose header cannot be read is never rotated over',
      () async {
    cloud.files[kRecordsFileName] = file(1);
    cloud.put(kPreviousFileName, 'my notes');
    final r = await write(2, const WriteExpect(installId: _me, seqs: [1]),
        keepPrevious: kPreviousFileName);
    expect(r.ok, isTrue);
    expect(String.fromCharCodes(cloud.files[kPreviousFileName]!), 'my notes');
    expect(cloud.log, ['write $kRecordsFileName']);
  });

  test('a previous copy that is not downloaded is not rotated over',
      () async {
    cloud.files[kRecordsFileName] = file(2);
    cloud.files[kPreviousFileName] = file(1);
    cloud.notDownloaded.add(kPreviousFileName);
    final r = await write(3, const WriteExpect(installId: _me, seqs: [2]),
        keepPrevious: kPreviousFileName);
    expect(r.ok, isTrue);
    expect(cloud.headerOf(kPreviousFileName)!.seq, 1);
  });

  test('startDownloads only starts the download; a coordinated read waits '
      'for it', () async {
    const p = 'Meal Pictures/2026-10.json';
    cloud.files[p] = file(1);
    cloud.notDownloaded.add(p);
    await cloud.startDownloads(const [p]);
    expect(cloud.downloadsStarted, [p]);
    expect(
        (await cloud.readHeader(p,
                allowDownload: false, timeout: const Duration(seconds: 1)))
            .kind,
        CloudResultKind.notDownloaded);
    expect((await cloud.itemState(p)).downloading, isTrue);
    cloud.finishDownloads();
    expect((await cloud.itemState(p)).downloading, isFalse);
    expect(
        (await cloud.readHeader(p,
                allowDownload: false, timeout: const Duration(seconds: 1)))
            .kind,
        CloudResultKind.ok);
  });
}
