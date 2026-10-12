/// main.dart's snackbar sink (the pipeline / startup-glue `notify`).
///
/// A cold-start share whose verdict needs no analyzer call (duplicate /
/// already logged — DB-only) can resolve before the first frame mounts the
/// ScaffoldMessenger; `currentState?.showSnackBar` used to drop it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/main.dart';

Widget _app() => MaterialApp(
    scaffoldMessengerKey: messengerKey, home: const Scaffold(body: Text('')));

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
}
