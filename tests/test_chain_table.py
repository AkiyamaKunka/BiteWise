"""shared/chains/us_chains.json: BiteWise's own table of US chains (stage R2a).

The restaurant assist sends an AI provider nothing but a chain's canonical
name FROM THIS TABLE, and trusts a nutrition source only on one of the
chain's own domains listed here. So the table must be unambiguous (every
name, alias and Chinese name belongs to exactly one chain, and maps back to
it) and its domains must be registrable, ASCII and never a multi-tenant
host where anyone can publish a page.

Also pins the Python twin of app/lib/core/chain_match.dart; the parity
vectors (shared/vectors/restaurant_lookup.json) pin Dart == Python.
"""
import json
import re
from pathlib import Path

import pytest

import restaurant_lookup as rl
import shared_generated

ROOT = Path(__file__).resolve().parent.parent
TABLE = json.loads((ROOT / "shared" / "chains" / "us_chains.json")
                   .read_text(encoding="utf-8"))
CHAINS = TABLE["chains"]

# Hosts where anyone can publish: a nutrition "source" there proves nothing.
MULTI_TENANT = (
    "github.io", "cloudfront.net", "amazonaws.com", "wixsite.com",
    "square.site", "vercel.app", "blogspot.com", "wordpress.com",
    "toasttab.com", "netlify.app", "herokuapp.com", "firebaseapp.com",
    "web.app", "pages.dev", "azurewebsites.net", "appspot.com",
    "myshopify.com", "squarespace.com", "weebly.com", "godaddysites.com",
    "olo.com", "ctfassets.net", "googleusercontent.com", "nutritionix.com",
    "fatsecret.com", "myfitnesspal.com", "google.com", "facebook.com",
    "instagram.com", "yelp.com", "doordash.com", "ubereats.com",
)

DOMAIN_RE = re.compile(
    r"^(?!-)[a-z0-9-]{1,63}(?<!-)\.(?!-)[a-z]{2,63}(?<!-)$")
KEY_RE = re.compile(r"^[a-z0-9]+(?:_[a-z0-9]+)*$")
CJK_RE = re.compile(r"[㐀-䶿一-鿿]")


def _variants(c):
    out = [c["name"]] + c["aliases"]
    if c.get("zh_name"):
        out.append(c["zh_name"])
    return out


# ─── shape and metadata ────────────────────────────────────────────

def test_metadata_names_its_sources_and_date():
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", TABLE["as_of"])
    assert isinstance(TABLE["source"], str) and TABLE["source"]
    assert TABLE["sources"], "record where the chains and counts came from"
    for s in TABLE["sources"]:
        assert s["name"] and s["url"].startswith("https://"), s


def test_table_size_meets_the_design_target():
    # Design target "about 250"; accuracy beat count when curating.
    assert len(CHAINS) >= 250


def test_rows_have_exactly_the_contract_fields():
    allowed = {"key", "name", "zh_name", "aliases", "domains", "size"}
    for c in CHAINS:
        assert set(c) <= allowed, c["key"]
        assert {"key", "name", "aliases", "domains", "size"} <= set(c), c
        assert c["size"] == "20_plus", c["key"]
        assert isinstance(c["aliases"], list), c["key"]
        assert c["domains"], c["key"]


def test_keys_are_unique_snake_case():
    keys = [c["key"] for c in CHAINS]
    assert len(keys) == len(set(keys))
    for k in keys:
        assert KEY_RE.fullmatch(k), k


def test_names_are_clean_short_text():
    """Names go into the prompt verbatim: they must already be what the
    cleaner would produce (no control or bidi characters, no angle
    brackets, no stray whitespace) and fit the 60-character cap."""
    for c in CHAINS:
        for v in _variants(c):
            assert isinstance(v, str) and v, c["key"]
            assert rl.clean_short_text(v, 60) == v, (c["key"], v)


def test_zh_names_are_chinese():
    for c in CHAINS:
        if "zh_name" in c:
            assert CJK_RE.search(c["zh_name"]), c["key"]


def test_generated_bindings_carry_the_table():
    assert shared_generated.US_CHAINS == CHAINS
    assert shared_generated.US_CHAINS_AS_OF == TABLE["as_of"]


# ─── domains ───────────────────────────────────────────────────────

def test_domains_are_ascii_registrable_names():
    """Two labels, lowercase ASCII, no scheme, path, port or www. — the
    shape that is registrable by construction, so no Public Suffix List
    is needed to decide what 'the chain's own domain' means."""
    for c in CHAINS:
        for d in c["domains"]:
            assert d.isascii(), (c["key"], d)
            assert DOMAIN_RE.fullmatch(d), (c["key"], d)
            assert not d.startswith("www."), (c["key"], d)


@pytest.mark.parametrize("bad", MULTI_TENANT)
def test_no_multi_tenant_host_is_ever_an_official_domain(bad):
    for c in CHAINS:
        for d in c["domains"]:
            assert d != bad and not d.endswith("." + bad), (c["key"], d)
            assert not bad.endswith("." + d), (c["key"], d)


def test_a_domain_belongs_to_exactly_one_chain():
    owners = {}
    for c in CHAINS:
        for d in c["domains"]:
            assert d not in owners, (d, owners.get(d), c["key"])
            owners[d] = c["key"]
    domains = list(owners)
    for a in domains:
        for b in domains:
            if a != b:
                assert not a.endswith("." + b), (a, b)


# ─── names are unambiguous ─────────────────────────────────────────

def test_no_two_chains_share_a_name_alias_or_compact_form():
    exact = {}
    compact = {}
    for c in CHAINS:
        for v in _variants(c):
            toks = tuple(rl.chain_tokens(v))
            assert toks, (c["key"], v)
            other = exact.setdefault(toks, c["key"])
            assert other == c["key"], (v, other, c["key"])
            joined = "".join(toks)
            other = compact.setdefault(joined, c["key"])
            assert other == c["key"], (v, other, c["key"])


def test_every_name_alias_and_zh_name_maps_back_to_its_chain():
    for c in CHAINS:
        for v in _variants(c):
            assert rl.match_chain(v) == c["key"], (v, rl.match_chain(v))


def test_no_variant_looks_like_a_web_address():
    for c in CHAINS:
        for v in _variants(c):
            assert not rl._is_host_like(v), (c["key"], v)


GENERIC = {"cafe", "coffee", "pizza", "grill", "bar", "kitchen", "deli",
           "restaurant", "diner", "bakery", "tacos", "sushi", "subs", "tims",
           "tommys", "jacks", "freddys", "marcos", "amatos", "the", "and"}


def test_single_token_variants_are_not_generic_words():
    """A single token never prefix-matches, but it still matches a place
    with exactly that name — so it must be a distinctive brand."""
    for c in CHAINS:
        for v in _variants(c):
            toks = rl.chain_tokens(v)
            if len(toks) == 1:
                assert toks[0] not in GENERIC, (c["key"], v)


# ─── matcher (Python twin of core/chain_match.dart) ────────────────

@pytest.mark.parametrize("name,url_host,expected", [
    # The design's table (R2a tests)
    ("Chipotle Mexican Grill", None, "chipotle"),
    (None, "order.chipotle.com", "chipotle"),
    (None, "chipotle-nutrition-calculator.com", None),
    ("chipotle-nutrition-calculator.com", None, None),
    ("Panda Express", None, "panda_express"),
    ("I'm donut ?", None, None),
    ("麦当劳", None, "mcdonalds"),
    ("肯德基", None, "kfc"),
    ("星巴克", None, "starbucks"),
    ("熊猫快餐", None, "panda_express"),
    # MapKit names from the live probe (scratchpad lane_places)
    ("Starbucks Coffee Company", None, "starbucks"),
    ("Popeyes Louisiana Kitchen", None, "popeyes"),
    ("McDonald's", None, "mcdonalds"),
    ("Bubba Gump Shrimp Co.", None, "bubba_gump"),
    ("Ora’s Market", None, None),
    ("Junior's Restaurant", None, None),
    ("John's Famous Hot Dogs", None, None),
    ("Sabrett Hot Dog Stand", None, None),
    # Apple Maps names from the 2026-10-24 audit (MapKit name searches)
    ("Kwik Trip", None, "kwik_trip"),
    ("KWIK TRIP #1234", None, "kwik_trip"),
    ("Old Chicago", None, "old_chicago"),
    ("Oberweis", None, "oberweis"),
    ("Great Harvest", None, "great_harvest"),
    ("George Webb Restaurant", None, "george_webb"),
    ("Papa Johns Pizza", None, "papa_johns"),
    ("Bob Evans Restaurants", None, "bob_evans"),
    # Chicago's Green Mill jazz club is not the Green Mill restaurant chain
    ("Green Mill", "greenmilljazz.com", None),
    ("Green Mill Restaurant & Bar", None, "green_mill"),
    # A common surname alone stays out of the table; the place's own web
    # host still finds the chain
    ("Casey's", None, None),
    ("Casey's", "www.caseys.com", "caseys"),
    ("Perkins", "stores.perkinsrestaurants.com", "perkins"),
    # Normalization
    ("McDonald’s", None, "mcdonalds"),
    ("MCDONALDS", None, "mcdonalds"),
    ("ＫＦＣ", None, "kfc"),
    ("Café Rio", None, "cafe_rio"),
    ("Fogo de Chão", None, "fogo_de_chao"),
    ("Cheesecake Factory", None, "cheesecake_factory"),
    ("Chick fil A", None, "chick_fil_a"),
    ("Chickfila", None, "chick_fil_a"),
    ("Wing Stop", None, "wingstop"),
    # Branch suffixes
    ("McDonald's - Times Square", None, "mcdonalds"),
    ("Starbucks (Times Sq)", None, "starbucks"),
    ("麥當勞（時代廣場店）", None, "mcdonalds"),
    ("Taco Bell Cantina", None, "taco_bell"),
    # Precision: generic or single-token names never prefix-match
    ("Jack's Bar", None, None),
    ("Subway Station Cafe", None, None),
    ("BBQ Chicken", None, None),
    ("Pizza", None, None),
    ("", None, None),
    (42, None, None),
    # Hosts
    ("Chipotle", "www.chipotle.com", "chipotle"),
    ("Starbucks", "www.mcdonalds.com", None),
    ("Store #1234", "restaurants.subway.com", "subway"),
    (None, "WWW.STARBUCKS.COM.", "starbucks"),
    (None, "notchipotle.com", None),
    (None, "chipotle.com.evil.example", None),
    (None, "chipotlé.com", None),
    (None, "xn--chipotl-dya.com", None),
    (None, "chipotle.com:443", None),
    (None, "https://chipotle.com/", None),
    ("www.starbucks.com", None, None),
])
def test_match_chain_table(name, url_host, expected):
    assert rl.match_chain(name, url_host) == expected


# Found by the 2026-10-24 audit: a hosting placeholder, a parked domain, and
# sites of unrelated businesses that share a chain's name. Anyone can put a
# "nutrition" page on them, so they must never be official.
NOT_THE_CHAINS_DOMAINS = (
    "gongchausa.com",        # Nexcess placeholder, wrong TLS certificate
    "goldenkrustbakery.com",  # parked
    "chickenexpress.com",    # not Chicken Express's site (chickene.com is)
    "mimiscafes.com",        # a single cafe in Wilmington, Illinois
    "greenmilljazz.com",     # the Green Mill jazz club, Chicago
    "friendlys.com",         # Dairy Farmers of America's grocery ice cream
)


@pytest.mark.parametrize("domain", NOT_THE_CHAINS_DOMAINS)
def test_lapsed_and_unrelated_domains_stay_out(domain):
    for c in CHAINS:
        assert domain not in c["domains"], (c["key"], domain)
    assert rl.match_chain(None, "www." + domain) is None


def test_audit_fixes_map_to_the_right_chain():
    assert rl.match_chain(None, "www.gong-cha.com") == "gong_cha"
    assert rl.match_chain(None, "locations.goldenkrust.com") == "golden_krust"
    assert rl.match_chain(None, "www.mrsfieldsstores.com") == "mrs_fields"
    assert rl.match_chain(None, "locations.jollibeeusa.com") == "jollibee"
    assert rl.match_chain(None, "locations.friendlysrestaurants.com") == "friendlys"


def test_every_domain_and_subdomain_maps_to_its_chain():
    for c in CHAINS:
        for d in c["domains"]:
            assert rl.match_chain(None, d) == c["key"], d
            assert rl.match_chain(None, "www." + d) == c["key"], d
            assert rl.is_chain_host("nutrition." + d, c["key"]), d
            assert not rl.match_chain(None, "x" + d), d
            assert not rl.is_chain_host(d + ".evil.example", c["key"]), d


def test_is_chain_host_is_per_chain():
    assert rl.is_chain_host("www.chipotle.com", "chipotle")
    assert not rl.is_chain_host("www.chipotle.com", "starbucks")
    assert not rl.is_chain_host("www.chipotle.com", "no_such_chain")
    assert not rl.is_chain_host(None, "chipotle")


def test_chain_by_key():
    assert rl.chain_by_key("chipotle")["name"] == "Chipotle"
    assert rl.chain_by_key("CHIPOTLE") is None
    assert rl.chain_by_key(None) is None
