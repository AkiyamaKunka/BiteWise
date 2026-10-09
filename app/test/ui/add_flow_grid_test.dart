// The recent-photos grid's MEMORY contract (rewritten 2026-07-31).
//
// It used to read up to THIRTY originals (25 MB each) before showing
// anything, hold them all alive for the screen's lifetime, and decode
// every 12 MP image full-res into a ~120 px cell. On a mid-range phone
// that is hundreds of MB for a screen that ends up using exactly ONE
// photo. These tests pin the new shape: list assets, thumbnail per cell,
// original bytes only for the tapped photo.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Only the access check is reachable from the grid; everything else says
/// so loudly if that changes.
class _AccessLibrary implements PhotoLibrary {
  _AccessLibrary({required this.full});
  final bool full;
  @override
  Future<bool> hasFullAccess() async => full;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<Uint8List?> thumbnailByAssetId(String assetId, {int size = 160}) =>
      throw UnimplementedError();
  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) =>
      throw UnimplementedError();
  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
          {int limit = 500}) =>
      throw UnimplementedError();
  @override
  Future<List<LibraryAsset>> recentImages(int limit) =>
      throw UnimplementedError();
  @override
  Future<void> startChangeNotify(void Function() onChange) =>
      throw UnimplementedError();
  @override
  Future<void> stopChangeNotify() => throw UnimplementedError();
}

IntakePhoto _photo(String id) => IntakePhoto(
    Uint8List.fromList(List.filled(16, 3)), id, '$id.jpg',
    capturedAt: DateTime(2026, 7, 30, 12));

void main() {
  testWidgets('the grid reads THUMBNAILS only — no originals until a tap',
      (tester) async {
    final picker = FakePicker()
      ..photos = [for (var i = 0; i < 12; i++) _photo('a$i')];
    final services = makeServices(picker: picker);

    await tester.pumpWidget(
        MaterialApp(home: AddPhotoScreen(services: services)));
    await tester.pumpAndSettle();

    expect(picker.loadedOriginals, isEmpty,
        reason: 'showing the grid must not read a single original');
    expect(picker.thumbnailed, isNotEmpty,
        reason: 'cells render from thumbnails');
    expect(find.byKey(const Key('recentPhoto0')), findsOneWidget);
  });

  testWidgets('tapping reads exactly ONE original and runs it through the '
      'app pipeline as a DELIBERATE add', (tester) async {
    final picker = FakePicker()..photos = [_photo('a0'), _photo('a1')];
    final processed = <IntakePhoto>[];
    final services = makeServices(
        picker: picker,
        processPhoto: (photo) async {
          processed.add(photo);
          return const PhotoOutcome(
              PhotoOutcomeKind.saved, 'Meal logged: ok');
        });

    await tester.pumpWidget(
        MaterialApp(home: AddPhotoScreen(services: services)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recentPhoto1')));
    await tester.pumpAndSettle();

    expect(picker.loadedOriginals, ['a1'],
        reason: 'ONLY the tapped photo costs an original read');
    expect(processed.single.assetId, 'a1');
    expect(processed.single.deliberate, isTrue,
        reason: 'user-picked adds reclaim skipped/failed ledger rows '
            '(spec §2.3)');
    expect(processed.single.capturedAt, isNotNull,
        reason: '§6.3 dating must survive the lazy path');
  });

  testWidgets('a double tap runs ONE analysis, not two', (tester) async {
    // onTap reads _analyzing from the last BUILD, so two taps in the same
    // frame both passed that gate — two model calls and two ledger
    // reservations for one meal.
    final picker = FakePicker()..photos = [_photo('a0')];
    final processed = <IntakePhoto>[];
    final services = makeServices(
        picker: picker,
        processPhoto: (photo) async {
          processed.add(photo);
          return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
        });
    await tester.pumpWidget(
        MaterialApp(home: AddPhotoScreen(services: services)));
    await tester.pumpAndSettle();

    // Two taps with NO pump between them: the same frame.
    final cell = find.byKey(const Key('recentPhoto0'));
    await tester.tap(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(picker.loadedOriginals, hasLength(1));
    expect(processed, hasLength(1),
        reason: 'one photo, one model call, one ledger reservation');
  });

  testWidgets('a photo still being analyzed elsewhere says so — not '
      '"Already logged", and no manual-log offer', (tester) async {
    // The watcher (or an iOS background run cut off mid-analysis) holds
    // this photo's reservation; the user picks the same photo. It is not
    // logged yet, so "Already logged" was wrong, and it is not a refusal
    // either, so there is nothing to log by hand (2026-10-07).
    final picker = FakePicker()..photos = [_photo('a0')];
    final services = makeServices(
        picker: picker,
        processPhoto: (photo) async => const PhotoOutcome(
            PhotoOutcomeKind.inFlight,
            'This photo is still being analyzed — check back in a moment.',
            retryable: true));
    await tester.pumpWidget(
        MaterialApp(home: AddPhotoScreen(services: services)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recentPhoto0')));
    await tester.pumpAndSettle();

    expect(find.text('Still analyzing'), findsOneWidget);
    expect(find.text('Already logged'), findsNothing);
    expect(find.textContaining('still being analyzed'), findsOneWidget);
    expect(find.byKey(const Key('logManuallyButton')), findsNothing);
  });

  testWidgets('an unreadable original says so instead of hanging on the '
      'spinner', (tester) async {
    // loadOriginal returns null for a photo that vanished or exceeds the
    // 25 MB cap — the old eager path silently dropped those from the grid.
    final picker = FakePicker()..photos = [_photo('gone')];
    final services = makeServices(picker: picker);
    await tester.pumpWidget(
        MaterialApp(home: AddPhotoScreen(services: services)));
    await tester.pumpAndSettle();
    picker.photos = const []; // the asset disappears before the tap
    await tester.tap(find.byKey(const Key('recentPhoto0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.byKey(const Key('photoAnalyzing')), findsNothing);
  });
  group('a wrong automatic leftover verdict (2026-10-09)', () {
    // The model called a NEW meal leftovers of an earlier one: that meal
    // was cut in place and the dialog offered only OK. Re-picking the
    // photo repeated the verdict, so the photo could never be logged.
    Meal tray() => Meal(
          id: 1,
          date: '2026-07-30',
          time: '11:30 AM',
          timestamp: '2026-07-30T11:30:00',
          source: 'app_watch',
          imageHash: 'orig-1',
          analysis: {
            'is_food': true,
            'meal_description': 'Cafeteria tray',
            'total_calories': 965,
            'total_protein_g': 40,
            'total_carbs_g': 90,
            'total_fat_g': 40,
            'food_items': [
              {'name': 'Rice (~200 g)', 'estimated_calories': 300},
              {'name': 'Pork (~150 g)', 'estimated_calories': 665},
            ],
          },
        );

    ({FakeDao dao, FakePicker picker, UiServices services}) setUpFlow() {
      final dao = FakeDao()..seed(tray());
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = const AnalysisOutcome(analysis: {
          'is_food': true,
          'leftover_of': 0,
          'confidence': 0.9,
          'leftover_fraction': 0.4,
          'items': [
            {'name': 'Rice (~200 g)', 'left_fraction': 1.0},
            {'name': 'Pork (~150 g)', 'left_fraction': 0.0},
          ],
        }, isFood: true, wall: Duration.zero);
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          hasher: (b) async => originalBytesMd5(b));
      final picker = FakePicker()..photos = [_photo('a0')];
      return (
        dao: dao,
        picker: picker,
        services: makeServices(
            dao: dao, picker: picker, processPhoto: pipeline.process),
      );
    }

    testWidgets('"not leftovers" puts the meal back and logs the photo as '
        'its own meal', (tester) async {
      final f = setUpFlow();
      await tester.pumpWidget(
          MaterialApp(home: AddPhotoScreen(services: f.services)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();

      expect(find.text('Leftovers deducted'), findsOneWidget);
      expect(f.dao.byId(1).analysis['total_calories'], 665);
      final hash = originalBytesMd5(_photo('a0').bytes);
      expect(f.dao.ledger[hash], IngestionStatus.skipped);

      await tester.tap(find.byKey(const Key('undoLeftoverButton')));
      await tester.pumpAndSettle();

      final restored = f.dao.byId(1);
      expect(restored.analysis['total_calories'], 965);
      expect(restored.analysis.containsKey('leftover'), isFalse);
      expect(restored.corrected, isTrue,
          reason: 'spec §2.4: every analysis rewrite sets corrected=1');
      expect(find.textContaining('Deduction undone'), findsOneWidget);
      expect(find.byType(MealEditorScreen), findsOneWidget,
          reason: 'the photo goes on to be logged as a new meal');

      await tester.enterText(
          find.byKey(const Key('editorDescription')), 'Noodles');
      await tester.enterText(find.byKey(const Key('editorCalories')), '600');
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pump();

      final day = await f.dao.mealsBetween('2026-07-30', '2026-07-30');
      expect(day.map((m) => m.analysis['total_calories']),
          containsAll([965, 600]),
          reason: 'both meals count, neither cut');
      expect(f.dao.ledger[hash], IngestionStatus.saved,
          reason: 'the photo is attached to its new meal');
    });

    testWidgets('a meal changed since the deduction is left alone',
        (tester) async {
      final f = setUpFlow();
      await tester.pumpWidget(
          MaterialApp(home: AddPhotoScreen(services: f.services)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();

      // A fix lands while the dialog is up (e.g. a background run).
      await f.dao.updateMealAnalysis(
          1, {...f.dao.byId(1).analysis, 'total_calories': 700});
      await tester.tap(find.byKey(const Key('undoLeftoverButton')));
      await tester.pumpAndSettle();

      expect(f.dao.byId(1).analysis['total_calories'], 700);
      expect(find.textContaining('changed or deleted'), findsOneWidget);
    });

    testWidgets('no undo offer on an ordinary save', (tester) async {
      final services = makeServices(
          picker: FakePicker()..photos = [_photo('a0')],
          processPhoto: (photo) async =>
              const PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged: ok'));
      await tester.pumpWidget(
          MaterialApp(home: AddPhotoScreen(services: services)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();
      expect(find.text('Meal logged'), findsOneWidget);
      expect(find.byKey(const Key('undoLeftoverButton')), findsNothing);
    });
  });

  group('a limited ("selected photos") grant (2026-10-09)', () {
    // The grid showed only the photos picked in that one system dialog,
    // with nothing saying others exist — a meal shot later never appeared
    // and the screen offered no way to grant the rest.
    testWidgets('says so above the grid, with a way to system settings',
        (tester) async {
      var opened = 0;
      final services = makeServices(
          picker: FakePicker()..photos = [_photo('a0')],
          photoLibrary: _AccessLibrary(full: false),
          openSystemSettings: () async => opened++);
      await tester.pumpWidget(
          MaterialApp(home: AddPhotoScreen(services: services)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('addPhotosLimited')), findsOneWidget);
      expect(find.textContaining('Only the photos you allowed'),
          findsOneWidget);
      expect(find.byKey(const Key('recentPhoto0')), findsOneWidget,
          reason: 'the allowed photos stay pickable');
      await tester.tap(find.byKey(const Key('addPhotosLimitedSettings')));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('nothing selected is not "no recent photos"', (tester) async {
      final services = makeServices(
          picker: FakePicker()..photos = const [],
          photoLibrary: _AccessLibrary(full: false),
          openSystemSettings: () async {});
      await tester.pumpWidget(
          MaterialApp(home: AddPhotoScreen(services: services)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('addPhotosLimited')), findsOneWidget);
      expect(find.text('No recent photos found.'), findsNothing);
    });

    testWidgets('full access shows no note', (tester) async {
      final services = makeServices(
          picker: FakePicker()..photos = [_photo('a0')],
          photoLibrary: _AccessLibrary(full: true),
          openSystemSettings: () async {});
      await tester.pumpWidget(
          MaterialApp(home: AddPhotoScreen(services: services)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('addPhotosLimited')), findsNothing);
      expect(find.byKey(const Key('scaleReferenceTip')), findsOneWidget);
    });

    testWidgets('no settings opener: the note still shows, without a dead '
        'button', (tester) async {
      final services = makeServices(
          picker: FakePicker()..photos = [_photo('a0')],
          photoLibrary: _AccessLibrary(full: false));
      await tester.pumpWidget(
          MaterialApp(home: AddPhotoScreen(services: services)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('addPhotosLimited')), findsOneWidget);
      expect(find.byKey(const Key('addPhotosLimitedSettings')), findsNothing);
    });
  });
}
