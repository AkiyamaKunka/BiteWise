// The Your own server page's address field. It saved only on Done or on a
// tap outside it — and Flutter does not count a tap into another text field
// (the upload key, right under it) as outside. So the natural order (type
// the address, tap the upload key, type it, Done) lost the address: Test
// This Provider said "No server address is set", and Connect Claude (U3)
// asked for an address the field still showed. Found on the run-7
// decisions simulator walk.
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  testWidgets('the address is kept when the next tap is the upload key',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(keys: {'server': ''})..provider = 'server';
    var starts = 0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SubscriptionProviderPage(
        settings: settings,
        startClaudeAuth: () async {
          starts++;
          return (url: null, error: 'stop here');
        },
        completeClaudeAuth: (_) async => null,
      ),
    ));
    await tester.pumpAndSettle();

    final address = find.byKey(const Key('serverUrlField'));
    final key = find.byKey(const Key('serverUploadKeyField'));
    await tester.tap(address);
    await tester.enterText(address, 'http://10.0.0.7');
    await tester.tap(key);
    await tester.enterText(key, 'up');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.serverBaseUrl, 'http://10.0.0.7');
    expect(settings.apiKey, 'up');

    // So Connect Claude asks the server instead of for the address.
    await tester.tap(find.byKey(const Key('connectClaudeButton')));
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(find.text('Enter your server address and upload key above first.'),
        findsNothing);
  });

  testWidgets('a trailing slash or space is trimmed as it is typed',
      (tester) async {
    final settings = FakeSettings(keys: {'server': 'up'})..provider = 'server';
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SubscriptionProviderPage(settings: settings),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('serverUrlField')), ' http://10.0.0.7 ');
    await tester.pump();
    expect(settings.serverBaseUrl, 'http://10.0.0.7');
    expect(find.text(' http://10.0.0.7 '), findsOneWidget,
        reason: 'the field keeps what was typed; only the saved value is trimmed');
  });
}
