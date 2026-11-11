/// The iCloud Backup file format (1.7.0): constants, the `backup` header
/// every backup file carries, how both Dart and Swift read that header
/// back, and the owner rule the Swift writer applies before it replaces a
/// file (CloudFiles.swift `checkOwner` is the same rule).
///
/// A backup file IS an export envelope (data/meals_logic.dart): format
/// `calorie_tracker_export`, version 2, so 1.6.0's importer reads it. The
/// header sits between `exported_at` and `tables`, and holds no user text:
/// ids, counts, dates and month names only.
///
/// ```
/// {"format":"calorie_tracker_export","version":2,"exported_at":"…",
///  "backup":{"kind":"records","install_id":"<32 hex>","seq":17,
///            "platform":"ios","app_version":"1.7.0","meals":412,
///            "thumbs":398,"thumbs_skipped":3,"first_date":"…",
///            "last_date":"…","months":{"2026-10":93}},
///  "tables":{…}}
/// ```
///
/// Reading the owner (both languages): the first [kBackupHeaderLimit]
/// bytes, cut at the first `,"tables":`, closed with `}`, decoded; the
/// format tag, an integer version of 2 or more, a known kind, a 32-hex
/// install id and an integer seq are required. Anything else is an
/// unknown owner.
///
/// This file must stay free of the key stores, the local store and the
/// consent keys (backup_privacy_test.dart scans it).
library;

import 'dart:convert';

import '../../data/meals_logic.dart' show kExportFormat, kExportVersion;

/// The iCloud container. MUST equal CloudBackupPlugin.containerIdentifier
/// (ios/Runner/CloudBackupPlugin.swift), and, once the entitlement is on,
/// Runner.entitlements and Info.plist NSUbiquitousContainers
/// (backup_container_pin_test.dart).
const String kICloudContainerId = 'iCloud.dev.calorietracker.calorieTracker';

/// iCloud Backup starts ON (owner decision 2026-11-10); nothing uploads
/// until the one-time notice is answered.
const bool kCloudBackupDefaultOn = true;

/// The envelope version backup files and 1.7.0 exports carry; a backup
/// header is only read from version 2 up.
const int kBackupEnvelopeVersion = kExportVersion;

/// Everything before `,"tables":` fits in this many bytes.
const int kBackupHeaderLimit = 16 * 1024;

/// Files under iCloud Drive › Chopstats (paths relative to the
/// container's Documents folder).
const String kRecordsFileName = 'Chopstats Backup.json';
const String kPreviousFileName = 'Chopstats Backup (previous).json';
const String kPicturesFolder = 'Meal Pictures';

/// A picked or downloaded file over this is refused before it is read.
const int kMaxImportFileBytes = 100 * 1024 * 1024;

/// A thumbnail row over this, or one that is not a JPEG, is not imported.
const int kMaxThumbBytes = 64 * 1024;

/// `Meal Pictures/2026-10.json`.
String picturesPath(String month) => '$kPicturesFolder/$month.json';

/// The month a pictures path names, or null.
String? monthOfPicturesPath(String path) {
  final m = RegExp(r'^Meal Pictures/(\d{4}-\d{2})\.json$').firstMatch(path);
  return m?.group(1);
}

/// A meal's month: `substr(date, 1, 7)` (`2026-10`), null when the date
/// does not start with one.
String? monthOfDate(String date) {
  if (date.length < 7) return null;
  final m = date.substring(0, 7);
  return RegExp(r'^\d{4}-\d{2}$').hasMatch(m) ? m : null;
}

final RegExp _installIdRe = RegExp(r'^[0-9a-f]{32}$');

bool isValidInstallId(String? id) => id != null && _installIdRe.hasMatch(id);

enum BackupKind { records, pictures, full }

BackupKind? backupKindFromName(Object? name) => switch (name) {
      'records' => BackupKind.records,
      'pictures' => BackupKind.pictures,
      'full' => BackupKind.full,
      _ => null,
    };

/// The `backup` object of a backup file.
class BackupHeader {
  const BackupHeader({
    required this.kind,
    required this.installId,
    required this.seq,
    this.platform = '',
    this.appVersion = '',
    this.meals = 0,
    this.thumbs = 0,
    this.thumbsSkipped = 0,
    this.firstDate,
    this.lastDate,
    this.months = const {},
    this.month,
    this.exportedAt,
    this.version = kBackupEnvelopeVersion,
  });

  final BackupKind kind;
  final String installId;

  /// Rises by one with every records write of [installId]; `full` files
  /// carry 0; a pictures file carries the records seq it was written for.
  final int seq;
  final String platform;
  final String appVersion;
  final int meals;
  final int thumbs;
  final int thumbsSkipped;
  final String? firstDate;
  final String? lastDate;

  /// records and full: each month that has pictures, and how many.
  final Map<String, int> months;

  /// pictures only.
  final String? month;

  /// The envelope's exported_at (read back only).
  final String? exportedAt;
  final int version;

  /// The `backup` object, keys in the pinned order.
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'install_id': installId,
        'seq': seq,
        'platform': platform,
        'app_version': appVersion,
        'meals': meals,
        'thumbs': thumbs,
        'thumbs_skipped': thumbsSkipped,
        'first_date': firstDate,
        'last_date': lastDate,
        if (kind != BackupKind.pictures) 'months': months,
        if (kind == BackupKind.pictures) 'month': month,
      };

  /// Everything a backup file holds before its tables, ending with
  /// `"tables":` — the writer streams the tables object after it.
  String envelopePrefix(DateTime exportedAt) {
    final head = jsonEncode(<String, Object?>{
      'format': kExportFormat,
      'version': kBackupEnvelopeVersion,
      'exported_at': exportedAt.toIso8601String(),
      'backup': toJson(),
    });
    // Drop the closing brace; the caller writes the tables and closes it.
    return '${head.substring(0, head.length - 1)},"tables":';
  }
}

/// Reads the header from the first bytes of a file (at most
/// [kBackupHeaderLimit] are looked at). Null = unknown owner.
BackupHeader? parseBackupHeader(List<int> prefix) {
  final bytes =
      prefix.length > kBackupHeaderLimit ? prefix.sublist(0, kBackupHeaderLimit) : prefix;
  final text = utf8.decode(bytes, allowMalformed: true);
  final cut = text.indexOf(',"tables":');
  if (cut < 0) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode('${text.substring(0, cut)}}');
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  return backupHeaderFromEnvelope(decoded);
}

/// The header of an already-decoded envelope map, or null when it is not
/// a valid backup file (see the library docs).
BackupHeader? backupHeaderFromEnvelope(Map<Object?, Object?> envelope) {
  if (envelope['format'] != kExportFormat) return null;
  final version = envelope['version'];
  if (version is! int || version < kBackupEnvelopeVersion) return null;
  final b = envelope['backup'];
  if (b is! Map) return null;
  final kind = backupKindFromName(b['kind']);
  final id = b['install_id'];
  final seq = b['seq'];
  if (kind == null || id is! String || !isValidInstallId(id) || seq is! int) {
    return null;
  }
  int count(Object? v) => v is int && v >= 0 ? v : 0;
  String? date(Object? v) => v is String && v.length <= 32 ? v : null;
  final months = <String, int>{};
  final rawMonths = b['months'];
  if (rawMonths is Map) {
    rawMonths.forEach((k, v) {
      if (k is String && RegExp(r'^\d{4}-\d{2}$').hasMatch(k) && v is int) {
        months[k] = v;
      }
    });
  }
  final month = b['month'];
  final stamp = envelope['exported_at'];
  String text(Object? v) => v is String && v.length <= 64 ? v : '';
  return BackupHeader(
    kind: kind,
    installId: id,
    seq: seq,
    platform: text(b['platform']),
    appVersion: text(b['app_version']),
    meals: count(b['meals']),
    thumbs: count(b['thumbs']),
    thumbsSkipped: count(b['thumbs_skipped']),
    firstDate: date(b['first_date']),
    lastDate: date(b['last_date']),
    months: months,
    month: month is String && RegExp(r'^\d{4}-\d{2}$').hasMatch(month)
        ? month
        : null,
    exportedAt: stamp is String ? stamp : null,
    version: version,
  );
}

/// What a writer may replace: sent with every automatic write and delete,
/// and checked by Swift inside the coordinated access.
class WriteExpect {
  const WriteExpect({
    required this.installId,
    this.seqs,
    this.adoptFrom,
    this.allowAbsent = false,
    this.replaceUnknown = false,
  });

  /// This install (Start Fresh: the install whose backup is deleted, so
  /// that only its files go).
  final String installId;

  /// The seqs of [installId]'s own file that may be replaced; null = any
  /// (pictures files, deletes).
  final List<int>? seqs;

  /// An install whose file the user chose to restore or take over: its
  /// file may be replaced whatever its seq.
  final String? adoptFrom;

  /// Whether a missing file may be created.
  final bool allowAbsent;

  /// Only the user's "Replace" on a file whose header cannot be read.
  final bool replaceUnknown;

  Map<String, Object?> toMap() => {
        'installId': installId,
        'seqs': seqs,
        'adoptFrom': adoptFrom,
        'allowAbsent': allowAbsent,
        'replaceUnknown': replaceUnknown,
      };
}

enum OwnerVerdict {
  allowed,
  ownedByOther,
  changedElsewhere,
  unknownOwner,
  absentNotAllowed,
}

/// The owner rule (CloudFiles.swift checkOwner is the same):
/// - a missing file may be created only with [WriteExpect.allowAbsent];
/// - an unreadable header is never replaced, unless [replaceUnknown];
/// - the adopted install's file may be replaced;
/// - this install's own file only at one of the expected seqs;
/// - anything else belongs to another install.
OwnerVerdict checkOwner({
  required bool exists,
  required BackupHeader? header,
  required WriteExpect expect,
}) {
  if (!exists) {
    return expect.allowAbsent
        ? OwnerVerdict.allowed
        : OwnerVerdict.absentNotAllowed;
  }
  if (header == null) {
    return expect.replaceUnknown
        ? OwnerVerdict.allowed
        : OwnerVerdict.unknownOwner;
  }
  final adopt = expect.adoptFrom;
  if (adopt != null && header.installId == adopt) return OwnerVerdict.allowed;
  if (header.installId == expect.installId) {
    final seqs = expect.seqs;
    return seqs == null || seqs.contains(header.seq)
        ? OwnerVerdict.allowed
        : OwnerVerdict.changedElsewhere;
  }
  return OwnerVerdict.ownedByOther;
}
