/// Writes backup and export files to a local path (1.7.0): the records file,
/// one month's pictures, or the full export (records and every picture).
///
/// Streamed through an IOSink one table, and for pictures one month, at a
/// time: a full export of a few years is tens of MB of base64, and building
/// it as one string would hold it twice in memory. The SHA-256 is computed
/// over exactly the bytes written, so the Swift writer can check the file
/// it is about to put in iCloud is the one Dart made.
///
/// Pictures go through [stripThumbnailJpeg]; one that cannot be cleaned is
/// left out and counted in `thumbs_skipped`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/contracts.dart';
import '../../data/db.dart' show kExportTables;
import 'backup_format.dart';
import 'jpeg_strip.dart';

/// The app's version, written into every backup header. MUST equal the
/// x.y.z of `version:` in pubspec.yaml (backup_files_test.dart pins it).
const String kAppVersion = '1.7.0';

/// A file [BackupFileWriter] wrote.
class WrittenBackupFile {
  const WrittenBackupFile(this.path, this.bytes, this.sha256, this.header);
  final String path;
  final int bytes;
  final String sha256;
  final BackupHeader header;
}

class BackupFileWriter {
  BackupFileWriter({
    required this.dao,
    required this.platform,
    this.appVersion = kAppVersion,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MealsDao dao;

  /// 'ios' | 'android'.
  final String platform;
  final String appVersion;
  final DateTime Function() _clock;

  /// The records file: the export tables, one moment's state. [months] is
  /// each month's picture count as the pictures files hold them.
  Future<WrittenBackupFile> writeRecords(
    String path, {
    required String installId,
    required int seq,
    required Map<String, int> months,
    int thumbsSkipped = 0,
  }) async {
    final tables = await dao.backupRecordTables();
    final header = _recordsHeader(BackupKind.records, tables,
        installId: installId,
        seq: seq,
        months: months,
        thumbsSkipped: thumbsSkipped);
    final out = _HashingFile(path);
    try {
      out.write(header.envelopePrefix(_clock().toUtc()));
      out.write('{');
      _writeTables(out, tables);
      out.write('}}');
      return await out.finish(header);
    } catch (_) {
      await out.abandon();
      rethrow;
    }
  }

  /// One month's pictures. The header's `thumbs` is how many went in,
  /// `thumbs_skipped` how many could not be cleaned.
  Future<WrittenBackupFile> writePictures(
    String path, {
    required String installId,
    required int seq,
    required String month,
  }) async {
    // The month is read before the file is opened, as the records are: an
    // IOSink whose file fails to open before anything was added to it
    // reports that error to no one (an uncaught error), so nothing may be
    // awaited between opening and the first write.
    final rows = <String>[];
    var skipped = 0;
    for (final t in await dao.thumbsForMonth(month)) {
      final row = _thumbRow(t);
      if (row == null) {
        skipped++;
      } else {
        rows.add(row);
      }
    }
    final out = _HashingFile(path);
    try {
      final header = BackupHeader(
        kind: BackupKind.pictures,
        installId: installId,
        seq: seq,
        platform: platform,
        appVersion: appVersion,
        thumbs: rows.length,
        thumbsSkipped: skipped,
        month: month,
      );
      out.write(header.envelopePrefix(_clock().toUtc()));
      out.write('{"meal_thumbs":[');
      for (var i = 0; i < rows.length; i++) {
        if (i > 0) out.write(',');
        out.write(rows[i]);
      }
      out.write(']}}');
      return await out.finish(header);
    } catch (_) {
      await out.abandon();
      rethrow;
    }
  }

  /// The tables and month prints a full export starts from: read before
  /// anything touches the disk, so a database failure is reported as such.
  Future<FullSnapshot> snapshotFull() async => FullSnapshot(
      await dao.backupRecordTables(), await dao.thumbMonthPrints());

  /// Settings › Export: the records and every picture, one month at a
  /// time, kind `full`, seq 0. [installId] is this install's when it has
  /// one; any valid id will do (the importer only reads the kind).
  Future<WrittenBackupFile> writeFull(String path,
      {required String installId, FullSnapshot? snapshot}) async {
    final snap = snapshot ?? await snapshotFull();
    final tables = snap.tables;
    final prints = snap.prints;
    final months = (prints.keys.toList()..sort());
    final out = _HashingFile(path);
    try {
      // The header is written first, so the month counts in it are what
      // the database says now; a picture that cannot be cleaned is still
      // counted in thumbs_skipped below (the header cannot be rewritten,
      // so it says how many the months held).
      final header = _recordsHeader(BackupKind.full, tables,
          installId: installId,
          seq: 0,
          months: {for (final m in months) m: prints[m]!.count});
      out.write(header.envelopePrefix(_clock().toUtc()));
      out.write('{');
      _writeTables(out, tables);
      out.write(',"meal_thumbs":[');
      var first = true;
      for (final m in months) {
        for (final t in await dao.thumbsForMonth(m)) {
          final row = _thumbRow(t);
          if (row == null) continue;
          if (!first) out.write(',');
          first = false;
          out.write(row);
        }
      }
      out.write(']}}');
      return await out.finish(header);
    } catch (_) {
      await out.abandon();
      rethrow;
    }
  }

  BackupHeader _recordsHeader(
    BackupKind kind,
    Map<String, List<Map<String, Object?>>> tables, {
    required String installId,
    required int seq,
    required Map<String, int> months,
    int thumbsSkipped = 0,
  }) {
    final meals = tables['meals'] ?? const [];
    String? first, last;
    for (final m in meals) {
      final d = m['date'];
      if (d is! String || d.isEmpty) continue;
      if (first == null || d.compareTo(first) < 0) first = d;
      if (last == null || d.compareTo(last) > 0) last = d;
    }
    return BackupHeader(
      kind: kind,
      installId: installId,
      seq: seq,
      platform: platform,
      appVersion: appVersion,
      meals: meals.length,
      thumbs: months.values.fold(0, (a, b) => a + b),
      thumbsSkipped: thumbsSkipped,
      // Dates only (YYYY-MM-DD as stored): never user text.
      firstDate: first == null ? null : _dateOnly(first),
      lastDate: last == null ? null : _dateOnly(last),
      months: months,
    );
  }

  static String? _dateOnly(String d) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch(d)?.group(0);

  void _writeTables(
      _HashingFile out, Map<String, List<Map<String, Object?>>> tables) {
    var firstTable = true;
    for (final name in kExportTables) {
      final rows = tables[name] ?? const [];
      if (!firstTable) out.write(',');
      firstTable = false;
      out.write('${jsonEncode(name)}:[');
      for (var i = 0; i < rows.length; i++) {
        if (i > 0) out.write(',');
        out.write(jsonEncode(rows[i]));
      }
      out.write(']');
    }
  }

  static String? _thumbRow(BackupThumb t) {
    if (t.imageHash.isEmpty) return null;
    final clean = stripThumbnailJpeg(t.jpeg);
    if (clean == null || clean.length > kMaxThumbBytes) return null;
    return jsonEncode({
      'chat_id': t.chatId,
      'image_hash': t.imageHash,
      'jpeg_b64': base64Encode(clean),
    });
  }
}

/// What [BackupFileWriter.snapshotFull] read.
class FullSnapshot {
  const FullSnapshot(this.tables, this.prints);
  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, ThumbMonthPrint> prints;
}

/// A file written through an IOSink with its SHA-256 and size kept along
/// the way.
class _HashingFile {
  _HashingFile(this.path)
      : _sink = (File(path)..parent.createSync(recursive: true)).openWrite() {
    _hash = sha256.startChunkedConversion(_digest);
  }

  final String path;
  final IOSink _sink;
  final _DigestSink _digest = _DigestSink();
  late final ByteConversionSink _hash;
  int _bytes = 0;

  void write(String s) {
    final b = utf8.encode(s);
    _sink.add(b);
    _hash.add(b);
    _bytes += b.length;
  }

  Future<WrittenBackupFile> finish(BackupHeader header) async {
    await _sink.flush();
    await _sink.close();
    _hash.close();
    return WrittenBackupFile(path, _bytes, _digest.value.toString(), header);
  }

  Future<void> abandon() async {
    try {
      await _sink.close();
    } catch (_) {}
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;
  @override
  void add(Digest data) => _value = data;
  @override
  void close() {}
}
