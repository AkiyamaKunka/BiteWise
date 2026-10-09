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
  String ringSemantics(String kcal) {
    return '今天已摄入 $kcal 千卡';
  }

  @override
  String ringSemanticsTypical(String kcal, String typical) {
    return '今天已摄入 $kcal 千卡，日常一天约 $typical 千卡';
  }

  @override
  String ringSemanticsAboveTypical(String kcal, String typical) {
    return '今天已摄入 $kcal 千卡，日常一天约 $typical 千卡（高于日常）';
  }

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
  String get bodyWaistShort => '腰';

  @override
  String get bodyChestShort => '胸';

  @override
  String get bodyHipShort => '臀';

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
  String get providerQuotaPaused =>
      '分析已暂停 — 已达当日额度。新照片会保留并自动重试；更换 Key 或服务后立即恢复。';

  @override
  String providerQuotaPausedUntil(String time) {
    return '分析已暂停 — 已达当日额度（$time 恢复）。新照片会保留并自动重试；更换 Key 或服务后立即恢复。';
  }

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
  String get settingsRowNextSummary => '下次总结';

  @override
  String timeToday(String time) {
    return '今天 $time';
  }

  @override
  String timeTomorrow(String time) {
    return '明天 $time';
  }

  @override
  String get nextSummaryNone => '未安排';

  @override
  String timeYesterday(String time) {
    return '昨天 $time';
  }

  @override
  String get settingsRowBackgroundScan => '后台扫描';

  @override
  String get backgroundScanNever => '尚未运行';

  @override
  String get backgroundScanDisabled => '系统已关闭';

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
      '按张计费：Key 保存在这台手机上，每张照片都是一次由服务商计费的 API 调用。中国大陆请选择 DeepSeek、Qwen、Doubao 或 GLM — 其余需要 VPN。';

  @override
  String get noteVpn => '需要 VPN';

  @override
  String get noteFreeTierVpn => '免费额度 · VPN';

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
  String get apiKeyFooterDeepseek =>
      '从 platform.deepseek.com 获取（API keys）。按量付费，中国大陆可直连。仅安全存储在本机。';

  @override
  String get apiKeyFooterXai => '从 console.x.ai 获取（API keys）。按量付费。仅安全存储在本机。';

  @override
  String get apiKeyFooterOpenrouter =>
      '从 openrouter.ai/keys 获取。一个 Key 可用 GPT、Claude、Gemini、Grok、DeepSeek 等多家模型，部分模型免费。仅安全存储在本机。';

  @override
  String get modelHeader => '模型';

  @override
  String get modelCustomRow => '自定义 — 输入模型名…';

  @override
  String get modelCustomLabel => '自定义模型名';

  @override
  String modelHelperDefault(String model) {
    return '默认：$model';
  }

  @override
  String modelHelperQwen(String model) {
    return '默认：$model。它也是便宜档 — qwen3-vl-plus 是更强的付费模型。';
  }

  @override
  String modelHelperDoubao(String model) {
    return '默认：$model。豆包需要方舟模型列表里带日期的完整模型 ID — 不带日期的名称会被拒绝。';
  }

  @override
  String modelHelperGlm(String model) {
    return '默认：$model（免费档）。glm-4.6v 是更强的付费模型。';
  }

  @override
  String modelHelperDeepseek(String model) {
    return '默认：$model — DeepSeek 唯一能识别照片的模型。';
  }

  @override
  String modelHelperOpenrouter(String model) {
    return '默认：$model。openrouter.ai/models 里任何支持图片的 厂商/模型 名称都可以。';
  }

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
  String get planGlmNote => '智谱订阅';

  @override
  String get planDoubaoNote => '火山引擎订阅';

  @override
  String get noteManyModels => '多家模型';

  @override
  String get nlDeleteTitle => '删除这些餐？';

  @override
  String get nlCannotUndo => '此操作无法撤销。';

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
  String get addPhotosLimited => '只显示你允许访问的照片，之后拍的照片不会出现在这里。请在系统设置里允许访问所有照片。';

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
  String garminBurnOnlyLine(String burn) {
    return '活动消耗：~$burn 千卡（Garmin）';
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
  String get planEffortLowShort => '低';

  @override
  String get planEffortHighShort => '高';

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
    return '比你平时少 $delta 千卡。很棒，这样的一天才是真正有效的。';
  }

  @override
  String coachPartialGoal(String delta) {
    return '比目标少 $delta 千卡 —— 还有没记上的餐吗？在筷拍里补上就好。';
  }

  @override
  String coachPartialTypical(String delta) {
    return '比平时少 $delta 千卡 —— 还有没记上的餐吗？在筷拍里补上就好。';
  }

  @override
  String get coachOnTarget => '正好达标。稳定比猛冲更重要，继续保持。';

  @override
  String get coachOnTypical => '和你平时差不多。稳定比猛冲更重要，继续保持。';

  @override
  String coachOverGoal(String delta) {
    return '比目标多 $delta 千卡。一天不会毁掉一周，接着来就好。';
  }

  @override
  String coachOverTypical(String delta) {
    return '比平时多 $delta 千卡。知道就好，不用焦虑 —— 下一餐重新开始。';
  }

  @override
  String get coachNoReference => '已记录。再积累几天，我就能告诉你和平时比如何了。';

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
  String diagModelNotFound(String model) {
    return 'Key 有效，但找不到模型“$model”。';
  }

  @override
  String get diagTextOk => '模型返回了 JSON —— 对话纠正和“描述一餐”都可用。';

  @override
  String get diagTextBad => '文字请求没有成功（服务器忙、限流或额度窗口未开、超时，或模型没有返回 JSON）。';

  @override
  String get diagTextBadDetail => '对话纠正和“描述一餐”可能失败；照片分析仍然可以正常工作。';

  @override
  String get diagFixPickModel => '如果一直这样，在设置里换一个模型。';

  @override
  String get diagTextBadPhotoAlsoFailed =>
      '对话纠正和“描述一餐”可能失败。下面的照片请求也失败了，那一行的原因很可能就是两者共同的原因。';

  @override
  String get diagFixTextPickModel => '如果照片分析正常而这里一直失败，再在设置里换一个模型。';

  @override
  String get diagFixTextFollowPhoto => '先按照片那一行的建议处理，再重新测试。';

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

  @override
  String get addPhotosTitle => '最近照片';

  @override
  String get addPhotoUnreadable => '无法读取这张照片（太大或已被删除）。';

  @override
  String addPhotosLoadFailed(String error) {
    return '无法加载照片：$error';
  }

  @override
  String photoCellLabel(int n, int total, String when) {
    return '第 $n/$total 张照片，$when';
  }

  @override
  String get photoPermissionDenied => '筷拍没有获得访问照片的权限。';

  @override
  String get openSystemSettings => '打开系统设置';

  @override
  String get outcomeSaved => '已记录一餐';

  @override
  String get outcomeSkipped => '没有识别到食物';

  @override
  String get outcomeDuplicate => '重复的照片';

  @override
  String get outcomeAlreadyTracked => '已经记录过';

  @override
  String get outcomeInFlight => '正在分析';

  @override
  String get outcomeFailed => '分析失败';

  @override
  String get outcomeLeftoverApplied => '已扣除剩菜';

  @override
  String get outcomeLogManuallyHint => '如果这确实是食物，可以手动记录 —— 照片会附在这一餐上。';

  @override
  String get outcomeUndoLeftover => '不是剩菜，记为新的一餐';

  @override
  String get outcomeUndoLeftoverDone => '已撤销扣除，之前那一餐已恢复原样。';

  @override
  String get outcomeUndoLeftoverStale => '那一餐之后被修改或删除了，所以没有改动它。';

  @override
  String get okButton => '好';

  @override
  String get logManually => '手动记录';

  @override
  String get describeTitle => '文字描述一餐';

  @override
  String get describeLabel => '你吃了什么？';

  @override
  String get describeHint =>
      '例如：\"一碗牛肉面加一个鸡蛋\"\n或 \"two eggs and toast with butter\"';

  @override
  String get describeHelp => '任何语言都可以。保存前你会看到估算结果，并且可以修改。';

  @override
  String get describeEstimating => '估算中…';

  @override
  String get describeEstimate => '估算这一餐';

  @override
  String get notificationsOffHint => '通知已关闭 —— 每日总结无法送达。';

  @override
  String outcomeSavedMsg(String summary) {
    return '已记录：$summary';
  }

  @override
  String outcomeLeftoverMsg(String summary) {
    return '已扣除剩菜：$summary';
  }

  @override
  String outcomeFailedKeptMsg(String reason) {
    return '照片分析失败，已保留以便重试。$reason';
  }

  @override
  String get backlogTruncatedWarning => '相册里待处理的照片太多 —— 一些较早的照片可能需要手动添加。';

  @override
  String get outcomeNotFoodMsg => '这张照片里没有识别到食物。';

  @override
  String get outcomeDuplicateMsg => '看起来和几分钟前记录的一张照片重复了。';

  @override
  String get outcomeAlreadyTrackedMsg => '这张照片已经记录过了。';

  @override
  String get outcomeInFlightMsg => '这张照片还在分析中，稍等片刻再看。';

  @override
  String get errNoApiKey => '当前服务还没有设置 API Key —— 请在设置里添加。';

  @override
  String get errNoServerKey => '还没有设置服务器地址或上传 Key —— 请在设置里添加。';

  @override
  String get errRejectedKey => '服务拒绝了 API Key，请在设置里检查。';

  @override
  String get errRateLimited => '服务正在限流 —— 照片已保留，稍后会自动重试。';

  @override
  String get errQuotaPaused => '分析已暂停：今天的额度已用完。照片已保留，稍后会自动重试。';

  @override
  String get errNetwork => '连不上服务（网络或服务问题）。照片已保留，稍后会自动重试。';

  @override
  String get errBadModel => '服务不接受这个模型 —— 请在设置里检查模型名。';

  @override
  String get errBadResponse => 'AI 返回的内容应用无法使用。';

  @override
  String get errBadPhoto => '无法处理这张照片（解码失败）。';

  @override
  String get errServerBusy => '你的服务器正在处理另一张照片 —— 照片已保留，稍后会自动重试。';

  @override
  String get mealCardAutoTitle => '🍽️ 已自动记录一餐';

  @override
  String dayLoadFailed(String error) {
    return '无法加载这一天：$error';
  }

  @override
  String get dayEmpty => '这一天还没有记录。点 + 添加一餐。';

  @override
  String get dayAddMealTooltip => '给这一天加一餐';

  @override
  String get notFoodTag => '非食物';

  @override
  String get correctedBadge => '已修正';

  @override
  String fixRequestFailed(String error) {
    return '请求失败：$error';
  }

  @override
  String get fixTitle => '修改某餐';

  @override
  String get fixIntro =>
      '说出要改或要删的内容 —— 用你习惯的方式描述那一餐（\"那碗面\"、\"早餐\"、\"600 千卡那个\"），任何语言都可以。要把某餐挪到别的日期或时间，请在「今天」或「历史」里点开那一餐，修改日期或时间。';

  @override
  String get fixNamingTip => '最稳妥的是说出食物名 —— 餐次编号是按最近 7 天算的，不只是今天。';

  @override
  String get fixLabel => '要改什么？';

  @override
  String get fixHint => '例如：\"那碗面其实是烧鸭饭\"\n或 \"删除刚才那杯咖啡\"';

  @override
  String get working => '处理中…';

  @override
  String get fixApply => '应用修改';

  @override
  String get fixAppliedHeader => '本次已应用';

  @override
  String editorSaveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String editorDeleteFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get editorDeleteTitle => '删除这一餐？';

  @override
  String get editorDeleteBody => '它会从历史和总计中移除。此操作无法撤销。';

  @override
  String get editorTitleAdd => '添加一餐';

  @override
  String get editorTitleEdit => '编辑这一餐';

  @override
  String get editorDeleteTooltip => '删除这一餐';

  @override
  String get editorDescriptionLabel => '吃了什么？';

  @override
  String get editorTotalsHeader => '总计';

  @override
  String get editorCaloriesLabel => '热量（千卡）';

  @override
  String get editorItemsHeader => '食物';

  @override
  String get editorTotalsDerivedHint => '总计随下面的食物变化';

  @override
  String get editorAddItem => '添加食物';

  @override
  String get editorAdd => '添加';

  @override
  String get editorItemLabel => '食物';

  @override
  String get editorRemoveItemTooltip => '移除';

  @override
  String editorErrNotNumber(String label) {
    return '$label必须是数字。';
  }

  @override
  String editorErrNegative(String label) {
    return '$label不能为负数。';
  }

  @override
  String editorErrTooLarge(String label, String max) {
    return '$label太大了（上限 $max）。';
  }

  @override
  String editorErrDescTooLong(String max) {
    return '描述太长了（上限 $max 字）。';
  }

  @override
  String get editorErrDate => '日期必须是真实存在的 YYYY-MM-DD 日期。';

  @override
  String get editorErrTime => '时间格式应类似 07:30 PM。';

  @override
  String editorErrTooManyItems(String max) {
    return '食物太多了（上限 $max 项）。';
  }

  @override
  String editorErrsNeedFixing(int count) {
    return '有 $count 处需要修改，请看顶部。';
  }

  @override
  String get editorFieldCalories => '热量';

  @override
  String editorItemFieldCalories(int n) {
    return '第 $n 项食物的热量';
  }

  @override
  String editorItemFieldProtein(int n) {
    return '第 $n 项食物的蛋白质';
  }

  @override
  String editorItemFieldCarbs(int n) {
    return '第 $n 项食物的碳水';
  }

  @override
  String editorItemFieldFat(int n) {
    return '第 $n 项食物的脂肪';
  }

  @override
  String get editorItemKcalLabel => '千卡';

  @override
  String get covPermissionRequired => '检查需要照片权限。';

  @override
  String covCheckFailed(String error) {
    return '检查失败：$error';
  }

  @override
  String get covNoAnalysis => '现在无法分析 —— 请为当前服务添加 Key，或等待额度暂停结束。';

  @override
  String covBulkTitle(String verb, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 张照片',
    );
    return '$verb $_temp0？';
  }

  @override
  String covBulkBody(int minutes, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes 分钟',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 次模型调用',
    );
    return '每张照片会依次单独分析 —— 预计约 $_temp0、$_temp1。你可以离开此页面，处理会继续。';
  }

  @override
  String get covPhotoUnreadable => '这张照片已无法读取。';

  @override
  String get covTitle => '照片覆盖检查';

  @override
  String covIntro(int days) {
    return '检查最近 $days 天的每张照片是否已记录：只做指纹比对 —— 检查本身不会把任何照片发给 AI。';
  }

  @override
  String get covChecking => '检查中…';

  @override
  String get covRun => '开始检查';

  @override
  String covNeverScanned(int count) {
    return '从未扫描（$count）';
  }

  @override
  String get covLogAll => '全部记录';

  @override
  String covMoreLogAll(int count) {
    return '…还有 $count 张 —— \"全部记录\" 会覆盖全部。';
  }

  @override
  String covJudgedNotFood(int count) {
    return '判定为\"非食物\"（$count）';
  }

  @override
  String get covAnalyzeAgain => '重新分析';

  @override
  String get covNotFoodHelp =>
      '饮品、订单截图和少见的菜会落在这里。\"重新分析\" 会再问一次 AI（规则改进后很有用）；点某一行可以手动录入。';

  @override
  String covFailedEarlier(int count) {
    return '之前失败（$count）';
  }

  @override
  String get covRetryAll => '全部重试';

  @override
  String get covFailedHelp => '\"全部重试\" 会再问一次 AI（同样的错误多半会重现）；点某一行可以手动录入。';

  @override
  String covMoreRetryAll(int count) {
    return '…还有 $count 张 —— \"全部重试\" 会覆盖全部。';
  }

  @override
  String covAllAccounted(int count) {
    return '全部 $count 张照片都已记录。';
  }

  @override
  String covSummary(int scanned, int missing) {
    return '已检查 $scanned 张 —— $missing 张从未扫描。';
  }

  @override
  String get covLimitedAccess =>
      '注意：应用只有部分照片权限 —— 只能检查被选中的照片。在系统设置里授予完全访问才能得到完整结果。';

  @override
  String get covTruncated => '注意：这个窗口内超过 2000 张照片 —— 更早的没有检查。缩短窗口可得到完整结果。';

  @override
  String get covVerbLog => '记录';

  @override
  String get covVerbRetry => '重试';

  @override
  String get covProgLogging => '记录中';

  @override
  String get covProgReanalyzing => '重新分析中';

  @override
  String get covProgRetrying => '重试中';

  @override
  String covStopped(String label, int attempted, int total, int remaining) {
    String _temp0 = intl.Intl.pluralLogic(
      remaining,
      locale: localeName,
      other: '$remaining 张',
    );
    return '$label在第 $attempted/$total 张后停止：现在无法分析（额度暂停或缺少 Key）。剩下的 $_temp0没有处理 —— 稍后再运行一次。';
  }

  @override
  String covStoppedBecause(
    String label,
    int attempted,
    int total,
    String reason,
    int remaining,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      remaining,
      locale: localeName,
      other: '$remaining 张',
    );
    return '$label在第 $attempted/$total 张后停止：$reason剩下的 $_temp0没有处理 —— 稍后再运行一次。';
  }

  @override
  String covMoreNotFood(int count) {
    return '…还有 $count 张。';
  }

  @override
  String get covUnnamedPhoto => '（未命名照片）';

  @override
  String covDone(String label, int count) {
    return '$label完成（$count 张照片）。';
  }

  @override
  String covDoneFailures(String label, int failures, int count) {
    return '$label完成 —— $count 张中有 $failures 张无法处理（已保留在“之前失败”列表中以便重试）。';
  }

  @override
  String covDaysShort(int days) {
    return '$days 天';
  }

  @override
  String covLoggedAsMeals(int count) {
    return '已记录 $count 餐';
  }

  @override
  String covNotFoodCount(int count) {
    return '$count 张非食物';
  }

  @override
  String covLeftoverCount(int count) {
    return '$count 张剩菜照片（已从原餐扣除）';
  }

  @override
  String covFailedCount(int count) {
    return '$count 张失败';
  }

  @override
  String covDeletedCount(int count) {
    return '$count 张已被你删除';
  }

  @override
  String covInFlightCount(int count) {
    return '$count 张分析中';
  }

  @override
  String covUnreadableCount(int count) {
    return '$count 张无法读取';
  }

  @override
  String covTooLargeCount(int count) {
    return '$count 张过大无法分析';
  }

  @override
  String get macroNoBreakdown => '没有记录营养素分布。';

  @override
  String get setupLinkTitle => '通过这个链接配置服务器？';

  @override
  String setupLinkBody(String server, String backend, String keyTail) {
    return '服务器：$server\n套餐：$backend\n上传密钥：••••$keyTail\n\n你的餐食照片会发送到这台服务器进行分析，请确认它是你自己的。';
  }

  @override
  String get setupLinkConfirm => '使用这台服务器';

  @override
  String get setupLinkDone => '服务器已配置 —— 照片将通过你的套餐分析。';

  @override
  String get setupLinkInvalid => '这个配置链接无效。';

  @override
  String get serverLoginRow => '服务器 Claude 登录';

  @override
  String get serverLoginOk => '已登录 ✓';

  @override
  String get serverLoginMissing => '未登录';

  @override
  String get serverLoginUnknown => '无法检查';

  @override
  String get serverLoginChecking => '检查中…';

  @override
  String get serverLoginFooter =>
      '已登录：无需再连接。未登录：用下方“连接 Claude”。无法检查：服务器不可达或密钥被拒。';

  @override
  String get errServerFailed => '你的服务器这次没能分析这张照片 —— 已保留，稍后会自动重试。';

  @override
  String errServerRejected(String code) {
    return '你的服务器拒绝了这次请求（$code）。请把 App 和服务器更新到匹配的版本，然后在 设置 › 覆盖检查 里重试。';
  }

  @override
  String get watcherPermissionDenied => '自动记录需要相册访问权限。';

  @override
  String get watcherOnQuotaPaused => '监控已打开，但分析因当日额度已暂停 —— 新照片会先保留。';

  @override
  String get watcherOnNoKey => '监控已打开，但要等上方设置好可用的 API Key 后，照片才会被分析。';

  @override
  String get watcherLimitedAccess =>
      '目前只共享了部分选中的照片，新的食物照片不会被自动看到。请授予访问所有照片的权限，才能自动记录。';

  @override
  String get fixAction => '去修复';

  @override
  String get importDialogTitle => '导入已导出的数据';

  @override
  String get importDialogBody => '粘贴导出的 JSON 文件内容。已有的餐会保留，只会添加新的。';

  @override
  String get importAction => '导入';

  @override
  String get importNothingNew => '没有可导入的新内容 —— 那个文件里的记录这里都已经有了。';

  @override
  String importDone(int meals, int rows) {
    return '已导入 $meals 餐（共 $rows 行）。';
  }

  @override
  String importDoneKept(int meals, int rows, int kept) {
    return '已导入 $meals 餐（共 $rows 行）；$kept 条已存在。';
  }

  @override
  String importFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String exportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get exportShareSubject => '筷拍数据导出';

  @override
  String get importErrNotJson => '这个文件不是 JSON。';

  @override
  String get importErrNotExport => '这个文件不是筷拍的导出文件。';

  @override
  String get importErrWrongFormatTag => '这个文件不是筷拍的导出文件（格式标记不对）。';

  @override
  String get importErrBadVersion => '这份导出文件的版本标记无法使用。';

  @override
  String get importErrNoTables => '这份导出文件没有 tables 部分。';

  @override
  String get nlSomethingWrong => '❌ 处理这条消息时出了点问题，请重试。';

  @override
  String get nlMissingServer => '❌ 还没有配置服务器——请先在「设置」里填写服务器地址和上传密钥。';

  @override
  String nlMissingKey(String provider) {
    return '❌ 还没有 $provider 的 API 密钥——请先在「设置」里添加，才能用文字记录。';
  }

  @override
  String get nlTypeFirst => '先输入你吃了什么。';

  @override
  String get nlErrorContactingAi => '❌ 联系 AI 失败，请重试。';

  @override
  String get nlNoFoodDetected => '🚫 这段描述里没有识别出食物。';

  @override
  String nlInvalidMealIndex(String shown, int count) {
    return '❌ 餐次编号无效（$shown）。你最近有 $count 顿餐。';
  }

  @override
  String nlCorrectedMeal(int n) {
    return '✏️ 已修正第 $n 顿餐！';
  }

  @override
  String nlKcalChange(String oldKcal, String newKcal, String diff) {
    return '🔥 $oldKcal → $newKcal（$diff）';
  }

  @override
  String nlDeleteAsk(int count) {
    return '🗑️ 删除 $count 顿餐？';
  }

  @override
  String get nlDeleteCancelled => '👍 已取消——没有删除任何记录。';

  @override
  String nlDeletedMeals(int count) {
    return '🗑️ 已删除 $count 顿餐：';
  }

  @override
  String get nlAddedManualMeal => '✅ 已添加手动记录的一餐：';

  @override
  String nlMealLabel(String desc, String date, String time, String kcal) {
    return '$desc（$date $time，~$kcal）';
  }

  @override
  String get nlNoActions => '❌ 我没弄明白该做什么。请一次只说一件事，比如「把第 2 顿改成烧鸭饭」。';

  @override
  String get nlRequestFailed => '❌ 这个请求失败了，请重试。';

  @override
  String nlAllActionsFailed(int count) {
    return '❌ 请求的 $count 项操作全部失败，请重试。';
  }

  @override
  String nlSomeActionsFailed(int failed, int total) {
    return '⚠️ 请求的 $total 项操作中有 $failed 项失败——其余已生效。';
  }

  @override
  String get nlCannotCorrectNoMeals => '❌ 最近没有记录任何餐，无法修正。';

  @override
  String get nlCorrectionUnusable =>
      '❌ 这次修正没有给出可用的新分析，所以这顿餐保持不变。请换个说法，比如「第 2 顿是烧鸭饭，大约 780 千卡」。';

  @override
  String get nlCannotDeleteNoMeals => '❌ 最近没有记录任何餐，无法删除。';

  @override
  String get nlDeleteWhich => '❌ 没听清要删除哪几顿餐，请说得具体一点。';

  @override
  String get nlDeleteNoMatch => '❌ 在最近的记录里没有找到对应的餐。';

  @override
  String nlDescribedMultiple(int count) {
    return '这段描述包含 $count 顿餐——这里只显示第一顿。其余的请一次描述一顿。';
  }

  @override
  String get nlWeightUnreadable => '⚖️ 没有读到有效的体重（30–300 公斤）。试试「我今天 72.5 公斤」。';

  @override
  String nlWeightLogged(String kg, String date) {
    return '⚖️ 已记录 $date 的体重：$kg 公斤。';
  }

  @override
  String get nlActivityUnreadable => '🏃 没有找到可记录的运动数据。试试「跑了 5 公里，消耗 450 千卡」。';

  @override
  String nlActivityLogged(String bits, String date) {
    return '🏃 已记录活动：$bits（$date）。';
  }

  @override
  String nlStepsAmount(String steps) {
    return '$steps 步';
  }

  @override
  String nlKmAmount(String km) {
    return '$km 公里';
  }

  @override
  String get nlChatFallback => '我不太明白你的意思。试着描述一顿餐，或者说说要改什么吧！';
}
