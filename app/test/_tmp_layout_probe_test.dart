// TEMPORARY read-only probe for the layout-robustness lens. Not part of the
// suite; deleted after the measurements are taken. Loads the real iOS-family
// fonts installed on this Mac so widths match the phone, then measures rows
// at the text scales iOS Dynamic Type produces.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:calorie_tracker/ui/screens/history_screen.dart';
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:calorie_tracker/ui/screens/settings/api_key_page.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/fakes.dart';

bool _fontsLoaded = false;
Future<void> loadFonts(WidgetTester tester) async {
  if (_fontsLoaded) return;
  await tester.runAsync(() async {
    for (final (family, path) in [
      ('SF', '/System/Library/Fonts/SFNS.ttf'),
      ('CJK', '/System/Library/Fonts/Hiragino Sans GB.ttc'),
    ]) {
      try {
        final bytes = File(path).readAsBytesSync();
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        print('PROBE font $family loaded (${bytes.length} bytes)');
      } catch (e) {
        print('PROBE font $family FAILED: $e');
      }
    }
  });
  _fontsLoaded = true;
}

ThemeData themed(Brightness b) => ThemeData(
      colorScheme:
          ColorScheme.fromSeed(seedColor: const Color(0xFFCC785C), brightness: b),
      fontFamily: 'SF',
      fontFamilyFallback: const ['CJK'],
    );

Widget app(Widget home,
        {double scale = 1.0,
        Locale locale = const Locale('en'),
        Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: themed(brightness),
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('zh')],
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// (laid-out box width, width the text would need on one line)
({double box, double needed, bool clipped}) measure(
    WidgetTester tester, Finder f) {
  final rp = tester.renderObject<RenderParagraph>(f);
  final tp = TextPainter(
      text: rp.text,
      textDirection: TextDirection.ltr,
      textScaler: rp.textScaler,
      maxLines: 1)
    ..layout();
  return (box: rp.size.width, needed: tp.width, clipped: tp.width > rp.size.width + 0.5);
}

String fmt(({double box, double needed, bool clipped}) m) =>
    'box=${m.box.toStringAsFixed(1)} needs=${m.needed.toStringAsFixed(1)}${m.clipped ? ' ELLIPSIS' : ''}';

List<String> collectErrors(void Function() body) {
  final out = <String>[];
  final old = FlutterError.onError;
  FlutterError.onError = (d) {
    final s = d.exceptionAsString();
    out.add(s.split('\n').first);
  };
  try {
    body();
  } finally {
    FlutterError.onError = old;
  }
  return out;
}

Meal meal(int id, String date, String time, num kcal, String desc) => Meal(
      id: id,
      date: date,
      time: time,
      timestamp: '${date}T12:00:00',
      source: 'app_watch',
      imageHash: '',
      analysis: {
        'is_food': true,
        'meal_description': desc,
        'total_calories': kcal,
        'total_protein_g': 40,
        'total_carbs_g': 90,
        'total_fat_g': 40,
        'food_items': [
          {'name': 'Rice', 'estimated_calories': 300},
        ],
      },
    );

String iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  const scales = [1.0, 1.35, 1.64, 2.0];

  testWidgets('colours: dark/light scheme contrast', (tester) async {
    double lum(Color c) {
      double ch(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }
    double cr(Color a, Color b) {
      final la = lum(a), lb = lum(b);
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }
    String hex(Color c) =>
        '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
    for (final b in [Brightness.light, Brightness.dark]) {
      final s = ColorScheme.fromSeed(seedColor: const Color(0xFFCC785C), brightness: b);
      final cell = cellBackground(s);
      print('PROBE scheme $b cell=${hex(cell)}');
      for (final (name, c) in [
        ('primary', s.primary),
        ('secondary', s.secondary),
        ('tertiary', s.tertiary),
        ('error', s.error),
      ]) {
        print('PROBE   badge $name ${hex(c)}: white icon ${cr(c, Colors.white).toStringAsFixed(2)}:1, '
            'black87 icon ${cr(c, Color.alphaBlend(Colors.black87, c)).toStringAsFixed(2)}:1, '
            'onX ${cr(c, name == 'primary' ? s.onPrimary : name == 'secondary' ? s.onSecondary : name == 'tertiary' ? s.onTertiary : s.onError).toStringAsFixed(2)}:1');
      }
      print('PROBE   onSurfaceVariant ${hex(s.onSurfaceVariant)} on cell ${cr(s.onSurfaceVariant, cell).toStringAsFixed(2)}:1');
      final chevron = Color.alphaBlend(s.onSurfaceVariant.withValues(alpha: 0.6), cell);
      print('PROBE   chevron (onSurfaceVariant@60%) on cell ${cr(chevron, cell).toStringAsFixed(2)}:1');
      final dis = Color.alphaBlend(s.onSurface.withValues(alpha: 0.38), cell);
      print('PROBE   disabled title (onSurface@38%) on cell ${cr(dis, cell).toStringAsFixed(2)}:1');
      print('PROBE   error ${hex(s.error)} vs white (Dismissible bg + white icon) ${cr(s.error, Colors.white).toStringAsFixed(2)}:1');
      print('PROBE   outlineVariant@60% divider on cell ${cr(Color.alphaBlend(s.outlineVariant.withValues(alpha: 0.6), cell), cell).toStringAsFixed(2)}:1');
      print('PROBE   surfaceContainerHighest ${hex(s.surfaceContainerHighest)} (delta chip bg) on cell ${cr(s.surfaceContainerHighest, cell).toStringAsFixed(2)}:1');
      print('PROBE   secondaryContainer ${hex(s.secondaryContainer)} / onSecondaryContainer ${cr(s.secondaryContainer, s.onSecondaryContainer).toStringAsFixed(2)}:1');
    }
  });

  testWidgets('GroupedRow title/value at text scales', (tester) async {
    await loadFonts(tester);
    phone(tester);
    final cases = [
      ('Daily calorie goal', '2,000 kcal'),
      ('每日热量目标', '2,000 千卡'),
      ('Backfill Lookback', '30 days'),
      ('Background scan', 'Off in Settings'),
      ('Next summary', 'Tomorrow 07:00'),
      ('AI Provider', 'Doubao Agent Plan'),
      ('Thinking effort', 'High — most thorough'),
      ('Google Gemini', 'free tier · VPN in China'),
      ('Doubao Agent Plan', 'Volcengine subscription'),
      ('Server Claude sign-in', 'Could not check'),
    ];
    for (final (title, value) in cases) {
      for (final sc in scales) {
        await tester.pumpWidget(app(
            Scaffold(
                body: ListView(children: [
              GroupedSection(children: [
                GroupedRow(
                    icon: Icons.flag_outlined,
                    title: title,
                    value: value,
                    onTap: () {}),
              ])
            ])),
            scale: sc));
        await tester.pumpAndSettle();
        final t = measure(tester, find.text(title));
        final v = measure(tester, find.text(value));
        print('PROBE row ${sc.toStringAsFixed(2)}x "$title" title[${fmt(t)}] value[${fmt(v)}]');
      }
    }
  });

  testWidgets('Leftover meal picker title room', (tester) async {
    await loadFonts(tester);
    phone(tester);
    final today = iso(DateTime.now());
    final yesterday = iso(DateTime.now().subtract(const Duration(days: 1)));
    for (final (locale, desc) in [
      (const Locale('zh'), '牛肉面配煎蛋'),
      (const Locale('zh'), '番茄炒蛋盖饭和一碗汤'),
      (const Locale('en'), 'Chicken rice bowl'),
      (const Locale('en'), 'Cafeteria tray'),
    ]) {
      for (final sc in [1.0, 1.35]) {
        final dao = FakeDao()
          ..seed(meal(1, today, '12:30 PM', 1200, desc))
          ..seed(meal(2, yesterday, '07:00 PM', 650, desc));
        await tester.pumpWidget(app(
            LeftoverScreen(services: makeServices(dao: dao)),
            locale: locale,
            scale: sc));
        await tester.pumpAndSettle();
        for (final id in [1, 2]) {
          final row = find.byKey(Key('leftoverMeal-$id'));
          final titleF = find.descendant(of: row, matching: find.text(desc));
          final t = measure(tester, titleF);
          final texts = find.descendant(of: row, matching: find.byType(Text));
          final all = tester.widgetList<Text>(texts).map((w) => w.data).toList();
          final cell = tester.getSize(find.descendant(
              of: find.byType(GroupedSection), matching: find.byType(Material)).first);
          print('PROBE leftover ${locale.languageCode} ${sc.toStringAsFixed(2)}x row$id texts=$all cellWidth=${cell.width.toStringAsFixed(0)} title[${fmt(t)}]');
        }
      }
    }
  });

  testWidgets('Body screen at text scales', (tester) async {
    await loadFonts(tester);
    phone(tester);
    final clock = DateTime(2026, 10, 7, 10);
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      for (final sc in scales) {
        final dao = FakeDao();
        dao.weightsByDate['2026-09-28'] = WeightEntry('2026-09-28', 82.4, source: 'manual');
        dao.weightsByDate['2026-10-06'] = WeightEntry('2026-10-06', 81.6, source: 'manual');
        dao.measurementsByDate['2026-09-28'] =
            const BodyMeasurements('2026-09-28', waistCm: 95.5, chestCm: 102, hipCm: 98.5);
        dao.measurementsByDate['2026-10-06'] =
            const BodyMeasurements('2026-10-06', waistCm: 94.3, chestCm: 101, hipCm: 98);
        final errors = collectErrors(() {});
        final old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(app(
            BodyScreen(key: UniqueKey(), dao: dao, clock: () => clock),
            locale: locale,
            scale: sc));
        await tester.pumpAndSettle();
        FlutterError.onError = old;
        final waist = find.byKey(const Key('bodyWaistLatest'));
        final waistBox = tester.getRect(waist);
        print('PROBE body ${locale.languageCode} ${sc.toStringAsFixed(2)}x errors=${errors.length} ${errors.toSet().join(' | ')} waistValue.right=${waistBox.right.toStringAsFixed(0)}');
      }
    }
  });

  testWidgets('API key + subscription pages (en)', (tester) async {
    await loadFonts(tester);
    phone(tester);
    for (final sc in [1.0, 1.35]) {
      await tester.pumpWidget(app(
          ApiKeyProviderPage(settings: FakeSettings()..provider = 'gemini'),
          scale: sc));
      await tester.pumpAndSettle();
      for (final v in ['free tier · VPN in China', 'free · direct in China', 'direct in China']) {
        final f = find.text(v);
        if (f.evaluate().isEmpty) { print('PROBE apikey missing "$v"'); continue; }
        print('PROBE apikey ${sc.toStringAsFixed(2)}x "$v" ${fmt(measure(tester, f.first))}');
      }
      final s = FakeSettings()
        ..provider = 'server'
        ..serverBackend = 'claude'
        ..serverEffort = 'high'
        ..serverModel = 'opus';
      await tester.pumpWidget(app(SubscriptionProviderPage(settings: s), scale: sc));
      await tester.pumpAndSettle();
      for (final v in ['Anthropic subscription', 'Zhipu subscription', 'Volcengine subscription', 'High — most thorough', 'Thinking effort', 'Doubao Agent Plan']) {
        final f = find.text(v);
        if (f.evaluate().isEmpty) { print('PROBE sub missing "$v"'); continue; }
        print('PROBE sub ${sc.toStringAsFixed(2)}x "$v" ${fmt(measure(tester, f.first))}');
      }
    }
  });

  testWidgets('Settings root at text scales', (tester) async {
    await loadFonts(tester);
    phone(tester);
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      for (final sc in [1.0, 1.64, 2.0]) {
        final s = FakeSettings(lookbackDays: 30)..calorieGoal = 2000;
        final errors = <String>[];
        final old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(app(
            Scaffold(
                body: SettingsScreen(
                    settings: s,
                    analyzer: FakeAnalyzer(),
                    dao: FakeDao(),
                    requestPhotoPermission: () async => true,
                    nextSummaryAt: () async => DateTime.now().add(const Duration(days: 1)),
                    lastBackgroundScan: () async => DateTime.now().subtract(const Duration(days: 1)),
                    backgroundRefreshEnabled: () async => false,
                    openSystemSettings: () async {})),
            locale: locale,
            scale: sc));
        await tester.pumpAndSettle();
        FlutterError.onError = old;
        final goalRow = find.byKey(const Key('calorieGoalTile'));
        await tester.scrollUntilVisible(goalRow, 200, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        final texts = tester.widgetList<Text>(find.descendant(of: goalRow, matching: find.byType(Text))).toList();
        final title = measure(tester, find.descendant(of: goalRow, matching: find.text(texts[0].data!)));
        final value = measure(tester, find.descendant(of: goalRow, matching: find.text(texts[1].data!)));
        print('PROBE settings ${locale.languageCode} ${sc.toStringAsFixed(2)}x errors=${errors.length} ${errors.toSet().join(' | ')} goal title "${texts[0].data}"[${fmt(title)}] value "${texts[1].data}"[${fmt(value)}]');
        final bg = find.byKey(const Key('backgroundScanRow'));
        final bgTexts = tester.widgetList<Text>(find.descendant(of: bg, matching: find.byType(Text))).toList();
        final bgT = measure(tester, find.descendant(of: bg, matching: find.text(bgTexts[0].data!)));
        final bgV = measure(tester, find.descendant(of: bg, matching: find.text(bgTexts[1].data!)));
        print('PROBE settings ${locale.languageCode} ${sc.toStringAsFixed(2)}x bgscan title "${bgTexts[0].data}"[${fmt(bgT)}] value "${bgTexts[1].data}"[${fmt(bgV)}]');
      }
    }
  });

  testWidgets('History + Today at text scales', (tester) async {
    await loadFonts(tester);
    phone(tester);
    final now = DateTime.now();
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      for (final sc in [1.0, 1.64, 2.0]) {
        final dao = FakeDao();
        var id = 1;
        for (var d = 0; d < 10; d++) {
          final date = iso(now.subtract(Duration(days: d)));
          dao.seed(meal(id++, date, '12:30 PM', 1200 + d * 37, '牛肉面配煎蛋 beef noodles with egg'));
          dao.seed(meal(id++, date, '07:00 PM', 800, 'Cafeteria tray'));
        }
        var errors = <String>[];
        var old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(app(Scaffold(body: HistoryScreen(dao: dao)), locale: locale, scale: sc));
        await tester.pumpAndSettle();
        FlutterError.onError = old;
        final row = find.byKey(Key('historyDay${iso(now.subtract(const Duration(days: 1)))}'));
        final rowTexts = tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).map((t) => t.data ?? t.textSpan?.toPlainText()).toList();
        print('PROBE history ${locale.languageCode} ${sc.toStringAsFixed(2)}x errors=${errors.length} ${errors.toSet().join(' | ')} row texts=$rowTexts rowHeight=${tester.getSize(row).height.toStringAsFixed(0)}');

        errors = <String>[];
        old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(app(Scaffold(body: TodayScreen(dao: dao, executor: FakeExecutor())), locale: locale, scale: sc));
        await tester.pumpAndSettle();
        FlutterError.onError = old;
        final total = find.byKey(const Key('todayTotalKcal'));
        print('PROBE today ${locale.languageCode} ${sc.toStringAsFixed(2)}x errors=${errors.length} ${errors.toSet().join(' | ')} total[${fmt(measure(tester, total))}]');
      }
    }
  });
}
