"""Shared helpers for the restaurant-lookup server tests (R3a/R3b).

found_chipotle.jsonl is SYNTHETIC: its init line is the event the
installed claude 2.1.233 really printed for build_lookup_argv (offline
probe, 2026-10-23), but the WebSearch result shape ({query, results:
[{tool_use_id, content: [{title, url}]} | str]} plus the "Links: [...]"
text) is inferred, not recorded. scripts/lookup_smoke.py --record on the
VM writes a redacted real stream; drop it in next to this one to pin
the real shape.
"""
import json
import os
import sys
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"
STREAMS = FIXTURES / "lookup_streams"


def stream(name):
    return [json.loads(line) for line in
            (STREAMS / name).read_text(encoding="utf-8").splitlines()
            if line.strip()]


INIT_OK = stream("init_ok.jsonl")[0]
FOUND = stream("found_chipotle.jsonl")

# The same rows as R2a's shared/chains/us_chains.json for these two keys
# (names included), so a test that stubs the table and R2a's composer,
# which reads the real one, agree once both are on the path.
CHAINS = {
    "chipotle": {"name": "Chipotle", "domains": ["chipotle.com"]},
    "panda_express": {"name": "Panda Express",
                      "domains": ["pandaexpress.com"]},
}

REQUEST_BODY = {
    "items": [{"name": "Chicken burrito bowl (~500 g)", "qty": 1,
               "unit": "bowl", "brand": "Chipotle"}],
    "order_merchant": "",
    "chains": [{"key": "chipotle", "name": "Chipotle",
                "size": "20_plus"}],
    "country": "US",
    "backend": "claude",
}


def init_with(**changes):
    event = dict(INIT_OK)
    for key, value in changes.items():
        if value is _DROP:
            event.pop(key, None)
        else:
            event[key] = value
    return event


_DROP = object()
DROP = _DROP


def make_cli(tmp_path, steps, exit_code=0, read_stdin=True, name="claude"):
    """An executable fake CLI in tmp_path; returns (path, record_path)."""
    scenario = tmp_path / f"{name}_scenario.json"
    scenario.write_text(json.dumps(
        {"steps": steps, "exit": exit_code, "read_stdin": read_stdin}))
    record = tmp_path / f"{name}_record.json"
    cli = tmp_path / name
    cli.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        f"sys.path.insert(0, {str(FIXTURES)!r})\n"
        "import fake_claude_cli\n"
        f"fake_claude_cli.main({str(scenario)!r}, {str(record)!r}, "
        "sys.argv[1:])\n")
    cli.chmod(0o755)
    return str(cli), record


def lines(events):
    return [{"line": e} for e in events]


def configure(monkeypatch, cli_path):
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "1")
    monkeypatch.setenv("CLAUDE_ANALYZER_BIN", cli_path)
    # config.py loads the developer's .env into this process, and the fake
    # CLI records its environment to a temp file: a real token must never
    # be the one it records. Tests that need another value set it after.
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "fake-oauth-for-tests")
    for knob in ("CLAUDE_LOOKUP_MODEL", "CLAUDE_LOOKUP_TIMEOUT_SECONDS",
                 "CLAUDE_LOOKUP_INIT_SECONDS",
                 "CLAUDE_LOOKUP_KEY_SOURCE", "CLAUDE_ANALYZER_EXTRA_FLAGS"):
        monkeypatch.delenv(knob, raising=False)


def use_chain_table(monkeypatch, table=None):
    import lookup_contract
    monkeypatch.setattr(lookup_contract, "chain_table",
                        lambda: dict(table if table is not None else CHAINS))


def read_record(record):
    return json.loads(Path(record).read_text())


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:  # pragma: no cover - not ours, but alive
        return True
    return True
