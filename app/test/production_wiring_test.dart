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
          r'recorder\.listed, passOver: deferred\.passOver\)',
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
}
