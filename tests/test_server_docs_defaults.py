"""The restaurant-lookup knob defaults an owner reads are the code's.

docs/SERVER_DEPLOY.md (the knob table and the sentence above it) and
.env.example each state a default for the CLAUDE_LOOKUP_* knobs. An owner
sets up a server from those two files, not from the code, so a default
that changes in claude_analyzer.py or lookup_jobs.py must change there
too. These tests fail when one side moves without the other.
"""
import os
import re

import pytest

import claude_analyzer
import lookup_jobs

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# knob -> the default the code uses, as the two files print it
CODE_DEFAULTS = {
    "CLAUDE_LOOKUP_MODEL": claude_analyzer.LOOKUP_MODEL_DEFAULT,
    "CLAUDE_LOOKUP_TIMEOUT_SECONDS": str(
        claude_analyzer.LOOKUP_TIMEOUT_SECONDS_DEFAULT),
    "CLAUDE_LOOKUP_INIT_SECONDS": str(
        claude_analyzer.LOOKUP_INIT_DEADLINE_SECONDS),
    "CLAUDE_LOOKUP_DAILY_CAP": str(lookup_jobs.DAILY_CAP_DEFAULT),
    "CLAUDE_LOOKUP_KEY_SOURCE": ",".join(
        claude_analyzer.LOOKUP_KEY_SOURCES_DEFAULT),
}


def _read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def _deploy_table():
    """{knob: (default cell, meaning cell)} from SERVER_DEPLOY.md."""
    rows = {}
    for line in _read("docs", "SERVER_DEPLOY.md").splitlines():
        m = re.match(r"^\| `(CLAUDE_LOOKUP_[A-Z_]+)` \| ([^|]+) \| (.*) \|$",
                     line)
        if m:
            assert m.group(1) not in rows, "knob listed twice: " + m.group(1)
            rows[m.group(1)] = (m.group(2).strip().strip("`"), m.group(3))
    return rows


def _env_example_lines():
    """{knob: its comment} from the commented knob lines of .env.example."""
    rows = {}
    for line in _read(".env.example").splitlines():
        m = re.match(r"^# (CLAUDE_LOOKUP_[A-Z_]+)=\s*#\s*(.*)$", line)
        if m:
            assert m.group(1) not in rows, "knob listed twice: " + m.group(1)
            rows[m.group(1)] = m.group(2)
    return rows


def _clamp(fn, monkeypatch, knob):
    """(lowest, highest) value [fn] returns for [knob]."""
    monkeypatch.setenv(knob, "-999999")
    low = fn()
    monkeypatch.setenv(knob, "999999")
    return low, fn()


def test_both_files_list_every_lookup_knob():
    knobs = set(CODE_DEFAULTS) | {"CLAUDE_LOOKUP_ENABLED"}
    assert set(_deploy_table()) == knobs
    assert set(_env_example_lines()) == knobs


@pytest.mark.parametrize("knob", sorted(CODE_DEFAULTS))
def test_deploy_guide_states_the_code_default(knob):
    assert _deploy_table()[knob][0] == CODE_DEFAULTS[knob]


def test_deploy_guide_says_the_endpoints_are_off_by_default(monkeypatch):
    monkeypatch.delenv("CLAUDE_LOOKUP_ENABLED", raising=False)
    assert lookup_jobs.is_enabled() is False
    assert _deploy_table()["CLAUDE_LOOKUP_ENABLED"][0] == "off"
    assert "(default off" in _env_example_lines()["CLAUDE_LOOKUP_ENABLED"]


def test_deploy_guide_states_the_code_clamps(monkeypatch):
    table = _deploy_table()
    low, high = _clamp(claude_analyzer.lookup_timeout_seconds, monkeypatch,
                       "CLAUDE_LOOKUP_TIMEOUT_SECONDS")
    assert "(%d–%d)" % (low, high) in table["CLAUDE_LOOKUP_TIMEOUT_SECONDS"][1]
    low, high = _clamp(claude_analyzer.lookup_init_deadline_seconds,
                       monkeypatch, "CLAUDE_LOOKUP_INIT_SECONDS")
    assert "(%d–%d)" % (low, high) in table["CLAUDE_LOOKUP_INIT_SECONDS"][1]


def test_deploy_guide_sentence_names_the_default_limit():
    text = " ".join(_read("docs", "SERVER_DEPLOY.md").split())
    assert ("the default limit is %d s"
            % claude_analyzer.LOOKUP_TIMEOUT_SECONDS_DEFAULT) in text


def test_env_example_states_the_code_defaults_and_clamps(monkeypatch):
    lines = _env_example_lines()
    assert lines["CLAUDE_LOOKUP_MODEL"].startswith(
        "%s (default)" % claude_analyzer.LOOKUP_MODEL_DEFAULT)
    for knob, fn in (
            ("CLAUDE_LOOKUP_TIMEOUT_SECONDS",
             claude_analyzer.lookup_timeout_seconds),
            ("CLAUDE_LOOKUP_INIT_SECONDS",
             claude_analyzer.lookup_init_deadline_seconds),
            ("CLAUDE_LOOKUP_DAILY_CAP", lookup_jobs.daily_cap)):
        low, high = _clamp(fn, monkeypatch, knob)
        assert ("(%s, clamp %d..%d)" % (CODE_DEFAULTS[knob], low, high)
                in lines[knob]), knob
    assert ("(%s)" % CODE_DEFAULTS["CLAUDE_LOOKUP_KEY_SOURCE"]
            in lines["CLAUDE_LOOKUP_KEY_SOURCE"])
