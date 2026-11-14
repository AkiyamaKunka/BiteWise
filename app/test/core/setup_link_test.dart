import 'package:calorie_tracker/core/server_transport.dart';
import 'package:calorie_tracker/core/setup_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uri link(String qs) => Uri.parse('bitewise://setup?$qs');
  const key = 'k1234567890abcdef';
  tearDown(() => debugRequireHttpsServerOverride = null);

  test('a well-formed link parses to an origin, the key and the backend', () {
    final l = parseSetupLink(link('server=https%3A%2F%2F10.0.0.7&key=$key'))!;
    expect(l.server, 'https://10.0.0.7');
    expect(l.key, key);
    expect(l.backend, 'claude', reason: 'default');
    expect(l.keyTail, 'cdef');
  });

  test('explicit port and https survive; a trailing slash is dropped', () {
    expect(
        parseSetupLink(link('server=https%3A%2F%2Fh.example%3A8443%2F&key=$key'))!
            .server,
        'https://h.example:8443');
  });

  test('backend is validated', () {
    expect(parseSetupLink(link('server=https%3A%2F%2Fh&key=$key&backend=glm'))!.backend,
        'glm');
    expect(parseSetupLink(link('server=https%3A%2F%2Fh&key=$key&backend=gemini')),
        isNull);
  });

  // Both switch positions: with plain http refused, an http:// variant
  // would be null for that reason alone, so each shape is tried as https
  // too, and with the switch off as http.
  for (final require in [true, false]) {
    test('rejects anything that is not a bare http(s) origin '
        '(https switch ${require ? 'on' : 'off'})', () {
      debugRequireHttpsServerOverride = require;
      for (final bad in [
        'ftp://h', 'h', 'http://', 'http://h/api', 'http://h?x=1', 'http://h#f',
        'http://user:pw@h', 'javascript:alert(1)',
        'https://', 'https://h/api', 'https://h?x=1', 'https://h#f',
        'https://user:pw@h',
      ]) {
        expect(
            parseSetupLink(
                link('server=${Uri.encodeQueryComponent(bad)}&key=$key')),
            isNull,
            reason: bad);
        expect(
            setupLinkNeedsHttps(
                link('server=${Uri.encodeQueryComponent(bad)}&key=$key')),
            isFalse,
            reason: '$bad is malformed, not "needs https"');
      }
    });
  }

  test('rejects short, whitespace-bearing or missing keys', () {
    expect(parseSetupLink(link('server=https%3A%2F%2Fh&key=short')), isNull);
    expect(parseSetupLink(link('server=https%3A%2F%2Fh&key=has%20space12345')),
        isNull);
    expect(parseSetupLink(link('server=https%3A%2F%2Fh')), isNull);
  });

  group('a plain http:// server (owner decision 2026-11-13)', () {
    setUp(() => debugRequireHttpsServerOverride = true);
    final httpLink = link('server=http%3A%2F%2F10.0.0.7&key=$key');

    test('switch on: refused, and said as "needs https"', () {
      expect(parseSetupLink(httpLink), isNull);
      expect(setupLinkNeedsHttps(httpLink), isTrue);
      final upper = link('server=HTTP%3A%2F%2Fh.example%3A5000&key=$key');
      expect(parseSetupLink(upper), isNull);
      expect(setupLinkNeedsHttps(upper), isTrue);
    });

    test('switch on: a malformed http link is still just invalid', () {
      expect(setupLinkNeedsHttps(link('server=http%3A%2F%2Fh&key=short')),
          isFalse);
      expect(
          setupLinkNeedsHttps(
              link('server=http%3A%2F%2Fh&key=$key&backend=gemini')),
          isFalse);
      expect(setupLinkNeedsHttps(Uri.parse('bitewise://other?server=http%3A%2F%2Fh&key=$key')),
          isFalse);
    });

    test('switch on: https passes and is not "needs https"', () {
      final ok = link('server=https%3A%2F%2F10.0.0.7&key=$key');
      expect(parseSetupLink(ok)!.server, 'https://10.0.0.7');
      expect(setupLinkNeedsHttps(ok), isFalse);
    });

    test('switch on: a debug build (this test run) keeps http:// to this '
        'device', () {
      final local = link('server=http%3A%2F%2F127.0.0.1%3A5000&key=$key');
      expect(parseSetupLink(local)!.server, 'http://127.0.0.1:5000');
      expect(setupLinkNeedsHttps(local), isFalse);
    });

    test('switch off: accepted as before', () {
      debugRequireHttpsServerOverride = false;
      final l = parseSetupLink(httpLink)!;
      expect(l.server, 'http://10.0.0.7');
      expect(setupLinkNeedsHttps(httpLink), isFalse);
    });
  });

  test('wrong scheme or host is not a setup link at all', () {
    expect(parseSetupLink(Uri.parse('https://setup?server=http%3A%2F%2Fh&key=$key')),
        isNull);
    expect(parseSetupLink(Uri.parse('bitewise://other?server=http%3A%2F%2Fh&key=$key')),
        isNull);
  });

  test('only the bitewise scheme counts as ours, case-insensitively', () {
    expect(isSetupLinkScheme(link('server=http%3A%2F%2Fh&key=$key')), isTrue);
    expect(isSetupLinkScheme(Uri.parse('BITEWISE://setup?key=$key')), isTrue);
    // The iOS share extension's hand-off to the host app (receive_sharing_intent).
    expect(
        isSetupLinkScheme(
            Uri.parse('ShareMedia-dev.calorietracker.calorieTracker:share')),
        isFalse);
    expect(isSetupLinkScheme(Uri.parse('https://setup?key=$key')), isFalse);
  });
}
