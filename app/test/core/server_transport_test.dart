// The https switch for the user's own server (core/server_transport.dart):
// the owner's decision (2026-11-13) is to refuse plain http everywhere, so
// it ships ON; the rules below hold in both positions, and the release
// rule (no loopback exception) is pinned with debugBuild: false.
import 'package:calorie_tracker/core/server_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugRequireHttpsServerOverride = null);

  // THE pin: the only test that fails when kRequireHttpsServer is flipped.
  // Every other test of the switch sets debugRequireHttpsServerOverride
  // and covers both positions.
  test('the switch ships on: plain http is refused (owner, 2026-11-13)', () {
    expect(kRequireHttpsServer, isTrue);
    expect(requireHttpsServer, isTrue);
  });

  test('the override wins over the const, both ways', () {
    debugRequireHttpsServerOverride = false;
    expect(requireHttpsServer, isFalse);
    debugRequireHttpsServerOverride = true;
    expect(requireHttpsServer, isTrue);
  });

  test('an http:// address is cleartext, in any letter case', () {
    expect(isCleartextServerUrl('http://10.0.0.5'), isTrue);
    expect(isCleartextServerUrl('  HTTP://h.example:5000 '), isTrue);
    expect(isCleartextServerUrl('https://h.example'), isFalse);
    expect(isCleartextServerUrl(''), isFalse);
    expect(isCleartextServerUrl('h.example'), isFalse);
  });

  test('loopback is localhost, 127.0.0.0/8 and ::1 only', () {
    for (final url in [
      'http://localhost:5000',
      'http://LOCALHOST',
      'http://127.0.0.1:5000',
      'http://127.8.9.10',
      'http://[::1]:8080',
    ]) {
      expect(isLoopbackServerUrl(url), isTrue, reason: url);
    }
    for (final url in [
      'http://10.0.0.5',
      'http://127.0.0.1.example.com',
      'http://localhost.example.com',
      'http://128.0.0.1',
      'http://[::2]',
      '',
    ]) {
      expect(isLoopbackServerUrl(url), isFalse, reason: url);
    }
  });

  group('switch ON (the shipped value)', () {
    test('everything that is not https:// is refused, in a release build',
        () {
      for (final url in [
        'http://10.0.0.5',
        'HTTP://h.example',
        ' http://h.example:5000/ ',
        'http://127.0.0.1:5000',
        'http://localhost',
        '10.0.0.5:5000',
        'h.example',
        'ftp://h.example',
      ]) {
        expect(serverAddressRefused(url, require: true, debugBuild: false),
            isTrue,
            reason: url);
      }
    });

    test('https:// passes, and an empty address is not "refused" (it is '
        'missing, said on its own)', () {
      for (final url in ['https://h.example', ' HTTPS://10.0.0.5:8443 ', '']) {
        expect(serverAddressRefused(url, require: true, debugBuild: false),
            isFalse,
            reason: url);
      }
    });

    test('a debug build keeps http:// to this device only', () {
      expect(
          serverAddressRefused('http://127.0.0.1:5000',
              require: true, debugBuild: true),
          isFalse);
      expect(
          serverAddressRefused('http://localhost:5000',
              require: true, debugBuild: true),
          isFalse);
      expect(
          serverAddressRefused('http://10.0.0.5',
              require: true, debugBuild: true),
          isTrue);
      expect(
          serverAddressRefused('localhost:5000',
              require: true, debugBuild: true),
          isTrue,
          reason: 'no scheme: not an http:// address at all');
    });

    test('without require:, it reads the switch', () {
      debugRequireHttpsServerOverride = true;
      expect(serverAddressRefused('http://10.0.0.5'), isTrue);
      debugRequireHttpsServerOverride = false;
      expect(serverAddressRefused('http://10.0.0.5'), isFalse);
    });
  });

  group('switch OFF', () {
    test('nothing is refused', () {
      for (final url in ['http://10.0.0.5', 'h.example', 'https://h']) {
        expect(serverAddressRefused(url, require: false, debugBuild: false),
            isFalse,
            reason: url);
      }
    });
  });

  test('the refusal line names the server address (user state, the photo '
      'kept) and is recognised', () {
    expect(kServerNeedsHttpsMessage.toLowerCase(), contains('server address'));
    expect(isServerNeedsHttpsMessage(kServerNeedsHttpsMessage), isTrue);
    expect(isServerNeedsHttpsMessage('Could not reach the server.'), isFalse);
    expect(isServerNeedsHttpsMessage(null), isFalse);
  });
}
