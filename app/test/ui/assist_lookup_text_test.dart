// What the meal editor says after a manual restaurant lookup that wrote
// nothing (ui/assist_lookup_text.dart), as one table. The editor tests
// (meal_editor_screen_test.dart) show the same lines through the screen.
import 'package:calorie_tracker/core/restaurant_assist_logic.dart'
    show AssistDecision, AssistReason;
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart'
    show AssistRun, AssistSkip;
import 'package:calorie_tracker/ui/assist_lookup_text.dart';
import 'package:calorie_tracker/ui/assist_view.dart' show AssistViewKind;
import 'package:flutter_test/flutter_test.dart';

import '../support/assist_fixtures.dart';

/// The owner's server (Claude Plan) answering McDonald's Big Mac at
/// [kcal]: a suggestion at most.
AssistDecision _planBigMac({int kcal = 590}) {
  final found = bigMacFound();
  final match =
      Map<String, dynamic>.from((found['matches'] as List).single as Map);
  final option =
      Map<String, dynamic>.from((match['options'] as List).single as Map)
        ..['calories'] = kcal;
  match['options'] = [option];
  found['matches'] = [match];
  return decideFixture(bigMacAnalysis(), found,
      verbatim: false, provider: 'claude_plan');
}

/// A search that found no published nutrition.
AssistDecision _notPublished() => decideFixture(
    bigMacAnalysis(),
    {...bigMacFound(), 'status': 'not_published', 'matches': <Object>[]},
    verbatim: false,
    provider: 'claude_plan');

void main() {
  final l = AppLocalizationsEn();

  // McDonald's published numbers standing on the meal (590 kcal).
  final applied = appliedBigMac();

  String? say(
    AssistRun run, {
    bool fresh = false,
    AssistViewKind kind = AssistViewKind.none,
    Map<String, dynamic>? before,
  }) =>
      manualLookupMessage(l, run,
          fresh: fresh, beforeKind: kind, before: before ?? bigMacAnalysis());

  // How a lookup with no answer ended → the line (null: nothing said).
  final byCode = <String, String?>{
    AssistSkip.pending: l.assistLookupStillRunning,
    AssistSkip.working: l.assistLookupStillRunning,
    AssistSkip.background: l.assistLookupStillRunning,
    AssistSkip.consentNeeded: null,
    AssistSkip.off: null,
    AssistSkip.cancelled: null,
    AssistSkip.pickNeedsHttps: l.assistLookupPickNeedsHttps,
    AssistSkip.outsideUs: l.assistLookupOutsideUs,
    AssistSkip.regionUnknown: l.assistLookupRegionUnknown,
    AssistSkip.dailyCap: l.assistLookupDailyCap,
    'lookup_daily_cap': l.assistLookupDailyCap,
    'lookup_server_outdated': l.restaurantServerOutdated,
    'lookup_disabled': l.restaurantServerDisabled,
    'lookup_bad_reply': l.assistLookupFailed,
    AssistSkip.placeThrottled: l.assistLookupFailed,
    AssistSkip.placeError: l.assistLookupFailed,
    AssistSkip.error: l.assistLookupFailed,
    AssistSkip.unsupported: l.assistLookupFailed,
    // No chain to ask about.
    AssistSkip.noBrand: l.assistLookupNoChain,
    AssistSkip.unavailable: l.assistLookupNoChain,
    AssistSkip.placeNoFix: l.assistLookupNoChain,
  };

  group('a lookup with no answer, by how it ended', () {
    for (final MapEntry(key: code, value: line) in byCode.entries) {
      test(code, () {
        expect(say(AssistRun(code)), line);
        // A press that was not a fresh search reads the same over
        // numbers that stand.
        expect(say(AssistRun(code), kind: AssistViewKind.applied,
            before: applied), line);
        // So does a fresh search over a meal with nothing standing.
        expect(say(AssistRun(code), fresh: true), line);
      });
    }
  });

  test('an answer with nothing usable to write keeps the AI estimate', () {
    expect(say(AssistRun(AssistReason.notPublished, decision: _notPublished())),
        l.assistContextOnly);
    expect(
        say(AssistRun(AssistReason.notGrounded, decision: _planBigMac()),
            fresh: true, kind: AssistViewKind.contextOnly),
        l.assistContextOnly);
  });

  // What stands before the search: published numbers in use, or a
  // suggestion the meal can still take.
  for (final (kind, before) in [
    (AssistViewKind.applied, applied),
    (AssistViewKind.suggested, suggestedBigMac()),
  ]) {
    group('Search again over ${kind.name} numbers, writing nothing', () {
      String? again(AssistRun run) =>
          say(run, fresh: true, kind: kind, before: before);

      test('one that could not run says why, or nothing if not started', () {
        // Only "no chain to ask about" is not a failure: nothing better
        // than what stands was found.
        const noChain = {
          AssistSkip.noBrand,
          AssistSkip.unavailable,
          AssistSkip.placeNoFix,
        };
        for (final MapEntry(key: code, value: line) in byCode.entries) {
          expect(again(AssistRun(code)),
              noChain.contains(code) ? l.assistSearchAgainNoChange : line,
              reason: code);
        }
      });

      test('one that found nothing: these numbers stay', () {
        expect(
            again(AssistRun(AssistReason.notPublished,
                decision: _notPublished())),
            l.assistSearchAgainNoChange);
      });
    });
  }

  group('Search again over published numbers in use', () {
    String? again(AssistRun run) =>
        say(run, fresh: true, kind: AssistViewKind.applied, before: applied);

    test('the same numbers say so', () {
      expect(
          again(AssistRun(AssistReason.notGrounded, decision: _planBigMac())),
          l.assistSearchAgainSame);
    });

    test('other numbers name the kcal found', () {
      expect(
          again(AssistRun(AssistReason.notGrounded,
              decision: _planBigMac(kcal: 610))),
          l.assistSearchAgainDiffers('610'));
    });
  });
}
