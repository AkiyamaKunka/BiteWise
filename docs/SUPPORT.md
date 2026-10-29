# BiteWise · 筷拍 — Support

BiteWise is an iPhone app (iOS 15 or later) that turns your food photos
into calorie and macro estimates using the AI service you choose, with
your own API key. There is no account, and no server of ours in between:
your meal log stays on your phone. Privacy details are in the
[privacy policy](PRIVACY.md).

## What it does

- **Log a meal** from a photo (Today › **+ Log** › *From recent photos*,
  or share a photo into BiteWise from Photos or Safari), by describing it
  (*Describe a meal*), or by typing the numbers yourself.
- **Watch Camera Roll** (Settings, optional): new food photos are logged
  for you. Every new photo, including ones that are not food, is sent to
  your AI provider so it can tell whether it is a meal.
- **Fix anything**: open a meal to edit its items and numbers, or use
  *Fix or delete a meal* and type something like "meal 2 was roast duck".
- **Leftovers**: photograph what is left and the meal shrinks to what you
  ate.
- Today, a 30-day history, weight and body measurements, and an optional
  daily summary notification.

Calories and nutrients are AI estimates and can be wrong. BiteWise is not
a medical device and does not give medical or nutrition advice.

## Getting started: bring your own key

1. Open **Settings › AI Provider › API Key** and pick a provider.
2. Paste its API key (it saves as you type; it is kept in the iOS
   Keychain on this phone).
3. Tap **Test This Provider**. The first time anything is sent to a
   provider, BiteWise asks for your permission; tap **Allow**.

Where each provider's key comes from:

- **Google Gemini**: create a key at aistudio.google.com/apikey (Google AI
  Studio); Gemini has a free tier.
- **OpenAI**: create a key at platform.openai.com/api-keys; usage is billed
  to your OpenAI account.
- **Anthropic (Claude)**: create a key in the Anthropic Console at
  console.anthropic.com under API keys; usage is billed to your account.
- **xAI (Grok)**: create a key at console.x.ai under API keys; usage is
  billed to your account.
- **OpenRouter**: create a key at openrouter.ai/keys; one key reaches
  models from many companies, and a few models are free.
- **DeepSeek**: create a key at platform.deepseek.com under API keys; pay
  as you go.
- **Alibaba Cloud Qwen**: create a key at bailian.console.aliyun.com
  (Model Studio › API-KEY); new accounts get free tokens.
- **ByteDance Doubao**: create a key at console.volcengine.com/ark, then
  activate the models you want to use there.
- **Zhipu GLM**: create a key at open.bigmodel.cn (the account needs
  real-name verification); the default flash model is free.

**Your own server** (Settings › AI Provider › Your own server) is for
people who run the open-source server from the BiteWise repository with an
AI plan signed in on it: enter the server's address and upload key there.

## Troubleshooting

- **Something does not work.** Settings › AI Provider › **Test This
  Provider** checks the setup step by step and names what is broken: the
  configuration, the network, the key, the account's credit, the reply
  format or the quota.
- **Nothing was sent.** If you tapped *Not now* in the permission dialog,
  nothing goes to that provider; the next photo or request asks again.
- **"Not available from your current network region".** The provider does
  not serve the region your connection comes from. Choose another
  provider.
- **"Out of balance or credits" or a quota message.** Top up the account
  in the provider's console, or wait for a free tier's daily limit to
  reset. Photos are kept and can be analyzed again.
- **Watch Camera Roll misses photos.** It needs full photo access (iOS
  Settings › Privacy & Security › Photos › BiteWise › *Full Access*) and
  Background App Refresh (iOS Settings › General › Background App
  Refresh). iOS decides when background scans run; opening BiteWise
  catches up. Settings › **Photo Coverage** shows which recent photos were
  logged and can retry the rest.
- **A number looks wrong.** Open the meal and edit it, or use *Fix or
  delete a meal*.

## Your data: export, delete, stop sharing

- **Export**: Settings › Your Data › **Export Data…** saves your meals,
  weight, body measurements, workouts, fitness profile and the list of
  processed photos to a file you can share or keep (API keys are not
  included).
  **Import Data…** restores it, from a file or from the clipboard.
- **Delete a meal**: open it and tap the delete button.
- **Delete everything**: uninstall BiteWise; that removes everything it
  stored on the phone. Your iCloud or computer backups and exported files
  may still hold a copy.
- **Stop sharing with a provider**: Settings › **Stop Sharing with …**
  stops all sending to it and turns off Watch Camera Roll. What was
  already sent is handled under that provider's own privacy policy.

## Contact

- **Questions and bug reports**: open an issue at
  <https://github.com/AkiyamaKunka/BiteWise/issues>. Issues are public, so
  never post an API key, your photos or personal data there.
- Email: <SUPPORT EMAIL — owner to choose>
