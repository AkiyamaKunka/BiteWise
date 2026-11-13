// The text fields that sit INSIDE a grouped cell (API Key, Your own server,
// Dietary profile) keep the cell's own 16-pt side inset, so their labels
// line up with the rows and headers, and 10 pt above and below. The three
// pages share one cellField (settings_kit.dart) for it.
import 'package:calorie_tracker/ui/screens/settings/api_key_page.dart';
import 'package:calorie_tracker/ui/screens/settings/profile_page.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

/// The gaps between the field keyed [key] and the grouped cell it sits in.
({double left, double top, double right, double bottom}) _gapsInCell(
    WidgetTester tester, Key key) {
  final field = find.byKey(key);
  expect(field, findsOneWidget, reason: '$key');
  final cell = tester.getRect(
      find.ancestor(of: field, matching: find.byType(Material)).first);
  final box = tester.getRect(field);
  return (
    left: box.left - cell.left,
    top: box.top - cell.top,
    right: cell.right - box.right,
    bottom: cell.bottom - box.bottom,
  );
}

void main() {
  testWidgets('API Key: the key, the model picker and a custom model',
      (tester) async {
    await pumpApp(
        tester,
        ApiKeyProviderPage(
            settings: FakeSettings(apiKey: 'k', model: 'my-own-model')),
        size: const Size(390, 1600));
    // The key is the only field in its cell.
    final key = _gapsInCell(tester, const Key('apiKeyField'));
    expect(key, (left: 16.0, top: 10.0, right: 16.0, bottom: 10.0));
    // The picker opens the model cell; the custom model closes it.
    final picker = _gapsInCell(tester, const Key('modelPicker'));
    expect((picker.left, picker.top, picker.right), (16.0, 10.0, 16.0));
    final custom = _gapsInCell(tester, const Key('modelField'));
    expect((custom.left, custom.right, custom.bottom), (16.0, 16.0, 10.0));
  });

  testWidgets('Your own server: the address and the upload key',
      (tester) async {
    final s = FakeSettings(apiKey: 'k')
      ..provider = 'server'
      ..serverBackend = 'claude';
    await pumpApp(tester, SubscriptionProviderPage(settings: s),
        size: const Size(390, 1600));
    final address = _gapsInCell(tester, const Key('serverUrlField'));
    expect((address.left, address.top, address.right), (16.0, 10.0, 16.0));
    final upload = _gapsInCell(tester, const Key('serverUploadKeyField'));
    expect((upload.left, upload.right, upload.bottom), (16.0, 16.0, 10.0));
  });

  testWidgets('Dietary profile: the one field', (tester) async {
    await pumpApp(tester, ProfileSettingsPage(settings: FakeSettings()));
    expect(_gapsInCell(tester, const Key('dietaryProfileField')),
        (left: 16.0, top: 10.0, right: 16.0, bottom: 10.0));
  });
}
