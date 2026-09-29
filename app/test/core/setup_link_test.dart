import 'package:calorie_tracker/core/setup_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uri link(String qs) => Uri.parse('bitewise://setup?$qs');
  const key = 'k1234567890abcdef';

  test('a well-formed link parses to an origin, the key and the backend', () {
    final l = parseSetupLink(link('server=http%3A%2F%2F10.0.0.7&key=$key'))!;
    expect(l.server, 'http://10.0.0.7');
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
    expect(parseSetupLink(link('server=http%3A%2F%2Fh&key=$key&backend=glm'))!.backend,
        'glm');
    expect(parseSetupLink(link('server=http%3A%2F%2Fh&key=$key&backend=gemini')),
        isNull);
  });

  test('rejects anything that is not a bare http(s) origin', () {
    for (final bad in [
      'ftp://h', 'h', 'http://', 'http://h/api', 'http://h?x=1', 'http://h#f',
      'http://user:pw@h', 'javascript:alert(1)',
    ]) {
      expect(
          parseSetupLink(
              link('server=${Uri.encodeQueryComponent(bad)}&key=$key')),
          isNull,
          reason: bad);
    }
  });

  test('rejects short, whitespace-bearing or missing keys', () {
    expect(parseSetupLink(link('server=http%3A%2F%2Fh&key=short')), isNull);
    expect(parseSetupLink(link('server=http%3A%2F%2Fh&key=has%20space12345')),
        isNull);
    expect(parseSetupLink(link('server=http%3A%2F%2Fh')), isNull);
  });

  test('wrong scheme or host is not a setup link at all', () {
    expect(parseSetupLink(Uri.parse('https://setup?server=http%3A%2F%2Fh&key=$key')),
        isNull);
    expect(parseSetupLink(Uri.parse('bitewise://other?server=http%3A%2F%2Fh&key=$key')),
        isNull);
  });
}
