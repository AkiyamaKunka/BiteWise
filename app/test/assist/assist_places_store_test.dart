/// services/assist/assist_places_store.dart: the restaurant assist's learned
/// places in the backup-excluded F1 document 'assist_places' (R2c) — the
/// document's shape, the user's latest word winning near a cell, TTLs and
/// caps, 'Clear learned places', a corrupt or foreign document reading as
/// empty, and no export or import path ever touching it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/place_match.dart';
import 'package:calorie_tracker/services/assist/assist_places_store.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Public landmarks only.
final PlaceCell _capitol = PlaceCell.fromLatLon(43.0747, -89.3842)!;
final PlaceCell _timesSquare = PlaceCell.fromLatLon(40.7580, -73.9851)!;

PlaceCell _shift(PlaceCell from, int dLat, int dLon) {
  final parts = from.wire.split(',');
  return PlaceCell.fromLatLon(
    double.parse(parts[0]) + dLat / 1000,
    double.parse(parts[1]) + dLon / 1000,
  )!;
}

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

void main() {
  late Directory root;
  late File file;
  late DateTime now;

  setUp(() {
    root = Directory.systemTemp.createTempSync('assist_places_test');
    file = File('${root.path}/$localStoreDirName/$assistPlacesDocument.json');
    now = DateTime.utc(2026, 10, 24, 18);
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LocalNoBackupStore local({bool create = true}) => LocalNoBackupStore(
    root: () async => root,
    createMissingDirectory: create,
    clock: () => now,
  );
  AssistPlacesStore places({bool create = true}) =>
      AssistPlacesStore(local(create: create), clock: () => now);

  Map<String, Object?> document() =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  void writeRaw(Object? json) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(json is String ? json : jsonEncode(json));
  }

  String ago(Duration d) => now.subtract(d).toIso8601String();

  test('a missing document is empty, and a read creates nothing', () async {
    final learned = await places().read();
    expect(learned.isEmpty, isTrue);
    expect(file.existsSync(), isFalse);
  });

  test(
    'zones, confirmations and blocks land in the documented shape',
    () async {
      final s = places();
      expect(await s.addZone(_capitol), isTrue);
      expect(await s.confirm('chipotle', _timesSquare), isTrue);
      expect(await s.block('qdoba', _timesSquare), isTrue);
      final at = now.toIso8601String();
      expect(at, endsWith('Z'), reason: 'stamps are UTC instants');
      expect(document(), {
        'v': assistPlacesVersion,
        'zones': [
          {'cell': '43.075,-89.384', 'at': at},
        ],
        'confirmed': [
          {
            'chain_key': 'chipotle',
            'cell': '40.758,-73.985',
            'count': 1,
            'last': at,
          },
        ],
        'blocked': [
          {'chain_key': 'qdoba', 'cell': '40.758,-73.985', 'at': at},
        ],
      });

      final learned = await places().read(); // another instance, same file
      expect(learned.zones, [_capitol]);
      expect(learned.inZone(_shift(_capitol, 1, -1)), isTrue);
      expect(learned.confirmedNear(_timesSquare), {'chipotle'});
      expect(learned.blockedNear(_shift(_timesSquare, -1, 0)), {'qdoba'});
      expect(learned.blockedNear(_capitol), isEmpty);
    },
  );

  test('confirming again counts up on one entry and refreshes it', () async {
    final s = places();
    await s.confirm('chipotle', _capitol);
    now = now.add(const Duration(days: 3));
    await s.confirm('chipotle', _capitol);
    final confirmed = document()['confirmed'] as List;
    expect(confirmed, [
      {
        'chain_key': 'chipotle',
        'cell': '43.075,-89.384',
        'count': 2,
        'last': now.toIso8601String(),
      },
    ]);
  });

  test('a zone added twice is one entry, refreshed', () async {
    final s = places();
    await s.addZone(_capitol);
    now = now.add(const Duration(hours: 5));
    await s.addZone(_capitol);
    expect(document()['zones'], [
      {'cell': '43.075,-89.384', 'at': now.toIso8601String()},
    ]);
  });

  test("the user's latest word about a chain wins near its cell", () async {
    final s = places();
    await s.block('chipotle', _capitol);
    await s.block('chipotle', _shift(_capitol, 5, 5)); // another spot
    await s.block('qdoba', _capitol); // another chain
    await s.confirm('chipotle', _shift(_capitol, 1, 0));
    var learned = await s.read();
    expect(learned.blockedNear(_capitol), {'qdoba'});
    expect(learned.blockedNear(_shift(_capitol, 5, 5)), {'chipotle'});
    expect(learned.confirmedNear(_capitol), {'chipotle'});

    await s.block('chipotle', _shift(_capitol, 0, -1));
    learned = await s.read();
    expect(learned.confirmedNear(_capitol), isEmpty);
    expect(learned.blockedNear(_capitol), {'qdoba', 'chipotle'});
  });

  test('a chain key outside the table is refused and writes nothing', () async {
    final s = places();
    expect(await s.confirm('not_a_chain', _capitol), isFalse);
    expect(await s.block('', _capitol), isFalse);
    expect(file.existsSync(), isFalse);
  });

  test('entries older than 180 days are pruned on read and on write', () async {
    writeRaw({
      'v': assistPlacesVersion,
      'zones': [
        {'cell': '43.075,-89.384', 'at': ago(const Duration(days: 181))},
        {'cell': '40.758,-73.985', 'at': ago(const Duration(days: 179))},
      ],
      'confirmed': [
        {
          'chain_key': 'chipotle',
          'cell': '43.075,-89.384',
          'count': 4,
          'last': ago(const Duration(days: 200)),
        },
        {
          'chain_key': 'qdoba',
          'cell': '43.075,-89.384',
          'count': 2,
          'last': ago(const Duration(days: 10)),
        },
      ],
      'blocked': [
        {
          'chain_key': 'subway',
          'cell': '43.075,-89.384',
          'at': ago(const Duration(days: 180, minutes: 1)),
        },
        {
          'chain_key': 'cava',
          'cell': '43.075,-89.384',
          'at': ago(const Duration(days: 1)),
        },
      ],
    });
    final learned = await places().read();
    expect(learned.zones, [_timesSquare]);
    expect(learned.confirmedNear(_capitol), {'qdoba'});
    expect(learned.blockedNear(_capitol), {'cava'});

    await places().addZone(_shift(_capitol, 9, 9));
    final doc = document();
    expect((doc['zones'] as List).map((e) => (e as Map)['cell']), [
      '40.758,-73.985',
      '43.084,-89.375',
    ]);
    expect((doc['confirmed'] as List).map((e) => (e as Map)['chain_key']), [
      'qdoba',
    ]);
    expect((doc['blocked'] as List).map((e) => (e as Map)['chain_key']), [
      'cava',
    ]);
  });

  test('a confirmation in use lives on past 180 days from its first', () async {
    final s = places();
    await s.confirm('chipotle', _capitol);
    now = now.add(const Duration(days: 170));
    await s.confirm('chipotle', _capitol);
    now = now.add(const Duration(days: 170));
    expect((await s.read()).confirmedNear(_capitol), {'chipotle'});
    now = now.add(const Duration(days: 11));
    expect((await s.read()).confirmedNear(_capitol), isEmpty);
  });

  test('each list keeps only its newest entries', () async {
    final base = now.subtract(const Duration(days: 30));
    String at(int i) => base.add(Duration(minutes: i)).toIso8601String();
    String cell(int i) => _shift(_capitol, i * 3, 0).wire;
    writeRaw({
      'v': assistPlacesVersion,
      'zones': [
        for (var i = 0; i < 105; i++) {'cell': cell(i), 'at': at(i)},
      ],
      'confirmed': [
        for (var i = 0; i < 205; i++)
          {'chain_key': 'chipotle', 'cell': cell(i), 'count': 1, 'last': at(i)},
      ],
      'blocked': [
        for (var i = 0; i < 205; i++)
          {'chain_key': 'qdoba', 'cell': cell(i), 'at': at(i)},
      ],
    });
    final learned = await places().read();
    expect(learned.zones, hasLength(assistPlacesZonesCap));
    expect(learned.confirmed, hasLength(assistPlacesConfirmedCap));
    expect(learned.blocked, hasLength(assistPlacesBlockedCap));
    expect(learned.zones.first.wire, cell(5), reason: 'the oldest 5 go');

    await places().addZone(_timesSquare);
    final doc = document();
    expect(doc['zones'], hasLength(assistPlacesZonesCap));
    expect((doc['zones'] as List).last, {
      'cell': _timesSquare.wire,
      'at': now.toIso8601String(),
    });
    expect((doc['zones'] as List).first, {'cell': cell(6), 'at': at(6)});
    expect(doc['confirmed'], hasLength(assistPlacesConfirmedCap));
    expect(doc['blocked'], hasLength(assistPlacesBlockedCap));
  });

  test('clear wipes everything', () async {
    final s = places();
    await s.addZone(_capitol);
    await s.confirm('chipotle', _timesSquare);
    expect(await s.clear(), isTrue);
    expect(file.existsSync(), isFalse);
    expect((await s.read()).isEmpty, isTrue);
    expect(await s.clear(), isTrue, reason: 'nothing to clear is fine');
  });

  test('a corrupt or other-version document reads as empty', () async {
    for (final raw in [
      '{"v":1,"zones":[{"cell":"43.0',
      'not json',
      '[1,2]',
      jsonEncode({
        'v': 2,
        'zones': [
          {'cell': '43.075,-89.384', 'at': now.toIso8601String()},
        ],
      }),
    ]) {
      writeRaw(raw);
      expect((await places().read()).isEmpty, isTrue, reason: raw);
    }
    // A write over a corrupt document starts afresh.
    writeRaw('{"v":1,"zones":[{"cell":"43.0');
    expect(await places().addZone(_capitol), isTrue);
    expect((await places().read()).zones, [_capitol]);
  });

  test('entries off the schema are dropped, duplicates collapse', () async {
    writeRaw({
      'v': assistPlacesVersion,
      'zones': [
        'cell',
        {'cell': '43.075,-89.384'}, // no stamp
        {'cell': '43.0750,-89.384', 'at': ago(Duration.zero)},
        {'cell': 43.075, 'at': ago(Duration.zero)},
        {'cell': '40.758,-73.985', 'at': ago(const Duration(days: 2))},
        {'cell': '40.758,-73.985', 'at': ago(const Duration(days: 1))},
      ],
      'confirmed': [
        {
          'chain_key': 'no_such_chain',
          'cell': '43.075,-89.384',
          'count': 1,
          'last': ago(Duration.zero),
        },
        {'chain_key': 7, 'cell': '43.075,-89.384', 'last': ago(Duration.zero)},
        {'chain_key': 'chipotle', 'cell': 'here', 'last': ago(Duration.zero)},
        {
          'chain_key': 'qdoba',
          'cell': '43.075,-89.384',
          'count': 'many',
          'last': ago(const Duration(hours: 2)),
        },
        {
          'chain_key': 'qdoba',
          'cell': '43.075,-89.384',
          'count': -4,
          'last': ago(const Duration(hours: 3)),
        },
        {
          'chain_key': 'cava',
          'cell': '43.075,-89.384',
          'count': 1000000,
          'last': ago(Duration.zero),
        },
      ],
      'blocked': {'chain_key': 'subway'},
    });
    final learned = await places().read();
    expect(learned.zones, [_timesSquare]);
    expect(learned.confirmedNear(_capitol), {'qdoba', 'cava'});
    expect(learned.blocked, isEmpty);

    await places().addZone(_capitol);
    final doc = document();
    expect(doc['zones'], [
      {'cell': '40.758,-73.985', 'at': ago(const Duration(days: 1))},
      {'cell': '43.075,-89.384', 'at': now.toIso8601String()},
    ]);
    expect(doc['confirmed'], [
      {
        'chain_key': 'qdoba',
        'cell': '43.075,-89.384',
        'count': 1,
        'last': ago(const Duration(hours: 2)),
      },
      {
        'chain_key': 'cava',
        'cell': '43.075,-89.384',
        'count': assistPlacesMaxCount,
        'last': ago(Duration.zero),
      },
    ]);
    expect(doc['blocked'], isEmpty);
  });

  test('writes through one store run one at a time: none is lost', () async {
    final s = places();
    final results = await Future.wait([
      s.addZone(_capitol),
      s.confirm('chipotle', _timesSquare),
      s.block('qdoba', _timesSquare),
      s.confirm('chipotle', _timesSquare),
      s.addZone(_shift(_capitol, 4, 4)),
    ]);
    expect(results, everyElement(isTrue));
    final doc = document();
    expect(doc['zones'], hasLength(2));
    expect(doc['confirmed'], [
      {
        'chain_key': 'chipotle',
        'cell': _timesSquare.wire,
        'count': 2,
        'last': now.toIso8601String(),
      },
    ]);
    expect(doc['blocked'], hasLength(1));
  });

  test(
    'without its directory (iOS before launch made it) writes refuse',
    () async {
      final s = places(create: false);
      expect(await s.addZone(_capitol), isFalse);
      expect(await s.confirm('chipotle', _capitol), isFalse);
      expect((await s.read()).isEmpty, isTrue);
      expect(
        Directory('${root.path}/$localStoreDirName').existsSync(),
        isFalse,
      );
    },
  );

  test('export and import code never reference the learned places', () {
    // Exports (MealsDao.exportJson) carry the meal database only; the
    // learned places are device-only, backup-excluded and never exported
    // or imported (design "Storage").
    final lib = Directory('${_appRoot().path}/lib');
    final files = <String, String>{};
    for (final f in lib.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final rel = f.path.substring(lib.parent.path.length + 1);
      final src = f.readAsStringSync();
      if (rel.startsWith('lib/data/') ||
          rel.startsWith('lib/services/report/') ||
          src.contains('exportJson') ||
          src.contains('importJson')) {
        files[rel] = src;
      }
    }
    expect(
      files.keys,
      containsAll([
        'lib/data/meals_dao_impl.dart',
        'lib/data/meals_logic.dart',
        'lib/services/report/builders.dart',
        'lib/ui/screens/settings/data_section.dart',
      ]),
    );
    for (final MapEntry(key: path, value: src) in files.entries) {
      for (final needle in [
        'assist_places',
        'AssistPlacesStore',
        'LearnedPlaces',
        'PlaceCell',
        'place_match',
        'local_store',
        'LocalNoBackupStore',
        localStoreDirName,
      ]) {
        expect(src.contains(needle), isFalse, reason: '$path: $needle');
      }
    }
  });
}
