// iOS: shares with the same file name, queued behind a busy pipeline
// (review of the C2 backpressure, 2026-11-13).
//
// receive_sharing_intent's share extension (RSIShareViewController.swift)
// copies each share to <appGroup>/<file name> and REMOVES an existing file
// of that name first: every edited Photos picture is FullSizeRender.jpg,
// every in-memory image TempImage.png. While the C2 backpressure held
// every copy on disk until the pipeline was free, a second share of the
// same name overwrote the first one waiting there: its path read the
// second photo's bytes, and the second path was gone. Two shares, one
// meal, nothing said. iOS reads each copy the moment it arrives again (it
// shares one image at a time, so that is one original per share); only
// Android, whose copies each have a folder of their own, keeps them on
// disk until their turn.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/services/photo/share_intake.dart';
import 'package:calorie_tracker/ui/ai_consent.dart' show SharedPhotoConsentGate;
import 'package:calorie_tracker/ui/photo_pipeline.dart' show PhotoPipeline;
import 'package:flutter_test/flutter_test.dart';

import '../ui/fakes.dart' show FakeAnalyzer, FakeDao, FakeSettings;
import '../photo/watcher_test.dart' show FakePhotoLibrary;

class _Source implements SharedMediaSource {
  final StreamController<List<String>> controller =
      StreamController<List<String>>();
  @override
  Stream<List<String>> imagePathBatches() => controller.stream;
  @override
  Future<List<String>> initialImagePaths() async => [];
}

void main() {
  for (final name in ['FullSizeRender.jpg', 'TempImage.png']) {
    test('two shares named $name behind a busy pipeline are both logged',
        () async {
      final disk = <String, Uint8List>{}; // the app group folder
      // The extension: a same-name file is replaced.
      void extensionWrites(String path, int tag) =>
          disk[path] = Uint8List.fromList([tag, tag, tag]);
      final analyzed = <int>[];
      final release = Completer<void>();
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          hasher: (b) async {
            analyzed.add(b[0]);
            if (analyzed.length == 1) await release.future; // a slow photo
            return 'h${b[0]}';
          },
          thumbnailer: (_) async => null);
      final source = _Source();
      // iOS: no share folder (createShareIntake passes one on Android only).
      pipeline.bindStream(SharedPhotoConsentGate(FakeSettings()).gate(
          ShareIntake(
                  source: source,
                  library: FakePhotoLibrary(),
                  readBytes: (p) async => disk[p],
                  cleanup: (p) async => disk.remove(p),
                  clock: () => DateTime(2026, 11, 13, 12))
              .photos()));

      extensionWrites('/group/IMG_0001.JPG', 1);
      source.controller.add(['/group/IMG_0001.JPG']); // A: in the pipeline
      await pumpEventQueue(times: 50);
      extensionWrites('/group/$name', 2);
      source.controller.add(['/group/$name']); // B: behind A
      await pumpEventQueue(times: 50);
      extensionWrites('/group/$name', 3); // C replaces B's file
      source.controller.add(['/group/$name']);
      await pumpEventQueue(times: 50);

      release.complete();
      await pumpEventQueue(times: 400);
      expect(analyzed, [1, 2, 3],
          reason: 'B was read only after C had replaced it: lost');
      expect(disk, isEmpty, reason: 'every copy still deleted');
      await pipeline.dispose();
    });
  }
}
