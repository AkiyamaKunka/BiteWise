#!/usr/bin/env python3
"""Render the Chopstats README slides (1600 x 900) from deck.json.

    python3 render.py deck.json --lang en --out ../slides
    python3 render.py deck.json --lang zh --out ../zh/slides
    python3 render.py social.json --lang en --out .. --size 1280x640

Options: --only ID,ID  --jobs 3  --scale 2  --max-kb 600  --html-only
         --sheet PATH (contact sheet)  --build DIR (raw renders + Chrome
         profiles; default ./build, git-ignored)  --screens DIR (default
         ./screens, git-ignored)  --photos DIR (default ../photos)

The deck file is {"defaults": {...}, "slides": [...]}. Each slide holds the
fields both languages share (layout, geometry) plus an "en" and a "zh" block
whose keys replace the shared ones for that language. In any string,
"{lang}" becomes en or zh; a path that starts with "$screens/" or "$photos/"
resolves against --screens or --photos; other paths resolve against the
deck file's folder. Text fields are trusted HTML (<em> paints the accent,
<b> is bold, <br> breaks a line).

Every slide
  id        output name (01-hero -> 01-hero.png or .jpg)
  layout    hero | phone1 | phone2 | phone3 | steps | statement | free
  theme     light (default) | deep | clay | next
  eyebrow   small caps line with the three macro dots
  tags      [{"text", "kind": new | off | next}]   (pills before the eyebrow)
  headline, sub, points [..], chips [..]
  note      footer note ("Demo data")   footer true/false   footer_pos bottom|top
  footer_side left|right   ring true/false   frame "dashed"   style (extra CSS)
  format    png | jpg | auto (auto = PNG when it fits --max-kb, else JPEG)
Extras, on any layout (all positions in slide pixels):
  free_phones [{"src", "x", "y", "sw" (screen width), "r" (deg), "z",
                "hl": [[x, y, w, h], ..] (screenshot pixels: spotlight),
                "label"}]
  photos      [{"src", "x", "y", "w", "h", "r", "z", "pos" (object-position),
                "radius", "print": true (white border), "cap", "cap_top": true,
                "badge": true}]
  zooms       [{"src", "crop": [x, y, w, h] (screenshot pixels), "x", "y",
                "w" (card width), "r", "z", "label", "label_below": true}]
  tiles       {"x", "y", "w" (tile width), "gap", "items": [{"src" | "art",
                "pos", "status", "ok": true/false}]}
  nodes       [{"x", "y", "w", "h", "kind": ok|no|ghost|row, "icon",
                "title", "text", "pic", "pos", "list": [..]}]
  links       [{"d": SVG path in slide pixels, "class": dash|mute, "arrow"}]
  linklabels  [{"x", "y", "text"}]
  smallprint  [{"x", "y", "w", "text", "align"}]
  html        raw HTML appended last
Per layout
  hero      title, tagline, sub, chips, screens [front, left, right], icon
  phone1    screens [one], side right | left, callouts
  phone2    screens [two], labels, align center | left
  phone3    screens [centre, left, right]
  steps     steps [{"title", "text", "screen" | "stack": [photo, ..]}] x 3
  statement big, sub, facts [{"value", "label"}], center, namechips [..],
            chips [..], icon (app icon on top), title (name under the icon)
  free      copy_style (CSS for the text box), then the extras above

Chrome renders each slide at --scale and PIL downsamples with Lanczos, so
text stays crisp. JPEG is saved at q90 with 4:4:4 chroma (stepping down to
q82 only to fit --max-kb); PNG is optimized but never palette-reduced.
"""
from __future__ import annotations

import argparse
import copy
import html
import json
import os
import queue
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
CSS = HERE / "slides.css"
ICON = (HERE / "../../../app/assets/app_icon.png").resolve()
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

DOTS = '<span class="dots"><i></i><i></i><i></i></span>'
ARROW = ('<svg viewBox="0 0 24 24" fill="none" stroke-width="2.5" stroke-linecap="round" '
         'stroke-linejoin="round"><path d="M5 12h14M13 6l6 6-6 6"/></svg>')
CHECK = ('<svg viewBox="0 0 24 24" fill="none" stroke-width="3" stroke-linecap="round" '
         'stroke-linejoin="round"><path d="M5.5 12.5l4.2 4.2L18.5 8"/></svg>')
CROSS = ('<svg viewBox="0 0 24 24" fill="none" stroke-width="3" stroke-linecap="round">'
         '<path d="M7 7l10 10M17 7L7 17"/></svg>')

# Simple line icons drawn for these slides (no logos, no product art).
ICONS = {
    "glasses": '<svg viewBox="0 0 32 32"><rect x="3.5" y="11" width="10.5" height="8.5" rx="3.6"/>'
               '<rect x="18" y="11" width="10.5" height="8.5" rx="3.6"/><path d="M14 14.2c1.3-1.1 2.7-1.1 4 0"/>'
               '<path d="M3.5 13.2L1.5 11.6M28.5 13.2l2-1.6"/></svg>',
    "library": '<svg viewBox="0 0 32 32"><rect x="7" y="9" width="20" height="17" rx="3.5"/>'
               '<path d="M4.5 21.5V9.5A3.5 3.5 0 0 1 8 6h15"/><circle cx="13.5" cy="15" r="2"/>'
               '<path d="M7.5 24l6-5.5 4 3.5 3.5-3 5.5 5"/></svg>',
    "phone": '<svg viewBox="0 0 32 32"><rect x="9" y="3.5" width="14" height="25" rx="3.5"/>'
             '<path d="M14 7h4"/></svg>',
    "scan": '<svg viewBox="0 0 32 32"><path d="M5 10V7.5A2.5 2.5 0 0 1 7.5 5H10M22 5h2.5A2.5 2.5 0 0 1 27 7.5V10'
            'M27 22v2.5a2.5 2.5 0 0 1-2.5 2.5H22M10 27H7.5A2.5 2.5 0 0 1 5 24.5V22"/>'
            '<path d="M10.5 17.5c0-3.6 2.5-6 5.5-6s5.5 2.4 5.5 6z"/><path d="M9.5 17.5h13M16 11.5V9.8"/></svg>',
    "check": '<svg viewBox="0 0 32 32"><path d="M8 16.5l5.2 5.2L24.5 10.5"/></svg>',
    "cross": '<svg viewBox="0 0 32 32"><path d="M10 10l12 12M22 10L10 22"/></svg>',
    "cloud": '<svg viewBox="0 0 32 32"><path d="M10 24.5h13a5.5 5.5 0 0 0 .6-11A7.5 7.5 0 0 0 9.4 12 6.3 6.3 0 0 0 10 24.5z"/>'
             '<path d="M13.5 18.5l2.5 2.5 4-4.5"/></svg>',
    "server": '<svg viewBox="0 0 32 32"><rect x="6" y="6" width="20" height="8.5" rx="2.5"/>'
              '<rect x="6" y="17.5" width="20" height="8.5" rx="2.5"/><path d="M10.5 10.2h.1M10.5 21.7h.1"/>'
              '<path d="M4 28L28 4"/></svg>',
    "lock": '<svg viewBox="0 0 32 32"><rect x="7" y="14" width="18" height="13" rx="3"/>'
            '<path d="M11 14v-3.5a5 5 0 0 1 10 0V14"/><path d="M16 19.5v2.5"/></svg>',
    "stop": '<svg viewBox="0 0 32 32"><circle cx="16" cy="16" r="11"/><path d="M8.3 23.7L23.7 8.3"/></svg>',
}

# A non-food "photo": a flat park drawing, so the camera-roll strip can show
# a photo that is not a meal without using anyone's picture.
PARK = ('<svg viewBox="0 0 150 150" preserveAspectRatio="xMidYMid slice">'
        '<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#9CC9E8"/><stop offset="1" stop-color="#DCEEF7"/></linearGradient></defs>'
        '<rect width="150" height="150" fill="url(#sky)"/>'
        '<circle cx="112" cy="38" r="15" fill="#FBE7A6"/>'
        '<path d="M0 104 Q40 78 82 96 T150 88 V150 H0z" fill="#8DBF7A"/>'
        '<path d="M0 122 Q52 100 100 118 T150 112 V150 H0z" fill="#6FA862"/>'
        '<rect x="40" y="76" width="6" height="30" rx="2" fill="#7A5A44"/>'
        '<circle cx="43" cy="68" r="18" fill="#4E8F4F"/><circle cx="33" cy="76" r="11" fill="#5A9C58"/>'
        '<circle cx="54" cy="75" r="12" fill="#5A9C58"/>'
        '<path d="M86 132 Q104 120 126 132" stroke="#C9B48E" stroke-width="7" fill="none" stroke-linecap="round"/>'
        '</svg>')


class Ctx:
    def __init__(self, deck_dir: Path, html_dir: Path, screens: Path, photos: Path, lang: str):
        self.deck_dir, self.html_dir, self.screens, self.photos, self.lang = deck_dir, html_dir, screens, photos, lang

    def path(self, p: str) -> Path:
        p = p.replace("{lang}", self.lang)
        if p.startswith("$screens/"):
            path = self.screens / p[len("$screens/"):]
        elif p.startswith("$photos/"):
            path = self.photos / p[len("$photos/"):]
        else:
            path = Path(p) if Path(p).is_absolute() else self.deck_dir / p
        path = path.resolve()
        if not path.exists():
            raise SystemExit(f"missing image: {path}")
        return path

    def url(self, p: str | Path) -> str:
        path = self.path(p) if isinstance(p, str) else Path(p).resolve()
        return html.escape(os.path.relpath(path, self.html_dir))


@lru_cache(maxsize=None)
def img_size(path: Path) -> tuple[int, int]:
    with Image.open(path) as im:
        return im.size


def px(v) -> str:
    return f"{v:.1f}px" if isinstance(v, float) else f"{v}px"


def rot(r) -> str:
    return f"transform:rotate({r}deg);" if r else ""


# ------------------------------------------------------------------ pieces
def phone(c: Ctx, src: str, cls: str = "", label: str | None = None, style: str = "", hl=None) -> str:
    lab = f'<div class="label">{label}</div>' if label else ""
    hls = ""
    if hl:
        iw, ih = img_size(c.path(src))
        for x, y, w, h in hl:
            hls += (f'<div class="hl" style="left:{x / iw * 100:.3f}%;top:{y / ih * 100:.3f}%;'
                    f'width:{w / iw * 100:.3f}%;height:{h / ih * 100:.3f}%"></div>')
    st = f' style="{style}"' if style else ""
    return (f'<div class="phone {cls}"{st}><div class="screen"><img src="{c.url(src)}" alt="">'
            f'{hls}<div class="island"></div><div class="glare"></div></div>{lab}</div>')


def free_phones(c: Ctx, s: dict) -> str:
    out = []
    for p in s.get("free_phones", []):
        st = (f'left:{px(p["x"])};top:{px(p["y"])};--sw:{px(p.get("sw", 340))};'
              + rot(p.get("r")) + (f'z-index:{p["z"]};' if "z" in p else ""))
        out.append(phone(c, p["src"], "free", p.get("label"), st, p.get("hl")))
    return "".join(out)


def photos(c: Ctx, s: dict) -> str:
    out = []
    for p in s.get("photos", []):
        cls = "photo" + (" print" if p.get("print") else "")
        st = (f'left:{px(p["x"])};top:{px(p["y"])};width:{px(p["w"])};height:{px(p["h"])};'
              + rot(p.get("r")) + (f'z-index:{p["z"]};' if "z" in p else "")
              + (f'--pr:{px(p["radius"])};' if "radius" in p else ""))
        cap = (f'<span class="cap{" top" if p.get("cap_top") else ""}"><i></i>{p["cap"]}</span>'
               if p.get("cap") else "")
        badge = f'<span class="badge">{CHECK}</span>' if p.get("badge") else ""
        pos = p.get("pos", "50% 50%")
        out.append(f'<div class="{cls}" style="{st}"><img src="{c.url(p["src"])}" alt="" '
                   f'style="object-position:{pos}">{cap}{badge}</div>')
    return "".join(out)


def zoom_box(c: Ctx, src: str, crop, w: float) -> str:
    iw, ih = img_size(c.path(src))
    x, y, cw, ch = crop
    k = w / cw
    return (f'<div class="zbox" style="width:{px(float(w))};height:{px(ch * k)}">'
            f'<img src="{c.url(src)}" alt="" style="left:{px(-x * k)};top:{px(-y * k)};'
            f'width:{px(iw * k)};height:{px(ih * k)}"></div>')


def zooms(c: Ctx, s: dict) -> str:
    out = []
    for z in s.get("zooms", []):
        st = f'left:{px(z["x"])};top:{px(z["y"])};' + rot(z.get("r")) + (f'z-index:{z["z"]};' if "z" in z else "")
        lab = f'<div class="zlabel"><i></i>{z["label"]}</div>' if z.get("label") else ""
        box = zoom_box(c, z["src"], z["crop"], z["w"])
        cls = "zoom lab-below" if z.get("label_below") else "zoom"
        out.append(f'<div class="{cls}" style="{st}">' + (box + lab if z.get("label_below") else lab + box) + "</div>")
    return "".join(out)


def tiles(c: Ctx, s: dict) -> str:
    t = s.get("tiles")
    if not t:
        return ""
    items = []
    for it in t["items"]:
        if it.get("art") == "park":
            pic = PARK
        else:
            pic = f'<img src="{c.url(it["src"])}" alt="" style="object-position:{it.get("pos", "50% 50%")}">'
        ok = it.get("ok", True)
        st = f'<div class="st {"ok" if ok else "no"}"><i>{CHECK if ok else CROSS}</i><span>{it["status"]}</span></div>'
        items.append(f'<div class="tile"><div class="pic">{pic}</div>{st}</div>')
    style = f'left:{px(t["x"])};top:{px(t["y"])};--tw:{px(t.get("w", 150))};gap:{px(t.get("gap", 18))}'
    return f'<div class="tiles" style="{style}">{"".join(items)}</div>'


def nodes(c: Ctx, s: dict) -> str:
    out = []
    for n in s.get("nodes", []):
        kind = n.get("kind", "")
        st = f'left:{px(n["x"])};top:{px(n["y"])};width:{px(n["w"])};' + (f'height:{px(n["h"])};' if "h" in n else "")
        pic = (f'<div class="pic"><img src="{c.url(n["pic"])}" alt="" style="object-position:{n.get("pos", "50% 50%")}"></div>'
               if n.get("pic") else "")
        ico = f'<div class="ico">{ICONS[n["icon"]]}</div>' if n.get("icon") else ""
        body = (f'<h4>{n["title"]}</h4>' if n.get("title") else "") + (f'<p>{n["text"]}</p>' if n.get("text") else "")
        if n.get("list"):
            body += "<ul>" + "".join(f"<li>{li}</li>" for li in n["list"]) + "</ul>"
        if "row" in kind.split():
            body = f"<div>{body}</div>"
        out.append(f'<div class="node {kind}" style="{st}">{pic}{ico}{body}</div>')
    return "".join(out)


def links(s: dict) -> str:
    ls = s.get("links", [])
    labels = "".join(f'<div class="linklabel" style="left:{px(l["x"])};top:{px(l["y"])}">{l["text"]}</div>'
                     for l in s.get("linklabels", []))
    if not ls:
        return labels
    paths = []
    for i, l in enumerate(ls):
        cls = l.get("class", "")
        end = ' marker-end="url(#ah)"' if l.get("arrow", True) else ""
        if "mute" in cls.split():
            end = ' marker-end="url(#ahm)"' if l.get("arrow", True) else ""
        paths.append(f'<path class="{cls}" d="{l["d"]}"{end}/>')
    defs = ('<defs><marker id="ah" viewBox="0 0 12 12" refX="7" refY="6" markerWidth="12" markerHeight="12" '
            'markerUnits="userSpaceOnUse" orient="auto"><path d="M1.5 1.5L8.5 6 1.5 10.5" style="fill:none;'
            'stroke:var(--accent);stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round"/></marker>'
            '<marker id="ahm" viewBox="0 0 12 12" refX="7" refY="6" markerWidth="12" markerHeight="12" '
            'markerUnits="userSpaceOnUse" orient="auto"><path d="M1.5 1.5L8.5 6 1.5 10.5" style="fill:none;'
            'stroke:var(--fg-3);stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round"/></marker></defs>')
    return f'<svg class="links" viewBox="0 0 1600 900">{defs}{"".join(paths)}</svg>' + labels


def smallprint(s: dict) -> str:
    out = []
    for p in s.get("smallprint", []):
        st = f'left:{px(p["x"])};top:{px(p["y"])};width:{px(p.get("w", 700))};text-align:{p.get("align", "left")}'
        out.append(f'<div class="smallprint" style="{st}">{p["text"]}</div>')
    return "".join(out)


def extras(c: Ctx, s: dict) -> str:
    return (photos(c, s) + free_phones(c, s) + tiles(c, s) + links(s) + nodes(c, s) + zooms(c, s)
            + smallprint(s) + s.get("html", ""))


def kicker(s: dict) -> str:
    parts = [f'<span class="tag k-{t.get("kind", "new")}">{t["text"]}</span>' for t in s.get("tags", [])]
    if s.get("eyebrow"):
        parts.append(f'<span class="eyebrow">{DOTS}{s["eyebrow"]}</span>')
    return f'<div class="kicker">{"".join(parts)}</div>' if parts else ""


def chips(s: dict) -> str:
    if not s.get("chips"):
        return ""
    return '<div class="chips">' + "".join(f'<span class="chip"><i></i>{c}</span>' for c in s["chips"]) + "</div>"


def text_block(s: dict) -> str:
    out = [kicker(s)]
    if s.get("headline"):
        out.append(f'<h1 class="headline">{s["headline"]}</h1>')
    if s.get("sub"):
        out.append(f'<p class="sub">{s["sub"]}</p>')
    if s.get("points"):
        out.append('<ul class="points">' + "".join(f"<li><span>{p}</span></li>" for p in s["points"]) + "</ul>")
    out.append(chips(s))
    return "".join(out)


def ring(s: dict) -> str:
    return '<div class="ring track"></div><div class="ring"></div>' if s.get("ring", True) else ""


def footer(c: Ctx, s: dict, default_on: bool, side: str = "left", pos: str = "bottom") -> str:
    if not s.get("footer", default_on):
        return ""
    brand = s.get("brand", "Chopstats <span>· 筷拍</span>")
    note = s.get("note")
    note_html = f'<span class="sep"></span><span class="note">{note}</span>' if note else ""
    cls = "footer right" if s.get("footer_side", side) == "right" else "footer"
    if s.get("footer_pos", pos) == "top":
        cls += " top"
    return f'<div class="{cls}"><span class="brand"><img src="{c.url(ICON)}" alt="">{brand}</span>{note_html}</div>'


def callouts(s: dict) -> str:
    return "".join(f'<div class="callout" style="left:{px(o["x"])};top:{px(o["y"])}"><i class="{o.get("dot", "")}"></i>{o["text"]}</div>'
                   for o in s.get("callouts", []))


def need(c: Ctx, s: dict, n: int) -> list[str]:
    srcs = s.get("screens", [])
    if len(srcs) < n:
        raise SystemExit(f'slide {s["id"]}: layout {s["layout"]} needs {n} screens, got {len(srcs)}')
    return srcs[:n]


def body_for(c: Ctx, s: dict) -> tuple[str, str]:
    lay = s["layout"]
    if lay == "hero":
        cls_for = ["p0", "p1", "p2"]
        stage = "".join(phone(c, src, cls_for[i]) for i, src in enumerate(s.get("screens", [])[:3]))
        ic = f'<img class="appicon" src="{c.url(ICON)}" alt="">' if s.get("icon", True) else ""
        title = s.get("title", "Chopstats <span>· 筷拍</span>")
        copy_ = (f'<div class="copy">{ic}{kicker(s)}<div class="title">{title}</div>'
                 + (f'<div class="tagline">{s["tagline"]}</div>' if s.get("tagline") else "")
                 + (f'<p class="sub">{s["sub"]}</p>' if s.get("sub") else "") + chips(s) + "</div>")
        return "", ring(s) + copy_ + (f'<div class="stage">{stage}</div>' if stage else "") + footer(c, s, False)
    if lay == "phone1":
        side = s.get("side", "right")
        (src,) = need(c, s, 1)
        return (f"side-{side}", ring(s) + f'<div class="copy">{text_block(s)}</div>' + phone(c, src, "p0", hl=s.get("hl"))
                + footer(c, s, True, "left" if side == "right" else "right"))
    if lay == "phone2":
        align = s.get("align", "center")
        labels = s.get("labels", [None, None])
        phones = "".join(phone(c, src, f"p{i}", labels[i] if i < len(labels) else None)
                         for i, src in enumerate(need(c, s, 2)))
        return (f"align-{align}", ring(s) + f'<div class="copy">{text_block(s)}</div>' + phones
                + footer(c, s, True, "left", "top" if align == "center" else "bottom"))
    if lay == "phone3":
        phones = "".join(phone(c, src, f"p{i}") for i, src in enumerate(need(c, s, 3)))
        return "", ring(s) + f'<div class="copy">{text_block(s)}</div>' + phones + footer(c, s, True, "left", "top")
    if lay == "steps":
        steps = s.get("steps", [])
        if len(steps) != 3:
            raise SystemExit(f'slide {s["id"]}: steps needs exactly 3 steps')
        with_pics = all(st.get("screen") or st.get("stack") for st in steps)
        cols = []
        for i, st in enumerate(steps):
            meta = (f'<div class="meta"><div class="num">{i + 1}</div><h3>{st["title"]}</h3>'
                    + (f'<p>{st["text"]}</p>' if st.get("text") else "") + "</div>")
            if st.get("stack"):
                pics = "".join(photos(c, {"photos": [p]}) for p in st["stack"])
                vis = f'<div class="stack">{pics}</div>'
            elif st.get("screen"):
                vis = phone(c, st["screen"], hl=st.get("hl"))
            else:
                vis = ""
            cols.append(f'<div class="step">{meta}{vis}</div>')
            if i < 2:
                cols.append(f'<div class="arrow"><span>{ARROW}</span></div>')
        copy_ = f'<div class="copy">{kicker(s)}' + (f'<h1 class="headline">{s["headline"]}</h1>' if s.get("headline") else "") + "</div>"
        return (("" if with_pics else "cards"), copy_ + f'<div class="row">{"".join(cols)}</div>'
                + footer(c, s, True, "left", "top" if with_pics else "bottom"))
    if lay == "statement":
        facts = s.get("facts", [])
        facts_html = ('<div class="facts">' + "".join(
            f'<div class="fact"><b>{f["value"]}</b><span>{f["label"]}</span></div>' for f in facts) + "</div>") if facts else ""
        names = ('<div class="namechips">' + "".join(f"<span>{n}</span>" for n in s["namechips"]) + "</div>") if s.get("namechips") else ""
        head = (f'<img class="gicon" src="{c.url(ICON)}" alt="">' if s.get("icon") else "") + (
            f'<div class="gname">{s["title"]}</div>' if s.get("title") else "")
        copy_ = (f'<div class="copy">{head}{kicker(s)}<h1 class="big">{s.get("big", s.get("headline", ""))}</h1>'
                 + (f'<p class="sub">{s["sub"]}</p>' if s.get("sub") else "") + names + facts_html + chips(s) + "</div>")
        return ("center" if s.get("center") else ""), ring(s) + copy_ + footer(c, s, True)
    if lay == "free":
        copy_ = f'<div class="copy" style="{s.get("copy_style", "")}">{text_block(s)}</div>'
        return "", ring(s) + copy_ + footer(c, s, True, s.get("footer_side", "left"), s.get("footer_pos", "bottom"))
    raise SystemExit(f'slide {s.get("id")}: unknown layout {lay!r}')


def page(c: Ctx, s: dict, size: tuple[int, int]) -> str:
    extra, inner = body_for(c, s)
    lang = "zh-Hans" if c.lang == "zh" else "en"
    theme = s.get("theme", "light")
    frame = " frame-dashed" if s.get("frame") == "dashed" else ""
    w, h = size
    dims = f"<style>html,body,.slide{{width:{w}px;height:{h}px}}</style>" if (w, h) != (1600, 900) else ""
    style = f"<style>{s['style']}</style>" if s.get("style") else ""
    return (f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width={w}"><title>{s["id"]}</title>'
            f'<link rel="stylesheet" href="{c.url(CSS)}">{dims}{style}</head>'
            f'<body><main class="slide t-{theme} l-{s["layout"]} {extra}{frame}">{inner}{extras(c, s)}{callouts(s)}</main></body></html>')


# ------------------------------------------------------------------ render
def shoot(html_path: Path, png_path: Path, scale: float, profile: Path, size: tuple[int, int], timeout: float = 60.0) -> None:
    """Chrome writes the screenshot and then may linger, so wait for the file and stop it."""
    if png_path.exists():
        png_path.unlink()
    profile.mkdir(parents=True, exist_ok=True)
    cmd = [CHROME, "--headless=new", f"--user-data-dir={profile}", "--hide-scrollbars",
           "--no-first-run", "--no-default-browser-check", "--disable-extensions",
           "--allow-file-access-from-files", f"--force-device-scale-factor={scale}",
           f"--window-size={size[0]},{size[1]}", "--virtual-time-budget=3000",
           f"--screenshot={png_path}", html_path.as_uri()]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0, last = time.time(), -1
    try:
        while time.time() - t0 < timeout:
            if png_path.exists():
                sz = png_path.stat().st_size
                if sz > 0 and sz == last:
                    try:
                        with Image.open(png_path) as im:
                            im.load()
                        return
                    except Exception:
                        pass
                last = sz
            if proc.poll() is not None and not png_path.exists():
                raise RuntimeError(f"chrome exited {proc.returncode} without a screenshot for {html_path.name}")
            time.sleep(0.3)
        raise RuntimeError(f"timed out rendering {html_path.name}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()


def optimize(raw: Path, out_base: Path, size: tuple[int, int], fmt: str, max_kb: int) -> tuple[Path, str, int]:
    with Image.open(raw) as im:
        img = im.convert("RGB")
    if img.size != size:
        img = img.resize(size, Image.Resampling.LANCZOS)
    for old in (out_base.with_suffix(".png"), out_base.with_suffix(".jpg")):
        if old.exists():
            old.unlink()
    limit = max_kb * 1024
    if fmt != "jpg":
        p = out_base.with_suffix(".png")
        img.save(p, "PNG", optimize=True)
        n = p.stat().st_size
        if fmt == "png" or n <= limit:
            return p, "png", n
        p.unlink()
    j = out_base.with_suffix(".jpg")
    q = 90
    for q in (90, 88, 85, 82):   # q90 is the target; step down only to fit --max-kb
        img.save(j, "JPEG", quality=q, subsampling=0, optimize=True, progressive=True)
        if j.stat().st_size <= limit:
            break
    return j, f"jpg q{q}", j.stat().st_size


def contact_sheet(paths: list[Path], dest: Path) -> None:
    thumbs = []
    for p in paths:
        with Image.open(p) as im:
            thumbs.append(im.convert("RGB").resize((800, int(800 * im.height / im.width)), Image.Resampling.LANCZOS))
    cols = 2
    rows = (len(thumbs) + cols - 1) // cols
    th = max(t.height for t in thumbs)
    sheet = Image.new("RGB", (cols * 800 + (cols + 1) * 20, rows * th + (rows + 1) * 20), (60, 60, 60))
    for i, t in enumerate(thumbs):
        r, col = divmod(i, cols)
        sheet.paste(t, (20 + col * 820, 20 + r * (th + 20)))
    sheet.save(dest, "JPEG", quality=88)


def merge_lang(s: dict, lang: str) -> dict:
    out = {k: copy.deepcopy(v) for k, v in s.items() if k not in ("en", "zh")}
    out.update(copy.deepcopy(s.get(lang, {})))
    out["lang"] = lang
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("deck", type=Path)
    ap.add_argument("--lang", default="en", choices=["en", "zh"])
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--scale", type=float, default=2.0)
    ap.add_argument("--size", default="1600x900")
    ap.add_argument("--max-kb", type=int, default=600)
    ap.add_argument("--format", default="", choices=["", "auto", "png", "jpg"], help="override every slide's format")
    ap.add_argument("--html-only", action="store_true")
    ap.add_argument("--sheet", type=Path, default=None)
    ap.add_argument("--build", type=Path, default=HERE / "build")
    ap.add_argument("--screens", type=Path, default=HERE / "screens")
    ap.add_argument("--photos", type=Path, default=HERE / "../photos")
    a = ap.parse_args()
    size = tuple(int(v) for v in a.size.lower().split("x"))

    spec = json.loads(a.deck.read_text())
    defaults = spec.get("defaults", {})
    slides = [merge_lang({**defaults, **s, **{k: {**defaults.get(k, {}), **s.get(k, {})} for k in ("en", "zh")}}, a.lang)
              for s in spec["slides"]]
    if a.only:
        keep = set(a.only.split(","))
        slides = [s for s in slides if s["id"] in keep]
    deck_dir = a.deck.resolve().parent
    html_dir = (HERE / "html" / a.lang).resolve()
    html_dir.mkdir(parents=True, exist_ok=True)
    c = Ctx(deck_dir, html_dir, a.screens.resolve(), a.photos.resolve(), a.lang)
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    jobs = []
    for s in slides:
        h = html_dir / f'{s["id"]}.html'
        h.write_text(page(c, s, size), encoding="utf-8")
        jobs.append((s, h))
    if a.html_only:
        for _, h in jobs:
            print(h)
        return

    build = a.build.resolve()
    profiles: queue.Queue = queue.Queue()
    for i in range(max(1, a.jobs)):
        profiles.put(build / f"chrome-profile-{i}")

    def run(job):
        s, h = job
        raw = build / "raw" / a.lang / f'{s["id"]}.png'
        raw.parent.mkdir(parents=True, exist_ok=True)
        prof = profiles.get()
        try:
            shoot(h, raw, a.scale, prof, size)
        finally:
            profiles.put(prof)
        return optimize(raw, out / s["id"], size, a.format or s.get("format", "auto"), a.max_kb)

    results = []
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for (path, kind, n) in ex.map(run, jobs):
            results.append(path)
            flag = "" if n <= a.max_kb * 1024 else "  OVER LIMIT"
            print(f"{path.name}  {kind}  {n / 1024:.0f} KB{flag}")
    if a.sheet:
        contact_sheet(results, a.sheet)
        print(f"sheet: {a.sheet}")


if __name__ == "__main__":
    main()
