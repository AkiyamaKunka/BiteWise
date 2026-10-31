/// Display formats (L2): short localized dates instead of ISO strings,
/// and times that follow the device's 24-Hour Time switch. Storage is
/// never touched: isoDate and the stored strings stay exactly as they are.
library;

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/app_formats.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<BuildContext> _context(WidgetTester tester,
    {Locale locale = const Locale('en'), bool use24h = false}) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24h),
      child: child!,
    ),
    home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }),
  ));
  await tester.pumpAndSettle();
  return ctx;
}

void main() {
  final now = DateTime(2026, 10, 31);

  testWidgets("short dates: 'Oct 29' / '10月29日'", (tester) async {
    var c = await _context(tester);
    expect(AppFormats.shortDate(c, '2026-10-29', now: now), 'Oct 29');
    expect(AppFormats.shortDate(c, '2026-01-05', now: now), 'Jan 5');
    c = await _context(tester, locale: const Locale('zh'));
    expect(AppFormats.shortDate(c, '2026-10-29', now: now), '10月29日');
  });

  testWidgets('another year carries the year', (tester) async {
    var c = await _context(tester);
    expect(AppFormats.shortDate(c, '2025-10-29', now: now), 'Oct 29, 2025');
    c = await _context(tester, locale: const Locale('zh'));
    expect(AppFormats.shortDate(c, '2025-10-29', now: now), '2025年10月29日');
  });

  testWidgets('a value that is not a real date is shown as stored',
      (tester) async {
    final c = await _context(tester);
    for (final raw in ['2026-02-30', 'yesterday', '', '2026-1-5']) {
      expect(AppFormats.shortDate(c, raw, now: now), raw);
    }
  });

  testWidgets('English times follow the 24-Hour switch', (tester) async {
    var c = await _context(tester);
    const t = TimeOfDay(hour: 21, minute: 30);
    expect(AppFormats.time(c, t), '9:30 PM');
    expect(AppFormats.hm(c, '21:30'), '9:30 PM');
    expect(AppFormats.hm(c, '07:05'), '7:05 AM');
    c = await _context(tester, use24h: true);
    expect(AppFormats.time(c, t), '21:30');
    expect(AppFormats.hm(c, '07:05'), '07:05');
  });

  testWidgets('Chinese times are 24-hour, like the meal times beside them',
      (tester) async {
    for (final use24h in [false, true]) {
      final c = await _context(tester,
          locale: const Locale('zh'), use24h: use24h);
      expect(AppFormats.hm(c, '21:30'), '21:30');
    }
  });

  testWidgets('an unparseable stored time is shown as stored',
      (tester) async {
    final c = await _context(tester);
    for (final raw in ['25:00', '9pm', '', '21:7']) {
      expect(AppFormats.hm(c, raw), raw);
    }
  });

  test('storage is unaffected: isoDate stays ISO', () {
    expect(isoDate(DateTime(2026, 10, 29, 23, 59)), '2026-10-29');
  });
}
