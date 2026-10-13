// Byte-exact request bodies and reply extraction for the two OpenAI-style
// chat-completions backends. Field-level tests elsewhere check individual
// keys; these pin the WHOLE wire body (key order included), so a refactor
// of the shared content builder cannot shift a single byte unnoticed.
import 'dart:typed_data';

import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Future<AppSettings> _settings() async {
  SharedPreferences.setMockInitialValues({'settings.provider': 'openai'});
  final prefs = await SharedPreferences.getInstance();
  final s = await AppSettings.load(prefs: prefs, keyStore: _MemKeys());
  await s.setOpenaiModel('m-oa');
  await s.setDoubaoModel('m-db');
  await s.setGlmModel('m-gl');
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 1, 2, 3]);

  const img = 'data:image/jpeg;base64,/9j/AQID';
  String photoContent(String model) =>
      '"model":"$model","messages":[{"role":'
      '"user","content":[{"type":"text","text":"P \\"q\\""},{"type":'
      '"image_url","image_url":{"url":"$img"}}]}]';
  String textContent(String model) =>
      '"model":"$model","messages":[{"role":'
      '"user","content":[{"type":"text","text":"P"}]}]';
  const thinkingOff = '"thinking":{"type":"disabled"},';
  const jsonMode = '"response_format":{"type":"json_object"},';

  test('OpenAI: photo and text-only bodies, byte for byte', () async {
    final s = await _settings();
    final a = OpenAiAnalyzer(s);
    expect(
      a.buildRequest('k', prompt: 'P "q"', jpegBytes: jpeg, maxTokens: 9).body,
      '{${photoContent('m-oa')},$jsonMode"max_completion_tokens":9}',
    );
    expect(
      a.buildRequest('k', prompt: 'P', maxTokens: 1).body,
      '{${textContent('m-oa')},"max_completion_tokens":1}',
    );
  });

  test('compat (Doubao: extras + json mode): bodies byte for byte', () async {
    final s = await _settings();
    final a = createDoubaoAnalyzer(s);
    expect(
      a.buildRequest('k', prompt: 'P "q"', jpegBytes: jpeg, maxTokens: 9).body,
      '{$thinkingOff${photoContent('m-db')},$jsonMode"max_tokens":9}',
    );
    expect(
      a.buildRequest('k', prompt: 'P', maxTokens: 1).body,
      '{$thinkingOff${textContent('m-db')},"max_tokens":1}',
    );
  });

  test('compat (GLM: extras, no json mode): bodies byte for byte', () async {
    final s = await _settings();
    final a = createGlmAnalyzer(s);
    expect(
      a.buildRequest('k', prompt: 'P "q"', jpegBytes: jpeg, maxTokens: 9).body,
      '{$thinkingOff${photoContent('m-gl')},"max_tokens":9}',
    );
    expect(
      a.buildRequest('k', prompt: 'P', maxTokens: 1).body,
      '{$thinkingOff${textContent('m-gl')},"max_tokens":1}',
    );
  });

  test('compat thinking model: the thinking extra is dropped', () async {
    final s = await _settings();
    await s.setDoubaoModel('m-thinking');
    final a = createDoubaoAnalyzer(s);
    expect(
      a.buildRequest('k', prompt: 'P "q"', jpegBytes: jpeg, maxTokens: 9).body,
      '{${photoContent('m-thinking')},$jsonMode"max_tokens":9}',
    );
  });

  test(
    'reply extraction: same text and same failures for both classes',
    () async {
      final s = await _settings();
      for (final a in [OpenAiAnalyzer(s), createDoubaoAnalyzer(s)]) {
        Map<String, dynamic> reply(Object? content) => {
          'choices': [
            {
              'message': {'role': 'assistant', 'content': content},
            },
          ],
        };
        expect(a.extractText(reply('hi')), 'hi');
        expect(() => a.extractText(reply(null)), throwsA(isA<TypeError>()));
        expect(
          () => a.extractText({'choices': <Object>[]}),
          throwsA(isA<StateError>()),
        );
        expect(
          () => a.extractText(<String, dynamic>{}),
          throwsA(isA<TypeError>()),
        );
      }
    },
  );
}
