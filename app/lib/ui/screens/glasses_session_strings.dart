/// Wording for the Meta glasses session (feat/meta-dat prototype).
///
/// Kept beside the screen instead of in the ARB files on purpose: the
/// screen is flag-gated and experimental, and the ARB files are being
/// edited by the other glasses/restaurant lanes. If the session ever ships,
/// these move into app_en.arb / app_zh.arb.
library;

import 'package:flutter/widgets.dart';

import '../../services/glasses/meta_dat_channel.dart';

class GlassesSessionStrings {
  const GlassesSessionStrings._(this.zh);
  final bool zh;

  static const en = GlassesSessionStrings._(false);
  static const zhHans = GlassesSessionStrings._(true);

  static GlassesSessionStrings of(BuildContext context) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zhHans : en;

  String _t(String e, String z) => zh ? z : e;

  String get entryTitle => _t('Meta glasses session', 'Meta 眼镜拍摄');
  String get entryNote => _t('Experimental', '实验功能');
  String get title => _t('Meta glasses (experimental)', 'Meta 眼镜（实验）');
  String get unsupported =>
      _t('This build has no Meta glasses support.', '此版本不支持 Meta 眼镜。');
  String get statusHeader => _t('Glasses', '眼镜');

  /// [minutes]: how long Chopstats keeps a session behind a locked phone or
  /// another app (GlassesSessionScreen.backgroundGrace).
  String keepOpen(int minutes) => _t(
    'Keep this screen open while you take photos. Going back or folding '
        'the glasses ends the session. With the phone locked or another app '
        'in front, Chopstats ends it after $minutes minutes, and the glasses '
        'may end it sooner. Each photo is analyzed like a photo you pick, '
        'and logged as a meal.',
    '拍照时请停留在此页面。返回上一页或合上眼镜会结束拍摄模式。'
        '锁屏或切换到其他应用时，筷拍会在 $minutes 分钟后结束拍摄模式，'
        '眼镜也可能更早结束。每张照片都会像手动选择的照片一样分析并记录为一餐。',
  );

  /// The session Chopstats ended itself after [minutes] in the background.
  String endedInBackground(int minutes) => _t(
    'The session ended: Chopstats was in the background for $minutes '
        'minutes. Start it again when you are ready.',
    '拍摄模式已结束：筷拍在后台停留了 $minutes 分钟。准备好后请重新开始。',
  );

  String get registrationLabel => _t('Meta AI app', 'Meta AI 应用');
  String get glassesLabel => _t('Glasses', '眼镜');
  String get sessionLabel => _t('Session', '拍摄模式');
  String get connect => _t('Link Chopstats in Meta AI', '在 Meta AI 中关联筷拍');
  String get start => _t('Start session', '开始拍摄模式');
  String get stop => _t('End session', '结束拍摄模式');
  String get takePhoto => _t('Take a photo now', '立即拍照');
  String get capturing => _t('Taking photo…', '正在拍照…');
  String get mockPress => _t('Press the mock shutter button', '模拟按下眼镜拍照键');
  String get updateGlassesApp => _t('Update in Meta AI', '在 Meta AI 中更新');
  String get photosHeader => _t('Photos from this session', '本次拍摄的照片');
  String get analyzing => _t('Analyzing…', '分析中…');
  String get shutterPressed => _t(
    'Shutter pressed on the glasses — the photo is on its way.',
    '已按下眼镜拍照键，照片传输中。',
  );
  String get permissionDenied => _t(
    'Chopstats may not use the glasses camera. Allow it in the Meta AI app.',
    '筷拍没有使用眼镜相机的权限，请在 Meta AI 应用中允许。',
  );
  String get notReady =>
      _t('The glasses are not ready to take a photo.', '眼镜尚未准备好拍照。');

  String registration(MetaDatRegistration r) => switch (r) {
    MetaDatRegistration.registered => _t('Linked', '已关联'),
    MetaDatRegistration.registering => _t('Linking…', '关联中…'),
    MetaDatRegistration.available => _t('Not linked', '未关联'),
    MetaDatRegistration.unavailable => _t('Not installed', '未安装'),
    MetaDatRegistration.unknown => _t('Unknown', '未知'),
  };

  String devices(int count, {required bool active, required bool mock}) {
    if (mock) return _t('Simulated', '模拟眼镜');
    if (active) return _t('Ready', '已就绪');
    if (count == 0) return _t('None nearby', '附近没有');
    // Paired but not picked: folded, off, or out of range.
    return _t('Not connected', '未连接');
  }

  String session(MetaDatSessionState s) => switch (s) {
    MetaDatSessionState.started => _t('Running', '进行中'),
    MetaDatSessionState.starting => _t('Starting…', '启动中…'),
    MetaDatSessionState.paused => _t('Paused', '已暂停'),
    MetaDatSessionState.stopping => _t('Ending…', '结束中…'),
    MetaDatSessionState.idle ||
    MetaDatSessionState.stopped ||
    MetaDatSessionState.unknown => _t('Off', '未开始'),
  };

  /// A wire code (Swift MetaDatFailure / event `error`) in words. Codes
  /// only: SDK messages are diagnostics, never shown.
  String failure(String code) => switch (code) {
    'registration' || 'unregistration' || 'callback' => _t(
      'The Meta AI app did not finish connecting. Try again.',
      'Meta AI 应用未完成连接，请重试。',
    ),
    'permission' || 'photo_permission_denied' => permissionDenied,
    'no_device' => _t(
      'No glasses are connected. Unfold and wear them, then try again.',
      '眼镜未连接。请打开并戴上眼镜后重试。',
    ),
    // Errors are news, not states: the Session row says whether it ended.
    'session' => _t(
      'The glasses session reported a problem. If it ended, unfold the '
          'glasses and start it again.',
      '眼镜拍摄模式出现问题。如果已结束，请打开眼镜后重新开始。',
    ),
    // Meta's version guide, one remedy per DeviceSessionError.
    'session_update_glasses_app' => _t(
      'The glasses need an update before Chopstats can use them. Tap '
          '"$updateGlassesApp" (or open Meta AI → App connections), then '
          'start the session again.',
      '眼镜需要更新后才能配合筷拍使用。请点按“$updateGlassesApp”'
          '（或打开 Meta AI → 应用连接），然后重新开始拍摄模式。',
    ),
    'session_sdk_too_old' => _t(
      'This Chopstats build is too old for the software on your glasses. '
          'Only a newer Chopstats build fixes this; updating the glasses will '
          'not.',
      '此版本的筷拍对眼镜上的软件来说太旧。只有更新版本的筷拍才能解决，'
          '更新眼镜无济于事。',
    ),
    metaDatVersionWarning => _t(
      'The session is running, but Chopstats and the glasses software are '
          'on versions Meta does not recommend together, so something may '
          'misbehave. Update Meta AI and the glasses when you can.',
      '拍摄模式仍在进行，但筷拍与眼镜软件的版本搭配不在 Meta 建议范围内，'
          '可能出现异常。方便时请更新 Meta AI 和眼镜。',
    ),
    'session_glasses_app_unavailable' => _t(
      'The glasses did not open their side of the Chopstats connection. In '
          'the Meta AI app, check that the glasses are set up and charged '
          'above 10% (the glasses part installs only then), then try again.',
      '眼镜端的筷拍连接没有启动。请在 Meta AI 应用中确认眼镜已设置好、'
          '电量高于 10%（只有这样眼镜端组件才能安装），然后重试。',
    ),
    'session_thermal' => _t(
      'The glasses are too hot and stopped the session. Let them cool down, '
          'then start it again.',
      '眼镜温度过高，已停止拍摄模式。请等眼镜冷却后重新开始。',
    ),
    'session_battery' => _t(
      'The glasses battery is too low for the session. Charge them, then '
          'start it again.',
      '眼镜电量过低，无法进行拍摄模式。请充电后重新开始。',
    ),
    'navigation' => _t(
      'Could not open the Meta AI app. Open it yourself and go to App '
          'connections.',
      '无法打开 Meta AI 应用。请手动打开并前往“应用连接”。',
    ),
    'capture_timeout' || 'photo_capture_failed' || 'photo_disconnected' => _t(
      'No photo arrived from the glasses. Try again.',
      '没有收到眼镜的照片，请重试。',
    ),
    // Only after Chopstats retried the camera's startup once itself.
    'photo_setup_failed' || 'camera' => _t(
      'The glasses camera did not start, even on a second try. Turn the '
          'glasses off and on, then start the session again.',
      '眼镜相机未能启动（已自动重试一次）。请将眼镜关机再开机，然后重新开始拍摄模式。',
    ),
    'photo_not_ready' || 'photo_busy' => notReady,
    'unsupported' => unsupported,
    _ => _t('Something went wrong with the glasses ($code).', '眼镜出现问题（$code）。'),
  };
}
