# H1: Ray-Ban Meta Gen 2 acceptance test (owner checklist)

Written 2026-10-24 for stage H1 of the Meta glasses and restaurant assist design. This is a plain-language checklist for testing the glasses while you can still return them. Do it in order. Part A is the only part that decides whether you keep the glasses, and it needs no new Bitewise build.

| Part | Question it answers | What it needs | Your time |
|---|---|---|---|
| Setup | Are all the settings right? | The glasses, the Meta AI app, your iPhone 18 Pro Max | 15 min |
| **A** | Does Meta put glasses photos into Apple Photos by itself, with the phone locked and Meta AI not open? **This decides the return.** | Nothing from Bitewise | About 45 min of active time, spread over 2 to 3 days |
| B | Does Bitewise log those photos, in the background and when you open it? | A Bitewise build with stages G1b, G2a, G2b and G3 (Claude installs it) | About 30 min, plus waiting |
| C | Does the restaurant assist work at a US chain? On Claude Plan it ends as a one-tap suggestion; an automatic apply with Undo needs a direct Anthropic or OpenRouter key. | A build with the R stages, your server redeployed, the lookup switched on (your approval), and TLS for the location half | 2 restaurant meals |

Build status on 2026-10-24 (branch feat/glasses-restaurant-assist): the glasses stages F1, G1a, G1b, G2a, G2b and G3 are built, so Part B can run on a new install. Of the restaurant stages, R1, R2a, R2b, R3a, R3b, R4 and R5b are merged, with the TLS guide (docs/SERVER_TLS.md); R2c, R5a, R6a to R6c, R7a and R7b (the assist itself, its settings and its diagnostics) are still to be built, so Part C waits for them. If the build is not ready before your return deadline, Part A alone decides. Parts B and C can wait, because any problem they find is a Bitewise problem we fix in software (see "Return the glasses if").

---

## 0. Before anything: write down two dates

1. **Delivery date.**
2. **Return deadline.** Use the date on your order (meta.com, Account, Orders, or the order email). The Oct 21 research found "free delivery and returns" on the Gen 2 product page, and a 30-day return window on Meta's Display glasses page. It did not confirm the Gen 2 window, so trust your order. If you bought somewhere else, use that store's policy.
3. **Your decision date is the deadline minus 3 days.** Finish Part A by then.

---

## 1. Setup (15 min, do this once)

Exact menu names may have changed since the Oct 21 research. If a menu item is not where this list says, write down where you found it, or that it was missing.

### 1.1 Glasses and the Meta AI app
1. Install **Meta AI** from the US App Store, pair the glasses, and let the app and the glasses firmware update fully.
2. Charge the glasses above 30%. Meta recommends more than 30% for auto-import.
3. In Meta AI, go to **Glasses** (top right) > **Device settings** > [your glasses] > **Media** and check that **Auto-import media** is **ON**. Meta says it is on by default on iOS, but two of its help pages disagree, so check.
4. In Meta AI, go to **Device settings** > **Early Access** and turn **Wi-Fi Aware** **ON**. Meta added it in v26 (June 29, 2026) to remove the "Meta AI wants to Join Wi-Fi network…" prompt on iPhone. It is the setting most likely to allow imports in the background. If the toggle is missing, it may now be the default (unverified). Write down "missing".
5. If iOS shows a one-time prompt to pair with or connect to the glasses, allow it.
6. Optional, for privacy: **Device settings** > **Glasses privacy** > **Cloud media** OFF. Meta otherwise keeps media on its servers for 30 days for some features.
7. Do not start an **autocapture** session or record video during the tests. Import is blocked while either is running, and autocapture clips never reach Apple Photos.
8. Leave **Dynamic photo** and **Ultra HDR** (added in v25/v26) at their defaults for the first round. If a single press turns into several photos (step A6), we come back to these settings.
9. Do **not** tap the version number in Meta AI > Settings > App info. Tapping it 5 times turns on Developer Mode, which this test does not need.

### 1.2 iPhone settings for Meta AI
Go to **Settings > Apps > Meta AI** (设置 > App > Meta AI):
- **Location: Always** (位置: 始终), and **Precise Location ON** (精确位置). Meta says the app needs location to geotag photos. With "Always" it can use your location "even without having your phone screen on and the Meta AI app open". The Oct 21 research also found that Meta needs location on iOS for the Wi-Fi link to the glasses. Giving Meta "Always" is your privacy decision. Round A5 tests whether "While Using" is enough.
- **Photos: Full Access** (照片: 完全访问).
- **Bluetooth: ON**. **Local Network: ON** (本地网络).
- **Background App Refresh: ON** (后台App刷新).

### 1.3 iPhone settings for the whole phone
- Keep **Bluetooth and Wi-Fi switched on**. The Control Center toggles count. Wi-Fi only needs to be on; the phone does not have to be connected to a network.
- Go to **Settings > General > Background App Refresh** (设置 > 通用 > 后台App刷新) and set it to **Wi-Fi & Cellular Data**.
- Go to **Settings > Battery** and turn **Low Power Mode OFF** (低电量模式) for the test days. Low Power Mode stops Bitewise's background scan.
- **Never swipe Bitewise away** in the app switcher. Doing that stops its background scan until you open it again. Do not swipe Meta AI away either, except in round A4, which tests exactly that.

### 1.4 Bitewise (needed for Parts B and C only)
- Claude installs the build. It is a free-team build, so it **expires 7 days after install**. Ask Claude for the exact expiry time. If Bitewise says "unavailable", the build has expired. After each new install, trust the developer again in **Settings > General > VPN & Device Management** (设置 > 通用 > VPN与设备管理).
- **Settings > Apps > Bitewise**: set **Photos: Full Access**. With Limited access, new glasses photos are invisible to Bitewise. Also turn **Background App Refresh: ON**.
- In Bitewise **Settings > Photos** (照片): turn **Watch Camera Roll** ON (监控相册), keep **Backfill Lookback** at 7 days (补扫回溯), and turn **Include Meta glasses photos** ON (包括 Meta 眼镜拍的照片). The last one is on by default in the new build.
- **Bitewise never asks for Location permission.** It reads a photo's location through Photos access only. If a Bitewise location prompt ever appears, that is a bug. Tap "Don't Allow" and tell Claude.

### 1.5 Where Bitewise's diagnostics are
In Bitewise, go to **Settings > AI Provider > Test This Provider** (AI 服务 > 测试当前服务). This opens the **Test AI provider** screen (测试 AI 服务). You do **not** need to tap "Run the checks", which spends two small AI calls. Scroll down to these sections:
- **Recent background scans** (最近的后台扫描), already in the app.
- **Late imports (other apps, glasses)** (后导入的照片（其他 App、眼镜）), stage G1b.
- **Glasses check** (眼镜检查), stage G3.
- **Restaurant lookups** (餐厅查询) and the last decisions, stage R7b.

Bitewise **Settings > Photos** also has a **Background scan** row (后台扫描) that shows when the last background scan ran.

---

## 2. Part A: does Meta import by itself? (decides the return)

Keep a note with times in 24-hour local time for every round: **shutter** (when you pressed the button), **fold** (when you folded or cased the glasses), and **seen** (when the photo first appeared in Apple Photos).

While you run Part A, your current Bitewise build treats glasses photos like any camera photo. Non-food glasses shots still go to your AI to be classified. For non-food test shots, pick boring things such as a wall, the floor or the sky. The current build may also not log glasses photos until you open it. That is the gap this project fixes, so do not judge Bitewise during Part A.

### A1. Baseline: does the import work at all? (5 min, at home)
1. Unlock the phone and open Meta AI on screen.
2. Take 1 photo with one press of the capture button. Fold the glasses.
3. Open **Photos > Recents**. **Expected:** the photo appears within about a minute. One owner reports "after a few moments"; Meta publishes no figure.
4. If it never arrives: check every item in 1.1 and 1.2, then see the triage table (section 5, row A1).

### A2. The hands-off test (the main test, 40 min, mostly waiting)
1. Put Meta AI in the **background**: swipe up to the Home Screen, but do **not** swipe it away in the app switcher.
2. **Lock the phone** and put it in your pocket.
3. Take **3 photos**: 2 of food and 1 not of food. Note each shutter time.
4. **Wait at least 15 minutes before folding.** This gap shows whether Photos keeps the shutter time or uses the import time.
5. **Fold the glasses** or put them in the case. Note the fold time. Do not touch the phone.
6. After **10 minutes**, unlock the phone and open **Photos** directly (not Meta AI). Look in **Recents** and write down which photos are there.
7. If they are missing: lock the phone again, wait **20 more minutes**, and check again.
8. If they are still missing after 30 minutes: open **Meta AI** and note whether the import starts now, and how long it takes. That result means imports happen only in the foreground.
9. Write down whether any **"Meta AI wants to Join Wi-Fi network…"** prompt or any other system prompt appeared, and when.

### A3. Repeat in real life (spread over at least 2 days)
Repeat A2 **4 more times**, for **5 hands-off tries** in total. Run them after real meals, not back to back. At least one try should be away from home with the phone on cellular data only, for example at a restaurant, with the Wi-Fi switch still on.

### A4. Force-quit variant (once, just to find out)
Swipe Meta AI away in the app switcher, then repeat A2 once. The likely result is no import until you open Meta AI. **Failing this is not a reason to return.** It only tells you the daily rule: never swipe Meta AI away.

### A5. Location variant (once each)
1. Set **Settings > Apps > Meta AI > Location** to **While Using the App** (使用App期间) and repeat A2 once. Write down whether the import happened and whether the photo has a location (step A6).
2. Optional: repeat with **Never** (永不). The import may stop completely, because Meta needs location for the Wi-Fi link. That result is useful to know too.
3. Set the location back to your choice afterwards.

### A6. Look closely at one imported photo (10 min)
Open the photo in Photos and swipe up for the info panel (or tap the "i" button). Write down:
- **Time shown:** your shutter time or your fold time? Use a photo from A2, where the two differ by 15 minutes or more.
- **Camera line:** copy the exact text. Community reports suggest "Meta AI" with "Ray-Ban Meta Smart Glasses", or "Ray-Ban Meta Smart Glasses 2" for Gen 2. These strings are not verified.
- **Size and format:** about **12 MP, 3024 × 4032**, HEIF (or JPEG). Write down any photo that is much smaller, such as a preview copy.
- **File name, if shown:** the expected pattern is `photo-<digits>_singular_display_fullPicture`. Send it with the digits replaced by `#`.
- **Saved from…:** if the panel shows which app saved the photo, copy that text.
- **Location:** is a map shown, yes or no? Never send the map, the address or coordinates. For the real test of when the location is stamped, take a photo at a restaurant and fold the glasses only after you get home. Then write down whether the pin is at the **restaurant**, at **home**, or missing.
- **Album:** in **Photos > Albums**, is there an album named **"Meta AI"**, and is the photo in it? Copy the exact album name.
- **Copies:** did one press create 2 or more nearly identical photos? Did a small copy appear first and a full-size one later?
- Optional: does the photo still show in Meta AI's Gallery? That gallery reads Apple Photos. **Careful: deleting a photo in Meta AI also deletes it from Apple Photos.**

### A7. Framing (check during A2 and A3)
Is the plate fully in frame and sharp in at least 4 of your 5 food shots? There is no viewfinder, so tilt your head down until the plate fills your view.

### A8. Optional: read the exact EXIF tags on your Mac (5 min)
Use this only if the Bitewise Glasses check card is not ready and Claude needs the exact strings.
1. Take one glasses photo of a **blank wall**.
2. AirDrop it to your Mac. In the share sheet, tap **Options**, turn **Location OFF** and **All Photos Data ON**.
3. In Terminal, run the command below on the file in Downloads. Paste only its output to Claude.
   ```
   sips -g make -g model -g software -g creation -g pixelWidth -g pixelHeight -g format ~/Downloads/<file name>
   ```
4. Delete the file from the Mac.

### Part A passes when:
- At least **4 of the 5** hands-off tries (A2/A3) put the photos into Apple Photos **within 30 minutes of folding**, with no need to open Meta AI and no repeated Wi-Fi join prompt.
- The photos are **full size** (about 12 MP).
- At least **4 of 5** food shots are usable plate photos.

---

## 3. Part B: does Bitewise log glasses photos? (needs G1b to G3)

### B1. Background logging: does a meal log itself without opening the app? (the main Bitewise test)
1. At a meal, take **5 food** and **5 non-food** glasses photos (non-food ideas: ceiling, floor, door, a wall, the sky). Also take **1 iPhone camera photo** of the same food as a control. Note the shutter times.
2. Leave Bitewise in the background (never swiped away), lock the phone, and fold the glasses.
3. **Do not open Bitewise for at least 4 hours**, or overnight. iOS decides when Bitewise's background scan runs, usually a few times a day. No iOS feature wakes Bitewise when a photo arrives.
4. Open Bitewise and go **straight to the diagnostics** (section 1.5) before doing anything else.
5. **Recent background scans:** find a scan whose **start time is before you opened the app** and whose counts line shows **"logged" of 1 or more**. If one exists, background logging works. Opening the app runs its own catch-up, so only scans before the open count.
6. **Late imports:** expected "{n} caught in 7 days · last {time}", where n went up by the number of glasses food photos and {time} is before you opened the app.
7. **Glasses check:** read one row per photo (expected values in the table below).

### B2. On open: logging when you open Bitewise
Take 1 glasses food photo with Bitewise in the background, fold, wait until the photo is in Photos, then open Bitewise. **Expected:** the meal appears within about 2 minutes, from the launch catch-up plus the late-import pass.

### B3. Live: Bitewise open on screen
With Bitewise open on the Today screen, take 1 photo and fold the glasses. **Expected:** the meal appears within about 2 minutes after the import lands in Photos.

### B4. Dating
For each logged meal, compare the time Bitewise shows with your shutter time. **Expected:** it matches the **shutter time** in local time (CDT), never the fold time, and it is **never off by whole hours** (5 h would be a time-zone bug).

### B5. Duplicates and preview copies
**Expected:** one meal per plate. If Meta made 2 copies of one shot, the second copy's Glasses check row says **"duplicate"**. A small preview copy says **"waiting for full size"** for up to 10 minutes, then the full-size photo is processed.

### B6. Badge
**Expected:** the meal card shows a glasses icon labelled **"Meta glasses"** (Meta 眼镜).

### B7. Non-food stays on the phone
**Expected:** the 5 non-food photos show **"not food"**, and no meal is created. That outcome comes from the on-phone check, which means those photos were **never sent to your AI**. Write down all 10 food scores, food and non-food, so the threshold can be tuned.

### B8. The Include switch
Turn **Include Meta glasses photos** OFF, take 1 food photo and fold. **Expected:** the Glasses check row says **"excluded"** and no meal is created. Turn the switch back ON.

### B9. Camera photos are not slowed down
**Expected:** the iPhone camera control photo from B1 is logged exactly as before, with no new delay, even while glasses photos are waiting or being checked.

### What the Glasses check card should show
The card covers the last 20 glasses photos from the last 14 days. It never shows coordinates. Example of one healthy row (illustrative values): *Signal: filename · Meta AI / Ray-Ban Meta Smart Glasses 2 · import lag 32 min · GPS yes · GPS time +0:20 · food 0.63 · logged.*

| Row | What we expect | What a surprise means |
|---|---|---|
| **Signal** (how Bitewise recognized the photo) | `filename` (the name contains `singular_display`), `album` (in the "Meta AI" album), or `exif` (Make/Model). If the card shows only one signal, also check the album and file name yourself (A6). | No signal and no badge: send the Make/Model text, the album name and the file-name pattern. Claude updates the detection table. |
| **Make / Model** | Make "Meta AI"; Model "Ray-Ban Meta Smart Glasses" or "Ray-Ban Meta Smart Glasses 2". These are likely but unverified. | Different text: send it exactly. |
| **Import lag** (capture time, then the time the photo was added to Photos) | About the time from shutter to fold, plus under a minute. Example: shot at 12:10, folded at 12:40, lag about 30 min. | A lag near 0 for a photo shot long before folding means Photos used the import time. Check B4: Bitewise should still show the shutter time. |
| **GPS** | Yes with Meta AI location "Always"; probably no with "Never". | No with "Always": Meta does not geotag. Restaurant lookups then use printed brands only. |
| **GPS time difference** (GPS fix time minus capture time) | Small, within ±10 min, which means the location was stamped at the shutter. | About the same as the import lag means the location was stamped at import, possibly at home. Bitewise then treats glasses locations as unverified and can only make suggestions from them, by design. |
| **Food score** | Food photos at or above **0.10** (the starting threshold); non-food photos below it. | A real food photo below 0.10 is a false "not food". Send all the scores. A blank score with no outcome yet means the on-phone check could not run in the background and the photo waits for the app to open. Send that too. |
| **Outcome** | `logged`, `not food`, `duplicate`, `waiting for full size`, or `excluded`. | Any other outcome, or a photo missing from the card: triage row B. |

---

## 4. Part C: restaurant assist at a US chain (needs R1 to R7)

**On Claude Plan, expect suggestions, not automatic applies.** Your server searches with the Claude CLI's WebSearch tool, which returns a summary of each search, not text taken from the cited page. Bitewise applies published numbers by itself only when every number is found in text from the source page itself. So on Claude Plan, a lookup that finds your item ends as a **one-tap suggestion** at most. When nothing else about the match stands in the way, its decision code is `not_grounded`. That is by design (docs/SERVER.md, "Evidence"). An automatic apply with Undo needs a direct **Anthropic** or **OpenRouter** key in Bitewise, because their search returns page text. Giving your server page text (a WebFetch pinned to the chain's own website, design L5) is your decision, and it is not built. Each step below says what to expect on each.

### Before the test (Claude or you, not at the restaurant)
1. Your server is redeployed with the lookup endpoints (docs/SERVER_DEPLOY.md), and you have approved `CLAUDE_LOOKUP_ENABLED=1` after `scripts/lookup_smoke.py` passes.
2. TLS (docs/SERVER_TLS.md) is required for the **location half** on Claude Plan. Without https, Bitewise looks up **brand only** (C1 and C2 still work; skip C3 and C4).
3. In Bitewise **Settings > Restaurant nutrition** (餐厅营养), read the hint under the mode. It must **not** say "Your server needs an update" or "Restaurant lookup is turned off on your server". On http it says "Nearby-restaurant lookups need https…", which means brand only.
4. The assist is **Off by default**. For the test, set **Restaurant nutrition lookup** to **Always** (总是). "Always" skips only the AI's confidence check; every privacy gate still applies. The consent sheet appears; tap **Use location** (使用位置), or **Brand only** (仅按品牌) on http. Check that **Use photo location** (使用照片位置) is ON. The footnote should say "Lookups go to your own server, which uses Claude web search (Anthropic)."

### Where and what to order
- Pick a **free-standing** location of a chain that is in Bitewise's chain table: **McDonald's, Chick-fil-A, Culver's, Starbucks, Panera Bread or Chipotle**. Each one's own website (for example mcdonalds.com) is the only source Bitewise accepts for an automatic apply. Avoid malls, food courts and busy blocks: with 3 or more restaurants close together, Bitewise only suggests.
- Order **one standard menu item, whole**: no combo meal, no sharing, nothing customized. Take the photo **before you eat**.
- The assist runs **only while Bitewise is open on screen**, never in the background. After the meal, open Bitewise **the same day and within 12 hours** and keep it on the Today screen for about **3 minutes**. Lookups on your server run as jobs, which the app checks every 10 s for up to 2 minutes.
- You can combine this with B1: take lunch photos at the chain, wait 4 hours for the background check, then open Bitewise in the afternoon. That is still the same day and within 12 hours.

### C1. Brand path (the cup, wrapper or bag is in the photo)
1. Take a glasses photo with the **printed logo clearly visible** on the cup, wrapper, box or bag next to the food. Also take 1 iPhone camera photo of the same scene as a control.
2. **Expected on Claude Plan (a one-tap suggestion):**
   - A chip on the meal card: "{chain} publishes {kcal} kcal — tap to review". Diagnostics shows the decision code `not_grounded`.
   - Tap the chip. The meal editor shows a source card with the menu item, size and serving, the published kcal/P/C/F, "**Source: mcdonalds.com**" and "via Claude Plan · {date}".
   - Tap **Use published numbers** (采用公布数值). The published numbers replace the AI's estimate.
3. **Expected with a direct Anthropic or OpenRouter key (automatic apply):**
   - A snackbar: "Used McDonald's's published numbers: 540 → 590 kcal" with **Undo**. The numbers are examples.
   - A chip on the meal card: "McDonald's numbers used for 1 item(s)", plus a small "updated" dot until you open the meal.
   - In the meal editor, the same source card, with "via {provider} · {date}" and "Number found on the source page".
4. **Also fine with a direct key (suggestion instead of apply):** the chip reads "{chain} publishes {kcal} kcal — tap to review". This happens when the match is not airtight: a combo, a size range, numbers very different from the AI's estimate, or a meal older than 12 hours. Write down the decision code from Diagnostics. On Claude Plan, any code other than `not_grounded` is worth writing down too.

### C2. Undo
1. With a direct key only: tap **Undo** (撤销) on the snackbar. **Expected:** the kcal goes back to **exactly** the old number from the snackbar, and the chip disappears. On Claude Plan there is no automatic apply and no snackbar, so skip this step.
2. Open the meal editor and tap **Look up restaurant nutrition** (查找餐厅营养) to run the lookup by hand. On Claude Plan it suggests again: accept it with **Use published numbers** (采用公布数值). With a direct key it applies or suggests again.
3. Tap **Use AI estimate** (改用 AI 估算). **Expected:** the kcal goes back to **exactly** the AI's number from before the published numbers were used.

### C3. Location path, first visit (no logo in the photo)
1. Photograph food with **no logo visible**, for example a dine-in tray or plate with the logos kept out of the frame. Also take an iPhone camera control photo.
2. **Expected: a one-tap suggestion, never an automatic apply on a first visit.** The chip reads "{chain} publishes {kcal} kcal — tap to review".
3. Open the meal and tap **Use published numbers** (采用公布数值). It applies and remembers that you confirmed this chain at this spot.
4. If nothing happens, check: does the Glasses check card say GPS yes? Is the GPS time difference within ±10 min? A glasses photo with no GPS uses the brand path only.

### C4. Location path, second visit
Go to the **same location**, at least **6 hours later** (ideally another day; the same item is not applied twice within 6 h). Order the same item and take a logo-free photo. **Expected on Claude Plan:** a one-tap suggestion again, with `not_grounded`. The spot you confirmed in C3 is remembered, but the number check still needs page text. **Expected with a direct Anthropic or OpenRouter key:** an **automatic apply** with snackbar and Undo. If you get a suggestion with any other code, write down the GPS line and the GPS time difference from the Glasses check card, and the decision code. A missing or stale GPS fix time on a glasses photo keeps it a suggestion, by design. With a direct key, the iPhone control photo should then apply.

### C5. Home meal (negative test)
Photograph a home-cooked meal at home, with the mode still "Always". **Expected:** nothing happens, and the **Restaurant lookups** count ("Today n/20") does not go up.

### C6. Privacy check
Check these three things:
- Bitewise never asked for Location permission.
- Bitewise shows no map, no street and no address anywhere.
- The source line names only the chain's own website.

### Afterwards
Set **Restaurant nutrition lookup** back to what you want to keep: **When unsure** (不确定时), or **Off**, which is the default. Turning it Off offers "Also clear learned places".

---

## 5. When something fails: triage per step

**Send values, never pictures.** Typing the values is best. A screenshot of Bitewise's **Test AI provider** screen is fine, because it shows no photos, keys or locations.

**Never send:**
- photos, or screenshots of Photos, the Meta AI gallery or a photo's info panel;
- maps, addresses or coordinates;
- API keys, the server upload key, the server address, or the setup link or QR code;
- Meta account details.

| Step | Symptom | Check first | Values to send |
|---|---|---|---|
| A1 / A2 | Photo never reaches Photos | Meta AI > Media > Auto-import ON; Early Access > Wi-Fi Aware ON; glasses above 30%; Bluetooth and Wi-Fi switches on; iOS Location, Photos (Full), Local Network and Bluetooth allowed for Meta AI; not recording, no autocapture | Meta AI app version (Settings > App info; do not tap it 5 times) and the glasses firmware version (in Device settings); whether the Wi-Fi Aware toggle exists and its state; phone locked or unlocked; Meta AI backgrounded or swiped away; minutes waited; whether opening Meta AI started the import and how long it took; any system prompt text |
| A2 | Arrives only after opening Meta AI | Wi-Fi Aware ON? Meta AI not swiped away? Low Power Mode off? | Same as above, plus how often it happened (for example "3 of 5 tries") |
| A6 | Photos shows the fold time, not the shutter time | Nothing to fix in Meta; Bitewise's dating guard handles this if the EXIF time is right | Shutter time, fold time, the time Photos shows, and A8 output if you ran it |
| A6 | Many copies per shot | Dynamic photo / Ultra HDR in Meta AI capture settings | Copies per press, their sizes (MP), and whether turning Dynamic photo off stops it |
| A6 | No location with "Always" | Meta AI Location Always + Precise | "GPS: no", the Location setting, and whether the pin is at the restaurant or at home in the fold-at-home test |
| B1 | Not logged before you opened the app | **Recent background scans**: any scans between the fold and the open? If none: Background App Refresh (global and Bitewise), Low Power Mode, Bitewise swiped away? Also the Bitewise **Settings > Photos > Background scan** row | The start time and the counts line ("listed / read / processed / logged / left for later") of each scan since the fold, and each one's stop reason; the Background scan row text; the Late imports line, with any status line under it ("History expired — rescanning" or "Needs iOS 16") |
| B1 / B2 / B3 | Photo is in Photos but missing from the Glasses check card | Bitewise Photos access is **Full** (not Limited); Watch Camera Roll ON; Include Meta glasses photos ON | The access level shown in Settings > Apps > Bitewise > Photos; the Late imports line; whether the meal appeared after opening the app, and how many minutes later |
| B1 | Card row has no outcome and a blank food score | The on-phone food check could not run in the background, so the photo waits for the app to open | The row as shown, and whether it changed to logged or not food after opening |
| B4 | Wrong meal time | Is the error a whole number of hours (time zone) or the fold time? | Shutter time, fold time, Bitewise meal time, and the card's import lag |
| B5 | Two meals for one plate | Glasses check rows for both | Both rows (signal, size if shown, import lag, outcome) |
| B6 | No glasses badge | Glasses check signal | Make/Model text, album name, file-name pattern with digits as `#` |
| B7 | A food photo marked "not food" | Glasses check food score | All 10 scores, each labelled food or non-food (no pictures; a short word such as "burger" or "wall" is enough) |
| C (any) | No lookup at all | Settings > Restaurant nutrition hint text; mode is Always; consent given; your provider is Claude Plan, Anthropic or OpenRouter (others are unsupported) | The hint text, the **Restaurant lookups** line ("Today n/20 · last {code}"), and the last decisions (code, old → new kcal, provider) |
| C1 | Suggestion instead of apply (with a direct key; on Claude Plan a suggestion with `not_grounded` is expected) | Decision code | The code; what you ordered (item and size); whether it was a combo or customized; the old and published kcal |
| C3 / C4 | No suggestion from location | Glasses check: GPS yes or no, GPS time difference; https on your server; "Use photo location" ON | Those values; whether the iPhone control photo got a suggestion; whether the place was a mall or a busy block |
| C2 | Undo did not restore exactly | Did you edit the meal before tapping Undo? (Edits are protected on purpose.) | Old kcal, new kcal, kcal after Undo, and any message shown ("This meal was changed after…", "This meal was just updated…") |

---

## 6. Return the glasses if…

Decide by **the deadline minus 3 days**, using Part A only. Run Part A as written: Wi-Fi Aware on, Meta AI in the background (not swiped away), the phone locked, and Location set to "Always" unless you decided against it.

**Return them if any of these is true:**
1. **Fewer than 4 of 5** hands-off tries put the photos into Apple Photos within **30 minutes of folding** without you opening Meta AI. If exactly 3 of 5 worked, run 3 more tries and keep the glasses only if 6 of the 8 worked.
2. The import **only happens when you open Meta AI**, or iOS asks you to tap "Join Wi-Fi network" **every time**. Logging would then mean "open Meta AI after every meal", which is not hands-free.
3. Only **small preview copies** ever reach Photos, never the full-size (about 12 MP) photo.
4. **Fewer than 4 of 5** food shots are usable plate photos (framing or focus).
5. You will not keep Meta AI's Location at "Always", **and** round A5 shows that the import fails with "While Using".

**Do not return them for these (they are Bitewise or iOS issues that we fix in software or work around):**
- Bitewise misses, misdates or fails to recognize glasses photos, or its food score is off.
- Background scans are rare. iOS schedules them; opening Bitewise always catches up.
- The force-quit round (A4) fails. Just never swipe Meta AI away.
- Photos have no geotag. Restaurant lookups still work from printed brands.
- Photos shows the import time instead of the shutter time.
- Restaurant lookups do not work yet: server, TLS or decision rules.
- Meta's developer kit (DAT) is not a rescue for criteria 1 and 2. It works only while Bitewise is open and the glasses are unfolded, so it cannot log meals in the background either.

---

## 7. Report-back template (copy, fill in, paste to Claude)

```
H1 report: date ______  Meta AI app version ____  glasses firmware ____
Return deadline ______   Wi-Fi Aware toggle: on / missing
Meta AI Location: Always / While Using / Never   Precise: on/off

PART A (one line per try)
try | MetaAI bg/swiped | locked y/n | shutter | fold | seen in Photos | opened MetaAI? | prompt?
1   |                  |            |         |      |                |                |
2 ... 5
A4 force-quit: imported? __ after opening Meta AI? __
A5 While Using: imported? __ GPS? __     Never (optional): imported? __ GPS? __
A6: time shown = shutter / fold;  camera line "______";  size __ MP __x__;
    file name pattern "photo-#_..."; Saved from "____"; album "____";
    copies per press __; preview copy seen? __; pin (fold-at-home test): restaurant / home / none
A7: usable food shots __ of __
A8 (optional): sips output pasted below

PART B
Background scans since fold (start time | logged count | stop reason): ...
Late imports line: "____"  status line: "____"
Glasses check rows (signal | make/model | lag | GPS | GPS time | food score | outcome): ...
Meal times vs shutter (B4): ...
Badge shown? __   Include-switch-off outcome: __   Camera control logged normally? __

PART C
Chain ______ (standalone? y/n)  server https? y/n
Provider: Claude Plan / Anthropic / OpenRouter
C1: applied / suggested (code ____) / nothing; old → new ___ → ___; source host ____
C2: Undo exact (direct key only)? __  manual lookup again? __  Use AI estimate exact? __
C3: suggestion? __  C4 (date/time ____): applied / suggested (code ____)
C5 home meal: lookups count unchanged? __
Restaurant lookups line "____"; last decisions (code, old → new, provider): ...
```

---

## 8. Sources behind the Meta claims (and how sure we are)

Facts from the October 2026 feature research (research:glasses; not in the repo), unless noted otherwise:

| Claim used above | Confidence | Source |
|---|---|---|
| Auto-import puts glasses media into the iPhone Photos library. It is on by default on iOS and runs when the glasses are on and either in the case or folded. It needs phone Bluetooth and Wi-Fi on, and Meta recommends battery above 30%. Imported media is removed from the glasses, and deleting in Meta AI also deletes from Photos. | Verified (Meta help) | https://www.meta.com/help/ai-glasses/1510723473009423/ ; https://www.meta.com/help/ai-glasses/1427588664906909/ ; https://www.meta.com/help/ai-glasses/683425686669295/ |
| Imports go to an album called "Meta AI". One owner saw import still work with Photos set to Limited, cellular blocked and Background App Refresh off, with photos appearing "after a few moments". | Likely (one owner, one open-source detector) | https://michael.team/rb/ ; https://github.com/infinitefutureinc/nohole/blob/main/nohole/Services/SmartGlassesDetector.swift ; Meta's "Meta View is now Meta AI" page, https://www.meta.com/help/ai-glasses/1964061290737893/ (from the Oct 21 research) |
| The file name looks like `photo-{id}_singular_display_fullPicture.HEIC`. | Likely | nohole (above) ; https://github.com/bgorzelic/skyforge/blob/main/src/skyforge/core/media.py |
| EXIF Make is "Meta AI"; Model is "Ray-Ban Meta Smart Glasses", or "…Glasses 2" for Gen 2. No Software value was found. Converter tools can fake these tags. | Likely, unverified on Gen 2 | nohole (above) ; https://od2.in/meta-glasses-converter ; https://github.com/m0mosenpai/instadamn |
| Photos are HEIC or JPEG at 4032 × 3024 (HEIC on iOS). | Likely | https://wearables.developer.meta.com/llms.txt?product=all&version=1.0&document=products/dat/sections/guides/camera-capture ; HEIC on iOS: https://www.meta.com/help/ai-glasses/272319252352130/ (from the Oct 21 research) |
| A late import that keeps an old EXIF time gets creationDate = the capture time and addedDate = the import time. | Verified on the iOS 26.2 **simulator** only; H1 confirms it on the device | Simulator probe logs from the G1a work (not in the repo) |
| Geotagging needs Meta AI location permission. With "Always" the phone's location can be used with the screen off and the app closed. Without permission, photos reportedly have no location. Whether the geotag is stamped at capture or at import is unknown. | Likely | https://www.meta.com/help/ai-glasses/265581062369977/ ; https://michael.team/rb/ (feature research: location and glasses) |
| Meta needs location permission on iOS for the Wi-Fi link to the glasses. | Likely (Meta help, read 2026-10-21) | https://www.meta.com/help/ai-glasses/265581062369977/ (from the Oct 21 research) |
| Wi-Fi Aware is an Early Access option, added in v26 (2026-06-29) under Device settings > Early Access, that removes the "Meta AI wants to Join Wi-Fi network…" prompt. It is unknown whether it is still Early Access. Apple's Wi-Fi Aware works in the foreground and background on iOS 26+ and iPhone 12 or later. | Release note verified; that it enables background import is an **inference** | https://www.meta.com/help/ai-glasses/1809764829519902/ ; https://developer.apple.com/documentation/wifiaware (from the Oct 21 research; not in the feature research) |
| Autocapture clips stay in Meta AI, and import is blocked while recording or during autocapture. | Verified (Meta help and a Meta community manager) | https://www.meta.com/help/ai-glasses/1677728930250028/ ; https://communityforums.atmeta.com/discussions/ai-captures/import-photos/1350920 (from the Oct 21 research) |
| Cloud media keeps media on Meta's servers for 30 days, and the toggle can be turned off. | Verified (Meta help) | https://www.meta.com/help/ai-glasses/734190441863923/ (from the Oct 21 research) |
| No PhotoKit API wakes Bitewise when a photo is added, so logging waits for a background scan or the next app open. | Likely (not tested on a device in the background) | https://developer.apple.com/videos/play/wwdc2022/10132/ ; the feature research, part (b) |
| DAT cannot wake Bitewise; its session ends on fold or when the app is backgrounded. | Likely | https://wearables.developer.meta.com/llms.txt?product=all&version=1.0&document=products/dat/sections/guides/lifecycle-events ; https://github.com/facebook/meta-wearables-dat-ios/blob/main/CHANGELOG.md |
| Return policy: the Gen 2 page offers "free delivery and returns", and the Display page states 30 days. The Gen 2 window itself was **not** confirmed. | Partial | https://www.meta.com/ai-glasses/ray-ban-meta-wayfarer-matte-black-clear-gen-2/ (from the Oct 21 research) |

The "Oct 21 research" is the camera-glasses research run of 2026-10-21 (its notes are not in the repo).

---

## 9. For Claude after the owner reports (not for the owner)

- Record the results in memory under H1, with the checklist outcome and the deadline decision.
- Update from the measured values:
  - the strings in `services/photo/glasses.dart`: album, file-name token, Make/Model;
  - `kFoodLabels` and `kFoodThreshold` (start 0.10), from the 10 scores;
  - the GPS freshness defaults in `core/place_match.dart`: the ±10 min gate, and the unknown-accuracy default of 65 m for glasses;
  - the dating guard, if the glasses write UTC times with no offset tag.
- Turn every failure into a fixture or regression test in G1b to G3 or R2b to R2c (design H1 "tests").
- Card gaps to consider fixing if they show up in the test:
  - the Glasses check card shows only one signal;
  - it has no separate "waiting for the app to open" outcome for a background food-check deferral (`deferred_gpu`).
- Copy nit spotted while writing C1: the design's snackbar template "Used {brand}'s published numbers" renders as "McDonald's's" for brands that already end in 's (McDonald's, Wendy's, Culver's). It needs a template without the possessive, for example "Used published numbers from {brand}: {old} → {new} kcal".
- If criterion 1 or 2 of "Return the glasses if" fails, do not propose L4 (DAT) as a fix. It is foreground-only.
- On Claude Plan, `not_grounded` suggestions are the expected Part C result: the server's evidence is a search summary (`verbatim: false`, lookup_jobs.py), and decideAssist grounds numbers only in verbatim page text. If the owner wants automatic applies on Claude Plan, that is design L5 (a WebFetch pinned to the chain's own domains that returns page text). It needs the owner's decision before anything is built.
