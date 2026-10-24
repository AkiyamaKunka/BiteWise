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
  String get keepOpen => _t(
    'Keep this screen open while you take photos: the session ends when '
        'Bitewise leaves the screen or the glasses fold. Each photo is '
        'analyzed like a photo you pick, and logged as a meal.',
    '拍照时请停留在此页面：离开筷拍或合上眼镜，拍摄模式就会结束。'
        '每张照片都会像手动选择的照片一样分析并记录为一餐。',
  );
  String get registrationLabel => _t('Meta AI app', 'Meta AI 应用');
  String get glassesLabel => _t('Glasses', '眼镜');
  String get sessionLabel => _t('Session', '拍摄模式');
  String get connect => _t('Link Bitewise in Meta AI', '在 Meta AI 中关联筷拍');
  String get start => _t('Start session', '开始拍摄模式');
  String get stop => _t('End session', '结束拍摄模式');
  String get takePhoto => _t('Take a photo now', '立即拍照');
  String get capturing => _t('Taking photo…', '正在拍照…');
  String get mockPress => _t('Press the mock shutter button', '模拟按下眼镜拍照键');
  String get photosHeader => _t('Photos from this session', '本次拍摄的照片');
  String get analyzing => _t('Analyzing…', '分析中…');
  String get shutterPressed => _t(
    'Shutter pressed on the glasses — the photo is on its way.',
    '已按下眼镜拍照键，照片传输中。',
  );
  String get permissionDenied => _t(
    'Bitewise may not use the glasses camera. Allow it in the Meta AI app.',
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
    'session' => _t(
      'The glasses session stopped. Unfold the glasses and start it again.',
      '眼镜拍摄模式已停止。请打开眼镜后重新开始。',
    ),
    'capture_timeout' || 'photo_capture_failed' || 'photo_disconnected' => _t(
      'No photo arrived from the glasses. Try again.',
      '没有收到眼镜的照片，请重试。',
    ),
    'photo_not_ready' || 'photo_busy' => notReady,
    'unsupported' => unsupported,
    _ => _t('Something went wrong with the glasses ($code).', '眼镜出现问题（$code）。'),
  };
}
