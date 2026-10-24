/// Meta glasses session (feat/meta-dat prototype, docs/META_DAT.md):
/// connect Bitewise in the Meta AI app, start a session, and every photo
/// the glasses take while this screen is open goes through the app's ONE
/// photo pipeline as deliberate intake (MealSource.appGlasses).
///
/// Behind BITEWISE_META_DAT (meta_dat_flags.dart): without it the add sheet
/// never offers this screen and nothing initialises the native SDK. The
/// session cannot outlive the foreground, so leaving the app ends it.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../services/glasses/glasses_intake.dart';
import '../../services/glasses/meta_dat_channel.dart';
import '../../services/glasses/meta_dat_flags.dart';
import '../../services/glasses/shutter_arbiter.dart';
import '../l10n.dart';
import '../meal_edit_logic.dart' show formatClock;
import '../outcome_text.dart';
import '../photo_pipeline.dart';
import '../widgets/grouped.dart';
import 'glasses_session_strings.dart';

class GlassesSessionScreen extends StatefulWidget {
  const GlassesSessionScreen({
    super.key,
    required this.processPhoto,
    this.announceOutcome,
    this.channel,
    this.links,
    this.initialLink,
    this.useMock = kMetaDatMock,
    this.now = DateTime.now,
    this.shutterWindow = const Duration(seconds: 3),
  });

  /// The app's serialized pipeline (UiServices.processPhoto).
  final Future<PhotoOutcome> Function(IntakePhoto photo) processPhoto;

  /// The pipeline's snackbar sink, for a verdict that lands after this
  /// screen closed (the add flow's rule: unannouncedOutcome).
  final void Function(PhotoOutcome outcome)? announceOutcome;

  /// Injected in tests; otherwise the screen owns one.
  final MetaDatChannel? channel;

  /// The app's incoming links (app_links): the Meta AI callback arrives
  /// here after "Connect" and after a camera-permission prompt.
  final Stream<Uri>? links;
  final Future<Uri?> Function()? initialLink;

  /// Pair Mock Device Kit glasses (BITEWISE_META_DAT_MOCK, debug builds).
  final bool useMock;
  final DateTime Function() now;
  final Duration shutterWindow;

  @override
  State<GlassesSessionScreen> createState() => _GlassesSessionScreenState();
}

class _Shot {
  _Shot(this.photo);
  final MetaDatPhoto photo;
  PhotoOutcome? outcome;
}

class _GlassesSessionScreenState extends State<GlassesSessionScreen>
    with WidgetsBindingObserver {
  /// Thumbnails kept on screen; older shots drop their bytes.
  static const _maxShots = 12;

  late final MetaDatChannel _channel = widget.channel ?? MetaDatChannel();
  late final bool _ownsChannel = widget.channel == null;
  late final ShutterArbiter _arbiter = ShutterArbiter(
    capture: _captureFromButton,
    window: widget.shutterWindow,
  );
  StreamSubscription<MetaDatEvent>? _events;
  StreamSubscription<Uri>? _links;

  MetaDatStatus? _status; // null while booting

  /// A state event arrived before boot had a status to fold it into.
  bool _missedWhileBooting = false;

  /// The launch link stays the app's initial link for the whole process:
  /// forwarded once, or every later visit would replay a used callback.
  static final Set<String> _forwardedInitialLinks = {};
  bool _busy = false;
  bool _capturing = false;
  double? _progress;
  String? _notice;
  final List<_Shot> _shots = [];

  GlassesSessionStrings get _s => GlassesSessionStrings.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = _channel.events.listen(_onEvent);
    _links = widget.links?.listen((uri) => unawaited(_onLink(uri)));
    unawaited(_boot());
  }

  Future<void> _boot() async {
    var status = await _channel.status();
    String? notice;
    if (status.supported) {
      try {
        status = await _channel.configure();
        if (widget.useMock && status.mockAvailable) {
          await _channel.enableMock();
          status = await _channel.status();
        }
      } on MetaDatException catch (e) {
        notice = e.code;
      }
      // Cold start from the Meta AI callback: the link that launched the
      // app is still waiting.
      final initial = widget.initialLink;
      if (initial != null) {
        Uri? uri;
        try {
          uri = await initial();
        } catch (_) {}
        if (uri != null &&
            isMetaDatCallback(uri) &&
            _forwardedInitialLinks.add(uri.toString())) {
          status = await _forwardCallback(uri) ?? status;
        }
      }
    }
    // Events that came while booting (the mock's device appearing, a
    // registration finishing) are already in the native state: read it
    // again rather than replay them over an older snapshot.
    for (var i = 0; i < 3 && _missedWhileBooting && status.supported; i++) {
      _missedWhileBooting = false;
      status = await _channel.status();
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      if (notice != null) _notice = _s.failure(notice);
    });
  }

  Future<void> _onLink(Uri uri) async {
    final status = await _forwardCallback(uri);
    if (mounted && status != null) setState(() => _status = status);
  }

  /// Hands a Meta AI callback to the toolkit; the status after it, or null
  /// for a link that is not ours (or no plugin).
  Future<MetaDatStatus?> _forwardCallback(Uri uri) async {
    if (!isMetaDatCallback(uri)) return null;
    try {
      await _channel.handleCallback(uri);
    } on MetaDatException catch (e) {
      if (mounted) setState(() => _notice = _s.failure(e.code));
    }
    final status = await _channel.status();
    return status.supported ? status : null;
  }

  void _onEvent(MetaDatEvent e) {
    _arbiter.onEvent(e);
    if (!mounted) return;
    switch (e) {
      case MetaDatPhoto():
        unawaited(_onPhoto(e));
      case MetaDatProgress(:final fraction):
        setState(() => _progress = fraction);
      case MetaDatButton(:final press):
        if (press == MetaDatPress.shortPress) {
          setState(() => _notice = _s.shutterPressed);
        }
      case MetaDatFailure(:final code):
        setState(() {
          _capturing = false;
          _progress = null;
          _notice = _s.failure(code);
        });
      default:
        if (_status == null) {
          _missedWhileBooting = true;
        } else {
          setState(() => _status = _status!.apply(e));
        }
    }
  }

  Future<void> _onPhoto(MetaDatPhoto photo) async {
    final shot = _Shot(photo);
    setState(() {
      _capturing = false;
      _progress = null;
      _notice = null;
      _shots.insert(0, shot);
      if (_shots.length > _maxShots) _shots.removeLast();
    });
    PhotoOutcome outcome;
    try {
      outcome = await widget.processPhoto(
        glassesIntakePhoto(photo, now: widget.now),
      );
    } catch (_) {
      // process() is contractually non-throwing; a throwing test double or
      // a future refactor must still not leave the row spinning.
      outcome = const PhotoOutcome(
        PhotoOutcomeKind.failed,
        'Could not analyze the photo.',
      );
    }
    if (!mounted) {
      final say = unannouncedOutcome(outcome, picked: true);
      if (say != null) {
        try {
          widget.announceOutcome?.call(say);
        } catch (_) {}
      }
      return;
    }
    setState(() => shot.outcome = outcome);
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on MetaDatException catch (e) {
      if (mounted) setState(() => _notice = _s.failure(e.code));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _guard(() async {
    await _channel.register();
    final status = await _channel.status();
    if (mounted) setState(() => _status = status);
  });

  Future<void> _start() => _guard(() async {
    // Asks through the Meta AI app the first time; mock glasses and an
    // earlier "Allow always" answer at once.
    if (!await _channel.requestCameraPermission()) {
      if (mounted) setState(() => _notice = _s.permissionDenied);
      return;
    }
    await _channel.startSession();
    if (mounted) setState(() => _notice = null);
  });

  Future<void> _stop() => _guard(() async {
    await _channel.stopSession();
    final status = await _channel.status();
    if (mounted) setState(() => _status = status);
  });

  Future<void> _takePhoto() => _guard(() async {
    final ok = await _channel.capture();
    if (!mounted) return;
    setState(() {
      _capturing = ok;
      if (!ok) _notice = _s.notReady;
    });
  });

  /// The arbiter's request after a shutter press the glasses did not
  /// answer with a photo of their own.
  Future<bool> _captureFromButton() async {
    final ok = await _channel.capture();
    if (ok && mounted) setState(() => _capturing = true);
    return ok;
  }

  Future<void> _mockPress() => _guard(() async {
    await _channel.mockCapturePress();
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // DAT ends a session when the app backgrounds anyway; ending it here
    // keeps the screen's state honest and releases the glasses at once.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_status?.supported ?? false) unawaited(_stopQuietly());
    }
  }

  /// Unconditional: a session just asked for may not have reported
  /// `starting` yet, and stopping none is a no-op natively.
  Future<void> _stopQuietly() async {
    try {
      await _channel.stopSession();
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _arbiter.dispose();
    unawaited(_events?.cancel());
    unawaited(_links?.cancel());
    if (_status?.supported ?? false) unawaited(_stopQuietly());
    if (_ownsChannel) unawaited(_channel.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final status = _status;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: groupedBackground(scheme),
      appBar: AppBar(title: Text(s.title)),
      body: status == null
          ? const Center(child: CircularProgressIndicator())
          : !status.supported
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(s.unsupported, textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                GroupedSection(
                  header: s.statusHeader,
                  footer: s.keepOpen,
                  children: [
                    GroupedRow(
                      icon: Icons.link,
                      title: s.registrationLabel,
                      value: s.registration(status.registration),
                    ),
                    GroupedRow(
                      icon: Icons.visibility_outlined,
                      title: s.glassesLabel,
                      value: s.devices(
                        status.deviceCount,
                        active: status.activeDevice,
                        mock: status.mock,
                      ),
                    ),
                    GroupedRow(
                      icon: Icons.sensors,
                      title: s.sessionLabel,
                      value: s.session(status.session),
                    ),
                  ],
                ),
                GroupedSection(
                  children: [
                    if (!status.registered)
                      GroupedRow(
                        key: const Key('glassesConnect'),
                        icon: Icons.login,
                        title: s.connect,
                        enabled: !_busy,
                        onTap: _connect,
                      ),
                    if (!status.sessionLive)
                      GroupedRow(
                        key: const Key('glassesStart'),
                        icon: Icons.play_arrow_rounded,
                        title: s.start,
                        enabled: !_busy && status.canStart,
                        onTap: _start,
                      )
                    else
                      GroupedRow(
                        key: const Key('glassesStop'),
                        icon: Icons.stop_rounded,
                        iconColor: scheme.error,
                        title: s.stop,
                        enabled: !_busy,
                        onTap: _stop,
                      ),
                    GroupedRow(
                      key: const Key('glassesCapture'),
                      icon: Icons.photo_camera_outlined,
                      title: _capturing ? s.capturing : s.takePhoto,
                      enabled: !_busy && !_capturing && status.canCapture,
                      onTap: _takePhoto,
                    ),
                    if (status.mock)
                      GroupedRow(
                        key: const Key('glassesMockPress'),
                        icon: Icons.radio_button_checked,
                        iconColor: scheme.tertiary,
                        title: s.mockPress,
                        enabled: !_busy && status.canCapture,
                        onTap: _mockPress,
                      ),
                  ],
                ),
                if (_progress != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 16, 32, 0),
                    child: LinearProgressIndicator(
                      key: const Key('glassesProgress'),
                      value: _progress,
                    ),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 16, 32, 0),
                    child: Text(
                      _notice!,
                      key: const Key('glassesNotice'),
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (_shots.isNotEmpty)
                  GroupedSection(
                    header: s.photosHeader,
                    separatorInset: 16,
                    children: [for (final shot in _shots) _ShotRow(shot: shot)],
                  ),
              ],
            ),
    );
  }
}

class _ShotRow extends StatelessWidget {
  const _ShotRow({required this.shot});
  final _Shot shot;

  @override
  Widget build(BuildContext context) {
    final outcome = shot.outcome;
    final l = context.l10n;
    final theme = Theme.of(context);
    final title = outcome == null
        ? GlassesSessionStrings.of(context).analyzing
        : switch (outcome.kind) {
            PhotoOutcomeKind.saved => l.outcomeSaved,
            PhotoOutcomeKind.skipped => l.outcomeSkipped,
            PhotoOutcomeKind.duplicate => l.outcomeDuplicate,
            PhotoOutcomeKind.alreadyTracked => l.outcomeAlreadyTracked,
            PhotoOutcomeKind.inFlight => l.outcomeInFlight,
            PhotoOutcomeKind.failed => l.outcomeFailed,
            PhotoOutcomeKind.leftoverApplied => l.outcomeLeftoverApplied,
          };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: _Thumb(bytes: shot.photo.bytes),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                Text(
                  outcome == null
                      ? context.clock(
                          formatClock(shot.photo.receivedAt.toLocal()),
                        )
                      : outcomeBody(l, outcome, deliberate: true),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (outcome == null)
            const Padding(
              padding: EdgeInsets.only(left: 8, top: 4),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) => Image.memory(
    bytes,
    fit: BoxFit.cover,
    // Decoded at thumbnail size: a 12 MP glasses photo must not sit
    // in memory full-size for a 56 pt cell.
    cacheWidth: 168,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.image_outlined),
    ),
  );
}
