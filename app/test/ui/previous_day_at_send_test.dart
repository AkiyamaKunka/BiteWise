// Run 7 (B14): a photo taken before 04:00 also offers the day before's
// meals to the leftover check, but only to a recipient allowed under the
// consent text that says so (AppSettings.previousDayLeftoverContext). The
// pipeline decides that AT the send, in the same turn as the AI consent
// check and the analyzer call: a provider switch while the meals are read
// must not carry the day before's meals to a recipient allowed only under
// the older text.

import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/background_glue.dart' show aiSendGateFor;
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

class _MemKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class _HookDao extends FakeDao {
  Future<void> Function()? duringMealsRead;
  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) async {
    final hook = duringMealsRead;
    duringMealsRead = null;
    if (hook != null) await hook();
    return super.mealsBetween(startDate, endDate);
  }
}

Future<AppSettings> _settings() async {
  SharedPreferences.setMockInitialValues({
    // gemini allowed under the current text (v2), openai only under v1.
    'settings.ai_consent_routes': <String>['gemini', 'openai'],
    'settings.ai_consent_versions': <String>['gemini=2'],
    'settings.provider': 'gemini',
  });
  final s = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
  await s.setGeminiApiKey('k');
  await s.setOpenaiApiKey('k2');
  return s;
}

_HookDao _daoWithLateDinner() => _HookDao()
  ..put(const Meal(
    id: 21,
    date: '2026-10-29',
    time: '11:20 PM',
    timestamp: '2026-10-29T23:21:00',
    source: 'app_watch',
    imageHash: 'orig-21',
    analysis: {
      'is_food': true,
      'meal_description': 'Hotpot',
      'total_calories': 1200,
    },
  ));

Future<(String?, List<String>?)> _run(AppSettings s, _HookDao dao) async {
  String? routeAtSend;
  final analyzer = FakeAnalyzer()
    ..nextPhotoOutcome = const AnalysisOutcome(
        analysis: {'is_food': false}, isFood: false, wall: Duration.zero);
  analyzer.onAnalyze = () async => routeAtSend = s.activeAiConsentRoute;
  // Wired as di.dart wires the app's pipeline.
  final pipeline = PhotoPipeline(
    dao: dao,
    analyzer: analyzer,
    previousDayContext: () => s.previousDayLeftoverContext,
    sendGate: aiSendGateFor(s),
    hasher: (_) async => 'h-0010',
    thumbnailer: (_) async => null,
  );
  await pipeline.process(IntakePhoto(
      Uint8List.fromList([7]), 'w3', 'IMG_9.jpg',
      capturedAt: DateTime(2026, 10, 30, 0, 10)));
  return (
    routeAtSend,
    analyzer.lastRecentMeals
        ?.map((m) => '${m['meal_description']}')
        .toList(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a recipient allowed under the current text gets the day before\'s '
      'meals with a photo taken at 00:10', () async {
    final s = await _settings();
    expect(s.previousDayLeftoverContext, isTrue);
    final (route, sent) = await _run(s, _daoWithLateDinner());
    expect(route, 'gemini');
    expect(sent, ['Hotpot']);
  });

  test('a switch to a recipient allowed only under the older text while '
      'the meals are read: the photo goes without the day before\'s '
      'meals', () async {
    final s = await _settings();
    expect(s.aiConsentVersion('openai'), 1);
    final dao = _daoWithLateDinner()
      // Settings > AI Provider > OpenAI lands during the read; openai
      // already has a grant, so confirmAiRecipientChange asks nothing.
      ..duringMealsRead = () => s.setProvider(AiProvider.openai);
    final (route, sent) = await _run(s, dao);
    expect(route, 'openai');
    expect(sent, isNot(contains('Hotpot')),
        reason: 'openai was allowed only under the older text: the day '
            "before's meals wait for its Allow");
  });
}
