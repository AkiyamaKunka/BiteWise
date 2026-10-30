// The "Meta glasses" badge (design G2a): a meal whose stored
// analysis.capture.device is 'meta_glasses' says so on its Today card and
// in the meal editor — 'Meta glasses' / 'Meta 眼镜', a drawn glasses glyph
// beside the words. Nothing else shows it, a hostile stored shape renders
// without it, and the editor's own saves keep the capture honest.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/widgets/glasses_badge.dart';
import 'package:calorie_tracker/ui/widgets/meal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _glassesCapture = {
  'device': 'meta_glasses',
  'signal': 'filename',
  'has_gps': false,
  'shutter_key': '0123456789abcdef',
};

Meal _meal(Map<String, dynamic> analysis, {int id = 1}) => Meal(
  id: id,
  date: '2026-10-08',
  time: '12:30 PM',
  timestamp: '2026-10-08T12:31:00.000',
  source: MealSource.appWatch,
  imageHash: 'abc',
  analysis: analysis,
);

Map<String, dynamic> _food({Object? capture, String name = 'Burrito bowl'}) => {
  'is_food': true,
  'meal_description': name,
  'total_calories': 720,
  'total_protein_g': 32,
  'total_carbs_g': 80,
  'total_fat_g': 25,
  'food_items': [
    {'name': name, 'estimated_calories': 720},
  ],
  'capture': ?capture,
};

Widget _host(Locale locale, Widget child, {double textScale = 1}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: inner!,
      ),
      home: child,
    );

void main() {
  group('meal card', () {
    for (final (locale, label) in [
      (const Locale('en'), 'Meta glasses'),
      (const Locale('zh'), 'Meta 眼镜'),
    ]) {
      testWidgets('${locale.languageCode}: a glasses meal reads "$label"', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            locale,
            Scaffold(
              body: MealCard(meal: _meal(_food(capture: _glassesCapture))),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('metaGlassesBadge')), findsOneWidget);
        expect(find.text(label), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('metaGlassesBadge')),
            matching: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is GlassesGlyphPainter,
            ),
          ),
          findsOneWidget,
          reason: 'the glyph beside the words',
        );
        // The screen reader hears the words, once.
        expect(find.bySemanticsLabel(label), findsOneWidget);
      });
    }

    testWidgets('no badge for a camera meal, a meal without capture, or any '
        'hostile stored shape', (tester) async {
      for (final capture in <Object?>[
        null,
        {'has_gps': true, 'shutter_key': '0123456789abcdef'},
        'meta_glasses',
        ['meta_glasses'],
        {'device': 'Meta_Glasses'},
        {'device': 7},
        {'signal': 'filename'},
      ]) {
        await tester.pumpWidget(
          _host(
            const Locale('en'),
            Scaffold(
              body: MealCard(meal: _meal(_food(capture: capture))),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('metaGlassesBadge')),
          findsNothing,
          reason: '$capture',
        );
        expect(
          find.text('Burrito bowl'),
          findsWidgets,
          reason: 'the card still renders',
        );
        expect(tester.takeException(), isNull);
      }
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('${scale}x text on a 320-pt phone: the badge wraps, '
          'nothing overflows', (tester) async {
        tester.view.physicalSize = const Size(320, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final locale in const [Locale('en'), Locale('zh')]) {
          await tester.pumpWidget(
            _host(
              locale,
              Scaffold(
                body: ListView(
                  children: [
                    MealCard(
                      meal: _meal(
                        _food(
                          capture: _glassesCapture,
                          name: '墨西哥卷饼碗配鸡肉、黑豆和莎莎酱',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$locale');
          final badge = tester.getRect(
            find.byKey(const Key('metaGlassesBadge')),
          );
          expect(badge.right, lessThanOrEqualTo(320), reason: '$locale');
        }
      });
    }
  });

  group('meal editor', () {
    DateTime clock() => DateTime(2026, 10, 8, 19, 5);

    void tall(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> fillAndSave(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('editorDescription')),
        'Noodles',
      );
      await tester.enterText(find.byKey(const Key('editorCalories')), '600');
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
    }

    for (final (locale, label) in [
      (const Locale('en'), 'Meta glasses'),
      (const Locale('zh'), 'Meta 眼镜'),
    ]) {
      testWidgets('${locale.languageCode}: editing a glasses meal shows '
          '"$label"; its save keeps the capture', (tester) async {
        tall(tester);
        final dao = FakeDao();
        final meal = _meal(_food(capture: _glassesCapture), id: 5);
        dao.meals.add(meal);
        await tester.pumpWidget(
          _host(locale, MealEditorScreen(dao: dao, meal: meal, now: clock)),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('editorMetaGlassesBadge')), findsOneWidget);
        expect(find.text(label), findsOneWidget);
        await tester.enterText(find.byKey(const Key('editorCalories')), '650');
        await tester.tap(find.byKey(const Key('saveMealButton')));
        await tester.pumpAndSettle();
        expect(dao.fieldUpdates.single.$2!['capture'], _glassesCapture);
      });
    }

    testWidgets('a camera meal shows no badge', (tester) async {
      tall(tester);
      final meal = _meal(_food(capture: {'has_gps': true}));
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          MealEditorScreen(dao: FakeDao(), meal: meal, now: clock),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorMetaGlassesBadge')), findsNothing);
    });

    testWidgets('logging a glasses photo by hand: the badge, and the saved '
        "meal keeps the intake's capture", (tester) async {
      tall(tester);
      final dao = FakeDao();
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          MealEditorScreen(
            dao: dao,
            fromPhoto: IntakePhoto(
              Uint8List.fromList([1, 2, 3]),
              'asset-9',
              'photo-9_singular_display_fullPicture.HEIC',
              deliberate: true,
              capture: const CaptureMeta(
                device: CaptureDevice.metaGlasses,
                strength: CaptureStrength.strong,
                signal: CaptureSignal.filename,
              ),
            ),
            now: clock,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorMetaGlassesBadge')), findsOneWidget);
      await fillAndSave(tester);
      expect(dao.saved.single.analysis['capture'], {
        'device': 'meta_glasses',
        'signal': 'filename',
        'has_gps': false,
      });
    });

    testWidgets('a photo the intake did not read stores none', (tester) async {
      tall(tester);
      final dao = FakeDao();
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          MealEditorScreen(
            dao: dao,
            fromPhoto: IntakePhoto(
              Uint8List.fromList([1, 2, 3]),
              'asset-9',
              'IMG_9.HEIC',
              deliberate: true,
            ),
            now: clock,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorMetaGlassesBadge')), findsNothing);
      await fillAndSave(tester);
      expect(dao.saved.single.analysis.containsKey('capture'), isFalse);
    });

    testWidgets("a text preview whose model reply carries a 'capture' stores "
        'none and shows no badge', (tester) async {
      tall(tester);
      final textDao = FakeDao();
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          MealEditorScreen(
            dao: textDao,
            initialAnalysis: _food(capture: _glassesCapture),
            newMealSource: MealSource.manualText,
            now: clock,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorMetaGlassesBadge')), findsNothing);
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(textDao.saved.single.analysis.containsKey('capture'), isFalse);
    });
  });

  testWidgets('3.1x text in a narrow space: the words give way, the badge '
      'never overflows', (tester) async {
    for (final locale in const [Locale('en'), Locale('zh')]) {
      await tester.pumpWidget(
        _host(
          locale,
          const Scaffold(
            body: Center(
              child: SizedBox(width: 120, child: MetaGlassesBadge()),
            ),
          ),
          textScale: 3.1,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$locale');
      expect(
        tester.getSize(find.byType(MetaGlassesBadge)).width,
        lessThanOrEqualTo(120),
      );
    }
  });

  test('the glyph repaints only for a new colour', () {
    const a = GlassesGlyphPainter(Colors.black);
    expect(a.shouldRepaint(const GlassesGlyphPainter(Colors.black)), isFalse);
    expect(a.shouldRepaint(const GlassesGlyphPainter(Colors.white)), isTrue);
  });
}
