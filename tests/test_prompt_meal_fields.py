"""The photo prompt's MEAL CONTEXT fields (restaurant assist, stage R1).

The photo analysis gains four meal-level keys (estimate_confidence,
restaurant_context, portion_state, order_merchant) and three item-level
keys (brand, qty, unit). They are additive: nothing on the server reads
them, the app coerces them on read (app/lib/core/coerce.dart), and a
missing value means "unknown", which never triggers anything.

What these tests pin:
  * both platform bindings ask for every key, with the confidence rubric
    and the brand rules ("only on that item's own packaging", "never
    guess") that keep background text from posing as an item's brand;
  * the zh reply-language directive keeps the enums in English and copies
    brand / order_merchant as printed;
  * the leftover and text-intent prompts do not ask for them;
  * the server's recent-meal and leftover whitelists never forward them
    (nor the app-side assist/capture blocks) into a CLI prompt.
"""
import json
from pathlib import Path

import shared_generated
import utils

ROOT = Path(__file__).resolve().parent.parent
DART = ROOT / "app" / "lib" / "core" / "shared_generated.dart"

MEAL_KEYS = ("estimate_confidence", "restaurant_context", "portion_state",
             "order_merchant")
ITEM_KEYS = ("brand", "qty", "unit")
ENUMS = {
    "estimate_confidence": ("low", "medium", "high"),
    "restaurant_context": ("restaurant", "takeout", "packaged", "home",
                           "unknown"),
    "portion_state": ("whole", "partial", "shared", "buffet"),
}
NEW_KEYS = MEAL_KEYS + ITEM_KEYS

PROMPT = shared_generated.FOOD_DETECTION_PROMPT_RAW
# Phrase checks run on the whitespace-collapsed text, so rewrapping the
# prompt's lines never fails them.
FLAT = " ".join(PROMPT.split())


def _example():
    """The JSON example the prompt shows for a food photo."""
    marker = "If the image DOES contain food, respond with a JSON object like this:\n"
    start = PROMPT.index(marker) + len(marker)
    end = PROMPT.index("\n}\n", start) + 2
    return json.loads(PROMPT[start:end])


def test_the_example_carries_every_new_key_with_a_listed_value():
    ex = _example()
    for key in MEAL_KEYS:
        assert key in ex, key
    for key, values in ENUMS.items():
        assert ex[key] in values, key
    assert ex["order_merchant"] == ""
    for item in ex["food_items"]:
        for key in ITEM_KEYS:
            assert key in item, key
        # The example must not teach brand-hallucination: a home-style
        # dish carries no brand.
        assert item["brand"] == ""
        assert item["qty"] == 1
    # The leftover key stays leftover-only.
    assert "confidence" not in ex


def test_every_enum_value_is_spelled_out_in_the_prompt():
    for key, values in ENUMS.items():
        assert f"{key}:" in PROMPT, key
        for v in values:
            assert f'"{v}"' in PROMPT, (key, v)


def test_confidence_rubric_ties_to_the_evidence_ladder():
    section = PROMPT[PROMPT.index("MEAL CONTEXT"):]
    high = section.index('"high":')
    medium = section.index('"medium":')
    low = section.index('"low":')
    assert high < medium < low
    assert "nutrition label" in section[high:medium]
    assert "printed weight" in section[high:medium]
    assert "Priority 1-3" in section[high:medium]
    assert "scale reference" in section[medium:low]
    assert "hidden" in section[low:low + 200]
    # The fields describe, they never steer the estimate.
    assert "never change how you estimate calories" in FLAT


def test_brand_rules_refuse_background_text_and_guessing():
    lower = FLAT.lower()
    assert "only on that item's own packaging" in lower
    assert "never guess" in lower
    for source in ("menus", "signs", "adverts", "another item"):
        assert source in FLAT, source
    # order_merchant comes only from a receipt or order screen.
    om = FLAT[FLAT.index("order_merchant:"):]
    assert "receipt" in om[:200] and "order screen" in om[:200]


def test_qty_keeps_item_numbers_as_totals():
    # A count must not turn per-line calories into per-unit calories: every
    # total in the app sums estimated_calories as-is.
    q = FLAT[FLAT.index("qty:"):]
    assert "TOTAL for all of them" in q[:200]


def test_the_dart_binding_carries_the_same_fields():
    dart = DART.read_text(encoding="utf-8")
    for key in NEW_KEYS:
        assert f'"{key}"' in dart, key
    assert "only on that item's own packaging" in " ".join(dart.split()).lower()


def test_zh_directive_names_the_enums_and_the_printed_fields():
    d = shared_generated.REPLY_LANGUAGE_DIRECTIVE_ZH
    for key in ("estimate_confidence", "restaurant_context", "portion_state"):
        assert key in d, key
    assert "brand and order_merchant are copied exactly as printed" in d
    # The leftover carve-out the auto-leftover match depends on survives.
    assert "copied exactly as written there" in d


def test_leftover_and_text_prompts_do_not_ask_for_them():
    for template in (shared_generated.LEFTOVER_PROMPT_TEMPLATE,
                     shared_generated.TEXT_HANDLER_PROMPT_TEMPLATE):
        for key in ("estimate_confidence", "restaurant_context",
                    "portion_state", "order_merchant"):
            assert key not in template, key


RICH = {
    "time": "12:30 PM",
    "meal_description": "Burrito bowl",
    "total_calories": 900,
    "total_protein_g": 40,
    "total_carbs_g": 90,
    "total_fat_g": 35,
    "estimate_confidence": "low",
    "restaurant_context": "restaurant",
    "portion_state": "whole",
    "order_merchant": "Chipotle",
    "assist": {"v": 2, "status": "applied", "chain_key": "chipotle"},
    "capture": {"device": "meta_glasses", "has_gps": True},
    "food_items": [{
        "name": "Burrito bowl (~600 g)", "estimated_calories": 900,
        "brand": "Chipotle", "qty": 1, "unit": "bowl", "published": True,
    }],
}

FORBIDDEN = NEW_KEYS + ("assist", "capture", "published", "Chipotle")


def _assert_clean(obj):
    text = json.dumps(obj, ensure_ascii=False)
    for word in FORBIDDEN:
        assert word not in text, word


def test_recent_meals_whitelist_never_forwards_the_new_keys():
    compacts = utils.compact_recent_meals([RICH])
    assert compacts and compacts[0]["food_items"][0]["name"].startswith(
        "Burrito bowl")
    _assert_clean(compacts)
    _assert_clean(utils.build_recent_meals_block(compacts))


def test_leftover_original_whitelist_never_forwards_the_new_keys():
    out = utils.compact_leftover_original(json.dumps(RICH))
    assert out is not None and "Burrito bowl" in out
    _assert_clean(json.loads(out))
