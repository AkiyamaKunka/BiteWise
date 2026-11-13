# README slides: source

The pictures in `docs/readme/slides/` (English), `docs/readme/zh/slides/`
(Chinese) and `docs/readme/social-preview.png` are rendered from this folder.
Nothing here is loaded from the internet: the phone frames, icons and
diagrams are drawn in CSS and SVG, the type is the Mac's own SF Pro and
PingFang SC, and the only photos are the five Unsplash photos in
`../photos/` (credits in `../CREDITS.md`).

| File | What it is |
|---|---|
| `deck.json` | The 14 slides. Each slide holds its layout and positions, plus an `en` and a `zh` block with that language's text and screenshots. |
| `social.json` | The 1280 × 640 social preview card (GitHub › Settings › Social preview). |
| `slides.css` | The visual system: colours, type, the CSS phone frame, photo cards, zoom cards, diagrams. |
| `render.py` | The renderer. Its docstring lists every field the JSON files accept. |
| `html/en/`, `html/zh/` | The HTML pages `render.py` generated, kept for reference. They link the screenshots with relative paths. |
| `seed_demo_data.py` | Fills a simulator's Chopstats install with the demo data the screenshots show. |
| `screens/` | The screenshots (git-ignored, see below). |

## Re-render

Needs Python 3 with Pillow, and Google Chrome in `/Applications`.

```sh
cd docs/readme/src
python3 render.py deck.json --lang en --out ../slides
python3 render.py deck.json --lang zh --out ../zh/slides
python3 render.py social.json --lang en --out .. --size 1280x640 --max-kb 1000
```

Add `--only 06-usual,07-restaurant` to render some slides, and
`--sheet /tmp/sheet.jpg` to get a contact sheet. Chrome runs headless with
its own throwaway profile in `build/` (git-ignored). In a sandboxed shell,
Chrome needs the sandbox off.

Each slide is drawn at twice its size and scaled down, then saved as JPEG
quality 90 with full colour resolution. Keep each slide under 600 KB and
all of `docs/readme/` under about 8 MB.

## Screenshots

`render.py` reads screenshots from `screens/en/` and `screens/zh/`
(`--screens` points elsewhere). They are 1320 × 2868 PNGs from an
iPhone 17 Pro Max simulator, status bar at 9:41, in light mode except the
`_dark_` ones. They are not committed; re-shoot them when the
App Store look changes.

1. Build the app at the release tag (for example `v1.6.0`) for the
   simulator, with `debugShowCheckedModeBanner: false` in
   `app/lib/ui/app.dart`, and install it.
2. Close the app and seed demo data, once per language:
   `python3 seed_demo_data.py en "$(xcrun simctl get_app_container <device> <bundle id> data)" ../../../app/lib/data/db.dart ../photos`
   It writes made-up meals, weights and measurements only. Never shoot real
   data.
3. Open each screen and save it with
   `xcrun simctl io <device> screenshot screens/en/<name>.png`. The names
   `deck.json` uses are listed below.

| Name | Screen |
|---|---|
| `01_today` | Today, top |
| `02_today_meals_chipotle_usual_chip` | Today scrolled to the meal cards (English) |
| `02b_today_meals_bottom_dumplings` | Today scrolled to the end, with the dumplings card (Chinese) |
| `04_usual_numbers_card` | Edit meal of the iced latte with the Your usual numbers card |
| `05_meal_editor` | Edit meal (English: Chicken Caesar salad; Chinese: the yogurt bowl) |
| `09_log_sheet` | The Log a meal sheet |
| `10_usual_foods` | My usual foods |
| `11_settings_watch_camera_roll_glasses` | Settings › Photos, Watch Camera Roll and Meta glasses photos on |
| `11a_settings_top_welcome` | Settings at the top (Chinese; used for the Stop Sharing row) |
| `20_dark_today`, `22_dark_history`, `23_dark_body` | Today, History and Body in dark mode |
| `21_dark_restaurant_source_card` | Edit meal of the burrito bowl with the restaurant source card, dark mode |

Zoom cards and highlights in `deck.json` are crops in screenshot pixels
(`[x, y, width, height]`). If a re-shot screen moves, update those numbers
and look at every slide again.

## Slides tied to a release

Since 2026-11-13 the README shows only `01-hero`, `02-how`, `03-control` and
`10-privacy`. The items below for `06-usual`, `07-restaurant`, `09-glasses`
and `13-next` matter only if one of those slides goes back on the page.

- `01-hero`, `02-how` and every slide with a phone: screenshots of 1.6.0.
  The footer says "Version 1.6 · demo data".
- `06-usual`, `07-restaurant` and `09-glasses` carry the "New in 1.6" pill.
  Drop it once 1.6 is no longer the newest version.
- `13-next` shows what is on `main` but not in the App Store build (the
  native iOS look, iCloud Backup). It has no screenshots and no date. When
  1.7.0 ships, its features go into the README's list (What else it does),
  not onto a slide.
- `07-restaurant` shows Chipotle's published numbers as demo data, with
  "not affiliated" in the footer. All calorie, protein, carb and fat values
  match Chipotle's US nutrition PDF (July 2022); the 1.6.0 shots show the
  fajita veggies serving as 2.5 oz where the PDF says 2 oz.
  `seed_demo_data.py` now uses 2 oz.
