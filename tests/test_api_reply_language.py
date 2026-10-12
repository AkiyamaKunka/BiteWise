"""The optional "lang" field on the app-facing analysis endpoints.

A Chinese-UI app sends lang="zh" so new meals come back with Chinese dish
names and ingredient lines instead of English ones. The contract:

  * zh / zh-Hans / zh-CN (any case) append the ONE shared directive
    (shared/constants.json → REPLY_LANGUAGE_DIRECTIVE_ZH) exactly once, at
    the end of the prompt the server hands the analyzer;
  * no lang, "en", any other tag, or a non-string → the prompt is
    BYTE-IDENTICAL to what an old app gets (and never a 400);
  * the directive is server text, not profile text: API_PROFILE_MAX_CHARS
    still bounds only the caller's profile;
  * /api/analyze_leftover ignores lang — its reply items are matched back to
    the original meal by exact name, which a translation would break.
"""
import base64
import json

import pytest

import claude_analyzer
import shared_generated
import telegram_bot

DIRECTIVE = shared_generated.REPLY_LANGUAGE_DIRECTIVE_ZH
ANALYSIS = {"is_food": True, "total_calories": 450, "meal_description": "Salad"}
H = {"X-API-Key": "secret-key"}
IMG = base64.b64encode(b"jpegdata").decode()


def _photo_prompt(client, monkeypatch, **fields):
    monkeypatch.setattr(claude_analyzer, "is_configured", lambda: True)
    seen = {}

    def fake(image_bytes, prompt=None, allow_file_fallback=True,
             backend="claude", raise_on_busy=False, **kw):
        seen["prompt"] = prompt
        return dict(ANALYSIS)

    monkeypatch.setattr(claude_analyzer, "analyze_food_photo", fake)
    resp = client.http.post("/api/analyze_photo", headers=H,
                            json={"image_b64": IMG, **fields})
    assert resp.status_code == 200, resp.get_json()
    return seen["prompt"]


def _text_prompt(client, monkeypatch, **fields):
    monkeypatch.setattr(claude_analyzer, "is_configured", lambda: True)
    seen = {}

    def fake(prompt, backend="claude", raise_on_busy=False, **kw):
        seen["prompt"] = prompt
        return {"result": {"intent": "chat", "reply": "hi"}}

    monkeypatch.setattr(claude_analyzer, "analyze_text_prompt", fake)
    resp = client.http.post("/api/text_intent", headers=H,
                            json={"prompt": "had a bowl of noodles", **fields})
    assert resp.status_code == 200, resp.get_json()
    return seen["prompt"]


RECENT = [{"time": "12:30", "meal_description": "Lunch",
           "total_calories": 600,
           "food_items": [{"name": "Steamed rice (~150 g)",
                           "estimated_calories": 200}]}]


def test_directive_is_one_fixed_server_sentence_both_sides_share():
    assert "Simplified Chinese" in DIRECTIVE and "简体中文" in DIRECTIVE
    # The auto-leftover carve-out keeps exact-name matching working.
    assert "copied exactly" in DIRECTIVE
    assert shared_generated.CONSTANTS["reply_language_directive_zh"] == DIRECTIVE


@pytest.mark.parametrize("lang", ["zh", "zh-Hans", "zh-CN", "ZH-cn", " zh "])
@pytest.mark.parametrize("profile", [None, "Cantonese home cooking"])
def test_photo_zh_appends_the_directive_once_at_the_end(
        client, monkeypatch, lang, profile):
    extra = {"dietary_profile": profile} if profile else {}
    base = _photo_prompt(client, monkeypatch, **extra)
    zh = _photo_prompt(client, monkeypatch, lang=lang, **extra)
    expected_base = base if base is not None else telegram_bot.FOOD_DETECTION_PROMPT
    assert zh == f"{expected_base}\n\n{DIRECTIVE}\n"
    assert zh.count(DIRECTIVE) == 1


def test_photo_zh_goes_after_the_recent_meals_block(client, monkeypatch):
    base = _photo_prompt(client, monkeypatch, recent_meals=RECENT)
    zh = _photo_prompt(client, monkeypatch, recent_meals=RECENT, lang="zh")
    assert "RECENT MEALS" in base
    assert zh == f"{base}\n\n{DIRECTIVE}\n"
    assert zh.count(DIRECTIVE) == 1


@pytest.mark.parametrize("lang", ["en", "en-US", "ja", "zh-TW", "", 123,
                                  None, ["zh"], {"zh": 1}, True])
@pytest.mark.parametrize("fields", [
    {}, {"dietary_profile": "vegetarian"}, {"recent_meals": RECENT}])
def test_photo_other_or_junk_lang_is_byte_identical(
        client, monkeypatch, lang, fields):
    before = _photo_prompt(client, monkeypatch, **fields)
    after = _photo_prompt(client, monkeypatch, lang=lang, **fields)
    assert after == before
    if not fields:
        # An old app with no profile gets the analyzer's own default.
        assert after is None
    assert after is None or DIRECTIVE not in after


@pytest.mark.parametrize("lang", ["zh", "zh-Hans", "zh-cn"])
def test_text_intent_zh_appends_the_directive_once(client, monkeypatch, lang):
    base = _text_prompt(client, monkeypatch)
    zh = _text_prompt(client, monkeypatch, lang=lang)
    assert base == "had a bowl of noodles"
    assert zh == f"{base}\n\n{DIRECTIVE}\n"
    assert zh.count(DIRECTIVE) == 1


@pytest.mark.parametrize("lang", ["en", 123, None, ["zh"], "chinese"])
def test_text_intent_other_or_junk_lang_is_byte_identical(
        client, monkeypatch, lang):
    assert _text_prompt(client, monkeypatch, lang=lang) == "had a bowl of noodles"


def test_text_intent_size_cap_bounds_the_callers_text_only(client, monkeypatch):
    monkeypatch.setattr(telegram_bot, "API_TEXT_MAX_CHARS", 1000)
    monkeypatch.setattr(claude_analyzer, "is_configured", lambda: True)
    seen = {}
    monkeypatch.setattr(claude_analyzer, "analyze_text_prompt",
                        lambda p, backend="claude", raise_on_busy=False, **kw:
                        seen.setdefault("p", p) and {"result": {}})
    exact = "x" * 1000
    resp = client.http.post("/api/text_intent", headers=H,
                            json={"prompt": exact, "lang": "zh"})
    assert resp.status_code == 200
    assert seen["p"] == f"{exact}\n\n{DIRECTIVE}\n"


def test_profile_limit_is_unaffected_by_the_directive(client, monkeypatch):
    monkeypatch.setattr(telegram_bot, "API_PROFILE_MAX_CHARS", 10)
    # Exactly at the cap still passes WITH the directive appended.
    zh = _photo_prompt(client, monkeypatch, dietary_profile="y" * 10, lang="zh")
    assert "y" * 10 in zh and zh.endswith(f"\n\n{DIRECTIVE}\n")
    # One over is still a 413, lang or not.
    for extra in ({}, {"lang": "zh"}):
        resp = client.http.post("/api/analyze_photo", headers=H,
                                json={"image_b64": IMG,
                                      "dietary_profile": "y" * 11, **extra})
        assert resp.status_code == 413


def test_leftover_ignores_lang_so_name_matching_survives(client, monkeypatch):
    monkeypatch.setattr(claude_analyzer, "is_configured", lambda: True)
    seen = []

    def fake(image_bytes, prompt, backend="claude", raise_on_busy=False, **kw):
        seen.append(prompt)
        return {"same_meal": True, "confidence": 0.9, "leftover_fraction": 0.4,
                "items": [{"name": "Steamed rice", "left_fraction": 1.0}]}

    monkeypatch.setattr(claude_analyzer, "analyze_leftover_photo", fake)
    original = json.dumps({"meal_description": "Lunch", "total_calories": 300,
                           "food_items": [{"name": "Steamed rice",
                                           "estimated_calories": 300}]})
    for extra in ({}, {"lang": "zh"}):
        resp = client.http.post("/api/analyze_leftover", headers=H,
                                json={"image_b64": IMG,
                                      "original_analysis": original, **extra})
        assert resp.status_code == 200
    assert seen[0] == seen[1]
    assert DIRECTIVE not in seen[1]
