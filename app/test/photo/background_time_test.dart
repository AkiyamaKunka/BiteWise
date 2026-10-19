/// iOS background time for the photo in flight (2026-10-19): one task per
/// photo, always ended — a task left open when iOS's time runs out gets the
/// app killed, and a begin per retry would stretch the time iOS gave.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart' show AnalysisErrorKind;
import 'package:calorie_tracker/services/photo/background_time.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';

import '../ui/fakes.dart';

/// The native side, as the tests see it: every call in order, and the
/// tasks still open.
class _NativeTasks {
  final List<String> calls = [];
  final Set<int> open = {};
  int _next = 0;

  /// What begin answers: a token, or null (iOS refused).
  bool refuse = false;

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    switch (call.method) {
      case 'begin':
        calls.add('begin:${args['name']}');
        if (refuse) return null;
        final id = ++_next;
        open.add(id);
        return id;
      case 'end':
        final id = args['id'] as int;
        calls.add('end:$id');
        expect(open.remove(id), isTrue, reason: 'ended a task not open');
        return null;
    }
    throw MissingPluginException();
  }
}

IntakePhoto _photo(int n) =>
    IntakePhoto(Uint8List.fromList([n, n, n]), 'asset$n', 'IMG_$n.jpg');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(backgroundTimeChannelName);
  late _NativeTasks native;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    native = _NativeTasks();
    messenger.setMockMethodCallHandler(channel, native.handle);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('guard begins one task, runs the body inside it, ends it', () async {
    final seen = <String>[];
    final out = await const BackgroundTime().guard('photo', () async {
      seen.add('body with ${native.open.length} open');
      return 42;
    });
    expect(out, 42);
    expect(seen, ['body with 1 open']);
    expect(native.calls, ['begin:photo', 'end:1']);
    expect(native.open, isEmpty);
  });

  test('a throwing body still ends its task, and the error comes through',
      () async {
    await expectLater(
        const BackgroundTime()
            .guard<void>('photo', () async => throw StateError('boom')),
        throwsStateError);
    expect(native.calls, ['begin:photo', 'end:1']);
    expect(native.open, isEmpty);
  });

  test('iOS refused (no token): the body runs, nothing to end', () async {
    native.refuse = true;
    final out = await const BackgroundTime().guard('photo', () async => 'ran');
    expect(out, 'ran');
    expect(native.calls, ['begin:photo']);
  });

  test('no channel (Android, an old build): the body runs, nothing throws',
      () async {
    messenger.setMockMethodCallHandler(channel, null);
    final out = await const BackgroundTime().guard('photo', () async => 'ran');
    expect(out, 'ran');
    await const BackgroundTime().end(7); // never throws
  });

  // Paused or hidden: the GPU is off and the time is iOS's to give.
  // Inactive (Control Center, the app switcher) is still on screen.
  testWidgets('appEngineBackgrounded: paused and hidden only',
      (tester) async {
    final expected = {
      AppLifecycleState.resumed: false,
      AppLifecycleState.inactive: false,
      AppLifecycleState.hidden: true,
      AppLifecycleState.paused: true,
      AppLifecycleState.detached: false,
    };
    for (final MapEntry(key: state, value: away) in expected.entries) {
      tester.binding.handleAppLifecycleStateChanged(state);
      expect(appEngineBackgrounded(), away, reason: '$state');
      expect(appEngineInForeground(), !away, reason: '$state');
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  group('PhotoPipeline with background time', () {
    test('every photo gets exactly one task, ended before the next begins',
        () async {
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true}, isFood: true, wall: Duration.zero);
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: analyzer,
          backgroundTime: const BackgroundTime());
      // Through the FIFO, as the watcher, share sheet and add flow use it.
      final outs = await Future.wait(
          [for (var n = 1; n <= 3; n++) pipeline.enqueue(_photo(n))]);
      expect(outs.map((o) => o.kind), everyElement(PhotoOutcomeKind.saved));
      expect(native.calls, [
        'begin:photo', 'end:1', //
        'begin:photo', 'end:2', //
        'begin:photo', 'end:3',
      ]);
      expect(native.open, isEmpty);
    });

    test('a photo whose save throws (contained) still ends its task',
        () async {
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true}, isFood: true, wall: Duration.zero);
      final out = await PhotoPipeline(
              dao: _ThrowingSaveDao(),
              analyzer: analyzer,
              backgroundTime: const BackgroundTime())
          .process(_photo(1));
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(native.calls, ['begin:photo', 'end:1']);
      expect(native.open, isEmpty);
    });

    // 2026-10-19: after the user left, each finished photo started the
    // next from the background; the shared ~30 s ran out mid-photo and it
    // froze reserved or mid-upload, one or two photos later.
    test('once the app is in the background no automatic photo starts: no '
        'task, no hash, no reservation, released for the next scan',
        () async {
      var hashed = 0;
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true}, isFood: true, wall: Duration.zero);
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          backgroundTime: const BackgroundTime(),
          backgrounded: () => true,
          hasher: (b) async {
            hashed++;
            return 'h${b.first}';
          });
      final out = await pipeline.enqueue(_photo(1));
      expect(out.retryable, isTrue, reason: 'the frontier halts in front');
      expect(native.calls, isEmpty);
      expect(hashed, 0);
      expect(dao.ledger, isEmpty);
      // A photo the user picked or shared still runs, in its own task.
      final picked = IntakePhoto(
          Uint8List.fromList([2, 2, 2]), 'asset2', 'IMG_2.jpg',
          deliberate: true);
      expect((await pipeline.enqueue(picked)).kind, PhotoOutcomeKind.saved);
      expect(native.calls, ['begin:photo', 'end:1']);
    });

    test('the photo in flight when the user leaves finishes in its task; '
        'the one after it waits', () async {
      var away = false;
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true}, isFood: true, wall: Duration.zero)
        ..onAnalyze = () async => away = true; // the user leaves mid-upload
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          backgroundTime: const BackgroundTime(),
          backgrounded: () => away,
          hasher: (b) async => 'h${b.first}');
      final outs = await Future.wait(
          [pipeline.enqueue(_photo(1)), pipeline.enqueue(_photo(2))]);
      expect(outs.first.kind, PhotoOutcomeKind.saved);
      expect(outs.last.retryable, isTrue);
      expect(dao.meals, hasLength(1));
      expect(native.calls, ['begin:photo', 'end:1']);
      expect(native.open, isEmpty);
    });

    test('an undecodable verdict reached in the background is deferred, not '
        'burned: in the foreground the same photo decodes', () async {
      var away = false;
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'Could not process this photo (decode failed).',
            wall: Duration.zero)
        ..onAnalyze = () async => away = true;
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          backgrounded: () => away,
          hasher: (b) async => 'h${b.first}');
      final out = await pipeline.process(_photo(1));
      expect(out.errorKind, AnalysisErrorKind.badPhoto);
      expect(out.retryable, isTrue);
      expect(dao.ledger, isEmpty, reason: 'released, not failed');
      // In the foreground the verdict is the permanent one, as before.
      away = false;
      final again = PhotoPipeline(
          dao: dao, analyzer: FakeAnalyzer()
            ..nextPhotoOutcome = analyzer.nextPhotoOutcome,
          backgrounded: () => false,
          hasher: (b) async => 'h${b.first}');
      expect((await again.process(_photo(1))).retryable, isFalse);
      expect(dao.ledger['h1'], IngestionStatus.failed);
    });

    test('a throwing probe reads as the foreground', () async {
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true}, isFood: true, wall: Duration.zero);
      final out = await PhotoPipeline(
              dao: FakeDao(),
              analyzer: analyzer,
              backgrounded: () => throw StateError('no binding'),
              hasher: (b) async => 'h${b.first}')
          .process(_photo(1));
      expect(out.kind, PhotoOutcomeKind.saved);
    });

    test('without background time (headless run, Android) no task is begun',
        () async {
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true}, isFood: true, wall: Duration.zero);
      await PhotoPipeline(dao: FakeDao(), analyzer: analyzer)
          .process(_photo(1));
      expect(native.calls, isEmpty);
    });
  });
}

class _ThrowingSaveDao extends FakeDao {
  @override
  Future<int> saveMeal(Meal meal,
          {IngestionStatus? markStatus, String? ownerStamp}) async =>
      throw StateError('disk full');
}
