// The photo change history's Dart side (lib/services/photo/photo_changes.dart,
// design G1a): every native status decodes, anything off-contract is an
// error (never an exception, never a partial result), and the channel's
// arguments and failures are what the Swift plugin expects.
import 'dart:async';

import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _tag = '0a1b2c3d';

Map<String, Object?> _entry(String id, {int? created, int? added}) => {
      'id': id,
      'created_ms': ?created,
      'added_ms': ?added,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeCurrentToken', () {
    test('ok carries the token and the device tag', () {
      final t = decodeCurrentToken(
          {'status': 'ok', 'token': 'YnBsaXN0', 'device_tag': _tag});
      expect(t.status, PhotoChangeStatus.ok);
      expect(t.token, 'YnBsaXN0');
      expect(t.deviceTag, _tag);
      expect(t.errorCode, isNull);
    });

    test('unsupported, denied and error decode with their reasons', () {
      expect(decodeCurrentToken({'status': 'unsupported'}).status,
          PhotoChangeStatus.unsupported);
      final denied =
          decodeCurrentToken({'status': 'denied', 'device_tag': _tag});
      expect(denied.status, PhotoChangeStatus.denied);
      expect(denied.deviceTag, _tag);
      expect(denied.token, isNull);
      final error = decodeCurrentToken(
          {'status': 'error', 'error_code': 'no_device_tag'});
      expect(error.status, PhotoChangeStatus.error);
      expect(error.errorCode, 'no_device_tag');
      expect(decodeCurrentToken({'status': 'error', 'error_code': 3300})
          .errorCode, '3300');
    });

    test('anything off-contract is an error, never an exception', () {
      for (final reply in <Object?>[
        null,
        'ok',
        42,
        ['ok'],
        <String, Object?>{},
        {'status': 'nope'},
        {'status': 7},
        {'status': 'ok'},
        {'status': 'ok', 'token': '', 'device_tag': _tag},
        {'status': 'ok', 'token': 5, 'device_tag': _tag},
        {'status': 'ok', 'token': 't'},
        {'status': 'ok', 'token': 't', 'device_tag': 'ABCDEF12'},
        {'status': 'ok', 'token': 't', 'device_tag': '0a1b2c3'},
        {'status': 'ok', 'token': 't', 'device_tag': 12345678},
        // Not answers currentToken gives.
        {'status': 'fresh', 'token': 't', 'device_tag': _tag},
        {'status': 'expired', 'token': 't', 'device_tag': _tag},
        {'status': 'unavailable', 'token': 't', 'device_tag': _tag},
        {'status': 'error', 'error_code': 1.5},
        {'status': 'denied', 'device_tag': 'xyz'},
      ]) {
        final t = decodeCurrentToken(reply);
        expect(t.status, PhotoChangeStatus.error, reason: '$reply');
        expect(t.errorCode, photoChangesMalformed, reason: '$reply');
        expect(t.token, isNull);
      }
    });
  });

  group('decodeInsertedImages', () {
    test('ok: IDs newest first as sent, dates, truncated, next token', () {
      final created = DateTime.utc(2026, 10, 21, 17, 15).millisecondsSinceEpoch;
      final added = DateTime.utc(2026, 10, 23, 20, 46).millisecondsSinceEpoch;
      final r = decodeInsertedImages({
        'status': 'ok',
        'token': 'next',
        'device_tag': _tag,
        'truncated': true,
        'dropped': 12,
        'ids': [
          _entry('A/L0/001', created: created, added: added),
          _entry('B/L0/001', created: created - 1000),
          _entry('C/L0/001'),
        ],
      });
      expect(r.status, PhotoChangeStatus.ok);
      expect(r.token, 'next');
      expect(r.deviceTag, _tag);
      expect(r.truncated, isTrue);
      expect(r.dropped, 12);
      expect(r.ids.map((e) => e.id), ['A/L0/001', 'B/L0/001', 'C/L0/001']);
      expect(r.ids[0].created!.millisecondsSinceEpoch, created);
      expect(r.ids[0].added!.millisecondsSinceEpoch, added);
      expect(r.ids[1].added, isNull);
      expect(r.ids[2].created, isNull);
      expect(() => r.ids.add(const InsertedImage('x')), throwsUnsupportedError);
    });

    test('ok with nothing new; truncated and dropped default to none', () {
      final r = decodeInsertedImages(
          {'status': 'ok', 'token': 't', 'device_tag': _tag, 'ids': []});
      expect(r.status, PhotoChangeStatus.ok);
      expect(r.ids, isEmpty);
      expect(r.truncated, isFalse);
      expect(r.dropped, 0);
    });

    test('fresh, expired and unavailable restart from the new token', () {
      for (final (name, status) in [
        ('fresh', PhotoChangeStatus.fresh),
        ('expired', PhotoChangeStatus.expired),
        ('unavailable', PhotoChangeStatus.unavailable),
      ]) {
        final r = decodeInsertedImages({
          'status': name,
          'token': 'current',
          'device_tag': _tag,
          'ids': [],
          'truncated': false,
          if (name == 'unavailable') 'error_code': 'token_unreadable',
        });
        expect(r.status, status, reason: name);
        expect(r.token, 'current');
        expect(r.deviceTag, _tag);
        expect(r.ids, isEmpty);
        expect(r.errorCode,
            name == 'unavailable' ? 'token_unreadable' : isNull);
      }
      // They never carry IDs, even if a reply did.
      expect(
          decodeInsertedImages({
            'status': 'fresh',
            'token': 'current',
            'device_tag': _tag,
            'ids': [_entry('A')],
          }).ids,
          isEmpty);
    });

    test('error keeps what the native side echoed; unsupported and denied',
        () {
      final error = decodeInsertedImages({
        'status': 'error',
        'error_code': 'PHPhotosErrorDomain:3300',
        'token': 'sent',
        'device_tag': _tag,
        'ids': [],
        'truncated': false,
      });
      expect(error.status, PhotoChangeStatus.error);
      expect(error.errorCode, 'PHPhotosErrorDomain:3300');
      expect(error.token, 'sent');
      expect(error.ids, isEmpty);
      final noTag = decodeInsertedImages(
          {'status': 'error', 'error_code': 'no_device_tag', 'token': 's'});
      expect(noTag.deviceTag, isNull);
      expect(noTag.errorCode, 'no_device_tag');
      expect(decodeInsertedImages({'status': 'unsupported'}).status,
          PhotoChangeStatus.unsupported);
      final denied = decodeInsertedImages(
          {'status': 'denied', 'device_tag': _tag, 'ids': []});
      expect(denied.status, PhotoChangeStatus.denied);
      expect(denied.token, isNull);
    });

    test('anything off-contract is an error, never an exception or a '
        'partial list', () {
      Map<String, Object?> ok(Object? ids, {Object? truncated = false}) => {
            'status': 'ok',
            'token': 't',
            'device_tag': _tag,
            'ids': ids,
            'truncated': truncated,
          };
      for (final reply in <Object?>[
        null,
        'ok',
        [1],
        {'status': null},
        {'status': 'OK', 'token': 't', 'device_tag': _tag, 'ids': []},
        // A token to store must be there, with its phone.
        {'status': 'ok', 'device_tag': _tag, 'ids': []},
        {'status': 'ok', 'token': '', 'device_tag': _tag, 'ids': []},
        {'status': 'ok', 'token': 't', 'ids': []},
        {'status': 'expired', 'device_tag': _tag},
        {'status': 'fresh', 'token': 't'},
        {'status': 'unavailable', 'token': 't', 'device_tag': 'nothex!!'},
        // The ID list and each entry.
        ok(null),
        ok('A,B'),
        ok({'id': 'A'}),
        ok([_entry('A'), 'B']),
        ok([
          {'id': ''}
        ]),
        ok([
          {'id': 7}
        ]),
        ok([
          {'created_ms': 1}
        ]),
        ok([
          {'id': 'A', 'created_ms': '1700000000000'}
        ]),
        ok([
          {'id': 'A', 'created_ms': 1.5}
        ]),
        ok([
          {'id': 'A', 'added_ms': 9000000000000000000}
        ]),
        ok([], truncated: 'yes'),
        ok([], truncated: 1),
        {...ok([]), 'dropped': -1},
        {...ok([]), 'dropped': '3'},
        {...ok([]), 'dropped': 2.5},
        {'status': 'error', 'token': 5},
        {'status': 'error', 'error_code': ['x']},
      ]) {
        final r = decodeInsertedImages(reply);
        expect(r.status, PhotoChangeStatus.error, reason: '$reply');
        expect(r.errorCode, photoChangesMalformed, reason: '$reply');
        expect(r.ids, isEmpty, reason: '$reply');
        expect(r.token, isNull, reason: '$reply');
      }
    });
  });

  group('decodeAlbumAssetIds', () {
    test('ok, denied, error', () {
      final ok = decodeAlbumAssetIds({
        'status': 'ok',
        'ids': ['A/L0/001', 'B/L0/001']
      });
      expect(ok.status, PhotoChangeStatus.ok);
      expect(ok.ids, ['A/L0/001', 'B/L0/001']);
      final denied = decodeAlbumAssetIds({'status': 'denied', 'ids': []});
      expect(denied.status, PhotoChangeStatus.denied);
      expect(denied.ids, isEmpty);
      expect(decodeAlbumAssetIds({'status': 'error', 'error_code': 'x'}).errorCode,
          'x');
      expect(decodeAlbumAssetIds({'status': 'unsupported'}).status,
          PhotoChangeStatus.unsupported);
    });

    test('anything off-contract is an error', () {
      for (final reply in <Object?>[
        null,
        [],
        {'status': 'ok'},
        {'status': 'ok', 'ids': 'A'},
        {
          'status': 'ok',
          'ids': ['A', 1]
        },
        {
          'status': 'ok',
          'ids': ['']
        },
        {'status': 'fresh', 'ids': []},
        {'status': 'what', 'ids': []},
      ]) {
        final r = decodeAlbumAssetIds(reply);
        expect(r.status, PhotoChangeStatus.error, reason: '$reply');
        expect(r.errorCode, photoChangesMalformed);
        expect(r.ids, isEmpty);
      }
    });
  });

  // Design G2b: when a glasses photo joined the library.
  group('decodeAssetDates', () {
    test('ok with dates, denied, error', () {
      final ok = decodeAssetDates({
        'status': 'ok',
        'ids': [
          _entry('A', created: 1000, added: 2000),
          _entry('B'),
        ]
      });
      expect(ok.status, PhotoChangeStatus.ok);
      expect(ok.ids.map((i) => i.id), ['A', 'B']);
      expect(ok.ids[0].created, DateTime.fromMillisecondsSinceEpoch(1000));
      expect(ok.ids[0].added, DateTime.fromMillisecondsSinceEpoch(2000));
      expect(ok.ids[1].added, isNull, reason: 'before iOS 26');
      final denied = decodeAssetDates({'status': 'denied', 'ids': []});
      expect(denied.status, PhotoChangeStatus.denied);
      expect(denied.ids, isEmpty);
      expect(decodeAssetDates({'status': 'error', 'error_code': 'x'}).errorCode,
          'x');
    });

    test('anything off-contract is an error', () {
      for (final reply in <Object?>[
        null,
        [],
        {'status': 'ok'},
        {'status': 'ok', 'ids': 'A'},
        {
          'status': 'ok',
          'ids': ['A']
        },
        {
          'status': 'ok',
          'ids': [
            {'id': ''}
          ]
        },
        {
          'status': 'ok',
          'ids': [
            {'id': 'A', 'added_ms': 'soon'}
          ]
        },
        {'status': 'expired', 'ids': []},
        {'status': 'what', 'ids': []},
      ]) {
        final r = decodeAssetDates(reply);
        expect(r.status, PhotoChangeStatus.error, reason: '$reply');
        expect(r.errorCode, photoChangesMalformed);
        expect(r.ids, isEmpty);
      }
    });
  });

  group('ChannelPhotoChangeSource', () {
    const channel = MethodChannel(photoChangesChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    void answer(Future<Object?> Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return handler(call);
      });
    }

    setUp(calls.clear);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the channel name is the Swift plugin\'s', () {
      expect(photoChangesChannelName, 'dev.calorietracker/photochanges');
    });

    test('sends the contract\'s arguments, clamped, and decodes replies',
        () async {
      answer((call) async => switch (call.method) {
            'currentToken' => {
                'status': 'ok',
                'token': 'cur',
                'device_tag': _tag
              },
            'insertedImagesSince' => {
                'status': 'ok',
                'token': 'next',
                'device_tag': _tag,
                'ids': [_entry('A', created: 1)],
                'truncated': false,
              },
            'albumAssetIds' => {
                'status': 'ok',
                'ids': ['A']
              },
            _ => null,
          });
      final source = ChannelPhotoChangeSource();

      final token = await source.currentToken();
      expect(token.token, 'cur');
      expect(calls.last.method, 'currentToken');

      final since = await source.insertedImagesSince('cur',
          limit: 50, budget: const Duration(milliseconds: 800), maxChanges: 300);
      expect(since.ids.single.id, 'A');
      expect(calls.last.arguments, {
        'token': 'cur',
        'limit': 50,
        'budget_ms': 800,
        'max_changes': 300,
      });

      // Over the caps → the caps; no token → null (fresh).
      await source.insertedImagesSince(null,
          limit: 9999, budget: const Duration(seconds: 9), maxChanges: 99999);
      expect(calls.last.arguments, {
        'token': null,
        'limit': photoChangesMaxLimit,
        'budget_ms': photoChangesMaxBudget.inMilliseconds,
        'max_changes': photoChangesMaxChanges,
      });
      await source.insertedImagesSince('cur', limit: 0, maxChanges: -1);
      expect((calls.last.arguments as Map)['limit'], 1);
      expect((calls.last.arguments as Map)['max_changes'], 1);

      final since0 = DateTime(2026, 10, 16);
      final albums = await source.albumAssetIds(['Meta AI', 'Ray-Ban Meta'],
          since: since0, limit: 5000);
      expect(albums.ids, ['A']);
      expect(calls.last.arguments, {
        'titles': ['Meta AI', 'Ray-Ban Meta'],
        'sinceMs': since0.millisecondsSinceEpoch,
        'limit': albumAssetIdsMaxLimit,
      });
      await source.albumAssetIds(['Meta AI']);
      expect((calls.last.arguments as Map)['sinceMs'], 0);
    });

    test('assetDates sends at most 50 non-empty ids, and asks nothing for '
        'none', () async {
      answer((call) async => {
            'status': 'ok',
            'ids': [_entry('A', created: 1, added: 2)],
          });
      final source = ChannelPhotoChangeSource();
      final dates = await source.assetDates(['A', '']);
      expect(dates.ids.single.added, DateTime.fromMillisecondsSinceEpoch(2));
      expect(calls.last.method, 'assetDates');
      expect(calls.last.arguments, {
        'ids': ['A']
      });
      await source.assetDates([for (var i = 0; i < 80; i++) 'id$i']);
      expect(((calls.last.arguments as Map)['ids'] as List), hasLength(50));
      final before = calls.length;
      expect((await source.assetDates(const [''])).status,
          PhotoChangeStatus.ok);
      expect(calls, hasLength(before), reason: 'nothing to ask about');

      answer((call) async =>
          throw PlatformException(code: 'boom', message: 'native failure'));
      expect((await source.assetDates(['A'])).errorCode, 'platform:boom');
      messenger.setMockMethodCallHandler(channel, null);
      expect((await source.assetDates(['A'])).errorCode,
          photoChangesMissingPlugin);
    });

    test('a platform error, a missing plugin, a timeout and a bad reply are '
        'errors, never exceptions', () async {
      answer((call) async =>
          throw PlatformException(code: 'boom', message: 'native failure'));
      final source = ChannelPhotoChangeSource();
      expect((await source.currentToken()).errorCode, 'platform:boom');
      final since = await source.insertedImagesSince('t');
      expect(since.status, PhotoChangeStatus.error);
      expect(since.errorCode, 'platform:boom');
      expect(since.token, isNull);
      expect((await source.albumAssetIds(['Meta AI'])).errorCode,
          'platform:boom');

      // No handler: what an engine without the plugin answers.
      messenger.setMockMethodCallHandler(channel, null);
      for (final r in [
        (await source.currentToken()).errorCode,
        (await source.insertedImagesSince('t')).errorCode,
        (await source.albumAssetIds(['Meta AI'])).errorCode,
      ]) {
        expect(r, photoChangesMissingPlugin);
      }

      answer((call) => Completer<Object?>().future); // never answers
      final slow = ChannelPhotoChangeSource(
          timeout: const Duration(milliseconds: 20));
      expect((await slow.currentToken()).errorCode, photoChangesTimeout);
      final late = await slow.insertedImagesSince('t');
      expect(late.status, PhotoChangeStatus.error);
      expect(late.errorCode, photoChangesTimeout);
      expect((await slow.albumAssetIds(['Meta AI'])).errorCode,
          photoChangesTimeout);

      answer((call) async => 'not a map');
      expect((await source.insertedImagesSince('t')).errorCode,
          photoChangesMalformed);
    });
  });

  test('a source on iOS only', () {
    expect(platformPhotoChangeSource(isIOS: true),
        isA<ChannelPhotoChangeSource>());
    expect(platformPhotoChangeSource(isIOS: false), isNull);
  });

  group('FakePhotoChangeSource', () {
    test('quiet defaults: fresh without a token, ok with one', () async {
      final fake = FakePhotoChangeSource();
      final current = await fake.currentToken();
      expect(current.status, PhotoChangeStatus.ok);
      expect(current.token, 'fake-token-1');
      expect(current.deviceTag, 'a1b2c3d4');
      final fresh = await fake.insertedImagesSince(null);
      expect(fresh.status, PhotoChangeStatus.fresh);
      expect(fresh.token, 'fake-token-2');
      final ok = await fake.insertedImagesSince('fake-token-2');
      expect(ok.status, PhotoChangeStatus.ok);
      expect(ok.token, 'fake-token-2');
      expect(ok.ids, isEmpty);
      expect((await fake.albumAssetIds(['Meta AI'])).ids, isEmpty);
      expect(fake.currentTokenCalls, 1);
      expect(fake.insertedImagesSinceTokens, [null, 'fake-token-2']);
      expect(fake.albumAssetIdsTitles, [
        ['Meta AI']
      ]);
      final dates = await fake.assetDates(['A']);
      expect(dates.status, PhotoChangeStatus.ok);
      expect(dates.ids, isEmpty);
      expect(fake.assetDatesIds, [
        ['A']
      ]);
    });

    test('scripted answers', () async {
      final fake = FakePhotoChangeSource(deviceTag: 'ffffffff')
        ..onCurrentToken =
            (() => const PhotoChangeToken(PhotoChangeStatus.denied))
        ..onInsertedImagesSince = ((token, limit, budget, maxChanges) =>
            InsertedImages(PhotoChangeStatus.ok,
                token: 'after-$token',
                ids: const [InsertedImage('A')],
                truncated: limit < 10,
                deviceTag: 'ffffffff'))
        ..onAlbumAssetIds = ((titles, since, limit) =>
            AlbumAssetIds(PhotoChangeStatus.ok, ids: ['in-${titles.first}']));
      expect((await fake.currentToken()).status, PhotoChangeStatus.denied);
      final r = await fake.insertedImagesSince('t', limit: 5);
      expect(r.token, 'after-t');
      expect(r.truncated, isTrue);
      expect((await fake.albumAssetIds(['Meta AI'])).ids, ['in-Meta AI']);
    });
  });
}
