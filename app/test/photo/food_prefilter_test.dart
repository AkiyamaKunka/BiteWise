/// The on-device food check (design G3): the verdict, the channel's reply,
/// the call, and the one label table both sides use.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/services/analyzer/platform_decode.dart'
    show imageIOChannel, imageIOChannelName, isEngineBackgrounded,
        isHeadlessEngine;
import 'package:calorie_tracker/services/photo/food_prefilter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('foodVerdict', () {
    FoodCheck ok(double s) => FoodCheck(FoodCheckStatus.ok, score: s);

    test('below the threshold is not food; at and above it is', () {
      expect(foodVerdict(ok(0)), FoodVerdict.notFood);
      expect(foodVerdict(ok(kFoodThreshold - 0.0001)), FoodVerdict.notFood);
      expect(foodVerdict(ok(kFoodThreshold)), FoodVerdict.food);
      expect(foodVerdict(ok(0.63)), FoodVerdict.food);
      expect(foodVerdict(ok(1)), FoodVerdict.food);
    });

    test('the threshold starts permissive', () {
      expect(kFoodThreshold, 0.10);
    });

    test('deferred_gpu waits for the foreground', () {
      expect(foodVerdict(const FoodCheck(FoodCheckStatus.deferredGpu)),
          FoodVerdict.deferred);
    });

    test('error, unsupported, or an ok without a score fail open', () {
      for (final c in [
        FoodCheck.error,
        FoodCheck.unsupported,
        const FoodCheck(FoodCheckStatus.ok),
      ]) {
        expect(foodVerdict(c), FoodVerdict.unchecked, reason: '$c');
      }
    });
  });

  group('decodeFoodCheck', () {
    test('an ok reply: the score and the best classes', () {
      final c = decodeFoodCheck({
        'status': 'ok',
        'score': 0.63,
        'top': [
          {'id': 'food', 'conf': 0.63},
          {'id': 'plate', 'conf': 0.4},
        ],
      });
      expect(c.status, FoodCheckStatus.ok);
      expect(c.score, 0.63);
      expect([for (final t in c.top) (t.id, t.conf)],
          [('food', 0.63), ('plate', 0.4)]);
    });

    test('an int score is fine', () {
      expect(decodeFoodCheck({'status': 'ok', 'score': 0}).score, 0.0);
    });

    test('the other statuses carry nothing', () {
      expect(decodeFoodCheck({'status': 'deferred_gpu', 'score': 0.9}).score,
          isNull);
      expect(decodeFoodCheck({'status': 'deferred_gpu'}).status,
          FoodCheckStatus.deferredGpu);
      expect(decodeFoodCheck({'status': 'unsupported'}).status,
          FoodCheckStatus.unsupported);
      expect(decodeFoodCheck({'status': 'error'}).status,
          FoodCheckStatus.error);
    });

    test('anything malformed is an error, so it can only fail open', () {
      for (final reply in <Object?>[
        null,
        'ok',
        42,
        const <Object?>[],
        {'status': 'maybe'},
        {'status': 'ok'},
        {'status': 'ok', 'score': '0.5'},
        {'status': 'ok', 'score': -0.1},
        {'status': 'ok', 'score': 1.5},
        {'status': 'ok', 'score': double.nan},
        {'status': 'ok', 'score': double.infinity},
        {'score': 0.5},
      ]) {
        expect(decodeFoodCheck(reply).status, FoodCheckStatus.error,
            reason: '$reply');
      }
    });

    test('bad classes are dropped, at most five kept', () {
      final c = decodeFoodCheck({
        'status': 'ok',
        'score': 0.2,
        'top': [
          {'id': 'a', 'conf': 0.9},
          {'id': '', 'conf': 0.8},
          {'id': 'b', 'conf': 2},
          {'id': 'c'},
          'junk',
          {'id': 'd', 'conf': 0.5},
          {'id': 'e', 'conf': 0.4},
          {'id': 'f', 'conf': 0.3},
          {'id': 'g', 'conf': 0.2},
          {'id': 'h', 'conf': 0.1},
        ],
      });
      expect([for (final t in c.top) t.id], ['a', 'd', 'e', 'f', 'g']);
      expect(decodeFoodCheck({'status': 'ok', 'score': 0.2, 'top': 'x'}).top,
          isEmpty);
    });
  });

  group('foodScoreViaImageIO (mocked channel)', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() {
      messenger.setMockMethodCallHandler(imageIOChannel, null);
      isHeadlessEngine = false;
      isEngineBackgrounded = () => false;
    });

    test('sends the bytes, the thumbnail size, the label table and whether '
        'the engine is in the background; decodes the reply', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(imageIOChannel, (call) async {
        seen = call;
        return {
          'status': 'ok',
          'score': 0.42,
          'top': [
            {'id': 'food', 'conf': 0.42},
          ],
        };
      });
      final bytes = Uint8List.fromList([1, 2, 3]);
      final c = await foodScoreViaImageIO(bytes);
      expect(seen!.method, 'foodScore');
      expect(seen!.arguments, {
        'bytes': bytes,
        'maxPx': kFoodCheckMaxPx,
        'labels': kFoodLabels,
        'background': false,
      });
      expect(c.status, FoodCheckStatus.ok);
      expect(c.score, 0.42);
    });

    test('the headless engine, or the app engine in the background, says '
        'so', () async {
      final sent = <Object?>[];
      messenger.setMockMethodCallHandler(imageIOChannel, (call) async {
        sent.add((call.arguments as Map)['background']);
        return {'status': 'deferred_gpu'};
      });
      isHeadlessEngine = true;
      expect((await foodScoreViaImageIO(Uint8List(1))).status,
          FoodCheckStatus.deferredGpu);
      isHeadlessEngine = false;
      isEngineBackgrounded = () => true;
      await foodScoreViaImageIO(Uint8List(1));
      isEngineBackgrounded = () => throw StateError('no lifecycle');
      await foodScoreViaImageIO(Uint8List(1));
      expect(sent, [true, true, false]);
    });

    test('no plugin in this engine → unsupported', () async {
      expect((await foodScoreViaImageIO(Uint8List(1))).status,
          FoodCheckStatus.unsupported);
    });

    test('a PlatformException → error, never a throw', () async {
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) async => throw PlatformException(code: 'boom'));
      expect((await foodScoreViaImageIO(Uint8List(1))).status,
          FoodCheckStatus.error);
    });

    testWidgets('a reply that never comes → error at the deadline',
        (tester) async {
      messenger.setMockMethodCallHandler(
          imageIOChannel, (_) => Completer<Object?>().future);
      FoodCheck? result;
      unawaited(foodScoreViaImageIO(Uint8List(1)).then((r) => result = r));
      await tester.pump(kFoodCheckTimeout);
      expect(result?.status, FoodCheckStatus.error);
    });
  });

  group('the label table', () {
    test('identifiers only, no duplicates, food in general first', () {
      expect(kFoodLabels.toSet(), hasLength(kFoodLabels.length));
      for (final id in kFoodLabels) {
        expect(RegExp(r'^[a-z][a-z_]*$').hasMatch(id), isTrue, reason: id);
      }
      expect(kFoodLabels.first, 'food');
      // What sits under a meal scores where a dish has no class of its own.
      expect(kFoodLabels, containsAll(['plate', 'bowl', 'tableware']));
      // Scenes are not food: a street or a restaurant interior is exactly
      // the casual photo the check exists to keep home.
      expect(kFoodLabels,
          isNot(anyOf(contains('restaurant'), contains('kitchen'))));
    });

    // The native side scores whatever labels it is sent, and RunnerTests
    // reads this list from food_prefilter.dart to check each against the
    // classifier's own identifiers — so the table stays in ONE place.
    test('the Swift side keeps no copy and serves the call this file makes',
        () {
      final swift =
          File('ios/Runner/ImageIOPlugin.swift').readAsStringSync();
      expect(swift, contains('"$imageIOChannelName"'));
      expect(swift, contains('case "foodScore":'));
      for (final arg in ['bytes', 'maxPx', 'labels', 'background']) {
        expect(swift, contains('args["$arg"]'), reason: arg);
      }
      for (final status in ['ok', 'deferred_gpu', 'unsupported', 'error']) {
        expect(swift, contains('"$status"'), reason: status);
      }
      expect(swift, contains('let imageIOFoodMaxPx = $kFoodCheckMaxPx'));
      expect(swift, isNot(contains('"tableware"')),
          reason: 'no second table to drift');
      // The native deadline sits inside the Dart one.
      final native = RegExp(r'let imageIOFoodTimeout: TimeInterval = ([\d.]+)')
          .firstMatch(swift)!
          .group(1)!;
      expect(double.parse(native) * 1000,
          lessThan(kFoodCheckTimeout.inMilliseconds));
      final tests =
          File('ios/RunnerTests/RunnerTests.swift').readAsStringSync();
      expect(tests, contains('lib/services/photo/food_prefilter.dart'),
          reason: 'RunnerTests checks this table against the classifier');
    });
  });
}
