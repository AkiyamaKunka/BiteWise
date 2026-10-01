// One-time repair: verdicts reached while iPhone photos were unreadable
// (raw HEIC labelled image/jpeg) are released exactly once.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  test('releases skipped + failed verdicts once, keeps saved and in-flight',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dao = FakeDao()
      ..ledger.addAll({
        'not-food': IngestionStatus.skipped,
        'too-big-heic': IngestionStatus.failed,
        'a-meal': IngestionStatus.saved,
        'in-flight': IngestionStatus.processing,
        'user-deleted': IngestionStatus.deleted,
      });
    expect(await reofferUnreadPhotosOnce(dao, prefs), 2);
    expect(dao.ledger.keys,
        unorderedEquals(['a-meal', 'in-flight', 'user-deleted']));

    // Second launch: the flag holds, and a FRESH (now trustworthy)
    // "not food" verdict is left alone.
    dao.ledger['really-not-food'] = IngestionStatus.skipped;
    expect(await reofferUnreadPhotosOnce(dao, prefs), 0);
    expect(dao.ledger.containsKey('really-not-food'), isTrue);
    expect(prefs.getBool(iosUnreadPhotoReofferFlag), isTrue);
  });
}
