<!--
Maintainer notes. Nothing in this comment is shown on GitHub.

This is the Simplified Chinese README. It follows README.md section by section,
with the same facts, links and caveats. Change both files in the same commit.
The release-tied lines listed at the top of README.md exist here too.

Rules for this file:
1. Screen, button and setting names are copied from app/lib/l10n/app_zh.arb and
   sit inside 「」. In prose the app is 筷拍.
2. Bold next to Chinese punctuation breaks on GitHub. A closing ** that comes
   right after 。 or 」 must be followed by punctuation, a space or the end of
   the line. An opening ** right before 「 must start the line or follow a
   space. So a bold label ends before its colon ("**标签**：正文"), and a
   control name in the middle of a sentence gets 「」 and no bold.
3. The pictures are in docs/readme/zh/ and show the 1.5.0 look in Chinese.
   Pad the six phone screenshots like the English ones: 14 transparent pixels
   above and below, 540 x 1201.
4. docs/PRIVACY.md has a Chinese half, linked here as docs/PRIVACY.md#中文.
   The other linked documents are in English only, and the text says so
   with （英文） after the link, or once at the top of 写给开发者.
5. One caveat is repeated on purpose. Step 1 of 开始使用 says again that the
   app is not on the mainland China App Store. Everything else has a
   counterpart in README.md, and nothing here goes beyond it.
6. Word map: "AI service" is AI 服务, "provider" is 服务商, "meal" is 一餐 or
   餐食, "portion" is 分量, "estimate" is 估算, "calories" is 热量.
-->

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

<div align="center">

# Chopstats · 筷拍

**让食物照片变成你的热量记录。**

一款免费、开源的 iPhone 热量记录应用。像平时一样拍下每一餐，在应用里选一张照片，你选择的 AI 服务就会估算这一餐的热量、蛋白质、碳水和脂肪。每个数字你都可以核对和修改。

<a href="https://apps.apple.com/app/id6828989410"><img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/zh-cn" width="180" alt="在 App Store 下载"></a>

免费 · 无 App 内购买 · iPhone，iOS&nbsp;15 或更高版本

需要准备一个你所选 AI 服务的 Key。默认选中的 Google Gemini 有免费额度。

</div>

<p align="center">
  <img src="docs/readme/zh/hero.png" width="100%" alt="三个筷拍页面：「记录一餐」面板，带热量圆环和餐食卡片的「今天」页面，以及显示每日总量的「历史」柱状图。">
</p>

<p align="center"><sub>截图来自 App Store 版本 1.5.0，内容为演示数据。</sub></p>

<div align="center">

筷拍不需要账户，没有广告，不做追踪。饮食记录保存在你的手机上。你记录的照片和文字描述会发送给你选择的 AI 服务，开发者不会收到你的任何数据。

[开始使用](#开始使用) · [费用](#费用) · [隐私](#隐私)

<sub>支持简体中文和英文 · 未在中国大陆区 App Store 上架 · Android：未上架 Google Play，开发者可以<a href="#android">从源码构建</a></sub>

</div>

## 开始使用

1. **下载应用**：从 [App Store](https://apps.apple.com/app/id6828989410) 下载筷拍（中国大陆区 App Store 未上架）。
2. **准备一个 API Key**：Key 是你在 AI 服务商网站上创建的一串字符。应用默认选中 Google Gemini，它有免费额度。各家的 Key 在哪里创建，见[支持页面](docs/SUPPORT.md#getting-started-bring-your-own-key)（英文）。如果产生费用，你付给的是服务商，不是筷拍。
3. **粘贴 Key**：打开「设置 › AI 服务 › API Key」，把 Key 粘贴进去。然后返回上一页，点「测试当前服务」。第一次发送任何内容之前，应用会先征求你的同意，点「允许」。
4. **记录一餐**：打开「今天 › 记录 › 从最近照片选择」，选一张餐食照片。你的 AI 会识别菜品，并估算热量、蛋白质、碳水和脂肪。核对这些数字，看着不对的就改掉。

## 主要功能

- **用照片记录一餐**：从最近照片里选一张，或者从「照片」应用分享进来。
- **需要的话，可以打开自动记录**：「监控相册」这项设置会自动记录新的食物照片，默认关闭。开启期间，每一张新照片，不管拍的是不是食物，都会发送给你的 AI 服务商，由它判断照片里是不是一餐。
- **核对 AI 的假设**：应用要求 AI 写明估算时假设的分量，例如“米饭（~150 克）”，还要求它先读营养成分表或印出来的重量，然后才凭目测估算。
- **每个数字都可以改**：点开某一餐直接编辑，或者输入一句修改，例如“第二餐是烤鸭”。
- **扣除剩菜**：拍下没吃完的部分，这一餐的热量会减为你实际吃掉的量。
- **不用照片也能记**：用文字描述一餐，例如“一碗牛肉面加一个鸡蛋”，你的 AI 能读懂的语言都可以。也可以自己输入数字，不用 AI，也不需要 Key。
- **看清今天，也看清趋势**：「今天」把已摄入的热量和你的日常水平放在一起对照。「历史」可以回看 30 天。「身体」把体重画成趋势图，并记录腰围、胸围和臀围。每日总结通知可开可关。

<p align="center">
  <img src="docs/readme/zh/today.png" width="250" hspace="8" alt="「今天」页面。热量圆环把今天已摄入的热量和日常水平放在一起，下面是蛋白质、碳水和脂肪的进度条。再往下是餐食卡片，列出每样食物、估算时假设的分量和热量。">
  <img src="docs/readme/zh/editor.png" width="250" hspace="8" alt="「编辑这一餐」页面。可以填写这一餐的名称、日期和时间，以及热量、蛋白质、碳水和脂肪的总计。一条色带显示蛋白质、碳水和脂肪各占多少热量，下面每样食物一行，都可以修改。">
</p>

<details>
<summary><b>更多功能和截图</b></summary>

这里列出的功能，App Store 版本里都有。

**记录**

- **饮品**：应用要求 AI 把咖啡、茶、果汁、汽水、奶茶、奶昔和啤酒记下来，白水不记。
- **订单、小票和营养成分表**：应用还要求 AI 读取外卖订单确认页、小票或营养成分表上的文字，据此记录一餐。效果如何，取决于你选的 AI。
- **饮食偏好**：写一句话，例如“素食”或“家常菜，少油”，AI 分析每张照片时都会参考。
- **剩菜的两种记法**：如果你的 AI 认出照片里是当天早些时候记录过的某一餐剩下的，应用会扣减那一餐，不会再多记一餐。你也可以在「今天 › 记录 › 记录剩菜」里自己选是哪一餐、用哪张剩菜照片，今天和昨天的餐食都可以选。
- **用你自己的话修改**：在「今天 › 记录 › 修改或删除某餐」里输入“第二餐是烤鸭”或“删除第一餐”。删除一餐之前，应用一定会先请你确认。

**照片**

- **一张照片只分析一次**：同一个照片文件，应用不会分析第二次。
- **按照片的拍摄日期记录**：一餐会记在照片拍摄的那一天，前提是那一天在最近 45 天以内。周六拍的照片周一才记录，也会记在周六。
- **缩略图一直保留**：用照片记录的每一餐，应用里都会留一张小缩略图。之后你把照片从相册里删掉，缩略图也还在。
- **「照片覆盖检查」**：这个页面列出最近的照片，标明哪些已经记录，其余的可以重试。

**今天和趋势**

- **没有记录的日子**：某一天什么都没记，「历史」会把它标为“无记录”。
- **蛋白质、碳水和脂肪的占比**：每一餐都会显示蛋白质、碳水和脂肪各占多少热量。
- **热量目标和每日总结**：每天在你设定的时间发一条通知，把当天的摄入和你的热量目标对比。如果没有设目标，就和你的日常水平对比，日常水平由应用根据此前 7 天的记录算出。这条通知可以关闭。
- **公制或英制单位**：英文界面可以用磅和英寸显示体重和围度。
- **把今天变成一张图**：应用可以把今天的饮食生成一张图片，方便你分享。
- **浅色和深色模式**：跟随手机的系统设置。

**你的 AI 和你的数据**

- **「测试当前服务」**：依次检查六项，分别是配置、网络、Key 与账户余额、文字分析、照片分析和额度。每一项都会说明哪里有问题、下一步该怎么做。
- **免费额度的上限**：Gemini 的免费额度达到当日上限后，应用会暂停分析，保留新照片，之后再重试。
- **导出**：「设置 › 你的数据 › 导出数据…」会生成一个 JSON 文件，里面有你的餐食、体重和身体围度，以及已处理照片的列表。设置、饮食偏好、缩略图和 API Key 不在文件里。
- **导入**：在另一台手机上打开「导入数据…」，粘贴文件里的文字，或者点「从剪贴板导入」。导入只会补上缺少的内容，已有的餐食不会重复。

<p align="center">
  <img src="docs/readme/zh/log.png" width="250" hspace="8" alt="「记录一餐」面板，共五行：从最近照片选择、记录剩菜、文字描述一餐、手动输入、修改或删除某餐。">
  <img src="docs/readme/zh/history.png" width="250" hspace="8" alt="「历史」页面。每日热量的柱状图和平均值，下面每天一行，显示当天的总量。">
</p>

<p align="center">
  <img src="docs/readme/zh/body.png" width="250" hspace="8" alt="「身体」页面。最新体重和体重趋势图，下面是腰围、胸围和臀围，以及按日期排列的历史记录。">
  <img src="docs/readme/zh/watch.png" width="250" hspace="8" alt="「设置」页面。「AI 服务」一行下面是「停止发送给 Gemini」一行。「监控相册」已打开，下方的说明写着：新照片会发送给你选择的 AI 服务，后台扫描由 iOS 决定何时运行。">
</p>

</details>

> [!NOTE]
> 热量和营养数据是 AI 根据照片和描述做出的估算，可能有误，请核对并修改。筷拍不是医疗器械，不提供医疗或营养建议。做出健康相关决定前，请咨询医生或注册营养师。

## 费用

应用免费，应用内也不出售任何东西。估算由你选择的 AI 服务商完成。如果服务商收费，费用由你直接付给它。

- **从 Google Gemini 开始**：它是应用的默认选项，有免费额度，每天有上限。按 Google 的说法，使用免费额度时，它可能把你发送的内容用于改进自己的产品。
- **或者换一家服务商**：OpenAI、Anthropic 和另外六家，每家都需要它自己的 Key。价格和额度会变，请查看服务商的定价页面。
- **或者完全不用 AI**：自己输入一餐的数字，不需要 Key，离线也能用。

## 隐私

你的餐食、体重和设置保存在你的手机上。应用里没有统计使用情况、上报崩溃或投放广告的代码。代码是公开的，任何人都可以核实这些说法。

交给 AI 分析的照片和文字，会发送给你的 AI 服务商。如果你运行了自己的服务器，则发送到那台服务器。应用还会附上 AI 需要的上下文，例如你的饮食偏好，或当天其他餐食的简短摘要。

- **照片不带位置**：应用发送的那份副本，不含拍摄地点和其他隐藏信息（元数据）。
- **「监控相册」开启期间会发送每一张新照片**：包括不是食物的照片。
- **先征求同意**：第一次向某家服务商发送任何内容之前，应用会弹出对话框，写明公司名称和要发送的内容。
- **你可以停止发送**：在「设置」里点「停止发送给 …」（后面是当前服务商的名称），应用就不再向这家服务商发送任何内容，「监控相册」也会关闭。
- **以服务商自己的条款为准**：它如何处理你的数据，由它的隐私政策决定。免费额度的条款可能不一样，[Gemini 就是如此](#费用)。

<details>
<summary><b>逐项说明：每种情况下发送了什么</b></summary>

这份清单针对 App Store 版本。接收方始终是你选择的 AI 服务商，或你自己的服务器。其中有两个会把数据再转交出去：OpenRouter 转交给你所选模型的厂商，你自己的服务器转交给服务器上登录的 AI 套餐。

- **用照片记录时**：一份缩小的照片副本，不含拍摄地点和其他元数据。一起发送的还有你的饮食偏好（如果你填写了），以及当天其他餐食的简短摘要，最多五餐。
- **打开「监控相册」时**：同上，对象是相册里的每一张新照片，不管是不是食物。打开开关时还会发送最近的照片，往回看多少天由「补扫回溯」这项设置决定。
- **记录剩菜时**：剩菜照片，以及你选的那一餐。
- **用文字描述一餐时**：你输入的文字和今天的日期。
- **输入一句修改，或要求删除某餐时**：你输入的文字、今天的日期，以及最近 7 天的餐食。
- **点「测试当前服务」时**：一条固定的测试消息和一张内置的测试图片。如果你填写了饮食偏好，也会一起发送。不会发送你的任何照片或餐食。
- **使用你自己的服务器时**：同样的数据会发送到你运行的那台服务器。只要保存了服务器地址，应用还会把日期发给它，用来请求当天的 Garmin 活动摘要。

应用不会向开发者发送任何内容。API Key 保存在 iOS 钥匙串里，也就是 iPhone 上存放密码和密钥的受保护区域。在 Android 上，Key 保存在由 Android Keystore 保护的加密存储里。手机自身的备份可能包含应用的数据。

餐厅营养查询还不在 App Store 版本里。它默认关闭，会在单独的页面上征求你的同意，数据的接收方也另有一份名单。隐私政策里已经列出了这些接收方。

</details>

你可以随时把数据导出为文件。完整细节见[隐私政策](docs/PRIVACY.md#中文)。

## Android

筷拍没有上架 Google Play，当前版本也还没有可以下载的 Android 安装包。本仓库里的 Android 代码是最新的，开发者可以[从源码构建应用](#从源码构建)。

<details>
<summary><b>2026 年 8 月的一个旧预览版</b></summary>

1.4.0 版放在 [Releases 页面](https://github.com/AkiyamaKunka/Chopstats/releases/tag/v1.4.0)上，是一个 APK（Android 的安装文件），适用于 arm64 手机。它比 iPhone 版早三个月，用的还是旧名字 Bitewise，和本页介绍的应用有这些不同：

- 发送照片时会带上照片里嵌入的元数据。如果相机记录了拍摄地点，地点也在其中。
- 没有征求同意的对话框，「监控相册」开始发送照片之前不会提示，也没有「停止发送给 …」这一项。
- 九家服务商里只有六家（没有 DeepSeek、xAI 和 OpenRouter），也没有每日热量目标。

今后的 Android 版本不能直接覆盖安装。你需要先卸载这个旧版，所以升级前请先导出数据。

</details>

## 常见问题

<details>
<summary><b>这些数字有多准？</b></summary>

这些数字都是估算，可能有误。没有人测量过这款应用的准确度，所以本页不给出任何准确率数字。

针对误差，应用做了三件事。第一，要求 AI 优先采用印出来的数字，其次才是猜测。第二，要求 AI 把假设的分量写进每样食物的名称里，假设错了你能看出来。第三，每个数字你都可以改。

优先采用印出来的数字，是一条[写给 AI 的指令](shared/prompts/estimation_priority.txt)（英文）。效果如何，取决于你选的 AI。应用不会显示某个数字的来源，比如是来自营养成分表，还是目测估算。

</details>

<details>
<summary><b>不打开应用，它也能记录吗？</b></summary>

可以，前提是打开「监控相册」。它需要一个 API Key 和访问所有照片的权限，还要打开系统的「后台 App 刷新」。

在 iPhone 上，应用什么时候可以在后台扫描新照片，由 iOS 决定，所以新照片不一定马上记录。如果你在多任务界面上滑关闭了筷拍，扫描会停止，直到你再次打开它。打开时，应用会补扫这期间拍的照片。如果你允许通知，应用在后台记录一餐后会发通知告诉你。

</details>

<details>
<summary><b>支持哪些 AI 服务商？它们在哪里处理我的数据？</b></summary>

有九家可以用 API Key 接入：Google Gemini、OpenAI、Anthropic Claude、xAI Grok、OpenRouter、DeepSeek 深度求索、Qwen 通义千问、Doubao 豆包和 GLM 智谱。全新安装时选中的是 Gemini。每家服务商都有一份简短的模型列表，模型就是它提供的某一个具体的 AI，你也可以自己输入模型名。更换服务商后，从下一次请求开始生效。

Gemini 有免费额度。GLM 的默认模型在应用里标为免费，GLM 账户需要实名认证。请查看服务商当前的定价。

DeepSeek、Qwen、Doubao 和 GLM 在中国大陆处理数据。在你允许之前，应用征求同意的对话框会写明这一点。每家服务商如何处理收到的数据，以它自己的隐私政策为准。

进阶用户也可以通过[自己运行的服务器](docs/SERVER.md)（英文）进行分析。

</details>

遇到问题？先试试「设置 › AI 服务 › 测试当前服务」，它会指出具体是哪里出了问题。然后可以看[支持页面](docs/SUPPORT.md)（英文），或者[提交 issue](https://github.com/AkiyamaKunka/Chopstats/issues)。issue 是公开的，千万不要在里面贴出 API Key、你的照片或个人信息。

## 即将推出

已经做好，也在公开的代码里，但还不在 App Store 版本中：

- **「我常吃的」**：你常吃的食物，点一下就能再记一次。不用拍照，也不用 AI。
- **餐厅营养查询**：如果是美国连锁餐厅的餐食，应用可以查找餐厅公布的营养信息。这项功能默认关闭，需要 Anthropic 或 OpenRouter 的 Key，或者你自己的服务器。

## 写给开发者

筷拍是一个面向 iPhone 和 Android 的 Flutter 应用，代码在 `app/`。仓库根目录还有一个可选的 Python 服务器，由你自行部署。本节链接的文档目前只有英文。

<p>
  <a href="https://apps.apple.com/app/id6828989410"><img src="https://img.shields.io/itunes/v/6828989410?label=version" width="96" alt="App Store 当前版本"></a>
  <a href="https://github.com/AkiyamaKunka/Chopstats/actions/workflows/python-tests.yml"><img src="https://img.shields.io/github/actions/workflow/status/AkiyamaKunka/Chopstats/python-tests.yml?branch=main&amp;label=tests" width="88" alt="main 分支的测试状态"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/AkiyamaKunka/Chopstats" width="78" alt="MIT 许可证"></a>
</p>

- **两套实现，保持一致**：Dart 应用和 Python 服务器不共用任何运行时代码。一份[行为规范](docs/APP_PORT_SPEC.md)为每条规则标出文件和行号，并列出有意保留的差异。[共享的常量和提示词](shared/)会为两边分别生成代码，两套测试回放的是同一批 [golden vectors](shared/vectors/)（标准测试向量）。
- **服务商的报错，用同一套说法**：一个[一致性测试](app/test/analyzer/provider_feedback_matrix_test.dart)把每家服务商的错误响应对照八类故障逐一检查。账户余额用完的用户，看到的提示是去充值，而不是重新创建 Key。
- **每张照片都记入台账**：照片以原始字节的 md5 作为标识，在五种状态之间流转。同一个文件不会分析两次。你删除一餐之后，监控也不会把它再记一遍。

每次推送，两套测试都会在 CI 里运行。2026-11-10 在 `main` 分支上统计，Dart 测试超过 3,500 个，Python 测试超过 2,300 个。架构图和细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：照片处理流程、拍摄日期的判定、剩菜的计算，以及服务器运维手册。

### 从源码构建

```bash
git clone https://github.com/AkiyamaKunka/Chopstats.git
cd Chopstats/app
flutter pub get
flutter run
```

需要安装 Flutter，自带的 Dart SDK 须为 3.12.2 或更高版本。然后按[开始使用](#开始使用)里的步骤，在应用里添加 Key。

- **装到 iPhone 真机**：用 Xcode 打开 `app/ios/Runner.xcworkspace`，设置你的签名团队。把两个 Bundle Identifier 和 App Group 改成你自己的，因为工程里现有的属于 App Store 上的那个应用。
- **构建 Android APK**：在仓库根目录运行 `bash scripts/build_share_apk.sh`。脚本会在 `~/Desktop/Chopstats-share/` 里生成一个 arm64 的 APK。Android 构建需要 JDK 17。在 Linux 上，请先设置 `JAVA_HOME`。

<details>
<summary><b>你自己的服务器（可选）</b></summary>

如果你对自己运行一台小型服务器没有把握，请跳过这一节。

仓库根目录里有一个 Python 服务器，由你在自己的机器上运行。在应用里选择「你自己的服务器」后，手机会用一个上传密钥，把照片和文字发送给它。

服务器通过 Claude Code CLI 执行分析，用的是这台服务器上已登录的 AI 套餐：Claude、GLM Coding Plan 或 Doubao Agent Plan。让应用的请求走这个套餐之前，请先查看套餐的使用条款。

- 手机上只保存一个上传密钥。套餐的登录凭证留在服务器上。
- 分析照片时，提示词由服务器自己生成。手机只提供其中用到的数据：你的饮食偏好、当天的餐食摘要，以及你选择的套餐、模型、思考力度和回复语言。
- 文字请求的提示词由手机发来，服务器运行它时不启用工具。
- 每次回复都会注明是哪个 AI 作答的，对不上时应用会拒收。
- 用一个配置链接或二维码，确认一次，就能填好应用里的服务器设置。
- 服务器上的 Claude 登录过期后，可以在手机上重新连接。
- 使用 Claude 时，可以在手机上选择模型（opus、sonnet、haiku 或 fable）和思考力度（低、中或高）。
- 只要保存了服务器地址，应用就会把日期发给它，用来请求当天的 Garmin 活动摘要。
- 最初的 Telegram 机器人还在仓库里，和服务器运行在同一个进程中。设置 `TELEGRAM_POLLING=0`，可以只运行手机用的 API，不启动机器人。

文档：[docs/SERVER.md](docs/SERVER.md) 讲安装配置、API，以及应用和服务器之间的请求流程，[docs/SERVER_DEPLOY.md](docs/SERVER_DEPLOY.md) 讲部署，[docs/SERVER_TLS.md](docs/SERVER_TLS.md) 讲 HTTPS。

</details>

<details>
<summary><b>对每家 AI 服务商做实时检查</b></summary>

模型名称和接口地址会变，所以仓库里除了使用模拟数据的契约测试，还有一个连接真实接口的检查：

```bash
scripts/test_providers_live.sh
```

它会通过应用自己的分析器，向每一家在 `~/.bitewise/provider_keys.env` 里配了 Key 的服务商，发送一张真实的照片和一条真实的文字请求。模板是 `scripts/provider_keys.env.example`，这个文件只留在你自己的机器上。

没有配 Key 的服务商同样会被探测。真实接口必须拒绝一个无效的 Key，应用也必须把它报告为 Key 的问题。这样可以发现写错的 URL、已经停用的接口，或者被误读的错误。

一个 OpenRouter 的 Key 可以一次跑完整个热门模型矩阵。OpenRouter 的公开模型目录不用 Key 也会被检查，所以应用里精选的模型列表一旦过时，就会被发现。

在应用里，「设置 › AI 服务 › 测试当前服务」会对当前选中的服务商做同一类分步检查。

</details>

<details>
<summary><b>运行检查</b></summary>

```bash
# 服务器测试
python3 -m pytest -q
# 应用测试
(cd app && flutter analyze && flutter test)
# 服务器和应用的共享绑定保持一致
python3 scripts/sync_shared.py --check
# 没有密钥或个人数据
bash scripts/check_public_safety.sh
```

每次推送，CI 都会运行这四项。Python 测试在 3.9 和 3.10 两个版本上运行，另有 `ruff` 检查和覆盖率下限。设置 `PUBLIC_SAFETY_SCAN_HISTORY=1` 后，安全检查还会扫描完整的 git 历史。

</details>

<details>
<summary><b>项目结构</b></summary>

- `app/`：面向 iPhone 和 Android 的 Flutter 应用。从这里看起。
- `shared/`：常量、提示词和标准测试向量，两边的代码都由它们生成。
- `telegram_bot.py`：可选的服务器。给应用用的 Flask API，外加 Telegram 机器人。
- `scripts/`：让两边保持一致的脚本、测试向量生成、APK 构建和安全检查。
- `tests/` 和 `app/test/`：Python 测试和 Dart 测试。
- `docs/ARCHITECTURE.md`：应用的架构，它如何与服务器保持一致，以及服务器运维手册。
- `docs/APP_PORT_SPEC.md`：两套实现共同遵循的行为规范。
- `docs/SERVER.md`：运行你自己的服务器。分析后端、Telegram 机器人和应用 API。
- `docs/RELEASING.md`：App Store 和 Android 的签名发布流程，以及项目所有者的检查清单。
- `docs/PRIVACY.md` 和 `docs/SUPPORT.md`：隐私政策和支持页面，App Store 的应用页面上都有链接。
- `android/` 和 `ios/`：早期给服务器用的上传客户端（Termux、快捷指令）。它们不是这个应用。

</details>

欢迎提交 issue 和 pull request。有两条规则比代码风格更重要：绝不提交任何凭证，并且让服务器和应用保持一致。细则见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。涉及安全的内容不要发在公开的 issue 里，请发到[支持页面](docs/SUPPORT.md#contact)上的邮箱。

## 许可证

[MIT](LICENSE) © 2026 AkiyamaKunka

<sub>曾用名 Bitewise，更早叫 CalorieTracker。旧链接会跳转到这里。</sub><br>
<sub>iPhone 是 Apple Inc. 在美国和其他国家及地区注册的商标。App Store 是 Apple Inc. 的服务标记。Android 和 Google Play 是 Google LLC 的商标。</sub>
