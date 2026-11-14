# Google Play App content: the answers for Chopstats

Paste-ready answers for **Play Console › Monitor and improve › Policy and
programs › App content**, written
2026-11-13 for the first Google Play release (1.7.0), with the owner's
decisions of that day: no broad photo access on Play (decision 1),
`http://` servers refused (decision 2), one signing key for Play and the
GitHub APK (decision 3), and an Android-only 1.7.0 (decision 4). Match the
meaning of each question, not its position; the console moves things
around. Data safety has its own file: [data_safety.md](data_safety.md).
`docs/RELEASING.md` § 6 has the order of the whole Play setup.

Google requires the Health apps and Financial features declarations for
apps on closed testing, open testing and production tracks, so finish
this page **before the first closed-test release** (that release is
reviewed too). An internal-testing upload can come first.

## Privacy policy

<https://github.com/AkiyamaKunka/Chopstats/blob/main/docs/PRIVACY.md>

It is public, needs no login, and is also linked inside the app
(Settings › Your Data › Privacy Policy), which the Health Content and
Services policy asks for.

## Ads

**No, my app does not contain ads.**

## Sign-in details (formerly "App access")

Choose **All or some functionality in my app is restricted**, then add
one instruction set. Google wants the details to work at all times, be
reusable, work wherever the reviewer is, and be in English. Keep the demo
key valid through **every** review: the closed test, the production
application and each later update.

- **Name:** Gemini demo key
- **Username / password:** leave empty (there is no account).
- **Any other information:** paste the text below, then replace the last
  line's placeholder with **the demo key from the owner's release notes**
  (the budget-capped Gemini key kept for App Review). Never commit the key
  to this repository.

```text
Chopstats is a bring-your-own-key calorie tracker. It has no accounts and
no backend of ours. The user pastes an API key for an AI provider they
already pay for (Google Gemini, OpenAI, Anthropic, xAI, OpenRouter,
DeepSeek, Alibaba Qwen, ByteDance Doubao, Zhipu GLM); that provider
receives each photo being analyzed (with the user's dietary profile and a
short summary of the day's meals) and returns a nutrition estimate. Before
anything is sent to a provider for the first time, the app asks for
permission in a dialog that names the company and what is sent; Settings ›
"Stop Sharing with …" withdraws it.

To test: a fresh install opens on Settings. Tap AI Provider › API Key;
Google Gemini is already selected; paste the key below into "Gemini API
key". Go back to Today, tap "Log" › "From recent photos" and tap Allow in
the consent dialog. Android's photo picker opens: pick a food photo, and
the estimate appears after a few seconds. Without food photos on the test
device, use "Log" › "Describe a meal" (for example "a bowl of beef noodle
soup"), or share a food image from Google Photos or Chrome into Chopstats
with the share button. There is no in-app camera: photos come from the
camera app.

AI Provider › Your own server is for people who run their own server (the
open-source server in the same repository) over https; it cannot be
tested without such a server. Nothing is sold in the app: there are no
in-app purchases. Settings › Restaurant nutrition › "Lookups" needs the
user's own server or an Anthropic or OpenRouter key, so it is grayed out
with the demo key.

Demo key (Gemini, budget-capped): <the demo key from the owner's release notes>
```

<!-- gated: release_decisions_test (system_photo_picker.dart and its use in add_flow.dart); the row stays "From recent photos" (addFromPhotos) -->

Before each review, run the steps above once on a phone with the build
you submit, and check every quoted label against it. The demo key must
stay on a billing-enabled Google Cloud project with a low daily request
quota and a budget alert: Gemini's free tier can run out mid-review, is
not offered in every region, and Google may use free-tier inputs.

**Owner note, not a change to the plan: the Gemini API terms.** Google's
Gemini API Additional Terms of Service
(<https://aistudio.google.com/docs/terms>, read by the plan's verifier on
2026-11-13, effective 2026-03-23) say, as the verifier summarized them:
the API is for developers building for professional or business purposes,
not for consumer use; do not send sensitive or personal information to the
Unpaid Services (the free tier), whose inputs Google may use and have
reviewed by people; and only Paid Services may be offered to users in the
EEA, Switzerland or the UK. That bears on a consumer app whose default
provider is Gemini and whose users bring their own (often free-tier) keys,
and on the demo key, which should stay a paid key. Re-read the terms
yourself before relying on this summary; nothing in the app or the plan
changes because of it today.

## Content rating

Start the IARC questionnaire with the developer email shown on Chopstats'
Play page, and choose the category **Utility, Productivity,
Communication, or Other** (not a game; Google lists fitness apps under
utility). Answer from these facts:

- No violence, blood, sexual content, nudity, profanity or crude humor.
- No references to drugs, alcohol or tobacco made by the app (users can
  log any food or drink they like; the app shows only what they log).
- No gambling and no simulated gambling.
- No user interaction: users cannot chat with, message or see other
  users, and nothing users enter is shared with other users.
- Does not share the user's location with other users.
- No digital purchases, no in-app purchases, no ads.
- No unrestricted internet access or web browser.

Keep the rating certificate email.

## Target audience and content

- **Target age groups:** **18 and over** only. Google's Gemini API terms
  require users to be 18 or older, and Gemini is the default provider.
  This also keeps the app out of the Families policy.
- **Restrict Minor Access:** tick it (it is offered only when 18+ is the
  only target age).
- **Could the store listing unintentionally appeal to children?** No.

## News apps

**No**, my app is not a news app.

## Government apps

**No**, my app is not developed by or on behalf of a government.

## Financial features

**My app doesn't provide any financial features.** (Required for every
app, closed testing included, even with no financial features.)

## Health apps

Tick:

- Health and fitness › **Nutrition and Weight Management** (the meal
  log, calories and macros, the calorie goal).
- Health and fitness › **Activity and Fitness** (workouts typed into Fix,
  weight and body measurements in the Body tab).

Tick nothing under Medical; Chopstats is not a medical device app. It
reads and writes no Health Connect data (no `android.permission.health.*`
permission), so the per-data-type screen stays empty.

The Health Content and Services policy also wants, for a health app that
is not a medical device, Google's disclaimer in the store description and
a reminder to consult a healthcare professional. Both full descriptions
in `metadata/` end with them. From 1.7.0 the app reminds users too: Settings
› Your Data ends with "Chopstats is not medical advice. For decisions about
your health or diet, consult a healthcare professional." (`settingsHealthReminder`,
in English and Chinese).
<!-- gated: release_decisions_test (settingsHealthReminder in app_en.arb and app_zh.arb) -->

## Data safety

See [data_safety.md](data_safety.md).

## Advertising ID

**No**, my app does not use an advertising ID. (The merged manifest has
no `com.google.android.gms.permission.AD_ID`, and no SDK reads the ID.)

## Photo and video permissions

**Nothing to declare for the first submission.** The Play build declares
no `READ_MEDIA_IMAGES`, `READ_MEDIA_VISUAL_USER_SELECTED` or
`READ_EXTERNAL_STORAGE` (decision 1); photos come through Android's photo
picker and the share sheet, which need no permission. If the console still
shows this declaration, the uploaded bundle is the wrong one: check its
permissions (`docs/RELEASING.md` § 6.3) before going on.

## AI-generated content (no form; the assessment to keep on file)

Google's AI-Generated Content policy asks apps that **generate** content
with AI to let users report offensive output without leaving the app. Its
help page lists chatbots, text-to-image and voice-to-image generators and
synthetic media of real people as in scope, and excludes, among others,
productivity apps that use AI to improve an existing feature
(<https://support.google.com/googleplay/android-developer/answer/14094294>,
read 2026-11-13). Chopstats' AI returns structured nutrition estimates for
the user's own meals; there is no chat and no image or voice generation.
The owner's assessment (2026-11-13): out of scope. This is a judgment
call, not a Google ruling. If a review cites the policy, a compliant fix
needs an in-app report that sends from inside the app (an email or share
intent leaves the app and does not count), which would add a
developer-collected data flow to Data safety and the privacy policy.

---

## Only if decision 1 changes to A later (broad photo access on Play)

**Not for the first submission.** Decision 1 (2026-11-13) is B: no broad
photo access on Play. If Watch Camera Roll comes to Play in an update,
Google reviews the permission declaration with the release that carries
`READ_MEDIA_IMAGES`; a refusal means removing the permission from every
track and uploading again.

### Full-description paragraph (add under HOW IT WORKS)

en-US:

> • Or turn on Watch Camera Roll (optional, off until you turn it on):
> new food photos are logged for you. Every new photo, including ones
> that are not food, is sent to your AI service so it can tell whether it
> is a meal. Android decides when background scans run, and opening the
> app catches up.

zh-CN:

> • 也可以打开「监控相册」（可选，默认关闭）：新的食物照片会自动记录。每张新照片（包括不是食物的照片）都会发送给你的 AI 服务，由它判断是不是一餐。后台扫描由 Android 决定何时运行，打开应用时会补扫。

### Declaration text (App content › Photo and video permissions)

> Chopstats logs meals from food photos. With Watch Camera Roll, which
> the user turns on in Settings after a notice that names the AI service
> receiving the photos, the app checks the photo library for new photos in
> the background (WorkManager, about every 30 minutes) and sends each new
> photo to the AI service the user chose, so meals are logged without the
> user opening the app. The system photo picker cannot do this: it
> returns only photos the user picks, one action at a time, while the
> app is open. Users who do not grant photo access log meals with the
> system photo picker or the share sheet, which need no permission.
> Chopstats declares READ_MEDIA_IMAGES only, never video.

Be aware when filing it: the app's own texts call Watch Camera Roll an
optional extra that is off by default, which weakens a "core
functionality" argument (answer/16558241 and answer/14115180, read
2026-11-13).

### Recording script for the declaration video (about 60 s)

1. Fresh install of that build, with an API key set. Settings › Watch
   Camera Roll: show the notice and the consent dialog, then Android's
   photo permission prompt; choose **Allow all**.
2. Open the camera app and take a photo of food. Leave Chopstats in the
   background.
3. Wait for (or trigger in a debug build) the background scan: the meal
   card notification appears; open it to show the logged meal on Today.
4. Turn the permission off in Android Settings and show that **Log ›
   From recent photos** still works through the system photo picker.
