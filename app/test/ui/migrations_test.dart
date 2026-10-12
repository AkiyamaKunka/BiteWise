// One-time repair: verdicts reached while iPhone photos were unreadable
// (raw HEIC labelled image/jpeg) are released exactly once per source.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/migrations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  FakeDao seeded() => FakeDao()
    ..ledger.addAll({
      'app_watch:not-food': IngestionStatus.skipped,
      'app_photo:manual-scan-not-food': IngestionStatus.skipped,
      'app_photo:too-big-heic': IngestionStatus.failed,
      'app_watch:a-meal': IngestionStatus.saved,
      'app_watch:in-flight': IngestionStatus.processing,
      'app_photo:user-deleted': IngestionStatus.deleted,
    });

  test('fresh phone: watcher AND manual-scan verdicts are released, once',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dao = seeded();
    expect(await reofferUnreadPhotosOnce(dao, prefs), 3);
    expect(
        dao.ledger.keys,
        unorderedEquals([
          'app_watch:a-meal',
          'app_watch:in-flight',
          'app_photo:user-deleted',
        ]));

    // Second launch: both flags hold, and a FRESH (now trustworthy)
    // "not food" verdict is left alone.
    dao.ledger['app_watch:really-not-food'] = IngestionStatus.skipped;
    expect(await reofferUnreadPhotosOnce(dao, prefs), 0);
    expect(dao.ledger.containsKey('app_watch:really-not-food'), isTrue);
  });

  test('a phone that already ran v1 still gets the manual-scan repair, and '
      'its post-fix watcher verdicts are NOT released again', () async {
    // The owner's phone, 2026-09-30 19:41: v1 ran and released nothing,
    // because every bad verdict came from manual coverage scans.
    SharedPreferences.setMockInitialValues({iosUnreadPhotoReofferFlag: true});
    final prefs = await SharedPreferences.getInstance();
    final dao = seeded();
    expect(await reofferUnreadPhotosOnce(dao, prefs), 2);
    expect(dao.ledger.containsKey('app_watch:not-food'), isTrue,
        reason: 'reached after the fix — trustworthy');
    expect(dao.ledger.containsKey('app_photo:manual-scan-not-food'), isFalse);
    expect(dao.ledger.containsKey('app_photo:too-big-heic'), isFalse);
    expect(prefs.getBool(iosUnreadDeliberateReofferFlag), isTrue);
  });
}
