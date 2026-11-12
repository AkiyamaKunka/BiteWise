# Captioned App Store screenshots (source)

Eight captioned, slide-style screenshots per language for the App Store page of
Chopstats · 筷拍, built from real **1.6.0** screens (demo data). The rendered
PNGs live in `../screenshots-marketing/en-US/` and `../screenshots-marketing/zh-Hans/`.
The plain screenshots in `../screenshots/` are untouched.

Use this set only while the App Store build keeps the 1.6 look (1.6.0, 1.6.1).
A release with a new look (1.7.0, the native iOS design) needs new captures first:
App Review guideline 2.3 wants screenshots that match the current version.

Nobody uploads from here. The owner previews the set and uploads it in
App Store Connect (Media Manager) when the next version is prepared.

## The frames

| File | Caption (en-US) | Caption (zh-Hans) | Picture (real 1.6.0 UI) |
|---|---|---|---|
| `01_snap_get_numbers` | Snap a meal. / Get the numbers. — *Your AI estimates calories, protein, carbs and fat.* | 拍下这一餐 / 热量一目了然 — *你选的 AI 估算热量、蛋白质、碳水和脂肪* | Unsplash photo of the yogurt bowl → its meal card on Today (~360 kcal, P/C/F, portions) |
| `02_edit_any_number` | See the portion. / Edit any number. — *Each food shows the portion your AI assumed.* | 分量写明白 / 数字随你改 — *每样食物都写明 AI 假设的分量* | Meal editor; ring on the assumed portion, touch point on the calories field |
| `03_your_ai_your_key` | Your AI, / your key — *Nine AI providers, or your own server. No Chopstats account.* | 你的 AI / 你的 Key — *9 家 AI 服务任选，或用你自己的服务器；无需注册筷拍账户* | Settings › AI (ring on "its key is stored only on this phone…") and the AI Provider page |
| `04_usual_foods` | Your usual foods, / one tap away — *No photo, no AI, nothing sent.* | 常吃的 / 点一下就记 — *不用拍照，不用 AI，不发送任何内容* | My usual foods (new in 1.6), touch point on a row |
| `05_restaurant_numbers` | pill *Off by default*; Use the chain's / own numbers — *For US chain meals. Needs a supported AI provider.* | pill *默认关闭*; 连锁餐厅？/ 用它公布的数值 — *仅限美国连锁餐厅，需要支持此功能的 AI 服务* | The restaurant source card (new in 1.6) |
| `06_trend` (dark) | See the trend, / not just today — *30 days of History. Weight and measurements in Body.* | 不只看今天 / 也看清趋势 — *「历史」回看 30 天，「身体」记录体重和围度* | History chart and Body cards, dark mode |
| `07_log_your_way` | Photo, words, / or just numbers — *Describe a meal in any language, or type the numbers with no AI.* | 拍照、描述 / 或者只填数字 — *用任何语言描述一餐，或者手动输入，不用 AI* | The Log a meal sheet over the dimmed Today; rings on "no AI" / "any language" |
| `08_privacy` | Your log stays / on your phone — *No ads. No tracking. Open source.* | 饮食记录 / 只留在你的手机上 — *没有广告，不做追踪，代码公开* | EN: the real consent dialog, ring on "no server of its own … nothing is sent until you allow it". ZH: the day log plus three check rows (see "Chinese privacy frame") |

`frames.json` holds every caption, crop, ring, touch point and label, and a
`notes` line per frame naming the facts behind it.

## Render

Needs macOS with Google Chrome in `/Applications` and Python 3 with Pillow.
Nothing is downloaded; fonts are the Mac's own (SF Pro, PingFang SC).

```sh
cd app/ios/store/marketing-src
python3 render_store.py                      # both languages, all frames
python3 render_store.py --lang en --only 03  # one frame
python3 render_store.py --medium             # also 1206x2622 copies (see below)
python3 render_store.py --html-only          # just write the HTML pages
```

- Headless Chrome runs with a fresh `--user-data-dir` inside the build folder
  (default: a new folder in `$TMPDIR`; pick one with `--build DIR`). The script
  refuses any path inside the owner's Chrome profile. In a sandboxed agent
  shell, run it with the sandbox off (Chrome needs it).
- Each picture is cropped from `screens/` or `photos/` and resized with Lanczos
  to the exact device pixels it fills; the page renders at device scale 2
  (2640×5736) and is reduced to 1320×2868 with Lanczos. Captures are never edited.
- Contact sheets for review land in the build folder, not in the repo:
  `sheet_search_300_*.png` (frames 1–3 at search-result size),
  `sheet_trio_375_*.png`, `sheet_all_690_*.png` (product-page size).

### What the script checks (it fails on any of these)

- Every PNG is exactly 1320×2868, mode RGB, no alpha (PIL and `sips -g hasAlpha`),
  sRGB profile embedded, under 8 MB.
- Headline lines fit 1144 px (EN 128 px, never under 112; ZH 132 px, never
  under 124); the sub-line keeps its explicit lines (no extra wrap, at most 2);
  the caption block stays in the top third; the pill stays 60 px from the edge.
- The picture fits between the caption and the bottom margin; labels stay
  inside the side margins; rings and touch points stay inside their crop.
- A banned-word scan of every caption, sub-line, pill, label and check row
  (list below). Allowed exceptions are explicit (`ALLOW` in the script).

## Rules this set follows

Apple (checked 2026-11-11): 1320×2868 portrait, PNG/JPEG, no alpha; 1 to 10
per size and language; screenshots show the app in use and match the current
version (2.3, 2.3.1, 2.3.3); overlays and touch points are fine but must not
hide or misrepresent the UI; no prices or pricing terms (2.3.7); 4+-suitable
imagery (2.3.8); rights to everything shown (2.3.9, Unsplash License); no other
platforms or stores (2.3.10); no third-party logos (5.2.1); no Apple device
art: the app sits in plain rounded "screen cards", no bezels, no Dynamic
Island, no buttons; status bars are cropped out.

Copy: only claims in the 1.6.0 fact sheet. Never in added text: free / no
subscription / in-app purchase / any price; best, #1, first, only (as a
ranking), unique; accurate, precise, instant, in seconds; ratings, reviews,
user counts, awards, press; Android, APK, Google Play, GitHub, any URL; "Data
Not Collected", "nothing leaves your phone", offline, encrypted; Meta or
glasses; Apple Health, Watch, widgets, barcode; weight-loss promises; iPhone,
iCloud; "New in 1.6"; any provider or chain name (they appear only as plain
text inside the captured UI). "Snap" means the phone's own Camera app: the app
has no camera of its own, so no viewfinder or shutter art. "No Chopstats
account" is scoped on purpose: a key still needs an account with the AI company.

Chinese: Simplified only, 「」 around UI names, no mainland-China or VPN text
(the 11a crop starts below the welcome card for that reason), no line-end
commas in headlines.

## Chinese privacy frame

There is no Chinese capture of the consent dialog yet, so `08_privacy` (ZH)
shows the day log plus three check rows drawn in CSS (无需注册筷拍账户 /
未经你同意，不发送任何内容 / 开发者收不到你的任何数据, all in the fact sheet).
Once `screens/zh/13_ai_consent_dialog.png` exists (same steps as the English
one, Chinese UI), give ZH the English layout: one `screen` item with the dialog
cropped to its own edges (`radius` 74 at full width), measure the paragraph
that says nothing is sent until you allow it, ring it, and label it
「未经同意不发送」 (not "asks before every send": after you allow it, Watch Camera
Roll sends new photos without asking again).

## Next version (re-shoot and re-render)

1. Build the release from its tag on a dedicated **iPhone 17 Pro Max**
   simulator (1320×2868; never another agent's device), with made-up demo data
   only (the demo seed the README screenshots use, in `docs/readme/src/` once
   the README slides land; never the owner's data), status bar 9:41 / full bars.
2. Capture the same screens and drop them into `screens/en/` and `screens/zh/`
   with the same names: `01_today`, `05_meal_editor`, `11_settings_…` /
   `11a_settings_top_welcome`, `15_ai_provider_connection`, `10_usual_foods`,
   `03_restaurant_source_card`, `22_dark_history`, `23_dark_body`,
   `09_log_sheet`, `13_ai_consent_dialog`, `07_day_detail` (ZH).
3. Re-measure every crop, ring and touch point in `frames.json` (source
   pixels). Crops end in empty background, never through text; a quick way is
   to list rows whose pixels all equal the screen background, then pick y
   values inside those bands. Rings get their box from the ink of the words.
4. Run `render_store.py`, read every PNG and the contact sheets, and re-check
   every number a viewer can read (kcal, macros, servings, averages, weights)
   against the seed data.
5. Keep the captions unless a feature changed; re-check them against that
   release's fact sheet.

## Size classes

The 6.9-inch set (1320×2868) is the one built here. Apple's specification page
(read 2026-11-11) also lists a 6.3-inch "medium Dynamic Island" class
(1206×2622) as required, while `docs/RELEASING.md` (2026-10-25) calls it
optional. Check Media Manager when preparing the version; if it asks for that
class, `--medium` writes 1206×2622 copies (same aspect within 0.1 %) to
`../screenshots-marketing-medium/`.

## Credits

`photos/yogurt-bowl.jpg`: Natalie Behn on Unsplash (Unsplash License), see
`photos/CREDITS.md`. All app data on screen is made-up demo data.
