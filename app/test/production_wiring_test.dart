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
        r'country: \(\) => regionOfLocale\(Platform\.localeName\),',
        r'repliesInChinese: \(\) => settings\.repliesInChinese,',
      ]) {
        expect(build, _wired(wire), reason: wire);
      }
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
