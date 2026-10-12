// The startup error screen retries instead of needing a force-quit: the
// usual cause is an iOS launch while the phone is still locked before the
// keys have moved to the after-first-unlock keychain class (2026-10-09).
import 'package:calorie_tracker/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('retries on resume and from the button', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(StartupErrorApp(
        error: 'PlatformException(-25308)', onRetry: () async => attempts++));
    expect(find.text('Bitewise could not start.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('PlatformException(-25308)'), findsOneWidget,
        reason: 'the raw error stays, as a secondary line');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(attempts, 1, reason: 'unlocking and returning retries');

    await tester.tap(find.byKey(const Key('startupRetry')));
    await tester.pump();
    expect(attempts, 2);
  });

  testWidgets('a Chinese phone reads the screen in Chinese, raw error kept',
      (tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(StartupErrorApp(
        error: 'PlatformException(-25308)', onRetry: () async {}));
    expect(find.text('筷拍无法启动。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('PlatformException(-25308)'), findsOneWidget);
    expect(find.textContaining('CalorieTracker'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('no retry callback: no button, nothing to call',
      (tester) async {
    await tester.pumpWidget(const StartupErrorApp(error: 'x'));
    expect(find.byKey(const Key('startupRetry')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });
}
