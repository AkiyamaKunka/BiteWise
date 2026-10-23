"""scripts/lookup_smoke.py — the owner's on-VM check of the lookup runner.
It must report the guard facts and the cited DOMAINS, and never print or
record a secret."""
import importlib.util
import io
import json
import os
import stat
from pathlib import Path

import pytest

from lookup_fakes import (FOUND, INIT_OK, configure, init_with, lines,
                          make_cli, read_record, use_chain_table)

SMOKE_PATH = Path(__file__).resolve().parent.parent / "scripts" / "lookup_smoke.py"
spec = importlib.util.spec_from_file_location("lookup_smoke", SMOKE_PATH)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)

SECRETS = {
    "CLAUDE_CODE_OAUTH_TOKEN": "sk-test-oauth-SENTINEL-000111",
    "ANDROID_API_KEY": "upload-SENTINEL-222333",
    "GLM_PLAN_KEY": "glm-SENTINEL-444555",
}


@pytest.fixture
def env(monkeypatch):
    for key, value in SECRETS.items():
        monkeypatch.setenv(key, value)
    use_chain_table(monkeypatch)


def _main(monkeypatch, tmp_path, steps, argv=(), exit_code=0):
    cli, record = make_cli(tmp_path, steps, exit_code=exit_code)
    configure(monkeypatch, cli)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN",
                       SECRETS["CLAUDE_CODE_OAUTH_TOKEN"])
    buf = io.StringIO()
    code = smoke.main(list(argv), out=buf)
    return code, buf.getvalue(), record


def test_init_only_reports_the_guard_facts_and_stops(env, monkeypatch, tmp_path):
    code, out, record = _main(monkeypatch, tmp_path, lines(FOUND),
                              ["--init-only"])
    assert code == 0
    assert "claude CLI        : 2.1.233" in out
    assert "init tools        : StructuredOutput, WebSearch" in out
    assert "apiKeySource      : none" in out
    assert "memory_paths      : absent" in out
    assert "guard             : pass" in out
    assert "status            : init_ok" in out
    assert "searches" not in out  # it stopped at the guard
    for value in SECRETS.values():
        assert value not in out
    # The sample request reached the CLI on stdin only.
    assert "chicken burrito bowl" in read_record(record)["stdin"]


def test_full_run_prints_domains_and_records_a_redacted_fixture(
        env, monkeypatch, tmp_path):
    # The CLI echoes the token somewhere in its output: it must not survive.
    events = json.loads(json.dumps(FOUND))
    events[1]["message"]["content"][0]["text"] = (
        "token " + SECRETS["CLAUDE_CODE_OAUTH_TOKEN"] + " home "
        + os.environ.get("HOME", "/nohome"))
    path = tmp_path / "rec.jsonl"
    code, out, _ = _main(monkeypatch, tmp_path, lines(events) + [
        {"line": "not json " + SECRETS["ANDROID_API_KEY"]}],
        ["--record", str(path)])
    assert code == 0, out
    assert "cited domains     : chipotle.com" in out
    assert "lookup            : found, chain=chipotle, matches=1, " \
           "source=chipotle.com (official_site)" in out
    assert "chipotle.com cited: yes" in out
    assert "nutrition-calculator" not in out  # domains, never URLs
    recorded = path.read_text()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    for value in SECRETS.values():
        assert value not in out and value not in recorded
    assert "<redacted-secret>" in recorded
    first = json.loads(recorded.splitlines()[0])
    assert first["session_id"] == "<redacted>" and first["cwd"] == "<redacted>"
    assert first["tools"] == ["StructuredOutput", "WebSearch"]


def test_guard_failure_exits_1_with_a_key_source_hint(env, monkeypatch, tmp_path):
    code, out, _ = _main(monkeypatch, tmp_path, [
        {"line": init_with(apiKeySource="/login managed key")}, {"sleep": 30}])
    assert code == 1
    assert "guard             : FAIL guard_fail:apiKeySource" in out
    assert "apiKeySource      : /login managed key" in out
    assert "CLAUDE_LOOKUP_KEY_SOURCE" in out


def test_failed_or_unusable_runs_exit_1(env, monkeypatch, tmp_path):
    code, out, _ = _main(monkeypatch, tmp_path, [{"line": INIT_OK}],
                         exit_code=1)
    assert code == 1 and "cli_error (no_result)" in out
    bad = [INIT_OK, {"type": "result", "is_error": False,
                     "structured_output": {"status": "weird"}}]
    sub = tmp_path / "b"
    sub.mkdir()
    code, out, _ = _main(monkeypatch, sub, lines(bad))
    assert code == 1 and "answer failed the section-5 shape" in out
    guard = tmp_path / "g"
    guard.mkdir()
    code, out, _ = _main(monkeypatch, guard, [
        {"line": init_with(tools=["WebSearch"])}], ["--init-only"])
    assert code == 1


def test_unconfigured_and_bad_model(env, monkeypatch, tmp_path):
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "0")
    buf = io.StringIO()
    assert smoke.main([], out=buf) == 2
    code, out, _ = _main(monkeypatch, tmp_path, lines(FOUND),
                         ["--model", "opus --x"])
    assert code == 2
    sub = tmp_path / "m"
    sub.mkdir()
    code, out, record = _main(monkeypatch, sub, lines(FOUND),
                              ["--model", "haiku", "--init-only"])
    assert code == 0 and "model             : haiku" in out
    assert read_record(record)["argv"][-1] == "haiku"


def test_sample_request_is_brand_only_without_the_table(monkeypatch):
    use_chain_table(monkeypatch, {})
    req = smoke.sample_request()
    assert req["chains"] == [] and req["items"][0]["brand"] == "Chipotle"
    use_chain_table(monkeypatch)
    assert smoke.sample_request()["chains"][0]["key"] == "chipotle"


def test_secret_values_and_redaction_units():
    environ = {"MY_API_KEY": "abcdefgh123", "SHORT_TOKEN": "abc",
               "PATH": "/usr/bin:/bin", "GARMIN_PASSWORD": "pw-123456789"}
    assert smoke.secret_values(environ) == ["pw-123456789", "abcdefgh123"]
    line = json.dumps({"uuid": "u1", "nested": [{"cwd": "/x"}],
                       "text": 'say "abcdefgh123" at /home/me/x'})
    red = json.loads(smoke.redact_line(line, ["abcdefgh123"], "/home/me"))
    assert red == {"uuid": "<redacted>", "nested": [{"cwd": "<redacted>"}],
                   "text": 'say "<redacted-secret>" at ~/x'}
    assert json.loads(smoke.redact_line("garbage", [])) == {
        "type": "_redacted_non_json_line"}


def test_cli_version_fallbacks(monkeypatch, tmp_path):
    def boom(*a, **kw):
        raise OSError("gone")

    monkeypatch.setattr(smoke.subprocess, "run", boom)
    assert smoke._cli_version("/nope") == "unknown"
    from types import SimpleNamespace
    monkeypatch.setattr(smoke.subprocess, "run",
                        lambda *a, **kw: SimpleNamespace(stdout=""))
    assert smoke._cli_version("/nope") == "unknown"
    monkeypatch.setattr(smoke.subprocess, "run",
                        lambda *a, **kw: SimpleNamespace(
                            stdout="2.1.233 (Claude Code)\n"))
    assert smoke._cli_version("/nope") == "2.1.233"
