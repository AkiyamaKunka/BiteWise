/// The on-device food check (design G3, 2026-10-24).
///
/// Folding Meta glasses can import 20–40 casual first-person photos at
/// once — a street, a screen, a friend. Before this check every one of them
/// went to the user's AI service like a camera photo: an upload of a photo
/// that has nothing to do with food, plan usage, and minutes of a busy
/// pipeline. So an AUTOMATIC Meta glasses photo on iOS is first shown to
/// Apple's on-device image classifier (VNClassifyImageRequest, through
/// ios/Runner/ImageIOPlugin.swift foodScore). Nothing leaves the phone for
/// it, and its answer decides only one thing:
///
/// - a score below [kFoodThreshold] skips the photo as not food
///   (PhotoPipeline: reserved and tombstoned 'skipped', reason
///   'not_food_local') — the model is never asked;
/// - deferred_gpu (the classifier needs a GPU, and the app is in the
///   background): the photo waits for the foreground, exactly as a decode
///   the background engine cannot do does;
/// - error or unsupported: the photo goes on as it always did (fail open).
///   A classifier that runs but gives a black and a white frame the same
///   answer — the iOS 26.2 simulator's sees every image as black — is
///   unsupported (ImageIOBlindCheck), never "not food".
///
/// Camera photos, photos the user adds on purpose, and Android are never
/// checked. The threshold is permissive on purpose: a false "not food"
/// loses a meal, a false "food" only costs today's model call. Both the
/// labels and the threshold are first guesses until the hardware test with
/// the owner's glasses (design H1) measures real scores; the Glasses check
/// card in the diagnostics shows each photo's.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

import '../analyzer/platform_decode.dart'
    show imageIOChannel, isEngineBackgrounded, isHeadlessEngine;

/// A photo whose best food-label confidence is below this is not food.
const double kFoodThreshold = 0.10;

/// The long side of the thumbnail the classifier is shown.
const int kFoodCheckMaxPx = 360;

/// The Dart side's deadline: the native check gives up at 1.5 s
/// (imageIOFoodTimeout); this only bounds a reply that never comes.
const Duration kFoodCheckTimeout = Duration(seconds: 3);

/// The classifier's identifiers that count as food — the ONE table: the
/// native side scores the labels it is sent. Every one must be a class
/// VNClassifyImageRequest knows (RunnerTests reads this list from this file
/// and checks it against the runtime's supportedIdentifiers()).
///
/// Its own classes for food in general, then what sits under a meal
/// (a plate scores where a dish the classifier has no class for does not),
/// then dishes, ingredients and drinks.
const List<String> kFoodLabels = [
  // Food in general.
  'food', 'fruit', 'vegetable', 'dessert', 'baked_goods', 'meat', 'seafood',
  'poultry', 'drink', 'condiment', 'candy', 'frozen_dessert',
  'shellfish_prepared',
  // What sits under a meal.
  'plate', 'bowl', 'tableware', 'chopsticks',
  // Dishes, ingredients, drinks.
  'almond', 'anchovy', 'antipasti', 'apple', 'apricot', 'artichoke',
  'arugula', 'asparagus', 'avocado', 'bacon', 'bagel', 'baklava', 'banana',
  'bean', 'beef', 'beer', 'beet', 'bell_pepper', 'berry', 'biryani',
  'birthday_cake', 'biscotti', 'biscuit', 'blackberry', 'blueberry', 'bread',
  'broccoli', 'brownie', 'bruschetta', 'bubble_tea', 'burrito', 'butter',
  'cake', 'cake_regular', 'cantaloupe', 'caprese', 'caramel', 'carrot',
  'cashew', 'casserole', 'cauliflower', 'celery', 'cereal', 'cheese',
  'cheesecake', 'cherry', 'chestnut', 'chocolate', 'chocolate_chip',
  'citrus_fruit', 'clam', 'cocktail', 'coconut', 'coffee', 'coleslaw',
  'cookie', 'corn', 'crab', 'cranberry', 'crepe', 'croissant', 'cucumber',
  'cupcake', 'curry', 'daikon', 'donut', 'dumpling', 'durian', 'edamame',
  'egg', 'eggplant', 'falafel', 'fig', 'flan', 'fondue', 'fried_chicken',
  'fried_egg', 'fries', 'fruitcake', 'gingerbread', 'grape', 'grapefruit',
  'green_beans', 'grilled_chicken', 'guacamole', 'guava', 'gyoza', 'ham',
  'hamburger', 'honey', 'honeydew', 'hotdog', 'hummus', 'ice_cream',
  'jalapeno', 'jello', 'jelly', 'juice', 'kebab', 'kiwi', 'lemon', 'lettuce',
  'lime', 'liquor', 'lobster', 'lollipop', 'lychee', 'macadamia', 'mandarine',
  'mango', 'mangosteen', 'margarita', 'marshmallow', 'martini', 'matzo',
  'meatball', 'melon', 'milkshake', 'mojito', 'muffin', 'mushroom', 'mussel',
  'naan', 'nachos', 'nectarine', 'nut', 'oatmeal', 'omelet', 'onion',
  'oranges', 'oyster', 'paella', 'pancake', 'papaya', 'passionfruit', 'pasta',
  'pastry', 'pea', 'peach', 'peanut', 'pear', 'pecan', 'pepper_veggie',
  'pepperoni', 'persimmon', 'pickle', 'pie', 'pierogi', 'pineapple',
  'pistachio', 'pita', 'pizza', 'plum', 'pomegranate', 'popcorn', 'popsicle',
  'potato', 'pretzel', 'pudding', 'pumpkin', 'quesadilla', 'quinoa', 'radish',
  'rambutan', 'ramen', 'raspberry', 'red_wine', 'rice', 'risotto', 'roe',
  'salad', 'salami', 'salmon', 'samosa', 'sandwich', 'sangria', 'sardine',
  'satay', 'sauerkraut', 'sausage', 'scallop', 'scone', 'scrambled_eggs',
  'seaweed', 'shawarma', 'smoothie', 'soda', 'souffle', 'soup', 'souvlaki',
  'spaghetti', 'spareribs', 'sparkling_wine', 'spinach', 'springroll',
  'starfruit', 'steak', 'stir_fry', 'strawberry', 'strudel', 'sushi',
  'tabbouleh', 'taco', 'taffy', 'tapas', 'tapioca_pearls', 'taro',
  'tea_drink', 'tempura', 'teriyaki', 'tiramisu', 'tomato', 'tortilla',
  'waffle', 'wasabi', 'watermelon', 'wedding_cake', 'white_bread',
  'white_wine', 'wine', 'wonton', 'yogurt', 'yolk', 'zucchini',
];

/// What the native check answered.
enum FoodCheckStatus { ok, deferredGpu, unsupported, error }

/// One class the classifier scored.
class FoodClass {
  const FoodClass(this.id, this.conf);
  final String id;

  /// 0–1.
  final double conf;

  @override
  String toString() => 'FoodClass($id, $conf)';
}

/// One check's answer.
class FoodCheck {
  const FoodCheck(this.status, {this.score, this.top = const []});

  final FoodCheckStatus status;

  /// The best confidence over [kFoodLabels], 0–1; set only with
  /// [FoodCheckStatus.ok].
  final double? score;

  /// The best classes of any kind, best first (for the diagnostics).
  final List<FoodClass> top;

  static const error = FoodCheck(FoodCheckStatus.error);
  static const unsupported = FoodCheck(FoodCheckStatus.unsupported);

  @override
  String toString() => 'FoodCheck(${status.name}, $score)';
}

/// What a check means for the photo.
enum FoodVerdict {
  /// Looks like food: on to the model, as before.
  food,

  /// Does not: skipped without asking the model.
  notFood,

  /// Could not run here (background, no CPU path): wait for the foreground.
  deferred,

  /// No answer: the photo goes on as if there were no check (fail open).
  unchecked,
}

/// [check]'s verdict against [threshold].
FoodVerdict foodVerdict(FoodCheck check, {double threshold = kFoodThreshold}) {
  final score = check.score;
  return switch (check.status) {
    FoodCheckStatus.ok when score != null =>
      score < threshold ? FoodVerdict.notFood : FoodVerdict.food,
    FoodCheckStatus.deferredGpu => FoodVerdict.deferred,
    _ => FoodVerdict.unchecked,
  };
}

/// The channel's reply as a [FoodCheck]. Anything malformed — a status it
/// does not know, an ok without a score, a score outside 0–1 — is
/// [FoodCheck.error], so it can only ever fail open. Never throws.
FoodCheck decodeFoodCheck(Object? reply) {
  try {
    if (reply is! Map) return FoodCheck.error;
    final status = switch (reply['status']) {
      'ok' => FoodCheckStatus.ok,
      'deferred_gpu' => FoodCheckStatus.deferredGpu,
      'unsupported' => FoodCheckStatus.unsupported,
      _ => FoodCheckStatus.error,
    };
    if (status != FoodCheckStatus.ok) return FoodCheck(status);
    final raw = reply['score'];
    if (raw is! num) return FoodCheck.error;
    final score = raw.toDouble();
    if (!score.isFinite || score < 0 || score > 1) return FoodCheck.error;
    final top = <FoodClass>[
      if (reply['top'] case final List list)
        for (final e in list)
          if (e case {
            'id': final String id,
            'conf': final num conf,
          } when id.isNotEmpty && conf.isFinite && conf >= 0 && conf <= 1)
            FoodClass(id, conf.toDouble()),
    ];
    return FoodCheck(
      FoodCheckStatus.ok,
      score: score,
      top: top.length > 5 ? top.sublist(0, 5) : top,
    );
  } catch (_) {
    return FoodCheck.error;
  }
}

/// Whether this engine is in the background right now: the headless
/// background run always is, the app's own engine when iOS says so. The
/// native side also asks UIApplication itself; either is enough.
bool _engineInBackground() {
  if (isHeadlessEngine) return true;
  try {
    return isEngineBackgrounded();
  } catch (_) {
    return false;
  }
}

/// The native food check of [bytes] (ImageIOPlugin.swift foodScore). No
/// plugin in this engine is [FoodCheck.unsupported]; a failure, a reply
/// past [timeout] or a malformed one is [FoodCheck.error]. Never throws.
Future<FoodCheck> foodScoreViaImageIO(
  Uint8List bytes, {
  MethodChannel channel = imageIOChannel,
  Duration timeout = kFoodCheckTimeout,
  bool? background,
}) async {
  try {
    final reply = await channel
        .invokeMethod<Object?>('foodScore', {
          'bytes': bytes,
          'maxPx': kFoodCheckMaxPx,
          'labels': kFoodLabels,
          'background': background ?? _engineInBackground(),
        })
        // Re-typed first, so the timeout's null fits (orNullAfter's note).
        .then<Object?>((v) => v)
        .timeout(timeout, onTimeout: () => null);
    return decodeFoodCheck(reply);
  } on MissingPluginException {
    return FoodCheck.unsupported;
  } catch (_) {
    return FoodCheck.error;
  }
}
