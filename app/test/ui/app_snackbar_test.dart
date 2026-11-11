/// main.dart's snackbar sink (the pipeline / startup-glue `notify`).
///
/// A cold-start share whose verdict needs no analyzer call (duplicate /
/// already logged — DB-only) can resolve before the first frame mounts the
/// ScaffoldMessenger; `currentState?.showSnackBar` used to drop it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/main.dart';
import 'package:calorie_tracker/ui/widgets/usual_offer_card.dart';

Widget _app() => MaterialApp(
    scaffoldMessengerKey: messengerKey, home: const Scaffold(body: Text('')));

/// [seconds] one-second frames, stopping early once [text] is on screen.
Future<bool> _seenWithin(WidgetTester tester, String text, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (find.text(text).evaluate().isNotEmpty) return true;
  }
  return false;
}

SnackBar _usedSnack(ScaffoldMessengerState messenger) => SnackBar(
    duration: kUsualUndoSnackDuration,
    persist: usualUndoPersists(messenger),
    content: const Text('Used your usual numbers: 300 → 350 kcal'),
    action: SnackBarAction(label: 'Undo', onPressed: () {}));

void main() {
  testWidgets('a message sent before the messenger mounts is shown after '
      'the first frame, in order', (tester) async {
    expect(messengerKey.currentState, isNull);
    showAppSnackbar('held one');
    showAppSnackbar('held two');
    await tester.pumpWidget(_app());
    await tester.pump(); // the post-frame flush schedules the snackbar frame
    expect(find.text('held one'), findsOneWidget);
    // Queued behind the first on the messenger, not lost.
    messengerKey.currentState!.removeCurrentSnackBar();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('held two'), findsOneWidget);
  });

  testWidgets('once mounted, a message shows straight away', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('now');
    await tester.pump();
    expect(find.text('now'), findsOneWidget);
  });

  // RC 1.6.0: the restaurant lookup's "used the chain's numbers" line with
  // Undo (di.dart notifyAction) had no duration and no persist, so on
  // Flutter 3.44 it never timed out and every later message queued unseen
  // behind it.
  testWidgets('no screen reader: the lookup Undo snackbar times out, and a '
      'message sent after it is seen', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbarWithAction(
        'Used Chipotle published numbers: 650 → 720 kcal', 'Undo', () {});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Undo'), findsOneWidget);
    showAppSnackbar('Logged: Oatmeal, 350 kcal');
    expect(await _seenWithin(tester, 'Logged: Oatmeal, 350 kcal', 12), isTrue,
        reason: 'queued behind an Undo snackbar that never left');
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('under VoiceOver / TalkBack the lookup Undo snackbar stays up '
      'until it is acted on', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_app());
    var undone = 0;
    showAppSnackbarWithAction('Used published numbers', 'Undo', () => undone++);
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Undo'), findsOneWidget,
        reason: 'a screen-reader user needs time to reach Undo');
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(undone, 1);
  });

  testWidgets('a plain message still leaves on its own', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Toast');
    await tester.pump();
    expect(find.text('Logged: Toast'), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Logged: Toast'), findsNothing);
  });

  testWidgets('Use on a chip while the lookup Undo snackbar is queued: its '
      'snackbar is still seen', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Big Mac');
    showAppSnackbarWithAction(
        'Used published numbers: 540 → 590 kcal', 'Undo', () {});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final messenger = messengerKey.currentState!;
    showUsualSnack(messenger, _usedSnack(messenger));
    expect(
        await _seenWithin(
            tester, 'Used your usual numbers: 300 → 350 kcal', 20),
        isTrue);
  });

  testWidgets('Use on a chip after a catch-up logged three photos: the '
      'queued messages are not dropped, and its snackbar follows them',
      (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Oatmeal');
    showAppSnackbar('Logged: Latte');
    showAppSnackbar('Logged: Banana');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Logged: Oatmeal'), findsOneWidget);
    final messenger = messengerKey.currentState!;
    showUsualSnack(messenger, _usedSnack(messenger));
    expect(await _seenWithin(tester, 'Logged: Latte', 3), isTrue);
    expect(await _seenWithin(tester, 'Logged: Banana', 6), isTrue);
    expect(
        await _seenWithin(
            tester, 'Used your usual numbers: 300 → 350 kcal', 6),
        isTrue);
  });
}
