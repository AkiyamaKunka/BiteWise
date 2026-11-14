// One photo at a time on Log › From recent photos with full access, where
// the grid and the "Choose from all photos…" row share the screen
// (adversarial review 2026-11-13). A grid tap while the picker was still
// opening ran a second analysis beside the picked photo's: two model
// calls, two outcome dialogs stacked.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/system_photo_picker.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _HeldPicker implements SystemPhotoPicker {
  final held = Completer<SystemPick>();
  int picks = 0;
  @override
  Future<bool> hasBroadAccess() async => true;
  @override
  Future<SystemPick> pick({int max = 1}) {
    picks++;
    return held.future;
  }
}

void main() {
  late List<IntakePhoto> processed;
  late Completer<PhotoOutcome> verdict;

  UiServices services() {
    processed = [];
    verdict = Completer<PhotoOutcome>();
    return UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: FakeSettings(),
      picker: FakePicker()
        ..photos = [
          IntakePhoto(Uint8List.fromList(List.filled(16, 3)), 'a0', 'a0.jpg',
              capturedAt: DateTime(2026, 11, 13, 9))
        ],
      requestPhotoPermission: () async => true,
      processPhoto: (p) {
        processed.add(p);
        return verdict.future;
      },
    );
  }

  final picked = SystemPick(SystemPickStatus.ok, photos: [
    IntakePhoto(Uint8List.fromList(List.filled(8, 9)), '', 'picked.jpg',
        deliberate: true)
  ]);

  testWidgets('a grid tap while the picker is opening is ignored',
      (tester) async {
    final system = _HeldPicker();
    await tester.pumpWidget(MaterialApp(
        home: AddPhotoScreen(services: services(), systemPicker: system)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addChooseAllPhotos')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('recentPhoto0')));
    await tester.pump();
    system.held.complete(picked);
    await tester.pump();
    await tester.pump();
    expect(system.picks, 1);
    expect(processed.map((p) => p.fileName), ['picked.jpg'],
        reason: 'one analysis, one outcome dialog');
    verdict.complete(const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'));
    await tester.pumpAndSettle();
  });

  testWidgets('the row does nothing while a grid photo is analyzed',
      (tester) async {
    final system = _HeldPicker();
    await tester.pumpWidget(MaterialApp(
        home: AddPhotoScreen(services: services(), systemPicker: system)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recentPhoto0')));
    await tester.pump();
    // The row sits under the analyzing overlay; pressed anyway (a hardware
    // keyboard or Switch Control presses the button itself).
    tester
        .widget<ButtonStyleButton>(find.byKey(const Key('addChooseAllPhotos')))
        .onPressed
        ?.call();
    await tester.pump();
    expect(system.picks, 0);
    expect(processed.map((p) => p.fileName), ['a0.jpg']);
    verdict.complete(const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'));
    await tester.pumpAndSettle();
  });
}
