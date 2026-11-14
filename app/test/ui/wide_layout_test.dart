// Android push (ui lane, 2026-11-13): for targetSdk 36, Android 16
// ignores orientation and resizability limits at 600 dp and wider, so
// tablets, foldables and Chromebooks get the app whatever the manifest
// says. The tab bodies filled the window: an 800 dp window stretched every
// card edge to edge (UX run screenshot 62), and in phone landscape with
// 3-button navigation the cards ran under the side bar (screenshot 73).
// From 600 dp the content is a centred column at most 640 dp wide, and the
// side insets are kept clear. Phones in portrait are unchanged.
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/screens/history_screen.dart';
import 'package:calorie_tracker/ui/screens/settings/profile_page.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void _window(WidgetTester tester, Size size,
    {FakeViewPadding padding = FakeViewPadding.zero}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
}

Future<void> _pumpShell(WidgetTester tester) async {
  await tester.pumpWidget(
      CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [Size(800, 1280), Size(1280, 800)]) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()}: the tabs are '
        'a centred column at most $kContentMaxWidth dp', (tester) async {
      _window(tester, size);
      await _pumpShell(tester);
      final today = tester.getRect(find.byType(TodayScreen));
      expect(today.width, kContentMaxWidth);
      expect(today.center.dx, closeTo(size.width / 2, 0.01));
      expect(today.height, greaterThan(size.height / 2),
          reason: 'still the whole height above the tab bar');
      // The tab bar still spans the window.
      expect(tester.getRect(find.byType(NavigationBar)).width, size.width);

      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      final history = tester.getRect(find.byType(HistoryScreen));
      expect(history.width, kContentMaxWidth);
      expect(history.center.dx, closeTo(size.width / 2, 0.01));
    });
  }

  testWidgets('a phone in portrait is unchanged: the tabs fill the width',
      (tester) async {
    _window(tester, const Size(411, 891));
    await _pumpShell(tester);
    final today = tester.getRect(find.byType(TodayScreen));
    expect(today.left, 0);
    expect(today.width, 411);
  });

  testWidgets('just under 600 dp nothing is capped', (tester) async {
    _window(tester, const Size(599, 900));
    await _pumpShell(tester);
    expect(tester.getRect(find.byType(TodayScreen)).width, 599);
  });

  testWidgets('phone landscape with 3-button navigation: nothing under the '
      'side bar', (tester) async {
    // A Pixel-size phone on its side: the navigation buttons on the right.
    _window(tester, const Size(891, 411),
        padding: const FakeViewPadding(right: 48, top: 24));
    await _pumpShell(tester);
    final today = tester.getRect(find.byType(TodayScreen));
    expect(today.right, lessThanOrEqualTo(891 - 48));
    expect(today.width, kContentMaxWidth);
    expect(today.center.dx, closeTo((891 - 48) / 2, 0.01));
  });

  testWidgets('a tab keeps its state across the breakpoint (unfolding)',
      (tester) async {
    _window(tester, const Size(411, 891));
    await _pumpShell(tester);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    final before = tester.state(find.byType(HistoryScreen));
    tester.view.physicalSize = const Size(840, 900);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(HistoryScreen)), same(before));
    expect(tester.getRect(find.byType(HistoryScreen)).width, kContentMaxWidth);
  });

  group('GroupedPage', () {
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
          home: ProfileSettingsPage(settings: FakeSettings())));
      await tester.pumpAndSettle();
    }

    testWidgets('1280 dp: its content is the centred column', (tester) async {
      _window(tester, const Size(1280, 800));
      await pumpPage(tester);
      final field = tester.getRect(find.byKey(const Key('dietaryProfileField')));
      final scroll = tester.getRect(find.byType(CustomScrollView));
      expect(scroll.width, kContentMaxWidth);
      expect(scroll.center.dx, closeTo(640, 0.01));
      expect(field.left, greaterThanOrEqualTo(scroll.left));
      expect(field.right, lessThanOrEqualTo(scroll.right));
    });

    testWidgets('a phone: the full width', (tester) async {
      _window(tester, const Size(390, 844));
      await pumpPage(tester);
      expect(tester.getRect(find.byType(CustomScrollView)).width, 390);
    });
  });
}
