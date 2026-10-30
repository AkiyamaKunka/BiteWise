/// Local documents that never leave this device (design F1, 2026-10-23).
///
/// Some state must not reach an iCloud, computer or Android backup: state
/// that hints at where the user eats (the restaurant assist's learned
/// places), and state that is only valid on this device (the photo
/// library's change token, which restored onto another iPhone points into a
/// different library). shared_preferences and the meal database are both
/// backed up, so that state lives here instead: small named JSON documents
/// at `<Application Support>/bitewise_local/<name>.json`.
///
/// - iOS: AppDelegate.prepareLocalStore creates the directory at every
///   launch, before either engine runs, and marks it isExcludedFromBackup,
///   which covers everything inside it. This store never creates the
///   directory on iOS: one it made would stay in backups until the next
///   launch flagged it. Without the directory, reads are empty and writes
///   refuse.
/// - Android: res/xml/data_extraction_rules.xml (Android 12+) and
///   res/xml/backup_rules.xml (older) exclude files/bitewise_local/ from
///   cloud backup and device transfer. The rule is by path, so the store
///   creates the directory itself.
///
/// Reads never throw: a missing, unreadable, oversized, corrupt or
/// non-object document reads as {}, which callers take as their defaults
/// (off, a fresh cursor, empty). Writes never throw either and say whether
/// they landed. A write goes to a temp file that is then renamed over the
/// document, so a crash part-way leaves the previous document readable.
/// Each document carries its schema version in 'v'.
///
/// Read-modify-write is the caller's job: the app's engine and the
/// background engine can both write a document, and the last rename wins
/// whole, never a mix of the two.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// The directory under Application Support. MUST equal
/// AppDelegate.localStoreDirectoryName (ios/Runner/AppDelegate.swift) and
/// the path in res/xml/data_extraction_rules.xml and backup_rules.xml.
const String localStoreDirName = 'bitewise_local';

/// A document larger than this is refused on write and reads as {}.
/// Callers keep theirs far below it with [pruneByTtl] and [capNewest].
const int localDocumentMaxBytes = 2 * 1024 * 1024;

/// A temp file this far from now (either way) is a crash's leftover, not a
/// write in flight in the other engine, and the next write deletes it.
const Duration localTempStaleAfter = Duration(hours: 1);

/// How far in the future [pruneByTtl] still accepts a timestamp. A clock
/// that was set ahead and then corrected cannot keep an entry past its TTL
/// by more than this.
const Duration ttlFutureSlack = Duration(days: 1);

final RegExp _documentName = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// `<name>.json.<epoch ms>.<random hex>.tmp`
final RegExp _tempName =
    RegExp(r'^[a-z][a-z0-9_]{0,63}\.json\.(\d{1,16})\.[0-9a-f]{1,16}\.tmp$');

class LocalNoBackupStore {
  /// [root] resolves the directory that holds [localStoreDirName]. With
  /// [createMissingDirectory] false (iOS), a missing directory is never
  /// created here.
  LocalNoBackupStore({
    required Future<Directory> Function() root,
    required this._createMissingDirectory,
    DateTime Function()? clock,
    @visibleForTesting this._beforeRename,
  })  : _resolveRoot = root,
        _clock = clock ?? DateTime.now;

  /// The app's store: under getApplicationSupportDirectory(). On iOS the
  /// directory is AppDelegate's to create, because only it can exclude it
  /// from backup before anything is written.
  factory LocalNoBackupStore.platform() => LocalNoBackupStore(
        root: getApplicationSupportDirectory,
        createMissingDirectory: !Platform.isIOS,
      );

  final Future<Directory> Function() _resolveRoot;
  final bool _createMissingDirectory;
  final DateTime Function() _clock;
  final Future<void> Function(File temp)? _beforeRename;
  final Random _random = Random();
  Future<Directory>? _root;

  /// The document [name], or {} when it is missing, unreadable, corrupt,
  /// not a JSON object, or (with [version]) of another version. Never
  /// throws.
  Future<Map<String, Object?>> read(String name, {int? version}) async {
    if (!_documentName.hasMatch(name)) return {};
    try {
      final dir = await _directory(create: false);
      if (dir == null) return {};
      final file = File('${dir.path}/$name.json');
      if (!await file.exists()) return {};
      if (await file.length() > localDocumentMaxBytes) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      final document = <String, Object?>{
        for (final entry in decoded.entries) '${entry.key}': entry.value,
      };
      if (version != null && document['v'] != version) return {};
      return document;
    } catch (_) {
      return {};
    }
  }

  /// Replaces the document [name] with [document], stamped 'v': [version]
  /// (any 'v' in [document] is overwritten). False when it did not land:
  /// a bad name, a value JSON cannot hold, a document over
  /// [localDocumentMaxBytes], no directory, or a failed file operation —
  /// the previous document is then still there. Never throws.
  Future<bool> write(
    String name,
    Map<String, Object?> document, {
    required int version,
  }) async {
    if (!_documentName.hasMatch(name)) return false;
    final List<int> bytes;
    try {
      bytes = utf8.encode(jsonEncode(<String, Object?>{
        'v': version,
        for (final entry in document.entries)
          if (entry.key != 'v') entry.key: entry.value,
      }));
    } catch (_) {
      return false;
    }
    if (bytes.length > localDocumentMaxBytes) return false;
    final Directory? dir;
    try {
      dir = await _directory(create: true);
    } catch (_) {
      return false;
    }
    if (dir == null) return false;
    final now = _clock();
    final temp = File('${dir.path}/$name.json.${now.millisecondsSinceEpoch}.'
        '${_random.nextInt(1 << 32).toRadixString(16)}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await _beforeRename?.call(temp);
      await temp.rename('${dir.path}/$name.json');
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      return false;
    }
    await _sweepStaleTemps(dir, now);
    return true;
  }

  /// Removes the document [name]. True when it is gone (or never was).
  /// Never throws.
  Future<bool> delete(String name) async {
    if (!_documentName.hasMatch(name)) return false;
    try {
      final dir = await _directory(create: false);
      if (dir == null) return true;
      final file = File('${dir.path}/$name.json');
      if (await file.exists()) await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Directory?> _directory({required bool create}) async {
    final Directory root;
    try {
      root = await (_root ??= _resolveRoot());
    } catch (_) {
      _root = null; // resolve again next time
      return null;
    }
    final dir = Directory('${root.path}/$localStoreDirName');
    if (await dir.exists()) return dir;
    if (!create || !_createMissingDirectory) return null;
    await dir.create(recursive: true);
    return dir;
  }

  /// Deletes temp files a crash left between their write and their rename.
  /// The time is in the name, so no file timestamp is read. A temp made
  /// moments ago by the other engine is never touched.
  Future<void> _sweepStaleTemps(Directory dir, DateTime now) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final match = _tempName.firstMatch(entity.uri.pathSegments.last);
        if (match == null) continue;
        final made =
            DateTime.fromMillisecondsSinceEpoch(int.parse(match.group(1)!));
        if (now.difference(made).abs() > localTempStaleAfter) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}

/// The time an entry stamped [field] carries: an ISO 8601 string, as the
/// documents store it. Null for anything else.
DateTime? _stampOf(Object? entry, String field) {
  if (entry is! Map) return null;
  final value = entry[field];
  return value is String ? DateTime.tryParse(value) : null;
}

/// The object entries of [entries] whose [field] is an ISO 8601 time no
/// older than [maxAge] at [now] and no more than [ttlFutureSlack] ahead of
/// it, in their original order. An entry that is not an object, or whose
/// [field] is missing or unreadable, is dropped, and so is everything when
/// [entries] is not a list.
List<Map<String, Object?>> pruneByTtl(
  Object? entries,
  String field,
  Duration maxAge, {
  DateTime? now,
}) {
  if (entries is! List) return [];
  final at = now ?? DateTime.now();
  final oldest = at.subtract(maxAge);
  final latest = at.add(ttlFutureSlack);
  return [
    for (final entry in entries)
      if (_stampOf(entry, field) case final stamp?
          when !stamp.isBefore(oldest) && !stamp.isAfter(latest))
        <String, Object?>{
          for (final e in (entry as Map).entries) '${e.key}': e.value,
        },
  ];
}

/// The newest [n] of [entries], in their original order. Without [field]
/// the list's order is its age (appended newest last), so the last [n] are
/// kept. With [field], age is that ISO 8601 stamp; entries without a
/// readable one count as the oldest, and equal stamps keep the later
/// position as the newer.
List<T> capNewest<T>(List<T> entries, int n, {String? field}) {
  if (n <= 0) return <T>[];
  if (entries.length <= n) return List<T>.of(entries);
  if (field == null) return entries.sublist(entries.length - n);
  final stamps = [for (final e in entries) _stampOf(e, field)];
  final order = List<int>.generate(entries.length, (i) => i)
    ..sort((a, b) {
      final sa = stamps[a], sb = stamps[b];
      final byTime = sa == null
          ? (sb == null ? 0 : -1)
          : (sb == null ? 1 : sa.compareTo(sb));
      return byTime != 0 ? byTime : a.compareTo(b);
    });
  final kept = order.sublist(order.length - n)..sort();
  return [for (final i in kept) entries[i]];
}
