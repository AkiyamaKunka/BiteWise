/// core/chain_match.dart: BiteWise's own US chain table and the matcher
/// that maps a place or a printed brand onto it (restaurant assist, R2a).
///
/// Only a chain's canonical name from this table ever reaches an AI
/// provider, and an official nutrition source must sit on one of the
/// chain's own domains — so the matcher has to be precise: an unknown,
/// generic or ambiguous name is null. Python twin: restaurant_lookup.py
/// (tests/test_chain_table.py); shared/vectors/restaurant_lookup.json pins
/// the two together.
library;

import 'package:calorie_tracker/core/chain_match.dart';
import 'package:calorie_tracker/core/shared_generated.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _variants(SharedChain c) => [
  c.name,
  ...c.aliases,
  if (c.zhName != null) c.zhName!,
];

void main() {
  group('the table', () {
    test('is large enough and keyed uniquely', () {
      expect(sharedUsChains.length, greaterThanOrEqualTo(250));
      final keys = sharedUsChains.map((c) => c.key).toSet();
      expect(keys.length, sharedUsChains.length);
      expect(sharedUsChainsAsOf, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('every row is a 20+ chain with at least one ASCII domain', () {
      final domainRe = RegExp(r'^[a-z0-9-]+\.[a-z]{2,63}$');
      for (final c in sharedUsChains) {
        expect(c.size, '20_plus', reason: c.key);
        expect(c.domains, isNotEmpty, reason: c.key);
        for (final d in c.domains) {
          expect(domainRe.hasMatch(d), isTrue, reason: '${c.key}: $d');
        }
      }
    });

    test('every name, alias and Chinese name maps back to its own chain', () {
      for (final c in sharedUsChains) {
        for (final v in _variants(c)) {
          expect(matchChain(v), c.key, reason: v);
        }
      }
    });

    test('every domain and its subdomains map to its own chain', () {
      for (final c in sharedUsChains) {
        for (final d in c.domains) {
          expect(matchChain(null, urlHost: d), c.key, reason: d);
          expect(matchChain(null, urlHost: 'www.$d'), c.key, reason: d);
          expect(isChainHost('nutrition.$d', c.key), isTrue, reason: d);
          expect(matchChain(null, urlHost: 'x$d'), isNull, reason: d);
          expect(isChainHost('$d.evil.example', c.key), isFalse, reason: d);
        }
      }
    });
  });

  group('matchChain', () {
    const cases = <(Object?, String?, String?)>[
      // The design's table (R2a tests)
      ('Chipotle Mexican Grill', null, 'chipotle'),
      (null, 'order.chipotle.com', 'chipotle'),
      (null, 'chipotle-nutrition-calculator.com', null),
      ('chipotle-nutrition-calculator.com', null, null),
      ('Panda Express', null, 'panda_express'),
      ("I'm donut ?", null, null),
      ('麦当劳', null, 'mcdonalds'),
      ('肯德基', null, 'kfc'),
      ('星巴克', null, 'starbucks'),
      ('熊猫快餐', null, 'panda_express'),
      // MapKit names from the live probe
      ('Starbucks Coffee Company', null, 'starbucks'),
      ('Popeyes Louisiana Kitchen', null, 'popeyes'),
      ("McDonald's", null, 'mcdonalds'),
      ('Bubba Gump Shrimp Co.', null, 'bubba_gump'),
      ('Ora’s Market', null, null),
      ("Junior's Restaurant", null, null),
      ("John's Famous Hot Dogs", null, null),
      // Normalization
      ('McDonald’s', null, 'mcdonalds'),
      ('MCDONALDS', null, 'mcdonalds'),
      ('ＫＦＣ', null, 'kfc'),
      ('Café Rio', null, 'cafe_rio'),
      ('Fogo de Chão', null, 'fogo_de_chao'),
      ('Cheesecake Factory', null, 'cheesecake_factory'),
      ('Chick fil A', null, 'chick_fil_a'),
      ('Chickfila', null, 'chick_fil_a'),
      ('Wing Stop', null, 'wingstop'),
      // Branch suffixes
      ("McDonald's - Times Square", null, 'mcdonalds'),
      ('Starbucks (Times Sq)', null, 'starbucks'),
      ('麥當勞（時代廣場店）', null, 'mcdonalds'),
      ('Taco Bell Cantina', null, 'taco_bell'),
      // Precision
      ("Jack's Bar", null, null),
      ('Subway Station Cafe', null, null),
      ('BBQ Chicken', null, null),
      ('Pizza', null, null),
      ('', null, null),
      (42, null, null),
      // Hosts
      ('Chipotle', 'www.chipotle.com', 'chipotle'),
      ('Starbucks', 'www.mcdonalds.com', null),
      ('Store #1234', 'restaurants.subway.com', 'subway'),
      (null, 'WWW.STARBUCKS.COM.', 'starbucks'),
      (null, 'notchipotle.com', null),
      (null, 'chipotle.com.evil.example', null),
      (null, 'chipotlé.com', null),
      (null, 'xn--chipotl-dya.com', null),
      (null, 'chipotle.com:443', null),
      (null, 'https://chipotle.com/', null),
      ('www.starbucks.com', null, null),
    ];
    for (final (name, host, expected) in cases) {
      test('$name @ $host -> $expected', () {
        expect(matchChain(name, urlHost: host), expected);
      });
    }
  });

  group('helpers', () {
    test('chainByKey is exact', () {
      expect(chainByKey('chipotle')?.name, 'Chipotle');
      expect(chainByKey('CHIPOTLE'), isNull);
      expect(chainByKey(null), isNull);
    });

    test('isChainHost is per chain', () {
      expect(isChainHost('www.chipotle.com', 'chipotle'), isTrue);
      expect(isChainHost('www.chipotle.com', 'starbucks'), isFalse);
      expect(isChainHost('www.chipotle.com', 'no_such_chain'), isFalse);
      expect(isChainHost(null, 'chipotle'), isFalse);
    });

    test('normalizeHost accepts only plain ASCII host names', () {
      expect(normalizeHost('Order.Chipotle.COM.'), 'order.chipotle.com');
      expect(normalizeHost('chipotle'), isNull);
      expect(normalizeHost('chipotle..com'), isNull);
      expect(normalizeHost('chipotlé.com'), isNull);
      expect(normalizeHost('chipotle.com/menu'), isNull);
      expect(normalizeHost(7), isNull);
    });

    test('chainTokens folds, drops apostrophes and splits CJK', () {
      expect(chainTokens("The Habit Burger Grill"), [
        'habit',
        'burger',
        'grill',
      ]);
      expect(chainTokens('A&W'), ['a', 'and', 'w']);
      expect(chainTokens('85°C Bakery Cafe'), ['85c', 'bakery', 'cafe']);
      expect(chainTokens('麦当劳'), ['麦', '当', '劳']);
      expect(chainTokens('The'), ['the']);
      expect(chainTokens(null), isEmpty);
    });
  });
}
