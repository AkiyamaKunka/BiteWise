# Bitewise · 筷拍 — Privacy Policy

Effective date: 2026-10-24

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
- A short record of the last 20 Meta glasses photos (how each was
  recognized, the camera model, whether it carries a location — never the
  location itself — its on-phone food score and what happened to it),
  shown on the diagnostics page. It is kept outside your phone's backups.
- Only if you turn on **Restaurant nutrition** lookup: the restaurants you
  confirmed or marked as wrong and the spots you marked as "not a
  restaurant" (each kept as an area of roughly 100 m, for up to 180 days;
  only on iPhone, where photo locations are used), lookups still waiting
  for an answer, recent lookup answers (up to 30 days, each marked if you
  turned it down, so it is only suggested again), which updated meals you
  have not opened yet, and a log of the last 20 lookup decisions (result
  codes and calorie numbers only). These are kept outside your phone's
  backups and are never exported. **Clear learned places** in Settings
  deletes the places, the recent lookup answers and the lookups still
  waiting.

The app contains no analytics, no crash reporting, no advertising and no
tracking SDK, and it does not use your data to track you across apps or
websites.

### What is sent, and to whom

Data leaves your phone to reach the AI service you selected in Settings,
using **your own API key** (with Claude Plan, the server you run). Nothing
else leaves the phone unless you turn on **Restaurant nutrition** lookup:
then, on iPhone, a photo's location goes to Apple Maps, and lookups go to
that AI service's web search, as described under *Restaurant nutrition
lookup* below.

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
  library, and — when you switch it on — the photos already taken within
  the look-back window (2 days by default, set under Settings), including
  photos that are not food. The AI decides whether a photo shows food, and
  non-food photos are not logged.
- Photos taken with **Meta glasses** that the Meta AI app imports into
  your library are treated like camera photos, under the same Watch Camera
  Roll rules. The app recognizes them on the phone, from the file name,
  the album the Meta AI app puts them in, or the camera model recorded in
  the photo. On iPhone, each one is first checked on the phone by Apple's
  built-in image classifier when it can run, and a photo it finds no food
  in is not sent. When the check cannot run (the classifier is
  unavailable, fails or takes too long), the photo is handled like any
  camera photo and sent to the AI. **Meta glasses photos** (Settings › Photos)
  turns automatic logging of these photos off; photos you pick or share
  are still sent.

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

**What is sent with a text request** (for example "I had a bowl of
noodles" or "delete lunch"): your text, today's date, and the
descriptions, items, dates, times and calorie estimates of your meals from
the last 7 days so the AI can find the meal you mean.

The connection check in Settings contacts only the selected service (or
your server) and sends a fixed test message and a built-in test image, plus
your dietary profile with the test image if you wrote one. None of your
photos or meals are sent.

### Restaurant nutrition lookup (off unless you turn it on)

When a meal photo looks like it came from a chain restaurant, the app can
check whether the chain publishes nutrition for that food. It is off by
default. Turning it on shows a notice that names who receives lookups, and
the app asks again, and sends nothing, when you switch to another AI
service or server.

- **Which meals:** photo meals the AI marks as eaten at a restaurant or as
  takeout ("When unsure": only when the AI also says its estimate is
  unsure), meals whose cup, bag, box or receipt shows a chain's brand, and
  any meal you look up yourself. A meal marked as home-cooked, packaged or
  unknown never has its location read.
- **Photo location (iPhone only, with "Use photo location" on):** for a
  meal the AI marks as eaten at a restaurant, the app reads where the photo
  was taken from your photo library and asks Apple Maps, on the phone,
  which food places are nearby. Apple receives that location, as when you
  use Maps, under Apple's own privacy policy. Nothing Apple Maps returns is
  stored, shown or sent anywhere: the app only compares the places with its
  own built-in list of US restaurant chains and then discards them. The
  location exists only in the phone's memory for that one query. When you
  answer a lookup result in the meal editor (**Correct**, **Use published
  numbers**, **Wrong restaurant** or **Not from a restaurant**), the app
  reads that photo's location once more, only to remember your answer on
  the phone as an area of roughly 100 m (see above); a printed brand's
  numbers teach it nothing about the place. On Android the app never reads
  a photo's location; lookups there use printed brands only. **Brand only**
  does the same on iPhone, for lookups and for your answers alike.
- **What a lookup sends:** up to three chain names from that built-in list
  (a chain found near where the photo was taken, or a brand printed on a
  cup, bag or receipt in the photo), the food names with their amounts and
  units, your phone's region setting (for example US) and the reply
  language. A chain found nearby shows you were near that chain.
- **What a lookup never sends:** the photo, its location, the city, the
  street, the distance to any place, anything Apple Maps returned, the
  meal's time or description, your dietary profile or your meal history.
- **Who receives it, and does the web search:**
  - **Claude Plan:** your own server, which searches with Claude web search
    (Anthropic) under your plan. Chain names found from a photo's location
    are sent to your server only when its address starts with `https://`;
    over `http://` lookups use printed brands only. Your server keeps a
    lookup's request and answer in memory for up to 24 hours. With Claude
    Plan the app only *suggests* the chain's published numbers: a meal
    changes only when you accept.
  - **Anthropic** (your API key): Anthropic, which runs the web search.
  - **OpenRouter** (your API key): OpenRouter and its search partner Exa.
  - Any other AI service: no lookups are made at all.

  Their own privacy policies and terms govern what they do with what you
  send.
- **What is saved with the meal:** the chain, the matched menu items, the
  published numbers, the address of the chain's page they came from, which
  service answered, the date, each item's numbers before and after, the
  lookup's notes (at most 200 characters, shown as plain text), why a
  suggestion was not used by itself (a code), and how the meal was tied to
  the chain (a brand printed on an item or receipt, the photo's location,
  or your own pick). This holds no location and is part of the meal in
  exports.
- Turning it off cancels lookups in progress, drops pending ones, and can
  clear learned places at the same time.

### Export, import and backups

- Export and import happen only when you tap them. An export is a file of
  your records (meals, weight, body measurements, workouts, fitness
  profile and the processed-photo list; API keys are not included) that you send wherever you
  choose with the system share sheet.
- Your phone's own backup can include the app's data: iCloud or computer
  backups on iPhone, and Android's system backup, which may keep a copy
  in your own Google account. The records described above as kept outside
  backups (the Meta glasses record and the restaurant lookup files) are
  not included.

### Deleting your data

Delete meals inside the app, use **Clear learned places** (Settings ›
Restaurant nutrition) to delete the places the restaurant lookup learned
and its recent answers, or uninstall the app to delete everything it stored on the phone. Copies you exported or that sit in your own backups,
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
- 最近 20 张 Meta 眼镜照片的简短记录（每张是怎样识别出来的、相机型号、是否带有位置——绝不记录位置本身——在手机上算出的食物分，以及处理结果），显示在诊断页面上。这份记录不会进入手机的备份。
- 仅当你开启**「餐厅营养」查询**时：你确认过或标记为不对的餐厅，以及你标记为"不是餐厅"的地点（每个都按约 100 米的范围保存，最长 180 天；只在会使用照片位置的 iPhone 上才有）、还在等待结果的查询、最近的查询结果（最长 30 天；你拒绝过的会被标记，之后只作为建议）、哪些被更新的餐你还没有打开过，以及最近 20 次查询决定的记录（只有结果代码和热量数字）。这些不会进入手机的备份，也不会被导出。设置中的**「清除已记住的地点」**会删除这些地点、最近的查询结果和还在等待的查询。

应用不包含任何统计分析、崩溃上报、广告或追踪 SDK，也不会利用你的数据在其他应用或网站之间追踪你。

### 发送了什么、发给谁

数据离开手机是为了连接你在设置中选择的 AI 服务，并使用**你自己的 API Key**（使用 Claude Plan 时，是你自己运行的服务器）。除非你开启**「餐厅营养」查询**，否则不会有其他数据离开手机；开启后，在 iPhone 上照片的拍摄位置会发送给 Apple 地图，查询会发送给该 AI 服务的网页搜索，详见下文**「餐厅营养查询」**。

- Google Gemini、OpenAI、Anthropic（Claude）、DeepSeek 深度求索、xAI（Grok）、OpenRouter、阿里云（Qwen 通义千问）、火山引擎 / 字节跳动（Doubao 豆包）或智谱（GLM）。它们如何处理你发送的内容，以它们各自的隐私政策和条款为准。
- **Claude Plan** 会把同样的数据发送到**你自己运行**、由你亲自填写地址的服务器，再由它转给你在该服务器上配置的 AI 套餐。填写了服务器地址后，应用还会向这台服务器请求当天的 Garmin 活动摘要，用于"今天"页面（只发送日期）。

**哪些照片会被发送：**

- 你手动选择或分享到应用里的照片。
- 仅当你打开**「监控相册」**时：相册里的每一张新照片，以及开启那一刻回溯窗口内（默认最近 2 天，可在设置里调整）已经拍下的照片，包括不是食物的照片——由 AI 判断照片是否为食物，非食物照片不会被记录。
- Meta AI App 导入相册的 **Meta 眼镜**照片，与相机照片同等对待，遵循同样的「监控相册」规则。应用在手机上根据文件名、Meta AI App 存放它们的相簿，或照片里记录的相机型号识别这些照片。在 iPhone 上，只要苹果系统自带的图像分类器能够运行，每一张都会先由它在手机上检查一遍，它认为不含食物的照片不会被发送；如果检查无法进行（分类器不可用、出错或耗时过长），这张照片就和普通相机照片一样处理，会发送给 AI。**「包括 Meta 眼镜拍的照片」**（设置 › 照片）可以关闭对这类照片的自动记录；你手动选择或分享的照片仍会发送。

**随照片一起发送的内容：**

- 照片本身（缩小尺寸并重新编码为 JPEG；极少数情况下应用无法解码一张较小的 JPEG，则不经重新编码直接发送该文件）。照片中嵌入的元数据（例如拍摄时间、相机型号，以及相机记录了的话，拍摄地点）会从发送的这份副本中删除，文件里附带的其他图像（例如预览图）也不会被发送。
- 你的饮食档案文字（如果你填写了）。
- 用于剩菜判断：已记录餐食的描述、食物名称、时间和热量估算（当天的餐食，或你选作原餐的那一餐）。

**随文字请求一起发送的内容**（例如"我吃了一碗面"或"删掉午饭"）：你输入的文字、今天的日期，以及最近 7 天餐食的描述、食物、日期、时间和热量估算，便于 AI 找到你指的那一餐。

设置中的连接检测只会访问所选服务（或你的服务器），发送一条固定的测试消息和一张内置的测试图片；如果你填写了饮食档案，它会随测试图片一起发送。不会发送你的任何照片或餐食。

### 餐厅营养查询（只有你开启后才会使用）

当一张餐食照片看起来来自连锁餐厅时，应用可以查一下这家连锁店是否公布了该食物的营养信息。此功能默认关闭。开启时会显示一份说明，写明查询会发送给谁；当你换用其他 AI 服务或服务器时，应用会再次询问，在你同意之前不会发送任何查询。

- **哪些餐会被查询：** AI 标记为在餐厅吃的或外卖的照片餐食（「不确定时」模式下，还要 AI 表示自己的估算没有把握），杯子、袋子、盒子或小票上印有连锁品牌的餐，以及你自己手动查询的任意一餐。被标记为家里做的、包装食品或无法判断的餐，绝不会读取其位置。
- **照片位置（仅限 iPhone，且开启了「使用照片位置」）：** 对 AI 标记为在餐厅吃的餐，应用会从照片库读取这张照片的拍摄位置，并在手机上向 Apple 地图查询附近的餐饮场所。Apple 会收到该位置（与使用地图时相同），并按 Apple 自己的隐私政策处理。Apple 地图返回的任何内容都不会被保存、显示或发送到任何地方：应用只是把这些场所与它内置的美国连锁餐厅列表比对，然后丢弃。该位置只在这一次查询期间存在于手机内存中。当你在编辑页回应查询结果（**「没错」**、**「采用公布数值」**、**「不是这家」**或**「不是餐厅的」**）时，应用会再读取一次这张照片的拍摄位置，仅用于在手机上按约 100 米的范围记住你的回答（见上文）；按印出的品牌得到的数值不会让它记住任何地点。在 Android 上，应用绝不读取照片的拍摄位置，只按印出的品牌查询；在 iPhone 上选择**「仅按品牌」**也是如此，查询和你的回答都一样。
- **查询会发送的内容：** 最多三个来自这份内置列表的连锁店名称（在照片拍摄地点附近找到的连锁店，或照片里杯子、袋子、小票上印的品牌），食物名称及其份量和单位，你手机的地区设置（例如 US）以及回复所用的语言。在附近找到的连锁店会显示你当时在它附近。
- **查询绝不会发送的内容：** 照片本身、拍摄位置、城市、街道、与任何场所的距离、Apple 地图返回的任何内容、这一餐的时间或描述、你的饮食档案或饮食记录。
- **由谁接收、由谁进行网页搜索：**
  - **Claude Plan：** 你自己的服务器，它在你的套餐下使用 Anthropic 的 Claude 网页搜索。根据照片位置找到的连锁店名称，只有在服务器地址以 `https://` 开头时才会发送给你的服务器；地址是 `http://` 时，只按印出的品牌查询。你的服务器会在内存中保留一次查询的请求和结果，最长 24 小时。使用 Claude Plan 时，应用只会*建议*连锁店公布的数值：只有你采用后，这一餐才会改变。
  - **Anthropic**（你的 API Key）：Anthropic，由它进行网页搜索。
  - **OpenRouter**（你的 API Key）：OpenRouter 及其搜索合作方 Exa。
  - 其他任何 AI 服务：完全不会进行查询。

  它们如何处理你发送的内容，以它们各自的隐私政策和条款为准。
- **随餐保存的内容：** 连锁店、匹配到的菜品、公布的数值、数值来源的连锁店网页地址、由哪个服务给出的结果、日期、每项食物在采用前后的数值、查询的备注（最多 200 个字符，以纯文本显示）、建议没有被自动采用的原因（一个代码），以及这一餐是如何与该连锁店对应上的（食物或小票上印的品牌、照片的拍摄位置，或你自己选的）。其中不含任何位置，导出时作为这一餐的一部分。
- 关闭此功能会取消进行中的查询、丢弃待处理的查询，并可同时清除已记住的地点。

### 导出、导入与备份

- 只有在你点击时才会导出或导入。导出的是一份记录文件（餐食、体重、身体围度、运动、健身档案和已处理照片列表；不包含 API Key），由你通过系统分享面板发送到你选择的地方。
- 手机自身的备份可能包含应用数据：iPhone 上的 iCloud 或电脑备份，以及 Android 的系统备份（可能会在你自己的 Google 账户中保存一份副本）。上文说明不会进入备份的记录（Meta 眼镜记录和餐厅查询的文件）不在其中。

### 删除数据

在应用内删除餐食，用**「清除已记住的地点」**（设置 › 餐厅营养）删除餐厅查询记住的地点和最近的查询结果，或卸载应用以删除它在手机上保存的全部数据。你导出的文件、你自己备份中的副本，以及已经发送给你所选 AI 服务的内容，分别由它们现在所在的位置（你的文件、你的备份或该服务商的政策）决定。

### 变更与联系

本政策的变更会发布在此文件中，并更新生效日期。如有问题，请在 <https://github.com/AkiyamaKunka/BiteWise/issues> 提交 issue。
