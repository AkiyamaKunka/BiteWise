// Android push (ui lane, 2026-11-13): with 3-button navigation, switching
// the phone between light and dark while the app ran left a light bar
// under the dark app, and the reverse (UX run screenshots 57-59; a cold
// start was fine, 58). MainActivity handles uiMode itself, so the window
// kept its launch-time bar, and the app never set a navigation-bar style.
// The shell now styles the bar from the theme it shows (the tab bar's
// opaque colour, buttons in its contrast); the status bar stays with the
// app bars. iPhone has no such bar and gets no style.
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart' show AppColors;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _transparent = Color(0x00000000);

Finder _navBarRegion() => find.byWidgetPredicate((w) =>
    w is AnnotatedRegion<SystemUiOverlayStyle> &&
    w.value.systemNavigationBarIconBrightness != null);

void main() {
  void expectBarFor(Brightness theme) {
    final style = SystemChrome.latestStyle!;
    expect(style.systemNavigationBarIconBrightness,
        theme == Brightness.dark ? Brightness.light : Brightness.dark,
        reason: 'buttons readable on the $theme app');
    // Opaque, the tab bar's own colour: below Android 15 the app does not
    // draw under the bar, so a transparent one showed the window colour
    // fixed at launch (MainActivity handles uiMode itself) under buttons
    // that followed the new theme: light buttons on a white bar (review
    // 2026-11-13). Android 15+ draws edge to edge and ignores the colour.
    final chrome = (theme == Brightness.dark ? AppColors.dark : AppColors.light)
        .chrome;
    expect(style.systemNavigationBarColor, chrome);
    expect(style.systemNavigationBarColor!.a, 1.0, reason: 'opaque');
    expect(style.systemNavigationBarDividerColor, _transparent);
    expect(style.systemNavigationBarContrastEnforced, isFalse);
  }

  testWidgets('Android: the bar follows a light/dark switch while running',
      (tester) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    expectBarFor(Brightness.light);
    // The status bar is the app bar's: dark icons on the light page.
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.dark);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expectBarFor(Brightness.dark);
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.light);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expectBarFor(Brightness.light);
  });

  testWidgets('Android: a screen pushed over the shell keeps the style',
      (tester) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(HomeShell));
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(appBar: AppBar(title: const Text('Sub')))));
    await tester.pumpAndSettle();
    expectBarFor(Brightness.dark);
  });

  testWidgets('Android: the startup-error screen styles it too',
      (tester) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpWidget(const StartupErrorApp(error: 'boom'));
    await tester.pumpAndSettle();
    expect(_navBarRegion(), findsOneWidget);
    expectBarFor(Brightness.dark);
  });

  testWidgets('iPhone: no navigation-bar style is set', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    expect(_navBarRegion(), findsNothing);
    await tester.pumpWidget(const StartupErrorApp(error: 'boom'));
    await tester.pumpAndSettle();
    expect(_navBarRegion(), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
