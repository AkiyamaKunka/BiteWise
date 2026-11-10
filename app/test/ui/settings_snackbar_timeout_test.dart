/// Settings' three snackbars that carry an action must still time out.
///
/// On the Flutter this app builds with, `SnackBar.persist` defaults to
/// `action != null`: a snackbar WITH an action ignores its `duration` and
/// stays until it is tapped or swiped, and every later snackbar queues
/// unseen behind it (seen in the simulator on 2026-11-09 for the
/// usual-foods Undo). The three here: the photo-permission notice ("Open
/// system settings"), the limited-access warning ("Fix") and the
/// privacy-link fallback ("Copy").
///
/// Under VoiceOver / TalkBack they stay up, as an action snackbar always
/// did: a screen-reader user needs more than a few seconds to reach the
/// button.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';

import 'fakes.dart';

/// iOS "selected photos" / Android partial grant. Nothing else is reached
/// from the toggle path.
class _LimitedLibrary implements PhotoLibrary {
  @override
  Future<bool> hasFullAccess() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _en = lookupAppLocalizations(const Locale('en'));

/// One snackbar: how to raise it, what it says, its action, and the
/// counter the action bumps.
typedef _Site = ({
  String name,
  String text,
  String action,
  Future<void> Function(WidgetTester tester, void Function() acted) raise,
});

Future<void> _pumpSettings(
  WidgetTester tester, {
  required FakeSettings settings,
  bool permission = true,
  PhotoLibrary? library,
  Future<void> Function()? openSystemSettings,
  Future<bool> Function(Uri)? openUrl,
}) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SettingsScreen(
        settings: settings,
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        requestPhotoPermission: () async => permission,
        photoLibrary: library,
        openSystemSettings: openSystemSettings,
        openUrl: openUrl,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

final _sites = <_Site>[
  (
    name: 'photo permission denied',
    text: _en.watcherPermissionDenied,
    action: _en.openSystemSettings,
    raise: (tester, acted) async {
      await _pumpSettings(tester,
          settings:
              FakeSettings(watcherEnabled: false, watcherDisclosureSeen: true),
          permission: false,
          openSystemSettings: () async => acted());
      await tester.tap(find.byKey(const Key('watcherToggle')));
    },
  ),
  (
    name: 'limited photo access',
    text: _en.watcherLimitedAccess,
    action: _en.fixAction,
    raise: (tester, acted) async {
      await _pumpSettings(tester,
          settings: FakeSettings(
              apiKey: 'k', watcherEnabled: false, watcherDisclosureSeen: true),
          library: _LimitedLibrary(),
          openSystemSettings: () async => acted());
      await tester.tap(find.byKey(const Key('watcherToggle')));
    },
  ),
  (
    name: 'privacy policy did not open',
    text: _en.privacyOpenFailed(privacyPolicyUri.toString()),
    action: _en.privacyCopyAction,
    raise: (tester, acted) async {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') acted();
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await _pumpSettings(tester,
          settings: FakeSettings(apiKey: 'k'), openUrl: (_) async => false);
      final row = find.byKey(const Key('privacyPolicyRow'));
      await tester.scrollUntilVisible(row, 200);
      await tester.tap(row);
    },
  ),
];

/// Lets [total] pass a frame at a time, so the messenger's entrance
/// animation, its timeout timer and its exit animation all get their turn.
Future<void> _elapse(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 250);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

void main() {
  for (final site in _sites) {
    group(site.name, () {
      testWidgets('shows for a few seconds, then leaves on its own',
          (tester) async {
        await site.raise(tester, () {});
        await _elapse(tester, const Duration(seconds: 5));
        expect(find.text(site.text), findsOneWidget,
            reason: 'long enough to read and to reach the action');
        expect(find.text(site.action), findsOneWidget);
        await _elapse(tester, const Duration(seconds: 5));
        expect(find.text(site.text), findsNothing,
            reason: 'a snackbar with an action must still time out');
      });

      testWidgets('a later snackbar is not stuck behind it', (tester) async {
        await site.raise(tester, () {});
        await _elapse(tester, const Duration(seconds: 1));
        ScaffoldMessenger.of(tester.element(find.byType(SettingsScreen)))
            .showSnackBar(const SnackBar(content: Text('the next message')));
        await _elapse(tester, const Duration(seconds: 10));
        expect(find.text('the next message'), findsOneWidget);
      });

      testWidgets('the action still works', (tester) async {
        var acted = 0;
        await site.raise(tester, () => acted++);
        await _elapse(tester, const Duration(seconds: 1));
        await tester.tap(find.text(site.action));
        await tester.pump();
        expect(acted, 1);
        await _elapse(tester, const Duration(seconds: 1));
        expect(find.text(site.text), findsNothing,
            reason: 'pressing the action dismisses it');
      });

      testWidgets('stays up under VoiceOver / TalkBack until it is acted on',
          (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
        var acted = 0;
        await site.raise(tester, () => acted++);
        await _elapse(tester, const Duration(seconds: 30));
        expect(find.text(site.text), findsOneWidget,
            reason: 'a screen-reader user needs time to reach the action');
        await tester.tap(find.text(site.action));
        await tester.pump();
        expect(acted, 1);
        await _elapse(tester, const Duration(seconds: 1));
        expect(find.text(site.text), findsNothing);
      });
    });
  }

  testWidgets('with no way to open system settings there is no action, and '
      'the notice still leaves — under VoiceOver too', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpSettings(tester,
        settings:
            FakeSettings(watcherEnabled: false, watcherDisclosureSeen: true),
        permission: false);
    await tester.tap(find.byKey(const Key('watcherToggle')));
    await _elapse(tester, const Duration(seconds: 1));
    expect(find.text(_en.watcherPermissionDenied), findsOneWidget);
    expect(find.text(_en.openSystemSettings), findsNothing);
    await _elapse(tester, const Duration(seconds: 9));
    expect(find.text(_en.watcherPermissionDenied), findsNothing,
        reason: 'nothing to press, so nothing to wait for');
  });
}
