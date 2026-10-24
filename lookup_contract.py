"""Restaurant-lookup ACCEPTANCE GATE for the owner's server (R3a/R3b).

The lookup contract is lane B's (stage R2a), and the server uses it as
is: restaurant_lookup.py -- the Python twin of the app's
core/restaurant_lookup_contract.dart and core/chain_match.dart, pinned to
them byte for byte by shared/vectors/restaurant_lookup.json -- composes
the request (data_contracts section 4) and the prompt, from the shared
prompt, response schema and US chain table that scripts/sync_shared.py
generates into shared_generated.py. So a request the app composed reaches
the model byte-identical to what a direct provider gets, and nothing here
keeps a second copy of the table, the prompt or the schema.

What this module adds is the server's own gate around that contract:

  * sanitize_request refuses anything that is not a lookup request this
    server will run (a field whitelist, forbidden location and free-text
    keys, caps with an oversize refusal, coordinate-shaped text in any
    field after full NFKC, chain keys that are not in the table, a lookup
    with neither a table chain nor a printed brand), then has
    restaurant_lookup.compose_lookup_request build the request from the
    caller's whitelisted fields and refuses the result unless it still
    matches what the gate accepted. A caller never supplies prompt text.
  * compose_prompt is restaurant_lookup.compose_lookup_prompt, sent only
    when the prompt still holds exactly one data block carrying exactly
    the request.
  * sanitize_lookup rebuilds the model's answer to the section-5 shape
    with lane B's acceptance limits (core/restaurant_assist_logic.dart):
    entries that break the contract are dropped, never repaired.

What a request may carry (and nothing else reaches the model): item
names, quantities and units, the chain an item's printed brand names, the
chain the receipt merchant names (lane B's chain_name_only: the table's
canonical name or "", never the printed text), up to 3 chain KEYS from
our own table (their canonical names are taken from the table, never from
the caller), the country code and the reply language. No coordinates,
street, city, distance, timestamps, meal_description, dietary profile,
history or image: those keys are refused outright, and coordinate-shaped
text inside any field is too.
"""

import hashlib
import json
import re
import unicodedata
from typing import Dict, List, Optional

import restaurant_lookup

# ─── Request caps (data_contracts section 4; lane B's composer) ──────
MAX_ITEMS = restaurant_lookup.LOOKUP_MAX_ITEMS
MAX_CHAINS = restaurant_lookup.LOOKUP_MAX_CHAINS
ITEM_NAME_CAP = restaurant_lookup.LOOKUP_ITEM_NAME_MAX
UNIT_CAP = restaurant_lookup.LOOKUP_UNIT_MAX
BRAND_CAP = restaurant_lookup.LOOKUP_BRAND_MAX
MERCHANT_CAP = restaurant_lookup.LOOKUP_MERCHANT_MAX
QTY_MAX = restaurant_lookup.LOOKUP_QTY_MAX
# Anything this many times over its cap was not produced by the app's
# composer (which truncates to the cap): refuse instead of truncating.
_OVERSIZE_FACTOR = 4

# Top-level keys the request is rebuilt from. Unknown keys are dropped
# (never forwarded), EXCEPT FORBIDDEN_KEYS, which mean a client is trying
# to send location, free text or personal data: those are a 400. Inside
# items and chains the whitelist is exact — any other key is a 400.
TOP_LEVEL_KEYS = frozenset(
    {"items", "order_merchant", "chains", "country", "lang", "backend"})
_ITEM_KEYS = frozenset({"name", "qty", "unit", "brand"})
_CHAIN_KEYS = frozenset({"key", "name", "size"})
FORBIDDEN_KEYS = frozenset({
    "lat", "lon", "lng", "latitude", "longitude", "coords", "coordinates",
    "location", "gps", "geo", "point", "city", "street", "address",
    "region", "postal_code", "zip", "distance", "distance_m", "place",
    "places", "poi", "mapkit", "map_item", "prompt", "system",
    "instructions", "meal_description", "dietary_profile", "profile",
    "history", "recent_meals", "image", "image_b64", "photo", "timestamp",
    "captured_at", "created_at", "time", "notes", "query", "url",
})

# The app's composer reads any zh tag (zh, zh-Hans, zh_CN, zh-Hant-TW) as
# "reply in Chinese"; the same rule here, so both sides agree.
_ZH_LANG_RE = re.compile(r"^[Zz][Hh](?:[-_][A-Za-z0-9]{1,8})*$")
_LANG_CAP = 35
_COUNTRY_RE = re.compile(r"^[A-Za-z]{2}$")
# Two decimal numbers with 3+ fractional digits side by side: the shape of
# a latitude/longitude pair. No dish, unit or brand looks like this.
_COORD_RE = re.compile(
    r"[-+]?\d{1,3}\.\d{3,}\s*[,;/ ]\s*[-+]?\d{1,3}\.\d{3,}")
_WS_RE = re.compile(r"\s+")
_TOKEN_RE = re.compile(r"<<[A-Z_]+>>")


class RequestRejected(ValueError):
    """The request is not a lookup request this server will run."""

    def __init__(self, code: str, field: str = ""):
        super().__init__(code)
        self.code = code
        self.field = field


def clean_text(value, cap: int) -> str:
    """The gate's cleaner: full NFKC (stricter than the composer's
    nfkc_lite, so coordinate-shaped text in any Unicode digit form is
    caught), control/format characters and angle brackets removed,
    whitespace collapsed, trimmed, capped. Idempotent, so text the app's
    composer already cleaned passes through unchanged."""
    text = unicodedata.normalize("NFKC", str(value))
    text = "".join(
        " " if ch in "\t\n\r" else ch for ch in text
        if ch in "\t\n\r" or not unicodedata.category(ch).startswith("C"))
    text = text.replace("<", "").replace(">", "")
    text = _WS_RE.sub(" ", text).strip()
    return text[:cap]


def _text_field(raw, cap: int, field: str) -> str:
    if raw is None:
        return ""
    if not isinstance(raw, str):
        raise RequestRejected("bad_request", field)
    if len(raw) > cap * _OVERSIZE_FACTOR:
        raise RequestRejected("bad_request", field)
    text = clean_text(raw, cap)
    if _COORD_RE.search(text):
        raise RequestRejected("bad_request", field)
    return text


def _qty(raw, field: str):
    """A count in (0, QTY_MAX]; anything else is refused (lane B's
    composer would quietly send 1, which is right for the app's own
    request but hides a caller's error). The count that is sent is the
    composer's (hundredths, half up, an int when whole)."""
    if raw is None:
        return 1
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        raise RequestRejected("bad_request", field)
    if raw != raw or not (0 < raw <= QTY_MAX):
        raise RequestRejected("bad_request", field)
    return raw


def chain_known(key) -> bool:
    """True when key is a chain in OUR table (lane B's chain_by_key)."""
    return restaurant_lookup.chain_by_key(key) is not None


# ─── Request validation (data_contracts sections 4 and 6) ─────────────
def sanitize_request(payload) -> Dict:
    """The lookup request REBUILT from a whitelist, or RequestRejected.

    code 'unsupported_backend' for any backend but 'claude'; everything
    else is 'bad_request' with the offending field name (the caller's own
    key, never its value)."""
    if not isinstance(payload, dict):
        raise RequestRejected("bad_request", "body")
    for key in payload:
        if not isinstance(key, str) or key.strip().lower() in FORBIDDEN_KEYS:
            raise RequestRejected("bad_request", str(key)[:40])
    backend = payload.get("backend") or "claude"
    if backend != "claude":
        raise RequestRejected("unsupported_backend", "backend")

    raw_items = payload.get("items")
    if not isinstance(raw_items, list) or not raw_items:
        raise RequestRejected("bad_request", "items")
    if len(raw_items) > MAX_ITEMS:
        raise RequestRejected("bad_request", "items")
    items: List[Dict] = []
    for i, raw in enumerate(raw_items):
        field = f"items[{i}]"
        if not isinstance(raw, dict) or not set(raw) <= _ITEM_KEYS:
            raise RequestRejected("bad_request", field)
        # A nameless item keeps its slot: item_index in the answer is the
        # meal's own food_items index (the app's composer keeps it too).
        name = _text_field(raw.get("name"), ITEM_NAME_CAP, field + ".name")
        items.append({
            "name": name,
            "qty": _qty(raw.get("qty"), field + ".qty"),
            "unit": _text_field(raw.get("unit"), UNIT_CAP, field + ".unit"),
            "brand": _text_field(raw.get("brand"), BRAND_CAP,
                                 field + ".brand"),
        })

    if not any(it["name"] for it in items):
        raise RequestRejected("bad_request", "items")

    merchant = _text_field(payload.get("order_merchant"), MERCHANT_CAP,
                           "order_merchant")

    raw_chains = payload.get("chains")
    if raw_chains is None:
        raw_chains = []
    if not isinstance(raw_chains, list) or len(raw_chains) > MAX_CHAINS:
        raise RequestRejected("bad_request", "chains")
    chains: List[Dict] = []
    for i, raw in enumerate(raw_chains):
        field = f"chains[{i}]"
        if not isinstance(raw, dict) or not set(raw) <= _CHAIN_KEYS:
            raise RequestRejected("bad_request", field)
        key = raw.get("key")
        if not isinstance(key, str) or not chain_known(key):
            raise RequestRejected("bad_request", field + ".key")
        if any(c["key"] == key for c in chains):
            raise RequestRejected("bad_request", field + ".key")
        name = raw.get("name")
        if name is not None and (not isinstance(name, str)
                                 or len(name) > BRAND_CAP * _OVERSIZE_FACTOR):
            raise RequestRejected("bad_request", field + ".name")
        if raw.get("size", "20_plus") != "20_plus":
            raise RequestRejected("bad_request", field + ".size")
        # The caller's name is never used: the canonical name is OURS.
        chains.append({"key": key,
                       "name": restaurant_lookup.chain_by_key(key)["name"],
                       "size": "20_plus"})

    if not chains and not merchant and not any(it["brand"] for it in items):
        # Independent restaurants get no lookup in v1: a chain from our
        # table or a printed brand is the only thing worth searching for.
        raise RequestRejected("bad_request", "chains")

    country = payload.get("country")
    if country is None or country == "":
        country = "US"
    if not isinstance(country, str) or not _COUNTRY_RE.match(country):
        raise RequestRejected("bad_request", "country")

    request = {"items": items, "order_merchant": merchant, "chains": chains,
               "country": country.upper()}
    lang = payload.get("lang")
    if lang is not None and (not isinstance(lang, str) or len(lang) > _LANG_CAP):
        raise RequestRejected("bad_request", "lang")
    if isinstance(lang, str) and _ZH_LANG_RE.match(lang):
        request["lang"] = "zh"
    return _compose(payload, request)


def _compose(payload: Dict, gated: Dict) -> Dict:
    """The request as lane B's composer builds it from the caller's own
    whitelisted fields (byte-identical to what the app composed), checked
    against what the gate accepted: same items, same chain keys in the
    same order, still a lookup worth running (a printed brand counts only
    when it names a table chain), no coordinate-shaped text. Anything else
    is refused, never repaired."""
    raw = {k: payload[k] for k in TOP_LEVEL_KEYS - {"backend"} if k in payload}
    composed = restaurant_lookup.compose_lookup_request(raw)
    try:
        items = composed["items"]
        chains = composed["chains"]
        texts = [composed["order_merchant"]]
        for item in items:
            texts += [item["name"], item["unit"], item["brand"]]
        ok = (len(items) == len(gated["items"])
              and [c["key"] for c in chains]
              == [c["key"] for c in gated["chains"]]
              and all(isinstance(t, str) and not _COORD_RE.search(t)
                      and "<" not in t and ">" not in t for t in texts)
              and any(item["name"] for item in items)
              and (chains or composed["order_merchant"]
                   or any(item["brand"] for item in items))
              and composed.get("country") == gated["country"]
              and composed.get("lang") == gated.get("lang"))
    except (KeyError, TypeError):
        ok = False
    if not ok:
        raise RequestRejected("bad_request", "request")
    return composed


def unknown_key_count(payload) -> int:
    """How many top-level keys sanitize_request dropped (for one log line;
    the keys themselves are never logged)."""
    if not isinstance(payload, dict):
        return 0
    return sum(1 for key in payload if key not in TOP_LEVEL_KEYS)


def request_hash(request: Dict, model: str = "") -> str:
    """SHA-256 over the canonical rebuilt request (and the lookup model,
    so switching CLAUDE_LOOKUP_MODEL never serves the old model's
    cached answer)."""
    canonical = json.dumps({"request": request, "model": model or ""},
                           sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


# ─── Prompt and schema (lane B's) ─────────────────────────────────────
def lookup_schema_json() -> str:
    """The --json-schema argument: lane B's response schema
    (shared/prompts/restaurant_lookup_schema.json), compact."""
    return json.dumps(json.loads(restaurant_lookup.RESTAURANT_LOOKUP_SCHEMA),
                      separators=(",", ":"))


def compose_prompt(request: Dict) -> str:
    """The full model prompt for an already-sanitized request: lane B's
    compose_lookup_prompt. It must hold exactly ONE data block carrying
    exactly this request and no unreplaced <<TOKEN>>, and the request
    nowhere else (caller text outside the data block would read as
    instructions) — otherwise it raises (the job fails) rather than send
    such a prompt."""
    payload = restaurant_lookup.canonical_lookup_json(request)
    prompt = restaurant_lookup.compose_lookup_prompt(request)
    if (prompt.count("<data>") != 1 or prompt.count("</data>") != 1
            or prompt.count(payload) != 1
            or f"<data>\n{payload}\n</data>" not in prompt
            or unreplaced_tokens(prompt)):
        raise ValueError("lookup prompt lost its request block")
    return prompt


def unreplaced_tokens(prompt: str) -> List[str]:
    return _TOKEN_RE.findall(prompt)


# ─── Response sanitization (data_contracts section 5) ─────────────────
_STATUSES = frozenset({"found", "not_published", "no_match", "ambiguous"})
_MATCH_TYPES = frozenset({"exact_item", "closest_item", "components_sum"})
_SOURCE_TYPES = frozenset({"official_site", "official_pdf", "official_app",
                           "third_party_db", "other"})
# The limits of lane B's acceptance (core/restaurant_assist_logic.dart
# kAssistMaxOptions, kAssistMaxComponents, kAssistMaxPublishedKcal,
# kAssistMaxPublishedGrams): the server never drops a size or a component
# the app would still consider, and never keeps a number it would refuse.
MAX_OPTIONS = 12
MAX_COMPONENTS = 20
KCAL_MAX = 6000
MACRO_MAX = 1000
URL_CAP = 500


def _num(value, upper: float, integer: bool = False):
    """A published number as published: in [0, upper], finite, not a
    bool. A calorie value (integer=True) must be whole -- 590.0 is the
    published 590, 590.5 is no published calorie value and is dropped,
    never rounded into one (the app's _publishedKcal). Grams are kept
    exactly."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or not (0 <= value <= upper):  # NaN, negatives, absurd
        return None
    if integer:
        return int(value) if value == int(value) else None
    return value


def _str_or_none(value, cap: int):
    if not isinstance(value, str):
        return None
    text = clean_text(value, cap)
    return text or None


def safe_url(value) -> Optional[str]:
    """An http(s) URL with no whitespace or control characters, or None."""
    if not isinstance(value, str) or len(value) > URL_CAP:
        return None
    if not re.match(r"^https?://[^\s/?#]+", value):
        return None
    if any(ch.isspace() or unicodedata.category(ch).startswith("C")
           for ch in value):
        return None
    return value


def _text(value, cap: int) -> str:
    """Answer text as kept: a string cleaned and capped; anything else is
    "" (lane B's sanitizeAssistText never stringifies a number)."""
    return clean_text(value, cap) if isinstance(value, str) else ""


def _list(value) -> list:
    return value if isinstance(value, list) else []


def _option(raw) -> Optional[Dict]:
    """One published size, or None when it publishes no calorie value
    (lane B's _parseOption skips it the same way). A valid range wins over
    a single value given next to it: both at once breaks the contract, and
    a range can never apply."""
    if not isinstance(raw, dict):
        return None
    out = {
        "label": _text(raw.get("label"), 40),
        "serving": _text(raw.get("serving"), 40),
        "unit": _text(raw.get("unit"), 20),
        "calories": _num(raw.get("calories"), KCAL_MAX, integer=True),
        "calories_range": None,
        "protein_g": _num(raw.get("protein_g"), MACRO_MAX),
        "carbs_g": _num(raw.get("carbs_g"), MACRO_MAX),
        "fat_g": _num(raw.get("fat_g"), MACRO_MAX),
    }
    rng = raw.get("calories_range")
    if isinstance(rng, list) and len(rng) == 2:
        lo = _num(rng[0], KCAL_MAX, integer=True)
        hi = _num(rng[1], KCAL_MAX, integer=True)
        if lo is not None and hi is not None and lo <= hi:
            out["calories_range"] = [lo, hi]
            out["calories"] = None
    if out["calories"] is None and out["calories_range"] is None:
        return None
    return out


def _component(raw) -> Dict:
    """One published component, KEPT even when it is unusable: lane B sums
    a components_sum match only when EVERY component publishes calories,
    so dropping a bad one would turn "no total" into a smaller, wrong
    total. An unusable entry stays with calories null."""
    if not isinstance(raw, dict):
        raw = {}
    return {"name": _text(raw.get("name"), 60),
            "calories": _num(raw.get("calories"), KCAL_MAX, integer=True),
            "protein_g": _num(raw.get("protein_g"), MACRO_MAX),
            "carbs_g": _num(raw.get("carbs_g"), MACRO_MAX),
            "fat_g": _num(raw.get("fat_g"), MACRO_MAX)}


def sanitize_lookup(raw, request: Dict) -> Optional[Dict]:
    """The model's answer rebuilt to the section-5 shape with every cap
    applied, or None when it is not a lookup answer at all.

    It never changes what lane B's acceptance (decideAssist) would decide
    on the raw answer: it reads the same first 12 matches, 12 options and
    20 components; drops only what lane B skips one by one (a match with
    a bad index, type or name, an option without a calorie value); keeps
    what lane B judges as a whole (a second match for the same item, which
    makes the mapping ambiguous; an unusable component, which voids its
    sum); and repairs nothing into a number the model did not give."""
    if not isinstance(raw, dict) or raw.get("status") not in _STATUSES:
        return None
    n_items = len(request.get("items", []))
    matches = []
    for m in _list(raw.get("matches"))[:MAX_ITEMS]:
        if not isinstance(m, dict):
            continue
        idx = m.get("item_index")
        if isinstance(idx, bool) or not isinstance(idx, int):
            continue
        if not 0 <= idx < n_items:
            continue
        if m.get("match_type") not in _MATCH_TYPES:
            continue
        menu_item = _text(m.get("menu_item"), 60)
        if not menu_item:
            continue
        options = [o for o in map(_option,
                                  _list(m.get("options"))[:MAX_OPTIONS]) if o]
        components = [_component(c) for c in
                      _list(m.get("components"))[:MAX_COMPONENTS]]
        if not options and not components:
            continue
        matches.append({
            "item_index": idx,
            "menu_item": menu_item,
            "match_type": m["match_type"],
            "is_drink": m.get("is_drink") is True,
            "components": components,
            "options": options,
        })
    chain_key = raw.get("chain_key")
    if not chain_known(chain_key):
        chain_key = None
    year = raw.get("source_year")
    if isinstance(year, bool) or not isinstance(year, int) \
            or not 1990 <= year <= 2100:
        year = None
    confidence = raw.get("match_confidence")
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) \
            or confidence != confidence:
        confidence = 0.0
    source_type = raw.get("source_type")
    return {
        "status": raw["status"],
        "chain_key": chain_key,
        "restaurant_name": _text(raw.get("restaurant_name"), 60),
        "matches": matches,
        "source_url": safe_url(raw.get("source_url")),
        "source_title": _str_or_none(raw.get("source_title"), 120),
        "source_type": source_type if source_type in _SOURCE_TYPES else "other",
        "source_year": year,
        "match_confidence": round(min(max(float(confidence), 0.0), 1.0), 3),
        "notes": _text(raw.get("notes"), 200),
    }
