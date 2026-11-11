// Production wiring gate (2026-10-19).
//
// The background-scan fixes are unit-tested through seams, but the lines
// that hand those seams to production are not: a mutation run on a scratch
// copy dropped `passOver:` in createPhotoIntake, `deferred:` in
// runHeadlessBackfill, the foreground catch-up in di.dart and app.dart, the
// iOS BackgroundTime and the deferred-asset clearing — and the whole suite
// stayed green each time. Dropping either of the first two silently turned
// "one undecodable photo cannot freeze the scan" off on the phone.
//
// AppServices.init and runHeadlessBackfill's pipeline open real plugins
// (sqflite, photo_manager), so where no behavioural test can reach, these
// pins read the source the way manifest_gate_test reads the Xcode project.
// Whitespace and trailing commas are free; the wiring is not.
import 'dart:io';

import 'package:calorie_tracker/services/photo/photo_changes.dart'
    show recordLateImportPass;
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

String _source(String path) =>
    File('${_appRoot().path}/$path').readAsStringSync();

/// The body of the top-level or member function [name] in [source]: from
/// its declaration to the next line that closes at column [indent].
String _body(String source, String declaration, {String indent = ''}) {
  final start = source.indexOf(declaration);
  expect(start, isNot(-1), reason: '"$declaration" not found');
  final end = source.indexOf('\n$indent}\n', start);
  expect(end, isNot(-1), reason: 'no end for "$declaration"');
  return source.substring(start, end);
}

/// [pattern] with every run of spaces in it allowed to be any whitespace,
/// and an optional trailing comma before each closing parenthesis.
Matcher _wired(String pattern) => matches(
  RegExp(pattern.replaceAll(' ', r'\s*').replaceAll(r'\)', r',?\s*\)')),
);

/// The one call in [source] that starts with [opening] ('Name('), through
/// its matching parenthesis.
String _call(String source, String opening) {
  expect(opening.allMatches(source), hasLength(1), reason: opening);
  final start = source.indexOf(opening);
  var depth = 0;
  for (var i = start + opening.length - 1; i < source.length; i++) {
    if (source[i] == '(') depth++;
    if (source[i] == ')' && --depth == 0) {
      return source.substring(start, i + 1);
    }
  }
  fail('no end for "$opening"');
}

void main() {
  group('lib/ui/di.dart (the app engine)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('iOS gives each photo background time and holds automatic photos '
        'while the app is in the background', () {
      expect(
        init(),
        _wired(
          r'backgroundTime: Platform\.isIOS \? const BackgroundTime\(\) : null',
        ),
      );
      expect(
        init(),
        _wired(
          r'backgrounded: Platform\.isIOS \? appEngineBackgrounded : null',
        ),
      );
      expect(
        init(),
        _wired(
          r'if \(Platform\.isIOS\) \{[^}]*isEngineBackgrounded = '
          r'appEngineBackgrounded;',
        ),
      );
    });

    test(
      'a verdict here forgets a photo the background run kept deferring',
      () {
        expect(
          init(),
          _wired(
            r'onOutcome: \(photo, o\) \{\s*if \(!o\.retryable && '
            r'o\.kind != PhotoOutcomeKind\.alreadyTracked\) \{\s*'
            r'unawaited\(clearDeferredAsset\(photo\.assetId\)\);',
          ),
        );
      },
    );

    test('the launch catch-up is foregroundCatchUp (it moves the background '
        'watermark), stopping on iOS once the app is left', () {
      expect(
        init(),
        _wired(
          r'foregroundCatchUp\(photoIntake, shouldContinue: '
          r'Platform\.isIOS \? appEngineInForeground : null\)',
        ),
      );
      expect(
        init(),
        isNot(contains('.backfillScan(')),
        reason: 'a bare backfillScan leaves the watermark days behind',
      );
    });

    test('the stuck probe reads the runs and the watermark together', () {
      expect(init(), _wired(r'backgroundScanStuck: backgroundScanStuckNow,'));
    });

    // G2b: without it every glasses preview copy is analyzed at once.
    test('a glasses preview copy waits once for its full-size one', () {
      expect(init(), _wired(r'previewHold: holdGlassesPreview,'));
    });

    // G3: without them a switched-off glasses photo is still logged, an
    // iPhone uploads every casual glasses frame, and the Glasses check
    // card stays empty.
    test('glasses photos: the live switch, the iOS food check, the record',
        () {
      expect(init(), _wired(r'includeGlasses: \(\) => settings\.watchGlasses,'));
      expect(
        init(),
        _wired(r'foodCheck: Platform\.isIOS \? foodScoreViaImageIO : null,'),
      );
      expect(init(), _wired(r'glassesCheckLog: recordGlassesCheckLocally\)'));
    });

    // G1b: without it every late import is read in full, logged or not.
    test('late imports skip photos a meal already names, without a read', () {
      expect(
        init(),
        _wired(
          r'createPhotoIntake\(settings, loggedAssetIds: dao\.loggedAssetIds\)',
        ),
      );
    });
  });

  // R6b: the restaurant assist lives in the app engine, reads the real
  // pipeline, analyzer and registry, counts against the app's daily ledger,
  // and looks once the launch catch-up's photos are in.
  group('the restaurant assist (MealAssist)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('di.dart builds it from the real pipeline, analyzer and registry',
        () {
      expect(
        init(),
        _wired(
          r'final analyzer = MultiProviderAnalyzer\(settings, '
          r'lookupBudget: assistBudget\);',
        ),
      );
      expect(
        init(),
        _wired(
          r'final assistBudget = AssistDailyBudget\('
          r'await SharedPreferences\.getInstance\(\)\);',
        ),
      );
      final source = init();
      final from = source.indexOf('final mealAssist = MealAssist(');
      expect(from, isNot(-1));
      final build = source.substring(from, source.indexOf('\n    );\n', from));
      for (final wire in [
        r'dao: dao,',
        r'lookups: analyzer,',
        r'analyzerBusy: analyzer\.analyzerBusy,',
        r'pipelineIdle: \(\) => pipeline\.isIdle,',
        r'inUse: mealInUse\.isInUse,',
        r'budget: assistBudget,',
        r'state: AssistLocalState\.platform\(\),',
        r'mealsChanged: mealsChangedSignal,',
        r'onMealsChanged: signalMealsChanged,',
        r'inForeground: appEngineInForeground,',
        // The region: the locale name's, else the preferred languages'
        // (review 2026-10-25: a region-less 'zh_Hans' read as not the US).
        r'country: \(\) => deviceRegion\( Platform\.localeName, '
            r'PlatformDispatcher\.instance\.locales\.map\(\(l\) => '
            r'l\.countryCode\) \),',
        r'repliesInChinese: \(\) => settings\.repliesInChinese,',
        // R6c: the location path is iOS only; Android is brand-only.
        r'location: Platform\.isIOS \? PhotoLocationReader\(photoLibrary\) '
            r': null,',
        r'places: Platform\.isIOS \? MapKitPlaces\(\) : null,',
        r'placesStore: AssistPlacesStore\.platform\(\),',
        // R7a: the mode, 'Use photo location' and the consent, read fresh
        // from the real settings on every decision (through the one view
        // usual foods reads too, pinned below).
        r'settings: assistSettingsView,',
      ]) {
        expect(build, _wired(wire), reason: wire);
      }
      expect(
        source,
        _wired(
          r'AssistSettingsView assistSettingsView\(\) => AssistSettingsView\( '
          r'mode: AssistMode\.fromWire\(settings\.restaurantAssist\), '
          r'useLocation: settings\.restaurantAssistLocation, '
          r'consentAt: settings\.restaurantAssistConsentAt, '
          r'consentRecipient: settings\.restaurantAssistConsentRecipient, '
          r'\);',
        ),
      );
      // The meal country's time zone is the phone's own (MealAssist's
      // default, DateTime.now().timeZoneOffset): di passes no other.
      expect(build, isNot(contains('utcOffset')));
      expect(build, isNot(contains('AssistSettingsView.off')),
          reason: 'R7a stores the settings: the assist reads them');
      // R7a: Settings' Restaurant nutrition group and the consent sheets
      // see the same analyzer, MealAssist and server; the location only on
      // iOS; and the shell gets them through UiServices.
      final controlsAt = source.indexOf(
          'final restaurantAssist = RestaurantAssistControls(');
      expect(controlsAt, isNot(-1));
      final controls = source.substring(
          controlsAt, source.indexOf('\n    );\n', controlsAt));
      for (final wire in [
        r'lookupSupport: analyzer\.lookupSupport,',
        r'clearLearnedPlaces: mealAssist\.clearLearnedPlaces,',
        r'consentNeeded: mealAssist\.consentNeeded,',
        r'serverState: \(\) async => '
            r'assistServerStateOf\(await serverAnalyzer\.serverFeatures\(\)\),',
        r'locationSupported: Platform\.isIOS,',
        // Review (run 6): Settings says why nothing would be looked up.
        r'whereNow: mealAssist\.whereNow,',
      ]) {
        expect(controls, _wired(wire), reason: wire);
      }
      expect(init(), _wired(r'restaurantAssist: restaurantAssist,'));
      expect(init(), _wired(r'mealAssist\.start\(\);'));
      expect(
        init(),
        _wired(
          r'foregroundCatchUp\(photoIntake, shouldContinue: '
          r'Platform\.isIOS \? appEngineInForeground : null\) '
          r'\.whenComplete\(\(\) => unawaited\(mealAssist\.sweep\(\)\)\)',
        ),
      );
      expect(init(), _wired(r'if \(!catchingUp\) unawaited\(mealAssist\.sweep\(\)\);'));
    });

    test('background_glue.dart never references it, and its PhotoPipeline '
        'is built as before', () {
      final glue = _source('lib/ui/background_glue.dart');
      for (final banned in [
        'MealAssist',
        'meal_assist',
        'assist_local_state',
        'AssistDailyBudget',
        'lookupNow',
        'services/assist/',
        // R6c: no photo position or places query in the background engine.
        'PhotoLocationReader',
        'photo_location',
        'MapKitPlaces',
        'PlaceResolver',
        'services/places/',
        'AssistPlacesStore',
        // R7a: no consent sheet, Settings group or their seams either.
        'RestaurantAssistControls',
        'restaurant_assist_controls',
        'restaurant_consent_sheet',
      ]) {
        expect(glue, isNot(contains(banned)), reason: banned);
      }
      final after = _body(glue, 'Future<bool> _runAfterLaunch({');
      expect(
        after,
        _wired(r'pipeline: \(\) async => inFlight\.pipeline = PhotoPipeline\('),
      );
      expect(after, _wired(r'analyzer: createMultiProviderAnalyzer\(settings\),'));
    });

    test('the pipeline constructor takes nothing from the assist', () {
      final pipeline = _source('lib/ui/photo_pipeline.dart');
      final from = pipeline.indexOf('\n  PhotoPipeline(\n');
      expect(from, isNot(-1));
      final ctor = pipeline.substring(
          from, pipeline.indexOf('_clock = clock ?? DateTime.now;', from));
      expect(ctor, isNot(contains('ssist')));
      expect(pipeline, isNot(contains('meal_assist')));
      expect(pipeline, contains('bool get isIdle =>'));
    });
  });

  // The owner's requirement before PR #19 ships (docs/RELEASING.md):
  // Settings › Stop Sharing with … says "nothing more is sent to …", so it
  // also stops the restaurant assist when its lookups go to that recipient.
  // The behaviour is tested through fakes and the real settings
  // (restaurant_assist_settings_test, stop_sharing_assist_test,
  // meal_assist_test). These pin the lines that make it true in the app:
  // another branch rewrites settings_screen.dart, and a merge that kept the
  // wrong side of these lines would leave lookups running after the stop.
  group('Stop Sharing also stops the restaurant assist', () {
    String stopSharing() => _body(
      _source('lib/ui/screens/settings_screen.dart'),
      'Future<void> _stopSharing() async {',
      indent: '  ',
    );

    test('the row stops the assist first, then withdraws the AI consent: '
        'nothing awaited before, nothing skipped in between', () {
      final body = stopSharing();
      final confirmed = body.indexOf('if (stop != true || !mounted) return;');
      expect(confirmed, isNot(-1));
      final after = body.substring(confirmed);
      final assist = RegExp(
        r'await\s+stopRestaurantAssistFor\(\s*s,\s*widget\.restaurantAssist,'
        r'\s*route,?\s*\);',
      ).firstMatch(after);
      final consent = RegExp(
        r'await\s+s\.setAiConsent\(\s*route,\s*granted:\s*false,?\s*\);',
      ).firstMatch(after);
      expect(assist, isNotNull, reason: 'the assist is stopped');
      expect(consent, isNotNull, reason: 'the AI consent is withdrawn');
      // No lookup reads the AI consent: only the assist's own mode and
      // consent stop one, so they go first.
      expect(assist!.start, lessThan(consent!.start));
      // The route is read after the dialog, and the assist's write starts
      // with nothing awaited before it: the settings say Off at once.
      final before = after.substring(0, assist.start);
      expect(before, _wired(r'final route = currentAiConsentRoute\(s\);'));
      expect(before, isNot(contains('await')));
      // A stop that began is finished: no way out between the two steps.
      final between = after.substring(assist.end, consent.start);
      expect(between, isNot(contains('return')));
      expect(between, isNot(contains('mounted')));
      expect(between, isNot(contains('await')));
      // The dialog says what will happen, from the same rule.
      expect(
        body.substring(0, confirmed),
        _wired(
          r'restaurantAssistStopFor\( s, widget\.restaurantAssist, '
          r'currentAiConsentRoute\(s\)\) \.turnOff;',
        ),
      );
    });

    test('nothing else withdraws an AI consent: the only call is the '
        "row's", () {
      final lib = Directory('${_appRoot().path}/lib');
      final withdrawals = <String>[];
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final found = RegExp(
          r'granted:\s*false',
        ).allMatches(file.readAsStringSync()).length;
        for (var i = 0; i < found; i++) {
          withdrawals.add(file.path.substring(lib.parent.path.length + 1));
        }
      }
      expect(withdrawals, ['lib/ui/screens/settings_screen.dart']);
      expect(stopSharing(), contains(RegExp(r'granted:\s*false')));
    });

    test('the engine sends through one poll and one submit, each behind '
        'the consent read again with nothing awaited in between', () {
      final source = _source('lib/services/assist/meal_assist.dart');
      expect('_lookups.poll('.allMatches(source), hasLength(1));
      expect('_lookups.submit('.allMatches(source), hasLength(1));
      const submit =
          'outcome = await _submit(request, settings, support, token);';
      expect(submit.allMatches(source), hasLength(2));
      expect('_submit('.allMatches(source), hasLength(3),
          reason: 'its declaration and the two calls in _run');
      // The check is the gate's own consent rule on freshly read settings.
      expect(
        source,
        _wired(
          r'bool _maySend\(int gen, LookupSupport support, '
          r'\{required bool manual\}\) => '
          r'_current\(gen, manual: manual\) && '
          r'_readSettings\(\)\.consentCovers\(support\);',
        ),
      );

      final run = _body(source, 'Future<_Run> _run(', indent: '  ');
      const check =
          r'if \(!_maySend\(gen, support, manual: manual\)\) '
          r'return _Run\.cancelled;';
      // Right before the send: the check, then the token, then the call.
      final send = RegExp(
        '$check\\s*final token = LookupCancelToken\\(\\);',
      ).firstMatch(run);
      expect(send, isNotNull, reason: 'the check at the send');
      const poll = 'outcome = await _lookups.poll(jobId);';
      expect(poll.allMatches(run), hasLength(1));
      expect(
        run.indexOf('await', send!.end),
        run.indexOf(poll) + 'outcome = '.length,
        reason: 'nothing is awaited between the check and the poll',
      );
      // A job the server lost is sent again only behind the same check,
      // and a refused resubmit ends the run as cancelled.
      expect(
        run,
        contains(
          RegExp(
            'if \\(outcome\\.needsResubmit\\) \\{(\\s*//[^\\n]*)*\\s*$check'
            '\\s*polled = false;\\s*${RegExp.escape(submit)}',
          ),
        ),
      );
      // The first submit follows the same check with nothing awaited: it
      // is the other branch of the poll.
      expect(
        run,
        contains(RegExp('\\} else \\{\\s*${RegExp.escape(submit)}\\s*\\}')),
      );
      // Every submit and the poll come after the check at the send.
      expect(run.indexOf(submit), greaterThan(send.end));
      expect(run.indexOf(poll), greaterThan(send.end));
    });

    // Without the controls the row cannot tell who a lookup reaches, and
    // fails closed (the assist goes Off whenever it is on).
    test('the app shell hands the assist to the Settings screen', () {
      final screen = _call(_source('lib/ui/app.dart'), 'SettingsScreen(');
      expect(screen, _wired(r'settings: s\.settings,'));
      expect(screen, _wired(r'restaurantAssist: s\.restaurantAssist,'));
    });
  });

  // Usual foods (spec T47, Lane C): worked out on the phone, app engine
  // only. The behaviour of usualLookupTakesIt is tested per branch in
  // usual_foods_test; these pin the lines that hand it the real settings
  // and lookup support, and keep the background engine and the photo
  // pipeline free of it.
  group('usual foods', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('di.dart builds one UsualFoods over one UsualChoices, with the '
        'lookup rule, and hands it to the screens', () {
      final di = _source('lib/ui/di.dart');
      expect('UsualFoods('.allMatches(di), hasLength(1));
      expect('UsualChoices('.allMatches(di), hasLength(1));
      final build = _call(init(), 'UsualFoods(');
      for (final wire in [
        r'dao: dao,',
        r'choices: UsualChoices\(await SharedPreferences\.getInstance\(\)\),',
        r'mealsChanged: mealsChangedSignal,',
        r'onMealsChanged: signalMealsChanged,',
        // Off decides first: the lookup client is not asked who a lookup
        // would reach (that builds it) while lookups are off.
        r'lookupTakesIt: \(analysis\) \{ '
            r'final view = assistSettingsView\(\); '
            r'if \(view\.mode == AssistMode\.off\) return false; '
            r'return usualLookupTakesIt\(analysis, '
            r'settings: view, support: analyzer\.lookupSupport\(\)\); '
            r'\},',
      ]) {
        expect(build, _wired(wire), reason: wire);
      }
      expect(build, isNot(contains('clock')),
          reason: 'the device clock, as every other service');
      expect(init(), _wired(r'usualFoods: usualFoods,'));
      final today = _call(_source('lib/ui/app.dart'), 'TodayScreen(');
      expect(today, _wired(r'usual: s\.usualFoods\)'));
    });

    test('background_glue.dart never references it, and the photo '
        'pipeline takes nothing from it', () {
      final glue = _source('lib/ui/background_glue.dart');
      for (final banned in [
        'services/usual',
        'usual_foods',
        'usual_choices',
        'UsualFoods',
        'UsualChoices',
        'usualLookupTakesIt',
      ]) {
        expect(glue, isNot(contains(banned)), reason: banned);
      }
      final pipeline = _source('lib/ui/photo_pipeline.dart');
      expect(pipeline, isNot(contains('sual')));
      final from = pipeline.indexOf('\n  PhotoPipeline(\n');
      expect(from, isNot(-1));
      final ctor = pipeline.substring(
          from, pipeline.indexOf('_clock = clock ?? DateTime.now;', from));
      expect(ctor, isNot(contains('sual')));
    });
  });

  group('lib/ui/app.dart (the resume catch-up)', () {
    test('is foregroundCatchUp, stopping on iOS once the app is left', () {
      final resume = _body(
        _source('lib/ui/app.dart'),
        'Future<void> _resumeCatchUp() async {',
        indent: '  ',
      );
      expect(
        resume,
        _wired(
          r'foregroundCatchUp\(intake, shouldContinue: '
          r'Platform\.isIOS \? appEngineInForeground : null\)',
        ),
      );
      expect(resume, isNot(contains('.backfillScan(')));
    });
  });

  // App Store 5.1.2(i), review run 7: a shared photo waits for the AI
  // consent through this gate. PR #19 rewrites the same line, and a merge
  // that keeps its side would send shared photos unasked with every
  // behavioural test still green (they drive the gate directly).
  group('lib/ui/di.dart (the AI consent for shared photos)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('a shared photo goes through the gate, built on the app\'s own '
        'store and handed to the app shell', () {
      expect(
        init(),
        _wired(
          r'pipeline\.bindStream\(shareConsent\.gate\('
          r'shareIntake\.photos\(\)\)\);',
        ),
      );
      expect(
        init(),
        isNot(_wired(r'bindStream\(shareIntake\.photos\(\)\)')),
        reason: 'no second, ungated subscription to the share sheet',
      );
      expect(
        init(),
        _wired(r'final shareConsent = SharedPhotoConsentGate\(store\);'),
      );
      expect(init(), _wired(r'\n\s*settings: store,'));
      expect(init(), _wired(r'\n\s*sharedPhotoConsent: shareConsent,'));
    });
  });

  // Release-candidate review of 1.6.0: an admitted photo can still be
  // queued when Stop Sharing is confirmed or the provider changes, so both
  // engines' pipelines read the consent again at the send (AiSendGate;
  // behaviour in test/ui/ai_send_gate_test.dart, which builds its own
  // pipelines). Dropping either line below sends those photos again with
  // every behavioural test still green.
  group('the AI consent is read again at the send', () {
    test('the app engine: over its own settings, never re-read from disk',
        () {
      final init = _body(
        _source('lib/ui/di.dart'),
        'static Future<AppServices> init(',
        indent: '  ',
      );
      expect(init, _wired(r'\n\s*sendGate: aiSendGateFor\(settings\),'));
    });

    test('the background run: re-read from disk before each send', () {
      final after = _body(
        _source('lib/ui/background_glue.dart'),
        'Future<bool> _runAfterLaunch({',
      );
      expect(
        after,
        _wired(
          r'\n\s*sendGate: aiSendGateFor\(settings, rereadFromDisk: true\),',
        ),
      );
    });

    test('the adapter: the active recipient is allowed, or no key is set; '
        'a disk re-read only on request', () {
      // An expression-bodied function: from its name to its semicolon.
      final glue = _source('lib/ui/background_glue.dart');
      final from = glue.indexOf('AiSendGate aiSendGateFor(');
      expect(from, isNot(-1));
      final expr = glue.substring(from, glue.indexOf(';', from) + 1);
      expect(
        expr,
        _wired(
          r"allowed: \(\) => \(settings\.activeApiKey \?\? ''\)\.trim\(\)"
          r'\.isEmpty \|\| settings\.hasAiConsent\('
          r'settings\.activeAiConsentRoute\),',
        ),
      );
      expect(
        expr,
        _wired(r'refresh: rereadFromDisk \? settings\.reloadAiConsent : null,'),
      );
    });

    test('the pipeline: from the last check to the analyzer call nothing '
        'awaits, and a held verdict is exempt at both checks', () {
      final pipeline = _source('lib/ui/photo_pipeline.dart');
      final process = _body(
        pipeline,
        'Future<PhotoOutcome> _process(IntakePhoto photo,',
        indent: '  ',
      );
      // Early: before the photo is hashed or reserved.
      final early = process.indexOf(
        'if (held == null && !_sendAllowed()) return _notAllowed;',
      );
      expect(early, isNot(-1));
      expect(early, lessThan(process.indexOf('await _hash(photo.bytes)')));
      expect(early, lessThan(process.indexOf('dao.reservePhotoHash(')));
      // At the send: the disk re-read, then the check, then the call.
      final refresh = process.indexOf(
        'if (held == null) await _refreshSendGate();',
      );
      final late = process.indexOf(
        'if (held == null && !_sendAllowed()) {',
      );
      final send = process.indexOf('await analyzer.analyzePhoto(');
      expect(refresh, isNot(-1));
      expect(late, greaterThan(refresh));
      expect(send, greaterThan(late));
      expect(
        process.indexOf('analyzer.analyzePhoto('),
        process.lastIndexOf('analyzer.analyzePhoto('),
        reason: 'one send in the pipeline',
      );
      final blocked = process.indexOf('return _notAllowed;', late);
      final afterBranch = process.indexOf('}', blocked) + 1;
      expect(blocked, inInclusiveRange(late, send));
      expect(
        process.substring(afterBranch, send),
        isNot(contains('await')),
        reason: 'a consent withdrawn in between would not be seen',
      );
    });
  });

  group('lib/ui/background_glue.dart (the headless run)', () {
    String glue() => _source('lib/ui/background_glue.dart');
    String launch() => _body(glue(), 'Future<bool> runHeadlessBackfill({');
    String after() => _body(glue(), 'Future<bool> _runAfterLaunch({');

    test('the intake passes over what the run deferred too often, and the '
        'run notes what it defers', () {
      expect(
        after(),
        _wired(
          r'intake: createPhotoIntake\(settings, onBackfillListed: '
          r'recorder\.listed, passOver: deferred\.passOver, '
          r'loggedAssetIds: inFlight\.loggedAssetIds\)',
        ),
      );
      expect(after(), _wired(r'\n\s*deferred: deferred,'));
      expect(
        after(),
        _wired(
          r'final deferred = inFlight\.deferred = await DeferredAssets\.load\(prefs\);',
        ),
      );
    });

    test('iOS: undecodable photos are deferred, the offer budget applies, '
        'and the deadline releases the photo in flight', () {
      expect(after(), _wired(r'deferUndecodable: ios\)'));
      // G2b: a glasses preview copy waits once there too.
      expect(after(), _wired(r'previewHold: holdGlassesPreview, '));
      // G3: the switch as the run loaded it, the food check on iOS (on the
      // CPU, or deferred to the app), and the Glasses check record.
      expect(
          after(), _wired(r'includeGlasses: \(\) => settings\.watchGlasses, '));
      expect(after(), _wired(r'foodCheck: ios \? foodScoreViaImageIO : null, '));
      expect(after(), _wired(r'glassesCheckLog: recordGlassesCheckLocally, '));
      expect(after(), _wired(r'budget: ios \? iosBackgroundBudget : null,'));
      expect(
        after(),
        _wired(r'pipeline: \(\) async => inFlight\.pipeline = PhotoPipeline\('),
      );
      expect(
        launch(),
        _wired(
          r'return finishWithinGrant\(run, left: startedAt\.add\(iosRunDeadline\)'
          r'\.difference\(clock\(\)\), recorder: recorder, abandon: inFlight\.abandon\);',
        ),
      );
    });

    // G1b: photos other apps imported late, with the budget the scan left.
    test('the run takes late imports after its scan, under its budget', () {
      final headless = _body(glue(), 'Future<bool> headlessBackfillWith({');
      expect(
        headless,
        _wired(
          r'final drain = await drainBackfill\([^;]*\n\s*lateImports: true,',
        ),
      );
      final drain = _body(glue(), 'Future<BackfillDrain> drainBackfill(');
      expect(
        drain,
        _wired(
          r'scanCompleted = true;[^}]*if \(lateImports && roomLeft\(\)\) \{\s*'
          r'try \{\s*await intake\.lateImportScan\('
          r'shouldContinue: timed \? budgetLeft : null\);',
        ),
      );
      final catchUp = _body(glue(), 'Future<DateTime?> foregroundCatchUp(');
      expect(
        catchUp,
        _wired(
          r'\} finally \{[^}]*if \(shouldContinue\?\.call\(\) \?\? true\) \{\s*'
          r'try \{\s*await intake\.lateImportScan\('
          r'shouldContinue: shouldContinue\);',
        ),
      );
    });

    // Review, 2026-10-19: without these the run admits a photo that cannot
    // finish, and every deadline cut counts against the photo, so a slow
    // patch of the server passes photos over for good.
    test('iOS: a photo that cannot finish by the deadline is not started, '
        'and a cut counts only for a photo that had the full window', () {
      expect(
        launch(),
        _wired(
          r'final inFlight = RunInFlight\( deadline: ios \? '
          r'startedAt\.add\(iosRunDeadline\) : null, clock: clock\);',
        ),
      );
      expect(after(), _wired(r'\n\s*finishBy: inFlight\.deadline,'));
      expect(after(), _wired(r'\n\s*photoOffered: inFlight\.offered,'));
    });
  });

  // Behavioural where it can be: the factory's own fields are public.
  test(
    'createPhotoIntake hands passOver and onBackfillListed to the intake',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: _Keys(),
      );
      bool passOver(String id) => id == 'x';
      void listed(int n) {}
      final intake =
          createPhotoIntake(
                settings,
                onBackfillListed: listed,
                passOver: passOver,
              )
              as LibraryPhotoIntake;
      expect(intake.passOver, same(passOver));
      expect(intake.onBackfillListed, same(listed));
    },
  );

  test(
    'createPhotoIntake hands loggedAssetIds over, and reads the change '
    'history (with its diagnostics record) on iOS only',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: _Keys(),
      );
      Future<Set<String>> logged(List<String> ids) async => {};
      final ios =
          createPhotoIntake(settings, loggedAssetIds: logged, isIOS: true)
              as LibraryPhotoIntake;
      expect(ios.loggedAssetIds, same(logged));
      expect(ios.lateImports, isNotNull);
      expect(ios.lateImports!.store, isNotNull);
      expect(ios.onLateImportPass, equals(recordLateImportPass));
      // G2a/G2b: the album lookup and the added dates ride the same channel.
      expect(ios.metaAlbumIds, isNotNull);
      expect(ios.assetAddedDate, isNotNull);
      final android =
          createPhotoIntake(settings, loggedAssetIds: logged, isIOS: false)
              as LibraryPhotoIntake;
      expect(android.lateImports, isNull);
      expect(android.onLateImportPass, isNull);
      expect(android.metaAlbumIds, isNull);
      expect(android.assetAddedDate, isNull);
    },
  );
}
