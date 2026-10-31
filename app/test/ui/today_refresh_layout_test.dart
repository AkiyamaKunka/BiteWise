// The run-7 Today and Day-detail refresh, measured on an iPhone SE
// (375×667) with the app's real theme and the iPhone's own fonts, in en
// and zh, light and dark:
//   - U15: the eaten total is printed once as the hero (the ring centre)
//     and once as the result row; the 'N kcal' title line is gone, the
//     typical-day footnote stays, and the emphasized row really is heavier.
//   - A4: at the accessibility sizes a meal card's clock moves under its
//     title and the title is never cut; the hero stacks (ring above the
//     rows, one macro per row) instead of squeezing a third of the card.
//   - L4: a load failure reads as one translated sentence, never the raw
//     English exception.
//   - A11: Today's meal cards and Day detail's rows are buttons.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/garmin_client.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/meal_thumbs.dart';
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/widgets/calorie_ring.dart';
import 'package:calorie_tracker/ui/widgets/meal_card.dart';
import 'package:calorie_tracker/ui/widgets/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

const _se = Size(375, 667);

String _daysAgo(int days) {
  final now = DateTime.now();
  return isoDate(DateTime(now.year, now.month, now.day - days));
}

/// A photo meal [daysAgo] calendar days back (computed — a pinned date is
/// a time bomb). Generic dish names, nobody's real meal.
Meal _meal(int id, int daysAgo, num kcal,
    {String title = 'Lunch', String time = '12:00 PM', bool corrected = false}) {
  final date = _daysAgo(daysAgo);
  return Meal(
    id: id,
    date: date,
    time: time,
    timestamp: '${date}T12:00:00',
    source: 'app_photo',
    imageHash: 'h$id',
    corrected: corrected,
    analysis: {
      'is_food': true,
      'meal_description': title,
      'total_calories': kcal,
      'total_protein_g': 20,
      'total_carbs_g': 50,
      'total_fat_g': 10,
    },
  );
}

String _longTitle(String lang) => lang == 'zh'
    ? '拿铁咖啡（大杯，全脂奶）和全麦三明治配水果沙拉'
    : 'Grilled chicken breast with Caesar salad and garlic croutons';

/// Today with two prior days (so the arithmetic rows show), a Garmin burn,
/// and two meals; meal 1 has a long title and is corrected.
Widget _today(String lang) {
  final d = FakeDao()
    ..seed(_meal(1, 0, 450,
        title: _longTitle(lang), time: '01:30 PM', corrected: true))
    ..seed(_meal(2, 0, 50, time: '06:10 PM'))
    ..seed(_meal(3, 1, 2010))
    ..seed(_meal(4, 2, 1760));
  return Scaffold(
    body: TodayScreen(
      dao: d,
      executor: FakeExecutor(),
      thumbs: MealThumbResolver(dao: d),
      garminDaily: (date) async => const GarminDaily(
          activeCalories: 512, steps: 8000, distanceM: 6200, activityCount: 1),
    ),
  );
}

Finder _inMeal(int id, String key) => find.descendant(
    of: find.byKey(ValueKey('meal$id')), matching: find.byKey(Key(key)));

RenderParagraph _paragraph(WidgetTester tester, Finder text) => tester
    .renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)).first);

/// [p] lays out on one line (its width is its natural width).
void _expectOneLine(RenderParagraph p) {
  expect(p.size.width,
      greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5),
      reason: '"${p.text.toPlainText()}" must not wrap');
}

class _FailingDao extends FakeDao {
  bool fail = true;

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) async {
    if (fail) throw StateError('database is locked (code 5)');
    return super.mealsBetween(startDate, endDate);
  }
}

void main() {
  setUpAll(loadIphoneFonts);

  group('iPhone SE, app theme', () {
    for (final lang in const ['en', 'zh']) {
      for (final brightness in Brightness.values) {
        final tag = '$lang ${brightness.name}';

        testWidgets('$tag, 1.0x: the ring sits beside the rows and a long '
            'card title stops at two lines', (tester) async {
          await pumpApp(tester, _today(lang),
              size: _se, locale: Locale(lang), brightness: brightness);
          expect(tester.takeException(), isNull);

          final ring = tester.getRect(find.byType(CalorieRing));
          final count = tester.getRect(find.byKey(const Key('todayMealCount')));
          expect(count.left, greaterThanOrEqualTo(ring.right));
          expect(count.top, lessThan(ring.bottom));
          final rows = find.byType(ArithmeticRow);
          expect(rows, findsNWidgets(3), reason: 'typical, burn and eaten');
          for (final row in rows.evaluate()) {
            final r = tester.getRect(find.byWidget(row.widget));
            expect(r.left, greaterThanOrEqualTo(ring.right));
          }

          final title = _inMeal(1, 'mealCardTitle');
          final time = _inMeal(1, 'mealCardTime');
          await tester.scrollUntilVisible(time, 200,
              scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          expect(tester.widget<Text>(title).maxLines, 2);
          final p = _paragraph(tester, title);
          expect(p.didExceedMaxLines, isTrue,
              reason: 'the long title is cut with an ellipsis at 1.0x');
          // titleMedium is 17/22: two lines are 44 pt.
          expect(p.size.height, lessThanOrEqualTo(44.5));
          // The clock stays on the title's line.
          expect(tester.getRect(time).left,
              greaterThanOrEqualTo(tester.getRect(title).right));
          expect(tester.getRect(time).top,
              lessThan(tester.getRect(title).bottom));
          expect(tester.widget<Icon>(_inMeal(1, 'correctedBadge')).size, 15);
        }, skip: !haveIphoneFonts);

        testWidgets('$tag, 3.1x: the ring is above the rows, each macro has '
            'a row, and the card clock sits under a whole title',
            (tester) async {
          await pumpApp(tester, _today(lang),
              size: _se,
              locale: Locale(lang),
              brightness: brightness,
              scale: 3.1);
          expect(tester.takeException(), isNull);

          final ring = tester.getRect(find.byType(CalorieRing));
          final count = tester.getRect(find.byKey(const Key('todayMealCount')));
          expect(count.top, greaterThanOrEqualTo(ring.bottom));
          final trio = find.byKey(const Key('macroTrio'));
          await tester.scrollUntilVisible(trio, 200,
              scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          final trioRect = tester.getRect(trio);
          for (final row in find.byType(ArithmeticRow).evaluate()) {
            final r = tester.getRect(find.byWidget(row.widget));
            expect(r.width, closeTo(trioRect.width, 0.5),
                reason: 'the rows take the full width under the ring');
          }

          // One macro per row: each label on one line, uncut, above the
          // next one.
          final labels = tester
              .renderObjectList<RenderParagraph>(
                  find.descendant(of: trio, matching: find.byType(RichText)))
              .toList();
          expect(labels, hasLength(3));
          for (var i = 0; i < labels.length; i++) {
            expect(labels[i].didExceedMaxLines, isFalse);
            _expectOneLine(labels[i]);
            if (i > 0) {
              final above = labels[i - 1].localToGlobal(Offset.zero).dy +
                  labels[i - 1].size.height;
              expect(labels[i].localToGlobal(Offset.zero).dy,
                  greaterThanOrEqualTo(above));
            }
          }

          final title = _inMeal(1, 'mealCardTitle');
          final time = _inMeal(1, 'mealCardTime');
          await tester.scrollUntilVisible(time, 200,
              scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final titleRect = tester.getRect(title);
          expect(tester.widget<Text>(title).maxLines, isNull);
          expect(_paragraph(tester, title).didExceedMaxLines, isFalse,
              reason: 'the meal name reads in full');
          expect(tester.getRect(time).top,
              greaterThanOrEqualTo(titleRect.bottom - 0.5),
              reason: 'the clock moves under the title');
          expect(
              tester
                  .getRect(_inMeal(1, 'correctedBadge'))
                  .top,
              greaterThanOrEqualTo(titleRect.bottom - 0.5),
              reason: 'the corrected mark goes with the clock');
          expect(tester.widget<Icon>(_inMeal(1, 'correctedBadge')).size, 22.5,
              reason: 'the mark grows with the text, up to 1.5x');
          final card = tester.getRect(find.byKey(const ValueKey('meal1')));
          expect(titleRect.width, greaterThanOrEqualTo(card.width / 2));
          _expectOneLine(_paragraph(tester, time));
        }, skip: !haveIphoneFonts);
      }
    }
  });

  group('U15: one hero number', () {
    testWidgets('the eaten total shows in the ring centre and the Eaten row '
        'only; the typical-day footnote stays', (tester) async {
      final dao = FakeDao()
        ..seed(_meal(1, 0, 500))
        ..seed(_meal(2, 1, 2010))
        ..seed(_meal(3, 2, 1760));
      await pumpApp(
          tester, Scaffold(body: TodayScreen(dao: dao, executor: FakeExecutor())));
      expect(find.byKey(const Key('todayTotalKcal')), findsNothing);
      expect(find.text('500 kcal'), findsNothing);
      expect(find.text('500'), findsNWidgets(2));
      expect(
          tester.widget<Text>(find.byKey(const Key('ringCenterValue'))).data,
          '500');
      expect(tester.widget<ArithmeticRow>(
              find.byKey(const Key('arithmeticResultRow'))).value,
          '500');
      expect(find.text('1 meal today'), findsOneWidget);
      // §5.1 parity pin: the footnote is kept (median of 2,010 and 1,760).
      expect(
          tester.widget<Text>(find.byKey(const Key('typicalDayLine'))).data,
          'Typical day: ~1,885 kcal');
    });

    testWidgets('an empty first day: the ring, the meal count and the empty '
        'state, with no Eaten row repeating the centre', (tester) async {
      await pumpApp(tester,
          Scaffold(body: TodayScreen(dao: FakeDao(), executor: FakeExecutor())));
      expect(tester.takeException(), isNull);
      expect(find.byType(ArithmeticRow), findsNothing);
      expect(find.text('0 meals today'), findsOneWidget);
      expect(
          tester.widget<Text>(find.byKey(const Key('ringCenterValue'))).data,
          '0');
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No meals logged yet today.'), findsOneWidget);
    });

    for (final lang in const ['en', 'zh']) {
      for (final brightness in Brightness.values) {
        testWidgets('$lang ${brightness.name}: the emphasized row is heavier',
            (tester) async {
          await pumpApp(
              tester,
              const Scaffold(
                body: Column(children: [
                  ArithmeticRow(
                      key: Key('plain'),
                      label: 'Typical',
                      value: '~1,500',
                      dot: Colors.grey),
                  ArithmeticRow(
                      key: Key('emphasized'),
                      label: 'Eaten',
                      value: '1,200',
                      dot: Colors.brown,
                      emphasized: true),
                ]),
              ),
              locale: Locale(lang),
              brightness: brightness);
          TextStyle valueStyle(String key, String value) => tester
              .widget<Text>(find.descendant(
                  of: find.byKey(Key(key)), matching: find.text(value)))
              .style!;
          final plain = valueStyle('plain', '~1,500');
          final strong = valueStyle('emphasized', '1,200');
          expect(strong.fontWeight!.value,
              greaterThan(plain.fontWeight!.value));
          expect(strong.fontSize!, greaterThan(plain.fontSize!));
          expect(strong.fontFeatures,
              contains(const FontFeature.tabularFigures()));
        });
      }
    }
  });

  group('L4: load failure', () {
    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: one translated sentence, Retry reloads',
          (tester) async {
        final dao = _FailingDao();
        await pumpApp(
            tester,
            Scaffold(body: TodayScreen(dao: dao, executor: FakeExecutor())),
            locale: Locale(lang));
        expect(find.byKey(const Key('todayLoadError')), findsOneWidget);
        expect(
            find.text(lang == 'zh' ? '无法加载今天的记录。' : "Couldn't load today's meals."),
            findsOneWidget);
        expect(find.textContaining('database is locked'), findsNothing,
            reason: 'the raw exception is for the debug log only');
        expect(find.textContaining('Could not load'), findsNothing);

        dao.fail = false;
        await tester.tap(find.byKey(const Key('todayRetry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('todayLoadError')), findsNothing);
        expect(find.byType(CalorieRing), findsOneWidget);
      });
    }
  });

  group('L7: item lines', () {
    for (final (lang, line) in const [
      ('en', '• Rice (~150 g): ~200 kcal'),
      ('zh', '• Rice (~150 g)：~200 千卡'),
    ]) {
      testWidgets('$lang: "$line"', (tester) async {
        final meal = _meal(1, 0, 450);
        await pumpApp(
            tester,
            Scaffold(
              body: MealCard(
                meal: Meal(
                  id: meal.id,
                  date: meal.date,
                  time: meal.time,
                  timestamp: meal.timestamp,
                  source: meal.source,
                  analysis: {
                    ...meal.analysis,
                    'food_items': [
                      {'name': 'Rice (~150 g)', 'estimated_calories': 200},
                    ],
                  },
                ),
              ),
            ),
            locale: Locale(lang));
        expect(find.text(line), findsOneWidget);
      });
    }
  });

  group('A11: meal rows are buttons', () {
    testWidgets('a Today meal card: one button node, title not doubled',
        (tester) async {
      final handle = tester.ensureSemantics();
      final dao = FakeDao()..seed(_meal(1, 0, 450, title: 'Tomato egg rice'));
      await pumpApp(
          tester, Scaffold(body: TodayScreen(dao: dao, executor: FakeExecutor())));
      final node = tester.getSemantics(_inMeal(1, 'mealCardTitle'));
      expect(node.flagsCollection.isButton, isTrue);
      expect('Tomato egg rice'.allMatches(node.label), hasLength(1));
      handle.dispose();
    });

    testWidgets('a Day-detail meal row is a button that opens the editor',
        (tester) async {
      final handle = tester.ensureSemantics();
      final dao = FakeDao()..seed(_meal(1, 0, 450, title: 'Tomato egg rice'));
      await pumpApp(tester, DayDetailScreen(dao: dao, date: _daysAgo(0)));
      final node = tester.getSemantics(find.byKey(const Key('mealRow1')));
      expect(node.flagsCollection.isButton, isTrue);
      expect('Tomato egg rice'.allMatches(node.label), hasLength(1));
      await tester.tap(find.byKey(const Key('mealRow1')));
      await tester.pumpAndSettle();
      expect(find.text('Edit meal'), findsOneWidget);
      handle.dispose();
    });
  });

  group('the ring arc', () {
    Widget ring(num eaten, {bool reduceMotion = false}) => MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reduceMotion),
              child: Scaffold(
                  body: Center(
                      child:
                          CalorieRing(eatenKcal: eaten, typicalKcal: 2000))),
            ),
          ),
        );

    testWidgets('draws in place first, eases to a new total, and is '
        'instant under Reduce Motion', (tester) async {
      await tester.pumpWidget(ring(800));
      expect(tester.hasRunningAnimations, isFalse,
          reason: 'the first build never animates');
      await tester.pumpWidget(ring(1500));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.hasRunningAnimations, isTrue,
          reason: 'still easing at half of 600 ms');
      await tester.pumpAndSettle();
      expect(
          tester.widget<Text>(find.byKey(const Key('ringCenterValue'))).data,
          '1,500',
          reason: 'the number itself never animates');

      await tester.pumpWidget(ring(1500, reduceMotion: true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(ring(1900, reduceMotion: true));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
