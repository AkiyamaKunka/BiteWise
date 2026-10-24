// The flag-gated "Glasses session" screen (feat/meta-dat prototype) over a
// mocked native channel: boot configures (and pairs the mock glasses when
// asked), Connect hands over to Meta AI and its callback comes back
// through the app's link stream, Start asks for the camera permission
// first, every photo from the glasses goes through the pipeline as
// app_glasses intake, the shutter button is arbitrated, and leaving the
// screen ends the session.
import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/services/glasses/glasses_intake.dart';
import 'package:calorie_tracker/services/glasses/meta_dat_channel.dart';
import 'package:calorie_tracker/services/glasses/meta_dat_flags.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/glasses_session_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/fakes.dart';
import 'fake_meta_dat_native.dart';

class _Harness {
  final native = FakeMetaDatNative();
  final links = StreamController<Uri>.broadcast();
  final processed = <IntakePhoto>[];
  final announced = <PhotoOutcome>[];
  Completer<PhotoOutcome>? gate;
  PhotoOutcome next = const PhotoOutcome(PhotoOutcomeKind.saved, 'Logged',
      detail: 'Ramen', mealName: 'Ramen', kcal: '650');

  Future<PhotoOutcome> process(IntakePhoto p) async {
    processed.add(p);
    final g = gate;
    if (g != null) return g.future;
    return next;
  }

  Widget app({bool useMock = false, Locale? locale, Uri? initial}) =>
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => GlassesSessionScreen(
                    processPhoto: process,
                    announceOutcome: announced.add,
                    links: links.stream,
                    initialLink: () async => initial,
                    useMock: useMock,
                    now: () => DateTime(2026, 10, 23, 12, 31),
                  ),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester,
      {bool useMock = false, Locale? locale, Uri? initial}) async {
    await tester
        .pumpWidget(app(useMock: useMock, locale: locale, initial: initial));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    native.dispose();
    await links.close();
  }
}

Finder _row(String key) => find.byKey(Key(key));

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<Semantics>(find.descendant(
            of: _row(key), matching: find.byType(Semantics)).first)
        .properties
        .button ==
    true;

void main() {
  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  testWidgets('boot configures once; nothing else touches the glasses',
      (tester) async {
    await h.open(tester);
    expect(h.native.methods, ['status', 'configure']);
    expect(find.text('Meta glasses (experimental)'), findsOneWidget);
    expect(find.text('Not linked'), findsOneWidget);
    expect(_row('glassesConnect'), findsOneWidget);
    // Not registered yet: Start is shown but disabled, no capture.
    expect(_enabled(tester, 'glassesStart'), isFalse);
    expect(_enabled(tester, 'glassesCapture'), isFalse);
    expect(_row('glassesMockPress'), findsNothing);
  });

  testWidgets('Connect → Meta AI → callback link → connected', (tester) async {
    await h.open(tester);
    await tester.tap(_row('glassesConnect'));
    await tester.pumpAndSettle();
    expect(h.native.methods.last, 'status');
    expect(h.native.methods, contains('register'));

    // Meta AI answers through the app's link stream. A setup link on the
    // same stream is not ours and is left alone.
    h.native.registration = 'registered';
    h.links.add(Uri.parse('bitewise://setup?server=https://x.example&key=k'));
    await tester.pumpAndSettle();
    expect(h.native.methods, isNot(contains('handleUrl')));
    final callback =
        Uri.parse('bitewise-glasses://cb?metaWearablesAction=register');
    h.links.add(callback);
    await tester.pumpAndSettle();
    final handled =
        h.native.calls.where((c) => c.method == 'handleUrl').single;
    expect(handled.arguments, {'url': callback.toString()});
    expect(find.text('Linked'), findsOneWidget);
    expect(_row('glassesConnect'), findsNothing);
    // Linked, but the glasses are not picked yet: still no session.
    expect(find.text('Not connected'), findsOneWidget);
    expect(_enabled(tester, 'glassesStart'), isFalse);
    await h.native.push({'type': 'activeDevice', 'active': true});
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
    expect(_enabled(tester, 'glassesStart'), isTrue);
  });

  testWidgets('an event during boot is not lost (the device picked late)',
      (tester) async {
    h.native.registration = 'registered';
    h.native.activateAfterConfigure = true;
    await h.open(tester);
    expect(find.text('Ready'), findsOneWidget);
    expect(_enabled(tester, 'glassesStart'), isTrue);
  });

  testWidgets('a cold start from the callback link handles it at boot',
      (tester) async {
    h.native.registration = 'registered';
    await h.open(tester,
        initial: Uri.parse('bitewise-glasses://cb?metaWearablesAction=perm'));
    expect(h.native.methods,
        ['status', 'configure', 'handleUrl', 'status']);

    // Opened again later in the same process: the launch link is spent.
    await tester.pageBack();
    await tester.pumpAndSettle();
    h.native.calls.clear();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(h.native.methods, isNot(contains('handleUrl')));
  });

  testWidgets('Start asks for the camera first; a denial starts nothing',
      (tester) async {
    h.native.registration = 'registered';
    h.native.activeDevice = true;
    h.native.permission = 'denied';
    await h.open(tester);
    await tester.tap(_row('glassesStart'));
    await tester.pumpAndSettle();
    expect(h.native.methods, isNot(contains('startSession')));
    expect(find.textContaining('Allow it in the Meta AI app'), findsOneWidget);

    h.native.permission = 'granted';
    await tester.tap(_row('glassesStart'));
    await tester.pumpAndSettle();
    expect(h.native.methods.sublist(h.native.methods.length - 2),
        ['requestCameraPermission', 'startSession']);
  });

  testWidgets(
      'a session photo goes through the pipeline as app_glasses intake',
      (tester) async {
    h.native.registration = 'registered';
    await h.open(tester);
    await h.native.push({'type': 'session', 'state': 'started'});
    await h.native.push({'type': 'camera', 'state': 'started'});
    await tester.pumpAndSettle();
    expect(find.text('Running'), findsOneWidget);
    expect(_enabled(tester, 'glassesCapture'), isTrue);

    await tester.tap(_row('glassesCapture'));
    await tester.pump();
    expect(h.native.calls.last.method, 'capture');
    expect(find.text('Taking photo…'), findsOneWidget);
    expect(_enabled(tester, 'glassesCapture'), isFalse);

    h.gate = Completer<PhotoOutcome>();
    await h.native.push({'type': 'progress', 'fraction': 0.4});
    await tester.pump();
    expect(_row('glassesProgress'), findsOneWidget);
    final at = DateTime(2026, 10, 23, 12, 30, 5);
    await h.native.photo(fakeJpeg(), at);
    await tester.pump();
    expect(find.text('Analyzing…'), findsOneWidget);
    expect(_row('glassesProgress'), findsNothing);
    final intake = h.processed.single;
    expect(intake, isA<GlassesIntakePhoto>());
    expect(intake.source, MealSource.appGlasses);
    expect(intake.deliberate, isTrue);
    expect(intake.bytes, fakeJpeg());
    expect(intake.capturedAt, at);

    h.gate!.complete(h.next);
    await tester.pumpAndSettle();
    expect(find.text('Analyzing…'), findsNothing);
    expect(find.text(AppLocalizationsEn().outcomeSaved), findsOneWidget);
    expect(find.text('Take a photo now'), findsOneWidget);
  });

  testWidgets('a shutter press with no photo of its own asks for one',
      (tester) async {
    h.native.registration = 'registered';
    await h.open(tester);
    await h.native.push({'type': 'session', 'state': 'started'});
    await h.native.push({'type': 'camera', 'state': 'started'});
    await tester.pumpAndSettle();
    await h.native.push({'type': 'button', 'press': 'shortPress'});
    await tester.pump();
    expect(find.textContaining('Shutter pressed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(h.native.calls.where((c) => c.method == 'capture'), hasLength(1));

    // The glasses' own shot arriving cancels the next one.
    await h.native.push({'type': 'button', 'press': 'shortPress'});
    await h.native.push({'type': 'progress', 'fraction': 0.1});
    await tester.pump(const Duration(seconds: 4));
    expect(h.native.calls.where((c) => c.method == 'capture'), hasLength(1));
  });

  testWidgets('failures are worded by code, never by SDK text',
      (tester) async {
    h.native.registration = 'registered';
    await h.open(tester);
    await h.native.push({
      'type': 'error',
      'code': 'capture_timeout',
      'message': 'SDK internals that must not be shown'
    });
    await tester.pump();
    expect(find.text('No photo arrived from the glasses. Try again.'),
        findsOneWidget);
    expect(find.textContaining('SDK internals'), findsNothing);
  });

  testWidgets('leaving the screen ends the session; a late verdict is said',
      (tester) async {
    h.native.registration = 'registered';
    await h.open(tester);
    await h.native.push({'type': 'session', 'state': 'started'});
    await tester.pumpAndSettle();
    h.gate = Completer<PhotoOutcome>();
    await h.native.photo(fakeJpeg(), DateTime(2026, 10, 23, 12, 30));
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(h.native.methods.last, 'stopSession');

    // A not-food verdict landing after the screen closed reaches the
    // app's snackbar sink (a save announces itself in the pipeline).
    h.gate!.complete(const PhotoOutcome(PhotoOutcomeKind.skipped, 'Not food'));
    await tester.pumpAndSettle();
    expect(h.announced.single.kind, PhotoOutcomeKind.skipped);
  });

  testWidgets('a session asked for but not yet reported is still ended',
      (tester) async {
    h.native.registration = 'registered';
    h.native.activeDevice = true;
    await h.open(tester);
    await tester.tap(_row('glassesStart'));
    await tester.pumpAndSettle();
    expect(h.native.methods.last, 'startSession');
    // No 'starting' event has come back yet.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(h.native.methods.last, 'stopSession');
  });

  testWidgets('the app leaving the foreground ends a live session',
      (tester) async {
    h.native.registration = 'registered';
    await h.open(tester);
    await h.native.push({'type': 'session', 'state': 'started'});
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(h.native.methods.where((m) => m == 'stopSession'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('mock mode pairs the simulated glasses and offers the shutter',
      (tester) async {
    await h.open(tester, useMock: true);
    expect(h.native.methods, ['status', 'configure', 'enableMock', 'status']);
    expect(find.text('Simulated'), findsOneWidget);
    await h.native.push({'type': 'session', 'state': 'started'});
    await h.native.push({'type': 'camera', 'state': 'started'});
    await tester.pumpAndSettle();
    await tester.tap(_row('glassesMockPress'));
    await tester.pumpAndSettle();
    expect(h.native.calls.last.method, 'mockCapturePress');
    expect(h.native.calls.last.arguments, {'press': 'shortPress'});
  });

  testWidgets('no plugin: the screen says so and offers nothing',
      (tester) async {
    h.native.noPlugin = true;
    await h.open(tester);
    expect(find.text('This build has no Meta glasses support.'),
        findsOneWidget);
    expect(_row('glassesStart'), findsNothing);
  });

  testWidgets('Chinese UI', (tester) async {
    h.native.registration = 'registered';
    h.native.activeDevice = true;
    await h.open(tester, locale: const Locale('zh'));
    expect(find.text('Meta 眼镜（实验）'), findsOneWidget);
    expect(find.text('已关联'), findsOneWidget);
    expect(find.text('已就绪'), findsOneWidget);
    expect(find.text('开始拍摄模式'), findsOneWidget);
  });

  group('add sheet entry', () {
    test('only with the flag, only on an iPhone', () {
      expect(metaDatEntryVisible(TargetPlatform.iOS, enabled: false), isFalse);
      expect(metaDatEntryVisible(TargetPlatform.android, enabled: true),
          isFalse);
      expect(metaDatEntryVisible(TargetPlatform.iOS, enabled: true), isTrue);
      // The default build never has it.
      expect(kMetaDatEnabled, isFalse);
      expect(kMetaDatMock, isFalse);
    });

    testWidgets('a default build does not offer the glasses session',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final services = makeServices();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => openAddFlow(context, services),
              child: const Text('add'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('addFromPhotos')), findsOneWidget);
      expect(find.byKey(const Key('addGlassesSession')),
          kMetaDatEnabled ? findsOneWidget : findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  test('the fixtures are what they claim', () {
    expect(sniffPhotoFormat(fakeJpeg()), MetaDatPhotoFormat.jpeg);
    expect(sniffPhotoFormat(Uint8List.fromList(fakeHeic())),
        MetaDatPhotoFormat.heic);
  });
}
