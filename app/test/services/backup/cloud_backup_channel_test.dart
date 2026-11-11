// The Dart end of the iCloud Backup channel (1.7.0): what each method
// sends, how each reply is read, and that a missing plugin (Part A without
// the entitlement, Android, tests) is "unavailable", never a throw.
import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:calorie_tracker/services/backup/cloud_backup_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _me = '0123456789abcdef0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(cloudBackupChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Object? Function(MethodCall) answer = (_) => null;

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  const t = ICloudTransport();

  test('status and the account change', () async {
    answer = (_) => {'status': 'ok', 'accountChanged': true};
    final s = await t.status();
    expect(s.state, CloudState.ok);
    expect(s.accountChanged, isTrue);
    answer = (_) => {'status': 'noAccount', 'accountChanged': false};
    expect((await t.status()).state, CloudState.noAccount);
    answer = (_) => {'status': 'unavailable'};
    expect((await t.status()).state, CloudState.unavailable);
  });

  test('a nil device key is null, never an empty key', () async {
    answer = (_) => {'status': 'ok', 'key': null};
    expect(await t.deviceKey(), isNull);
    answer = (_) => {'status': 'ok', 'key': 'abc'};
    expect(await t.deviceKey(), 'abc');
  });

  test('the listing', () async {
    answer = (_) => {
          'status': 'ok',
          'gathered': true,
          'liveMs': 61000,
          'items': [
            {
              'path': 'Chopstats Backup.json',
              'downloading': false,
              'uploaded': false,
              'uploading': true,
              'hasConflicts': false,
              'uploadError': 'quota',
            },
            {'path': 'Meal Pictures/2026-10.json', 'uploaded': true},
            {'nope': 1},
          ],
        };
    final l = await t.list();
    expect(l.gathered, isTrue);
    expect(l.live, const Duration(seconds: 61));
    expect(l.items, hasLength(2));
    expect(l.item(kRecordsFileName)!.uploadError, 'quota');
    expect(l.item(kRecordsFileName)!.topLevel, isTrue);
    expect(l.item('Meal Pictures/2026-10.json')!.topLevel, isFalse);
  });

  test('a write sends the expectation and reads the verdict with its header',
      () async {
    answer = (_) => {
          'status': 'ownedByOther',
          'header': {
            'format': 'calorie_tracker_export',
            'version': 2,
            'exported_at': '2026-11-11T08:00:00.000Z',
            'backup': {
              'kind': 'records',
              'install_id': 'fedcba9876543210fedcba9876543210',
              'seq': 9,
              'meals': 120,
            },
          },
        };
    final r = await t.write(
      path: kRecordsFileName,
      sourcePath: '/tmp/x.json',
      bytes: 10,
      sha256: 'ab',
      expect: const WriteExpect(installId: _me, seqs: [3, 4]),
      keepPreviousPath: kPreviousFileName,
      allowDownload: false,
      timeout: const Duration(seconds: 15),
    );
    expect(r.kind, CloudResultKind.ownedByOther);
    expect(r.header!.seq, 9);
    expect(r.header!.meals, 120);
    final args = calls.single.arguments as Map;
    expect(args['expect'], {
      'installId': _me,
      'seqs': [3, 4],
      'adoptFrom': null,
      'allowAbsent': false,
      'replaceUnknown': false,
    });
    expect(args['timeoutMs'], 15000);
    expect(args['keepPreviousPath'], kPreviousFileName);
  });

  test('a delete reads what it removed, refused and left', () async {
    answer = (_) => {'status': 'ok', 'deleted': 2, 'refused': 1, 'left': 1};
    final r = await t.delete(
        const ['Meal Pictures/2026-09.json', kRecordsFileName],
        const WriteExpect(installId: _me));
    expect(r.ok, isTrue);
    expect([r.deleted, r.refused, r.left], [2, 1, 1]);
    answer = (_) => {'status': 'ok', 'deleted': 1};
    final old = await t.delete(const [kRecordsFileName],
        const WriteExpect(installId: _me));
    expect([old.deleted, old.refused, old.left], [1, 0, 0]);
  });

  test('error replies carry a code and nothing else', () async {
    answer = (_) => {'status': 'error', 'domain': 'NSCocoaErrorDomain', 'code': 4};
    final r = await t.readHeader(kRecordsFileName,
        allowDownload: false, timeout: const Duration(seconds: 1));
    expect(r.kind, CloudResultKind.error);
    expect(r.errorCode, 'NSCocoaErrorDomain:4');
    answer = (_) => {'status': 'quota'};
    expect((await t.fetch('a.json', '/tmp/a', timeout: Duration.zero)).kind,
        CloudResultKind.quota);
  });

  test('no plugin is unavailable, not a throw', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect((await t.status()).state, CloudState.unavailable);
    expect(await t.deviceKey(), isNull);
    expect((await t.list()).watching, isFalse);
    expect(
        (await t.write(
                path: kRecordsFileName,
                sourcePath: '/x',
                bytes: 1,
                sha256: 'x',
                expect: const WriteExpect(installId: _me),
                allowDownload: false,
                timeout: Duration.zero))
            .kind,
        CloudResultKind.unavailable);
    expect((await t.pickFiles()).kind, CloudResultKind.unavailable);
  });
}
