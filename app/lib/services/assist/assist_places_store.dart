/// The restaurant assist's learned places (design R2c, "Feedback actions",
/// "Storage"; data_contracts §9b): what the user said about the spot a
/// meal photo was taken at, kept as ~100 m cells (core/place_match.dart
/// PlaceCell) in the backup-excluded F1 document 'assist_places':
///
///   {"v": 1,
///    "zones":     [{"cell", "at"}],                      // 180 d, ≤ 100
///    "confirmed": [{"chain_key", "cell", "count", "last"}], // 180 d, ≤ 200
///    "blocked":   [{"chain_key", "cell", "at"}]}          // 180 d, ≤ 200
///
///   * zones: 'Not from a restaurant' — no place match near the cell;
///   * confirmed: 'Correct', or an accepted location suggestion — the only
///     way a location alone can ever apply published numbers;
///   * blocked: 'Wrong restaurant' — that chain is no candidate near the
///     cell.
///
/// The user's latest word about a chain wins near its cell: confirming
/// drops that chain's blocks in the 3×3 cells around, blocking drops its
/// confirmations there. 'Clear learned places' ([clear]) deletes the
/// document.
///
/// Location-shaped data, so it lives only here: never in shared_preferences,
/// the meal database, an export, a backup or a log (the cells' toString
/// says nothing). Reads never throw and come back empty on a missing,
/// corrupt or other-version document; entries past their TTL, with an
/// unreadable cell or a chain key outside BiteWise's table are dropped.
/// Writes never throw either and say whether they landed. The app engine
/// is the only writer (MealAssist and the editor's feedback actions);
/// writes through one instance run one at a time.
library;

import '../../core/chain_match.dart' show chainByKey;
import '../../core/place_match.dart';
import '../local_store.dart';

/// The F1 document's name and schema version.
const String assistPlacesDocument = 'assist_places';
const int assistPlacesVersion = 1;

/// How long a zone, a confirmation (since its last use) or a block lasts.
const Duration assistPlacesTtl = Duration(days: 180);

/// The most entries each list keeps (the newest win).
const int assistPlacesZonesCap = 100;
const int assistPlacesConfirmedCap = 200;
const int assistPlacesBlockedCap = 200;

/// A confirmation's count stops here.
const int assistPlacesMaxCount = 9999;

class AssistPlacesStore {
  AssistPlacesStore(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The app's store (LocalNoBackupStore.platform()).
  factory AssistPlacesStore.platform() =>
      AssistPlacesStore(LocalNoBackupStore.platform());

  final LocalNoBackupStore _store;
  final DateTime Function() _clock;
  Future<void> _tail = Future<void>.value();

  /// What the user taught, past-TTL entries left out; empty when there is
  /// nothing or it cannot be read. Never throws.
  Future<LearnedPlaces> read() async {
    try {
      return (await _load(_clock())).toPlaces();
    } catch (_) {
      return LearnedPlaces.empty;
    }
  }

  /// 'Not from a restaurant' at [cell].
  Future<bool> addZone(PlaceCell cell) => _mutate((doc, at) {
    final wire = cell.wire;
    doc.zones
      ..removeWhere((e) => e['cell'] == wire)
      ..add({'cell': wire, 'at': at});
  });

  /// 'Correct' (or an accepted location suggestion) for [chainKey] at
  /// [cell]: counted, and that chain's blocks near [cell] dropped. False
  /// for a key outside the table.
  Future<bool> confirm(String chainKey, PlaceCell cell) async {
    if (chainByKey(chainKey) == null) return false;
    return _mutate((doc, at) {
      doc.blocked.removeWhere(
        (e) => e['chain_key'] == chainKey && _cellOf(e)?.isNear(cell) == true,
      );
      final wire = cell.wire;
      var count = 0;
      doc.confirmed.removeWhere((e) {
        if (e['chain_key'] != chainKey || e['cell'] != wire) return false;
        count = e['count'] as int;
        return true;
      });
      doc.confirmed.add({
        'chain_key': chainKey,
        'cell': wire,
        'count': count >= assistPlacesMaxCount ? count : count + 1,
        'last': at,
      });
    });
  }

  /// 'Wrong restaurant' for [chainKey] at [cell]: that chain's
  /// confirmations near [cell] dropped. False for a key outside the table.
  Future<bool> block(String chainKey, PlaceCell cell) async {
    if (chainByKey(chainKey) == null) return false;
    return _mutate((doc, at) {
      doc.confirmed.removeWhere(
        (e) => e['chain_key'] == chainKey && _cellOf(e)?.isNear(cell) == true,
      );
      final wire = cell.wire;
      doc.blocked
        ..removeWhere((e) => e['chain_key'] == chainKey && e['cell'] == wire)
        ..add({'chain_key': chainKey, 'cell': wire, 'at': at});
    });
  }

  /// 'Clear learned places': the document is deleted. True when it is
  /// gone. Never throws.
  Future<bool> clear() => _serial(() => _store.delete(assistPlacesDocument));

  Future<bool> _mutate(void Function(_Doc doc, String at) change) =>
      _serial(() async {
        final now = _clock();
        final doc = await _load(now);
        change(doc, now.toUtc().toIso8601String());
        return _store.write(
          assistPlacesDocument,
          doc.toJson(),
          version: assistPlacesVersion,
        );
      });

  /// Runs [task] after every earlier write through this instance; false
  /// when it throws.
  Future<bool> _serial(Future<bool> Function() task) {
    final run = _tail.then((_) => task()).catchError((Object _) => false);
    _tail = run.then((_) {});
    return run;
  }

  Future<_Doc> _load(DateTime now) async => _Doc.decode(
    await _store.read(assistPlacesDocument, version: assistPlacesVersion),
    now,
  );
}

PlaceCell? _cellOf(Map<String, Object?> entry) =>
    PlaceCell.tryParse(entry['cell']);

/// The document's lists, validated and pruned, as plain JSON entries.
final class _Doc {
  _Doc(this.zones, this.confirmed, this.blocked);

  final List<Map<String, Object?>> zones;
  final List<Map<String, Object?>> confirmed;
  final List<Map<String, Object?>> blocked;

  factory _Doc.decode(Map<String, Object?> raw, DateTime now) {
    List<Map<String, Object?>> live(String list, String stamp) =>
        pruneByTtl(raw[list], stamp, assistPlacesTtl, now: now);

    final zones = <Map<String, Object?>>[];
    for (final e in live('zones', 'at')) {
      final cell = _cellOf(e);
      if (cell == null) continue;
      zones.add({'cell': cell.wire, 'at': e['at']});
    }
    final confirmed = <Map<String, Object?>>[];
    for (final e in live('confirmed', 'last')) {
      final key = e['chain_key'];
      final cell = _cellOf(e);
      if (key is! String || chainByKey(key) == null || cell == null) continue;
      final count = e['count'];
      confirmed.add({
        'chain_key': key,
        'cell': cell.wire,
        'count': count is int && count >= 1
            ? (count > assistPlacesMaxCount ? assistPlacesMaxCount : count)
            : 1,
        'last': e['last'],
      });
    }
    final blocked = <Map<String, Object?>>[];
    for (final e in live('blocked', 'at')) {
      final key = e['chain_key'];
      final cell = _cellOf(e);
      if (key is! String || chainByKey(key) == null || cell == null) continue;
      blocked.add({'chain_key': key, 'cell': cell.wire, 'at': e['at']});
    }
    return _Doc(
      _newestPer(zones, (e) => '${e['cell']}', 'at'),
      _newestPer(confirmed, (e) => '${e['chain_key']}|${e['cell']}', 'last'),
      _newestPer(blocked, (e) => '${e['chain_key']}|${e['cell']}', 'at'),
    );
  }

  Map<String, Object?> toJson() => {
    'zones': capNewest(zones, assistPlacesZonesCap, field: 'at'),
    'confirmed': capNewest(confirmed, assistPlacesConfirmedCap, field: 'last'),
    'blocked': capNewest(blocked, assistPlacesBlockedCap, field: 'at'),
  };

  LearnedPlaces toPlaces() {
    final kept = toJson();
    LearnedChainCell chainCell(Object? e) {
      final m = e as Map<String, Object?>;
      return LearnedChainCell(m['chain_key'] as String, _cellOf(m)!);
    }

    return LearnedPlaces(
      zones: List.unmodifiable([
        for (final e in kept['zones'] as List)
          _cellOf(e as Map<String, Object?>)!,
      ]),
      confirmed: List.unmodifiable([
        for (final e in kept['confirmed'] as List) chainCell(e),
      ]),
      blocked: List.unmodifiable([
        for (final e in kept['blocked'] as List) chainCell(e),
      ]),
    );
  }
}

/// One entry per [identity], the one with the newest [stamp] (the later
/// position on a tie), in their original order otherwise.
List<Map<String, Object?>> _newestPer(
  List<Map<String, Object?>> entries,
  String Function(Map<String, Object?>) identity,
  String stamp,
) {
  final keep = <String, int>{};
  for (var i = 0; i < entries.length; i++) {
    final id = identity(entries[i]);
    final j = keep[id];
    if (j == null ||
        !DateTime.parse(
          entries[i][stamp] as String,
        ).isBefore(DateTime.parse(entries[j][stamp] as String))) {
      keep[id] = i;
    }
  }
  final indexes = keep.values.toList()..sort();
  return [for (final i in indexes) entries[i]];
}
