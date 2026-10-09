// The iOS keychain move from `unlocked` to `first_unlock` (2026-10-09).
// The BGAppRefresh scan runs with the phone locked, where an `unlocked`
// item cannot be read, so every run died before scanning. Two layers:
//   1. MigratingKeyStore's order, with in-memory fakes.
//   2. platformKeyStore() against a model of the real keychain rules the
//      plugin exposes (accessibility in every query; one item per key
//      whatever its class; delete matches every class; locked phone).
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory seam with failure switches and a shared call log.
class FakeStore implements SecureKeyStore {
  FakeStore(this.name, this.log);
  final String name;
  final List<String> log;
  final Map<String, String> data = {};
  bool throwOnRead = false;
  bool throwOnWrite = false;
  bool throwOnDelete = false;
  /// Writes of these keys fail (e.g. a duplicate of an old-class item).
  final Set<String> failWriteKeys = {};
  /// Writes fail this many more times, then succeed.
  int failNextWrites = 0;
  /// Runs after a read is logged — lets a test interleave another engine.
  Future<void> Function()? onRead;

  @override
  Future<String?> read(String key) async {
    log.add('$name.read');
    if (throwOnRead) throw PlatformException(code: '-25308');
    await onRead?.call();
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    log.add('$name.write');
    if (throwOnWrite || failWriteKeys.contains(key)) {
      throw PlatformException(code: '-25299');
    }
    if (failNextWrites > 0) {
      failNextWrites--;
      throw PlatformException(code: '-25299');
    }
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    log.add('$name.delete');
    if (throwOnDelete) throw PlatformException(code: '-34018');
    data.remove(key);
  }
}

/// The keychain as flutter_secure_storage_darwin 0.3.2 drives it.
class KeychainModel {
  /// key -> (value, accessibility class)
  final Map<String, (String, String)> items = {};
  final List<MethodCall> calls = [];
  bool locked = false;

  static const _whileUnlocked = {'unlocked', 'unlocked_this_device'};

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map).cast<String, Object?>();
    final key = args['key'] as String?;
    final options = (args['options'] as Map).cast<String, String>();
    final acc = options['accessibility'] ?? 'unlocked';
    final item = key == null ? null : items[key];
    switch (call.method) {
      case 'read':
        // kSecAttrAccessible is part of the read query.
        if (item == null || item.$2 != acc) return null;
        if (locked && _whileUnlocked.contains(acc)) {
          throw PlatformException(code: '-25308'); // InteractionNotAllowed
        }
        return item.$1;
      case 'write':
        final value = args['value'] as String;
        if (locked && _whileUnlocked.contains(acc)) {
          throw PlatformException(code: '-25308');
        }
        if (item != null && item.$2 != acc) {
          // Accessibility is not part of the item's identity.
          throw PlatformException(code: '-25299'); // DuplicateItem
        }
        items[key!] = (value, acc);
        return null;
      case 'delete':
        items.remove(key); // every accessibility permutation
        return null;
    }
    throw MissingPluginException(call.method);
  }
}

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MigratingKeyStore', () {
    late List<String> log;
    late FakeStore primary;
    late FakeStore legacy;
    late MigratingKeyStore store;

    setUp(() {
      log = [];
      primary = FakeStore('primary', log);
      legacy = FakeStore('legacy', log);
      store = MigratingKeyStore(primary: primary, legacy: legacy);
    });

    test('fresh install: a missing key reads null and nothing is touched',
        () async {
      expect(await store.read('k'), isNull);
      // Re-reads the new class (another engine may have migrated it) and
      // the staging slot (an interrupted move); writes nothing.
      expect(log, ['primary.read', 'legacy.read', 'primary.read', 'primary.read']);
    });

    test('a key in the new class is read straight from it', () async {
      primary.data['k'] = 'v';
      expect(await store.read('k'), 'v');
      expect(log, ['primary.read']);
    });

    test('an old key migrates once: delete the old copy, then write the new',
        () async {
      legacy.data['k'] = 'v';
      expect(await store.read('k'), 'v');
      expect(log, [
        'primary.read', 'legacy.read',
        'primary.write', // stage
        'legacy.delete',
        'primary.write', // the real item
        'primary.delete', // drop the stage
      ]);
      expect(primary.data, {'k': 'v'});
      expect(legacy.data, isEmpty);

      log.clear();
      expect(await store.read('k'), 'v');
      expect(log, ['primary.read'], reason: 'migrated for good');
    });

    test('locked phone: the old copy is unreadable -> the read FAILS, '
        'nothing deleted (never "missing")', () async {
      // Reporting null here let the UI show an empty key field whose next
      // save deleted the stored key (review 2026-10-09).
      legacy
        ..data['k'] = 'v'
        ..throwOnRead = true;
      await expectLater(store.read('k'), throwsA(isA<PlatformException>()));
      expect(log, ['primary.read', 'legacy.read']);
      expect(legacy.data, {'k': 'v'});
      expect(primary.data, isEmpty);

      // Unlocked later: the same key migrates then.
      legacy.throwOnRead = false;
      expect(await store.read('k'), 'v');
      expect(primary.data, {'k': 'v'});
    });

    test('a failed stage write moves nothing', () async {
      legacy.data['k'] = 'v';
      primary.throwOnWrite = true;
      expect(await store.read('k'), 'v');
      expect(legacy.data, {'k': 'v'}, reason: 'never lose a key');
      expect(primary.data, isEmpty);
      expect(log, isNot(contains('legacy.delete')));
    });

    test('a failed new-class write puts the key back in the old class',
        () async {
      legacy.data['k'] = 'v';
      primary.failWriteKeys.add('k');
      expect(await store.read('k'), 'v');
      expect(legacy.data, {'k': 'v'}, reason: 'never lose a key');
      expect(primary.data, isEmpty, reason: 'stage dropped after restore');
    });

    test('a move interrupted after the delete is finished from the stage',
        () async {
      // The new write AND the restore fail (or the app dies in between):
      // only the staged copy holds the key.
      legacy.data['k'] = 'v';
      primary.failWriteKeys.add('k');
      legacy.throwOnWrite = true;
      expect(await store.read('k'), 'v');
      expect(legacy.data, isEmpty);
      expect(primary.data, {MigratingKeyStore.stagingKey('k'): 'v'});

      primary.failWriteKeys.clear();
      expect(await store.read('k'), 'v');
      expect(primary.data, {'k': 'v'}, reason: 'moved, stage gone');
    });

    test('another engine migrating between the two reads is not "missing"',
        () async {
      legacy.data['k'] = 'v';
      legacy.onRead = () async {
        // The other engine finished the move just now.
        legacy.data.remove('k');
        primary.data['k'] = 'v';
      };
      expect(await store.read('k'), 'v');
    });

    test('a failed delete of the old copy leaves it intact for later',
        () async {
      legacy
        ..data['k'] = 'v'
        ..throwOnDelete = true;
      expect(await store.read('k'), 'v');
      expect(legacy.data, {'k': 'v'});
      expect(primary.data, isEmpty, reason: 'stage dropped, no new copy');
    });

    test('write replaces an old-class copy with a new-class one', () async {
      legacy.data['k'] = 'old';
      primary.failNextWrites = 1; // the add collides with the old item
      await store.write('k', 'new');
      expect(legacy.data, isEmpty);
      expect(primary.data, {'k': 'new'});
      expect(log.last, 'primary.write', reason: 'clear, then write');
      expect(await store.read('k'), 'new');
    });

    test('write of a migrated key is one in-place write (atomic)', () async {
      primary.data['k'] = 'a';
      await store.write('k', 'b');
      expect(log, ['primary.write']);
      expect(primary.data, {'k': 'b'});
    });

    test('delete clears both classes', () async {
      legacy.data['k'] = 'a';
      primary.data['k'] = 'b';
      await store.delete('k');
      expect(legacy.data, isEmpty);
      expect(primary.data, isEmpty);
      expect(await store.read('k'), isNull);
    });
  });

  group('platformKeyStore on the keychain model', () {
    late KeychainModel keychain;

    setUp(() {
      keychain = KeychainModel();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, keychain.handle);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<AppSettings> load() async {
      SharedPreferences.setMockInitialValues({});
      return AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: platformKeyStore());
    }

    test('iOS: an upgraded iPhone keeps its key and the locked-phone '
        'background run can read it once migrated', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      // Saved by an earlier build under the plugin default.
      keychain.items['server_api_key'] = ('sk-test', 'unlocked');

      // Locked before the app was opened unlocked: the load FAILS (never
      // "no key" — the UI would offer to overwrite it) and the item stays.
      // The background runner survives a failed load (background_glue).
      keychain.locked = true;
      await expectLater(load(), throwsA(isA<PlatformException>()));
      expect(keychain.items['server_api_key'], ('sk-test', 'unlocked'));

      // Foreground, unlocked: read and migrated.
      keychain.locked = false;
      expect((await load()).serverApiKey, 'sk-test');
      expect(keychain.items['server_api_key'], ('sk-test', 'first_unlock'));

      // Locked again: the background run now has the key.
      keychain.locked = true;
      expect((await load()).serverApiKey, 'sk-test');
    });

    test('iOS: uses first_unlock, never a this-device class (backups restore)',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await platformKeyStore().write('gemini_api_key', 'g');
      final writes = keychain.calls.where((c) => c.method == 'write');
      expect(writes, hasLength(1));
      final options = ((writes.single.arguments as Map)['options'] as Map);
      expect(options['accessibility'], 'first_unlock');
      expect(keychain.items['gemini_api_key'], ('g', 'first_unlock'));
    });

    test('iOS: saving over an old-class key is not a duplicate', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      keychain.items['openai_api_key'] = ('old', 'unlocked');
      await platformKeyStore().write('openai_api_key', 'new');
      expect(keychain.items['openai_api_key'], ('new', 'first_unlock'));
    });

    test('Android: the plain store, one plugin call per operation', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final store = platformKeyStore();
      expect(store, isA<FlutterSecureKeyStore>());
      await store.write('k', 'v');
      expect(await store.read('k'), 'v');
      await store.delete('k');
      expect(keychain.calls.map((c) => c.method), ['write', 'read', 'delete']);
    });
  });
}
