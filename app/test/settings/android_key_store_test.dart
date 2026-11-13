// Android's key store reads forgive a broken store (2026-11-13).
//
// flutter_secure_storage keeps each API key in a shared_prefs file,
// encrypted with a key that lives in this phone's Android Keystore. A copy
// of that file whose Keystore key is gone (restored or transferred onto
// another phone, or kept through an uninstall that keeps the app's data
// without it) can never be read again. The plugin's own resetOnError
// covers only its key-mismatch exceptions; any other failure reached
// AppSettings.load, main.dart then showed StartupErrorApp, and its Retry
// could never succeed. On Android a key that cannot be read is now no key, so the app
// starts and asks for it. Only reads: a failed save or delete still fails.
// iOS keeps MigratingKeyStore exactly as it was (owner rule: no keychain
// changes), where a locked phone's failed read MUST propagate.
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// A secret-looking value; it must never reach a log line.
const _secret = 'sk-test-DO-NOT-LOG-0123456789';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, String> stored;
  late Set<String> broken;
  late List<MethodCall> calls;
  late List<String> logged;
  late DebugPrintCallback savedPrint;

  setUp(() {
    stored = {};
    broken = {};
    calls = [];
    logged = [];
    savedPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        logged.add(message ?? '');
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final key = (call.arguments as Map)['key'] as String?;
      switch (call.method) {
        case 'read':
          if (broken.contains(key)) {
            // What the plugin sends for a store it cannot decrypt: its
            // message and stack trace, which could quote anything.
            throw PlatformException(
                code: 'Exception encountered',
                message: 'javax.crypto.AEADBadTagException $_secret',
                details: 'java.security.KeyStoreException at $_secret');
          }
          return stored[key];
        case 'write':
          if (broken.contains(key)) {
            throw PlatformException(code: 'Exception encountered');
          }
          stored[key!] = (call.arguments as Map)['value'] as String;
          return null;
        case 'delete':
          if (broken.contains(key)) {
            throw PlatformException(code: 'Exception encountered');
          }
          stored.remove(key);
          return null;
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
    debugPrint = savedPrint;
  });

  Future<AppSettings> load() async {
    SharedPreferences.setMockInitialValues({});
    return AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: platformKeyStore());
  }

  group('platformKeyStore', () {
    test('iOS still gets MigratingKeyStore over the same two stores', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      for (final migrate in [true, false]) {
        final store = platformKeyStore(migrate: migrate);
        expect(store, isA<MigratingKeyStore>());
        store as MigratingKeyStore;
        expect(store.migrate, migrate);
        expect(
            identical(
                store.primary,
                const FlutterSecureKeyStore(
                    FlutterSecureStorage(iOptions: keychainIOSOptions))),
            isTrue,
            reason: 'primary: the first_unlock keychain class, unchanged');
        expect(identical(store.legacy, const FlutterSecureKeyStore()), isTrue,
            reason: 'legacy: the plugin default, unchanged');
        expect(store.primary, isNot(isA<AndroidSecureKeyStore>()));
        expect(store.legacy, isNot(isA<AndroidSecureKeyStore>()));
      }
    });

    test('Android gets the plain store with forgiving reads', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final migrate in [true, false]) {
        final store = platformKeyStore(migrate: migrate);
        expect(store, isA<AndroidSecureKeyStore>());
        expect(store, isA<FlutterSecureKeyStore>());
        expect(store, isNot(isA<MigratingKeyStore>()));
      }
    });

    test('other platforms keep the plain store', () {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        final store = platformKeyStore();
        expect(store, isA<FlutterSecureKeyStore>(), reason: '$platform');
        expect(store, isNot(isA<AndroidSecureKeyStore>()), reason: '$platform');
      }
    });
  });

  group('Android', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('settings load with every key unreadable: no keys, no startup '
        'error', () async {
      for (final key in [
        'gemini_api_key',
        'openai_api_key',
        'anthropic_api_key',
        'server_api_key',
        'qwen_api_key',
        'doubao_api_key',
        'glm_api_key',
        'deepseek_api_key',
        'xai_api_key',
        'openrouter_api_key',
      ]) {
        stored[key] = _secret;
        broken.add(key);
      }
      final settings = await load();
      expect(settings.geminiApiKey, isNull);
      expect(settings.openaiApiKey, isNull);
      expect(settings.anthropicApiKey, isNull);
      expect(settings.serverApiKey, isNull);
      expect(settings.qwenApiKey, isNull);
      expect(settings.doubaoApiKey, isNull);
      expect(settings.glmApiKey, isNull);
      expect(settings.deepseekApiKey, isNull);
      expect(settings.xaiApiKey, isNull);
      expect(settings.openrouterApiKey, isNull);
      expect(settings.activeApiKey, isNull);
      // One diagnostics line per unreadable key, and none quotes the
      // value, the plugin's message or its stack trace.
      expect(logged, hasLength(10));
      for (final line in logged) {
        expect(line, isNot(contains(_secret)));
        expect(line, isNot(contains('AEADBadTagException')));
        expect(line, isNot(contains('KeyStoreException')));
        expect(line, contains('could not be read'));
      }
      // Nothing was deleted or rewritten: a key that failed to read once
      // is still there for a later read.
      expect(calls.map((c) => c.method).toSet(), {'read'});
      expect(stored['gemini_api_key'], _secret);
    });

    test('one unreadable key hides only itself, and a readable one is '
        'never logged', () async {
      stored['gemini_api_key'] = 'broken-value';
      broken.add('gemini_api_key');
      stored['openai_api_key'] = _secret;
      final settings = await load();
      expect(settings.geminiApiKey, isNull);
      expect(settings.openaiApiKey, _secret);
      expect(logged, hasLength(1));
      expect(logged.single, contains('gemini_api_key'));
      expect(logged.join('\n'), isNot(contains(_secret)));
      expect(logged.join('\n'), isNot(contains('broken-value')));
    });

    test('a store that reads fine logs nothing and behaves as before',
        () async {
      final store = platformKeyStore();
      await store.write('k', _secret);
      expect(await store.read('k'), _secret);
      await store.delete('k');
      expect(await store.read('k'), isNull);
      expect(calls.map((c) => c.method), ['write', 'read', 'delete', 'read']);
      expect(logged, isEmpty);
    });

    test('a failed save or delete still fails', () async {
      broken.add('k');
      final store = platformKeyStore();
      await expectLater(
          store.write('k', _secret), throwsA(isA<PlatformException>()));
      await expectLater(store.delete('k'), throwsA(isA<PlatformException>()));
      expect(logged.join('\n'), isNot(contains(_secret)));
    });
  });
}
