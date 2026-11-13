#!/usr/bin/env python3
"""Render the captioned App Store screenshots (1320 x 2868) from frames.json.

    python3 render_store.py [--lang en,zh] [--only 01,05] [--out DIR]
                            [--build DIR] [--jobs 3] [--medium]
                            [--html-only] [--no-sheets]

Pipeline, per frame and language:
  1. Each picture (a crop of a real capture in screens/, or the photo in
     photos/) is cut and resized with Lanczos to exactly the device pixels it
     will fill, so Chrome never resamples it. The captures themselves are
     never modified.
  2. An HTML page (store.css + inline layout) is written to the build folder.
  3. Headless Chrome renders it at device scale 2 (2640 x 5736) with a fresh
     --user-data-dir inside the build folder (never the owner's profile; the
     script refuses any path inside ~/Library/Application Support/Google/Chrome).
     The page script fits the headline, places the picture zone and the label
     chips, and logs a REPORT line; any layout error fails the run.
  4. PIL reduces the render to 1320 x 2868 with Lanczos and writes an RGB PNG
     (no alpha, sRGB profile embedded).
  5. Checks: exact size, mode RGB, no alpha (PIL and `sips -g hasAlpha`), file
     size under 8 MB, and a banned-word scan of every caption, sub-line, pill,
     chip, tag and check row (rules in README.md).
  6. Contact sheets go to the build folder (never into the repo).

--medium also writes 1206 x 2622 copies (the "iPhone with Dynamic Island,
medium display" class) to <out>/../screenshots-marketing-medium/<locale>/.

Text fields in frames.json are trusted HTML: <em> paints the accent colour.
Coordinates of rings, touch points and chips are in SOURCE pixels of the
capture (1320 x 2868), so they survive a change of scale.
"""
from __future__ import annotations

import argparse
import html
import io
import json
import queue
import re
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageCms

HERE = Path(__file__).resolve().parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1320, 2868
DPR = 2                      # Chrome device scale factor
CONTENT_W = 1144             # W - 2 * 88 px safe side margin
FULL = CONTENT_W / W         # scale of a full-width slice (0.8667)
LOCALES = {"en": "en-US", "zh": "zh-Hans"}
MAX_BYTES = 8 * 1024 * 1024
FORBIDDEN_PROFILE = Path.home() / "Library" / "Application Support" / "Google" / "Chrome"

CHEVRON = ('<svg viewBox="0 0 24 24" fill="none" stroke-width="2.6" stroke-linecap="round" '
           'stroke-linejoin="round"><path d="M6 9.5l6 6 6-6"/></svg>')

# ---------------------------------------------------------------- copy rules
# Words that must never appear in added text (captions, sub-lines, pills,
# chips, tags, check rows). See README.md "Rules this set follows". Matching is
# case-insensitive; ALLOW lists exact phrases that are fine in context.
BANNED_EN = [
    r"\bfree\b", r"subscription", r"in-app", r"purchase", r"\bprice", r"\$", r"\bcost",
    r"\bbest\b", r"#\s?1\b", r"number one", r"\bfirst\b", r"\bonly\b", r"\bunique\b",
    r"accura", r"precis", r"\binstant", r"in seconds", r"\brating", r"\breview", r"\busers?\b",
    r"\baward", r"\bpress\b", r"android", r"\bapk\b", r"google", r"github", r"https?:", r"www\.",
    r"\.com\b", r"data not collected", r"nothing leaves", r"offline", r"encrypt", r"\bmeta\b",
    r"glasses", r"apple", r"health ?kit", r"\bwatch\b", r"widget", r"barcode", r"lose weight",
    r"weight[- ]loss", r"iphone", r"icloud", r"new in", r"gemini", r"openai", r"anthropic",
    r"claude", r"grok", r"\bxai\b", r"openrouter", r"deepseek", r"qwen", r"doubao", r"\bglm\b",
    r"chipotle", r"chatgpt", r"\bgpt\b",
]
BANNED_ZH = [
    r"免费", r"订阅", r"内购", r"购买", r"价格", r"最好", r"最佳", r"第一", r"唯一", r"首个", r"首款",
    r"准确", r"精准", r"精确", r"立即", r"秒", r"评分", r"好评", r"用户数", r"奖", r"安卓", r"android",
    r"\bapk\b", r"google", r"github", r"https?:", r"www\.", r"\.com", r"离线", r"加密", r"\bmeta\b",
    r"眼镜", r"健康", r"手表", r"小组件", r"条形码", r"减肥", r"瘦", r"新增", r"icloud", r"iphone",
    r"gemini", r"openai", r"anthropic", r"claude", r"grok", r"deepseek", r"qwen", r"doubao", r"\bglm\b",
    r"chipotle", r"大陆", r"vpn", r"深度求索", r"通义", r"豆包", r"智谱",
]
ALLOW = [
    "only on this phone",   # the app's own wording for where the key is stored
    "asks first",           # "first" in time (it asks before sending), not a ranking claim
]


def banned_hits(text: str, lang: str) -> list[str]:
    plain = re.sub(r"<[^>]+>", "", text).lower()
    for phrase in ALLOW:
        plain = plain.replace(phrase, " ")
    pats = BANNED_ZH if lang == "zh" else BANNED_EN
    return [p for p in pats if re.search(p, plain, flags=re.I)]


# ---------------------------------------------------------------- spec helpers
def merged(defaults: dict, frame: dict, lang: str) -> dict:
    spec = {**defaults, **{k: v for k, v in frame.items() if k not in ("en", "zh")}}
    spec.update(frame[lang])
    spec["lang"] = lang
    # One picture top per locale (defaults.stage_top_by_lang), so frames
    # line up side by side; a frame may still set its own stage_top.
    by_lang = spec.get("stage_top_by_lang") or {}
    if spec.get("stage_top") is None and lang in by_lang:
        spec["stage_top"] = by_lang[lang]
    return spec


def r2(v: float) -> float:
    """Round a CSS length to whole device pixels (half CSS pixels at 2x)."""
    return round(v * DPR) / DPR


def prepare_image(src: Path, crop: list[int], css_w: float, css_h: float, dest: Path) -> tuple[float, float]:
    """Crop `src` and resize it with Lanczos to exactly the device pixels of
    a css_w x css_h box. Returns the CSS size actually used."""
    dw, dh = round(css_w * DPR), round(css_h * DPR)
    with Image.open(src) as im:
        icc = im.info.get("icc_profile")
        img = im.convert("RGB")
        if icc:
            prof = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            if "srgb" not in ImageCms.getProfileDescription(prof).lower().replace(" ", ""):
                img = ImageCms.profileToProfile(img, prof, ImageCms.createProfile("sRGB"), outputMode="RGB")
    x0, y0, x1, y1 = crop
    if not (0 <= x0 < x1 <= img.width and 0 <= y0 < y1 <= img.height):
        raise SystemExit(f"crop {crop} is outside {src.name} ({img.width}x{img.height})")
    part = img.crop((x0, y0, x1, y1))
    part = part.resize((dw, dh), Image.Resampling.LANCZOS)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part.save(dest, "PNG", compress_level=1)
    return dw / DPR, dh / DPR


# ---------------------------------------------------------------- layout
class Layout:
    """Stacks the stage items top to bottom and emits their HTML."""

    def __init__(self, spec: dict, build: Path, key: str):
        self.spec, self.build, self.key = spec, build, key
        self.html: list[str] = []
        self.texts: list[tuple[str, str]] = []      # (where, text) for the banned-word scan
        self.y = 0.0
        self.n = 0

    def asset(self, item: dict) -> Path:
        self.n += 1
        return self.build / "assets" / f"{self.key}_{self.n}.png"

    def place_x(self, item: dict, w: float) -> float:
        return r2(item["x"]) if "x" in item else r2((W - w) / 2)

    def add(self, item: dict) -> None:
        t = item["type"]
        if t == "gap":
            self.y += item["h"]
        elif t == "connector":
            h = item.get("h", 104)
            cy = self.y + h / 2
            self.html.append(f'<div class="connector" style="left:{W / 2 - 60}px;top:{r2(cy - 60)}px">{CHEVRON}</div>')
            self.y += h
        elif t == "photo":
            self.photo(item)
        elif t == "screen":
            self.screen(item)
        elif t == "checks":
            self.checks(item)
        else:
            raise SystemExit(f"{self.key}: unknown stage item type {t!r}")

    def photo(self, item: dict) -> None:
        x0, y0, x1, y1 = item["crop"]
        w = item.get("width", CONTENT_W)
        h = w * (y1 - y0) / (x1 - x0)
        dest = self.asset(item)
        w, h = prepare_image(HERE / item["src"], item["crop"], w, h, dest)
        x, y = self.place_x(item, w), r2(self.y)
        rad = item.get("radius", 56)
        self.html.append(f'<div class="photo" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;'
                         f'border-radius:{rad}px"><img src="{dest.as_uri()}" alt=""></div>')
        self.y = y + h

    def screen(self, item: dict) -> None:
        x0, y0, x1, y1 = item["crop"]
        s = item.get("scale", FULL)
        w, h = (x1 - x0) * s, (y1 - y0) * s
        dest = self.asset(item)
        w, h = prepare_image(HERE / item["src"], item["crop"], w, h, dest)
        s = w / (x1 - x0)                     # the scale actually used after rounding
        x, y = self.place_x(item, w), r2(self.y)
        rad = item.get("radius", round(56 * s, 1))   # 56 px at full width, scaled with the card
        self.html.append(f'<div class="card" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;'
                         f'border-radius:{rad}px"><img src="{dest.as_uri()}" alt=""></div>')

        def pt(sx: float, sy: float) -> tuple[float, float]:
            return x + (sx - x0) * s, y + (sy - y0) * s

        if item.get("tag"):
            tag = item["tag"]
            self.texts.append(("tag", tag))
            self.html.append(f'<div class="tag" data-anchor="{x + 40},{y}" data-mode="tag"><i></i>{tag}</div>')
        for ring in item.get("rings", []):
            bx0, by0, bx1, by1 = ring["box"]
            pad = ring.get("pad", 14)          # number, [vertical, horizontal] or [top, right, bottom, left]
            if isinstance(pad, (int, float)):
                pt_, pr, pb, pl = pad, pad, pad, pad
            elif len(pad) == 2:
                pt_, pr, pb, pl = pad[0], pad[1], pad[0], pad[1]
            else:
                pt_, pr, pb, pl = pad
            (ax, ay), (bx, by) = pt(bx0 - pl, by0 - pt_), pt(bx1 + pr, by1 + pb)
            if not (x0 <= bx0 - pl and bx1 + pr <= x1 and y0 <= by0 - pt_ and by1 + pb <= y1):
                raise SystemExit(f"{self.key}: ring {ring['box']} (+{pad}) leaves the crop {item['crop']}")
            self.html.append(f'<div class="hl" style="left:{r2(ax - 6)}px;top:{r2(ay - 6)}px;'
                             f'width:{r2(bx - ax + 12)}px;height:{r2(by - ay + 12)}px"></div>')
            chip = ring.get("chip")
            if chip:
                self.texts.append(("chip", chip["text"]))
                if "at" in chip:          # explicit centre, in source pixels
                    cx, cy = pt(*chip["at"])
                    data = f'data-mode="at" data-anchor="{cx},{cy}"'
                else:
                    data = (f'data-mode="ring" data-box="{ax - 6},{ay - 6},{bx + 6},{by + 6}" '
                            f'data-pos="{chip.get("pos", "above")}" data-align="{chip.get("align", "center")}"')
                data += f' data-dx="{chip.get("dx", 0)}" data-dy="{chip.get("dy", 0)}"'
                dot = chip.get("dot", "")
                self.html.append(f'<div class="chip" {data}><i class="{dot}"></i>{chip["text"]}</div>')
        for tx, ty in item.get("touches", []):
            cx, cy = pt(tx, ty)
            if not (x0 <= tx <= x1 and y0 <= ty <= y1):
                raise SystemExit(f"{self.key}: touch point {(tx, ty)} is outside the crop {item['crop']}")
            self.html.append(f'<div class="touch" style="left:{r2(cx - 60)}px;top:{r2(cy - 60)}px"></div>')
        for chip in item.get("chips", []):        # free-standing label, centred on a source point
            self.texts.append(("chip", chip["text"]))
            cx, cy = pt(*chip["at"])
            dot = chip.get("dot", "")
            self.html.append(f'<div class="chip" data-mode="at" data-anchor="{cx},{cy}" '
                             f'data-dx="{chip.get("dx", 0)}" data-dy="{chip.get("dy", 0)}"><i class="{dot}"></i>{chip["text"]}</div>')
        self.y = y + h

    def checks(self, item: dict) -> None:
        w = item.get("width", CONTENT_W)
        rows = item["rows"]
        for r in rows:
            self.texts.append(("check", r))
        x, y = self.place_x(item, w), r2(self.y)
        est = item["h"]                     # declared height; the page script verifies it
        body = "".join(f'<div class="row">{r}</div>' for r in rows)
        self.html.append(f'<div class="checks" data-declared-h="{est}" style="left:{x}px;top:{y}px;width:{w}px">{body}</div>')
        self.y = y + est


def deco_html(spec: dict, stage_h: float) -> str:
    d = spec.get("deco")
    if not d:
        return ""
    dia, t = d.get("d", 1500), d.get("t", 70)
    cx = W * d.get("cx", 0.5) + d.get("dx", 0)
    cy = stage_h * d.get("cy", 0.5) + d.get("dy", 0)
    style = f"width:{dia}px;height:{dia}px;left:{cx - dia / 2}px;top:{cy - dia / 2}px;--t:{t}px;--rot:{d.get('rot', 0)}deg"
    return f'<div class="deco track" style="{style}"></div><div class="deco" style="{style}"></div>'


PAGE_JS = r"""
(function () {
  const R = {errors: []};
  const S = window.__SPEC__;
  const copy = document.querySelector('.copy');
  const hl = document.querySelector('.headline');
  const lines = [...hl.querySelectorAll('.ln')];
  let px = S.head[0];
  const fits = () => lines.every(l => l.getBoundingClientRect().width <= S.maxw + 0.5);
  hl.style.fontSize = px + 'px';
  while (!fits() && px > S.head[1]) { px -= 2; hl.style.fontSize = px + 'px'; }
  R.headline_px = px;
  R.line_widths = lines.map(l => Math.round(l.getBoundingClientRect().width));
  if (!fits()) R.errors.push('headline does not fit at ' + px + ' px');
  const sub = document.querySelector('.sub');
  if (sub) {
    const lh = parseFloat(getComputedStyle(sub).lineHeight);
    R.sub_lines = Math.round(sub.getBoundingClientRect().height / lh);
    if (R.sub_lines > 2) R.errors.push('sub-line runs to ' + R.sub_lines + ' lines');
    if (R.sub_lines !== S.sub_n) R.errors.push('sub-line wraps: ' + R.sub_lines + ' lines for ' + S.sub_n + ' explicit');
  }
  const pill = document.querySelector('.pill');
  if (pill) {
    const pr = pill.getBoundingClientRect();
    R.pill_top = Math.round(pr.top);
    if (pr.top < 60) R.errors.push('pill is within 60 px of the top edge');
  }
  const cb = copy.getBoundingClientRect();
  R.caption_bottom = Math.round(cb.bottom);
  if (cb.bottom > S.H / 3 + 1) R.errors.push('caption leaves the top third (' + Math.round(cb.bottom) + ' px)');
  const stage = document.querySelector('.stage');
  const zoneTop = cb.bottom + S.gap, zoneBottom = S.H - S.bottom;
  const room = zoneBottom - zoneTop;
  if (S.stage_h > room + 0.5) R.errors.push('stage is ' + Math.round(S.stage_h - room) + ' px too tall');
  let top = S.stage_top != null ? S.stage_top : zoneTop + Math.max(0, room - S.stage_h) * S.align;
  top = Math.round(top);
  stage.style.top = top + 'px';
  R.stage_top = top; R.stage_bottom = Math.round(top + S.stage_h); R.zone = [Math.round(zoneTop), Math.round(zoneBottom)];
  if (top < zoneTop - 0.5) R.errors.push('stage overlaps the caption');
  // checks rows: declared height must hold the rows
  document.querySelectorAll('.checks').forEach(c => {
    const real = c.getBoundingClientRect().height, dec = parseFloat(c.dataset.declaredH);
    if (real > dec + 1) R.errors.push('check rows need ' + Math.round(real) + ' px, declared ' + dec);
  });
  // chips and tags
  const placed = [];
  document.querySelectorAll('.chip, .tag').forEach(el => {
    const r = el.getBoundingClientRect(); const w = r.width, h = r.height;
    let x, y;
    const dx = parseFloat(el.dataset.dx || 0), dy = parseFloat(el.dataset.dy || 0);
    if (el.dataset.mode === 'tag') {
      const [ax, ay] = el.dataset.anchor.split(',').map(Number);
      x = ax; y = ay - h / 2;
    } else if (el.dataset.mode === 'at') {
      const [cx, cy] = el.dataset.anchor.split(',').map(Number);
      x = cx - w / 2; y = cy - h / 2;
    } else {
      const [x0, y0, x1, y1] = el.dataset.box.split(',').map(Number);
      const pos = el.dataset.pos, al = el.dataset.align, g = 14;
      const hx = al === 'start' ? x0 + 18 : al === 'end' ? x1 - w - 18 : (x0 + x1 - w) / 2;
      const vy = al === 'start' ? y0 : al === 'end' ? y1 - h : (y0 + y1 - h) / 2;
      if (pos === 'above') { x = hx; y = y0 - h - g; }
      else if (pos === 'below') { x = hx; y = y1 + g; }
      else if (pos === 'top') { x = hx; y = y0 - h / 2; }
      else if (pos === 'bottom') { x = hx; y = y1 - h / 2; }
      else if (pos === 'left') { x = x0 - w - g; y = vy; }
      else if (pos === 'right') { x = x1 + g; y = vy; }
    }
    x = Math.round(x + dx); y = Math.round(y + dy);
    el.style.left = x + 'px'; el.style.top = y + 'px';
    el.classList.add('placed');
    const ax = x, ay = top + y;
    placed.push({text: el.textContent.trim(), x: ax, y: ay, w: Math.round(w), h: Math.round(h)});
    if (ax < 48 || ax + w > S.W - 48) R.errors.push('"' + el.textContent.trim() + '" leaves the side margin');
    if (ay < cb.bottom + 8 || ay + h > S.H - 48) R.errors.push('"' + el.textContent.trim() + '" collides with the caption or bottom edge');
  });
  R.labels = placed;
  // everything inside the canvas
  document.querySelectorAll('.card, .photo, .checks').forEach(el => {
    const r = el.getBoundingClientRect();
    if (r.left < 40 || r.right > S.W - 40 || r.top < 0 || r.bottom > S.H - 40) R.errors.push(el.className + ' leaves the canvas safe area');
  });
  R.fonts = [...new Set([...document.querySelectorAll('.headline, .sub, .chip, .tag, .checks .row')].map(e => getComputedStyle(e).fontFamily))];
  document.title = 'done';
  console.log('REPORT ' + JSON.stringify(R));
})();
"""


def page(spec: dict, build: Path, key: str) -> tuple[str, list[tuple[str, str]]]:
    lang = spec["lang"]
    lay = Layout(spec, build, key)
    for item in spec["stage"]:
        lay.add(item)
    stage_h = lay.y
    head = spec["headline"]
    sub_lines = spec.get("sub") or []
    if isinstance(sub_lines, str):
        sub_lines = [sub_lines]
    texts = [("headline", " ".join(head))]
    if sub_lines:
        texts.append(("sub", " ".join(sub_lines)))
    if spec.get("pill"):
        texts.append(("pill", spec["pill"]))
    texts += lay.texts
    hp = spec["headline_px"][lang]
    js_spec = {
        "W": W, "H": H, "maxw": CONTENT_W, "head": [hp[0], hp[1]],
        "gap": spec.get("stage_gap", 72), "bottom": spec.get("bottom", 96),
        "align": spec.get("align", 0.5), "stage_top": spec.get("stage_top"),
        "stage_h": stage_h, "sub_n": len(sub_lines),
    }
    head_html = "<br>".join(f'<span class="ln">{ln}</span>' for ln in head)
    pill = f'<div class="pill">{spec["pill"]}</div>' if spec.get("pill") else ""
    sub = f'<p class="sub">{"<br>".join(sub_lines)}</p>' if sub_lines else ""
    css = (HERE / "store.css").as_uri()
    hlang = "zh-Hans" if lang == "zh" else "en"
    doc = (f'<!doctype html><html lang="{hlang}"><head><meta charset="utf-8">'
           f'<meta name="viewport" content="width={W}"><title>{html.escape(key)}</title>'
           f'<link rel="stylesheet" href="{css}">'
           + (f"<style>{spec['style']}</style>" if spec.get("style") else "")
           + f'</head><body><main class="frame t-{spec.get("theme", "light")}">'
           f'<div class="copy">{pill}<h1 class="headline">{head_html}</h1>{sub}</div>'
           f'<div class="stage" style="height:{stage_h}px">{deco_html(spec, stage_h)}{"".join(lay.html)}</div>'
           f'</main><script>window.__SPEC__ = {json.dumps(js_spec)};</script>'
           f'<script>{PAGE_JS}</script></body></html>')
    return doc, texts


# ---------------------------------------------------------------- chrome
def check_profile(p: Path) -> None:
    rp = p.resolve()
    if rp == FORBIDDEN_PROFILE or FORBIDDEN_PROFILE in rp.parents:
        raise SystemExit(f"refusing to use the owner's Chrome profile: {rp}")


def shoot(html_path: Path, png_path: Path, profile: Path, timeout: float = 60.0) -> dict:
    """Render one page. Chrome writes the screenshot and may linger, so wait
    for the file, read the REPORT line from its console log, and stop it."""
    check_profile(profile)
    if png_path.exists():
        png_path.unlink()
    profile.mkdir(parents=True, exist_ok=True)
    log = png_path.with_suffix(".log")
    cmd = [CHROME, "--headless=new", f"--user-data-dir={profile}", "--no-first-run",
           "--no-default-browser-check", "--disable-extensions", "--disable-background-networking",
           "--disable-component-update", "--disable-sync", "--disable-domain-reliability",
           "--no-pings", "--disable-default-apps", "--hide-scrollbars", "--force-color-profile=srgb",
           "--allow-file-access-from-files", f"--force-device-scale-factor={DPR}",
           f"--window-size={W},{H}", "--virtual-time-budget=4000", "--enable-logging=stderr", "--v=0",
           f"--screenshot={png_path}", html_path.as_uri()]
    with open(log, "w") as lf:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=lf)
        t0, last = time.time(), -1
        try:
            while time.time() - t0 < timeout:
                if png_path.exists():
                    size = png_path.stat().st_size
                    if size > 0 and size == last:
                        try:
                            with Image.open(png_path) as im:
                                im.load()
                            break
                        except Exception:
                            pass
                    last = size
                if proc.poll() is not None and not png_path.exists():
                    raise RuntimeError(f"chrome exited {proc.returncode} without a screenshot for {html_path.name}")
                time.sleep(0.3)
            else:
                raise RuntimeError(f"timed out rendering {html_path.name}")
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    proc.kill()
    m = re.search(r'"REPORT (\{.*\})", source:', log.read_text(errors="replace"))
    if not m:
        raise RuntimeError(f"no REPORT from the page script for {html_path.name} (see {log})")
    return json.loads(m.group(1))


def finish(raw: Path, dest: Path, medium: Path | None) -> int:
    with Image.open(raw) as im:
        img = im.convert("RGB")
    if img.size != (W * DPR, H * DPR):
        raise RuntimeError(f"{raw.name}: Chrome rendered {img.size}, expected {(W * DPR, H * DPR)}")
    img = img.resize((W, H), Image.Resampling.LANCZOS)
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest, "PNG", optimize=True, icc_profile=srgb)
    if medium:
        medium.parent.mkdir(parents=True, exist_ok=True)
        img.resize((1206, 2622), Image.Resampling.LANCZOS).save(medium, "PNG", optimize=True, icc_profile=srgb)
    return dest.stat().st_size


def verify(path: Path, size: tuple[int, int]) -> list[str]:
    errs = []
    with Image.open(path) as im:
        if im.size != size:
            errs.append(f"size {im.size} != {size}")
        if im.mode != "RGB":
            errs.append(f"mode {im.mode} (must be RGB)")
        if "transparency" in im.info:
            errs.append("has a transparency key")
    out = subprocess.run(["sips", "-g", "hasAlpha", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         capture_output=True, text=True).stdout
    if "hasAlpha: no" not in out:
        errs.append("sips reports an alpha channel")
    if path.stat().st_size > MAX_BYTES:
        errs.append(f"file is {path.stat().st_size / 1e6:.1f} MB")
    return errs


# ---------------------------------------------------------------- sheets
def sheet(paths: list[Path], width: int, dest: Path, gap: int = 24, bg=(60, 60, 60)) -> None:
    thumbs = []
    for p in paths:
        with Image.open(p) as im:
            h = round(H * width / W)
            thumbs.append(im.convert("RGB").resize((width, h), Image.Resampling.LANCZOS))
    th = thumbs[0].height
    out = Image.new("RGB", (len(thumbs) * width + (len(thumbs) + 1) * gap, th + 2 * gap), bg)
    for i, t in enumerate(thumbs):
        out.paste(t, (gap + i * (width + gap), gap))
    out.save(dest, "PNG", optimize=True)


# ---------------------------------------------------------------- main
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", type=Path, default=HERE / "frames.json")
    ap.add_argument("--lang", default="en,zh")
    ap.add_argument("--only", default="", help="comma-separated frame ids or number prefixes (01,05)")
    ap.add_argument("--out", type=Path, default=HERE.parent / "screenshots-marketing")
    ap.add_argument("--build", type=Path, default=None,
                    help="scratch folder for assets, HTML, raw renders, Chrome profiles and sheets "
                         "(default: a new folder in $TMPDIR)")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--medium", action="store_true", help="also write 1206 x 2622 copies")
    ap.add_argument("--html-only", action="store_true")
    ap.add_argument("--no-sheets", action="store_true")
    a = ap.parse_args()

    if not Path(CHROME).exists() and not a.html_only:
        raise SystemExit(f"Chrome not found at {CHROME}")
    spec_all = json.loads(a.frames.read_text())
    defaults, frames = spec_all.get("defaults", {}), spec_all["frames"]
    if a.only:
        keys = [k.strip() for k in a.only.split(",") if k.strip()]
        frames = [f for f in frames if any(f["id"] == k or f["id"].startswith(k + "_") for k in keys)]
    langs = [l.strip() for l in a.lang.split(",") if l.strip()]
    build = (a.build or Path(tempfile.mkdtemp(prefix="chopstats-store-"))).resolve()
    check_profile(build)
    build.mkdir(parents=True, exist_ok=True)
    print(f"build folder: {build}")

    jobs = []
    problems: list[str] = []
    for f in frames:
        for lang in langs:
            spec = merged(defaults, f, lang)
            key = f"{f['id']}_{lang}"
            doc, texts = page(spec, build, key)
            for where, t in texts:
                hits = banned_hits(t, lang)
                if hits:
                    problems.append(f"{key}: {where} {t!r} matches banned pattern(s) {hits}")
            hp = build / "html" / f"{key}.html"
            hp.parent.mkdir(parents=True, exist_ok=True)
            hp.write_text(doc, encoding="utf-8")
            jobs.append((f["id"], lang, hp))
    if problems:
        print("\n".join(problems))
        raise SystemExit("banned words in added text; fix frames.json")
    if a.html_only:
        for _, _, hp in jobs:
            print(hp)
        return

    profiles: queue.Queue = queue.Queue()
    for i in range(max(1, a.jobs)):
        profiles.put(build / f"chrome-profile-{i}")

    def run(job):
        fid, lang, hp = job
        raw = build / "raw" / f"{fid}_{lang}.png"
        raw.parent.mkdir(parents=True, exist_ok=True)
        prof = profiles.get()
        try:
            report = shoot(hp, raw, prof)
        finally:
            profiles.put(prof)
        dest = a.out / LOCALES[lang] / f"{fid}.png"
        med = (a.out.parent / (a.out.name + "-medium") / LOCALES[lang] / f"{fid}.png") if a.medium else None
        size = finish(raw, dest, med)
        errs = verify(dest, (W, H)) + (verify(med, (1206, 2622)) if med else [])
        return fid, lang, dest, size, report, errs

    results = []
    failed = False
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for fid, lang, dest, size, rep, errs in ex.map(run, jobs):
            results.append((fid, lang, dest))
            errs = rep.get("errors", []) + errs
            status = "OK" if not errs else "FAIL: " + "; ".join(errs)
            print(f"{dest.relative_to(a.out.parent) if a.out.parent in dest.parents else dest}  "
                  f"{size / 1e6:.2f} MB  head {rep.get('headline_px')} px {rep.get('line_widths')}  "
                  f"sub {rep.get('sub_lines')} lines  caption to {rep.get('caption_bottom')}  "
                  f"stage {rep.get('stage_top')}-{rep.get('stage_bottom')} in {rep.get('zone')}  {status}")
            failed |= bool(errs)
    if not a.no_sheets:
        for lang in langs:
            mine = sorted([d for (f, l, d) in results if l == lang])
            if not mine:
                continue
            trio = [p for p in mine if p.name[:2] in ("01", "02", "03")]
            if trio:
                sheet(trio, 300, build / f"sheet_search_300_{lang}.png", gap=16, bg=(255, 255, 255))
                sheet(trio, 375, build / f"sheet_trio_375_{lang}.png", gap=20, bg=(255, 255, 255))
            sheet(mine, 690, build / f"sheet_all_690_{lang}.png")
            sheet(mine, 330, build / f"sheet_all_330_{lang}.png")
        print(f"contact sheets: {build}/sheet_*.png")
    if failed:
        raise SystemExit("some frames failed their checks")


if __name__ == "__main__":
    main()
