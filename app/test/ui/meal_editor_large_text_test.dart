// The meal editor at enlarged text (run-7 E2E-2, the A10 note). An
// outlined field draws its floated label centred on its top border at
// 0.75x, so half the label sits ABOVE the field's box: about 26 pt at AX5.
// With 8-pt gaps the labels (热量 / 蛋白质 / 碳水 …) covered the 总计 header
// and the field above them, the first one was clipped under the app bar,
// and the one-line description showed only 'Pan-fried du'.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

const _desc = 'Pan-fried dumplings with millet porridge';

Meal _meal() => Meal(
  id: 1,
  date: '2026-10-31',
  time: '08:05 AM',
  timestamp: '2026-10-31T08:05:00.000',
  source: 'app_photo',
  imageHash: 'h1',
  analysis: const {
    'is_food': true,
    'meal_description': _desc,
    'total_calories': 640,
    'total_protein_g': 23,
    'total_carbs_g': 77,
    'total_fat_g': 26,
    'food_items': [
      {
        'name': 'Pan-fried pork dumplings (8 pieces)',
        'estimated_calories': 480,
        'protein_g': 18,
        'carbs_g': 52,
        'fat_g': 22,
      },
      {
        'name': 'Millet porridge',
        'estimated_calories': 160,
        'protein_g': 5,
        'carbs_g': 25,
        'fat_g': 4,
      },
    ],
  },
);

Rect _global(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Each outlined field's box and the global rect of its floated label.
List<({Rect field, Rect label, String text})> _fields(WidgetTester tester) {
  final out = <({Rect field, Rect label, String text})>[];
  for (final e in find.byType(InputDecorator).evaluate()) {
    final text = (e.widget as InputDecorator).decoration.labelText;
    if (text == null) continue;
    final label = find
        .descendant(
          of: find.byElementPredicate((x) => identical(x, e)),
          matching: find.text(text),
        )
        .evaluate()
        .single;
    out.add((
      field: _global(e.renderObject! as RenderBox),
      label: _global(label.renderObject! as RenderBox),
      text: text,
    ));
  }
  return out;
}

void main() {
  setUpAll(loadIphoneFonts);

  for (final (locale, scale) in [
    (const Locale('zh'), 53 / 17), // AX5
    (const Locale('en'), 53 / 17),
    (const Locale('en'), 1.35), // xxxLarge, the largest standard size
  ]) {
    testWidgets('${locale.languageCode} at ${scale.toStringAsFixed(2)}x: no '
        'floated label covers the header or field above it', (tester) async {
      final dao = FakeDao()..seed(_meal());
      // Tall enough that every row is built and on screen.
      await pumpApp(
        tester,
        MealEditorScreen(dao: dao, meal: dao.meals.first),
        size: const Size(375, 4000),
        locale: locale,
        scale: scale,
      );
      final fields = _fields(tester);
      expect(
        fields.length,
        greaterThanOrEqualTo(10),
        reason: 'description, totals and two item rows',
      );
      final obstacles = <Rect>[
        for (final f in fields) f.field,
        for (final k in ['editorDateButton', 'editorTimeButton'])
          tester.getRect(find.byKey(Key(k))),
        for (final e in find.byType(Text).evaluate())
          // Headers and the live total; field labels, button labels and
          // the app bar are not obstacles.
          if (e.findAncestorWidgetOfExactType<InputDecorator>() == null &&
              e.findAncestorWidgetOfExactType<ButtonStyleButton>() == null &&
              e.findAncestorWidgetOfExactType<AppBar>() == null &&
              e.findAncestorWidgetOfExactType<FloatingActionButton>() == null)
            _global(e.renderObject! as RenderBox),
      ];
      for (final f in fields) {
        for (final o in obstacles) {
          if (o == f.field) continue;
          expect(
            f.label.overlaps(o.deflate(0.5)),
            isFalse,
            reason: "'${f.text}' label ${f.label} covers $o",
          );
        }
      }
    });
  }

  testWidgets('zh at AX5 on an SE: the first label clears the app bar', (
    tester,
  ) async {
    final dao = FakeDao()..seed(_meal());
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(375, 667),
      locale: const Locale('zh'),
      scale: 53 / 17,
      padding: const EdgeInsets.only(top: 20),
    );
    final first = _fields(tester).first;
    final viewport = _global(
      tester.renderObject<RenderBox>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Viewport),
        ),
      ),
    );
    expect(
      first.label.top,
      greaterThanOrEqualTo(viewport.top),
      reason: 'the floated label is not clipped by the list',
    );
  });

  RenderEditable editableFor(WidgetTester tester, String text) => tester
      .allRenderObjects
      .whereType<RenderEditable>()
      .firstWhere((r) => r.text?.toPlainText() == text);

  testWidgets('at AX5 the description and item names wrap instead of '
      'cutting off', (tester) async {
    final dao = FakeDao()..seed(_meal());
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(375, 4000),
      locale: const Locale('zh'),
      scale: 53 / 17,
    );
    for (final text in [_desc, 'Pan-fried pork dumplings (8 pieces)']) {
      final editable = editableFor(tester, text);
      expect(
        editable.size.height,
        greaterThan(editable.preferredLineHeight * 1.5),
        reason: '"$text" shows on more than one line',
      );
    }
    final field = tester.widget<TextField>(
      find.byKey(const Key('editorDescription')),
    );
    expect(
      field.textInputAction,
      TextInputAction.done,
      reason: 'Return still finishes; the text stays one paragraph',
    );
  });

  testWidgets('at the default size the fields are one line, 8 pt apart, as '
      'before', (tester) async {
    final dao = FakeDao()..seed(_meal());
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(390, 4000),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('editorDescription')))
          .maxLines,
      1,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('editorProtein'))).dy -
          tester.getBottomLeft(find.byKey(const Key('editorCalories'))).dy,
      8,
    );
  });
}
