# Google Play phone screenshots: the shot list

For the QA step that owns the emulators (`docs/RELEASING.md` § 6.5). No
screenshot is in this folder yet: they are captured from the **release
build of the Play variant** (no Watch Camera Roll, no Photo Coverage;
decision 1, 2026-11-13), never from a debug build (the DEBUG banner) and
never from the iPhone sets, which Play refuses (1320×2868 and 1206×2622
are about 2.17:1).

## What Play accepts

From "Add preview assets to showcase your app"
(<https://support.google.com/googleplay/android-developer/answer/9866151>,
read 2026-11-13):

- JPEG or 24-bit PNG, **no alpha**; each side 320 to 3840 px; the long
  side at most twice the short side. At least 2 to publish, up to 8 per
  device type.
- To be eligible for recommendations: at least 4 screenshots of at
  least 1080 px.

What we capture, per language: **at least 4 portrait shots, 9:16,
1080×1920** (or larger at 9:16), 24-bit PNG with no alpha, en-US and
zh-CN.

## How

- Use an emulator whose screen is 1080×1920 to begin with: the `pixel_2`
  device profile (1080×1920, 9:16). The existing AVD `ct_e2e` is a Pixel 7
  at 1080×2400 (2.22:1), which Play refuses, and squeezing it with
  `adb shell wm size` changes the layout the app was laid out for. For
  example, with the system image `ct_e2e` already uses and the
  `avdmanager` under `$ANDROID_HOME/cmdline-tools` (not Homebrew's):

  ```bash
  "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd -n play_shots \
      -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_2
  ```

  `adb shell wm size 1080x1920` on `ct_e2e` (undo with `adb shell wm size
  reset`) is only the fallback. Gesture navigation, light mode unless the
  shot says dark, font and display size at default, system language as the
  shot's language, status bar clean (`adb shell settings put global
  sysui_demo_allowed 1` and the demo-mode broadcasts, or accept the real
  bar).
- Capture: `adb exec-out screencap -p > NN_name.png`. `screencap` writes
  RGBA; drop the alpha and check every file with
  `python3 scripts/play_graphics.py --check-shots app/android/store/screenshots/en-US`
  (it flattens RGBA onto white and refuses a wrong size, ratio or format).
- Demo data only: no real meals, no API key in view, no server address,
  no notification content from a real account. Use food photos that may
  be shown publicly: the README demo pictures in `docs/readme/photos/`,
  whose licences are listed in `docs/readme/CREDITS.md`.
- Name the files `NN_name.png` in Play order, in
  `app/android/store/screenshots/en-US/` and `.../zh-CN/`.

## The shots (same order in both languages)

| # | File | Screen | Must show |
|---|---|---|---|
| 1 | `01_today.png` | Today with three or four logged meals | Meal cards with photos, the day's calories and macros |
| 2 | `02_meal_editor.png` | A photo meal opened in the editor | Food items with the portion the AI assumed, editable numbers |
| 3 | `03_log_sheet.png` | The Log sheet over Today | From recent photos, Describe a meal, Enter manually, My usual foods, Leftovers |
| 4 | `04_history.png` | History | The 30-day chart and daily totals |
| 5 | `05_body.png` (optional) | Body | Weight trend and measurements |
| 6 | `06_ai_provider.png` (optional) | Settings › AI Provider › API Key | The provider list, no key in view |
| 7 | `07_dark_today.png` (optional) | Today in dark mode | As shot 1 |

Never in a shot: Watch Camera Roll, Photo Coverage, Meta glasses rows,
anything that names the GitHub APK, a real key or address, a provider's
logo, or accuracy or user-count claims.

After capture, the owner uploads them under **Grow users › Store presence
› Main store listing** (and the zh-CN translation) with the graphics from
`app/android/store/graphics/`.
