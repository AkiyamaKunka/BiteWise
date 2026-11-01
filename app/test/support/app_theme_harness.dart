/// Widget-test harness for the run-7 design system: the app's REAL theme
/// (AppTheme), optionally measured with the iPhone's own system fonts.
///
/// row_fit_layout_test and large_text_overflow_test build their own bare
/// ThemeData, so they cannot catch a regression from the iOS type scale.
/// New layout cases use this instead (in new test files).
///
/// The SF + Hiragino glyphs exist on macOS only: [haveIphoneFonts] is
/// false elsewhere and glyph-dependent checks should `skip:` on it. Without
/// them [iphoneAppTheme] falls back to the test font, which still renders.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

const sfFontPath = '/System/Library/Fonts/SFNS.ttf';
const cjkFontPath = '/System/Library/Fonts/Hiragino Sans GB.ttc';
const _sfFamily = 'HarnessSF';
const _cjkFamily = 'HarnessHiragino';

/// True when this machine has the iPhone's system fonts (macOS).
final bool haveIphoneFonts =
    File(sfFontPath).existsSync() && File(cjkFontPath).existsSync();

bool _loaded = false;

/// Loads SF and Hiragino under the harness family names (once per isolate;
/// a no-op without the fonts). Call from setUpAll.
Future<void> loadIphoneFonts() async {
  if (_loaded || !haveIphoneFonts) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (family, path) in [(_sfFamily, sfFontPath), (_cjkFamily, cjkFontPath)]) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }
  _loaded = true;
}

/// The app theme with the iPhone fonts (when present) in place of the
/// platform families.
ThemeData iphoneAppTheme(Brightness brightness,
        {bool cjk = false, bool highContrast = false}) =>
    AppTheme.build(
      brightness,
      cjk: cjk,
      highContrast: highContrast,
      debugFontFamily: haveIphoneFonts ? _sfFamily : null,
      debugFontFallback: haveIphoneFonts ? const [_cjkFamily] : null,
    );

/// Pumps [home] in a MaterialApp with the app theme at a phone [size],
/// [locale], Dynamic Type [scale] (linear, as iOS reports it) and
/// [brightness], with [padding] as the safe-area insets.
Future<void> pumpApp(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  double scale = 1.0,
  Brightness brightness = Brightness.light,
  EdgeInsets padding = EdgeInsets.zero,
  double devicePixelRatio = 1.0,
  bool settle = true,
}) async {
  tester.view.physicalSize = size * devicePixelRatio;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);
  final cjk = locale.languageCode == 'zh';
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    theme: iphoneAppTheme(Brightness.light, cjk: cjk),
    darkTheme: iphoneAppTheme(Brightness.dark, cjk: cjk),
    themeMode:
        brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        padding: padding,
        viewPadding: padding,
      ),
      child: child!,
    ),
    home: home,
  ));
  if (settle) await tester.pumpAndSettle();
}
