// Log › From recent photos on Android (Play's Photo and Video Permissions
// policy, 2026-11): the system Photo Picker, not a permission prompt.
//
// The screen asked for READ_MEDIA_IMAGES first, and a denial dead-ended
// on "isn't allowed to see your photos" with only Open system settings;
// "selected photos" showed only the earlier picks. The Play build ships
// without the permission at all, so with no access the picker must carry
// the whole flow: consent, pick, analysis, the same dialogs. With full
// access the grid stays, plus a row for the picker. iOS (no picker
// passed) is unchanged; add_flow_grid_test covers it.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/system_photo_picker.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The picker as the screens see it: [broad] is the full-access answer,
/// [replies] the picks in order (cancelled once they run out); [held]
/// keeps a pick open until completed.
class FakeSystemPicker implements SystemPhotoPicker {
  FakeSystemPicker({this.broad = false, List<SystemPick>? replies})
      : replies = replies ?? [];
  bool broad;
  final List<SystemPick> replies;
  Completer<SystemPick>? held;
  int broadAsks = 0;
  final List<int> picks = [];

  @override
  Future<bool> hasBroadAccess() async {
    broadAsks++;
    return broad;
  }

  @override
  Future<SystemPick> pick({int max = 1}) async {
    picks.add(max);
    final h = held;
    if (h != null) return h.future;
    return replies.isEmpty
        ? const SystemPick(SystemPickStatus.cancelled)
        : replies.removeAt(0);
  }
}

/// Every library call is counted; the picker path must make none that can
/// prompt.
class _CountingLibrary implements PhotoLibrary {
  _CountingLibrary({required this.full});
  final bool full;
  int permissionRequests = 0;
  int fullAccessAsks = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<bool> hasFullAccess() async {
    fullAccessAsks++;
    return full;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return full;
  }
}

/// A grid source that counts listings: in production the listing itself
/// asks for library access (di.dart _ShareIntakePicker.recentAssets).
class _CountingPicker extends FakePicker {
  int listings = 0;
  @override
  Future<List<RecentAsset>> recentAssets({int limit = 30}) {
    listings++;
    return super.recentAssets(limit: limit);
  }
}

final _bytes = Uint8List.fromList(List.filled(32, 7));

IntakePhoto _picked([String name = 'PXL_20261113_123000000.jpg']) =>
    IntakePhoto(_bytes, '', name,
        capturedAt: DateTime(2026, 11, 13, 12, 30), deliberate: true);

SystemPick _ok([IntakePhoto? photo]) =>
    SystemPick(SystemPickStatus.ok, photos: [photo ?? _picked()]);

IntakePhoto _gridPhoto(String id) => IntakePhoto(
    Uint8List.fromList(List.filled(16, 3)), id, '$id.jpg',
    capturedAt: DateTime(2026, 11, 13, 9));

class _World {
  _World(
      {bool full = false,
      FakeSettings? settings,
      this.outcome,
      this.grantOnRequest = false})
      : library = _CountingLibrary(full: full),
        settings = settings ?? FakeSettings();
  final _CountingLibrary library;
  final FakeSettings settings;
  final picker = _CountingPicker();
  final processed = <IntakePhoto>[];
  PhotoOutcome? outcome;

  /// What services.requestPhotoPermission answers; false: the Play build,
  /// which declares nothing to grant.
  final bool grantOnRequest;
  int permissionRequests = 0;

  late final UiServices services = UiServices(
    dao: FakeDao(),
    analyzer: FakeAnalyzer(),
    executor: FakeExecutor(),
    settings: settings,
    picker: picker,
    requestPhotoPermission: () async {
      permissionRequests++;
      return grantOnRequest;
    },
    photoLibrary: library,
    openSystemSettings: () async {},
    processPhoto: (p) async {
      processed.add(p);
      return outcome ?? const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
    },
  );

  /// No prompt of any kind was raised for the library.
  void expectNoPermissionAsked() {
    expect(permissionRequests, 0, reason: 'services.requestPhotoPermission');
    expect(library.permissionRequests, 0, reason: 'library.requestPermission');
    expect(picker.listings, 0,
        reason: 'the grid listing asks for access in production');
  }
}

/// Today in miniature: a button that pushes the screen, so a pop shows.
Future<void> _open(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const Key('openAdd'),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => screen)),
            child: const Text('Log'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('openAdd')));
  await tester.pumpAndSettle();
}

Finder get _screen => find.byType(AddPhotoScreen);

void main() {
  group('no photo access (the Play build ships without READ_MEDIA_IMAGES)',
      () {
    testWidgets('the picker opens at once and the photo is logged: no '
        'permission request, no "isn\'t allowed" dead end', (tester) async {
      final w = _World();
      final system = FakeSystemPicker(replies: [_ok()]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));

      expect(system.picks, [1], reason: 'one photo, picked at once');
      w.expectNoPermissionAsked();
      expect(find.byKey(const Key('photoPermissionDenied')), findsNothing);
      expect(w.processed, hasLength(1));
      final photo = w.processed.single;
      expect(photo.deliberate, isTrue,
          reason: 'user-picked: reclaims failed/skipped rows (spec §2.3)');
      expect(photo.bytes, _bytes);
      // The outcome dialog, then the saved meal closes the screen.
      expect(find.text('OK'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(_screen, findsNothing);
    });

    testWidgets('"selected photos" and denied read the same: the picker, '
        'never the grid of earlier picks', (tester) async {
      for (final library in ['limited', 'denied']) {
        final w = _World();
        final system = FakeSystemPicker(broad: false);
        await _open(tester,
            AddPhotoScreen(services: w.services, systemPicker: system));
        expect(system.picks, [1], reason: library);
        w.expectNoPermissionAsked();
        expect(find.byKey(const Key('addPhotosLimited')), findsNothing,
            reason: library);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the AI consent comes BEFORE the picker; Not now opens '
        'nothing and leaves the screen', (tester) async {
      final w = _World(settings: FakeSettings()..aiConsent = {});
      final system = FakeSystemPicker(replies: [_ok()]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));

      expect(find.byKey(const Key('aiConsentDialog')), findsOneWidget);
      expect(system.picks, isEmpty,
          reason: 'no photo is chosen before the recipient is allowed');
      await tester.tap(find.byKey(const Key('aiConsentNotNow')));
      await tester.pumpAndSettle();
      expect(system.picks, isEmpty);
      expect(w.processed, isEmpty);
      expect(_screen, findsNothing, reason: 'nothing to show without a pick');
      expect(find.text('Nothing was sent.'), findsOneWidget);
    });

    testWidgets('Allow is saved, then the picker opens', (tester) async {
      final w = _World(settings: FakeSettings()..aiConsent = {});
      final system = FakeSystemPicker(replies: [_ok()]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));
      await tester.tap(find.byKey(const Key('aiConsentAllow')));
      await tester.pumpAndSettle();
      expect(w.settings.aiConsentWrites, [('gemini', true)]);
      expect(system.picks, [1]);
      expect(w.processed, hasLength(1));
    });

    testWidgets('cancelling the picker closes the screen', (tester) async {
      final w = _World();
      final system = FakeSystemPicker(
          replies: [const SystemPick(SystemPickStatus.cancelled)]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));
      expect(system.picks, [1]);
      expect(_screen, findsNothing);
      expect(w.processed, isEmpty);
      w.expectNoPermissionAsked();
    });

    testWidgets('after a verdict that is not a save, the screen offers the '
        'picker again', (tester) async {
      final w = _World(
          outcome: const PhotoOutcome(PhotoOutcomeKind.skipped, 'not food'));
      final system = FakeSystemPicker(replies: [_ok(), _ok(_picked('b.jpg'))]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));
      expect(find.byKey(const Key('logManuallyButton')), findsOneWidget,
          reason: 'the same dialog as the grid: not food is no dead end');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(_screen, findsOneWidget);
      final again = find.byKey(const Key('addChooseAllPhotos'));
      expect(again, findsOneWidget);
      expect(find.byKey(const Key('photoPermissionDenied')), findsNothing);
      await tester.tap(again);
      await tester.pumpAndSettle();
      expect(system.picks, [1, 1]);
      expect(w.processed.map((p) => p.fileName),
          ['PXL_20261113_123000000.jpg', 'b.jpg']);
      w.expectNoPermissionAsked();
    });

    testWidgets('Log manually opens the editor with the picked photo',
        (tester) async {
      final w = _World(
          outcome: const PhotoOutcome(PhotoOutcomeKind.skipped, 'not food'));
      await _open(
          tester,
          AddPhotoScreen(
              services: w.services,
              systemPicker: FakeSystemPicker(replies: [_ok()])));
      await tester.tap(find.byKey(const Key('logManuallyButton')));
      await tester.pumpAndSettle();
      final editor =
          tester.widget<MealEditorScreen>(find.byType(MealEditorScreen));
      expect(identical(editor.fromPhoto?.bytes, _bytes), isTrue,
          reason: 'the manual log keeps the picked photo attached');
    });

    testWidgets('a photo too big or unreadable says so and stays',
        (tester) async {
      for (final pick in const [
        SystemPick(SystemPickStatus.ok, tooBig: 1),
        SystemPick(SystemPickStatus.ok, failed: 1),
      ]) {
        final w = _World();
        await _open(
            tester,
            AddPhotoScreen(
                services: w.services,
                systemPicker: FakeSystemPicker(replies: [pick])));
        expect(find.text('That photo could not be read (too large or '
                'removed).'),
            findsOneWidget);
        expect(_screen, findsOneWidget);
        expect(find.byKey(const Key('addChooseAllPhotos')), findsOneWidget);
        expect(w.processed, isEmpty);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a picker that cannot open says so, without asking for the '
        'library or the "isn\'t allowed" dead end', (tester) async {
      final w = _World();
      await _open(
          tester,
          AddPhotoScreen(
              services: w.services,
              systemPicker: FakeSystemPicker(
                  replies: [const SystemPick(SystemPickStatus.unavailable)])));
      expect(find.byKey(const Key('addPickerUnavailable')), findsOneWidget);
      expect(find.byKey(const Key('photoPermissionDenied')), findsNothing);
      expect(_screen, findsOneWidget);
      w.expectNoPermissionAsked();
    });

    testWidgets('a pick still open ignores a second tap', (tester) async {
      final w = _World(
          outcome: const PhotoOutcome(PhotoOutcomeKind.skipped, 'not food'));
      final system = FakeSystemPicker(replies: [_ok()]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      system.held = Completer<SystemPick>();
      final again = find.byKey(const Key('addChooseAllPhotos'));
      await tester.tap(again);
      await tester.pump();
      await tester.tap(again);
      await tester.pump();
      expect(system.picks, [1, 1], reason: 'one pick open at a time');
      system.held!.complete(const SystemPick(SystemPickStatus.cancelled));
      await tester.pumpAndSettle();
      expect(_screen, findsOneWidget,
          reason: 'a cancel from the button is not leaving the screen');
    });
  });

  // The picker page at accessibility sizes: the note, the button and the
  // tip scroll instead of overflowing, and the button can still be reached.
  for (final (size, scale) in const [
    (Size(320, 568), 53 / 17), // AX5 on an SE (1st gen)
    (Size(375, 667), 2.35), // AX3 on an SE
  ]) {
    testWidgets(
        'at ${scale.toStringAsFixed(2)}x on ${size.width.toInt()} pt the '
        'picker page fits and its button is reachable', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final w = _World(
          outcome: const PhotoOutcome(PhotoOutcomeKind.skipped, 'not food'));
      final system = FakeSystemPicker(replies: [_ok()]);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: AddPhotoScreen(services: w.services, systemPicker: system),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final button = find.byKey(const Key('addChooseAllPhotos'));
      await tester.scrollUntilVisible(button, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(system.picks, [1, 1]);
    });
  }

  group('full photo access (the GitHub APK, once granted)', () {
    testWidgets('the grid as before, plus a row that opens the picker',
        (tester) async {
      final w = _World(full: true);
      w.picker.photos = [_gridPhoto('a0'), _gridPhoto('a1')];
      final system = FakeSystemPicker(broad: true, replies: [_ok()]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));

      expect(system.picks, isEmpty, reason: 'the grid first');
      expect(find.byKey(const Key('recentPhoto1')), findsOneWidget);
      expect(find.byKey(const Key('addPhotosLimited')), findsNothing);
      expect(w.permissionRequests, 0,
          reason: 'full access is read, never asked for');

      await tester.tap(find.byKey(const Key('addChooseAllPhotos')));
      await tester.pumpAndSettle();
      expect(system.picks, [1]);
      expect(w.processed.single.assetId, '');
      expect(w.processed.single.deliberate, isTrue);
    });

    testWidgets('a grid photo is still read from the library', (tester) async {
      final w = _World(full: true);
      w.picker.photos = [_gridPhoto('a0')];
      final system = FakeSystemPicker(broad: true);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));
      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();
      expect(w.picker.loadedOriginals, ['a0']);
      expect(system.picks, isEmpty);
      expect(w.processed.single.assetId, 'a0');
    });

    testWidgets('a picker that cannot open from the row says so; the grid '
        'stays', (tester) async {
      final w = _World(full: true);
      w.picker.photos = [_gridPhoto('a0')];
      final system = FakeSystemPicker(
          broad: true,
          replies: [const SystemPick(SystemPickStatus.unavailable)]);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));
      await tester.tap(find.byKey(const Key('addChooseAllPhotos')));
      await tester.pumpAndSettle();
      expect(
          find.text("The photo picker can't open on this phone. You can still "
              'share a photo to Chopstats from your gallery app.'),
          findsOneWidget,
          reason: 'it did nothing at all');
      expect(find.byKey(const Key('recentPhoto0')), findsOneWidget);
    });

    testWidgets('cancelling the picker from the row keeps the grid',
        (tester) async {
      final w = _World(full: true);
      w.picker.photos = [_gridPhoto('a0')];
      final system = FakeSystemPicker(broad: true);
      await _open(tester,
          AddPhotoScreen(services: w.services, systemPicker: system));
      await tester.tap(find.byKey(const Key('addChooseAllPhotos')));
      await tester.pumpAndSettle();
      expect(system.picks, [1]);
      expect(_screen, findsOneWidget);
      expect(find.byKey(const Key('recentPhoto0')), findsOneWidget);
    });
  });

  testWidgets('a build without the native picker keeps the old grid flow',
      (tester) async {
    // MissingPluginException: the method is not there (a build from
    // before the native half). The screen behaves as it did.
    final w = _World(grantOnRequest: true);
    w.picker.photos = [_gridPhoto('a0')];
    final system = FakeSystemPicker(
        replies: [const SystemPick(SystemPickStatus.missing)]);
    await _open(tester,
        AddPhotoScreen(services: w.services, systemPicker: system));
    expect(system.picks, [1]);
    expect(w.permissionRequests, 1, reason: 'the old flow asks, as before');
    expect(find.byKey(const Key('recentPhoto0')), findsOneWidget);
    expect(find.byKey(const Key('addChooseAllPhotos')), findsNothing);
  });

  testWidgets('openAddFlow hands both photo screens the platform picker',
      (tester) async {
    final system = FakeSystemPicker(broad: true);
    debugSystemPhotoPicker = () => system;
    addTearDown(() => debugSystemPhotoPicker = null);
    final w = _World(full: true);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const Key('fab'),
            onPressed: () => openAddFlow(context, w.services),
            child: const Text('+'),
          ),
        ),
      ),
    ));
    for (final (row, type) in [
      ('addFromPhotos', AddPhotoScreen),
      ('addLeftover', LeftoverScreen),
    ]) {
      await tester.tap(find.byKey(const Key('fab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(row)));
      await tester.pumpAndSettle();
      final screen = tester.widget(find.byType(type));
      final passed = switch (screen) {
        AddPhotoScreen(:final systemPicker) => systemPicker,
        LeftoverScreen(:final systemPicker) => systemPicker,
        _ => null,
      };
      expect(identical(passed, system), isTrue, reason: row);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });
}
