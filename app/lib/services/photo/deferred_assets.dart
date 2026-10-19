/// Photos the iOS background run keeps deferring (2026-10-19).
///
/// The headless engine defers a photo it cannot turn into upload bytes
/// (PhotoPipeline.deferUndecodable): released, retryable, so the frontier
/// waits in front of it for the app, which has every decoder. Until the
/// app next opened, EVERY background run met the same photo first and
/// deferred it again — one odd file froze the watermark, and every photo
/// shot after it waited behind it.
///
/// So the run notes each deferral here, and a photo deferred
/// [deferralsBeforePassOver] times is passed over by later background runs:
/// counted covered for the watermark without being read. Nothing is written
/// to the ledger — not failed, not covered — so the app's lookback
/// catch-up still offers it, and a verdict from either engine removes the
/// entry.
///
/// Asset ids, counts and the first deferral's time only. Both engines
/// rewrite the list (read, change, write); two writes interleaving can at
/// worst lose one count or one removal, and either only delays the pass
/// over or keeps a harmless entry until the cap drops it.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A JSON list of {id, n, first}.
const String deferredAssetsPrefsKey = 'background.deferred_assets_v1';

/// How many photos are tracked; past it the earliest-deferred goes.
const int deferredAssetsKept = 50;

/// Deferrals after which later background runs pass a photo over.
const int deferralsBeforePassOver = 2;

class DeferredAsset {
  const DeferredAsset(this.id, this.count, this.firstSeen);
  final String id;
  final int count;

  /// The first deferral (UTC).
  final DateTime firstSeen;

  Map<String, Object?> toJson() =>
      {'id': id, 'n': count, 'first': firstSeen.toUtc().toIso8601String()};

  static DeferredAsset? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final n = json['n'];
    final first = DateTime.tryParse('${json['first']}');
    if (id is! String || id.isEmpty || n is! int || n < 1 || first == null) {
      return null;
    }
    return DeferredAsset(id, n, first);
  }
}

/// Parses the stored list; unreadable entries are skipped.
List<DeferredAsset> decodeDeferredAssets(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  try {
    final list = jsonDecode(stored);
    if (list is! List) return const [];
    return [for (final e in list) ?DeferredAsset.fromJson(e)];
  } catch (_) {
    return const [];
  }
}

/// The background run's view: loaded once at its start, so a photo is
/// passed over only by runs AFTER the one that deferred it the second
/// time. Writes never throw — bookkeeping must not take the scan down.
class DeferredAssets {
  DeferredAssets._(this._prefs, this._clock, List<DeferredAsset> entries)
      : _passOver = {
          for (final e in entries)
            if (e.count >= deferralsBeforePassOver) e.id,
        },
        _known = {for (final e in entries) e.id};

  final SharedPreferences _prefs;
  final DateTime Function() _clock;
  final Set<String> _passOver;

  /// Ids with an entry, as far as this run knows: a verdict for any other
  /// photo (nearly all of them) costs no store access.
  final Set<String> _known;

  static Future<DeferredAssets> load(SharedPreferences prefs,
      {DateTime Function()? clock}) async {
    try {
      await prefs.reload();
    } catch (_) {}
    return DeferredAssets._(prefs, clock ?? DateTime.now,
        decodeDeferredAssets(prefs.getString(deferredAssetsPrefsKey)));
  }

  /// Whether this run counts [assetId] covered without reading it.
  bool passOver(String assetId) => _passOver.contains(assetId);

  /// This run deferred [assetId] (again).
  Future<void> deferred(String assetId) {
    _known.add(assetId);
    return _rewrite(_prefs, (list) {
        final i = list.indexWhere((e) => e.id == assetId);
        if (i >= 0) {
          final e = list[i];
          list[i] = DeferredAsset(e.id, e.count + 1, e.firstSeen);
        } else {
          list.add(DeferredAsset(assetId, 1, _clock().toUtc()));
        }
        if (list.length > deferredAssetsKept) {
          list.sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
          list.removeRange(0, list.length - deferredAssetsKept);
        }
        return true;
      });
  }

  /// [assetId] got a verdict: forget it.
  Future<void> settled(String assetId) async {
    if (!_known.remove(assetId)) return;
    await forgetDeferredAsset(_prefs, assetId);
  }
}

/// The app engine's half: [assetId] just got a verdict there (di.dart).
/// Never throws.
Future<void> clearDeferredAsset(String assetId,
    {Future<SharedPreferences> Function()? loadPrefs}) async {
  try {
    await forgetDeferredAsset(
        await (loadPrefs ?? SharedPreferences.getInstance)(), assetId);
  } catch (_) {}
}

/// Removes [assetId]'s entry, if any — for the engine that just gave the
/// photo a verdict. Re-reads the store first (the other engine writes it
/// too); writes only when there was an entry. Never throws.
Future<void> forgetDeferredAsset(SharedPreferences prefs, String assetId) =>
    _rewrite(prefs, (list) {
      final before = list.length;
      list.removeWhere((e) => e.id == assetId);
      return list.length != before;
    });

Future<void> _rewrite(SharedPreferences prefs,
    bool Function(List<DeferredAsset> list) edit) async {
  try {
    await prefs.reload();
    final list = [
      ...decodeDeferredAssets(prefs.getString(deferredAssetsPrefsKey)),
    ];
    if (!edit(list)) return;
    if (list.isEmpty) {
      await prefs.remove(deferredAssetsPrefsKey);
    } else {
      await prefs.setString(deferredAssetsPrefsKey,
          jsonEncode([for (final e in list) e.toJson()]));
    }
  } catch (_) {}
}
