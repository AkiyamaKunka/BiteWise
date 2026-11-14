#!/usr/bin/env python3
"""Google Play graphics for Chopstats, made from the app icon.

    python3 scripts/play_graphics.py                # store icon + feature graphics, then --verify
    python3 scripts/play_graphics.py --launcher     # also the adaptive icon's layers in app/assets/
    python3 scripts/play_graphics.py --verify       # check the committed files only (no fonts needed)
    python3 scripts/play_graphics.py --check-shots DIR [--fix]   # Play's screenshot rules

Writes, from app/assets/app_icon.png (1024 x 1024, opaque, the iOS and
Android icon art):

- app/android/store/graphics/icon-512.png: 512 x 512, 32-bit PNG (RGBA),
  full square with no rounded corners (Play applies its own mask and
  shadow), at most 1024 KB.
- app/android/store/graphics/feature-graphic.png (en-US) and
  feature-graphic-zh-CN.png: 1024 x 500, 24-bit PNG (RGB, no alpha).
- with --launcher, app/assets/app_icon_foreground.png and
  app_icon_monochrome.png (1024 x 1024 RGBA): the adaptive icon's
  foreground with the background keyed out, and the themed-icon
  silhouette (white, alpha only), which flutter_launcher_icons turns into
  the res/drawable-*/ic_launcher_{foreground,monochrome}.png files
  (app/pubspec.yaml). Then run `dart run flutter_launcher_icons` in app/.

Play's rules (support.google.com/googleplay/android-developer/answer/9866151,
read 2026-11-13): icon 512 x 512, 32-bit PNG with alpha, 1024 KB max;
feature graphic 1024 x 500, JPEG or 24-bit PNG with no alpha (required to
publish); screenshots JPEG or 24-bit PNG with no alpha, each side 320 to
3840 px, the long side at most twice the short side.

Needs Python 3 with Pillow. The feature graphics use the Mac's own fonts
(SF Pro, Hiragino Sans GB); nothing is downloaded. --verify and
--check-shots need no fonts.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
APP_ICON = ROOT / "app" / "assets" / "app_icon.png"
FOREGROUND = ROOT / "app" / "assets" / "app_icon_foreground.png"
MONOCHROME = ROOT / "app" / "assets" / "app_icon_monochrome.png"
GRAPHICS = ROOT / "app" / "android" / "store" / "graphics"
STORE_ICON = GRAPHICS / "icon-512.png"
FEATURE = {
    "en-US": GRAPHICS / "feature-graphic.png",
    "zh-CN": GRAPHICS / "feature-graphic-zh-CN.png",
}

# The icon's flat colours (app_icon.png's most frequent ones). The
# monochrome weight is how opaque each part is in the themed icon: the
# unfilled track stays a lighter ring, as in the notification icon
# (res/drawable/ic_stat_bitewise.xml), a little stronger than its 0.35 so
# it still reads on a dark themed tile.
BACKGROUND = (0xF0, 0xEB, 0xE2)  # = adaptive_icon_background in pubspec.yaml
PARTS = {
    "ring": ((0xB2, 0x5D, 0x3A), 1.0),
    "track": ((0xD6, 0xCD, 0xC1), 0.45),
    "blue": ((0x2A, 0x78, 0xD6), 1.0),
    "orange": ((0xEB, 0x68, 0x34), 1.0),
    "green": ((0x1B, 0xAF, 0x7A), 1.0),
}

# Feature graphic: the README / App Store marketing palette and captions
# (app/ios/store/marketing-src/store.css and README.md frame 01).
INK = (0x22, 0x19, 0x15)
INK_2 = (0x5C, 0x4E, 0x47)
CLAY = (0xB2, 0x5D, 0x3A)
TAGLINE = {
    "en-US": "Snap a meal. Get the numbers.",
    "zh-CN": "拍下这一餐，热量一目了然",
}
SF_PRO = Path("/System/Library/Fonts/SFNS.ttf")
HIRAGINO = Path("/System/Library/Fonts/Hiragino Sans GB.ttc")

MAX_ICON_BYTES = 1024 * 1024
SHOT_MIN, SHOT_MAX = 320, 3840


# --------------------------------------------------------------- icon layers


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _mix(lo, hi, u):
    """(t, residual): u as lo + t * (hi - lo), t clamped to [0, 1]."""
    d = _sub(hi, lo)
    n = _dot(d, d)
    t = 0.0 if n == 0 else max(0.0, min(1.0, _dot(_sub(u, lo), d) / n))
    fit = (lo[0] + t * d[0], lo[1] + t * d[1], lo[2] + t * d[2])
    r = _sub(u, fit)
    return t, math.sqrt(_dot(r, r))


def _decompose(u):
    """How one pixel colour of the flat-colour icon came about.

    Each anti-aliased edge pixel is a blend of two flat colours: the
    background and one part, or two parts (where the ring meets its
    track). Returns ((r, g, b, a) for the keyed foreground, monochrome
    alpha 0..1, residual)."""
    best = None
    parts = list(PARTS.values())
    for colour, weight in parts:
        t, res = _mix(BACKGROUND, colour, u)
        cand = (res, (colour[0], colour[1], colour[2], round(255 * t)), t * weight)
        if best is None or cand[0] < best[0]:
            best = cand
    for i, (c1, w1) in enumerate(parts):
        for c2, w2 in parts[i + 1:]:
            t, res = _mix(c1, c2, u)
            cand = (res, (u[0], u[1], u[2], 255), w1 + t * (w2 - w1))
            if cand[0] < best[0]:
                best = cand
    res, rgba, mono = best
    if rgba[3] == 0:
        rgba = (0, 0, 0, 0)  # coloured in by _bleed
    return rgba, mono, res


def _bleed(layer: Image.Image, steps: int = 12) -> Image.Image:
    """Give the fully transparent pixels next to the art the colour of the
    art beside them. flutter_launcher_icons resizes without premultiplying
    alpha, so an edge pixel averages its neighbours' colours as well as
    their alpha: transparent pixels of another colour would tint or lighten
    every edge. Alpha is unchanged."""
    alpha = layer.getchannel("A")
    seen = alpha.point(lambda a: 255 if a else 0)
    rgb = layer.convert("RGB")
    black = Image.new("RGB", layer.size)
    rgb = Image.composite(rgb, black, seen)
    for _ in range(steps):
        grown = rgb.filter(ImageFilter.MaxFilter(3))
        rgb = Image.composite(rgb, grown, seen)
        seen = seen.filter(ImageFilter.MaxFilter(3))
    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


def launcher_layers(icon: Image.Image):
    """The adaptive icon's keyed foreground and its monochrome silhouette."""
    rgb = icon.convert("RGB")
    table = {}
    worst = 0.0
    for _count, colour in rgb.getcolors(rgb.width * rgb.height):
        rgba, mono, res = _decompose(colour)
        table[colour] = (rgba, (255, 255, 255, round(255 * mono)))
        worst = max(worst, res)
    if worst > 24:
        raise SystemExit(
            f"app_icon.png has a colour {worst:.0f} away from every blend of "
            "its parts: the palette in play_graphics.py no longer matches the "
            "icon art")
    flat = getattr(rgb, "get_flattened_data", None) or rgb.getdata  # Pillow 12+ / older
    pixels = list(flat())
    fg = Image.new("RGBA", rgb.size)
    fg.putdata([table[p][0] for p in pixels])
    fg = _bleed(fg)
    mono = Image.new("RGBA", rgb.size)
    mono.putdata([table[p][1] for p in pixels])
    return fg, mono


# --------------------------------------------------------------- store art


def store_icon(icon: Image.Image) -> Image.Image:
    return icon.convert("RGB").resize((512, 512), Image.LANCZOS).convert("RGBA")


def _font(path: Path, size: int, *, weight: str | None = None, index: int = 0):
    if not path.exists():
        raise SystemExit(f"font {path} not found: render the feature graphics on a Mac")
    font = ImageFont.truetype(str(path), size, index=index)
    if weight:
        font.set_variation_by_name(weight)
    return font


def feature_graphic(foreground: Image.Image, lang: str) -> Image.Image:
    """1024 x 500, drawn at 2x and reduced: the mark on the left, the name
    and the App Store's first caption on the right, kept inside a 64 px
    margin (Play may crop the edges). The text shrinks until it fits."""
    s = 2
    w, h = 1024 * s, 500 * s
    margin = 64 * s
    art = foreground.crop(foreground.getbbox())
    mark_h = 250 * s
    mark = art.resize((round(art.width * mark_h / art.height), mark_h), Image.LANCZOS)
    left = 80 * s
    x = left + mark.width + 56 * s
    for size in range(72, 40, -2):
        name = _font(SF_PRO, size * s, weight="Bold")
        zh_name = _font(HIRAGINO, round(size * 0.92) * s, index=2)
        if lang == "zh-CN":
            tag = _font(HIRAGINO, round(size * 0.5) * s, index=0)
        else:
            tag = _font(SF_PRO, round(size * 0.52) * s, weight="Medium")
        probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
        gap = round(size * 0.22) * s
        name_w = (probe.textlength("Chopstats", font=name) + gap
                  + probe.textlength("·", font=name) + gap
                  + probe.textlength("筷拍", font=zh_name))
        tag_w = probe.textlength(TAGLINE[lang], font=tag)
        if x + max(name_w, tag_w) <= w - margin:
            break
    else:
        raise SystemExit(f"feature graphic ({lang}): the text does not fit")

    img = Image.new("RGB", (w, h), BACKGROUND)
    img.paste(mark, (left, (h - mark_h) // 2), mark)
    draw = ImageDraw.Draw(img)
    base = h // 2 + round(size * 0.12) * s
    draw.text((x, base), "Chopstats", font=name, fill=INK, anchor="ls")
    x2 = x + draw.textlength("Chopstats", font=name) + gap
    draw.text((x2, base), "·", font=name, fill=CLAY, anchor="ls")
    x3 = x2 + draw.textlength("·", font=name) + gap
    draw.text((x3, base), "筷拍", font=zh_name, fill=INK, anchor="ls")
    draw.text((x, base + round(size * 0.95) * s), TAGLINE[lang], font=tag,
              fill=INK_2, anchor="ls")
    return img.resize((1024, 500), Image.LANCZOS)


# --------------------------------------------------------------- checks


def png_header(path: Path):
    """(width, height, bit depth, colour type) from the PNG's IHDR chunk."""
    with open(path, "rb") as f:
        head = f.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a PNG")
    return struct.unpack(">IIBB", head[16:26])


def verify() -> list[str]:
    """Problems with the committed files; empty when they are what Play wants."""
    problems = []
    if not STORE_ICON.exists():
        problems.append(f"{STORE_ICON} is missing")
    else:
        w, h, depth, ctype = png_header(STORE_ICON)
        if (w, h) != (512, 512):
            problems.append(f"icon is {w}x{h}, not 512x512")
        if (depth, ctype) != (8, 6):
            problems.append("icon is not a 32-bit PNG with alpha (8-bit RGBA)")
        if STORE_ICON.stat().st_size > MAX_ICON_BYTES:
            problems.append("icon is over 1024 KB")
    for lang, path in FEATURE.items():
        if not path.exists():
            problems.append(f"{path} is missing")
            continue
        w, h, depth, ctype = png_header(path)
        if (w, h) != (1024, 500):
            problems.append(f"feature graphic {lang} is {w}x{h}, not 1024x500")
        if (depth, ctype) != (8, 2):
            problems.append(f"feature graphic {lang} is not a 24-bit PNG without alpha")
    for path in (FOREGROUND, MONOCHROME):
        if path.exists():
            w, h, depth, ctype = png_header(path)
            if (w, h, depth, ctype) != (1024, 1024, 8, 6):
                problems.append(f"{path.name} is not a 1024x1024 RGBA PNG")
    return problems


def check_shots(folder: Path, fix: bool) -> int:
    files = sorted(p for p in folder.iterdir()
                   if p.suffix.lower() in (".png", ".jpg", ".jpeg") and not p.name.startswith("."))
    if not files:
        print(f"no screenshots in {folder}")
        return 1
    bad = 0
    portrait_916 = 0
    for p in files:
        with Image.open(p) as im:
            im.load()
            w, h = im.size
            mode = im.mode
            fmt = im.format
        why = []
        if fmt not in ("PNG", "JPEG"):
            why.append(f"format {fmt}")
        if min(w, h) < SHOT_MIN or max(w, h) > SHOT_MAX:
            why.append(f"{w}x{h} is outside {SHOT_MIN}-{SHOT_MAX} px")
        if max(w, h) > 2 * min(w, h):
            why.append(f"{w}x{h}: the long side is more than twice the short side")
        if mode not in ("RGB", "L"):
            if fix and fmt == "PNG":
                with Image.open(p) as im:
                    flat = Image.new("RGB", im.size, (255, 255, 255))
                    rgba = im.convert("RGBA")
                    flat.paste(rgba, mask=rgba.getchannel("A"))
                flat.save(p, optimize=True)
                print(f"{p.name}: alpha removed")
            else:
                why.append(f"mode {mode} (alpha or palette; run with --fix)")
        if h > w and w * 16 == h * 9 and w >= 1080:
            portrait_916 += 1
        if why:
            bad += 1
            print(f"{p.name}: " + "; ".join(why))
        else:
            print(f"{p.name}: {w}x{h} ok")
    if portrait_916 < 4:
        print(f"only {portrait_916} portrait 9:16 shots of at least 1080x1920; "
              "SHOTS.md asks for at least 4 per language")
        bad += 1
    return 1 if bad else 0


# --------------------------------------------------------------- main


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--launcher", action="store_true",
                    help="also write the adaptive icon's foreground and monochrome layers")
    ap.add_argument("--verify", action="store_true", help="only check the committed files")
    ap.add_argument("--check-shots", type=Path, metavar="DIR",
                    help="check the screenshots in DIR against Play's rules")
    ap.add_argument("--fix", action="store_true",
                    help="with --check-shots: drop the alpha channel of PNG screenshots in place")
    args = ap.parse_args(argv)

    if args.check_shots:
        return check_shots(args.check_shots, args.fix)
    if not args.verify:
        icon = Image.open(APP_ICON)
        if icon.size != (1024, 1024):
            raise SystemExit(f"{APP_ICON} is {icon.size}, expected 1024x1024")
        foreground, monochrome = launcher_layers(icon)
        if args.launcher:
            foreground.save(FOREGROUND, optimize=True)
            monochrome.save(MONOCHROME, optimize=True)
            print(f"wrote {FOREGROUND.relative_to(ROOT)} and {MONOCHROME.relative_to(ROOT)}")
        GRAPHICS.mkdir(parents=True, exist_ok=True)
        store_icon(icon).save(STORE_ICON, optimize=True)
        print(f"wrote {STORE_ICON.relative_to(ROOT)}")
        for lang, path in FEATURE.items():
            feature_graphic(foreground, lang).save(path, optimize=True)
            print(f"wrote {path.relative_to(ROOT)}")
    problems = verify()
    for p in problems:
        print(f"FAIL: {p}")
    if not problems:
        print("ok: icon 512x512 RGBA <= 1024 KB; feature graphics 1024x500 RGB, no alpha")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
