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
/// A photo the iOS run's deadline cuts off mid-analysis (finishWithinGrant
/// releases it) is counted apart, as a cut, and passed over only after
/// [cutsBeforePassOver] of them. A cut is mostly not the photo's doing: a
/// server or network that hangs for a while cuts off whatever photo each
/// run meets, and a photo offered late in a run has only what the run has
/// left. Passed over, it gets no background log or meal card until the app
/// next opens, so a cut counts at all only when the photo had the run's
/// full window to itself (background_glue.dart slowPhotoWindow), and it
/// takes more of them: a photo really too slow for any run is still passed
/// over in the end, instead of holding the watermark — and every photo shot
/// after it — until the app opens.
///
/// Asset ids, counts and the first deferral's time only. Both engines
/// rewrite the list (read, change, write); two writes interleaving can at
/// worst lose one count or one removal, and either only delays the pass
/// over or keeps a harmless entry until the cap drops it.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A JSON list of {id, n, first}, and c (the cuts) when there are any.
const String deferredAssetsPrefsKey = 'background.deferred_assets_v1';

/// How many photos are tracked; past it the earliest-deferred goes.
const int deferredAssetsKept = 50;

/// Deferrals after which later background runs pass a photo over.
const int deferralsBeforePassOver = 2;

/// Deadline cuts (each with the run's full window) after which later
/// background runs pass a photo over. More than [deferralsBeforePassOver]:
/// a cut can be a slow patch of the server or the network, which the next
/// run may not meet; an undecodable photo stays undecodable.
const int cutsBeforePassOver = 3;

class DeferredAsset {
  const DeferredAsset(this.id, this.count, this.firstSeen, {this.cuts = 0});
  final String id;

  /// Deferrals: the run could not decode it.
  final int count;

  /// Deadline cuts: the run's deadline released it mid-analysis.
  final int cuts;

  /// The first deferral or cut (UTC).
  final DateTime firstSeen;

  bool get passedOver =>
      count >= deferralsBeforePassOver || cuts >= cutsBeforePassOver;

  Map<String, Object?> toJson() => {
        'id': id,
        'n': count,
        'first': firstSeen.toUtc().toIso8601String(),
        if (cuts > 0) 'c': cuts,
      };

  static DeferredAsset? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final n = json['n'];
    final c = json['c'] ?? 0;
    final first = DateTime.tryParse('${json['first']}');
    if (id is! String ||
        id.isEmpty ||
        n is! int ||
        n < 0 ||
        c is! int ||
        c < 0 ||
        n + c < 1 ||
        first == null) {
      return null;
    }
    return DeferredAsset(id, n, first, cuts: c);
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
/// passed over only by runs AFTER the one whose deferral or cut reached the
/// threshold. Writes never throw — bookkeeping must not take the scan down.
class DeferredAssets {
  DeferredAssets._(this._prefs, this._clock, List<DeferredAsset> entries)
      : _passOver = {
          for (final e in entries)
            if (e.passedOver) e.id,
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

  /// This run deferred [assetId] (again): it could not decode it.
  Future<void> deferred(String assetId) => _note(assetId, cut: false);

  /// This run's deadline cut [assetId] off mid-analysis after it had the
  /// run's full window (RunInFlight.abandon decides that).
  Future<void> cutOff(String assetId) => _note(assetId, cut: true);

  Future<void> _note(String assetId, {required bool cut}) {
    _known.add(assetId);
    return _rewrite(_prefs, (list) {
        final i = list.indexWhere((e) => e.id == assetId);
        if (i >= 0) {
          final e = list[i];
          list[i] = DeferredAsset(
              e.id, e.count + (cut ? 0 : 1), e.firstSeen,
              cuts: e.cuts + (cut ? 1 : 0));
        } else {
          list.add(DeferredAsset(assetId, cut ? 0 : 1, _clock().toUtc(),
              cuts: cut ? 1 : 0));
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
///
/// Asks this engine's own copy of the list first and goes to the store
/// (a full reload over the platform channel) only for an id it holds: the
/// list is nearly always empty, and this runs for every verdict. A shared
/// photo has no asset id and was never deferred. A copy too old to know an
/// entry leaves it behind, which is harmless: the photo now has a verdict,
/// so a background run passing it over, or meeting it as already logged
/// (which forgets it), changes nothing.
Future<void> clearDeferredAsset(String assetId,
    {Future<SharedPreferences> Function()? loadPrefs}) async {
  if (assetId.isEmpty) return;
  try {
    final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
    final cached =
        decodeDeferredAssets(prefs.getString(deferredAssetsPrefsKey));
    if (!cached.any((e) => e.id == assetId)) return;
    await forgetDeferredAsset(prefs, assetId);
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

// ---------------------------------------------------------------------------
// Glasses preview copies (design G2b, 2026-10-24).
//
// The Meta AI app can put a small preview of a glasses photo in the library
// before the full-size one. Analyzed at once, the preview is a worse photo
// to estimate from, and the full-size copy that follows becomes a second
// meal (the duplicate-capture guard then skips whichever comes second). So
// the automatic intake holds a glasses photo below 2 MP back ONCE, for
// [glassesPreviewWait] from the first time it met it: released, retryable,
// and a later scan offers it again. After that it is analyzed like any
// photo. Deliberate adds are never held (photo_pipeline.dart decides who
// asks).
//
// Both engines read and write the list (asset ids and the first meeting's
// time, nothing else); an entry is let go after [glassesPreviewKeep].

/// A JSON map {assetId: first hold, UTC ISO-8601}.
const String glassesPreviewPrefsKey = 'photo.glasses_preview_holds_v1';

/// How long a preview copy is held back from the first time it was met.
const Duration glassesPreviewWait = Duration(minutes: 10);

/// How long an entry is kept. A photo offered again after it is gone is
/// held once more, which only delays it.
const Duration glassesPreviewKeep = Duration(days: 2);

/// Entries kept at most; past it the earliest go.
const int glassesPreviewKept = 100;

/// Parses the stored map; unreadable entries are skipped.
Map<String, DateTime> decodeGlassesPreviewHolds(String? stored) {
  if (stored == null || stored.isEmpty) return {};
  try {
    final map = jsonDecode(stored);
    if (map is! Map) return {};
    return {
      for (final MapEntry(:key, :value) in map.entries)
        if (key is String && key.isNotEmpty && value is String)
          if (DateTime.tryParse(value) case final at?) key: at.toUtc(),
    };
  } catch (_) {
    return {};
  }
}

/// Whether the automatic intake holds the glasses preview [assetId] back
/// for now: true the first time it is met (noted here) and until
/// [glassesPreviewWait] has passed since; false after that, and for any
/// trouble — an unreadable store, or a note that could not be written,
/// processes the photo now rather than holding it for good. Never throws.
Future<bool> holdGlassesPreview(String assetId,
    {Future<SharedPreferences> Function()? loadPrefs,
    DateTime Function()? clock}) async {
  if (assetId.isEmpty) return false;
  try {
    final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
    await prefs.reload(); // the other engine writes it too
    final now = (clock ?? DateTime.now)().toUtc();
    final holds =
        decodeGlassesPreviewHolds(prefs.getString(glassesPreviewPrefsKey));
    final stored = holds.length;
    // Gone stale, or stamped ahead of a clock that has since moved back.
    holds.removeWhere((_, at) =>
        now.difference(at) > glassesPreviewKeep ||
        at.isAfter(now.add(_previewClockSlack)));
    final first = holds[assetId];
    if (first != null) {
      if (holds.length != stored) await _writeHolds(prefs, holds);
      return now.difference(first) < glassesPreviewWait;
    }
    holds[assetId] = now;
    if (holds.length > glassesPreviewKept) {
      final byAge = holds.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final e in byAge.take(holds.length - glassesPreviewKept)) {
        holds.remove(e.key);
      }
    }
    // Held only once the note is stored: a hold nobody remembers would
    // start over at every offer.
    return await _writeHolds(prefs, holds);
  } catch (_) {
    return false;
  }
}

/// A hold stamped this far ahead of now is from a clock that moved back.
const Duration _previewClockSlack = Duration(minutes: 2);

Future<bool> _writeHolds(
    SharedPreferences prefs, Map<String, DateTime> holds) async {
  if (holds.isEmpty) return prefs.remove(glassesPreviewPrefsKey);
  return prefs.setString(
      glassesPreviewPrefsKey,
      jsonEncode({
        for (final MapEntry(:key, :value) in holds.entries)
          key: value.toUtc().toIso8601String(),
      }));
}
