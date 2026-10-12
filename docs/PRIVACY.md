# Bitewise · 筷拍 — Privacy Policy

Effective date: 2026-10-12

[English](#english) · [中文](#中文)

## English

Bitewise is a calorie tracker that estimates meals from food photos and
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
- **Claude Plan** sends the same data to a server that **you** run and
  whose address you enter yourself; from there it reaches the AI plan you
  configured on that server. While your server's address is set, the
  app also asks it for the day's Garmin activity summary for the Today
  screen (only the date is sent).

**Which photos are sent:**

- Photos you pick or share into the app.
- Only if you turn on **Watch Camera Roll**: every new photo in your
  library, including photos that are not food — the AI decides whether a
  photo shows food, and non-food photos are not logged.

**What is sent with a photo:**

- The image, resized and re-encoded as a JPEG. Embedded photo metadata
  (for example the time the photo was taken and, if your camera recorded
  it, its location) may still be inside that file.
- Your dietary profile text, if you wrote one.
- For the leftover check: the descriptions, food names, times and calorie
  estimates of meals you already logged (that day's meals, or the meal you
  picked as the original).

**What is sent with a text request** (for example "I had a bowl of
noodles" or "delete lunch"): your text, today's date, and the
descriptions, items, dates, times and calorie estimates of your meals from
the last 7 days so the AI can find the meal you mean.

The connection check in Settings only contacts the selected service's (or
your server's) address and sends no personal data.

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
- **Claude Plan** 会把同样的数据发送到**你自己运行**、由你亲自填写地址的服务器，再由它转给你在该服务器上配置的 AI 套餐。填写了服务器地址后，应用还会向这台服务器请求当天的 Garmin 活动摘要，用于"今天"页面（只发送日期）。

**哪些照片会被发送：**

- 你手动选择或分享到应用里的照片。
- 仅当你打开**「监控相册」**时：相册里的每一张新照片，包括不是食物的照片——由 AI 判断照片是否为食物，非食物照片不会被记录。

**随照片一起发送的内容：**

- 照片本身（缩小尺寸并重新编码为 JPEG）。照片中嵌入的元数据（例如拍摄时间，以及相机记录了的话，拍摄地点）可能仍保留在这个文件里。
- 你的饮食档案文字（如果你填写了）。
- 用于剩菜判断：已记录餐食的描述、食物名称、时间和热量估算（当天的餐食，或你选作原餐的那一餐）。

**随文字请求一起发送的内容**（例如"我吃了一碗面"或"删掉午饭"）：你输入的文字、今天的日期，以及最近 7 天餐食的描述、食物、日期、时间和热量估算，便于 AI 找到你指的那一餐。

设置中的连接检测只会访问所选服务（或你的服务器）的地址，不发送任何个人数据。

### 导出、导入与备份

- 只有在你点击时才会导出或导入。导出的是一份记录文件（餐食、体重、身体围度、运动、健身档案和已处理照片列表；不包含 API Key），由你通过系统分享面板发送到你选择的地方。
- 手机自身的备份可能包含应用数据：iPhone 上的 iCloud 或电脑备份，以及 Android 的系统备份（可能会在你自己的 Google 账户中保存一份副本）。

### 删除数据

在应用内删除餐食，或卸载应用以删除它在手机上保存的全部数据。你导出的文件、你自己备份中的副本，以及已经发送给你所选 AI 服务的内容，分别由它们现在所在的位置（你的文件、你的备份或该服务商的政策）决定。

### 变更与联系

本政策的变更会发布在此文件中，并更新生效日期。如有问题，请在 <https://github.com/AkiyamaKunka/BiteWise/issues> 提交 issue。
