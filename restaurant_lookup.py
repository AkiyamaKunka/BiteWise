"""Restaurant-assist lookup contract (stage R2a).

Three pieces every lookup provider shares, so the request can never differ
between the owner's server and the app:

  * compose_lookup_request(raw) -> the request body (data_contracts section
    4): item names, counts, units and printed brands, the receipt merchant,
    up to 3 chains taken from OUR table by key, the country and the reply
    language. Nothing else survives: no coordinates, street, distance, city,
    timestamps, meal_description, calories or any other key.
  * compose_lookup_prompt(raw) -> the shared prompt with that request as
    compact JSON inside its single data block.
  * match_chain(name, url_host) -> the key of a chain in
    shared/chains/us_chains.json, or None.

This module is the Python twin of app/lib/core/restaurant_lookup_contract.dart
and app/lib/core/chain_match.dart; shared/vectors/restaurant_lookup.json pins
Dart == Python. The text cleaning is a port of core/coerce.dart's brand
cleaner (nfkcLite and _cleanShortText) rather than unicodedata NFKC, because
the two sides must produce identical bytes.

Injection safety: every string is cleaned (compatibility-folded, control,
invisible and bidi characters and every angle bracket removed, whitespace
collapsed, capped), so request text can never close the data block, and the
JSON encoding quotes everything else. Chain names come from the table, never
from the caller.
"""
import json
import math
import re

import shared_generated

LOOKUP_MAX_ITEMS = 12
LOOKUP_ITEM_NAME_MAX = 80
LOOKUP_BRAND_MAX = 60
LOOKUP_UNIT_MAX = 20
LOOKUP_MERCHANT_MAX = 60
LOOKUP_MAX_CHAINS = 3
LOOKUP_QTY_MAX = 20
LOOKUP_DEFAULT_COUNTRY = "US"
REQUEST_JSON_TOKEN = "<<REQUEST_JSON>>"

US_CHAINS = shared_generated.US_CHAINS
RESTAURANT_LOOKUP_PROMPT = shared_generated.RESTAURANT_LOOKUP_PROMPT
RESTAURANT_LOOKUP_SCHEMA = shared_generated.RESTAURANT_LOOKUP_SCHEMA


# ---------------------------------------------------------------------------
# Text cleaning (port of app/lib/core/coerce.dart nfkcLite / _cleanShortText)
# ---------------------------------------------------------------------------

_NFKC_LITE_TABLE = {
    0x00A0: " ", 0x2000: " ", 0x2001: " ", 0x2002: " ", 0x2003: " ",
    0x2004: " ", 0x2005: " ", 0x2006: " ", 0x2007: " ", 0x2008: " ",
    0x2009: " ", 0x200A: " ", 0x202F: " ", 0x205F: " ", 0x3000: " ",
    0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl",
    0xFB05: "st", 0xFB06: "st",
    0x2122: "TM", 0x2120: "SM",
    0xFE64: "<", 0xFE65: ">",
    0x2024: ".", 0x2025: "..", 0x2026: "...",
}


def nfkc_lite(s):
    """The deliberate NFKC subset of core/coerce.dart nfkcLite: fullwidth
    ASCII, compatibility spaces, Latin ligatures, TM/SM, small angle
    brackets and dot leaders. Everything else passes through."""
    out = []
    for ch in s:
        r = ord(ch)
        if 0xFF01 <= r <= 0xFF5E:
            out.append(chr(r - 0xFEE0))
            continue
        out.append(_NFKC_LITE_TABLE.get(r, ch))
    return "".join(out)


def _is_space_rune(r):
    return (r == 0x20 or 0x09 <= r <= 0x0D or 0x1C <= r <= 0x1F
            or r == 0x85 or r == 0xA0 or r == 0x1680
            or 0x2000 <= r <= 0x200A or r == 0x2028 or r == 0x2029
            or r == 0x202F or r == 0x205F or r == 0x3000)


def _is_stripped_rune(r):
    return (r < 0x20 or 0x7F <= r <= 0x9F or 0xD800 <= r <= 0xDFFF
            or r == 0x3C or r == 0x3E or r == 0x061C
            or 0x200B <= r <= 0x200F or 0x202A <= r <= 0x202E
            or 0x2060 <= r <= 0x2064 or 0x2066 <= r <= 0x2069
            or r == 0xFEFF)


def clean_short_text(value, max_chars):
    """core/coerce.dart cleanShortText: non-strings are ""; whitespace runs
    collapse to one space (none leading, none trailing); stripped runes are
    dropped; at most max_chars code points."""
    if not isinstance(value, str):
        return ""
    out = []
    pending_space = False
    for ch in nfkc_lite(value):
        r = ord(ch)
        if _is_space_rune(r):
            pending_space = len(out) > 0
            continue
        if _is_stripped_rune(r):
            continue
        if pending_space:
            out.append(" ")
            pending_space = False
        out.append(ch)
    s = "".join(out)
    if len(s) <= max_chars:
        return s
    return s[:max_chars].rstrip(" ")


def coerce_qty(value):
    """core/coerce.dart coerceQty: a finite number in (0, 20], else 1.
    Bools and numeric strings are not counts."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 1
    if isinstance(value, int):
        return value if 0 < value <= LOOKUP_QTY_MAX else 1
    if not math.isfinite(value) or value <= 0 or value > LOOKUP_QTY_MAX:
        return 1
    return value


def _request_qty(value):
    """The count as sent: coerce_qty, then hundredths rounded half up (at
    least 0.01), an int when whole. Integer arithmetic past one IEEE
    multiply keeps Dart and Python byte-identical."""
    q = float(coerce_qty(value))
    hundredths = math.floor(q * 100 + 0.5)
    if hundredths < 1:
        hundredths = 1
    if hundredths % 100 == 0:
        return hundredths // 100
    return hundredths / 100


_COUNTRY_RE = re.compile(r"[A-Za-z]{2}")
_LANG_ZH_RE = re.compile(r"[Zz][Hh](?:[-_][A-Za-z0-9]{1,8})*")


def _country(value):
    if isinstance(value, str) and _COUNTRY_RE.fullmatch(value):
        return value.upper()
    return LOOKUP_DEFAULT_COUNTRY


def _lang(value):
    if isinstance(value, str) and _LANG_ZH_RE.fullmatch(value):
        return "zh"
    return None


# ---------------------------------------------------------------------------
# Composers
# ---------------------------------------------------------------------------

def _request_item(item):
    m = item if isinstance(item, dict) else {}
    return {
        "name": clean_short_text(m.get("name"), LOOKUP_ITEM_NAME_MAX),
        "qty": _request_qty(m.get("qty")),
        "unit": clean_short_text(m.get("unit"), LOOKUP_UNIT_MAX),
        "brand": clean_short_text(m.get("brand"), LOOKUP_BRAND_MAX),
    }


def _request_chains(value):
    out = []
    seen = set()
    for entry in value if isinstance(value, list) else []:
        key = entry.get("key") if isinstance(entry, dict) else entry
        if not isinstance(key, str) or key in seen:
            continue
        chain = chain_by_key(key)
        if chain is None:
            continue
        seen.add(key)
        out.append({"key": chain["key"], "name": chain["name"],
                    "size": chain["size"]})
        if len(out) == LOOKUP_MAX_CHAINS:
            break
    return out


def compose_lookup_request(raw):
    """The lookup request body (data_contracts section 4) from a raw input
    of the same shape. Only items[].name/qty/unit/brand, order_merchant,
    chains (keys of OUR table, in rank order), country and lang are read;
    every other key is ignored. Items keep their positions (the first 12),
    so a response's item_index is the meal's food_items index. Idempotent:
    composing a composed request returns it unchanged."""
    r = raw if isinstance(raw, dict) else {}
    items = r.get("items")
    request = {
        "items": [_request_item(i)
                  for i in (items if isinstance(items, list) else [])
                  [:LOOKUP_MAX_ITEMS]],
        "order_merchant": clean_short_text(r.get("order_merchant"),
                                           LOOKUP_MERCHANT_MAX),
        "chains": _request_chains(r.get("chains")),
        "country": _country(r.get("country")),
    }
    lang = _lang(r.get("lang"))
    if lang is not None:
        request["lang"] = lang
    return request


def canonical_lookup_json(obj):
    """Compact JSON, keys in insertion order, non-ASCII kept: the exact
    bytes Dart's jsonEncode produces for the same composed request."""
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"),
                      allow_nan=False)


def compose_lookup_prompt(raw):
    """The shared lookup prompt with the composed request in its data block."""
    request = compose_lookup_request(raw)
    return RESTAURANT_LOOKUP_PROMPT.replace(REQUEST_JSON_TOKEN,
                                            canonical_lookup_json(request))


# ---------------------------------------------------------------------------
# Chain matching (twin of app/lib/core/chain_match.dart)
# ---------------------------------------------------------------------------

# Dropped while tokenizing: apostrophes (McDonald's / McDonald’s /
# McDonalds) and the degree sign (85°C).
_DROPPED = {0x27, 0x60, 0xB4, 0x2BC, 0x2018, 0x2019, 0xB0}

_LATIN_FOLD = {}
for _chars, _base in (
        ("ÀÁÂÃÄÅàáâãäå", "a"),
        ("Ææ", "ae"),
        ("Çç", "c"),
        ("ÈÉÊËèéêë", "e"),
        ("ÌÍÎÏìíîï", "i"),
        ("Ññ", "n"),
        ("ÒÓÔÕÖØòóôõöø", "o"),
        ("Œœ", "oe"),
        ("ÙÚÛÜùúûü", "u"),
        ("Ýýÿ", "y"),
        ("ß", "ss")):
    for _c in _chars:
        _LATIN_FOLD[ord(_c)] = _base

# Where a place name's suffix starts: "McDonald's (Times Sq)",
# "Starbucks - Midtown", "Chipotle #1234".
_NAME_CUTS = ("(", "[", "|", "#", ",", " - ", " – ", " — ",
              " @ ", " · ")

_HOST_LIKE_RE = re.compile(r"[a-z0-9]\.[a-z]{2,}")
_HOST_RE = re.compile(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+")

# A compact (space-free) comparison needs at least this many characters.
_COMPACT_MIN = 5


def _is_cjk(r):
    return (0x3040 <= r <= 0x30FF or 0x3400 <= r <= 0x4DBF
            or 0x4E00 <= r <= 0x9FFF or 0xAC00 <= r <= 0xD7AF
            or 0xF900 <= r <= 0xFAFF or 0x20000 <= r <= 0x2FA1F)


def _ascii_lower(s):
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in s)


def chain_tokens(value):
    """Match tokens of a name: nfkc_lite, apostrophes dropped, Latin-1
    letters folded to ASCII, ASCII lowercased, "&" and "+" read as "and",
    each CJK character its own token, anything else a separator; a leading
    "the" is ignored when more follows."""
    if not isinstance(value, str):
        return []
    buf = []
    for ch in nfkc_lite(value):
        r = ord(ch)
        if r in _DROPPED:
            continue
        if 0x41 <= r <= 0x5A:
            buf.append(chr(r + 32))
        elif 0x61 <= r <= 0x7A or 0x30 <= r <= 0x39:
            buf.append(ch)
        elif r in _LATIN_FOLD:
            buf.append(_LATIN_FOLD[r])
        elif r == 0x26 or r == 0x2B:
            buf.append(" and ")
        elif _is_cjk(r):
            buf.append(" " + ch + " ")
        else:
            buf.append(" ")
    tokens = [t for t in "".join(buf).split(" ") if t]
    if len(tokens) > 1 and tokens[0] == "the":
        tokens = tokens[1:]
    return tokens


def _is_host_like(value):
    lowered = _ascii_lower(nfkc_lite(value))
    return ("://" in lowered or "www." in lowered
            or _HOST_LIKE_RE.search(lowered) is not None)


def _variants(chain):
    out = [chain["name"]] + list(chain.get("aliases", []))
    if chain.get("zh_name"):
        out.append(chain["zh_name"])
    return out


_INDEX = None
_BY_KEY = None


def _index():
    global _INDEX, _BY_KEY
    if _INDEX is None:
        index = []
        for chain in US_CHAINS:
            for v in _variants(chain):
                toks = chain_tokens(v)
                if toks:
                    index.append((chain["key"], toks, "".join(toks)))
        _BY_KEY = {c["key"]: c for c in US_CHAINS}
        _INDEX = index
    return _INDEX


def chain_by_key(key):
    """The table row for key, or None."""
    _index()
    return _BY_KEY.get(key) if isinstance(key, str) else None


def _match_tokens(tokens):
    """(key or None, matched_any). Exact token equality (or a compact
    equality when one side is a single token) beats a token prefix of a
    multi-token variant; a longer prefix beats a shorter one. Two chains
    tied at the best score match nothing."""
    if not tokens:
        return None, False
    compact = "".join(tokens)
    best = None
    keys = set()
    for key, vt, vc in _index():
        score = None
        if tokens == vt:
            score = (2, 0)
        elif ((len(tokens) == 1 or len(vt) == 1) and compact == vc
              and len(compact) >= _COMPACT_MIN):
            score = (2, 0)
        elif len(vt) >= 2 and len(tokens) > len(vt) and tokens[:len(vt)] == vt:
            score = (1, len(vt))
        if score is None:
            continue
        if best is None or score > best:
            best = score
            keys = {key}
        elif score == best:
            keys.add(key)
    if best is None:
        return None, False
    return (next(iter(keys)) if len(keys) == 1 else None), True


def _cut_name(value):
    s = nfkc_lite(value)
    cut = len(s)
    for sep in _NAME_CUTS:
        i = s.find(sep)
        if 0 < i < cut:
            cut = i
    return s[:cut] if cut < len(s) else None


def match_chain_name(name):
    """The chain a place or brand name belongs to, or None. A name that
    looks like a web address never matches by name."""
    if not isinstance(name, str) or _is_host_like(name):
        return None
    key, matched = _match_tokens(chain_tokens(name))
    if matched:
        return key
    cut = _cut_name(name)
    if cut is None:
        return None
    return _match_tokens(chain_tokens(cut))[0]


def normalize_host(host):
    """An ASCII host name lowercased, one trailing dot removed; None for
    anything else (non-ASCII/IDN, ports, paths, empty labels)."""
    if not isinstance(host, str):
        return None
    h = _ascii_lower(host)
    if h.endswith("."):
        h = h[:-1]
    return h if _HOST_RE.fullmatch(h) else None


def host_matches_domain(host, domain):
    """host equals domain or is a subdomain of it (both normalized)."""
    return host == domain or host.endswith("." + domain)


def match_chain_host(host):
    """The chain whose table domain host equals or is a subdomain of."""
    h = normalize_host(host)
    if h is None:
        return None
    for chain in US_CHAINS:
        for d in chain["domains"]:
            if host_matches_domain(h, d):
                return chain["key"]
    return None


def is_chain_host(host, chain_key):
    """True when host is (a subdomain of) one of chain_key's own domains."""
    h = normalize_host(host)
    chain = chain_by_key(chain_key)
    if h is None or chain is None:
        return False
    return any(host_matches_domain(h, d) for d in chain["domains"])


def match_chain(name, url_host=None):
    """matchChain(name, urlHost?): the domain match and the name match; when
    both match different chains, None."""
    host_key = match_chain_host(url_host) if url_host is not None else None
    name_key = match_chain_name(name)
    if host_key is not None and name_key is not None and host_key != name_key:
        return None
    return host_key if host_key is not None else name_key
