// Source screening: URL normalization, official-domain matching, number
// grounding (lane B's rules, re-exported), and the combined check over
// fake / uncited / third-party sources.
import 'package:calorie_tracker/core/restaurant_assist_logic.dart' as core;
import 'package:calorie_tracker/services/assist/clients/citation_check.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _bigMac = 'https://www.mcdonalds.com/us/en-us/product/big-mac.html';

void main() {
  group('normalizeSourceUrl', () {
    final cases = <String?, String?>{
      _bigMac: 'https://mcdonalds.com/us/en-us/product/big-mac.html',
      '$_bigMac?utm_source=openai': 'https://mcdonalds.com/us/en-us/product/big-mac.html',
      '$_bigMac#nutrition': 'https://mcdonalds.com/us/en-us/product/big-mac.html',
      'https://WWW.McDonalds.COM/us/': 'https://mcdonalds.com/us',
      'https://mcdonalds.com': 'https://mcdonalds.com',
      'https://mcdonalds.com./a': 'https://mcdonalds.com/a',
      'HTTPS://www.mcdonalds.com/a': 'https://mcdonalds.com/a',
      '  https://order.chipotle.com/menu//  ': 'https://order.chipotle.com/menu',
      // Not launchable:
      'http://www.mcdonalds.com/us': null,
      'javascript:alert(1)': null,
      'ftp://mcdonalds.com/a': null,
      // Lane B: no port at all, not even the default one.
      'https://mcdonalds.com:443/a': null,
      'https://mcdonalds.com:8443/a': null,
      'https://192.168.1.10/a': null,
      r'https://mcdonalds.com\a': null,
      'https://mcdonalds.com@evil.example/a': null,
      'https://chipötle.com/nutrition': null, // IDN lookalike
      'https://chip%C3%B6tle.com/nutrition': null,
      // Dart would decode %2e in a host into a launchable lookalike.
      'https://chipotle.com%2eevil.com/': null,
      'https://chipotle%2ecom/nutrition': null,
      // A percent-escape in the PATH is fine (and kept as sent).
      'https://mcdonalds.com/menu/big%20mac': 'https://mcdonalds.com/menu/big%20mac',
      'https://mc donalds.com/a': null,
      'https://localhost/a': null,
      '': null,
      null: null,
    };
    for (final e in cases.entries) {
      test('${e.key} → ${e.value}', () {
        expect(normalizeSourceUrl(e.key), e.value);
      });
    }
  });

  test('hostOnDomains: equal or subdomain, never a lookalike', () {
    const d = ['chipotle.com'];
    expect(hostOnDomains('chipotle.com', d), isTrue);
    expect(hostOnDomains('www.chipotle.com', d), isTrue);
    expect(hostOnDomains('order.chipotle.com', d), isTrue);
    expect(hostOnDomains('ORDER.Chipotle.com', d), isTrue);
    expect(hostOnDomains('chipotle-nutrition-calculator.com', d), isFalse);
    expect(hostOnDomains('notchipotle.com', d), isFalse);
    expect(hostOnDomains('chipotle.com.evil.net', d), isFalse);
    expect(hostOnDomains('chipotle.co', d), isFalse);
    expect(hostOnDomains('chipotle.com', const ['https://www.chipotle.com/']),
        isTrue, reason: 'table entries are canonicalized too');
    expect(hostOnDomains('chipotle.com', const ['not a domain']), isFalse);
  });

  test('cleanDomains: canonical, unique, capped at 5', () {
    expect(
        cleanDomains(const [
          'https://www.McDonalds.com/',
          'mcdonalds.com',
          'bad domain',
          'a.com',
          'b.com',
          'c.com',
          'd.com',
          'e.com',
        ]),
        ['mcdonalds.com', 'a.com', 'b.com', 'c.com', 'd.com']);
  });

  test('the screen uses lane B\'s functions, not copies', () {
    expect(normalizeSourceUrl, same(core.normalizeSourceUrl));
    expect(grounded, same(core.grounded));
  });

  test('sourceHost and canonicalDomain', () {
    expect(sourceHost('$_bigMac?x=1'), 'mcdonalds.com');
    expect(sourceHost('http://mcdonalds.com'), isNull);
    expect(canonicalDomain('HTTPS://WWW.Chipotle.com//'), 'chipotle.com');
    expect(canonicalDomain('chipötle.com'), isNull);
    expect(canonicalDomain('chipotle.com:443'), isNull);
  });

  group('grounded', () {
    final rows = <(int, String, bool)>[
      (590, 'Big Mac® | 590 Cal.', true),
      (590, 'Calories 590, Total Fat 34g', true),
      (1050, 'Burrito: 1,050 calories', true),
      (1050, 'Burrito: 1050 calories', true),
      (1050, 'Burrito: 11050 calories', false),
      (1050, 'Burrito: 1050.5 calories', false),
      (1050, 'Burrito: 1,0500', false),
      (590, '5900 Cal', false),
      (590, 'item 2590', false),
      (590, 'ratio 0.590', false),
      (590, 'no numbers here', false),
      (12345, '12,345 kcal', true),
      (0, 'Diet Coke 0 Cal', true),
    ];
    for (final (kcal, text, want) in rows) {
      test('$kcal in "$text" → $want', () {
        expect(grounded(kcal, text), want);
      });
    }
  });

  group('checkSource', () {
    const verbatim = LookupEvidence(
        url: _bigMac, text: 'Big Mac® | 590 Cal. Protein 25g', verbatim: true);

    test('cited + official + grounded passes (query stripped for matching)',
        () {
      final c = checkSource(
        sourceUrl: '$_bigMac?utm_source=openai',
        citedUrls: const [_bigMac],
        evidence: const [verbatim],
        chainDomains: const ['mcdonalds.com'],
        figures: const [590],
      );
      expect(c.passes, isTrue);
      expect(c.reason, 'ok');
      expect(c.normalizedUrl,
          'https://mcdonalds.com/us/en-us/product/big-mac.html');
      expect(c.host, 'mcdonalds.com');
    });

    test('a URL on a cited domain that the search did not return → not cited',
        () {
      final c = checkSource(
        sourceUrl:
            'https://www.mcdonalds.com/us/en-us/product/big-mac-nutrition.html',
        citedUrls: const [_bigMac],
        evidence: const [verbatim],
        chainDomains: const ['mcdonalds.com'],
        figures: const [590],
      );
      expect(c.cited, isFalse);
      expect(c.official, isTrue);
      expect(c.passes, isFalse);
      expect(c.reason, 'source_not_cited');
    });

    test('missing source → not launchable', () {
      final c = checkSource(
          sourceUrl: null,
          citedUrls: const [_bigMac],
          evidence: const [verbatim],
          chainDomains: const ['mcdonalds.com'],
          figures: const [590]);
      expect(c.launchable, isFalse);
      expect(c.reason, 'source_not_launchable');
    });

    test('third-party page: cited but not official', () {
      const third = 'https://www.fastfoodnutrition.org/mcdonalds/big-mac';
      final c = checkSource(
          sourceUrl: third,
          citedUrls: const [third],
          evidence: const [
            LookupEvidence(url: third, text: '563 calories', verbatim: true)
          ],
          chainDomains: const ['mcdonalds.com'],
          figures: const [563]);
      expect(c.cited, isTrue);
      expect(c.official, isFalse);
      expect(c.reason, 'source_not_official');
    });

    test('a number only in the model\'s own span is not grounded', () {
      final c = checkSource(
          sourceUrl: _bigMac,
          citedUrls: const [_bigMac],
          evidence: const [
            LookupEvidence(
                url: _bigMac, text: 'The Big Mac has 590 Cal', verbatim: false)
          ],
          chainDomains: const ['mcdonalds.com'],
          figures: const [590]);
      expect(c.groundedFigures, isEmpty);
      expect(c.modelOnlyFigures, [590]);
      expect(c.reason, 'grounded_by_model_only');
      expect(c.passes, isFalse);
    });

    test('evidence for ANOTHER url does not ground this one', () {
      final c = checkSource(
          sourceUrl: _bigMac,
          citedUrls: const [_bigMac, 'https://www.mcdonalds.com/other'],
          evidence: const [
            LookupEvidence(
                url: 'https://www.mcdonalds.com/other',
                text: '590 Cal',
                verbatim: true)
          ],
          chainDomains: const ['mcdonalds.com'],
          figures: const [590]);
      expect(c.reason, 'figure_not_grounded');
    });

    test('a fabricated figure is caught even when another is grounded', () {
      final c = checkSource(
          sourceUrl: _bigMac,
          citedUrls: const [_bigMac],
          evidence: const [verbatim],
          chainDomains: const ['mcdonalds.com'],
          figures: const [590, 640]);
      expect(c.groundedFigures, [590]);
      expect(c.ungroundedFigures, [640]);
      expect(c.passes, isFalse);
    });

    test('no figures → no pass', () {
      final c = checkSource(
          sourceUrl: _bigMac,
          citedUrls: const [_bigMac],
          evidence: const [verbatim],
          chainDomains: const ['mcdonalds.com']);
      expect(c.reason, 'no_figures');
      expect(c.passes, isFalse);
    });
  });
}
