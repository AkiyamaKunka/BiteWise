/// iCloud Backup (1.7.0, iPhone): when to back up, what may be written,
/// and the user's choices — restore, take over, combine, turn off, delete.
///
/// Owner decisions (2026-11-10): the meal record survives a delete and
/// reinstall or a move to another phone without any account and without
/// the developer or any server holding it; the backup goes to the user's
/// OWN iCloud Drive (Chopstats folder, visible in Files), ON by default;
/// pictures are included; nothing is released without the owner's go.
///
/// Files (paths under iCloud Drive › Chopstats):
///   Chopstats Backup.json             kind records — the export tables
///   Chopstats Backup (previous).json  the records file before today's
///                                     first write (rotated at most daily)
///   Meal Pictures/YYYY-MM.json        kind pictures — that month's photos
///
/// Only the install that owns a file writes it, proven by its header's
/// (install_id, seq); Swift checks it again inside the coordinated access
/// (CloudFiles.swift). A restore is always a merge through importJson.
///
/// Guards on every automatic run (design §3.2):
///   G1 enabled, and the notice answered Keep On;
///   G2 something logged (meals, weigh-ins, measurements, workouts or
///      activities);
///   G3 the owner rule;
///   G4 first write only: the metadata query live 60 s in the foreground
///      with no unanswered backup of another install, first seen empty
///      at least 24 h ago (Back Up Now skips the 24 h);
///   G5 a file of 20+ meals is never replaced by one with under half;
///   G6 nothing changed (the data_changes counter, the month prints);
///   G7 iCloud available, the same account, the same device key;
///   G8 background runs never write first, adopt, download, ask or create
///      ids;
///   G9 a file this install wrote that has gone pauses backups;
///   G10 an empty log on the owner phone writes nothing.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/coerce.dart' show isoDate;
import '../../core/contracts.dart';
import 'backup_files.dart';
import 'backup_format.dart';
import 'backup_prefs.dart';
import 'cloud_backup_channel.dart';

/// What Settings › Your Data says about the backup (one status line each).
enum BackupState {
  off,
  needsNotice,
  checking,
  never,
  ok,
  uploading,
  quota,
  noAccount,
  unavailable,
  otherDevice,
  changedElsewhere,
  unknownFile,
  twoCopies,
  missing,
  shrink,
  emptyLog,
  failed,
}

/// A records-kind backup of another install, offered for restore.
class BackupCandidate {
  const BackupCandidate(this.path, this.header);
  final String path;
  final BackupHeader header;
}

class BackupStatus {
  const BackupStatus(
    this.state, {
    this.lastOkAt,
    this.bytes = 0,
    this.other,
    this.count = 0,
    this.busy = false,
    this.restorable = const [],
    this.skippedMonths = 0,
    this.ownsFiles = false,
  });

  final BackupState state;
  final DateTime? lastOkAt;

  /// What the last successful run wrote (the app's own count).
  final int bytes;

  /// otherDevice / changedElsewhere: the header of the file in the way.
  final BackupHeader? other;

  /// shrink: the meals in the file the write would have replaced;
  /// emptyLog: the meals in the last file this install wrote.
  final int count;

  /// A restore, takeover, combine or delete is running.
  final bool busy;

  /// Backups of other installs seen in the folder (Restore From iCloud…).
  final List<BackupCandidate> restorable;

  /// Months with pictures on this phone whose file is another install's,
  /// so the last run did not back them up.
  final int skippedMonths;

  /// This install wrote backup files that may still be in iCloud (with the
  /// files it took over, once its own records file replaced the adopted
  /// one): Delete iCloud Backup… is offered whatever the switch says (with
  /// it off, there is no other way to them).
  final bool ownsFiles;

  bool get canTakeOver => const {
        BackupState.otherDevice,
        BackupState.changedElsewhere,
        BackupState.unknownFile,
      }.contains(state);

  BackupStatus copyWith({bool? busy, List<BackupCandidate>? restorable}) =>
      BackupStatus(state,
          lastOkAt: lastOkAt,
          bytes: bytes,
          other: other,
          count: count,
          busy: busy ?? this.busy,
          restorable: restorable ?? this.restorable,
          skippedMonths: skippedMonths,
          ownsFiles: ownsFiles);
}

/// A question for the app shell to ask in the foreground, one at a time.
sealed class BackupPrompt {
  const BackupPrompt();
}

/// A backup of another install was found: Restore / Start Fresh / Not Now.
class RestoreOfferPrompt extends BackupPrompt {
  const RestoreOfferPrompt(this.candidate, this.localMeals);
  final BackupCandidate candidate;

  /// Meals already on this phone: the sheet warns that restoring adds to
  /// them.
  final int localMeals;
}

/// The one-time notice: Keep On / Turn Off.
class NoticePrompt extends BackupPrompt {
  const NoticePrompt();
}

/// What a delete of backup files came to.
enum BackupDeleteResult {
  /// Every file it set out to delete is gone (another install's stay).
  deleted,

  /// Some went and some are left for now (not downloaded to this phone in
  /// time, or busy): the backup is still known, so Delete can be tried
  /// again.
  partial,

  /// Nothing was deleted.
  failed,
}

class RestoreSummary {
  const RestoreSummary({
    this.ok = true,
    this.mealsAdded = 0,
    this.thumbsAdded = 0,
    this.mealsSkippedDeleted = 0,
    this.failedMonths = 0,
  });
  final bool ok;
  final int mealsAdded;
  final int thumbsAdded;
  final int mealsSkippedDeleted;

  /// Months of pictures that could not be read (the rest came in).
  final int failedMonths;
}

enum _Kind { launch, foreground, background, headless, now }

class _Run {
  const _Run(
    this.kind, {
    this.force = false,
    this.skipWait = false,
    this.allowMissing = false,
    this.overrideShrink = false,
    this.takeover = false,
    this.replaceUnknown = false,
    this.timeout = const Duration(seconds: 20),
  });
  final _Kind kind;

  /// Write even when nothing changed (G6).
  final bool force;

  /// The first write without the 24 h wait (G4).
  final bool skipWait;

  /// Back Up Again: create the records file that went missing (G9).
  final bool allowMissing;

  /// Back Up Anyway (G5).
  final bool overrideShrink;

  /// After the user chose to take over: no G4, the adopted file replaced.
  final bool takeover;
  final bool replaceUnknown;
  final Duration timeout;

  bool get background => kind == _Kind.background || kind == _Kind.headless;
}

class BackupCoordinator {
  BackupCoordinator({
    required MealsDao dao,
    required BackupTransport transport,
    required SharedPreferences prefs,
    required this.tempDir,
    this.uiEngine = true,
    String platform = 'ios',
    DateTime Function()? clock,
    Random? random,
    Future<void> Function(String name, Future<void> Function() body)?
        backgroundGuard,
    this.onDataImported,
    this.onCatchUpReleased,
    this.debounce = const Duration(minutes: 2),
    this.pollEvery = const Duration(minutes: 5),
    this.gatherWait = const Duration(seconds: 90),
    this.gatherPoll = const Duration(seconds: 2),
  })  : _dao = dao,
        _t = transport,
        _prefs = BackupPrefs(prefs),
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure(),
        _guard = backgroundGuard,
        _writer = BackupFileWriter(dao: dao, platform: platform, clock: clock) {
    _status = ValueNotifier(_statusFromPrefs());
    // The launch's look for a backup to offer: the shell starts it after
    // the first frame, and init asks about the photo catch-up before that.
    if (uiEngine) {
      _deciding = Completer<void>();
      _decidingSince = _now;
    }
  }

  final MealsDao _dao;
  final BackupTransport _t;
  final BackupPrefs _prefs;

  /// The app's temporary folder (snapshots and fetched files go in an
  /// icloud_backup folder inside it and are deleted after each step).
  final Future<Directory> Function() tempDir;
  final DateTime Function() _clock;
  final Random _random;
  final Future<void> Function(String, Future<void> Function())? _guard;
  final BackupFileWriter _writer;

  /// Only the app's engine creates ids, asks, adopts or downloads (G8).
  final bool uiEngine;

  /// After a restore, takeover or combine brought rows in: the screens
  /// reload and the thumbnail cache is cleared.
  final void Function()? onDataImported;

  /// The app's engine: a restore offer or a restore (or a takeover or
  /// combine that merged another install's backup in) stopped holding the
  /// photo catch-up. The photos it kept back are caught up then (di.dart),
  /// not only at the next return to the app: the launch or resume catch-up
  /// asked while it held, and the live watcher's photos were released.
  /// Not while something else still holds it ([holdsPhotosNow]).
  final void Function()? onCatchUpReleased;

  final Duration debounce;
  final Duration pollEvery;
  final Duration gatherWait;
  final Duration gatherPoll;

  static const Duration minForegroundGap = Duration(minutes: 15);
  static const Duration minBackgroundGap = Duration(minutes: 5);
  static const Duration launchStaleAfter = Duration(hours: 1);
  static const Duration firstWriteQuery = Duration(seconds: 60);
  static const Duration firstWriteWait = Duration(hours: 24);
  static const Duration catchUpLease = Duration(minutes: 30);
  static const int shrinkFloor = 20;

  /// How much longer than [gatherWait] [holdsCatchUp] waits, at most, for
  /// a look for a backup to offer to decide (the status call, the query
  /// starting, the headers read).
  static const Duration lookSlack = Duration(seconds: 60);

  late final ValueNotifier<BackupStatus> _status;
  ValueListenable<BackupStatus> get status => _status;

  /// The question the app shell should ask next, if any.
  final ValueNotifier<BackupPrompt?> prompt = ValueNotifier(null);

  /// Records-kind files seen by the last scan, by install.
  List<BackupCandidate> _restorable = const [];
  CloudListing? _listing;
  bool _foreground = true;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  Timer? _refreshTimer;
  int? _seenRecords;
  int? _seenThumbs;

  /// The look for a backup to offer, until it has decided whether to offer
  /// one (or ended without deciding): the photo catch-up waits for it
  /// ([holdsCatchUp]). Pending from the start in the app's engine.
  Completer<void>? _deciding;

  /// When [_deciding] began ([holdsPhotosNow] waits no longer than
  /// [holdsCatchUp] does).
  DateTime? _decidingSince;

  /// A look for a backup to offer got as far as deciding (an offer, the
  /// notice, or nothing to ask) for the iCloud account of now. One that
  /// ended before (no iCloud identity, the query not gathered in time, the
  /// app left meanwhile, another account) looks again at the next return
  /// to the app ([_onResume]).
  bool _decided = false;

  void _endDeciding() {
    final d = _deciding;
    _deciding = null;
    if (d != null && !d.isCompleted) d.complete();
  }

  // ------------------------------------------------------------- the lock

  Future<void> _tail = Future.value();

  /// One run, restore or choice at a time.
  Future<T> _locked<T>(Future<T> Function() body) {
    final next = _tail.then((_) => body());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  // ------------------------------------------------------------ the status

  /// Whether this install has backup files of its own that a delete would
  /// remove. An adopted install's files count only once this install's
  /// records file replaced theirs (lastSeq, [_adoptionTaken]): until then
  /// that install still owns its backup and may still be writing it.
  bool get _ownsFiles =>
      _prefs.lastSeq > 0 ||
      _prefs.pendingSeq > 0 ||
      _prefs.months.values.any((m) => m.state == MonthState.written);

  /// The adopted install's files are this install's to delete: its own
  /// records file replaced the one it adopted.
  bool get _adoptionTaken =>
      _prefs.adoptedFrom.isNotEmpty && _prefs.lastSeq > 0;

  /// [h] is the adopted install's file as it was adopted
  /// (WriteExpect.adoptMaxSeq), not one it wrote after taking it back.
  bool _isAdopted(BackupHeader h) {
    final max = _prefs.adoptedSeq;
    return _prefs.adoptedFrom.isNotEmpty &&
        h.installId == _prefs.adoptedFrom &&
        (max == null || h.seq <= max);
  }

  /// Restores, takeovers, combines and deletes going on ([_setBusy]).
  /// Every status set meanwhile says busy, whoever sets it: a refresh, a
  /// run of their own, or a trigger outside the lock.
  int _busy = 0;

  BackupStatus _statusFromPrefs() {
    // Off and paused keep what is known about the last backup: the
    // turn-off sheet and the Delete row go by it.
    BackupStatus known(BackupState state, {int count = 0}) => BackupStatus(
        state,
        lastOkAt: _prefs.lastOkAt,
        bytes: _prefs.lastBytes,
        count: count,
        busy: _busy > 0,
        ownsFiles: _ownsFiles);
    if (!_prefs.enabled) return known(BackupState.off);
    if (!_prefs.noticeSeen) return known(BackupState.needsNotice);
    switch (_prefs.paused) {
      case BackupPause.missing:
        return known(BackupState.missing);
      case BackupPause.shrink:
        return known(BackupState.shrink, count: _prefs.pausedCount);
      case BackupPause.none:
        break;
    }
    final err = BackupState.values.where((s) => s.name == _prefs.lastError);
    if (err.isNotEmpty) return known(err.first);
    final ok = _prefs.lastOkAt;
    if (ok == null) return known(BackupState.never);
    return BackupStatus(BackupState.ok,
        lastOkAt: ok,
        bytes: _prefs.lastBytes,
        busy: _busy > 0,
        skippedMonths: _prefs.skippedMonths,
        ownsFiles: _ownsFiles);
  }

  BackupState _set(BackupState state,
      {BackupHeader? other, int count = 0, bool remember = false}) {
    if (remember) unawaited(_prefs.setLastError(state.name));
    _status.value = BackupStatus(state,
        lastOkAt: _prefs.lastOkAt,
        bytes: _prefs.lastBytes,
        other: other,
        count: count,
        busy: _busy > 0,
        restorable: _restorable,
        skippedMonths: _prefs.skippedMonths,
        ownsFiles: _ownsFiles);
    return state;
  }

  BackupState _okState() {
    if (_prefs.lastOkAt == null) return _set(BackupState.never);
    final item = _listing?.item(kRecordsFileName);
    if (item?.uploadError == 'quota') return _set(BackupState.quota);
    if (item != null && !item.uploaded) return _set(BackupState.uploading);
    return _set(BackupState.ok);
  }

  /// The run did not get as far as deciding: the status stays as it was.
  BackupState _skip() => _status.value.state;

  BackupState _fail(CloudResultKind kind) => _set(
      switch (kind) {
        CloudResultKind.quota => BackupState.quota,
        CloudResultKind.unavailable => BackupState.unavailable,
        _ => BackupState.failed,
      },
      remember: true);

  /// One such action starts (true) or ends (false); each start has its end
  /// in a finally.
  void _setBusy(bool busy) {
    _busy = max(0, _busy + (busy ? 1 : -1));
    _status.value = _status.value.copyWith(busy: _busy > 0);
  }

  DateTime get _now => _clock();
  String get _today => isoDate(_now.toLocal());

  Future<String> _tmpPath(String name) async {
    final dir = Directory('${(await tempDir()).path}/icloud_backup');
    await dir.create(recursive: true);
    return '${dir.path}/$name';
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  // ------------------------------------------------------------- identity

  /// G7 and the identity steps every run starts with. Null when the run
  /// should stop (the status is already set).
  Future<String?> _identity({required bool background}) async {
    final cloud = await _t.status();
    switch (cloud.state) {
      case CloudState.noAccount:
        _set(BackupState.noAccount);
        return null;
      case CloudState.unavailable:
        _set(BackupState.unavailable);
        return null;
      case CloudState.ok:
        break;
    }
    if (cloud.accountChanged) {
      // Another iCloud account: nothing this install knew about the old
      // one's folder holds, and the notice is asked again. The install id
      // stays. Either engine may do this (it creates nothing).
      await _prefs.forgetBackup(keepNotice: false);
      await _prefs.setOffersAnswered(const []);
      _restorable = const [];
      _decided = false; // its folder is looked at on the next return
      _set(_prefs.enabled ? BackupState.needsNotice : BackupState.off);
      return null;
    }
    final key = await _t.deviceKey();
    if (key == null) return null; // iOS has no vendor id yet: skip the run
    if (key != _prefs.deviceKey || !isValidInstallId(_prefs.installId)) {
      if (!uiEngine) return null;
      // Another phone (set up from this one's device backup), or the first
      // run: a new install id; the notice's answer still holds.
      if (_prefs.deviceKey.isNotEmpty) {
        await _prefs.forgetBackup(keepNotice: true);
      }
      await _prefs.setDeviceKey(key);
      await _prefs.setInstallId(newInstallId(_random));
      await _prefs.setTopSeq(0);
    }
    return _prefs.installId;
  }

  // ------------------------------------------------------------ the guards

  /// Pictures whose meal date names no month, at the last [_monthPrints].
  int _noMonth = 0;

  /// This phone's pictures per month. A meal whose date does not start
  /// with a month (`YYYY-MM`, backup_format.dart monthOfDate) has no
  /// pictures file to go in: '2026/10/05' would make a path iCloud
  /// refuses and '2026-1-05' a month a restore never reads. Those pictures
  /// are counted in [_noMonth] (thumbs_skipped) and never make a month
  /// look changed.
  Future<Map<String, ThumbMonthPrint>> _monthPrints() async {
    final all = await _dao.thumbMonthPrints();
    var noMonth = 0;
    final out = <String, ThumbMonthPrint>{};
    for (final e in all.entries) {
      if (monthOfDate(e.key) == e.key) {
        out[e.key] = e.value;
      } else {
        noMonth += e.value.count;
      }
    }
    _noMonth = noMonth;
    return out;
  }

  bool _monthsChanged(
      Map<String, ThumbMonthPrint> prints, Map<String, MonthRecord> months) {
    for (final e in prints.entries) {
      final rec = months[e.key];
      if (rec == null) return true;
      if (rec.state == MonthState.foreign || rec.state == MonthState.pending) {
        continue;
      }
      if (rec.state == MonthState.absent || rec.print != e.value.key) {
        return true;
      }
    }
    for (final e in months.entries) {
      if (!prints.containsKey(e.key) &&
          (e.value.state == MonthState.written ||
              e.value.state == MonthState.restored)) {
        return true;
      }
    }
    return false;
  }

  /// The headers of the top-level files as last read. Every scan reads
  /// each file again (another phone may have backed up since, and an offer
  /// shows its counts); one that cannot be read this time (a coordinated
  /// read that timed out) keeps the header read before.
  final Map<String, BackupHeader?> _headerCache = {};

  Future<List<BackupCandidate>> _recordsFiles(CloudListing listing,
      {required bool allowDownload}) async {
    final out = <BackupCandidate>[];
    for (final item in listing.items) {
      if (!item.topLevel || !item.path.endsWith('.json')) continue;
      BackupHeader? h;
      final r = await _t.readHeader(item.path,
          allowDownload: allowDownload, timeout: const Duration(seconds: 10));
      switch (r.kind) {
        case CloudResultKind.ok:
          h = r.header;
          _headerCache[item.path] = h;
        case CloudResultKind.unknownOwner:
          _headerCache[item.path] = null;
        case CloudResultKind.missing:
          _headerCache.remove(item.path);
        default:
          h = _headerCache[item.path];
      }
      if (h != null && h.kind == BackupKind.records) {
        out.add(BackupCandidate(item.path, h));
      }
    }
    return out;
  }

  /// Other installs' records files, the newest per install.
  List<BackupCandidate> _others(List<BackupCandidate> files, String me) {
    final best = <String, BackupCandidate>{};
    for (final c in files) {
      if (c.header.installId == me) continue;
      final seen = best[c.header.installId];
      if (seen == null ||
          c.header.seq > seen.header.seq ||
          (c.header.seq == seen.header.seq && c.path == kRecordsFileName)) {
        best[c.header.installId] = c;
      }
    }
    return best.values.toList();
  }

  /// G4. Also notes the first time the folder was seen empty.
  Future<bool> _firstWriteAllowed({required bool skipWait}) async {
    final listing = _listing = await _t.list();
    if (!listing.gathered || listing.live < firstWriteQuery) return false;
    final files = await _recordsFiles(listing, allowDownload: true);
    final answered = _prefs.offersAnswered.toSet();
    final others = _others(files, _prefs.installId);
    _restorable = others;
    if (others.any((c) => !answered.contains(c.header.installId))) {
      return false;
    }
    final first = _prefs.firstEmptyAt;
    if (first == null) {
      await _prefs.setFirstEmptyAt(_now);
      return skipWait;
    }
    return skipWait || _now.difference(first) >= firstWriteWait;
  }

  // --------------------------------------------------------------- the run

  /// Never throws: runs are started from timers and lifecycle callbacks
  /// that nobody awaits, and anything a step did not expect (a database or
  /// disk error) ends the run as failed.
  Future<BackupState> _run(_Run r) => _locked(() async {
        try {
          return await _runLocked(r);
        } catch (_) {
          return _set(BackupState.failed, remember: true);
        }
      });

  Future<BackupState> _runLocked(_Run r) async {
    final bg = r.background;
    await _prefs.reload();
    if (!_prefs.enabled) return _set(BackupState.off);
    if (!_prefs.noticeSeen) return _set(BackupState.needsNotice); // G1
    if (!uiEngine && !isValidInstallId(_prefs.installId)) return _skip(); // G8
    final me = await _identity(background: bg); // G7
    if (me == null) return _status.value.state;
    final pause = _prefs.paused;
    if (pause == BackupPause.missing && !r.allowMissing) {
      return _set(BackupState.missing);
    }
    if (pause == BackupPause.shrink && !r.overrideShrink) {
      return _set(BackupState.shrink, count: _prefs.pausedCount);
    }
    if (!bg && uiEngine) await _retryPending();
    final counts = await _dao.backupCounts();
    var lastSeq = _prefs.lastSeq;
    if (counts.records == 0) {
      // G2 / G10: nothing to back up, and never an empty file over a full
      // one.
      return lastSeq > 0
          ? _set(BackupState.emptyLog, count: _prefs.lastMeals)
          : _set(BackupState.never);
    }
    final prints = await _monthPrints();
    final months = _prefs.months;
    final noMonth = _noMonth;
    final dirty = counts.recordsChange != _prefs.lastRecordsChange ||
        _monthsChanged(prints, months);
    if (!dirty && !r.force) return _okState(); // G6
    await _prefs.setLastAttemptAt(_now);

    final adopted = _prefs.adoptedFrom;
    final adoptFrom = adopted.isEmpty ? null : adopted;
    final adoptMax = _prefs.adoptedSeq;
    final firstWrite = lastSeq == 0;
    var allowAbsent = false;
    BackupHeader? current;
    if (firstWrite && adoptFrom == null && !r.takeover) {
      if (bg) return _set(BackupState.never); // G8
      if (!await _firstWriteAllowed(skipWait: r.skipWait)) {
        return _set(BackupState.never);
      }
    }
    // G3 before anything is written, the first write included: when the
    // records file is another install's, this install creates no month
    // file either (the owner could never write that month again).
    final h = await _t.readHeader(kRecordsFileName,
        allowDownload: !bg, timeout: r.timeout);
    switch (h.kind) {
      case CloudResultKind.ok:
        current = h.header;
        // A write of this install's that landed but was never recorded
        // (the app was killed first), or this install's file in an iCloud
        // account it left and came back to (lastSeq was forgotten, not
        // topSeq): the file is this install's at that seq, recorded now,
        // before the next seq is taken. Otherwise one more run that fails
        // after taking its seq, or the way back, would leave the file at a
        // seq no expected one names (changedElsewhere).
        final pending = _prefs.pendingSeq;
        if (current != null &&
            current.installId == me &&
            current.seq > lastSeq &&
            current.seq <= max(pending, _prefs.topSeq)) {
          lastSeq = current.seq;
          await _prefs.setLastSeq(lastSeq);
          if (pending == lastSeq) await _prefs.setPendingSeq(0);
        }
        final verdict = checkOwner(
            exists: true,
            header: current,
            expect: WriteExpect(
                installId: me,
                seqs: [lastSeq, if (_prefs.pendingSeq > 0) _prefs.pendingSeq],
                adoptFrom: adoptFrom,
                adoptMaxSeq: adoptMax));
        if (verdict == OwnerVerdict.ownedByOther) {
          return _set(BackupState.otherDevice, other: current);
        }
        if (verdict == OwnerVerdict.changedElsewhere) {
          return _set(BackupState.changedElsewhere, other: current);
        }
      case CloudResultKind.missing:
        if (firstWrite || r.allowMissing) {
          allowAbsent = true;
        } else {
          if (bg) return _skip();
          // G9: only once the live query has gathered without it.
          final listing = _listing = await _t.list();
          if (listing.gathered && listing.item(kRecordsFileName) == null) {
            await _prefs.setPaused(BackupPause.missing);
            return _set(BackupState.missing);
          }
          return _skip();
        }
      case CloudResultKind.unknownOwner:
        if (!r.replaceUnknown) return _set(BackupState.unknownFile);
      case CloudResultKind.notDownloaded:
        if (!bg) await _t.startDownloads(const [kRecordsFileName]);
        return _skip();
      case CloudResultKind.twoCopies:
        return _set(BackupState.twoCopies);
      default:
        return _fail(h.kind);
    }
    // G5: never replace a file of 20+ meals with one of under half.
    final replaced = current;
    if (!r.overrideShrink &&
        replaced != null &&
        replaced.meals >= shrinkFloor &&
        counts.meals * 2 < replaced.meals) {
      await _prefs.setPaused(BackupPause.shrink, count: replaced.meals);
      return _set(BackupState.shrink, count: replaced.meals);
    }

    // Above every seq this install id ever took, in any account, and after
    // a takeover too: a seq names one write.
    final oldPending = _prefs.pendingSeq;
    final newSeq = max(max(lastSeq, oldPending), _prefs.topSeq) + 1;
    await _prefs.setTopSeq(newSeq);
    await _prefs.setPendingSeq(newSeq);
    var bytes = 0;

    // 1. The months that changed, then the ones with no pictures left.
    final monthFailure = await _writeMonths(
        prints: prints,
        months: months,
        me: me,
        adoptFrom: adoptFrom,
        adoptMax: adoptMax,
        seq: newSeq,
        r: r,
        addBytes: (n) => bytes += n);
    if (monthFailure == CloudResultKind.cancelled) {
      return _set(BackupState.off);
    }
    if (monthFailure != null) return _fail(monthFailure);

    // 2. The records file (not once the switch went off).
    if (await _switchedOff()) return _set(BackupState.off);
    final skipped =
        months.values.fold<int>(0, (a, m) => a + m.skipped) + noMonth;
    final tmp = await _tmpPath('records-$newSeq.json');
    final WrittenBackupFile file;
    try {
      file = await _writer.writeRecords(tmp,
          installId: me,
          seq: newSeq,
          months: _headerMonths(prints, months),
          thumbsSkipped: skipped);
    } catch (_) {
      return _set(BackupState.failed, remember: true);
    }
    final rotate = !firstWrite && _prefs.previousDay != _today;
    final w = await _t.write(
      path: kRecordsFileName,
      sourcePath: file.path,
      bytes: file.bytes,
      sha256: file.sha256,
      expect: WriteExpect(
        installId: me,
        seqs: [lastSeq, if (oldPending > 0) oldPending],
        adoptFrom: adoptFrom,
        adoptMaxSeq: adoptMax,
        allowAbsent: allowAbsent,
        replaceUnknown: r.replaceUnknown,
      ),
      keepPreviousPath: rotate ? kPreviousFileName : null,
      allowDownload: !bg,
      timeout: r.timeout,
    );
    await _deleteQuietly(file.path);
    switch (w.kind) {
      case CloudResultKind.ok:
        break;
      case CloudResultKind.ownedByOther:
        return _set(BackupState.otherDevice, other: w.header);
      case CloudResultKind.changedElsewhere:
        return _set(BackupState.changedElsewhere, other: w.header);
      case CloudResultKind.unknownOwner:
        return _set(BackupState.unknownFile);
      case CloudResultKind.twoCopies:
        return _set(BackupState.twoCopies);
      case CloudResultKind.absentNotAllowed:
        if (bg) return _skip();
        await _prefs.setPaused(BackupPause.missing);
        return _set(BackupState.missing);
      case CloudResultKind.notDownloaded:
        return _skip();
      default:
        return _fail(w.kind);
    }
    bytes += file.bytes;
    await _prefs.setLastSeq(newSeq);
    await _prefs.setPendingSeq(0);
    await _prefs.setLastRecordsChange(counts.recordsChange);
    await _prefs.setLastOkAt(_now);
    await _prefs.setLastBytes(bytes);
    await _prefs.setLastMeals(file.header.meals);
    await _prefs.setLastError('');
    await _prefs.setFirstEmptyAt(null);
    await _prefs.setPaused(BackupPause.none);
    if (rotate || firstWrite) await _prefs.setPreviousDay(_today);
    _listing = null;
    if (uiEngine && !bg) {
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(seconds: 30), () => unawaited(refresh()));
    }
    // Turned off while this last write was in flight: it landed, and the
    // switch says off.
    return _set(_prefs.enabled ? BackupState.uploading : BackupState.off);
  }

  /// The switch went off while a run was going (turnOff only sets the
  /// preference): the run stops before its next upload.
  Future<bool> _switchedOff() async {
    await _prefs.reload();
    return !_prefs.enabled;
  }

  /// Writes each month whose pictures changed and deletes each of this
  /// install's months that has none left. Only months this install wrote,
  /// restored or found absent are touched. Returns a failure that stops
  /// the run (cancelled: the switch went off), or null.
  Future<CloudResultKind?> _writeMonths({
    required Map<String, ThumbMonthPrint> prints,
    required Map<String, MonthRecord> months,
    required String me,
    required String? adoptFrom,
    required int? adoptMax,
    required int seq,
    required _Run r,
    required void Function(int) addBytes,
  }) async {
    final bg = r.background;
    final all = {...prints.keys, ...months.keys}.toList()..sort();
    try {
      for (final m in all) {
        final rec = months[m];
        final print = prints[m];
        final path = picturesPath(m);
        // Its file holds the adopted install's pictures that have not come
        // in yet: never written over before they did.
        if (rec?.state == MonthState.pending) continue;
        if (rec?.state == MonthState.foreign) {
          // Another install's file: nothing to back up here once this
          // phone has no pictures in the month; otherwise looked at again
          // in the foreground (below), in case it is gone or now ours.
          if (print == null) {
            months.remove(m);
            continue;
          }
          if (bg) continue;
        }
        if (print == null) {
          if (rec == null || rec.state == MonthState.absent) {
            months.remove(m);
            continue;
          }
          if (await _switchedOff()) return CloudResultKind.cancelled;
          final d = await _t.delete([path],
              WriteExpect(
                  installId: me, adoptFrom: adoptFrom, adoptMaxSeq: adoptMax),
              timeout: r.timeout);
          if (d.ok && d.left == 0) {
            months.remove(m);
          } else if (!d.ok && !_transient(d.kind)) {
            return d.kind;
          }
          // Left (not on this phone yet: Swift started its download):
          // deleted by a later run.
          continue;
        }
        if (rec != null &&
            rec.state != MonthState.absent &&
            rec.state != MonthState.foreign &&
            rec.print == print.key) {
          continue;
        }
        var allowAbsent = rec?.state == MonthState.absent;
        if (rec == null || rec.state == MonthState.foreign) {
          final st = await _t.itemState(path);
          if (st.exists == ItemExists.no) {
            allowAbsent = true;
          } else if (st.exists == ItemExists.yes) {
            if (bg && st.downloading) continue;
            final h = await _t.readHeader(path,
                allowDownload: !bg, timeout: r.timeout);
            if (h.kind == CloudResultKind.unknownOwner) {
              months[m] = const MonthRecord(MonthState.foreign);
              continue;
            }
            final owner = h.header?.installId;
            if (h.kind != CloudResultKind.ok || owner == null) continue;
            final adoptedFile = owner == adoptFrom &&
                (adoptMax == null || h.header!.seq <= adoptMax);
            if (owner != me && !adoptedFile) {
              months[m] = const MonthRecord(MonthState.foreign);
              continue;
            }
          } else {
            continue;
          }
        }
        if (await _switchedOff()) return CloudResultKind.cancelled;
        final WrittenBackupFile file;
        try {
          file = await _writer.writePictures(
              await _tmpPath('pictures-$m.json'),
              installId: me,
              seq: seq,
              month: m);
        } catch (_) {
          // The temporary file could not be made (the phone is full, the
          // month could not be read; the writer deleted what it began):
          // the run ends as failed, as it does for the records file.
          return CloudResultKind.error;
        }
        final w = await _t.write(
          path: path,
          sourcePath: file.path,
          bytes: file.bytes,
          sha256: file.sha256,
          expect: WriteExpect(
              installId: me,
              adoptFrom: adoptFrom,
              adoptMaxSeq: adoptMax,
              allowAbsent: allowAbsent),
          allowDownload: !bg,
          timeout: r.timeout,
        );
        await _deleteQuietly(file.path);
        switch (w.kind) {
          case CloudResultKind.ok:
            months[m] = MonthRecord(MonthState.written,
                print: print.key, skipped: file.header.thumbsSkipped);
            addBytes(file.bytes);
          case CloudResultKind.ownedByOther:
          case CloudResultKind.unknownOwner:
          case CloudResultKind.changedElsewhere:
            months[m] = const MonthRecord(MonthState.foreign);
          case CloudResultKind.absentNotAllowed:
            months.remove(m); // looked at again next run
          case CloudResultKind.notDownloaded:
          case CloudResultKind.twoCopies:
            break;
          default:
            return w.kind;
        }
      }
      return null;
    } finally {
      await _prefs.setMonths(months);
      await _prefs.setSkippedMonths(months.entries
          .where((e) =>
              e.value.state == MonthState.foreign && prints.containsKey(e.key))
          .length);
    }
  }

  /// The records header's months: this phone's pictures per month, and
  /// each adopted month still pending with the count its file holds.
  static Map<String, int> _headerMonths(
          Map<String, ThumbMonthPrint> prints, Map<String, MonthRecord> months) =>
      {
        for (final e in prints.entries) e.key: e.value.count,
        for (final e in months.entries)
          if (e.value.state == MonthState.pending) e.key: e.value.count,
      };

  bool get _hasPending =>
      _prefs.months.values.any((m) => m.state == MonthState.pending);
  DateTime? _pendingTriedAt;

  /// Foreground only: the adopted months that could not be read during the
  /// restore are fetched and imported again. One that comes in is marked
  /// restored (by the same rule as _adoptMonths); one whose file the
  /// gathered query no longer shows is dropped; the rest stay pending.
  Future<void> _retryPending() async {
    final months = _prefs.months;
    final pending = [
      for (final e in months.entries)
        if (e.value.state == MonthState.pending) e.key,
    ]..sort();
    if (pending.isEmpty) return;
    _pendingTriedAt = _now;
    await _t.startDownloads([for (final m in pending) picturesPath(m)]);
    final before = await _monthPrints();
    final done = <String>[];
    var added = 0;
    CloudListing? listing;
    for (final m in pending) {
      final p = await _tmpPath('retry-$m.json');
      try {
        final r = await _t.fetch(picturesPath(m), p,
            timeout: const Duration(seconds: 20));
        if (r.kind == CloudResultKind.missing) {
          listing ??= await _t.list();
          if (listing.gathered && listing.item(picturesPath(m)) == null) {
            months.remove(m); // gone from iCloud: nothing left to bring in
          }
          continue;
        }
        if (!r.ok) continue;
        final s = await _dao.importJson(await File(p).readAsString());
        added += s.thumbsAdded;
        done.add(m);
      } catch (_) {
        // Stays pending.
      } finally {
        await _deleteQuietly(p);
      }
    }
    if (done.isNotEmpty) {
      final after = await _monthPrints();
      for (final m in done) {
        months[m] = MonthRecord(MonthState.restored,
            print: before[m] == null ? (after[m]?.key ?? '') : '');
      }
    }
    await _prefs.setMonths(months);
    if (added > 0) onDataImported?.call();
  }

  static bool _transient(CloudResultKind k) =>
      k == CloudResultKind.notDownloaded || k == CloudResultKind.timeout;

  // ------------------------------------------------------------- triggers

  /// The app's engine, after the first frame and once the database is
  /// open: ask iCloud for its status, start the metadata query, look for a
  /// backup to offer, then run if the last backup is stale.
  Future<void> start() async {
    if (!uiEngine) return;
    await _prefs.reload();
    _status.value = _statusFromPrefs();
    _startPolling();
    unawaited(_launchCheck(startWatching: true));
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _debounceTimer?.cancel();
    _refreshTimer?.cancel();
    _endDeciding();
    await _t.stopWatching();
  }

  Future<void> _launchCheck({bool startWatching = false}) async {
    if (_deciding == null) {
      _deciding = Completer<void>();
      _decidingSince = _now;
    }
    final bool nothingToAsk;
    try {
      nothingToAsk = await _lookForOffer(startWatching: startWatching);
    } finally {
      // Decided (an offer holds the catch-up from here), or ended without
      // deciding: the catch-up waits no longer either way.
      _endDeciding();
    }
    if (nothingToAsk) await _maybeLaunchRun();
  }

  /// The look for a backup to offer, or the notice to ask. True when it
  /// found nothing to ask (the launch's run may go); false when it asks,
  /// or ended before it could tell.
  Future<bool> _lookForOffer({required bool startWatching}) async {
    final me = await _locked(() async {
      await _prefs.reload();
      return _identity(background: false);
    });
    // The metadata query only after that status call. In iOS a query finds
    // the container's files only once the container was fetched in the
    // process (url(forUbiquityContainerIdentifier:), which status runs, as
    // does the plugin's startWatching); started before, it can gather an
    // empty folder while a backup is there: no restore offer, and G4's
    // "no backup" evidence. Started whatever status said: the plugin
    // starts the query once there is a container (CloudQueryPlan).
    if (startWatching) await _t.startWatching();
    if (me == null) return false;
    // Wait for the query's first gathering (foreground only).
    final until = _now.add(gatherWait);
    var listing = await _t.list();
    while (!listing.gathered && _foreground && _now.isBefore(until)) {
      await Future<void>.delayed(gatherPoll);
      listing = await _t.list();
    }
    if (!listing.gathered || !_foreground) return false;
    _listing = listing;
    final files = await _recordsFiles(listing, allowDownload: true);
    final others = _restorable = _others(files, me);
    _status.value = _status.value.copyWith(restorable: others);
    final answered = _prefs.offersAnswered.toSet();
    final open =
        others.where((c) => !answered.contains(c.header.installId)).toList();
    if (_prefs.enabled && open.isNotEmpty) {
      // The newest backup first; the rest wait for the next launch or the
      // Restore From iCloud… row.
      open.sort((a, b) => (b.header.exportedAt ?? '')
          .compareTo(a.header.exportedAt ?? ''));
      await _holdCatchUp();
      final counts = await _dao.backupCounts();
      _decided = true;
      prompt.value = RestoreOfferPrompt(open.first, counts.meals);
      return false;
    }
    _decided = true;
    if (_prefs.enabled && !_prefs.noticeSeen) {
      prompt.value = const NoticePrompt();
      return false;
    }
    return true;
  }

  Future<void> _maybeLaunchRun() async {
    final last = _prefs.lastOkAt;
    final stale = last == null ||
        _now.difference(last) >= launchStaleAfter ||
        _prefs.lastError.isNotEmpty ||
        _pendingDue;
    if (stale) await _run(const _Run(_Kind.launch));
  }

  /// Adopted months wait to come in, and the last try was a while ago.
  bool get _pendingDue {
    if (!_hasPending) return false;
    final tried = _pendingTriedAt;
    return tried == null || _now.difference(tried) >= minForegroundGap;
  }

  /// The app's lifecycle (the shell forwards every change).
  void onLifecycle(bool foreground) {
    if (!uiEngine) return;
    final was = _foreground;
    _foreground = foreground;
    if (!foreground && was) {
      _pollTimer?.cancel();
      _debounceTimer?.cancel();
      unawaited(_onBackgroundEntry());
    } else if (foreground && !was) {
      _startPolling();
      unawaited(_onResume());
    }
  }

  Future<void> _onBackgroundEntry() async {
    await _prefs.reload();
    if (!_prefs.enabled || !_prefs.noticeSeen || _prefs.lastSeq == 0) return;
    final last = _prefs.lastAttemptAt;
    if (last != null && _now.difference(last) < minBackgroundGap) return;
    final counts = await _dao.backupCounts();
    final prints = await _monthPrints();
    if (counts.recordsChange == _prefs.lastRecordsChange &&
        !_monthsChanged(prints, _prefs.months)) {
      return;
    }
    Future<void> body() async {
      final left = await _t.backgroundTimeRemaining();
      var timeout = const Duration(seconds: 15);
      if (left != null) {
        final cap = left - const Duration(seconds: 5);
        if (cap < timeout) timeout = cap;
      }
      if (timeout < const Duration(seconds: 3)) return;
      await _run(_Run(_Kind.background, timeout: timeout));
    }

    final guard = _guard;
    await (guard == null ? body() : guard('icloud-backup', body));
  }

  Future<void> _onResume() async {
    // No look for a backup to offer has decided (see [_decided]): one looks
    // again now, started before anything is awaited so that the photo
    // catch-up of this return waits for it as well ([holdsCatchUp]). One
    // at a time, and not over a question still waiting to be asked.
    if (!_decided && _deciding == null && prompt.value == null) {
      await _launchCheck();
      if (_decided) return;
    }
    await refresh();
    await _prefs.reload();
    if (prompt.value != null) return;
    final counts = await _dao.backupCounts();
    if (counts.recordsChange == _prefs.lastRecordsChange &&
        !_monthsChanged(await _monthPrints(), _prefs.months) &&
        !_pendingDue) {
      return;
    }
    await _maybeLaunchRun();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollEvery, (_) => unawaited(_poll()));
  }

  /// The 5-minute look at the change counter: catches edits that send no
  /// meals-changed signal (a weigh-in, an edit in the meal editor).
  Future<void> _poll() async {
    final c = await _dao.backupCounts();
    if (c.recordsChange != _seenRecords || c.thumbsChange != _seenThumbs) {
      final first = _seenRecords == null;
      _seenRecords = c.recordsChange;
      _seenThumbs = c.thumbsChange;
      if (!first) noteChange();
    }
  }

  /// Something changed in the foreground: a run after [debounce], and no
  /// sooner than [minForegroundGap] after the last success.
  void noteChange() {
    if (!uiEngine || !_foreground) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      final last = _prefs.lastOkAt;
      final wait = last == null
          ? Duration.zero
          : minForegroundGap - _now.difference(last);
      if (wait > Duration.zero) {
        _debounceTimer = Timer(wait, () => unawaited(_run(const _Run(_Kind.foreground))));
      } else {
        unawaited(_run(const _Run(_Kind.foreground)));
      }
    });
  }

  /// Whether the app's photo catch-up should wait: a restore offer is open
  /// or a restore is running (the headless run reads the same lease).
  ///
  /// While the look for a backup to offer has not decided, the answer
  /// waits for it ([gatherWait] + [lookSlack] at most): a catch-up started
  /// before the offer exists would log the offered backup's photos afresh,
  /// and the restore would keep those over the backup's own, maybe
  /// corrected, meals (it merges photo meals by their photo). The launch's
  /// look starts after the first frame: never awaited before runApp.
  Future<bool> holdsCatchUp() async {
    final deciding = _deciding;
    if (deciding != null) {
      try {
        await deciding.future.timeout(gatherWait + lookSlack);
      } on TimeoutException {
        // A look that never ends holds nothing.
      }
    }
    await _prefs.reload();
    return holdsCatchUpNow;
  }

  /// [holdsCatchUp] without waiting or reading the store again (this
  /// engine sets and lets go the lease itself): a catch-up already running
  /// asks it before each photo, and stops before the next one once an
  /// offer is raised or a restore starts.
  ///
  /// An offer raised here holds until it is answered or dismissed, however
  /// long it waits: the 30-minute lease is how the background run sees it,
  /// and what a crash leaves behind, not how long an offer may stay open.
  bool get holdsCatchUpNow {
    if (prompt.value is RestoreOfferPrompt) return true;
    final until = _prefs.holdCatchUpUntil;
    return until != null && until.isAfter(_now);
  }

  /// Whether an AUTOMATIC photo should wait right now: the app's pipeline
  /// releases it untouched (PhotoPipeline.intakeHeld), and a catch-up
  /// after the hold offers it again ([onCatchUpReleased]). Held while
  /// [holdsCatchUpNow], and while a look for a backup to offer has not
  /// decided, as the catch-up waits for it ([holdsCatchUp]: [gatherWait] +
  /// [lookSlack] at most from when the look began). The live watcher hands
  /// photos over from the first frame on, while the launch's look is still
  /// gathering the folder: a photo logged then would be kept over the
  /// backup's own, maybe corrected, meal for it once the offer it raises
  /// is answered with Restore (a restore merges photo meals by their
  /// photo).
  bool get holdsPhotosNow {
    if (holdsCatchUpNow) return true;
    final since = _decidingSince;
    return _deciding != null &&
        since != null &&
        _now.difference(since) < gatherWait + lookSlack;
  }

  /// This install's id once it has one (an export's header uses it).
  String? get installIdOrNull {
    final id = _prefs.installId;
    return isValidInstallId(id) ? id : null;
  }

  /// An import added rows: back up straight away (every guard still
  /// applies, the 24 h first-write wait included).
  void afterImport() {
    if (!uiEngine) return;
    unawaited(_run(const _Run(_Kind.now, force: true)));
  }

  /// Back Up Now: no wait for a change or the 24 h. G4's query still
  /// counts: tapped within its first minute, a first write waits the rest
  /// of it out (busy: Checking iCloud…) instead of doing nothing.
  Future<BackupState> backUpNow() async {
    await _awaitFirstWriteQuery();
    return _run(const _Run(_Kind.now, force: true, skipWait: true));
  }

  /// Before Back Up Now's first write: the metadata query gathered and
  /// live [firstWriteQuery] (G4), waited for while the app is in the
  /// foreground and the query runs, [gatherWait] at most. Nothing to wait
  /// for before the notice, with nothing to back up, or once this install
  /// wrote or adopted the file (G4 is for the first write only).
  Future<void> _awaitFirstWriteQuery() async {
    if (!uiEngine) return;
    await _prefs.reload();
    if (!_prefs.enabled ||
        !_prefs.noticeSeen ||
        _prefs.lastSeq > 0 ||
        _prefs.adoptedFrom.isNotEmpty) {
      return;
    }
    bool ready(CloudListing l) =>
        !l.watching || (l.gathered && l.live >= firstWriteQuery);
    var listing = await _t.list();
    if (ready(listing) || (await _dao.backupCounts()).records == 0) return;
    final until = _now.add(gatherWait);
    _setBusy(true);
    try {
      while (!ready(listing) && _foreground && _now.isBefore(until)) {
        await Future<void>.delayed(gatherPoll);
        listing = await _t.list();
      }
    } finally {
      _setBusy(false);
    }
  }

  /// The upload state for the status line (Settings opening, a resume,
  /// 30 s after a foreground write).
  Future<void> refresh() async {
    if (!uiEngine) return;
    _listing = await _t.list();
    final s = _status.value.state;
    if (s == BackupState.ok || s == BackupState.uploading ||
        s == BackupState.quota) {
      _okState();
    }
    final item = _listing?.item(kRecordsFileName);
    if (item != null && item.hasConflicts && s != BackupState.twoCopies) {
      final versions = await _t.conflicts(
          kRecordsFileName, await _tmpPath('conflict-check'));
      final me = _prefs.installId;
      final foreign = versions.any((v) =>
          v.header == null ||
          (v.header!.installId != me && !_isAdopted(v.header!)));
      for (final v in versions) {
        await _deleteQuietly(v.tmpPath);
      }
      if (foreign) _set(BackupState.twoCopies);
    }
  }

  // ---------------------------------------------------------- the choices

  /// The notice: Keep On or Turn Off. Either way it is not asked again.
  Future<void> answerNotice({required bool keepOn}) async {
    await _prefs.setNoticeSeen(true);
    await _prefs.setEnabled(keepOn);
    if (!keepOn) await _dropUnwrittenAdoption();
    prompt.value = null;
    _status.value = _statusFromPrefs();
    if (keepOn) unawaited(_run(const _Run(_Kind.foreground)));
  }

  /// The switch. Turning it on is an answer to the notice too.
  Future<void> setEnabled(bool on) async {
    await _prefs.setEnabled(on);
    if (on) await _prefs.setNoticeSeen(true);
    if (!on) await _dropUnwrittenAdoption();
    _dropNotice();
    _status.value = _statusFromPrefs();
    if (on) unawaited(_run(const _Run(_Kind.foreground)));
  }

  /// The switch was set while the notice waited to be asked (the shell
  /// asks only with nothing on top of it): turned on, the notice is
  /// answered; turned off, "iCloud Backup is on" is no longer true, and
  /// its Keep On would turn the switch back on.
  void _dropNotice() {
    if (prompt.value is NoticePrompt) prompt.value = null;
  }

  /// Turned off before this install's records file replaced the one a
  /// restore (or a takeover) adopted: the takeover is given up. That
  /// install still owns its backup and may still be writing it, so its
  /// files are not this install's to write over or delete; turned on
  /// again, this install finds it in the way like any other install's
  /// (Back Up From This iPhone… asks first). Not while one of this
  /// install's writes may be in flight or landed (pendingSeq): a run
  /// writes nothing once the switch is off, and one whose write landed
  /// keeps the files it took over.
  Future<void> _dropUnwrittenAdoption() async {
    await _prefs.reload();
    if (_prefs.adoptedFrom.isEmpty ||
        _prefs.lastSeq > 0 ||
        _prefs.pendingSeq > 0) {
      return;
    }
    await _prefs.clearAdopted();
    final months = _prefs.months
      ..removeWhere((_, m) =>
          m.state == MonthState.restored || m.state == MonthState.pending);
    await _prefs.setMonths(months);
  }

  Future<void> _holdCatchUp() =>
      _prefs.setHoldCatchUpUntil(_now.add(catchUpLease));

  /// Lets the lease go, and the app catch up on what it held back once
  /// nothing else holds it ([onCatchUpReleased]).
  Future<void> _releaseCatchUp() async {
    await _prefs.setHoldCatchUpUntil(null);
    if (!uiEngine || holdsPhotosNow) return;
    try {
      onCatchUpReleased?.call();
    } catch (_) {}
  }

  Future<void> _markAnswered(String installId) async {
    final answered = {..._prefs.offersAnswered, installId}.toList();
    await _prefs.setOffersAnswered(answered);
  }

  /// Imports [path]'s records, then the months of pictures ITS header
  /// lists: the header of the file as fetched, not one from an earlier
  /// scan (the other phone may have backed up months since). A file that
  /// is no longer [installId]'s backup is not imported. A failed month
  /// does not fail the import. Returns the summary, the months that came
  /// in, this phone's month prints from before the import, and the header
  /// the import went by (null when it failed).
  Future<
      (
        RestoreSummary,
        List<String>,
        Map<String, ThumbMonthPrint>,
        BackupHeader?
      )> _importBackup(String path, String installId) async {
    final before = await _monthPrints();
    final dest = await _tmpPath('restore-records.json');
    final f = await _t.fetch(path, dest, timeout: const Duration(seconds: 60));
    if (!f.ok) {
      await _deleteQuietly(dest);
      return (
        const RestoreSummary(ok: false),
        const <String>[],
        before,
        null
      );
    }
    final ImportSummary s;
    final BackupHeader header;
    try {
      final h = parseBackupHeader(await _headOf(dest));
      if (h == null || h.installId != installId) {
        return (
          const RestoreSummary(ok: false),
          const <String>[],
          before,
          null
        );
      }
      header = h;
      s = await _dao.importJson(await File(dest).readAsString());
    } on FormatException {
      return (
        const RestoreSummary(ok: false),
        const <String>[],
        before,
        null
      );
    } finally {
      await _deleteQuietly(dest);
    }
    final months = header.months.keys.toList()..sort();
    await _t.startDownloads([for (final m in months) picturesPath(m)]);
    var thumbs = 0, failed = 0;
    final done = <String>[];
    for (final m in months) {
      await _holdCatchUp(); // the lease is renewed as long as it runs
      final p = await _tmpPath('restore-$m.json');
      try {
        final r = await _t.fetch(picturesPath(m), p,
            timeout: const Duration(seconds: 60));
        if (!r.ok) {
          failed++;
          continue;
        }
        final ps = await _dao.importJson(await File(p).readAsString());
        thumbs += ps.thumbsAdded;
        done.add(m);
      } catch (_) {
        failed++;
      } finally {
        await _deleteQuietly(p);
      }
    }
    return (
      RestoreSummary(
        mealsAdded: s.added['meals'] ?? 0,
        thumbsAdded: thumbs,
        mealsSkippedDeleted: s.mealsSkippedDeleted,
        failedMonths: failed,
      ),
      done,
      before,
      header
    );
  }

  /// The first bytes of a local file, where its backup header is.
  static Future<List<int>> _headOf(String path) async {
    final f = await File(path).open();
    try {
      return await f.read(kBackupHeaderLimit);
    } finally {
      await f.close();
    }
  }

  /// After a restore, takeover or combine: the adopted install's months as
  /// this one knows them. A month that could not be read is pending: its
  /// file still has the other phone's pictures, which this install never
  /// overwrites with fewer, and its import is tried again (_retryPending).
  ///
  /// A month's print says what its FILE holds, not what the merged
  /// database holds: only when this phone had no pictures in the month
  /// before the import ([before]) and the file is kept (not [replace]d) is
  /// the file what the database now holds. Otherwise the print is '', and
  /// the next run rewrites the month from the merged database (or deletes
  /// it when this phone has no pictures there), so this phone's own
  /// pictures in it are backed up too.
  Future<void> _adoptMonths(BackupHeader header,
      {required Map<String, ThumbMonthPrint> before,
      required List<String> restored,
      bool replace = false}) async {
    final after = await _monthPrints();
    final months = _prefs.months;
    for (final m in header.months.keys) {
      if (!restored.contains(m)) {
        months[m] =
            MonthRecord(MonthState.pending, count: header.months[m] ?? 0);
        continue;
      }
      final fileIsDatabase = !replace && before[m] == null;
      months[m] = MonthRecord(MonthState.restored,
          print: fileIsDatabase ? (after[m]?.key ?? '') : '');
    }
    await _prefs.setMonths(months);
  }

  /// Restore: merge [c] into this phone. When it takes [c] over
  /// ([restoreTakesOver]), it adopts it: the next write replaces it with
  /// this phone's (now merged) record.
  Future<RestoreSummary> restore(BackupCandidate c) async {
    // Held from the tap: the offer may have outwaited its own lease, and a
    // run may have the lock (the import renews it as long as it runs).
    await _holdCatchUp();
    prompt.value = null;
    _setBusy(true);
    try {
      final summary = await _locked(() async {
        await _holdCatchUp();
        // [c] is from the last scan; the import goes by the file as it is
        // now, and so does the adoption.
        final (summary, done, before, header) =
            await _importBackup(c.path, c.header.installId);
        if (!summary.ok || header == null) return summary;
        await _prefs.reload();
        if (restoreTakesOver(c)) {
          await _prefs.setAdopted(header);
          await _adoptMonths(header, before: before, restored: done);
        }
        await _markAnswered(c.header.installId);
        return summary;
      });
      if (summary.ok) onDataImported?.call();
      return summary;
    } finally {
      await _releaseCatchUp();
      _setBusy(false);
      await _afterChoice();
    }
  }

  /// Whether restoring [c] makes this install take its file over (the
  /// restore sheet says so): iCloud Backup is on, this install has no
  /// backup of its own yet and [c] is the canonical file, so the next run
  /// writes over it. With the switch off no run would: the restore is a
  /// merge, and [c]'s install keeps its backup. (On by default, the offer
  /// can come before the notice; Turn Off there gives the takeover up,
  /// [_dropUnwrittenAdoption].)
  bool restoreTakesOver(BackupCandidate c) =>
      _prefs.enabled && _prefs.lastSeq == 0 && c.path == kRecordsFileName;

  /// Not Now: the offer is not raised again for that install (the Restore
  /// From iCloud… row still has it).
  Future<void> declineOffer(BackupCandidate c) async {
    prompt.value = null;
    await _markAnswered(c.header.installId);
    await _releaseCatchUp();
    await _afterChoice();
  }

  /// The offer dismissed without an answer (swiped away): Not Now for this
  /// launch only, so it comes back at the next one, and the photo catch-up
  /// it held is let go now rather than when the lease runs out.
  Future<void> dismissOffer() async {
    prompt.value = null;
    await _releaseCatchUp();
  }

  /// Start Fresh: delete [c]'s backup (after the red confirm) and back up
  /// this phone from scratch, without the 24 h wait.
  /// A delete that did not finish leaves the offer unanswered: it comes
  /// back (and the Restore From iCloud… row keeps it) to be finished.
  Future<BackupDeleteResult> startFresh(BackupCandidate c) async {
    prompt.value = null;
    _setBusy(true);
    try {
      return await _locked(() async {
        // [c] is from the last scan: the months its file lists now are
        // deleted too (the other phone may have backed up since). A file
        // another install has written since is not [c]'s backup any more:
        // nothing is deleted, and the offer comes back with what is there.
        final cur = await _t.readHeader(c.path,
            allowDownload: true, timeout: const Duration(seconds: 30));
        final Map<String, int> listed;
        switch (cur.kind) {
          case CloudResultKind.ok:
            if (cur.header!.installId != c.header.installId) {
              _headerCache.clear();
              return BackupDeleteResult.failed;
            }
            listed = {...c.header.months, ...cur.header!.months};
          case CloudResultKind.missing:
            listed = c.header.months;
          default:
            return BackupDeleteResult.failed;
        }
        // Only [c]'s install's files go (its id stands where this
        // install's would; any seq): a month path is every install's, and
        // when this install backs up too ([c] is a second records file, or
        // its month lost the name race) the month file is this install's
        // own, which it would never write again.
        final result = await _deleteInOrder([
          [for (final m in listed.keys) picturesPath(m)],
          if (c.path == kRecordsFileName) const [kPreviousFileName],
          [c.path],
        ], WriteExpect(installId: c.header.installId));
        _headerCache.clear();
        // A month whose file is gone now is forgotten: one this install
        // skipped as [c]'s is written by the next run.
        final months = _prefs.months;
        final before = months.length;
        for (final m in listed.keys) {
          if (!months.containsKey(m)) continue;
          final st = await _t.itemState(picturesPath(m));
          if (st.exists == ItemExists.no) months.remove(m);
        }
        if (months.length != before) await _prefs.setMonths(months);
        if (result != BackupDeleteResult.deleted) return result;
        await _markAnswered(c.header.installId);
        await _prefs.setFirstEmptyAt(_now.subtract(firstWriteWait));
        return result;
      });
    } finally {
      await _releaseCatchUp();
      _setBusy(false);
      await _afterChoice();
    }
  }

  /// After a restore offer is answered: the notice when it is still due,
  /// else a run.
  Future<void> _afterChoice() async {
    await _prefs.reload();
    if (_prefs.enabled && !_prefs.noticeSeen) {
      prompt.value = const NoticePrompt();
    } else {
      // The user has seen the folder and chosen: no 24 h wait.
      unawaited(_run(const _Run(_Kind.now, force: true, skipWait: true)));
    }
  }

  /// Back Up From This iPhone…: the file in the way (another install's, a
  /// copy changed outside the app, or one whose header cannot be read)
  /// becomes this install's. [replace] false merges it in first (the
  /// default); true replaces it (the sheet showed both sides' counts).
  Future<bool> takeOver({required bool replace}) async {
    _setBusy(true);
    var unknown = false;
    // The merge's import holds the photo catch-up (_importBackup).
    var held = false;
    try {
      final ok = await _locked(() async {
        await _prefs.reload();
        final h = await _t.readHeader(kRecordsFileName,
            allowDownload: true, timeout: const Duration(seconds: 30));
        if (h.kind == CloudResultKind.ok && h.header != null) {
          var header = h.header!;
          var done = header.months.keys.toList();
          var before = await _monthPrints();
          if (!replace) {
            held = true;
            final (summary, months, prints, fetched) =
                await _importBackup(kRecordsFileName, header.installId);
            if (!summary.ok || fetched == null) return false;
            header = fetched;
            done = months;
            before = prints;
            onDataImported?.call();
          }
          if (header.installId == _prefs.installId) {
            // This install's own file at a seq it did not expect (changed
            // outside the app): it is this install's again at that seq.
            // Adopting its own id would accept any seq from now on.
            await _prefs.setLastSeq(header.seq);
          } else {
            await _prefs.setAdopted(header);
            await _prefs.setLastSeq(0);
          }
          await _prefs.setPendingSeq(0);
          await _adoptMonths(header,
              before: before, restored: done, replace: replace);
          await _markAnswered(header.installId);
          return true;
        }
        if (h.kind == CloudResultKind.unknownOwner && replace) {
          unknown = true;
          await _prefs.setLastSeq(0);
          await _prefs.setPendingSeq(0);
          return true;
        }
        return false;
      });
      if (!ok) return false;
      final state = await _run(_Run(_Kind.now,
          force: true,
          skipWait: true,
          takeover: true,
          overrideShrink: replace,
          replaceUnknown: unknown));
      return state == BackupState.uploading || state == BackupState.ok;
    } finally {
      if (held) await _releaseCatchUp();
      _setBusy(false);
    }
  }

  /// Combine the Two Copies: each conflict version another install wrote
  /// is merged in, marked resolved, and this phone's record written over
  /// the file. True only once that write landed (the row says "backed
  /// up"); the merge itself stays in either way.
  Future<bool> combine() async {
    _setBusy(true);
    // The merge's import holds the photo catch-up (_importBackup).
    var held = false;
    try {
      final ok = await _locked(() async {
        await _prefs.reload();
        final me = _prefs.installId;
        final ids = <String>{me};
        final dir = (await _tmpPath('conflicts'));
        final versions = await _t.conflicts(kRecordsFileName, dir);
        var imported = false;
        for (final v in versions) {
          final h = v.header;
          try {
            if (h == null || h.kind != BackupKind.records) continue;
            // The adopted install's version as adopted is in already; a
            // later one (it took the backup back) is merged like any other.
            if (h.installId != me && !_isAdopted(h)) {
              await _dao.importJson(await File(v.tmpPath).readAsString());
              imported = true;
            }
            ids.add(h.installId);
          } catch (_) {
            // Unreadable: left unresolved.
          } finally {
            await _deleteQuietly(v.tmpPath);
          }
        }
        // iCloud may have kept the OTHER phone's write as the current file
        // (and ours as the conflict version): merge it too and adopt it, so
        // the write below replaces it with the combined record.
        final cur = await _t.readHeader(kRecordsFileName,
            allowDownload: true, timeout: const Duration(seconds: 30));
        final curHeader = cur.header;
        if (cur.kind == CloudResultKind.ok &&
            curHeader != null &&
            curHeader.installId != me) {
          held = true;
          final (summary, done, before, fetched) =
              await _importBackup(kRecordsFileName, curHeader.installId);
          if (summary.ok && fetched != null) {
            imported = true;
            await _prefs.setAdopted(fetched);
            await _prefs.setLastSeq(0);
            await _prefs.setPendingSeq(0);
            await _adoptMonths(fetched, before: before, restored: done);
            ids.add(fetched.installId);
          }
        }
        if (imported) onDataImported?.call();
        return _t.resolveConflicts(kRecordsFileName, ids.toList());
      });
      if (!ok) return false;
      final state =
          await _run(const _Run(_Kind.now, force: true, takeover: true));
      return state == BackupState.uploading || state == BackupState.ok;
    } finally {
      if (held) await _releaseCatchUp();
      _setBusy(false);
    }
  }

  /// Back Up Again: the records file this install wrote went missing.
  Future<BackupState> backUpAgain() async {
    await _prefs.setPaused(BackupPause.none);
    // Its months may have gone too: looked at again (an adopted month
    // still waiting to come in stays pending).
    final months = _prefs.months
      ..removeWhere((_, m) =>
          m.state != MonthState.foreign && m.state != MonthState.pending);
    await _prefs.setMonths(months);
    return _run(const _Run(_Kind.now, force: true, allowMissing: true));
  }

  /// Back Up Anyway: the user confirmed the smaller record (G5).
  Future<BackupState> backUpAnyway() async {
    await _prefs.setPaused(BackupPause.none);
    return _run(const _Run(_Kind.now, force: true, overrideShrink: true));
  }

  /// Deletes this install's files (and the adopted install's, once this
  /// install's records file replaced theirs) from the folder; anything
  /// another install wrote stays. Only the paths this install wrote or
  /// adopted are sent (its months, the records file and the previous
  /// copy): another phone's months, never read here and maybe not even
  /// downloaded, are none of its business. The switch is left as it is.
  ///
  /// Pictures go first and the records file last, so a delete that stops
  /// part-way never leaves pictures the records file no longer names. When
  /// it does stop part-way, the months that are gone are forgotten and the
  /// rest of the backup stays known, so Delete can be tried again.
  Future<BackupDeleteResult> deleteBackup() async {
    _setBusy(true);
    try {
      return await _locked(() async {
        await _prefs.reload();
        final me = _prefs.installId;
        if (!isValidInstallId(me)) return BackupDeleteResult.deleted;
        // Before this install wrote over the adopted file, it is still
        // that install's live backup.
        final adopted = _adoptionTaken ? _prefs.adoptedFrom : '';
        final months = _prefs.months;
        final result = await _deleteInOrder([
          [
            for (final e in months.entries)
              if (e.value.state != MonthState.foreign) picturesPath(e.key),
          ],
          const [kPreviousFileName],
          const [kRecordsFileName],
        ], WriteExpect(
            installId: me,
            adoptFrom: adopted.isEmpty ? null : adopted,
            adoptMaxSeq: _prefs.adoptedSeq));
        _headerCache.clear();
        _listing = null;
        if (result == BackupDeleteResult.deleted) {
          await _prefs.forgetBackup(keepNotice: true);
        } else {
          for (final m in months.keys.toList()) {
            if (months[m]!.state == MonthState.foreign) continue;
            final st = await _t.itemState(picturesPath(m));
            if (st.exists == ItemExists.no) months.remove(m);
          }
          await _prefs.setMonths(months);
        }
        _status.value = _statusFromPrefs();
        return result;
      });
    } finally {
      _setBusy(false);
    }
  }

  /// How long a delete waits, in all, for files that are not on this phone
  /// yet to download.
  static const Duration deleteDownloadWait = Duration(seconds: 60);

  /// Deletes each step's paths, a step only once everything before it is
  /// gone. A file not on this phone yet has no owner Swift can read, so it
  /// is read first: a coordinated read waits for its download (within
  /// [deleteDownloadWait] in all), and Swift then decides inside the
  /// delete, as always. Another install's file is never deleted and does
  /// not stop the steps.
  Future<BackupDeleteResult> _deleteInOrder(
      List<List<String>> steps, WriteExpect expect) async {
    final all = [for (final step in steps) ...step];
    await _t.startDownloads(all);
    final until = _now.add(deleteDownloadWait);
    for (final p in all) {
      final st = await _t.itemState(p);
      if (st.exists != ItemExists.yes || !st.downloading) continue;
      final left = until.difference(_now);
      if (left <= Duration.zero) break;
      await _t.readHeader(p,
          allowDownload: true,
          timeout: left < const Duration(seconds: 30)
              ? left
              : const Duration(seconds: 30));
    }
    var deleted = 0;
    for (final step in steps) {
      if (step.isEmpty) continue;
      final r = await _t.delete(step, expect);
      deleted += r.deleted;
      if (!r.ok || r.left > 0) {
        return deleted > 0
            ? BackupDeleteResult.partial
            : BackupDeleteResult.failed;
      }
    }
    return BackupDeleteResult.deleted;
  }

  /// Turning the switch off: keep the files (the default; null) or delete
  /// them. A run in progress stops before its next upload.
  Future<BackupDeleteResult?> turnOff({required bool deleteFiles}) async {
    await _prefs.setEnabled(false);
    await _dropUnwrittenAdoption();
    _dropNotice();
    _status.value = _statusFromPrefs();
    if (!deleteFiles) return null;
    final result = await deleteBackup();
    _status.value = _statusFromPrefs();
    return result;
  }

  // ------------------------------------------------------ headless engine

  /// The background refresh run (background_glue), after the photo scan:
  /// only a backup this install already owns, only when it changed, never
  /// a download or a question (G8), and only with [left] ≥ 8 s.
  static Future<void> runHeadless({
    required MealsDao dao,
    required SharedPreferences prefs,
    required Duration left,
    required Future<Directory> Function() tempDir,
    BackupTransport transport = const ICloudTransport(),
    @visibleForTesting DateTime Function()? clock,
  }) async {
    if (left < const Duration(seconds: 8)) return;
    var timeout = left - const Duration(seconds: 5);
    if (timeout > const Duration(seconds: 15)) {
      timeout = const Duration(seconds: 15);
    }
    final c = BackupCoordinator(
        dao: dao,
        transport: transport,
        prefs: prefs,
        tempDir: tempDir,
        clock: clock,
        uiEngine: false);
    await c._run(_Run(_Kind.headless, timeout: timeout));
  }

  /// Test seam: one automatic run of [kind] as the triggers start it.
  @visibleForTesting
  Future<BackupState> runForTest(
          {bool background = false, Duration? timeout}) =>
      _run(_Run(background ? _Kind.background : _Kind.foreground,
          timeout: timeout ?? const Duration(seconds: 20)));

  @visibleForTesting
  Future<void> launchCheckForTest() => _launchCheck();

  /// Test seam: the status the Settings rows render.
  @visibleForTesting
  void debugSetStatus(BackupStatus status) => _status.value = status;
}
