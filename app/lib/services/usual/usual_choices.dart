/// The user's choices about usual foods (usual-foods spec §5): which meals
/// they hid from My usual foods and which offers of their usual numbers
/// they turned down. One small preferences value, backed up with the
/// app's settings, never exported:
///
///   `usual_foods.choices_v1` =
///   `{"v":1,"hidden":[{"h":"<16hex>","at":ISO}],
///     "declined":[{"m":<meal id>,"h":"<16hex>","at":ISO}]}`
///
/// Only [usualHideId]s (16 hex characters of a SHA-256) and meal ids are
/// stored, never a food name. A corrupt value reads as empty. At most
/// [kUsualChoicesCap] of each, newest first; declines older than
/// [kUsualDeclineDays] days are dropped.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/usual_foods_logic.dart';

export '../../core/usual_foods_logic.dart' show UsualChoicesView, UsualDecline;

/// The preferences key.
const String usualChoicesPrefsKey = 'usual_foods.choices_v1';

/// At most this many hidden meals and this many declines are kept.
const int kUsualChoicesCap = 200;

final RegExp _hideIdRe = RegExp(r'^[0-9a-f]{16}$');

/// Built once (di.dart) from the SharedPreferences instance the app
/// already awaits. Reads are synchronous; writes are serialized, so two
/// quick taps never lose one another's entry.
///
/// The value is read from the preferences ONCE, here, and kept: every read
/// and every change after that works on this copy, and each change writes
/// the preference from it. The shared preferences cache is not read again,
/// because other code reloads that instance while the app is in use (the
/// late-import record, the background watermark, the deferred notes), and
/// a reload whose reply was already on its way when a choice was written
/// puts the older snapshot back over the cache: the choice came back
/// undone, and the next one, built from that cache and written whole,
/// erased it from storage (2026-11-10). Only the app engine writes this
/// key, and it builds exactly one of these, so the copy is the truth.
class UsualChoices {
  UsualChoices(this._prefs, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    try {
      _raw = _prefs.getString(usualChoicesPrefsKey);
    } catch (_) {
      _raw = null; // a value of another type reads as empty
    }
  }

  final SharedPreferences _prefs;
  final DateTime Function() _clock;
  Future<void> _tail = Future.value();

  /// The stored value as this instance last read or wrote it.
  String? _raw;

  /// The choices now, as an immutable snapshot for the pure rules.
  UsualChoicesView view() {
    final (hidden, declined) = _read();
    return UsualChoicesView(
      hidden: {for (final h in hidden) h.h},
      declined: [
        for (final d in declined)
          UsualDecline(mealId: d.m, hideId: d.h, at: d.at),
      ],
    );
  }

  /// Hide the meal key whose [usualHideId] is [hideId] from My usual
  /// foods. Anything but a 16-hex id is ignored.
  Future<void> hide(String hideId) => _serial(() {
        if (!_hideIdRe.hasMatch(hideId)) return;
        final (hidden, declined) = _read();
        _write([
          (h: hideId, at: _clock()),
          ...hidden.where((e) => e.h != hideId),
        ], declined);
      });

  /// Show the meal key [hideId] again.
  Future<void> unhide(String hideId) => _serial(() {
        final (hidden, declined) = _read();
        if (!hidden.any((e) => e.h == hideId)) return;
        _write(hidden.where((e) => e.h != hideId).toList(), declined);
      });

  /// "Keep AI estimate" on meal [mealId]: one decline per offered food
  /// ([usualHideId] of its name key). Anything but 16-hex ids is ignored.
  Future<void> decline(int mealId, Iterable<String> hideIds) => _serial(() {
        final ids = hideIds.where(_hideIdRe.hasMatch).toSet();
        if (mealId <= 0 || ids.isEmpty) return;
        final (hidden, declined) = _read();
        final at = _clock();
        _write(hidden, [
          for (final h in ids) (m: mealId, h: h, at: at),
          ...declined.where((d) => !(d.m == mealId && ids.contains(d.h))),
        ]);
      });

  Future<void> _serial(void Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  (List<_Hidden>, List<_Declined>) _read() {
    final hidden = <_Hidden>[];
    final declined = <_Declined>[];
    try {
      final raw = _raw;
      if (raw == null) return (hidden, declined);
      final doc = jsonDecode(raw);
      if (doc is! Map || doc['v'] != 1) return (hidden, declined);
      DateTime? atOf(Map e) {
        final at = e['at'];
        return at is String ? DateTime.tryParse(at) : null;
      }

      final h = doc['hidden'];
      for (final e in h is List ? h : const []) {
        if (e is! Map) continue;
        final id = e['h'];
        final at = atOf(e);
        if (id is String && _hideIdRe.hasMatch(id) && at != null) {
          hidden.add((h: id, at: at));
        }
      }
      final d = doc['declined'];
      for (final e in d is List ? d : const []) {
        if (e is! Map) continue;
        final m = e['m'];
        final id = e['h'];
        final at = atOf(e);
        if (m is int &&
            m > 0 &&
            id is String &&
            _hideIdRe.hasMatch(id) &&
            at != null) {
          declined.add((m: m, h: id, at: at));
        }
      }
    } catch (_) {
      return (<_Hidden>[], <_Declined>[]);
    }
    return (hidden, declined);
  }

  void _write(List<_Hidden> hidden, List<_Declined> declined) {
    final now = _clock();
    final oldest = now.subtract(const Duration(days: kUsualDeclineDays));
    final keptHidden = [...hidden]..sort((a, b) => b.at.compareTo(a.at));
    final keptDeclined = [
      for (final d in declined)
        if (!d.at.isBefore(oldest)) d,
    ]..sort((a, b) => b.at.compareTo(a.at));
    final doc = {
      'v': 1,
      'hidden': [
        for (final e in keptHidden.take(kUsualChoicesCap))
          {'h': e.h, 'at': usualStamp(e.at)},
      ],
      'declined': [
        for (final d in keptDeclined.take(kUsualChoicesCap))
          {'m': d.m, 'h': d.h, 'at': usualStamp(d.at)},
      ],
    };
    // Our copy updates at once; the platform write finishes later.
    final raw = jsonEncode(doc);
    _raw = raw;
    unawaited(_prefs
        .setString(usualChoicesPrefsKey, raw)
        .then((_) {}, onError: (Object _) {}));
  }
}

typedef _Hidden = ({String h, DateTime at});
typedef _Declined = ({int m, String h, DateTime at});
