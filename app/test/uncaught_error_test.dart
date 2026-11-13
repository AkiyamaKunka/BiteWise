// The root isolate's uncaught errors (review 1.7.1, second pass). With no
// handler installed, the engine reports one as 'Unhandled Exception: <its
// text>' in the device log, release builds included, and sqflite's text
// carries the statement and its arguments: meal text, weights, girths.
// Some writes can still throw with nothing catching them (an iCloud
// restore whose import fails, the leftover flow's write, the add flow's
// Undo Leftover), so main.dart installs a backstop: a database error is
// logged by its type and its stack, never its text, and every other error
// goes on to the engine as before. The stack is frames only (function,
// file, line; addresses that `flutter symbolize` reads in a release
// build), and without it every such error was the same one line, with no
// way to tell which write threw.
import 'dart:io';

import 'package:calorie_tracker/data/db.dart' show openAppDatabase;
import 'package:calorie_tracker/data/meals_dao_impl.dart' show SqfliteMealsDao;
import 'package:calorie_tracker/main.dart' show onUncaughtError;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show
        createDatabaseFactoryFfi,
        databaseFactoryOrNull,
        inMemoryDatabasePath,
        sqfliteFfiInit;

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

void main() {
  /// Every line debugPrint is handed while [body] runs.
  List<String> logged(void Function() body) {
    final lines = <String>[];
    final before = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      body();
    } finally {
      debugPrint = before;
    }
    return lines;
  }

  test('a database error is logged by its type and stack, never its text, '
      'and handled', () async {
    sqfliteFfiInit();
    databaseFactoryOrNull = createDatabaseFactoryFfi(noIsolate: true);
    final db = await openAppDatabase(path: inMemoryDatabasePath);
    addTearDown(db.close);
    final dao = SqfliteMealsDao(db, clock: () => DateTime(2026, 8, 2, 10));
    // SQLite refuses the insert inside the statement, as a locked or full
    // database does, so sqflite's own error comes back.
    await db.execute('CREATE TRIGGER refuse_insert BEFORE INSERT ON '
        "body_weight BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END");
    Object? error;
    StackTrace? stack;
    try {
      await dao.saveBodyWeight('2026-08-02', 81.6, source: 'manual');
    } catch (e, s) {
      error = e;
      stack = s;
    }
    // The premise, so this cannot pass for nothing: the error's own text
    // holds the statement and the weight.
    expect('$error', contains('INSERT INTO body_weight'));
    expect('$error', contains('81.6'));

    var handled = false;
    final log =
        logged(() => handled = onUncaughtError(error!, stack!)).join('\n');
    expect(handled, isTrue,
        reason: 'handled: the engine prints nothing more of it');
    expect(log, contains('${error.runtimeType}'),
        reason: 'the failure itself is still logged');
    expect(log, contains('SqfliteMealsDao.saveBodyWeight'),
        reason: 'its frames say which write threw: $log');
    expect(log, contains('uncaught_error_test.dart'),
        reason: 'and from where: $log');
    for (final secret in [
      'INSERT',
      'body_weight',
      '81.6',
      '2026-08-02',
      'disk I/O',
    ]) {
      expect(log, isNot(contains(secret)), reason: log);
    }
  });

  test('every other error goes on to the engine as before', () {
    var handled = true;
    final log = logged(
        () => handled = onUncaughtError(StateError('boom'), StackTrace.current));
    expect(handled, isFalse, reason: "the engine's own report, unchanged");
    expect(log, isEmpty);
  });

  test('main() installs it before the app starts', () {
    final source = File('${_appRoot().path}/lib/main.dart').readAsStringSync();
    final start = source.indexOf('Future<void> main() async {');
    expect(start, isNot(-1));
    final body = source.substring(start, source.indexOf('\n}\n', start));
    expect(
        body,
        matches(RegExp(r'PlatformDispatcher\.instance\.onError\s*=\s*'
            r'onUncaughtError;\s*await _boot\(\);')));
  });
}
