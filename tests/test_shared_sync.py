"""Drift gate: the generated shared bindings must match shared/ sources.

scripts/sync_shared.py generates shared_generated.py (server) and
app/lib/core/shared_generated.dart (mobile app) from shared/prompts/*.txt
and shared/constants.json. Editing any of those without regenerating —
or hand-editing a generated file — fails here AND in the app's suite.
"""
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


def test_shared_bindings_are_in_sync():
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "sync_shared.py"), "--check"],
        capture_output=True, text=True, timeout=60,
    )
    assert proc.returncode == 0, f"stale shared bindings:\n{proc.stdout}{proc.stderr}"


def test_config_prompts_come_from_shared():
    import config
    import shared_generated

    assert config.TEXT_HANDLER_PROMPT == shared_generated.TEXT_HANDLER_PROMPT_TEMPLATE
    base = config.FOOD_DETECTION_PROMPT
    marker = "\n\nUser's Dietary Profile / Cultural Context:"
    if marker in base:
        base = base.split(marker)[0]
    assert base == shared_generated.FOOD_DETECTION_PROMPT_RAW


def test_prompt_admits_order_screenshots_and_nutrition_labels():
    """A calorie tracker logs what was EATEN, not only what was photographed:
    takeout order screenshots and nutrition labels are evidence of a meal
    (user request 2026-07-27). Both sides read this from shared/, so pinning
    it here pins the app too."""
    import config
    p = config.FOOD_DETECTION_PROMPT
    for phrase in ["TEXTUAL EVIDENCE", "order confirmation", "NUTRITION LABEL",
                   "meal_description"]:
        assert phrase in p, phrase


def test_prompt_refuses_meals_without_evidence_of_eating():
    """The counterweight: a phantom meal corrupts the log worse than a
    missing one, so menus/ads/recipes/social feeds must stay is_food false."""
    import config
    p = config.FOOD_DETECTION_PROMPT
    for phrase in ["menus", "adverts", "recipes", "social feed",
                   "cancelled order", "phantom meal"]:
        assert phrase in p, phrase


# ─── The server reads the shared values, not copies of them ────────────
#
# shared/constants.json is the single source of truth: an edit plus
# sync_shared.py changes the app, and the server must follow. The mismatch
# threshold, the magnitude clamp and the captured-at window are contracts
# both sides apply to the same data, so a server left on an old literal
# would produce different numbers from the app with nothing failing.

_SERVER_DEFAULTS = [
    # (module, attribute, env override or None, shared_generated name)
    ("telegram_bot", "NL_MAX_ACTIONS", None, "NL_MAX_ACTIONS"),
    ("telegram_bot", "TEXT_EDIT_WINDOW_DAYS", "TEXT_EDIT_WINDOW_DAYS",
     "TEXT_EDIT_WINDOW_DAYS_DEFAULT"),
    ("telegram_bot", "CAPTURED_AT_MAX_AGE_DAYS", "CAPTURED_AT_MAX_AGE_DAYS",
     "CAPTURED_AT_MAX_AGE_DAYS_DEFAULT"),
    ("telegram_bot", "GEMINI_ANALYSIS_MAX_ATTEMPTS",
     "GEMINI_ANALYSIS_MAX_ATTEMPTS", "GEMINI_ANALYSIS_MAX_ATTEMPTS"),
    ("telegram_bot", "GEMINI_RETRY_MAX_DELAY_SECONDS",
     "GEMINI_RETRY_MAX_DELAY_SECONDS", "GEMINI_RETRY_DELAY_CAP_SECONDS"),
    ("config", "GEMINI_MODEL", "GEMINI_MODEL", "GEMINI_MODEL_DEFAULT"),
]


@pytest.mark.parametrize("module_name,attr,env,shared_name", _SERVER_DEFAULTS,
                         ids=[row[1] for row in _SERVER_DEFAULTS])
def test_server_defaults_equal_the_shared_constants(module_name, attr, env,
                                                    shared_name):
    import importlib
    import os

    import shared_generated

    if env and os.environ.get(env) is not None:
        pytest.skip(f"{env} is set here, so the module holds the override")
    module = importlib.import_module(module_name)
    assert getattr(module, attr) == getattr(shared_generated, shared_name)


def test_photo_normalize_uses_the_shared_size_and_quality():
    import io

    from PIL import Image

    import shared_generated as sg
    import telegram_bot

    src = Image.new("RGB", (4000, 3000), (200, 120, 80))
    buf = io.BytesIO()
    src.save(buf, format="JPEG")
    out = Image.open(io.BytesIO(
        telegram_bot._normalize_photo_for_analysis(buf.getvalue())))
    assert max(out.size) == sg.NORMALIZE_MAX_DIMENSION_PX
    # Same quantization tables as a reference encode at the shared quality.
    ref = io.BytesIO()
    out.convert("RGB").save(ref, format="JPEG",
                            quality=sg.NORMALIZE_JPEG_QUALITY)
    assert out.quantization == Image.open(ref).quantization


def test_captured_at_future_window_is_the_shared_one(monkeypatch):
    from datetime import datetime, timedelta

    import database
    import shared_generated as sg
    import telegram_bot

    now = datetime(2026, 7, 15, 12, 0, 0)
    monkeypatch.setattr(database, "user_local_now", lambda *a, **k: now)
    edge = now + timedelta(seconds=sg.CAPTURED_AT_MAX_FUTURE_SECONDS)
    fmt = "%Y-%m-%d %H:%M:%S"
    assert telegram_bot._parse_captured_at(edge.strftime(fmt)) == edge
    late = edge + timedelta(seconds=1)
    assert telegram_bot._parse_captured_at(late.strftime(fmt)) is None


def test_calorie_clamp_and_mismatch_threshold_are_the_shared_ones():
    import shared_generated as sg
    import utils

    limit = sg.CALORIE_MAGNITUDE_LIMIT
    assert utils.safe_number(limit - 1, default=None) == limit - 1
    assert utils.safe_number(limit, default=None) is None
    assert utils.safe_number(-limit, default=None) is None

    def meal(total, items):
        return {"total_calories": total,
                "food_items": [{"estimated_calories": items}]}

    # Small meals: the absolute floor decides (exactly the floor is fine).
    floor = sg.MEAL_MISMATCH_MIN_KCAL
    assert utils.meal_calorie_mismatch(meal(100 + floor, 100)) is None
    assert utils.meal_calorie_mismatch(meal(100 + floor + 1, 100)) == 100
    # Large meals: the percentage of the larger number decides.
    big = 10_000
    gap = sg.MEAL_MISMATCH_PCT * big
    assert utils.meal_calorie_mismatch(meal(big, big - gap)) is None
    assert utils.meal_calorie_mismatch(meal(big, big - gap - 1)) == int(
        big - gap - 1)
