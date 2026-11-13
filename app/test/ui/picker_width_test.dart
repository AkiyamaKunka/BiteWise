// Android push (ui lane, 2026-11-13): the date picker's text-scale clamp
// (kPickerMaxTextScale = 1.6) was tuned on 375-pt iPhones. Android's
// largest Display size takes a phone to 320 dp, where at font scale 2.0
// the selected '13' drew as '1' and the month as 'Novembe…' (UX run
// screenshots 46 and 46zoom). The date dialog's clamp now follows the
// screen width; the time picker, fine at those settings, keeps 1.6.
//
// Measured with Roboto, Android's own font, from the Flutter SDK's
// material_fonts (the test font's square glyphs are wider than any real
// font: without Roboto the checks run on it, which is stricter).
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/theme/app_theme.dart';
import 'package:calorie_tracker/ui/widgets/pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

const _roboto = 'RobotoTest';

/// Roboto's regular, medium and bold faces (the picker's header and
/// selected day are medium), or empty without the SDK's material_fonts.
List<String> _robotoPaths() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return const [];
  final paths = [
    for (final face in const ['Regular', 'Medium', 'Bold'])
      '$root/bin/cache/artifacts/material_fonts/Roboto-$face.ttf',
  ];
  return paths.every((p) => File(p).existsSync()) ? paths : const [];
}

final bool _haveRoboto = _robotoPaths().isNotEmpty;

Future<void> _pump(WidgetTester tester, Size size, double scale,
    {Locale locale = const Locale('en'),
    required Future<void> Function(BuildContext) open}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    theme: AppTheme.build(Brightness.light,
        cjk: locale.languageCode == 'zh',
        debugFontFamily: _haveRoboto ? _roboto : null),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const Key('open'),
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

Future<void> _openDate(BuildContext context) => showAppDatePicker(
      context: context,
      initialDate: DateTime(2026, 11, 13),
      firstDate: DateTime(2020),
      lastDate: DateTime(2026, 11, 14),
      currentDate: DateTime(2026, 11, 13),
    );

/// Every day label of the shown month is laid out on one line: nothing
/// wrapped (a wrapped '13' showed only its '1' in the round cell).
void _expectDaysWhole(WidgetTester tester) {
  final grid = find.byType(CalendarDatePicker);
  for (var day = 1; day <= 30; day++) {
    final label = find.descendant(of: grid, matching: find.text('$day'));
    if (label.evaluate().isEmpty) continue; // a header digit elsewhere
    for (final element in label.evaluate()) {
      final paragraph = _firstParagraph(element.renderObject!);
      final needs = paragraph.getMaxIntrinsicWidth(double.infinity);
      expect(paragraph.size.width, greaterThanOrEqualTo(needs - 0.01),
          reason: 'day $day needs ${needs.toStringAsFixed(1)} px but got '
              '${paragraph.size.width.toStringAsFixed(1)}: it wraps');
    }
  }
}

RenderParagraph _firstParagraph(RenderObject r) => _paragraphIn(r)!;

RenderParagraph? _paragraphIn(RenderObject r) {
  if (r is RenderParagraph) return r;
  RenderParagraph? found;
  r.visitChildren((c) => found ??= _paragraphIn(c));
  return found;
}

/// The month header ('November 2026' / '2026年11月') is not cut short.
void _expectMonthWhole(WidgetTester tester, String month) {
  final header = find.text(month);
  expect(header, findsWidgets, reason: 'the month header shows');
  for (final element in header.evaluate()) {
    final paragraph = _firstParagraph(element.renderObject!);
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: '"$month" is ellipsized');
  }
}

void main() {
  setUpAll(() async {
    if (!_haveRoboto) return;
    final loader = FontLoader(_roboto);
    for (final path in _robotoPaths()) {
      loader.addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    }
    await loader.load();
  });

  group('the date picker clamp follows the screen width', () {
    test('1.6 at 375 dp and wider, 0.01 less per dp below, never under 1',
        () {
      expect(datePickerMaxTextScale(430), kPickerMaxTextScale);
      expect(datePickerMaxTextScale(375), kPickerMaxTextScale);
      expect(datePickerMaxTextScale(360), closeTo(1.45, 1e-9));
      expect(datePickerMaxTextScale(320), closeTo(1.05, 1e-9));
      expect(datePickerMaxTextScale(280), 1.0);
    });

    for (final (lang, month) in const [
      ('en', 'November 2026'),
      ('zh', '2026年11月'),
    ]) {
      for (final width in const [320.0, 340.0, 350.0, 360.0, 368.0, 375.0, 411.0]) {
        testWidgets('$lang at $width dp, font 2.0: two-digit days and the '
            'month are whole', (tester) async {
          await _pump(tester, Size(width, 640), 2.0,
              locale: Locale(lang), open: _openDate);
          final grid = tester.element(find.byType(CalendarDatePicker));
          expect(MediaQuery.textScalerOf(grid).scale(1),
              datePickerMaxTextScale(width));
          _expectDaysWhole(tester);
          _expectMonthWhole(tester, month);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('below the clamp nothing changes at 360 dp', (tester) async {
      await _pump(tester, const Size(360, 640), 1.3, open: _openDate);
      expect(
          MediaQuery.textScalerOf(
                  tester.element(find.byType(CalendarDatePicker)))
              .scale(1),
          closeTo(1.3, 1e-9));
    });

    testWidgets('the default size is never shrunk, even at 280 dp',
        (tester) async {
      await _pump(tester, const Size(280, 640), 1.0, open: _openDate);
      expect(
          MediaQuery.textScalerOf(
                  tester.element(find.byType(CalendarDatePicker)))
              .scale(1),
          1.0);
    });
  });

  testWidgets('the time picker keeps its 1.6 clamp at 320 dp', (tester) async {
    await _pump(tester, const Size(320, 640), 2.0,
        open: (c) => showAppTimePicker(
            context: c, initialTime: const TimeOfDay(hour: 13, minute: 5)));
    final dialog = tester.element(find.byType(TimePickerDialog));
    expect(MediaQuery.textScalerOf(dialog).scale(1), kPickerMaxTextScale);
    expect(tester.takeException(), isNull);
  });
}
