// Fuzz: the saved lookup answers (usual-foods spec §2.1, D1-D3;
// services/assist/assist_local_state.dart, the 'assist_cache' document).
//
// A real AssistLocalState and one injected clock are driven by
// seeded-random sequences of: put
// (found or not, three providers), read, touch, mark declined, clear,
// the clock moving forward by minutes to more than a year and back by
// up to three days, a `used_at` rewritten into the future, an entry
// stripped of `used_at` (an older build's), a junk entry, and the file
// replaced by something unreadable. Some sequences start from a store
// that is already full.
//
// The store under the state is the real LocalNoBackupStore over a temp
// directory for some sequences and, for most, the same documents held in
// memory (a real write flushes to disk, which costs milliseconds; the
// rules under test are AssistLocalState's and do not change with where
// the bytes live).
//
// A small model restates the spec: an answer lives 365 days from its
// fetch when it found numbers and 30 days otherwise, never longer for
// being used; a `used_at` before the fetch or more than a day ahead
// counts as the fetch; a write keeps the 200 used most recently; a
// search that found nothing never replaces a found answer of the same
// provider. After every operation the stored document must equal the
// model's (or be untouched, byte for byte, when nothing was to be
// written), parse back to itself, and every read must agree. A failure
// prints the seed and the operations cut down to those that still fail.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fuzz_support.dart';

const Duration _foundLife = Duration(days: 365);
const Duration _otherLife = Duration(days: 30);
const Duration _slack = Duration(days: 1);
const int _cap = 200;

const List<String> _providers = ['anthropic', 'anthropic', 'claude_plan'];
const List<String> _statuses = [
  'found', 'found', 'found', 'not_published', 'no_match', 'ambiguous', //
];

String _key(int i) => i.toRadixString(16).padLeft(32, '0');

AssistCachedLookup _entry(
  String key, {
  required String status,
  required String provider,
  required DateTime at,
  String text = 'Big Mac 590 Cal.',
  String chain = 'mcdonalds',
  bool declined = false,
}) => AssistCachedLookup(
  key: key,
  chainKey: chain,
  names: const ['big mac'],
  lookup: AssistLookup(
    result: {'status': status, 'chain_key': chain},
    provider: provider,
    citedUrls: const ['https://www.mcdonalds.com/big-mac'],
    evidence: [
      AssistEvidence(url: 'https://www.mcdonalds.com/big-mac', text: text),
    ],
  ),
  at: at,
  declined: declined,
);

// ─── Where the document lives ──────────────────────────────────────────

abstract class Disk {
  LocalNoBackupStore store(DateTime Function() clock);

  /// The cache document's bytes, or null when there is none.
  List<int>? bytes();
  void write(List<int> bytes);
  void dispose();
}

/// The real store: files under a temp directory.
class FileDisk implements Disk {
  final Directory root = Directory.systemTemp.createTempSync(
    'assist_cache_fuzz',
  );

  File get _file =>
      File('${root.path}/$localStoreDirName/$assistCacheDocument.json');

  @override
  LocalNoBackupStore store(DateTime Function() clock) => LocalNoBackupStore(
    root: () async => root,
    createMissingDirectory: true,
    clock: clock,
  );

  @override
  List<int>? bytes() => _file.existsSync() ? _file.readAsBytesSync() : null;

  @override
  void write(List<int> bytes) {
    _file.parent.createSync(recursive: true);
    _file.writeAsBytesSync(bytes);
  }

  @override
  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

/// The same documents in memory, read as LocalNoBackupStore reads a file:
/// anything that is not a JSON object of the asked version is {}.
class MemoryStore extends LocalNoBackupStore {
  MemoryStore()
    : super(
        root: () async => throw StateError('no disk'),
        createMissingDirectory: false,
      );

  final Map<String, List<int>> files = {};

  @override
  Future<Map<String, Object?>> read(String name, {int? version}) async {
    final bytes = files[name];
    if (bytes == null) return {};
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return {};
      final document = <String, Object?>{
        for (final e in decoded.entries) '${e.key}': e.value,
      };
      if (version != null && document['v'] != version) return {};
      return document;
    } catch (_) {
      return {};
    }
  }

  @override
  Future<bool> write(
    String name,
    Map<String, Object?> document, {
    required int version,
  }) async {
    files[name] = utf8.encode(
      jsonEncode(<String, Object?>{
        'v': version,
        for (final e in document.entries)
          if (e.key != 'v') e.key: e.value,
      }),
    );
    return true;
  }

  @override
  Future<bool> delete(String name) async {
    files.remove(name);
    return true;
  }
}

class MemoryDisk implements Disk {
  final MemoryStore _store = MemoryStore();

  @override
  LocalNoBackupStore store(DateTime Function() clock) => _store;

  @override
  List<int>? bytes() => _store.files[assistCacheDocument];

  @override
  void write(List<int> bytes) => _store.files[assistCacheDocument] = bytes;

  @override
  void dispose() {}
}

// ─── Operations, as data ───────────────────────────────────────────────

enum Kind {
  put,
  badPut,
  read,
  touch,
  mark,
  clear,
  forward,
  back,
  futureUse,
  legacy,
  junk,
  twin,
  corrupt,
}

final class Op {
  const Op(
    this.kind, {
    this.key = 0,
    this.status = 'found',
    this.provider = 'anthropic',
    this.flag = false,
    this.minutes = 0,
    this.n = 0,
  });
  final Kind kind;
  final int key;
  final String status;
  final String provider;
  final bool flag;
  final int minutes;
  final int n;

  @override
  String toString() {
    final keyed =
        kind.index <= Kind.mark.index ||
        kind == Kind.futureUse ||
        kind == Kind.legacy ||
        kind == Kind.twin;
    final parts = [
      if (keyed) 'key $key',
      if (kind == Kind.put || kind == Kind.twin) '$status by $provider',
      if (flag) 'flag',
      if (minutes != 0) '$minutes min',
      if (n != 0) 'n $n',
    ];
    return '${kind.name}(${parts.join(', ')})';
  }
}

final class Case {
  Case(this.start, this.prefill, this.ops);
  final DateTime start;

  /// Entries already stored when the sequence starts: (key, status,
  /// provider, minutes before start it was fetched, minutes after the
  /// fetch it was last used).
  final List<(int, String, String, int, int)> prefill;
  final List<Op> ops;

  String show() =>
      'start ${start.toIso8601String()}, ${prefill.length} '
      'entries stored${prefill.length <= 6 ? ' $prefill' : ''}\n'
      'ops: ${ops.join(', ')}';
}

const List<int> _short = [1, 1, 1, 5, 5, 30, 60, 60, 600, 1440, 1440, 2880];

const List<int> _long = [
  10 * 1440, 29 * 1440, 30 * 1440, 31 * 1440, 100 * 1440, 364 * 1440, //
  365 * 1440, 366 * 1440, 400 * 1440,
];

Case anyCase(Random r) {
  final start = DateTime(
    2026,
    r.between(1, 12),
    r.between(1, 28),
    r.nextInt(24),
    r.nextInt(60),
    r.nextInt(60),
    r.nextInt(1000),
  );
  final stored = r.pick(const [0, 0, 5, 150, 198, 200, 200, 203]);
  final full = stored >= 198;
  // One store in four was filled in a few bursts: many answers fetched
  // and last used at the same moment, so the order they are stored in
  // decides which goes first.
  final bursts = r.chance(0.25);
  final prefill = [
    for (var i = 0; i < stored; i++)
      () {
        final status = r.pick(_statuses);
        if (bursts) {
          return (
            i,
            status,
            r.pick(_providers),
            r.pick(const [600, 1440, 4320]),
            0,
          );
        }
        final age = status == 'found'
            ? r.nextInt(300 * 1440)
            : r.nextInt(25 * 1440);
        return (i, status, r.pick(_providers), age, r.nextInt(age + 1));
      }(),
  ];
  // A key already stored, or (more often over a full store) a new one.
  int key() => r.chance(full ? 0.5 : 0.25)
      ? stored + r.nextInt(60)
      : r.nextInt(max(8, stored));
  // A found answer under a key never stored before.
  var unused = stored + 60;
  Op fresh() => Op(Kind.put, key: unused++, provider: r.pick(_providers));
  final ops = <Op>[];
  for (var i = r.between(30, 80); i > 0; i--) {
    final roll = r.nextInt(1000);
    if (roll < 430) {
      ops.add(
        Op(
          Kind.put,
          key: key(),
          status: r.pick(_statuses),
          provider: r.pick(_providers),
          flag: r.chance(0.1),
        ),
      );
    } else if (roll < 445) {
      ops.add(Op(Kind.badPut, n: r.nextInt(4)));
    } else if (roll < 525) {
      ops.add(Op(Kind.read, key: key()));
    } else if (roll < 675) {
      // One touch in three is of the answer that would go next; over a
      // full store a new answer often follows, and another one must go.
      final next = r.chance(0.33);
      ops.add(Op(Kind.touch, key: key(), flag: next));
      if (next && full && r.chance(0.7)) ops.add(fresh());
    } else if (roll < 745) {
      ops.add(Op(Kind.mark, key: key(), n: r.chance(0.6) ? 1 : 0));
    } else if (roll < 748) {
      ops.add(const Op(Kind.clear));
    } else if (roll < 855) {
      ops.add(
        Op(
          Kind.forward,
          minutes:
              (r.chance(full ? 0.08 : 0.3) ? r.pick(_long) : r.pick(_short)) +
              r.nextInt(3),
        ),
      );
    } else if (roll < 885) {
      ops.add(
        Op(
          Kind.back,
          minutes: r.pick(const [1, 30, 600, 1439, 1441, 3 * 1440]),
        ),
      );
    } else if (roll < 950) {
      // Half the time the answer that would go next gets the used_at;
      // over a full store a new answer often follows, and that one must
      // still go when its used_at does not count.
      final next = r.chance(0.5);
      ops.add(
        Op(
          Kind.futureUse,
          key: key(),
          flag: next,
          minutes: r.pick(const [
            60, 1439, 1441, 10 * 1440, 400 * 1440, 5 * 365 * 1440, -600, //
          ]),
        ),
      );
      if (next && full && r.chance(0.7)) ops.add(fresh());
    } else if (roll < 970) {
      ops.add(Op(Kind.legacy, key: key()));
    } else if (roll < 980) {
      ops.add(Op(Kind.junk, n: r.nextInt(8), key: r.nextInt(250)));
    } else if (roll < 992) {
      ops.add(
        Op(
          Kind.twin,
          key: key(),
          status: r.pick(_statuses),
          provider: r.pick(_providers),
          n: r.nextInt(250),
          flag: r.chance(0.5),
        ),
      );
    } else {
      ops.add(Op(Kind.corrupt, n: r.nextInt(9), key: r.nextInt(1 << 20)));
    }
  }
  return Case(start, prefill, ops);
}

// ─── The model ─────────────────────────────────────────────────────────

/// One element of the stored list: an entry and the `used_at` written
/// beside it (null: none, as an older build wrote it), or junk.
final class Slot {
  Slot(this.entry, this.usedRaw) : junk = null;
  Slot.junk(this.junk) : entry = null, usedRaw = null;
  final AssistCachedLookup? entry;
  final DateTime? usedRaw;
  final Object? junk;

  Object? toDisk() {
    final e = entry;
    if (e == null) return junk;
    final json = e.toJson()..remove('used_at');
    final used = usedRaw;
    return {
      for (final kv in json.entries) ...{
        if (kv.key == 'declined' && used != null)
          'used_at': used.toUtc().toIso8601String(),
        kv.key: kv.value,
      },
      if (!json.containsKey('declined') && used != null)
        'used_at': used.toUtc().toIso8601String(),
    };
  }
}

typedef Live = ({AssistCachedLookup e, DateTime used});

class Model {
  List<Slot> slots = [];

  /// The entries a reader sees at [now], in stored order: alive by their
  /// fetch alone, each with the `used_at` that counts.
  List<Live> live(DateTime now) => [
    for (final s in slots)
      if (s.entry case final e?)
        if (!e.at.isBefore(now.subtract(_foundLife)) &&
            !e.at.isAfter(now.add(_slack)) &&
            (e.found || !e.at.isBefore(now.subtract(_otherLife))))
          (
            e: e,
            used:
                s.usedRaw == null ||
                    s.usedRaw!.isBefore(e.at) ||
                    s.usedRaw!.isAfter(now.add(_slack))
                ? e.at
                : s.usedRaw!,
          ),
  ];

  /// The key that would go first at [now]: used longest ago (of two used
  /// at the same moment, the one stored earlier).
  String? oldest(DateTime now) {
    Live? first;
    for (final l in live(now)) {
      if (first == null || l.used.isBefore(first.used)) first = l;
    }
    return first?.e.key;
  }

  Live? read(String key, DateTime now) {
    Live? hit;
    for (final l in live(now)) {
      if (l.e.key == key) hit = l;
    }
    return hit;
  }

  /// A write: the 200 used most recently stay, in their order (of two
  /// used at the same moment, the one stored later counts as newer).
  /// Returns the keys that went.
  List<String> write(List<Live> next) {
    final order = List<int>.generate(next.length, (i) => i)
      ..sort((a, b) {
        final c = next[a].used.compareTo(next[b].used);
        return c != 0 ? c : a.compareTo(b);
      });
    final gone = order.take(max(0, next.length - _cap)).toSet();
    slots = [
      for (var i = 0; i < next.length; i++)
        if (!gone.contains(i))
          Slot(next[i].e.withUsedAt(next[i].used), next[i].used),
    ];
    return [for (final i in gone) next[i].e.key];
  }
}

// ─── What a run saw ────────────────────────────────────────────────────

class Seen {
  int steps = 0;
  int writes = 0;
  int evictions = 0;
  int evictedNotOldest = 0;
  int d2a = 0;
  int replaced = 0;
  int readsHit = 0;
  int readsExpired = 0;
  int futureUseIgnored = 0;
  int futureEvicted = 0;
  int touchedKept = 0;
  int corrupt = 0;
  int junk = 0;
  int twins = 0;
  int full = 0;
}

// ─── One sequence ──────────────────────────────────────────────────────

class World {
  World(this.disk, this.clock, this.seen) {
    state = AssistLocalState(disk.store(() => clock), clock: () => clock);
  }

  final Disk disk;
  final Seen seen;
  DateTime clock;
  late final AssistLocalState state;
  final Model model = Model();
  final List<String> trace = [];
  final Random _sample = Random(7);

  /// Keys whose stored used_at is more than a day ahead of the clock
  /// (until the next write, which stores the one that counts), and keys
  /// touched while they were next to go: the first must still be
  /// evicted, the second must not be.
  final Set<String> aheadOnDisk = {};
  final Set<String> touchedWhenNext = {};

  /// Every key the sequence ever stored, to read back.
  final Set<String> known = {};

  /// The document byte for byte (one character per byte), or null.
  String? text() {
    final bytes = disk.bytes();
    return bytes == null ? null : latin1.decode(bytes);
  }

  void put(String text) => disk.write(latin1.encode(text));

  void store() => put(
    jsonEncode({
      'v': assistLocalVersion,
      'entries': [for (final s in model.slots) s.toDisk()],
    }),
  );

  /// The document must hold exactly the model's entries, byte for byte.
  void expectStored() {
    final raw = text();
    if (model.slots.isEmpty && raw == null) return;
    final disk = [for (final s in model.slots) s.toDisk()];
    expect(
      raw,
      jsonEncode({'v': assistLocalVersion, 'entries': disk}),
      reason: 'the stored document',
    );
    // "Never more than 200 entries."
    expect(disk.length, lessThanOrEqualTo(_cap));
    // "The stored document always parses back to the same entries": all
    // of a small store, the ends and a dozen others of a large one.
    final at = disk.length <= 24
        ? List<int>.generate(disk.length, (i) => i)
        : [
            0,
            disk.length - 1,
            for (var i = 0; i < 12; i++) _sample.nextInt(disk.length),
          ];
    for (final i in at) {
      final parsed = AssistCachedLookup.fromJson(disk[i], now: clock);
      expect(parsed, isNotNull, reason: 'unreadable entry ${dump(disk[i])}');
      expect(jsonEncode(parsed!.toJson()), jsonEncode(disk[i]));
    }
    if (disk.length == _cap) seen.full++;
  }

  /// A read of [key] must agree with the model, and with the spec stated
  /// outright.
  Future<void> expectRead(String key) async {
    final got = await state.cachedLookup(key);
    final want = model.read(key, clock);
    final why = 'read of $key at $clock';
    if (want == null) {
      expect(got, isNull, reason: why);
      if (known.contains(key)) seen.readsExpired++;
      return;
    }
    expect(got, isNotNull, reason: why);
    got!;
    expect(
      got.at.isAtSameMomentAs(want.e.at),
      isTrue,
      reason: '$why: fetched ${got.at}, want ${want.e.at}',
    );
    expect(
      got.usedAt.isAtSameMomentAs(want.used),
      isTrue,
      reason: '$why: used ${got.usedAt}, want ${want.used}',
    );
    expect(got.found, want.e.found, reason: why);
    expect(got.declined, want.e.declined, reason: why);
    expect(got.lookup.provider, want.e.lookup.provider, reason: why);
    expect(
      got.lookup.evidence.single.text,
      want.e.lookup.evidence.single.text,
      reason: why,
    );
    // "A found entry is gone after 365 days from its fetch, however often
    // it is used"; "a negative entry is gone after 30 days from its
    // fetch"; "a used_at in the future never makes an entry immortal".
    final age = clock.difference(got.at);
    expect(
      age <= (got.found ? _foundLife : _otherLife),
      isTrue,
      reason: '$why: read at age $age',
    );
    expect(got.at.isAfter(clock.add(_slack)), isFalse, reason: why);
    expect(got.usedAt.isBefore(got.at), isFalse, reason: why);
    expect(got.usedAt.isAfter(clock.add(_slack)), isFalse, reason: why);
    seen.readsHit++;
  }

  /// The key an operation acts on: its own, or (a flagged touch or
  /// used_at rewrite) the answer that would go next.
  String keyOf(Op op) =>
      op.flag && (op.kind == Kind.touch || op.kind == Kind.futureUse)
      ? model.oldest(clock) ?? _key(op.key)
      : _key(op.key);

  Future<void> run(Op op) async {
    final key = keyOf(op);
    final before = text();
    final now = clock;
    switch (op.kind) {
      case Kind.put:
        // The app stamps an answer with the clock; one put in ten is
        // stamped an hour to 40 days ago, or up to 2 days ahead.
        final at = op.flag
            ? now.add(
                Duration(minutes: (op.key * 977) % (42 * 1440) - 40 * 1440),
              )
            : now;
        final e = _entry(
          key,
          status: op.status,
          provider: op.provider,
          at: at,
          text: 'answer ${seen.steps}',
        );
        final cur = model.live(now);
        final old = model.read(key, now);
        final keeps =
            !e.found &&
            old != null &&
            old.e.found &&
            old.e.lookup.provider == e.lookup.provider;
        final ok = await state.putCachedLookup(e);
        expect(ok, isTrue);
        if (keeps) {
          // "An unexpired found entry is never replaced by a non-found
          // answer from the same provider": nothing is written.
          expect(text(), before, reason: 'D2a: the document was rewritten');
          seen.d2a++;
          trace.add('put $key ${op.status}/${op.provider}: kept the found one');
        } else {
          final declined = cur.any((l) => l.e.key == key && l.e.declined);
          final next = [
            for (final l in cur)
              if (l.e.key != key) l,
            (e: e.withDeclined(declined), used: e.at),
          ];
          final gone = model.write(next);
          expectStored();
          // "The entry evicted at the cap is always the one with the
          // oldest used_at": nothing that stayed was used before one
          // that went.
          for (final g in gone) {
            final went = next.lastWhere((l) => l.e.key == g).used;
            for (final s in model.slots) {
              expect(
                s.usedRaw!.isBefore(went),
                isFalse,
                reason:
                    '$g (used $went) went before '
                    '${s.entry!.key} (used ${s.usedRaw})',
              );
            }
            // Least recently USED, not first fetched: an answer fetched
            // earlier may stay.
            final fetched = next.lastWhere((l) => l.e.key == g).e.at;
            if (model.slots.any((s) => s.entry!.at.isBefore(fetched))) {
              seen.evictedNotOldest++;
            }
          }
          seen.evictions += gone.length;
          seen.futureEvicted += gone.where(aheadOnDisk.contains).length;
          if (gone.isNotEmpty) {
            seen.touchedKept += touchedWhenNext
                .where((k) => model.slots.any((s) => s.entry!.key == k))
                .length;
            touchedWhenNext.clear();
          }
          aheadOnDisk.clear();
          if (old != null) seen.replaced++;
          seen.writes++;
          trace.add(
            'put $key ${op.status}/${op.provider}'
            '${gone.isEmpty ? '' : ', evicted $gone'}',
          );
        }
        known.add(key);
      case Kind.badPut:
        // Entries the store must refuse: over the size cap, an unknown
        // chain, a provider or a key of the wrong shape.
        final e = switch (op.n) {
          0 => _entry(
            'f' * 32,
            status: 'found',
            provider: 'anthropic',
            at: now,
            text: 'x' * 9000,
          ),
          1 => _entry(
            'e' * 32,
            status: 'found',
            provider: 'anthropic',
            at: now,
            chain: 'nope',
          ),
          2 => _entry(
            'd' * 32,
            status: 'found',
            provider: 'An Thropic',
            at: now,
          ),
          _ => _entry(
            'not-a-key',
            status: 'found',
            provider: 'anthropic',
            at: now,
          ),
        };
        expect(await state.putCachedLookup(e), isFalse);
        expect(text(), before, reason: 'a refused entry was written');
        trace.add('refused put ${op.n}');
      case Kind.read:
        await expectRead(key);
        expect(text(), before, reason: 'a read wrote the document');
        trace.add('read $key');
      case Kind.touch:
        final cur = model.live(now);
        expect(await state.touchCachedLookup(key), isTrue);
        if (cur.any((l) => l.e.key == key)) {
          if (op.flag) touchedWhenNext.add(key);
          aheadOnDisk.clear();
          model.write([
            for (final l in cur)
              l.e.key == key
                  ? (e: l.e, used: now.isBefore(l.e.at) ? l.e.at : now)
                  : l,
          ]);
          expectStored();
          seen.writes++;
        } else {
          expect(text(), before, reason: 'a touch of nothing wrote');
        }
        trace.add('touch $key');
      case Kind.mark:
        final cur = model.live(now);
        final hit = cur.where((l) => l.e.key == key).toList();
        final declined = op.n == 1;
        expect(await state.markCachedLookup(key, declined: declined), isTrue);
        // Nothing is written when an entry of the key already says so.
        if (hit.isNotEmpty && hit.every((l) => l.e.declined != declined)) {
          aheadOnDisk.clear();
          model.write([
            for (final l in cur)
              l.e.key == key
                  ? (e: l.e.withDeclined(declined), used: l.used)
                  : l,
          ]);
          expectStored();
          seen.writes++;
        } else {
          expect(text(), before, reason: 'a mark that changes nothing wrote');
        }
        trace.add('mark $key declined $declined');
      case Kind.clear:
        expect(await state.clearCache(), isTrue);
        model.slots = [];
        expect(disk.bytes(), isNull);
        trace.add('clear');
      case Kind.forward:
        clock = clock.add(Duration(minutes: op.minutes));
        trace.add('clock +${op.minutes} min → $clock');
      case Kind.back:
        clock = clock.subtract(Duration(minutes: op.minutes));
        trace.add('clock -${op.minutes} min → $clock');
      case Kind.futureUse:
        // The stored used_at of one entry is rewritten: ahead of the
        // clock (inside the day of slack, or far beyond it), or before
        // the fetch.
        final i = model.slots.indexWhere((s) => s.entry?.key == key);
        if (i < 0 || before == null) return;
        final s = model.slots[i];
        model.slots[i] = Slot(
          s.entry,
          op.minutes < 0
              ? s.entry!.at.add(Duration(minutes: op.minutes))
              : now.add(Duration(minutes: op.minutes)),
        );
        store();
        if (op.minutes > 1440 || op.minutes < 0) {
          seen.futureUseIgnored++;
          if (op.minutes > 1440) aheadOnDisk.add(key);
        }
        trace.add(
          'used_at of $key set ${op.minutes} min from '
          '${op.minutes < 0 ? 'its fetch' : 'now'}',
        );
      case Kind.legacy:
        final i = model.slots.indexWhere((s) => s.entry?.key == key);
        if (i < 0 || before == null) return;
        model.slots[i] = Slot(model.slots[i].entry, null);
        store();
        trace.add('used_at of $key removed');
      case Kind.junk:
        if (before == null) return;
        final good = _entry(
          _key(op.key),
          status: 'found',
          provider: 'anthropic',
          at: now,
        ).toJson();
        final junk = switch (op.n) {
          0 => 7,
          1 => 'entry',
          2 => null,
          3 => {...good}..remove('key'),
          4 => {...good, 'at': 'yesterday'},
          5 => {...good, 'names': 'big mac'},
          6 => {...good, 'chain_key': 'subway'},
          _ => {
            ...good,
            'evidence': [3],
          },
        };
        model.slots.insert(op.key % (model.slots.length + 1), Slot.junk(junk));
        store();
        seen.junk++;
        trace.add('junk entry ${op.n}');
      case Kind.twin:
        // A second entry under a key already stored (no write of the
        // store leaves one, a foreign file may): a read takes the later
        // one, and the next put of the key replaces both.
        if (before == null || !model.slots.any((s) => s.entry?.key == key)) {
          return;
        }
        final twin = _entry(
          key,
          status: op.status,
          provider: op.provider,
          at: now.subtract(Duration(minutes: op.n)),
          text: 'twin ${seen.steps}',
          declined: op.flag,
        );
        model.slots.insert(
          op.n % (model.slots.length + 1),
          Slot(twin, twin.at),
        );
        store();
        seen.twins++;
        trace.add('twin of $key');
      case Kind.corrupt:
        // "A corrupt or truncated file reads as empty and never throws."
        final raw = before ?? '{"v":1,"entries":[]}';
        switch (op.n) {
          case 0:
            put(raw.substring(0, op.key % raw.length));
          case 1:
            put('not json');
          case 2:
            put('[]');
          case 3:
            put('');
          case 4:
            put('{"v":1,"entries":"all of them"}');
          case 5:
            put(raw.replaceFirst('"v":1', '"v":${1 + op.key % 5 + 1}'));
          case 6:
            disk.write([0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x7B]);
          case 7:
            put(raw.replaceFirst('"v":1,', ''));
          default:
            put('{"v":1,"entries":{"0":$raw}}');
        }
        model.slots = [];
        seen.corrupt++;
        trace.add('file corrupted ${op.n}');
    }
  }

  /// After every step (each operation has already compared the document
  /// with the model, or seen it untouched): a few reads agree.
  Future<void> check(Op op, Random reads) async {
    await expectRead(keyOf(op));
    for (var i = 0; i < 1; i++) {
      if (known.isEmpty && model.slots.isEmpty) break;
      final keys = [
        ...known,
        for (final s in model.slots)
          if (s.entry != null) s.entry!.key,
      ];
      await expectRead(keys[reads.nextInt(keys.length)]);
    }
    seen.steps++;
  }
}

Future<String?> runCase(Case c, Seen seen, {required bool onDisk}) async {
  final disk = onDisk ? FileDisk() : MemoryDisk();
  final w = World(disk, c.start, seen);
  try {
    if (c.prefill.isNotEmpty) {
      for (final (i, status, provider, age, usedAfter) in c.prefill) {
        final at = c.start.subtract(Duration(minutes: age));
        w.model.slots.add(
          Slot(
            _entry(
              _key(i),
              status: status,
              provider: provider,
              at: at,
              text: 'stored $i',
            ),
            at.add(Duration(minutes: usedAfter)),
          ),
        );
        w.known.add(_key(i));
      }
      w.store();
    }
    final reads = Random(c.ops.length);
    for (var i = 0; i < c.ops.length; i++) {
      final op = c.ops[i];
      final error = await failureOfAsync(() async {
        await w.run(op);
        await w.check(op, reads);
      });
      if (error != null) {
        return 'at op $i ($op), clock ${w.clock}:\n$error\n'
            'trace:\n  ${w.trace.join('\n  ')}';
      }
    }
    return null;
  } finally {
    disk.dispose();
  }
}

/// Runs [cases] sequences from [seed]; the first failure fails the test
/// with its seed and the operations cut down.
Future<void> forAllCases(
  Seen seen, {
  required int seed,
  required int cases,
  required bool onDisk,
  Case Function(Case)? cut,
}) async {
  for (var i = 0; i < cases; i++) {
    var c = anyCase(Random(seed + i));
    if (cut != null) c = cut(c);
    final error = await runCase(c, seen, onDisk: onDisk);
    if (error == null) continue;
    final quiet = Seen();
    final ops = await shrinkListAsync(
      c.ops,
      (kept) async =>
          await runCase(
            Case(c.start, c.prefill, kept),
            quiet,
            onDisk: onDisk,
          ) !=
          null,
      budget: 150,
    );
    final small = Case(c.start, c.prefill, ops);
    fail(
      'seed ${seed + i} (case $i of $cases)\n'
      '${await runCase(small, quiet, onDisk: onDisk) ?? error}\n'
      'input: ${small.show()}',
    );
  }
}

void main() {
  const seed = 20261112;

  test(
    'the stored answers follow the spec through 45 random sequences',
    () async {
      final seen = Seen();
      await forAllCases(seen, seed: seed, cases: 45, onDisk: false);
      // No promise held for want of cases.
      expect(seen.steps, greaterThan(1900), reason: 'steps');
      expect(seen.writes, greaterThan(900), reason: 'writes');
      expect(seen.full, greaterThan(160), reason: 'writes of a full store');
      expect(seen.evictions, greaterThan(80), reason: 'evictions');
      expect(
        seen.evictedNotOldest,
        greaterThan(35),
        reason: 'evictions of an answer that was not the first fetched',
      );
      expect(
        seen.touchedKept,
        greaterThan(10),
        reason: 'answers touched when next to go, and kept',
      );
      expect(
        seen.futureEvicted,
        greaterThan(1),
        reason: 'evictions of an answer whose used_at was far ahead',
      );
      expect(seen.d2a, greaterThan(30), reason: 'kept found answers (D2a)');
      expect(seen.replaced, greaterThan(150), reason: 'replaced answers');
      expect(seen.readsHit, greaterThan(1700), reason: 'reads that hit');
      expect(
        seen.readsExpired,
        greaterThan(600),
        reason: 'reads of an answer stored once and gone',
      );
      expect(
        seen.futureUseIgnored,
        greaterThan(40),
        reason: 'used_at values that must not count',
      );
      expect(seen.corrupt, greaterThan(12), reason: 'unreadable files');
      expect(seen.junk, greaterThan(15), reason: 'junk entries');
      expect(seen.twins, greaterThan(1), reason: 'second entries of a key');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'and through 8 shorter sequences on the real file store',
    () async {
      final seen = Seen();
      await forAllCases(
        seen,
        seed: seed + 500,
        cases: 8,
        onDisk: true,
        cut: (c) => Case(c.start, c.prefill, c.ops.take(25).toList()),
      );
      expect(seen.writes, greaterThan(40), reason: 'writes');
      expect(seen.readsHit, greaterThan(100), reason: 'reads that hit');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('every kind of unreadable file reads as empty on the real file '
      'store, and the next answer is stored', () async {
    final seen = Seen();
    for (var kind = 0; kind < 9; kind++) {
      for (final cut in const [0, 1, 17, 250, 4099]) {
        final c = Case(DateTime(2026, 11, 7, 12, 30), const [], [
          const Op(Kind.put, key: 1),
          const Op(Kind.put, key: 2, status: 'no_match'),
          const Op(Kind.touch, key: 1),
          Op(Kind.corrupt, n: kind, key: cut),
          const Op(Kind.read, key: 1),
          const Op(Kind.read, key: 2),
          const Op(Kind.mark, key: 1, n: 1),
          const Op(Kind.touch, key: 2),
          const Op(Kind.put, key: 3),
          const Op(Kind.read, key: 3),
          const Op(Kind.put, key: 1, status: 'ambiguous'),
        ]);
        final error = await runCase(c, seen, onDisk: true);
        if (error != null) fail('corruption $kind cut at $cut\n$error');
      }
    }
    expect(seen.corrupt, 45);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a year of daily use never keeps a found answer past day 365, nor '
      'a negative one past day 30 (40 schedules)', () async {
    for (var i = 0; i < 40; i++) {
      final r = Random(seed + 1000 + i);
      var clock = DateTime(
        2026,
        r.between(1, 12),
        r.between(1, 28),
        r.nextInt(24),
        r.nextInt(60),
      );
      final disk = MemoryDisk();
      final state = AssistLocalState(
        disk.store(() => clock),
        clock: () => clock,
      );
      try {
        final fetched = clock;
        final found = _key(1);
        final other = _key(2);
        await state.putCachedLookup(
          _entry(found, status: 'found', provider: 'anthropic', at: clock),
        );
        await state.putCachedLookup(
          _entry(
            other,
            status: r.pick(const ['not_published', 'no_match', 'ambiguous']),
            provider: 'anthropic',
            at: clock,
          ),
        );
        // Used again and again, at random gaps of minutes to weeks.
        while (clock.difference(fetched) < const Duration(days: 380)) {
          clock = clock.add(
            Duration(
              minutes:
                  r.pick(const [7, 600, 1440, 3 * 1440, 20 * 1440]) +
                  r.nextInt(60),
            ),
          );
          final age = clock.difference(fetched);
          final why = 'seed ${seed + 1000 + i}, day ${age.inHours / 24}';
          for (final key in [found, other]) {
            expect(await state.touchCachedLookup(key), isTrue, reason: why);
            if (r.chance(0.2)) {
              await state.markCachedLookup(key, declined: r.nextBool());
            }
          }
          final f = await state.cachedLookup(found);
          final o = await state.cachedLookup(other);
          expect(f != null, age <= _foundLife, reason: '$why: found');
          expect(o != null, age <= _otherLife, reason: '$why: negative');
          if (f != null) {
            expect(f.at.isAtSameMomentAs(fetched), isTrue, reason: why);
            expect(f.usedAt.isAtSameMomentAs(clock), isTrue, reason: why);
          }
        }
      } finally {
        disk.dispose();
      }
    }
  });
}
