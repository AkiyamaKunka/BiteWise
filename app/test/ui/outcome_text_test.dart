// outcomeBody is what the add-flow dialog and the headless meal card show.
// English must stay byte-identical to the pipeline's own prose (older tests
// pin it); Chinese must never leak English for a recognised kind; anything
// unrecognised falls back to the raw line rather than a wrong guess.
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();

  test('English is byte-identical to the pipeline message', () {
    const saved = PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged: Ramen (~600 kcal)',
        detail: 'Ramen (~600 kcal)');
    expect(outcomeBody(en, saved), saved.message);
    const skipped = PhotoOutcome(PhotoOutcomeKind.skipped, 'No food detected in this photo.');
    expect(outcomeBody(en, skipped), skipped.message);
    const dup = PhotoOutcome(PhotoOutcomeKind.duplicate,
        'Looks like a duplicate of a photo logged minutes ago.');
    expect(outcomeBody(en, dup), dup.message);
    const tracked = PhotoOutcome(PhotoOutcomeKind.alreadyTracked, 'This photo was already logged.');
    expect(outcomeBody(en, tracked), tracked.message);
    const inFlight = PhotoOutcome(PhotoOutcomeKind.inFlight,
        'This photo is still being analyzed — check back in a moment.',
        retryable: true);
    expect(outcomeBody(en, inFlight), inFlight.message);
  });

  test('a photo mid-analysis elsewhere is "still analyzing", not "already '
      'logged", in both languages', () {
    // The deliberate add used to answer 已经记录过了 for a photo the watcher
    // (or an iOS run cut off mid-analysis) was still holding (2026-10-07).
    const o = PhotoOutcome(PhotoOutcomeKind.inFlight,
        'This photo is still being analyzed — check back in a moment.',
        retryable: true);
    expect(outcomeBody(zh, o), zh.outcomeInFlightMsg);
    expect(outcomeBody(zh, o), isNot(zh.outcomeAlreadyTrackedMsg));
    expect(RegExp(r'[a-z]{4,}').hasMatch(outcomeBody(zh, o)), isFalse,
        reason: 'no English leaking into the Chinese UI');
    expect(outcomeBody(en, o), isNot(en.outcomeAlreadyTrackedMsg));
    expect(en.outcomeInFlight, isNot(en.outcomeAlreadyTracked));
    expect(zh.outcomeInFlight, isNot(zh.outcomeAlreadyTracked));
  });

  test('Chinese for every recognised failure kind, no English leaking', () {
    for (final kind in AnalysisErrorKind.values) {
      if (kind == AnalysisErrorKind.none || kind == AnalysisErrorKind.unknown) continue;
      // A terminal server refusal repeats the server's reason — realistic
      // here, since an arbitrary English reason is passed through verbatim.
      final line = kind == AnalysisErrorKind.serverError
          ? 'The server cannot analyze right now: the analysis ran but '
              'produced no usable result.'
          : 'raw english line';
      final o = PhotoOutcome(PhotoOutcomeKind.failed, line,
          errorKind: kind, detail: line);
      final body = outcomeBody(zh, o);
      // A provider's NAME is not English leaking (Gemini's region and
      // withheld-answer lines are about Gemini specifically).
      expect(RegExp(r'[a-z]{4,}').hasMatch(body.replaceAll('Gemini', '')),
          isFalse,
          reason: '$kind -> $body');
    }
  });

  test('unrecognised failures fall back to the raw message', () {
    const o = PhotoOutcome(PhotoOutcomeKind.failed, 'Provider request failed: 418',
        errorKind: AnalysisErrorKind.unknown, detail: 'Provider request failed: 418');
    expect(outcomeBody(zh, o), o.message);
    expect(outcomeBody(en, o), o.message);
  });

  test('a saved outcome without detail (older callers) keeps its message', () {
    const o = PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged: ok');
    expect(outcomeBody(zh, o), 'Meal logged: ok');
  });

  test('the no-key case names the SERVER path for subscription users', () {
    const o = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
        errorKind: AnalysisErrorKind.noServerKey, detail: 'x');
    expect(outcomeBody(zh, o), contains('服务器'));
    expect(outcomeBody(en, o), contains('server'));
  });

  group('outcomeSnackbar (the pipeline notify in di.dart)', () {
    // The snackbar used to get the pipeline's English sentence verbatim, so
    // every photo the automatic scan saved with the app open said "Meal
    // logged: …" in the Chinese UI (2026-10-08).
    const saved = PhotoOutcome(
        PhotoOutcomeKind.saved, 'Meal logged: Ramen — ~600 kcal',
        detail: 'Ramen — ~600 kcal');
    const leftover = PhotoOutcome(PhotoOutcomeKind.leftoverApplied,
        'Leftovers deducted: Ramen — −180 kcal, now ~420 kcal',
        detail: 'Ramen — −180 kcal, now ~420 kcal');

    test('English is byte-identical to what the snackbar used to show', () {
      expect(outcomeSnackbar(en, saved), 'Meal logged: Ramen — ~600 kcal');
      expect(outcomeSnackbar(en, leftover),
          'Leftovers deducted: Ramen — −180 kcal, now ~420 kcal');
      const failed = PhotoOutcome(PhotoOutcomeKind.failed, 'Provider said no',
          errorKind: AnalysisErrorKind.unknown, detail: 'Provider said no');
      expect(outcomeSnackbar(en, failed),
          'Photo analysis failed — kept for retry. Provider said no');
    });

    test('Chinese frames the save and the deduction in Chinese', () {
      expect(outcomeSnackbar(zh, saved), startsWith('已记录'));
      expect(outcomeSnackbar(zh, saved), isNot(contains('Meal logged')));
      expect(outcomeSnackbar(zh, leftover), startsWith('已扣除剩菜'));
      expect(outcomeSnackbar(zh, leftover),
          isNot(contains('Leftovers deducted')));
    });

    test('the summary itself is Chinese when the numbers ride along', () {
      // The {summary} was built in English by the pipeline, so the zh
      // snackbar and the headless card read '已记录：… — ~485 kcal'.
      const s = PhotoOutcome(
          PhotoOutcomeKind.saved, 'Meal logged: Ramen — ~600 kcal',
          detail: 'Ramen — ~600 kcal', mealName: 'Ramen', kcal: '600');
      const c = PhotoOutcome(PhotoOutcomeKind.leftoverApplied,
          'Leftovers deducted: Ramen — −180 kcal, now ~420 kcal',
          detail: 'Ramen — −180 kcal, now ~420 kcal',
          mealName: 'Ramen',
          kcal: '420',
          deductedKcal: 180);
      expect(outcomeSnackbar(en, s), s.message);
      expect(outcomeSnackbar(en, c), c.message);
      expect(outcomeBody(zh, s), '已记录：Ramen —— 约 600 千卡');
      expect(outcomeBody(zh, c), '已扣除剩菜：Ramen —— 减 180 千卡，现约 420 千卡');
    });

    test('a recognised permanent failure has no English in Chinese', () {
      const o = PhotoOutcome(PhotoOutcomeKind.failed, 'raw english line',
          errorKind: AnalysisErrorKind.badPhoto, detail: 'raw english line');
      final body = outcomeSnackbar(zh, o);
      expect(body, startsWith('照片分析失败'));
      expect(body, contains(zh.errBadPhoto));
      expect(RegExp(r'[a-z]{4,}').hasMatch(body), isFalse, reason: body);
    });

    test('the backlog warning is Chinese too', () {
      expect(RegExp(r'[a-z]{4,}').hasMatch(zh.backlogTruncatedWarning),
          isFalse);
      expect(en.backlogTruncatedWarning,
          'Photo library backlog is very large — some older photos may need '
          'to be added manually.');
    });
  });

  test('an empty provider balance says "top up" in both languages', () {
    const line =
        'Provider balance or credits exhausted — check your DeepSeek billing.';
    final o = PhotoOutcome(PhotoOutcomeKind.failed, line,
        retryable: true,
        errorKind: classifyAnalysisError(line),
        detail: line);
    expect(o.errorKind, AnalysisErrorKind.billing);
    expect(outcomeBody(zh, o), contains('充值'));
    expect(outcomeBody(zh, o), isNot(contains('billing')));
    expect(outcomeBody(en, o), contains('top it up'));
    // No automatic re-analysis promise: false with the automatic scan off
    // and on the coverage stop line.
    expect(outcomeBody(zh, o), isNot(contains('会重新分析')));
    expect(outcomeBody(en, o), isNot(contains('analyzed again after')));
  });

  test('Doubao / OpenRouter model errors keep their provider remedy', () {
    PhotoOutcome o(String line) => PhotoOutcome(PhotoOutcomeKind.failed, line,
        errorKind: classifyAnalysisError(line), detail: line);
    final doubao = o('Doubao model not found — Ark needs the EXACT versioned '
        'ID from its model list, and the model must be activated (开通管理) '
        'in the Volcengine console.');
    expect(outcomeBody(zh, doubao), zh.errBadModelDoubao);
    expect(outcomeBody(zh, doubao), contains('开通管理'));
    expect(outcomeBody(en, doubao), en.errBadModelDoubao);
    final openRouter = o('OpenRouter model not found — use the full slug from '
        'openrouter.ai/models (vendor/model, for example '
        'google/gemini-3.8-flash) and pick one that accepts images.');
    expect(outcomeBody(zh, openRouter), zh.errBadModelOpenRouter);
    expect(outcomeBody(zh, openRouter), contains('支持图片'));
    expect(outcomeBody(zh, openRouter), contains('完整模型 ID'));
    expect(outcomeBody(zh, openRouter), isNot(contains('slug')));
    final qwen = o('Qwen model not found — check the model name in Settings.');
    expect(outcomeBody(zh, qwen), zh.errBadModel);
  });

  group('a server that cannot analyze', () {
    PhotoOutcome o(String reason, {required bool retryable}) {
      final line = 'The server cannot analyze right now: $reason.';
      return PhotoOutcome(PhotoOutcomeKind.failed, line,
          retryable: retryable,
          errorKind: classifyAnalysisError(line),
          detail: line);
    }

    test('retryable (no verdict / "later"): kept and retried automatically',
        () {
      final later = o('You have hit your usage limit', retryable: true);
      expect(outcomeBody(zh, later), zh.errServerFailed);
      expect(outcomeBody(en, later), en.errServerFailed);
    });

    test('terminal (retry:false): says why and where to retry, never '
        '"automatically"', () {
      // The photo is marked failed and no scan offers it again, yet the
      // snackbar said 稍后会自动重试 with no reason (2026-10-12).
      final refused = o('the CLI exited 1', retryable: false);
      expect(outcomeBody(zh, refused),
          '你的服务器没能分析这张照片：the CLI exited 1。'
          '可在 设置 › 照片覆盖检查 里重试。');
      expect(outcomeBody(en, refused),
          'Your server could not analyze this photo: the CLI exited 1. '
          'You can retry it from Settings › Photo Coverage.');
      // A credits refusal repeats on every retry: the fix is another
      // model, so it says that instead of sending the user to retry.
      final credits = o('Fable 5 requires usage credits', retryable: false);
      expect(outcomeBody(zh, credits),
          '你的服务器无法使用所选模型：Fable 5 requires usage credits —— '
          '请在 设置 › AI 服务 › Claude 订阅 里换一个模型。');
      expect(outcomeBody(zh, credits), isNot(contains('重试')));
      expect(outcomeBody(zh, credits), isNot(contains('❌')));
      expect(outcomeBody(en, credits),
          contains('Settings › AI Provider › Claude Plan'));
      final empty = o('the analysis ran but produced no usable result',
          retryable: false);
      expect(outcomeBody(zh, empty), contains('AI 的回答无法使用'));
      expect(RegExp(r'[a-z]{4,}').hasMatch(outcomeBody(zh, empty)), isFalse);
      expect(outcomeBody(en, empty), contains("the AI's answer was unusable"));
      for (final out in [refused, credits, empty]) {
        expect(outcomeBody(zh, out), isNot(contains('自动重试')));
        expect(outcomeBody(en, out), isNot(contains('retried later')));
      }
    });

    test('serverReason is bounded and absent without the marker', () {
      expect(serverReason('no marker'), isNull);
      final long = serverReason(
          'The server cannot analyze right now: ${'x' * 500}.')!;
      expect(long.runes.length, 160);
      expect(long, endsWith('…'));
    });
  });

  group('a deliberate add (the add-flow dialog)', () {
    // Its photo was RELEASED on a transient failure and nothing re-offers
    // a picked photo, so "kept and retried later" was a false promise
    // (2026-10-12). Snackbars and the coverage screen keep the default.
    const promising = {
      AnalysisErrorKind.rateLimited: 'rate limit',
      AnalysisErrorKind.quotaPaused: 'Gemini daily quota exhausted',
      AnalysisErrorKind.billing: 'Provider balance or credits exhausted',
      AnalysisErrorKind.network: 'network or service issue',
      AnalysisErrorKind.serverBusy: 'busy',
      AnalysisErrorKind.serverError: 'The server cannot analyze right now.',
    };

    test('transient kinds: no automatic-retry promise, point at Retry', () {
      for (final MapEntry(key: kind, value: line) in promising.entries) {
        final o = PhotoOutcome(PhotoOutcomeKind.failed, line,
            retryable: true, errorKind: kind, detail: line);
        final zhBody = outcomeBody(zh, o, deliberate: true);
        final enBody = outcomeBody(en, o, deliberate: true);
        expect(zhBody, zh.outcomeRetryLaterMsg(retryReason(zh, o)!),
            reason: '$kind');
        expect(zhBody, isNot(contains('自动重试')), reason: '$kind');
        expect(zhBody, isNot(contains('已保留')), reason: '$kind');
        expect(RegExp(r'[a-z]{4,}').hasMatch(zhBody), isFalse, reason: zhBody);
        expect(enBody, contains('tap Retry'), reason: '$kind');
        expect(enBody, isNot(contains('retried later')), reason: '$kind');
        // The default (snackbar / coverage) wording is untouched.
        expect(outcomeBody(zh, o), isNot(zhBody), reason: '$kind');
      }
    });

    test('a permanent failure and a missing key keep their own lines', () {
      const rejected = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
          errorKind: AnalysisErrorKind.rejectedKey, detail: 'x');
      expect(outcomeBody(zh, rejected, deliberate: true), zh.errRejectedKey);
      const noKey = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
          retryable: true, errorKind: AnalysisErrorKind.noApiKey, detail: 'x');
      expect(outcomeBody(zh, noKey, deliberate: true), zh.errNoApiKey);
      // Gemini's region refusal keeps its VPN hint in the dialog, and a
      // share names it instead of the raw English line.
      const geminiRegion = 'Gemini is not available from your current '
          'network region (check the VPN).';
      const region = PhotoOutcome(PhotoOutcomeKind.failed, geminiRegion,
          retryable: true,
          errorKind: AnalysisErrorKind.regionBlocked,
          detail: geminiRegion);
      expect(outcomeBody(zh, region, deliberate: true),
          zh.errRegionBlocked('Gemini'));
      expect(
          outcomeSnackbar(
              zh,
              const PhotoOutcome(PhotoOutcomeKind.failed, geminiRegion,
                  retryable: true,
                  errorKind: AnalysisErrorKind.regionBlocked,
                  detail: geminiRegion,
                  shared: true)),
          zh.outcomeShareRetryMsg(zh.reasonRegionBlocked('Gemini')));
      const withheld = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
          errorKind: AnalysisErrorKind.contentBlocked, detail: 'x');
      expect(outcomeBody(zh, withheld, deliberate: true),
          'Gemini 拒绝分析这张照片 —— 可以手动记录。');
    });

    test('a region refusal names the provider that refused, not always '
        'Gemini', () {
      const openai = PhotoOutcome(PhotoOutcomeKind.failed,
          'OpenAI is not available from your current network region '
          '(check the VPN).',
          retryable: true, errorKind: AnalysisErrorKind.regionBlocked);
      expect(outcomeBody(zh, openai),
          'OpenAI 在当前网络地区不可用 —— 请检查 VPN 节点（香港等地区不支持）。');
      expect(outcomeBody(zh, openai), isNot(contains('Gemini')));
      // A line without the provider never invents one.
      const bare = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
          retryable: true, errorKind: AnalysisErrorKind.regionBlocked);
      expect(outcomeBody(zh, bare), startsWith('当前 AI 服务'));
    });

    test('a share that failed transiently asks for a re-share', () {
      const o = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
          retryable: true,
          errorKind: AnalysisErrorKind.network,
          detail: 'x',
          shared: true);
      expect(outcomeSnackbar(zh, o),
          '分享的照片这次没能分析（网络或服务问题）—— 请稍后重新分享。');
      expect(outcomeSnackbar(en, o),
          'The shared photo was not analyzed this time (network or service '
          'issue) — share it again later.');
      const raw = PhotoOutcome(PhotoOutcomeKind.failed, 'Odd failure.',
          retryable: true,
          errorKind: AnalysisErrorKind.unknown,
          detail: 'Odd failure.',
          shared: true);
      expect(outcomeSnackbar(en, raw),
          'The shared photo was not analyzed this time (Odd failure) — share '
          'it again later.');
    });

    test('a PICKED photo whose add flow was closed asks for a re-pick, not '
        'a re-share', () {
      const o = PhotoOutcome(PhotoOutcomeKind.failed, 'x',
          retryable: true,
          errorKind: AnalysisErrorKind.network,
          detail: 'x',
          picked: true);
      expect(outcomeSnackbar(zh, o), '这张照片没能分析（网络或服务问题）—— 请稍后重新选择它。');
      expect(outcomeSnackbar(en, o),
          'This photo was not analyzed (network or service issue) — pick it '
          'again later.');
      // The filter both detached callers share: refusals pass through
      // untouched, a transient failure is flagged, announced kinds drop.
      const notFood = PhotoOutcome(PhotoOutcomeKind.skipped, 'n');
      expect(unannouncedOutcome(notFood, picked: true), same(notFood));
      final flagged = unannouncedOutcome(
          const PhotoOutcome(PhotoOutcomeKind.failed, 'x', retryable: true),
          picked: true)!;
      expect((flagged.picked, flagged.shared), (true, false));
      expect(
          unannouncedOutcome(const PhotoOutcome(PhotoOutcomeKind.failed, 'x'),
              picked: true),
          isNull);
      expect(
          unannouncedOutcome(const PhotoOutcome(PhotoOutcomeKind.saved, 's'),
              shared: true),
          isNull);
    });
  });

  test('a server rejection shows the CODE in both languages', () {
    const o = PhotoOutcome(
        PhotoOutcomeKind.failed, 'The server rejected this request (bad_model).',
        errorKind: AnalysisErrorKind.serverRejected,
        detail: 'The server rejected this request (bad_model).');
    expect(outcomeBody(zh, o), contains('bad_model'));
    expect(outcomeBody(en, o), contains('bad_model'));
    expect(rejectionCode('no code here'), '?');
  });
}
