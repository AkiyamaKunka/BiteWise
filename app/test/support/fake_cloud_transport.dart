/// An in-memory iCloud Drive › Chopstats for the iCloud Backup tests.
///
/// It applies the same owner rule as the Swift writer (backup_format.dart
/// checkOwner, which CloudFiles.swift mirrors and RunnerTests pin), checks
/// the size and SHA-256 of every source file like Swift does, and keeps a
/// log of writes and deletes so a test can tell "nothing was written".
///
/// Where Swift asks whether an install owns a file it has looked at
/// (a conflict version, the previous copy), a file whose header cannot be
/// read is never owned (CloudFiles.Expect.owns(nil) is false), and
/// [startDownloads] only starts a download, as the plugin does: the paths
/// stay not downloaded until a test calls [finishDownloads] (or a
/// coordinated read, readHeader with allowDownload or fetch, waits for
/// one).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/services/backup/backup_format.dart';
import 'package:calorie_tracker/services/backup/cloud_backup_channel.dart';
import 'package:crypto/crypto.dart';

class FakeCloudTransport implements BackupTransport {
  /// Each path's bytes (`Chopstats Backup.json`, `Meal Pictures/2026-10.json`).
  final Map<String, Uint8List> files = {};

  /// Paths whose bytes are not on this phone yet.
  final Set<String> notDownloaded = {};

  /// Unresolved conflict versions per path.
  final Map<String, List<Uint8List>> conflictVersions = {};

  CloudState state = CloudState.ok;
  bool accountChangedOnce = false;
  String? device = 'device-key-1';
  bool gathered = true;
  Duration live = const Duration(minutes: 5);
  bool uploaded = true;
  Duration? backgroundLeft;

  /// Writes and deletes that landed, in order (`write <path>`).
  final List<String> log = [];
  int statusCalls = 0;

  BackupHeader? headerOf(String path) {
    final b = files[path];
    return b == null ? null : parseBackupHeader(b);
  }

  void put(String path, String text) =>
      files[path] = Uint8List.fromList(text.codeUnits);

  @override
  Future<CloudStatus> status() async {
    statusCalls++;
    final changed = accountChangedOnce;
    accountChangedOnce = false;
    return CloudStatus(state, accountChanged: changed);
  }

  @override
  Future<String?> deviceKey() async => device;

  bool watching = false;
  @override
  Future<void> startWatching() async => watching = true;
  @override
  Future<void> stopWatching() async => watching = false;

  @override
  Future<CloudListing> list() async => CloudListing(
        watching: watching,
        gathered: gathered,
        live: live,
        items: [
          for (final p in files.keys)
            CloudItem(
                path: p,
                downloading: notDownloaded.contains(p),
                uploaded: uploaded,
                hasConflicts: conflictVersions[p]?.isNotEmpty ?? false),
        ],
      );

  @override
  Future<CloudItemState> itemState(String path) async => CloudItemState(
      files.containsKey(path) ? ItemExists.yes : ItemExists.no,
      downloading: notDownloaded.contains(path),
      hasConflicts: conflictVersions[path]?.isNotEmpty ?? false);

  @override
  Future<CloudResult> readHeader(String path,
      {required bool allowDownload, required Duration timeout}) async {
    if (state != CloudState.ok) return CloudResult.unavailable;
    final b = files[path];
    if (b == null) return const CloudResult(CloudResultKind.missing);
    if (notDownloaded.contains(path)) {
      if (!allowDownload) return const CloudResult(CloudResultKind.notDownloaded);
      notDownloaded.remove(path);
    }
    final h = parseBackupHeader(b);
    return h == null
        ? const CloudResult(CloudResultKind.unknownOwner)
        : CloudResult(CloudResultKind.ok, header: h);
  }

  @override
  Future<CloudResult> fetch(String path, String destPath,
      {required Duration timeout}) async {
    final b = files[path];
    if (b == null) return const CloudResult(CloudResultKind.missing);
    notDownloaded.remove(path);
    await File(destPath).writeAsBytes(b);
    return CloudResult(CloudResultKind.ok, bytes: b.length);
  }

  final List<String> downloadsStarted = [];
  @override
  Future<void> startDownloads(List<String> paths) async {
    downloadsStarted.addAll(paths);
  }

  /// The downloads [startDownloads] started have finished.
  void finishDownloads() => notDownloaded.removeAll(downloadsStarted);

  /// CloudFiles.Expect.owns: never true for a header that cannot be read.
  static bool _owns(WriteExpect expect, String? id) =>
      id != null && (id == expect.installId || id == expect.adoptFrom);

  @override
  Future<CloudResult> write({
    required String path,
    required String sourcePath,
    required int bytes,
    required String sha256,
    required WriteExpect expect,
    String? keepPreviousPath,
    required bool allowDownload,
    required Duration timeout,
  }) async {
    if (state != CloudState.ok) return CloudResult.unavailable;
    final exists = files.containsKey(path);
    if (exists && notDownloaded.contains(path)) {
      return const CloudResult(CloudResultKind.notDownloaded);
    }
    final current = exists ? parseBackupHeader(files[path]!) : null;
    final verdict =
        checkOwner(exists: exists, header: current, expect: expect);
    switch (verdict) {
      case OwnerVerdict.allowed:
        break;
      case OwnerVerdict.ownedByOther:
        return CloudResult(CloudResultKind.ownedByOther, header: current);
      case OwnerVerdict.changedElsewhere:
        return CloudResult(CloudResultKind.changedElsewhere, header: current);
      case OwnerVerdict.unknownOwner:
        return const CloudResult(CloudResultKind.unknownOwner);
      case OwnerVerdict.absentNotAllowed:
        return const CloudResult(CloudResultKind.absentNotAllowed);
    }
    final foreign = (conflictVersions[path] ?? const <Uint8List>[])
        .where((v) => !_owns(expect, parseBackupHeader(v)?.installId));
    if (foreign.isNotEmpty) return const CloudResult(CloudResultKind.twoCopies);
    conflictVersions.remove(path);
    final src = await File(sourcePath).readAsBytes();
    final h = parseBackupHeader(src);
    if (src.length != bytes ||
        _sha(src) != sha256 ||
        h == null ||
        h.installId != expect.installId) {
      return const CloudResult(CloudResultKind.verifyFailed);
    }
    if (keepPreviousPath != null && exists) {
      final prev = files[keepPreviousPath];
      final prevOwner = prev == null ? null : parseBackupHeader(prev)?.installId;
      // CloudFiles.rotatePrevious: only over a downloaded copy this install
      // (or the adopted one) owns.
      if (prev == null ||
          (!notDownloaded.contains(keepPreviousPath) &&
              _owns(expect, prevOwner))) {
        files[keepPreviousPath] = files[path]!;
        log.add('rotate $keepPreviousPath');
      }
    }
    files[path] = src;
    log.add('write $path');
    return CloudResult(CloudResultKind.ok, bytes: bytes);
  }

  static String _sha(List<int> b) => sha256.convert(b).toString();

  @override
  Future<CloudResult> delete(List<String> paths, WriteExpect expect,
      {Duration timeout = const Duration(seconds: 20)}) async {
    var deleted = 0;
    for (final p in paths) {
      final b = files[p];
      if (b == null) continue;
      if (notDownloaded.contains(p)) {
        return CloudResult(CloudResultKind.notDownloaded, deleted: deleted);
      }
      final verdict = checkOwner(
          exists: true,
          header: parseBackupHeader(b),
          expect: WriteExpect(
              installId: expect.installId, adoptFrom: expect.adoptFrom));
      if (verdict != OwnerVerdict.allowed) continue;
      files.remove(p);
      log.add('delete $p');
      deleted++;
    }
    return CloudResult(CloudResultKind.ok, deleted: deleted);
  }

  @override
  Future<List<ConflictVersion>> conflicts(String path, String destDir) async {
    await Directory(destDir).create(recursive: true);
    final out = <ConflictVersion>[];
    final versions = conflictVersions[path] ?? const <Uint8List>[];
    for (var i = 0; i < versions.length; i++) {
      final p = '$destDir/conflict-$i.json';
      await File(p).writeAsBytes(versions[i]);
      out.add(ConflictVersion(p, parseBackupHeader(versions[i])));
    }
    return out;
  }

  @override
  Future<bool> resolveConflicts(String path, List<String> installIds) async {
    final left = (conflictVersions[path] ?? const <Uint8List>[])
        .where((v) => !installIds.contains(parseBackupHeader(v)?.installId))
        .toList();
    if (left.isEmpty) {
      conflictVersions.remove(path);
    } else {
      conflictVersions[path] = left;
    }
    return true;
  }

  List<String> picked = const [];
  @override
  Future<CloudResult> pickFiles() async =>
      CloudResult(CloudResultKind.ok, paths: picked);

  @override
  Future<Duration?> backgroundTimeRemaining() async => backgroundLeft;
}
