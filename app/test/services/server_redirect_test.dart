// Review of the privacy lane, finding 3, on real sockets: a server that
// answers 303 See Other with an http:// Location. dart:io follows a
// redirect by itself and copies every header but Authorization and Cookie,
// so the X-API-Key went to the http:// address in clear and the reply read
// there was taken as the server's. Every request to the user's own server
// now has redirects off (services/server_http_client.dart).
//
// Both listeners are plain http on this machine's loopback, the one http
// a debug build (this test run) may use, so no certificate is needed: the
// mechanism, dart:io following the redirect with the key, is the same one
// an https:// server redirecting to http:// set off. No test binding here
// on purpose: it replaces HttpClient with one that answers 400.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/ai_consent.dart' show aiConsentRoute;
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/server_lookup_client.dart';
import 'package:calorie_tracker/services/garmin_client.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;

void main() {
  test('a 303 to another address is never followed: the key goes nowhere '
      'else, and that reply is never the answer', () async {
    final leak = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final leaked = <String>[];
    leak.listen((req) async {
      leaked.add('${req.method} ${req.uri} '
          'key=${req.headers.value('x-api-key')}');
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'ok': true,
          'analysis': {'is_food': true, 'total_calories': 1},
          'analyzed_by': 'claude',
          'available': true,
          'steps': 1,
          'claude_login': 'token',
        }));
      await req.response.close();
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final asked = <String>[];
    server.listen((req) async {
      asked.add(req.uri.path);
      await req.drain<void>();
      req.response
        ..statusCode = HttpStatus.seeOther
        ..headers.set('location', 'http://127.0.0.1:${leak.port}/leak');
      await req.response.close();
    });
    addTearDown(() async {
      await leak.close(force: true);
      await server.close(force: true);
    });

    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: MemoryKeyStore());
    await s.setProvider(AiProvider.server);
    await s.setServerBaseUrl('http://127.0.0.1:${server.port}');
    await s.setServerApiKey('SECRET-upload-key');
    await s.setAiConsent(aiConsentRoute('server', 'claude'), granted: true);
    final client = IOClient(HttpClient());
    addTearDown(client.close);
    final a = ServerAnalyzer(s,
        client: client, normalizer: (b) async => b, sleep: (_) async {});

    final keyTest = await a.validateKey('SECRET-upload-key');
    final photo = await a.analyzePhoto(Uint8List.fromList([1, 2, 3]));
    final login = await a.serverLoginState();
    final garmin = await makeGarminDailyFetch(s, client: client)('2026-11-13');
    final lookups = ServerLookupClient(s, client: client);
    final support = lookups.lookupSupport();
    await lookups.submit(
        LookupRequest.compose({
          'items': [
            {'name': 'Big Mac', 'qty': 1, 'brand': "McDonald's"}
          ],
          'chains': ['mcdonalds'],
        }),
        expectedRecipient: support.recipient,
        expectedRecipientStamp: support.recipientStamp);

    expect(leaked, isEmpty, reason: 'the redirect target got nothing');
    expect(asked, containsAll(['/api/auth_check', '/api/analyze_photo',
        '/api/garmin_daily', '/api/restaurant_lookup']));
    expect(keyTest, isNotNull, reason: 'a 3xx is not the server saying OK');
    expect(photo.analysis, isNull);
    expect(login, isNot('token'));
    expect(garmin, isNull);
  });
}
