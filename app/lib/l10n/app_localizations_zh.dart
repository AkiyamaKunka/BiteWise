// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get tabToday => '今天';

  @override
  String get tabHistory => '历史';

  @override
  String get tabBody => '身体';

  @override
  String get tabSettings => '设置';

  @override
  String kcalAmount(String kcal) {
    return '$kcal 千卡';
  }

  @override
  String mealsToday(int count) {
    return '今天 $count 餐';
  }

  @override
  String get rowTypical => '日常';

  @override
  String get rowBurn => '消耗';

  @override
  String get rowEaten => '已摄入';

  @override
  String get rowResultLeft => '= 剩余';

  @override
  String get rowResultOver => '= 超出日常';

  @override
  String get ringHeadroom => '剩余';

  @override
  String get ringLeftToday => '今日剩余';

  @override
  String get ringAboveTypical => '超出日常';

  @override
  String get ringKcalToday => '千卡';

  @override
  String get todayEmptyTitle => '今天还没有记录。';

  @override
  String get todayEmptyHint =>
      '点击下方\"记录\"，用照片或文字添加一餐；也可以在设置里打开\"监控相册\"，新的食物照片会自动记录。';

  @override
  String get fabLog => '记录';

  @override
  String get shareDayTooltip => '把今天分享为图片';

  @override
  String shareDayFailed(String error) {
    return '生成图片失败：$error';
  }

  @override
  String historyAverage(String kcal) {
    return '平均：约 $kcal 千卡 / 天';
  }

  @override
  String get historyNoMeals => '无记录';

  @override
  String historyEmpty(int days) {
    return '过去 $days 天没有记录。';
  }

  @override
  String get retry => '重试';

  @override
  String get bodyWeightHeader => '体重';

  @override
  String get bodyMeasurementsHeader => '围度';

  @override
  String get bodyHistoryHeader => '历史';

  @override
  String bodyOnDate(String date) {
    return '$date';
  }

  @override
  String get bodyNoChange => '无变化';

  @override
  String get bodyWaist => '腰围';

  @override
  String get bodyChest => '胸围';

  @override
  String get bodyHip => '臀围';

  @override
  String get bodyEmptyTitle => '还没有身体数据。';

  @override
  String get bodyEmptyHint =>
      '点击\"记录\"来记体重或腰围、胸围、臀围。通过对话记录的体重（\"我今天 81.6 公斤\"）也会显示在这里。';

  @override
  String bodySheetLogTitle(String date) {
    return '记录身体 · $date';
  }

  @override
  String bodySheetEditTitle(String date) {
    return '编辑 $date';
  }

  @override
  String get bodySheetHint => '没量的项目留空即可。';

  @override
  String get bodyFieldWeight => '体重';

  @override
  String get save => '保存';

  @override
  String get saving => '保存中…';

  @override
  String bodyErrNotNumber(String label, String raw) {
    return '$label：\"$raw\" 不是数字。';
  }

  @override
  String bodyErrBounds(String label, String min, String max) {
    return '$label需要在 $min 到 $max 之间。';
  }

  @override
  String get bodyErrEmpty => '请至少填写一项。';

  @override
  String bodyDeleteTitle(String date) {
    return '删除 $date？';
  }

  @override
  String bodyDeleteBody(String what) {
    return '将删除这一天记录的$what。';
  }

  @override
  String get bodyDeleteWeight => '体重';

  @override
  String get bodyDeleteMeasurements => '围度';

  @override
  String get bodyDeleteBoth => '体重和围度';

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get settingsWelcomeTitle => '欢迎 — 一步开始记录';

  @override
  String get settingsWelcomeBody =>
      '点击下方\"AI 服务\"，选择一家并粘贴它的 API Key（输入即保存），然后\"测试当前服务\"。\n之后打开\"监控相册\"，新的食物照片会自动记录。\n中国大陆用户请选择 Qwen 通义千问、Doubao 豆包或 GLM 智谱（GLM 默认模型免费）——其余服务需要 VPN。';

  @override
  String get settingsSectionAi => 'AI';

  @override
  String get settingsAiFooterPaused =>
      '分析已暂停 — 已达当日额度。新照片会保留并自动重试；在 AI 服务页更换 Key 或服务后立即恢复。';

  @override
  String get settingsAiFooter => '照片由你选择的服务分析 — 它的 Key 不会离开这台手机。';

  @override
  String get settingsRowAiProvider => 'AI 服务';

  @override
  String get settingsSectionPhotos => '照片';

  @override
  String get settingsPhotosFooter => '监控会自动记录新的食物照片；回溯窗口决定补扫时往回看多少天。';

  @override
  String get settingsRowWatch => '监控相册';

  @override
  String get settingsRowLookback => '补扫回溯';

  @override
  String lookbackDays(int count) {
    return '$count 天';
  }

  @override
  String get settingsRowCoverage => '照片覆盖检查';

  @override
  String get settingsSectionReport => '报告';

  @override
  String get settingsRowReportTime => '报告时间';

  @override
  String get settingsSectionProfile => '个人资料';

  @override
  String get settingsRowDietaryProfile => '饮食偏好';

  @override
  String get profileSet => '已设置';

  @override
  String get profileNotSet => '未设置';

  @override
  String get settingsSectionData => '你的数据';

  @override
  String get settingsDataFooter => '导入会把导出的文件合并进这台手机：已有的餐不会被改动，导入两次也不会让热量翻倍。';

  @override
  String get settingsRowExport => '导出数据…';

  @override
  String get settingsRowImport => '导入数据…';

  @override
  String get settingsRowLanguage => '语言';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get languageSheetTitle => '语言';

  @override
  String get lookbackSheetTitle => '补扫回溯';

  @override
  String get lookbackSheetHint => '补扫时往回检查多少天的照片。';

  @override
  String lookbackSet(int count) {
    return '设为 $count 天';
  }

  @override
  String get providerPageTitle => 'AI 服务';

  @override
  String get connectionTypeHeader => '连接方式';

  @override
  String get connectionTypeFooter =>
      'API Key 按张照片计费，Key 保存在这台手机上。订阅是固定月费套餐，由你自己的云服务器登录使用 — 照片不再额外花钱。';

  @override
  String get typeApiKey => 'API Key';

  @override
  String get typeSubscription => '订阅';

  @override
  String get testProvider => '测试当前服务';

  @override
  String get testProviderFooter => '测试会指出具体问题：配置、网络、Key、账户余额、返回格式或额度。';

  @override
  String get apiPageTitle => 'API Key';

  @override
  String get apiProviderHeader => '服务商';

  @override
  String get apiProviderFooter =>
      '按张计费：Key 保存在这台手机上，每张照片都是一次由服务商计费的 API 调用。中国大陆请选择 Qwen、Doubao 或 GLM — 其余需要 VPN。';

  @override
  String get noteVpn => '需要 VPN';

  @override
  String get noteFreeTierVpn => '有免费额度 · 需要 VPN';

  @override
  String get noteDirect => '中国直连';

  @override
  String get noteFreeDirect => '免费 · 中国直连';

  @override
  String get apiKeyHeader => 'API Key';

  @override
  String apiKeyLabel(String provider) {
    return '$provider API Key';
  }

  @override
  String get apiKeyFooterDefault => '输入即保存。仅安全存储在本机。';

  @override
  String get apiKeyFooterQwen =>
      '从 bailian.console.aliyun.com（阿里云百炼 → API-KEY）获取。新账户每个模型约有 100 万免费 tokens。仅安全存储在本机。';

  @override
  String get apiKeyFooterDoubao =>
      '从 console.volcengine.com/ark 获取（API Key + 开通管理里激活模型）。每个模型 50 万免费 tokens。仅安全存储在本机。';

  @override
  String get apiKeyFooterGlm =>
      '从 open.bigmodel.cn 获取（需实名认证）。默认 flash 模型免费。仅安全存储在本机。';

  @override
  String get modelHeader => '模型';

  @override
  String get modelCustomRow => '自定义 — 输入模型名…';

  @override
  String get modelCustomLabel => '自定义模型名';

  @override
  String get apiInactiveFooter => '当前使用的是订阅。在上方选择一家服务商即可切换为按张计费的 API Key。';

  @override
  String get subPageTitle => '订阅';

  @override
  String get planHeader => '套餐';

  @override
  String get planFooter =>
      '固定月费：你自己的云服务器登录一个套餐并用它分析照片 — 每张照片不再额外花钱。套餐凭证保存在那台机器上。';

  @override
  String get planClaude => 'Claude 订阅';

  @override
  String get planClaudeNote => 'Anthropic 订阅';

  @override
  String get planGlm => 'GLM 编程套餐';

  @override
  String get planDoubao => '豆包 Agent 套餐';

  @override
  String get serverHeader => '你的服务器';

  @override
  String get serverFooter => '保存套餐登录并执行分析的云端机器 — 不是这台手机。手机上只保存与它通信的上传密钥。';

  @override
  String get serverAddressLabel => '服务器地址';

  @override
  String get serverUploadKeyLabel => '服务器上传密钥';

  @override
  String get connectClaude => '连接 Claude';

  @override
  String get connectClaudeFooter => '让服务器登录你的 Anthropic 订阅。中国大陆需要 VPN。';

  @override
  String get subInactiveFooter => '当前使用的是 API Key。在上方选择一个套餐即可切换为经你服务器的订阅分析。';

  @override
  String get connectDialogTitle => '完成 Claude 连接';

  @override
  String get connectDialogBody => '在刚打开的 Anthropic 页面登录，它会显示一个代码 — 粘贴到这里。';

  @override
  String get connectCodeLabel => '授权代码';

  @override
  String get connect => '连接';

  @override
  String get connectStartFailed => '无法开始登录。';

  @override
  String get connectBrowserFailed => '无法打开浏览器。';

  @override
  String get connectDone => 'Claude 已连接 — 分析将使用你的订阅。';

  @override
  String get profilePageTitle => '饮食偏好';

  @override
  String get profileFooter =>
      'AI 分析每张照片时都会参考的偏好和背景 — 例如\"素食\"、\"广式家常菜，少油\"、\"减脂期，高蛋白\"。输入即保存。';

  @override
  String get profileHint => '还没有内容 — AI 将按无特殊偏好处理。';

  @override
  String get addSheetTitle => '记录一餐';

  @override
  String get addFromPhotos => '从最近照片选择';

  @override
  String get addDescribe => '文字描述一餐';

  @override
  String get addDescribeNote => '任何语言';

  @override
  String get addManual => '手动输入';

  @override
  String get addManualNote => '不用 AI';

  @override
  String get addFix => '修改或删除某餐';

  @override
  String get addFixFooter => '\"第二餐是烤鸭\" · \"删除第一餐\"';

  @override
  String get addPhotosTip => '小提示：照片里带上筷子或手，AI 估算分量更准。';

  @override
  String get addNoPhotos => '没有找到最近的照片。';

  @override
  String get analyzing => '分析中…';

  @override
  String get reportTitle => '今日饮食';

  @override
  String reportMeals(int count) {
    return '$count 餐';
  }

  @override
  String get reportNoMeals => '没有记录。';

  @override
  String get reportFooter => '由筷拍记录';

  @override
  String typicalDayHeadroom(String typical, String delta) {
    return '日常：~$typical 千卡 · 剩余 ~$delta 千卡';
  }

  @override
  String typicalDayOver(String typical, String delta) {
    return '日常：~$typical 千卡 · 超出 ~$delta 千卡';
  }

  @override
  String get historyDayPattern => 'M月d日 EEEE';

  @override
  String garminBurnLine(String burn, String net) {
    return '活动消耗：~$burn 千卡（Garmin）· 净摄入 ~$net 千卡';
  }

  @override
  String get settingsRowUnits => '单位';

  @override
  String get unitsMetric => '公制';

  @override
  String get unitsImperial => '英制';

  @override
  String get unitsMetricDetail => '公制 — 公斤 · 厘米';

  @override
  String get unitsImperialDetail => '英制 — 磅 · 英寸';

  @override
  String get unitsSheetTitle => '单位';

  @override
  String get unitsFooter => '身体体重与围度的显示和输入单位。食物始终使用克与千卡。';

  @override
  String get bodyEmptyHintImperial =>
      '点击\"记录\"来记体重或腰围、胸围、臀围。通过对话记录的体重（\"我今天 81.6 公斤\"）也会显示在这里。';

  @override
  String bodySince(String date) {
    return '自 $date';
  }

  @override
  String get addLeftover => '记录剩菜';

  @override
  String get addLeftoverNote => '扣除没吃完的部分';

  @override
  String get leftoverTitle => '剩菜扣除';

  @override
  String get leftoverPickMeal => '这是哪一餐的剩菜？';

  @override
  String get leftoverPickPhoto => '选择剩下食物的照片 — 这餐的热量会减为实际吃掉的部分。';

  @override
  String get leftoverChangeMeal => '更换';

  @override
  String get leftoverNotSame => '照片看起来不是这一餐';

  @override
  String get leftoverUseAnyway => '仍然使用';

  @override
  String get leftoverResultTitle => '确认扣除剩菜？';

  @override
  String leftoverResultLine(String pct, String kcal, String now) {
    return '吃了约 $pct% — 扣除 $kcal 千卡，这餐现在 $now 千卡。';
  }

  @override
  String leftoverDupRemoved(String kcal) {
    return '这张照片还被误记成了一餐（$kcal 千卡）— 该重复记录将一并删除。';
  }

  @override
  String get leftoverApplied => '已扣除剩菜。';

  @override
  String get leftoverFailed => '无法从这张照片估算剩菜。';

  @override
  String get leftoverNoMeals => '今天和昨天没有可扣除的餐。';

  @override
  String get planTuningHeader => '模型与思考';

  @override
  String get planTuningFooter =>
      '服务器用哪个 Claude 模型分析、思考多少。默认跟随服务器自身设置；仅 Claude 订阅提供此选项 — 其他套餐由服务商决定模型。';

  @override
  String get planModelRow => '模型';

  @override
  String get planEffortRow => '思考力度';

  @override
  String get planChoiceDefault => '服务器默认';

  @override
  String get planModelOpus => 'Opus — 最准确';

  @override
  String get planModelSonnet => 'Sonnet — 均衡';

  @override
  String get planModelHaiku => 'Haiku — 最快';

  @override
  String get planEffortLow => '低 — 最快';

  @override
  String get planEffortMedium => '中';

  @override
  String get planEffortHigh => '高 — 最仔细';

  @override
  String get planModelFable => 'Fable — 旗舰 · Pro 需另购额度';

  @override
  String typicalDayOnly(String typical) {
    return '日常：~$typical 千卡';
  }

  @override
  String get garminIdleLine => 'Garmin 已连接 · 今天还没有活动数据';

  @override
  String coachTitle(String kcal) {
    return '今天：$kcal 千卡';
  }

  @override
  String coachTitleYesterday(String kcal) {
    return '昨天：$kcal 千卡';
  }

  @override
  String get coachEmpty => '今天还没有记录。拍下一餐，它会自动出现在这里。';

  @override
  String get coachEmptyYesterday => '昨天没有记录。拍下一餐，它会自动出现在这里。';

  @override
  String coachUnderGoal(String delta) {
    return '比目标少 $delta 千卡 —— 实打实的缺口，这种自律会累积成结果。💪';
  }

  @override
  String coachUnderTypical(String delta) {
    return '比你平时少 $delta 千卡。今天很棒，这样的一天才是真正有效的。';
  }

  @override
  String get coachOnTarget => '今天正好达标。稳定比猛冲更重要，继续保持。';

  @override
  String coachOverGoal(String delta) {
    return '今天比目标多 $delta 千卡。一天不会毁掉一周，明天继续。';
  }

  @override
  String coachOverTypical(String delta) {
    return '今天比平时多 $delta 千卡。知道就好，不用焦虑 —— 明天重新开始。';
  }

  @override
  String get coachNoReference => '已记录。再积累几天，我就能告诉你今天和平时比如何了。';

  @override
  String coachDetail(String meals, String protein) {
    return '$meals 餐 · 蛋白质 $protein 克';
  }

  @override
  String get settingsRowGoal => '每日热量目标';

  @override
  String get goalSheetTitle => '每日热量目标';

  @override
  String get goalNotSet => '未设置';

  @override
  String get goalFooter => '每日总结会以此为基准。留空则与你的日常水平比较。';

  @override
  String get goalFieldLabel => '千卡 / 天';

  @override
  String get goalClear => '清除目标';

  @override
  String get macroProtein => '蛋白质';

  @override
  String get macroCarbs => '碳水';

  @override
  String get macroFat => '脂肪';

  @override
  String get macroProteinShort => '蛋';

  @override
  String get macroCarbsShort => '碳';

  @override
  String get macroFatShort => '脂';

  @override
  String get editorProteinLabel => '蛋白质（克）';

  @override
  String get editorCarbsLabel => '碳水（克）';

  @override
  String get editorFatLabel => '脂肪（克）';

  @override
  String get diagTitle => '测试 AI 服务';

  @override
  String get diagIntro =>
      '逐步检查你的 AI 配置，并准确指出问题所在：配置、网络（VPN）、Key、账户余额、返回格式和额度。运行测试会消耗两次小的 AI 调用。';

  @override
  String get diagRunning => '测试中…';

  @override
  String get diagRunAgain => '重新测试';

  @override
  String get diagRunChecks => '开始检查';

  @override
  String get diagVerdictOk => '一切正常。如果某张照片仍然失败，那是这张照片的问题 —— 对它试试“重新分析”。';

  @override
  String diagVerdictProblems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '发现 $count 个问题 —— 下面红色/橙色的行说明该怎么做。',
    );
    return '$_temp0';
  }

  @override
  String get diagStageTestRun => '测试运行';

  @override
  String get diagTestRunFailed => '检查本身中途失败了。';

  @override
  String get diagFixTestRun => '重新运行；如果一直卡在这里，说明服务返回的内容应用完全无法解析。';

  @override
  String get diagStageConfiguration => '配置';

  @override
  String get diagStageEndpoint => '网络连通性';

  @override
  String get diagStageAuth => '身份验证';

  @override
  String get diagStageText => '文字分析';

  @override
  String get diagStagePhoto => '照片分析';

  @override
  String get diagStageQuota => '额度';

  @override
  String get diagNoServerAddress => '还没有设置服务器地址。';

  @override
  String get diagFixEnterServer => '先在设置里填写服务器地址，然后重新测试。';

  @override
  String get diagNoUploadKey => '还没有设置服务器上传 Key。';

  @override
  String get diagNoApiKey => '这个服务还没有设置 API Key。';

  @override
  String get diagFixPasteKey => '把 Key 粘贴到设置里，然后重新测试。';

  @override
  String diagServerConfigured(String backend) {
    return '服务器地址和上传 Key 都已设置（后端：$backend）。';
  }

  @override
  String diagProviderConfigured(String provider, String model) {
    return '服务“$provider”已配置 Key，模型为“$model”。';
  }

  @override
  String get diagTargetServer => '服务器';

  @override
  String get diagTargetYourServer => '你的服务器';

  @override
  String diagEndpointAnswered(String target) {
    return '$target的接口有响应。';
  }

  @override
  String diagEndpointUnreachable(String target) {
    return '完全连不上$target。';
  }

  @override
  String get diagFixVpn =>
      '这个服务在中国大陆需要 VPN 才能访问。请打开 VPN，或改用通义千问 / 豆包 / 智谱 GLM（无需 VPN）。';

  @override
  String get diagFixServerUnreachable => '检查服务器地址、服务器是否在运行，以及你的网络。';

  @override
  String get diagFixNetwork => '检查网络连接后重试。';

  @override
  String get diagKeyAccepted => '服务已接受你的 Key。';

  @override
  String get diagOutOfCredit => 'Key 有效，但账户当前无法扣费。';

  @override
  String get diagFixTopUp => '给服务账户充值，或改用免费额度（智谱 GLM 的默认视觉模型免费，在中国大陆也无需 VPN）。';

  @override
  String get diagRateLimited => 'Key 有效，但服务正在限流。';

  @override
  String get diagFixWaitRateLimit => '等一分钟再试；期间照片会被保留并自动重试。';

  @override
  String get diagKeyRejected => 'Key 未被接受。';

  @override
  String get diagFixRecopyKey =>
      '从服务商控制台重新复制 Key —— 并确认它属于当前这个服务（不同服务的 Key 不能混用）。';

  @override
  String get diagTextOk => '模型返回了 JSON —— 对话纠正和“描述一餐”都可用。';

  @override
  String get diagTextBad => '模型没有为文字请求返回可用的 JSON。';

  @override
  String get diagTextBadDetail => '对话纠正和“描述一餐”可能失败；照片分析仍然可以正常工作。';

  @override
  String get diagFixPickModel => '如果一直这样，在设置里换一个模型。';

  @override
  String get diagPhotoOk => '模型分析了测试图片，并按用餐格式返回。';

  @override
  String get diagPhotoThoughtFood => '它甚至认为测试图案是食物。';

  @override
  String get diagPhotoNotFood => '判定为“不是食物”—— 对这张测试图片来说是正确的。';

  @override
  String get diagPhotoTempFail => '照片分析失败，属于临时性问题。';

  @override
  String get diagPhotoPermFail => '照片分析失败，重试也无法解决。';

  @override
  String get diagFixPhotoTemp => '通常是限流或服务器繁忙 —— 照片会被保留并自动重试。';

  @override
  String get diagFixPhotoPerm => '看上面的信息 —— 它会指出坏掉的环节（模型、格式或账户）。';

  @override
  String get diagQuotaPaused => '分析已暂停 —— 今天的额度已用完。';

  @override
  String diagQuotaPausedUntil(String until) {
    return '暂停至 $until。';
  }

  @override
  String get diagFixQuota => '等待恢复（照片会保留），或更换 Key / 服务立即恢复。';

  @override
  String get diagQuotaOk => '没有额度暂停。';
}
