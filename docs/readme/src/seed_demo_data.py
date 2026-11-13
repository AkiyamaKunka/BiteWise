#!/usr/bin/env python3
"""Seed a simulator's Chopstats 1.6.0 install with DEMO data for the README.

Usage: seed_demo_data.py <en|zh> <app data container> <db.dart path> <photos dir>

  app data container: xcrun simctl get_app_container <device> <bundle id> data
  db.dart path:       app/lib/data/db.dart (the schema is read from it)
  photos dir:         docs/readme/photos (the five Unsplash photos)
Close the app first; the script replaces its database.

Made-up meals, weights and measurements only (no real person's data). Photo
meals use ONLY the five owner-approved Unsplash photos; each becomes that
meal's meal_thumbs JPEG the way the app makes one (long side 160 px, JPEG
q70, no EXIF). Every other meal is a described or typed meal (no photo).
The restaurant meal is a chicken burrito bowl with Chipotle's published
numbers applied (the values Chipotle's US nutrition calculator lists for a
standard serving of each ingredient). The app must not be running.
"""
import io
import json
import os
import plistlib
import random
import re
import sqlite3
import sys
from datetime import datetime, timedelta

from PIL import Image

lang, container, db_dart, photos = sys.argv[1:5]
assert lang in ("en", "zh")
rng = random.Random(1170 if lang == "en" else 1171)
now = datetime.now()
today = now.date()

# ---------------------------------------------------------------- thumbs
# Crop boxes (fractions of the original: left, top, right, bottom) frame the
# food the way a phone photo of it would; then the app's own thumb recipe.
CROPS = {
    "yogurt-bowl": (0.02, 0.40, 0.98, 0.86),
    "chicken-salad": (0.00, 0.36, 1.00, 1.00),
    "burrito-bowl": (0.18, 0.06, 0.96, 0.76),
    "iced-latte": (0.175, 0.20, 0.575, 0.96),
    "dumplings": (0.12, 0.00, 1.00, 1.00),
}


def thumb(name):
    im = Image.open(os.path.join(photos, name + ".jpg")).convert("RGB")
    w, h = im.size
    l, t, r, b = CROPS[name]
    im = im.crop((int(l * w), int(t * h), int(r * w), int(b * h)))
    w, h = im.size
    if max(w, h) > 160:
        if w >= h:
            im = im.resize((160, max(1, round(h * 160 / w))), Image.BOX)
        else:
            im = im.resize((max(1, round(w * 160 / h)), 160), Image.BOX)
    out = io.BytesIO()
    im.save(out, "JPEG", quality=70)  # PIL writes no EXIF unless asked
    return out.getvalue()


THUMBS = {k: thumb(k) for k in CROPS}

# ---------------------------------------------------------------- schema
src = open(db_dart, encoding="utf-8").read()
start = src.index("const List<String> kSchemaDdl = [")
block = src[start:src.index("];", start)]
ddl = re.findall(r"'''(.*?)'''|'(CREATE INDEX[^']*)'", block, re.S)
stmts = [a or b for a, b in ddl]
assert len(stmts) >= 10, len(stmts)

docs = os.path.join(container, "Documents")
os.makedirs(docs, exist_ok=True)
dbp = os.path.join(docs, "calorie_tracker.db")
for suffix in ("", "-wal", "-shm", "-journal"):
    if os.path.exists(dbp + suffix):
        os.remove(dbp + suffix)
for stale in ("ct_debug_tab",):
    if os.path.exists(os.path.join(docs, stale)):
        os.remove(os.path.join(docs, stale))
db = sqlite3.connect(dbp)
for s in stmts:
    db.execute(s)
db.execute("PRAGMA user_version = 3")


def item(name, kcal, p, c, f):
    return {"name": name, "estimated_calories": kcal,
            "protein_g": p, "carbs_g": c, "fat_g": f}


def ts_of(d, hhmm):
    h, m = map(int, hhmm.split(":"))
    return datetime(d.year, d.month, d.day, h, m)


def insert_meal(d, hhmm, source, meal, confidence="medium", context="home",
                extra=None, photo=None):
    desc, items = meal
    items = [dict(i) for i in items]
    ts = ts_of(d, hhmm)
    analysis = {
        "is_food": True,
        "meal_description": desc,
        "total_calories": sum(i["estimated_calories"] for i in items),
        "total_protein_g": sum(i["protein_g"] for i in items),
        "total_carbs_g": sum(i["carbs_g"] for i in items),
        "total_fat_g": sum(i["fat_g"] for i in items),
        "estimate_confidence": confidence,
        "restaurant_context": context,
        "food_items": items,
    }
    if source == "app_manual":
        analysis.pop("estimate_confidence")
        analysis.pop("restaurant_context")
    if extra:
        analysis = extra(analysis, d)
    h = ""
    if photo:
        h = "demo%s%s" % (d.strftime("%Y%m%d"), hhmm.replace(":", ""))
    cur = db.execute(
        "INSERT INTO meals (chat_id, date, time, timestamp, source, image_hash,"
        " file_id, analysis, corrected) VALUES (1, ?, ?, ?, ?, ?, NULL, ?, 0)",
        (d.isoformat(), ts.strftime("%I:%M %p"),
         ts.isoformat(timespec="milliseconds"), source, h or None,
         json.dumps(analysis, ensure_ascii=False)))
    if photo:
        db.execute("INSERT INTO meal_thumbs (meal_id, jpeg) VALUES (?, ?)",
                   (cur.lastrowid, THUMBS[photo]))


# ---------------------------------------------------------------- meals
# Chipotle's published numbers (US nutrition calculator, one standard
# serving each): name, serving, kcal, protein, carbs, fat.
CHIPOTLE = [
    ("Chicken", "4 oz", 180, 32, 0, 7),
    ("White Rice", "4 oz", 210, 4, 40, 4),
    ("Black Beans", "4 oz", 130, 8, 22, 1.5),
    ("Roasted Chili-Corn Salsa", "4 oz", 80, 3, 16, 1.5),
    ("Fajita Veggies", "2 oz", 20, 1, 5, 0),
]
# Checked 2026-11-11 against Chipotle's US nutrition PDF (chipotle.com, dated
# July 2022) and its nutrition calculator: every calorie, protein, carb and
# fat value above matches, and the names and servings are the calculator's
# ("White Rice", fajita veggies 2 oz).

if lang == "en":
    YOGURT = ("Greek yogurt bowl with blackberries and granola", [
        item("Greek yogurt, 2% (~200 g)", 150, 20, 8, 4),
        item("Blackberries (~60 g)", 25, 1, 6, 0),
        item("Granola (~40 g)", 185, 4, 26, 7)])
    CAESAR = ("Chicken Caesar salad", [
        item("Grilled chicken breast (~140 g)", 225, 42, 0, 5),
        item("Romaine and croutons (~120 g)", 115, 4, 15, 4),
        item("Caesar dressing (~30 g)", 150, 1, 1, 16),
        item("Parmesan shavings (~15 g)", 60, 5, 0, 4),
        item("Hard-boiled egg (1 large)", 75, 6, 1, 5),
        item("Tomato (~40 g)", 7, 0, 2, 0)])
    BOWL = ("Chicken burrito bowl", [
        item("Grilled chicken (~110 g)", 200, 34, 0, 7),
        item("Cilantro-lime rice (~140 g)", 200, 4, 42, 2),
        item("Black beans (~110 g)", 140, 9, 24, 1),
        item("Roasted corn salsa (~90 g)", 90, 3, 18, 2),
        item("Fajita peppers and onions (~60 g)", 30, 1, 6, 1)])
    LATTE_AI = ("Iced latte", [item("Iced latte (~350 ml)", 160, 9, 13, 8)])
    LATTE_MINE = ("Iced latte", [item("Iced latte", 120, 4, 14, 5)])
    DUMPLINGS = ("Pan-fried pork dumplings", [
        item("Pan-fried pork dumplings (7 pieces, ~180 g)", 380, 16, 36, 18),
        item("Shredded cabbage (~40 g)", 10, 1, 2, 0)])
    OATS = ("Oatmeal with banana", [item("Oatmeal with banana", 350, 10, 62, 7)])
    TEXT_BREAKFAST = [
        ("Scrambled eggs on toast", [
            item("Scrambled eggs (2 eggs)", 180, 12, 2, 14),
            item("Whole-wheat toast (2 slices)", 160, 8, 28, 2)]),
        ("Avocado toast with a fried egg", [
            item("Sourdough toast (~60 g)", 160, 6, 30, 1),
            item("Avocado (~70 g)", 115, 1, 6, 10),
            item("Fried egg (1 large)", 90, 6, 0, 7)]),
    ]
    TEXT_LUNCH = [
        ("Turkey and Swiss sandwich", [
            item("Turkey breast (~85 g)", 90, 18, 2, 1),
            item("Swiss cheese (1 slice)", 105, 8, 0, 8),
            item("Whole-grain bread (2 slices)", 220, 10, 38, 3)]),
        ("Tomato soup and grilled cheese", [
            item("Tomato soup (~300 ml)", 150, 4, 26, 4),
            item("Grilled cheese sandwich", 380, 15, 30, 22)]),
    ]
    TEXT_DINNER = [
        ("Salmon rice bowl", [
            item("Grilled salmon (~120 g)", 250, 27, 0, 15),
            item("Steamed rice (~150 g)", 195, 4, 43, 0),
            item("Edamame (~50 g)", 60, 6, 5, 3)]),
        ("Spaghetti bolognese", [
            item("Spaghetti (~200 g cooked)", 315, 12, 62, 2),
            item("Bolognese sauce (~150 g)", 220, 14, 10, 13)]),
        ("Chicken stir-fry with rice", [
            item("Chicken and vegetable stir-fry (~200 g)", 320, 30, 12, 16),
            item("Steamed rice (~150 g)", 195, 4, 43, 0)]),
    ]
    SNACKS = [
        ("Apple with peanut butter", [
            item("Apple (1 medium)", 95, 0, 25, 0),
            item("Peanut butter (~32 g)", 190, 7, 7, 16)]),
        ("Mixed nuts", [item("Mixed nuts (~30 g)", 175, 5, 7, 15)]),
    ]
    NOTES = "Standard servings from Chipotle's nutrition calculator."
else:
    YOGURT = ("黑莓燕麦脆酸奶碗", [
        item("希腊酸奶（~200 克）", 150, 20, 8, 4),
        item("黑莓（~60 克）", 25, 1, 6, 0),
        item("格兰诺拉燕麦脆（~40 克）", 185, 4, 26, 7)])
    CAESAR = ("鸡肉凯撒沙拉", [
        item("烤鸡胸肉（~140 克）", 225, 42, 0, 5),
        item("罗马生菜和面包丁（~120 克）", 115, 4, 15, 4),
        item("凯撒沙拉酱（~30 克）", 150, 1, 1, 16),
        item("帕玛森奶酪片（~15 克）", 60, 5, 0, 4),
        item("水煮蛋（1 个）", 75, 6, 1, 5),
        item("番茄（~40 克）", 7, 0, 2, 0)])
    BOWL = ("鸡肉卷饼碗", [
        item("烤鸡肉（~110 克）", 200, 34, 0, 7),
        item("香菜青柠米饭（~140 克）", 200, 4, 42, 2),
        item("黑豆（~110 克）", 140, 9, 24, 1),
        item("烤玉米莎莎（~90 克）", 90, 3, 18, 2),
        item("炒彩椒洋葱（~60 克）", 30, 1, 6, 1)])
    LATTE_AI = ("冰拿铁", [item("冰拿铁（~350 毫升）", 160, 9, 13, 8)])
    LATTE_MINE = ("冰拿铁", [item("冰拿铁", 120, 4, 14, 5)])
    DUMPLINGS = ("煎饺", [
        item("猪肉煎饺（7 个，~180 克）", 380, 16, 36, 18),
        item("卷心菜丝（~40 克）", 10, 1, 2, 0)])
    OATS = ("牛奶燕麦粥", [item("牛奶燕麦粥", 320, 12, 48, 8)])
    TEXT_BREAKFAST = [
        ("豆浆配鲜肉包", [
            item("无糖豆浆（~300 毫升）", 95, 9, 4, 5),
            item("鲜肉包（2 个，~160 克）", 375, 14, 48, 14)]),
        ("小米粥配茶叶蛋", [
            item("小米粥（~300 克）", 140, 4, 28, 1),
            item("茶叶蛋（1 个）", 75, 6, 1, 5)]),
    ]
    TEXT_LUNCH = [
        ("番茄炒蛋盖饭", [
            item("番茄炒蛋（~250 克）", 290, 15, 12, 20),
            item("米饭（~200 克）", 255, 5, 56, 1)]),
        ("宫保鸡丁饭", [
            item("宫保鸡丁（~200 克）", 380, 28, 14, 24),
            item("米饭（~200 克）", 255, 5, 56, 1)]),
    ]
    TEXT_DINNER = [
        ("清蒸鲈鱼配青菜", [
            item("清蒸鲈鱼（~200 克）", 220, 36, 2, 8),
            item("清炒菜心（~200 克）", 90, 4, 8, 5),
            item("米饭（~150 克）", 190, 4, 42, 0)]),
        ("麻婆豆腐饭", [
            item("麻婆豆腐（~250 克）", 320, 18, 10, 23),
            item("米饭（~200 克）", 255, 5, 56, 1)]),
        ("兰州牛肉面", [
            item("牛肉拉面（~450 克）", 520, 24, 80, 11),
            item("卤蛋（1 个）", 80, 6, 1, 6)]),
    ]
    SNACKS = [
        ("苹果", [item("苹果（1 个，~200 克）", 105, 1, 28, 0)]),
        ("每日坚果", [item("每日坚果（1 包，~30 克）", 175, 5, 7, 15)]),
    ]
    NOTES = "数值为 Chipotle 营养计算器中每份标准分量。"


def applied_chipotle(analysis, d):
    items = analysis["food_items"]
    before_tot = {k: analysis[k] for k in (
        "total_calories", "total_protein_g", "total_carbs_g", "total_fat_g")}
    matches = []
    for idx, (menu, serving, k, p, c, f) in enumerate(CHIPOTLE):
        it = items[idx]
        before = {"estimated_calories": it["estimated_calories"],
                  "protein_g": it["protein_g"], "carbs_g": it["carbs_g"],
                  "fat_g": it["fat_g"]}
        applied = {"estimated_calories": k, "protein_g": p, "carbs_g": c,
                   "fat_g": f}
        it.update(applied)
        it["published"] = True
        matches.append({
            "item_index": idx, "menu_item": menu, "match_type": "exact",
            "option_label": "", "serving": serving, "qty": 1,
            "published": {"calories": k, "protein_g": p, "carbs_g": c,
                          "fat_g": f},
            "before": before, "applied": applied})
    after = {
        "total_calories": sum(i["estimated_calories"] for i in items),
        "total_protein_g": sum(i["protein_g"] for i in items),
        "total_carbs_g": sum(i["carbs_g"] for i in items),
        "total_fat_g": sum(i["fat_g"] for i in items),
    }
    analysis.update(after)
    analysis["restaurant_context"] = "restaurant"
    analysis["assist"] = {
        "v": 2, "status": "applied", "trigger": "auto",
        "evidence": "location_confirmed",
        "chain_key": "chipotle", "brand_name": "Chipotle",
        "matches": matches,
        "applied_total": after["total_calories"],
        "totals": {"before": before_tot, "applied": after},
        "source": {"url": "https://www.chipotle.com/nutrition-calculator",
                   "host": "www.chipotle.com", "type": "official",
                   "year": d.year},
        "grounded": True, "provider": "anthropic",
        "decided_on": d.isoformat(),
        "reason": "ok", "notes": NOTES,
    }
    return analysis


def glasses(analysis, d):
    analysis["capture"] = {"device": "meta_glasses", "signal": "filename",
                           "has_gps": False}
    return analysis


# Past days, oldest first. Photo meals are only the five photographed
# dishes; everything else was described in words or typed by hand.
for back in range(34, 0, -1):
    d = today - timedelta(days=back)
    # Breakfast
    if back in (2, 5, 9, 13, 16, 20, 24, 29):
        insert_meal(d, "07:%02d" % rng.randint(30, 55), "app_manual", OATS)
    elif back % 3 == 0:
        insert_meal(d, "08:%02d" % rng.randint(0, 40), "manual_text",
                    TEXT_BREAKFAST[back % 2])
    else:
        insert_meal(d, "0%d:%02d" % (rng.choice([7, 8]), rng.randint(0, 50)),
                    "app_photo", YOGURT, photo="yogurt-bowl")
    # Lunch
    if back == 1:
        insert_meal(d, "12:%02d" % rng.randint(10, 40), "app_watch", CAESAR,
                    context="restaurant", extra=glasses,
                    photo="chicken-salad")
    elif back % 4 == 0:
        insert_meal(d, "12:%02d" % rng.randint(5, 50), "manual_text",
                    TEXT_LUNCH[(back // 4) % 2])
    elif back % 4 == 2:
        insert_meal(d, "12:%02d" % rng.randint(5, 50), "app_photo", BOWL,
                    context="restaurant", photo="burrito-bowl")
    else:
        insert_meal(d, "12:%02d" % rng.randint(5, 50), "app_photo", CAESAR,
                    photo="chicken-salad")
    # Afternoon
    if back % 2 == 0:
        if back in (2, 6, 10, 14):
            insert_meal(d, "15:%02d" % rng.randint(20, 55), "app_manual",
                        LATTE_MINE)
        else:
            insert_meal(d, "15:%02d" % rng.randint(20, 55), "app_photo",
                        LATTE_AI, photo="iced-latte")
    elif back % 5 == 1:
        insert_meal(d, "16:%02d" % rng.randint(0, 40), "manual_text",
                    SNACKS[0])
    # Dinner
    if back % 3 == 1:
        insert_meal(d, "%d:%02d" % (rng.choice([18, 19]), rng.randint(0, 55)),
                    "app_photo", DUMPLINGS, photo="dumplings")
    else:
        insert_meal(d, "%d:%02d" % (rng.choice([18, 19]), rng.randint(0, 55)),
                    "manual_text", TEXT_DINNER[back % 3])
    if back % 4 == 3:
        insert_meal(d, "21:%02d" % rng.randint(0, 40), "manual_text",
                    SNACKS[1])

# Today: the rich day.
insert_meal(today, "08:10" if lang == "en" else "07:50", "app_photo", YOGURT,
            photo="yogurt-bowl")
insert_meal(today, "12:30" if lang == "en" else "12:20", "app_photo", BOWL,
            context="restaurant", extra=applied_chipotle, photo="burrito-bowl")
insert_meal(today, "15:40", "app_photo", LATTE_AI, photo="iced-latte")
if lang == "en":
    insert_meal(today, "19:05", "app_photo", CAESAR, photo="chicken-salad")
else:
    insert_meal(today, "18:50", "app_photo", DUMPLINGS, photo="dumplings")

# ---------------------------------------------------------------- body
# A gentle trend (about 2.6 lb / 1.2 kg over 30 days), so the demo does not
# read as a weight-loss result.
LB = 0.45359237
start_kg = 172.6 * LB if lang == "en" else 78.3
end_kg = 170.0 * LB if lang == "en" else 77.1
days = 30
for back in range(days, -1, -1):
    if back % 7 == 3:
        continue  # a few days without a weigh-in
    frac = (days - back) / days
    kg = start_kg + (end_kg - start_kg) * frac
    if back:
        kg += rng.uniform(-0.25, 0.25)
        kg = max(kg, end_kg + 0.1)  # today stays the low point (no label clash)
    d = today - timedelta(days=back)
    db.execute(
        "INSERT INTO body_weight (chat_id, date, weight_kg, source, note,"
        " logged_at) VALUES (1, ?, ?, 'manual', '', ?)",
        (d.isoformat(), round(kg, 2), ts_of(d, "07:05").isoformat()))
for i, back in enumerate((28, 21, 14, 7, 0)):
    d = today - timedelta(days=back)
    db.execute(
        "INSERT INTO body_measurements (chat_id, date, waist_cm, chest_cm,"
        " hip_cm, note, logged_at) VALUES (1, ?, ?, ?, ?, '', ?)",
        (d.isoformat(), round(85.4 - i * 0.2, 1), round(101.0 - i * 0.1, 1),
         round(99.2 - i * 0.15, 1), ts_of(d, "07:06").isoformat()))
db.commit()
print("meals", db.execute("SELECT COUNT(*) FROM meals").fetchone()[0],
      "thumbs", db.execute("SELECT COUNT(*), MAX(LENGTH(jpeg)) FROM meal_thumbs").fetchone(),
      "today", db.execute(
          "SELECT COUNT(*), SUM(json_extract(analysis,'$.total_calories'))"
          " FROM meals WHERE date=?", (today.isoformat(),)).fetchone(),
      "weights", db.execute("SELECT COUNT(*) FROM body_weight").fetchone()[0])
db.close()

# ---------------------------------------------------------------- prefs
pp = os.path.join(container, "Library", "Preferences",
                  "dev.calorietracker.calorieTracker.plist")
prefs = {}
if os.path.exists(pp):
    with open(pp, "rb") as fh:
        prefs = plistlib.load(fh)
prefs.update({
    "flutter.settings.app_language": lang,
    "flutter.settings.units": "imperial" if lang == "en" else "metric",
})
os.makedirs(os.path.dirname(pp), exist_ok=True)
with open(pp, "wb") as fh:
    plistlib.dump(prefs, fh, fmt=plistlib.FMT_BINARY)
print("prefs", sorted(k for k in prefs if k.startswith("flutter.")))
