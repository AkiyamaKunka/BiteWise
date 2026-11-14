// The share stream never stalls (review of the C2 backpressure,
// 2026-11-13): Not now on every shared photo, and a plugin error between
// two batches, leave later shares flowing.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/ai_consent.dart' show allAiConsentRoutes;
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/share_intake.dart';
import 'package:calorie_tracker/ui/ai_consent.dart' show SharedPhotoConsentGate;
import 'package:calorie_tracker/ui/photo_pipeline.dart' show PhotoPipeline;
import 'package:flutter_test/flutter_test.dart';

import '../ui/fakes.dart' show FakeAnalyzer, FakeDao, FakeSettings;
import '../photo/watcher_test.dart' show FakePhotoLibrary;

class Src implements SharedMediaSource {
  final StreamController<List<String>> controller =
      StreamController<List<String>>();
  List<String> initial = [];
  @override
  Stream<List<String>> imagePathBatches() => controller.stream;
  @override
  Future<List<String>> initialImagePaths() async => initial;
}

void main() {
  final reads = <String>[];
  final cleaned = <String>[];
  final held = <String, Uint8List>{};
  setUp(() {
    reads.clear();
    cleaned.clear();
    held.clear();
  });
  ShareIntake intake(Src s) => ShareIntake(
      source: s,
      library: FakePhotoLibrary(),
      readBytes: (p) async {
        reads.add(p);
        return held[p];
      },
      cleanup: (p) async => cleaned.add(p),
      clock: () => DateTime(2026, 11, 13, 12));
  List<String> share(int n, String prefix) => [
        for (var i = 0; i < n; i++) '/shared/${prefix}_$i.jpg'
      ]..forEach((p) => held[p] = Uint8List.fromList(
          [p.length, p.codeUnitAt(9), p.codeUnitAt(p.length - 5)]));

  test('Not now on every shared photo never stalls the stream', () async {
    final settings = FakeSettings()..aiConsent = {};
    final gate = SharedPhotoConsentGate(settings);
    var asks = 0;
    var allow = false;
    gate.attach(() async {
      asks++;
      if (allow) {
        settings.aiConsent = {...allAiConsentRoutes};
      }
      return allow;
    });
    var analyses = 0;
    final analyzer = FakeAnalyzer()..onAnalyze = () async => analyses++;
    final pipeline = PhotoPipeline(
        dao: FakeDao(),
        analyzer: analyzer,
        hasher: (b) async => 'h${b.join('-')}',
        thumbnailer: (_) async => null);
    final s = Src();
    final i = intake(s);
    // Wired as the app wires it (di.dart): the gate told the deliveries.
    pipeline.bindStream(gate.gate(i.photos(), deliveries: i));
    final first = share(5, 'A');
    s.controller.add(first);
    await pumpEventQueue(times: 100);
    expect(analyses, 0);
    // One Not now covers the whole share (privacy lane): asked once, not
    // once per photo, nothing analyzed, and the copies not read by the
    // answer are deleted unread.
    expect(asks, 1);
    final readFirst = [...reads];
    expect(first.take(readFirst.length), readFirst);
    expect(cleaned.toSet(), first.toSet(), reason: 'no copy left behind');
    allow = true;
    final second = share(3, 'B');
    s.controller.add(second);
    await pumpEventQueue(times: 200);
    expect(asks, 2, reason: 'the next share is asked again');
    expect(reads, [...readFirst, ...second], reason: 'never stalled');
    expect(analyses, 3);
    await pipeline.dispose();
  });

  test('a plugin error between batches does not stall later shares',
      () async {
    final s = Src();
    final got = <String>[];
    final errors = <Object>[];
    late StreamSubscription<IntakePhoto> sub;
    sub = intake(s).photos().listen((p) {
      got.add(p.fileName);
      sub.pause();
      Future<void>.delayed(Duration.zero, sub.resume);
    }, onError: errors.add);
    s.controller.add(share(3, 'A'));
    s.controller.addError(StateError('bad json'));
    s.controller.add(share(2, 'B'));
    await pumpEventQueue(times: 200);
    expect(got, hasLength(5));
    expect(errors, hasLength(1));
    await sub.cancel();
  });
}
