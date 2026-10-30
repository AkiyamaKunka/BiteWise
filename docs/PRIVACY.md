# BiteWise · 筷拍 — Privacy Policy

Effective date: 2026-10-29

[English](#english) · [中文](#中文)

## English

BiteWise is a calorie tracker that estimates meals from food photos and
short text descriptions using an AI service **you** choose. It is an
open-source project. The developer runs **no backend server, has no user
accounts, and receives none of your data.**

### What stays on your phone

- Your meal log, the small meal thumbnails, your weight, body
  measurements, workouts and fitness profile, and the record of which
  photos were already processed live in a database inside the app on your
  phone.
- Settings live in the app's own preferences on your phone.
- API keys (and the key for your own server, if you use one) are kept in
  the iOS Keychain, or on Android in encrypted storage protected by the
  Android Keystore.
- Notifications (meal cards, daily summary) are generated on the phone.

The app contains no analytics, no crash reporting, no advertising and no
tracking SDK, and it does not use your data to track you across apps or
websites.

### What is sent, and to whom

Data leaves your phone only to reach the AI service you selected in
Settings, using **your own API key**:

- Google Gemini, OpenAI, Anthropic (Claude), DeepSeek, xAI (Grok),
  OpenRouter, Alibaba Cloud (Qwen 通义千问), Volcano Engine / ByteDance
  (Doubao 豆包) or Zhipu (GLM 智谱). Their own privacy policies and terms
  govern what they do with what you send.
- **Your own server** (Settings › AI Provider › Your own server) sends the
  same data to a server that **you** run and whose address you enter
  yourself; from there it reaches the AI plan you configured on that
  server. While your server's address is set, the
  app also asks it for the day's Garmin activity summary for the Today
  screen (only the date is sent).

**Which photos are sent:**

- Photos you pick or share into the app.
- Only if you turn on **Watch Camera Roll**: every new photo in your
  library, and — when you switch it on — the photos already taken within
  the look-back window (2 days by default, set under Settings), including
  photos that are not food. The AI decides whether a photo shows food, and
  non-food photos are not logged.

**What is sent with a photo:**

- The image, resized and re-encoded as a JPEG (in the rare case the app
  cannot decode a small JPEG, that file is sent without re-encoding).
  Embedded photo metadata (for example the time the photo was taken, the
  camera model and, if your camera recorded it, its location) is removed
  from the copy that is sent, and extra images stored inside the file
  (such as previews) are not sent.
- Your dietary profile text, if you wrote one.
- For the leftover check: the descriptions, food names, times and calorie
  estimates of meals you already logged (that day's meals, or the meal you
  picked as the original).

**What is sent with a text request:**

- *Describe a meal* (for example "I had a bowl of noodles"): your text and
  today's date. No other meals are sent.
- *Fix or delete a meal* (for example "meal 2 was roast duck" or "delete
  lunch"): your text, today's date, and the descriptions, items, dates,
  times and calorie estimates of your meals from the last 7 days so the AI
  can find the meal you mean.

The connection check in Settings contacts only the selected service (or
your server) and sends a fixed test message and a built-in test image, plus
your dietary profile with the test image if you wrote one. None of your
photos or meals are sent.

### Export, import and backups

- Export and import happen only when you tap them. An export is a file of
  your records (meals, weight, body measurements, workouts, fitness
  profile and the processed-photo list; API keys are not included) that you send wherever you
  choose with the system share sheet.
- Your phone's own backup can include the app's data: iCloud or computer
  backups on iPhone, and Android's system backup, which may keep a copy
  in your own Google account.

### Deleting your data

Delete meals inside the app, or uninstall the app to delete everything it
stored on the phone. Copies you exported or that sit in your own backups,
and anything already sent to the AI service you chose, are governed by
where they now live (your files, your backup, or that provider's policy).

### Third parties and your consent

BiteWise does not sell your data. It shares it only with the AI
recipient you set up under Settings › AI Provider, and its developer
receives none of it. That recipient is:

- **With an API key:** that AI provider — Google (Gemini), OpenAI,
  Anthropic (Claude), xAI (Grok), OpenRouter (which passes the request on
  to the company behind the model you picked), DeepSeek, Alibaba Cloud
  (Qwen), Volcano Engine / ByteDance (Doubao) or Zhipu (GLM).
- **With Your own server:** your server, which you run yourself, and the
  AI plan you configured on it (Anthropic, Zhipu or Volcano Engine), to
  which your server passes the data.

What that recipient receives:

- **Each photo** comes with your dietary profile (if you wrote one) and a
  short summary of the other meals logged that day — up to five, each with
  its time, description, food names and calorie estimates — so the AI can
  tell leftovers from a new meal.
- **A leftover photo** comes with the meal it belongs to.
- **Describe a meal** sends what you typed and today's date — no other
  meals.
- **Fix or delete a meal** sends what you typed, today's date and your
  meals from the last 7 days.

**Asking first.** Before anything goes to a recipient for the first time,
the app asks in a dialog that names the company and lists what is sent;
nothing is sent to it until you tap **Allow**. Another provider, or
another AI on your server, is a new recipient and is asked about again.
Confirming a setup link for your own server counts as allowing it, and
the link's dialog says so.

**Withdrawing consent.** Settings › **Stop Sharing with …** (followed by
the recipient's name) stops all sending to that recipient and turns off
Watch Camera Roll; the app asks again before it sends anything there.
Meals already logged stay on your phone. The app cannot call back what was
already sent: that is held under the provider's own rules (or on your own
server).

**Their terms apply.** Each provider handles what it receives under its
own privacy policy, terms and data-retention rules — for example how long
it keeps requests and whether it may use them to improve its models.
These differ from provider to provider, and sometimes between a
provider's free and paid plans; BiteWise cannot change them. Read the
policy of the provider you choose. DeepSeek, Alibaba Cloud, Volcano Engine
and Zhipu process data in mainland China, as the consent dialog says.

### Changes and contact

Changes to this policy are published in this file, with a new effective
date. Questions: open an issue at
<https://github.com/AkiyamaKunka/BiteWise/issues>.

---

## 中文

筷拍是一款卡路里记录应用：它借助**你自己选择**的 AI 服务，根据食物照片和简短的文字描述估算每一餐。本项目开源。开发者**不运营任何后端服务器、没有用户账户，也不会收到你的任何数据。**

### 留在你手机上的数据

- 你的饮食记录、每餐的小缩略图、体重、身体围度、运动记录和健身档案，以及"哪些照片已经处理过"的记录，都保存在手机上应用内部的数据库里。
- 设置保存在手机上应用自己的偏好设置中。
- API Key（以及你自己服务器的密钥，如果你使用的话）保存在 iOS 钥匙串中；在 Android 上保存在由 Android Keystore 保护的加密存储中。
- 通知（餐食卡片、每日总结）在手机上生成。

应用不包含任何统计分析、崩溃上报、广告或追踪 SDK，也不会利用你的数据在其他应用或网站之间追踪你。

### 发送了什么、发给谁

只有在需要连接你在设置中选择的 AI 服务时，数据才会离开手机，并使用**你自己的 API Key**：

- Google Gemini、OpenAI、Anthropic（Claude）、DeepSeek 深度求索、xAI（Grok）、OpenRouter、阿里云（Qwen 通义千问）、火山引擎 / 字节跳动（Doubao 豆包）或智谱（GLM）。它们如何处理你发送的内容，以它们各自的隐私政策和条款为准。
- **你自己的服务器**（设置 › AI 服务 › 你自己的服务器）会把同样的数据发送到**你自己运行**、由你亲自填写地址的服务器，再由它转给你在该服务器上配置的 AI 套餐。填写了服务器地址后，应用还会向这台服务器请求当天的 Garmin 活动摘要，用于"今天"页面（只发送日期）。

**哪些照片会被发送：**

- 你手动选择或分享到应用里的照片。
- 仅当你打开**「监控相册」**时：相册里的每一张新照片，以及开启那一刻回溯窗口内（默认最近 2 天，可在设置里调整）已经拍下的照片，包括不是食物的照片——由 AI 判断照片是否为食物，非食物照片不会被记录。

**随照片一起发送的内容：**

- 照片本身（缩小尺寸并重新编码为 JPEG；极少数情况下应用无法解码一张较小的 JPEG，则不经重新编码直接发送该文件）。照片中嵌入的元数据（例如拍摄时间、相机型号，以及相机记录了的话，拍摄地点）会从发送的这份副本中删除，文件里附带的其他图像（例如预览图）也不会被发送。
- 你的饮食档案文字（如果你填写了）。
- 用于剩菜判断：已记录餐食的描述、食物名称、时间和热量估算（当天的餐食，或你选作原餐的那一餐）。

**随文字请求一起发送的内容：**

- *文字描述一餐*（例如"我吃了一碗面"）：你输入的文字和今天的日期，不发送其他餐食。
- *修改或删除某餐*（例如"第二餐是烤鸭"或"删掉午饭"）：你输入的文字、今天的日期，以及最近 7 天餐食的描述、食物、日期、时间和热量估算，便于 AI 找到你指的那一餐。

设置中的连接检测只会访问所选服务（或你的服务器），发送一条固定的测试消息和一张内置的测试图片；如果你填写了饮食档案，它会随测试图片一起发送。不会发送你的任何照片或餐食。

### 导出、导入与备份

- 只有在你点击时才会导出或导入。导出的是一份记录文件（餐食、体重、身体围度、运动、健身档案和已处理照片列表；不包含 API Key），由你通过系统分享面板发送到你选择的地方。
- 手机自身的备份可能包含应用数据：iPhone 上的 iCloud 或电脑备份，以及 Android 的系统备份（可能会在你自己的 Google 账户中保存一份副本）。

### 删除数据

在应用内删除餐食，或卸载应用以删除它在手机上保存的全部数据。你导出的文件、你自己备份中的副本，以及已经发送给你所选 AI 服务的内容，分别由它们现在所在的位置（你的文件、你的备份或该服务商的政策）决定。

### 第三方与你的同意

筷拍不会出售你的数据，只会把它发送给你在 设置 › AI 服务 里设置的那个 AI 接收方，开发者也收不到其中任何内容。这个接收方是：

- **使用 API Key 时：**该 AI 服务商——Google（Gemini）、OpenAI、Anthropic（Claude）、xAI（Grok）、OpenRouter（它会把请求转交给你所选模型背后的公司）、DeepSeek 深度求索、阿里云（Qwen 通义千问）、火山引擎 / 字节跳动（Doubao 豆包）或智谱（GLM）。
- **使用「你自己的服务器」时：**你自己运行的服务器，以及你在它上面配置的 AI 套餐（Anthropic、智谱或火山引擎），由服务器把数据转交给它。

接收方会收到的内容：

- **每张照片**都会附带你的饮食档案（如果你填写了）和当天其他已记录餐食的简短摘要——最多五餐，每餐包括时间、描述、食物名称和热量估算——便于 AI 区分剩菜和新的一餐。
- **剩菜照片**会附带它对应的那一餐。
- **文字描述一餐**只发送你输入的文字和今天的日期，不发送其他餐食。
- **修改或删除某餐**会发送你输入的文字、今天的日期和最近 7 天的餐食。

**先征得同意。**第一次向某个接收方发送任何内容之前，应用会弹出对话框，写明公司名称和要发送的内容；在你点**「允许」**之前，不会向它发送任何内容。换用其他服务商，或换用你服务器上的其他 AI，都算新的接收方，会再次询问。确认你自己服务器的设置链接即表示同意，链接的对话框里也会写明。

**撤回同意。**设置 › **停止发送给 …**（后面是接收方的名称）会停止向该接收方发送任何内容，并关闭「监控相册」；之后再向它发送任何内容前，应用都会重新询问。已经记录的餐食仍保留在你的手机上。已经发送出去的内容，应用无法收回：它们按该服务商自己的规定保存（或保存在你自己的服务器上）。

**以它们自己的条款为准。**每家服务商都按它自己的隐私政策、条款和数据保留规则处理收到的内容——例如请求保存多久、是否可能用于改进它的模型。这些规则因服务商而异，有时同一服务商的免费和付费方案也不同，筷拍无法改变它们。请阅读你所选服务商的政策。DeepSeek、阿里云、火山引擎和智谱在中国大陆处理数据，同意对话框里也会说明。

### 变更与联系

本政策的变更会发布在此文件中，并更新生效日期。如有问题，请在 <https://github.com/AkiyamaKunka/BiteWise/issues> 提交 issue。
