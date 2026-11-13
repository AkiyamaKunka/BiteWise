/// The iCloud side of iCloud Backup (1.7.0), as Dart sees it:
/// [BackupTransport], with [ICloudTransport] over the
/// `dev.calorietracker/cloudbackup` channel (ios/Runner/
/// CloudBackupPlugin.swift) and [NoTransport] where there is no iCloud
/// (Android, tests that never back up). test/support/
/// fake_cloud_transport.dart is an in-memory one with the same owner rule.
///
/// Paths are relative to iCloud Drive › Chopstats (the container's
/// Documents folder): `Chopstats Backup.json`, `Meal Pictures/2026-10.json`.
/// Nothing here ever throws for iCloud trouble: every call answers with a
/// [CloudResult] whose [CloudResult.kind] says what happened.
library;

import 'package:flutter/services.dart';

import 'backup_format.dart';

const String cloudBackupChannelName = 'dev.calorietracker/cloudbackup';

/// noAccount: iOS gives no iCloud identity, which it does when signed out
/// and also while iCloud Drive is off for the phone or for Chopstats,
/// without saying which. unavailable: an identity but no container, or a
/// build without iCloud (CloudBackupPlugin.statusName).
enum CloudState { ok, noAccount, unavailable }

class CloudStatus {
  const CloudStatus(this.state, {this.accountChanged = false});
  final CloudState state;

  /// The signed-in iCloud account is not the one of the last status call
  /// (reported once).
  final bool accountChanged;
}

/// One .json file the metadata query sees.
class CloudItem {
  const CloudItem({
    required this.path,
    this.downloading = false,
    this.uploaded = true,
    this.uploading = false,
    this.hasConflicts = false,
    this.uploadError,
    this.downloadError,
  });
  final String path;

  /// Not (fully) on this phone yet.
  final bool downloading;
  final bool uploaded;
  final bool uploading;
  final bool hasConflicts;

  /// 'quota' | 'serverUnavailable' | … (CloudFiles.errorReply's status).
  final String? uploadError;
  final String? downloadError;

  bool get topLevel => !path.contains('/');
}

class CloudListing {
  const CloudListing(
      {this.watching = false,
      this.gathered = false,
      this.live = Duration.zero,
      this.items = const []});
  final bool watching;

  /// The query finished its first gathering.
  final bool gathered;

  /// How long since it did: a query that has been live a while and still
  /// shows no backup is the evidence that there is none (guard G4).
  final Duration live;
  final List<CloudItem> items;

  CloudItem? item(String path) {
    for (final i in items) {
      if (i.path == path) return i;
    }
    return null;
  }
}

enum ItemExists { yes, no, unknown }

class CloudItemState {
  const CloudItemState(this.exists,
      {this.downloading = false, this.hasConflicts = false});
  final ItemExists exists;
  final bool downloading;
  final bool hasConflicts;
}

enum CloudResultKind {
  ok,
  missing,
  notDownloaded,
  unknownOwner,
  ownedByOther,
  changedElsewhere,
  absentNotAllowed,
  verifyFailed,
  twoCopies,
  timeout,
  quota,
  serverUnavailable,
  unavailable,
  diskFull,
  locked,
  busy,
  cancelled,
  badArguments,
  error,
}

class CloudResult {
  const CloudResult(this.kind,
      {this.header,
      this.bytes,
      this.deleted = 0,
      this.refused = 0,
      this.left = 0,
      this.errorCode,
      this.paths = const []});
  final CloudResultKind kind;

  /// The file's header, when the reply carried one.
  final BackupHeader? header;
  final int? bytes;

  /// delete: the files removed; the files another install owns (never
  /// removed); the files left for now (not on this phone yet, with their
  /// download started, or busy), which a later delete may remove.
  final int deleted;
  final int refused;
  final int left;

  /// `domain:code` of an unmapped error.
  final String? errorCode;

  /// pickFiles: the picked copies.
  final List<String> paths;

  bool get ok => kind == CloudResultKind.ok;

  static const CloudResult unavailable = CloudResult(CloudResultKind.unavailable);
}

/// An unresolved version of a file another device wrote at the same time.
class ConflictVersion {
  const ConflictVersion(this.tmpPath, this.header);
  final String tmpPath;
  final BackupHeader? header;
}

abstract class BackupTransport {
  Future<CloudStatus> status();

  /// A hash of identifierForVendor, or null while iOS has none.
  Future<String?> deviceKey();

  /// Starts the metadata query. iOS: once the container is fetched in the
  /// process, and again when it comes back or the account changes
  /// (CloudBackupPlugin.swift, CloudQueryPlan). The launch calls it after
  /// [status].
  Future<void> startWatching();
  Future<void> stopWatching();
  Future<CloudListing> list();
  Future<CloudItemState> itemState(String path);
  Future<CloudResult> readHeader(String path,
      {required bool allowDownload, required Duration timeout});
  Future<CloudResult> fetch(String path, String destPath,
      {required Duration timeout});
  Future<void> startDownloads(List<String> paths);
  Future<CloudResult> write({
    required String path,
    required String sourcePath,
    required int bytes,
    required String sha256,
    required WriteExpect expect,
    String? keepPreviousPath,
    required bool allowDownload,
    required Duration timeout,
  });
  Future<CloudResult> delete(List<String> paths, WriteExpect expect,
      {Duration timeout = const Duration(seconds: 20)});
  Future<List<ConflictVersion>> conflicts(String path, String destDir);

  /// Marks resolved the conflict versions [installIds] wrote. True only
  /// when none is left unresolved (and within [timeout]).
  Future<bool> resolveConflicts(String path, List<String> installIds,
      {Duration timeout = const Duration(seconds: 30)});

  /// The document picker (JSON files, several at once): copies the user
  /// picked, or cancelled / unavailable.
  Future<CloudResult> pickFiles();

  /// UIApplication.backgroundTimeRemaining, null in the foreground.
  Future<Duration?> backgroundTimeRemaining();
}

CloudResultKind _kindOf(Object? status) => switch (status) {
      'ok' => CloudResultKind.ok,
      'missing' => CloudResultKind.missing,
      'notDownloaded' => CloudResultKind.notDownloaded,
      'unknownOwner' => CloudResultKind.unknownOwner,
      'ownedByOther' => CloudResultKind.ownedByOther,
      'changedElsewhere' => CloudResultKind.changedElsewhere,
      'absentNotAllowed' => CloudResultKind.absentNotAllowed,
      'verifyFailed' => CloudResultKind.verifyFailed,
      'twoCopies' => CloudResultKind.twoCopies,
      'timeout' => CloudResultKind.timeout,
      'quota' => CloudResultKind.quota,
      'serverUnavailable' => CloudResultKind.serverUnavailable,
      'unavailable' => CloudResultKind.unavailable,
      'diskFull' => CloudResultKind.diskFull,
      'locked' => CloudResultKind.locked,
      'busy' => CloudResultKind.busy,
      'cancelled' => CloudResultKind.cancelled,
      'badArguments' => CloudResultKind.badArguments,
      _ => CloudResultKind.error,
    };

/// A channel reply as a [CloudResult].
CloudResult cloudResultFromReply(Object? reply) {
  if (reply is! Map) return const CloudResult(CloudResultKind.error);
  final kind = _kindOf(reply['status']);
  final h = reply['header'];
  final header = h is Map ? backupHeaderFromEnvelope(h) : null;
  final domain = reply['domain'], code = reply['code'];
  return CloudResult(
    kind,
    header: header,
    bytes: (reply['bytes'] as num?)?.toInt(),
    deleted: (reply['deleted'] as num?)?.toInt() ?? 0,
    refused: (reply['refused'] as num?)?.toInt() ?? 0,
    left: (reply['left'] as num?)?.toInt() ?? 0,
    errorCode: domain is String && code is num ? '$domain:$code' : null,
    paths: [
      for (final p in (reply['paths'] as List?) ?? const [])
        if (p is String) p,
    ],
  );
}

class ICloudTransport implements BackupTransport {
  const ICloudTransport(
      [this._channel = const MethodChannel(cloudBackupChannelName)]);
  final MethodChannel _channel;

  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      return const {'status': 'unavailable'};
    } on PlatformException catch (e) {
      return {'status': 'error', 'domain': 'platform', 'code': e.code.hashCode};
    }
  }

  @override
  Future<CloudStatus> status() async {
    final r = await _call('status');
    if (r is! Map) return const CloudStatus(CloudState.unavailable);
    final state = switch (r['status']) {
      'ok' => CloudState.ok,
      'noAccount' => CloudState.noAccount,
      _ => CloudState.unavailable,
    };
    return CloudStatus(state, accountChanged: r['accountChanged'] == true);
  }

  @override
  Future<String?> deviceKey() async {
    final r = await _call('deviceKey');
    final key = r is Map ? r['key'] : null;
    return key is String && key.isNotEmpty ? key : null;
  }

  @override
  Future<void> startWatching() => _call('startWatching');

  @override
  Future<void> stopWatching() => _call('stopWatching');

  @override
  Future<CloudListing> list() async {
    final r = await _call('list');
    if (r is! Map) return const CloudListing();
    return CloudListing(
      watching: r['status'] == 'ok',
      gathered: r['gathered'] == true,
      live: Duration(milliseconds: (r['liveMs'] as num?)?.toInt() ?? 0),
      items: [
        for (final i in (r['items'] as List?) ?? const [])
          if (i is Map && i['path'] is String)
            CloudItem(
              path: i['path'] as String,
              downloading: i['downloading'] == true,
              uploaded: i['uploaded'] == true,
              uploading: i['uploading'] == true,
              hasConflicts: i['hasConflicts'] == true,
              uploadError: i['uploadError'] as String?,
              downloadError: i['downloadError'] as String?,
            ),
      ],
    );
  }

  @override
  Future<CloudItemState> itemState(String path) async {
    final r = await _call('itemState', {'path': path});
    if (r is! Map || r['status'] != 'ok') {
      return const CloudItemState(ItemExists.unknown);
    }
    return CloudItemState(
      switch (r['exists']) {
        'yes' => ItemExists.yes,
        'no' => ItemExists.no,
        _ => ItemExists.unknown,
      },
      downloading: r['downloading'] == true,
      hasConflicts: r['hasConflicts'] == true,
    );
  }

  @override
  Future<CloudResult> readHeader(String path,
          {required bool allowDownload, required Duration timeout}) async =>
      cloudResultFromReply(await _call('readHeader', {
        'path': path,
        'allowDownload': allowDownload,
        'timeoutMs': timeout.inMilliseconds,
      }));

  @override
  Future<CloudResult> fetch(String path, String destPath,
          {required Duration timeout}) async =>
      cloudResultFromReply(await _call('fetch', {
        'path': path,
        'destPath': destPath,
        'timeoutMs': timeout.inMilliseconds,
      }));

  @override
  Future<void> startDownloads(List<String> paths) =>
      _call('startDownloads', {'paths': paths});

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
  }) async =>
      cloudResultFromReply(await _call('write', {
        'path': path,
        'sourcePath': sourcePath,
        'bytes': bytes,
        'sha256': sha256,
        'expect': expect.toMap(),
        'keepPreviousPath': keepPreviousPath,
        'allowDownload': allowDownload,
        'timeoutMs': timeout.inMilliseconds,
      }));

  @override
  Future<CloudResult> delete(List<String> paths, WriteExpect expect,
          {Duration timeout = const Duration(seconds: 20)}) async =>
      cloudResultFromReply(await _call('delete', {
        'paths': paths,
        'expect': expect.toMap(),
        'timeoutMs': timeout.inMilliseconds,
      }));

  @override
  Future<List<ConflictVersion>> conflicts(String path, String destDir) async {
    final r = await _call('conflicts', {'path': path, 'destDir': destDir});
    if (r is! Map || r['status'] != 'ok') return const [];
    return [
      for (final v in (r['versions'] as List?) ?? const [])
        if (v is Map && v['tmpPath'] is String)
          ConflictVersion(
              v['tmpPath'] as String,
              v['header'] is Map
                  ? backupHeaderFromEnvelope(v['header'] as Map)
                  : null),
    ];
  }

  @override
  Future<bool> resolveConflicts(String path, List<String> installIds,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final r = await _call('resolveConflicts', {
      'path': path,
      'installIds': installIds,
      'timeoutMs': timeout.inMilliseconds,
    });
    // A version nobody listed (another install's, or unreadable) is still
    // unresolved: the conflict is not settled.
    return r is Map &&
        r['status'] == 'ok' &&
        ((r['left'] as num?)?.toInt() ?? 0) == 0;
  }

  @override
  Future<CloudResult> pickFiles() async =>
      cloudResultFromReply(await _call('pickFiles'));

  @override
  Future<Duration?> backgroundTimeRemaining() async {
    final r = await _call('backgroundTimeRemaining');
    final ms = r is Map ? r['ms'] : null;
    return ms is num ? Duration(milliseconds: ms.toInt()) : null;
  }
}

/// No iCloud here: every call says so.
class NoTransport implements BackupTransport {
  const NoTransport();
  @override
  Future<CloudStatus> status() async =>
      const CloudStatus(CloudState.unavailable);
  @override
  Future<String?> deviceKey() async => null;
  @override
  Future<void> startWatching() async {}
  @override
  Future<void> stopWatching() async {}
  @override
  Future<CloudListing> list() async => const CloudListing();
  @override
  Future<CloudItemState> itemState(String path) async =>
      const CloudItemState(ItemExists.unknown);
  @override
  Future<CloudResult> readHeader(String path,
          {required bool allowDownload, required Duration timeout}) async =>
      CloudResult.unavailable;
  @override
  Future<CloudResult> fetch(String path, String destPath,
          {required Duration timeout}) async =>
      CloudResult.unavailable;
  @override
  Future<void> startDownloads(List<String> paths) async {}
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
  }) async =>
      CloudResult.unavailable;
  @override
  Future<CloudResult> delete(List<String> paths, WriteExpect expect,
          {Duration timeout = const Duration(seconds: 20)}) async =>
      CloudResult.unavailable;
  @override
  Future<List<ConflictVersion>> conflicts(String path, String destDir) async =>
      const [];
  @override
  Future<bool> resolveConflicts(String path, List<String> installIds,
          {Duration timeout = const Duration(seconds: 30)}) async =>
      false;
  @override
  Future<CloudResult> pickFiles() async => CloudResult.unavailable;
  @override
  Future<Duration?> backgroundTimeRemaining() async => null;
}
