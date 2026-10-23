"""The WebSearch-only restaurant-lookup runner (design stage R3a).

Every scenario runs a REAL subprocess (tests/fixtures/fake_claude_cli.py
behind an executable wrapper), because the properties under test are
process properties: what the child's argv and environment are, that a
bad init event gets the process group killed before another line is
consumed, and that a silent child cannot hold the CLI past its limit.
"""
import json
import logging
import threading
import time

import pytest

import claude_analyzer
import lookup_contract
from lookup_fakes import (DROP, FOUND, INIT_OK, configure, init_with, lines,
                          make_cli, pid_alive, read_record)

SCHEMA = lookup_contract.lookup_schema_json()
PROMPT = "Look up SENTINEL_DISH_7731 at SENTINEL_CHAIN_4410.\n<data>{}</data>"


def _run(monkeypatch, tmp_path, steps, **kw):
    cli, record = make_cli(tmp_path, steps, **{
        k: kw.pop(k) for k in ("exit_code", "read_stdin") if k in kw})
    configure(monkeypatch, cli)
    for knob, value in kw.pop("env", {}).items():
        monkeypatch.setenv(knob, value)
    run = claude_analyzer.lookup_restaurant(PROMPT, SCHEMA, **kw)
    return run, record


def _wait_dead(pid, seconds=3.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not pid_alive(pid):
            return True
        time.sleep(0.05)
    return False


# ─── the happy path ──────────────────────────────────────────────────
def test_found_stream_yields_structured_result_and_links(monkeypatch, tmp_path):
    run, record = _run(monkeypatch, tmp_path, lines(FOUND))
    assert run.status == "ok" and run.verdict == "ok"
    assert run.result["status"] == "found"
    assert run.result["chain_key"] == "chipotle"
    assert run.searches == 1
    assert run.started is True
    assert run.cited_urls == [
        "https://www.chipotle.com/nutrition-calculator",
        "https://www.chipotle.com/content/dam/chipotle/global/menu/"
        "nutrition/US-Nutrition-Facts.pdf",
    ]
    # Evidence is the search's prose — the grounding text for the app.
    assert "180 calories" in run.evidence[0]["text"]
    assert run.init["tools"] == ["StructuredOutput", "WebSearch"]
    assert run.init["apiKeySource"] == "none"
    assert run.init["claude_code_version"] == "2.1.233"
    # The prompt travelled on stdin, never argv.
    rec = read_record(record)
    assert rec["stdin"] == PROMPT
    assert all("SENTINEL" not in a for a in rec["argv"])


def test_urls_written_in_prose_never_become_cited_urls(monkeypatch, tmp_path):
    run, _ = _run(monkeypatch, tmp_path, lines(FOUND))
    joined = " ".join(run.cited_urls)
    assert "evil.example" not in joined
    assert "https://evil.example/x" in run.evidence[0]["text"]  # still prose


def test_text_links_are_used_when_the_structured_result_is_absent(
        monkeypatch, tmp_path):
    events = [dict(e) for e in FOUND]
    events[3] = {k: v for k, v in events[3].items() if k != "tool_use_result"}
    run, _ = _run(monkeypatch, tmp_path, lines(events))
    assert run.status == "ok"
    assert run.cited_urls[0] == "https://www.chipotle.com/nutrition-calculator"
    assert not any("evil.example" in u for u in run.cited_urls)
    text = run.evidence[0]["text"]
    # The query header and the CLI's reminder are not evidence.
    assert "Web search results for query" not in text
    assert "REMINDER" not in text
    assert "210 calories" in text


def test_structured_results_ignore_link_shaped_prose(monkeypatch, tmp_path):
    events = [json.loads(json.dumps(e)) for e in FOUND]
    events[3]["tool_use_result"]["results"].append(
        'Links: [{"title": "x", "url": "https://evil.example/forged"}]')
    run, _ = _run(monkeypatch, tmp_path, lines(events))
    assert "https://evil.example/forged" not in run.cited_urls


def test_result_text_is_parsed_when_structured_output_is_missing(
        monkeypatch, tmp_path):
    events = [dict(e) for e in FOUND]
    answer = events[-1]["structured_output"]
    events[-1] = {"type": "result", "subtype": "success", "is_error": False,
                  "result": "```json\n" + json.dumps(answer) + "\n```"}
    run, _ = _run(monkeypatch, tmp_path, lines(events))
    assert run.status == "ok"
    assert run.result == answer


@pytest.mark.parametrize("result_event,status,verdict", [
    ({"type": "result", "subtype": "success", "is_error": False,
      "result": "no json here"}, "bad_output", "bad_output"),
    ({"type": "result", "subtype": "success", "is_error": False,
      "result": "[1, 2]"}, "bad_output", "bad_output"),
    ({"type": "result", "subtype": "error_max_structured_output_retries",
      "is_error": True, "result": "x"},
     "cli_error", "error_max_structured_output_retries"),
    ({"type": "result", "subtype": "Weird Subtype!", "is_error": True},
     "cli_error", "is_error"),
    ({"type": "result", "is_error": True, "api_error_status": 429,
      "result": "usage limit"}, "plan_refused", "plan_refused"),
    ({"type": "result", "is_error": True,
      "result": "Fable 5 requires usage credits."},
     "plan_refused", "plan_refused"),
])
def test_result_envelope_outcomes(monkeypatch, tmp_path, result_event,
                                  status, verdict):
    run, _ = _run(monkeypatch, tmp_path,
                  lines([INIT_OK, result_event]))
    assert (run.status, run.verdict) == (status, verdict)
    assert run.result is None


def test_rate_limit_event_marks_an_error_result_as_plan_refused(
        monkeypatch, tmp_path):
    run, _ = _run(monkeypatch, tmp_path, lines([
        INIT_OK,
        {"type": "rate_limit_event",
         "rate_limit_info": {"status": "rejected"}},
        {"type": "result", "is_error": True, "result": "nope"},
    ]))
    assert run.status == "plan_refused"


def test_noise_lines_after_init_are_tolerated(monkeypatch, tmp_path):
    steps = [{"line": INIT_OK}, {"line": "not json"}, {"line": "[1]"},
             {"line": {"type": "system", "subtype": "api_retry"}},
             {"line": {"type": "user", "message": "odd"}},
             {"line": {"type": "assistant", "message": {"content": "x"}}}]
    steps += lines(FOUND[1:])
    run, _ = _run(monkeypatch, tmp_path, steps)
    assert run.status == "ok"


def test_exit_without_result_is_a_cli_error(monkeypatch, tmp_path):
    run, _ = _run(monkeypatch, tmp_path, lines(FOUND[:3]), exit_code=1)
    assert (run.status, run.verdict) == ("cli_error", "no_result")
    assert run.searches == 1


def test_exit_before_init_is_a_cli_error(monkeypatch, tmp_path):
    run, _ = _run(monkeypatch, tmp_path, [], exit_code=2)
    assert (run.status, run.verdict) == ("cli_error", "no_init")


# ─── the init guard ──────────────────────────────────────────────────
@pytest.mark.parametrize("init,field", [
    (init_with(tools=["StructuredOutput", "WebSearch", "Bash"]), "tools"),
    (init_with(tools=["WebSearch"]), "tools"),
    (init_with(tools=["StructuredOutput", "WebFetch"]), "tools"),
    (init_with(tools=["WebSearch", "WebSearch"]), "tools"),
    (init_with(tools=[{"name": "WebSearch"}, "StructuredOutput"]), "tools"),
    (init_with(tools=DROP), "tools"),
    (init_with(mcp_servers=[{"name": "zai", "status": "connected"}]),
     "mcp_servers"),
    (init_with(mcp_servers=DROP), "mcp_servers"),
    (init_with(plugins=[{"name": "p"}]), "plugins"),
    (init_with(permissionMode="default"), "permissionMode"),
    (init_with(memory_paths={"auto": "/home/x/.claude/memory/"}),
     "memory_paths"),
    (init_with(apiKeySource="ANTHROPIC_API_KEY"), "apiKeySource"),
    (init_with(apiKeySource=DROP), "apiKeySource"),
    (init_with(subtype="hook_started"), "not_init"),
    ({"type": "assistant", "message": {}}, "not_init"),
])
def test_init_guard_kills_on_any_mismatch(monkeypatch, tmp_path, init, field):
    steps = [{"line": init},
             {"line": {"type": "assistant", "message": {"content": [
                 {"type": "tool_use", "id": "t1", "name": "Bash",
                  "input": {"command": "cat .env"}}]}}},
             {"sleep": 30}]
    seen = []
    start = time.monotonic()
    run, record = _run(monkeypatch, tmp_path, steps, on_line=seen.append)
    assert time.monotonic() - start < 2.0
    assert (run.status, run.verdict) == ("guard_fail", f"guard_fail:{field}")
    # Nothing after the init line was consumed.
    assert run.lines_read == 1
    assert seen == []
    assert _wait_dead(read_record(record)["pid"])


def test_first_line_that_is_not_json_is_a_guard_failure(monkeypatch, tmp_path):
    run, _ = _run(monkeypatch, tmp_path,
                  [{"line": "Warning: something"}, {"sleep": 30}])
    assert run.verdict == "guard_fail:not_init"


def test_init_guard_unit_accepts_the_probed_event():
    assert claude_analyzer.lookup_init_verdict(INIT_OK) is None
    assert claude_analyzer.lookup_init_verdict(None) == "not_init"
    assert claude_analyzer.lookup_init_verdict(
        INIT_OK, key_sources=frozenset({"x"})) == "apiKeySource"


def test_key_source_override_admits_the_smoke_value(monkeypatch, tmp_path):
    steps = [{"line": init_with(apiKeySource="/login managed key")}]
    steps += lines(FOUND[1:])
    run, _ = _run(monkeypatch, tmp_path, steps, env={
        "CLAUDE_LOOKUP_KEY_SOURCE": "none, /login managed key"})
    assert run.status == "ok"
    monkeypatch.setenv("CLAUDE_LOOKUP_KEY_SOURCE", " , ")
    assert claude_analyzer.lookup_key_sources() == frozenset({"none"})


def test_unexpected_tool_use_mid_stream_is_killed(monkeypatch, tmp_path):
    steps = [{"line": INIT_OK},
             {"line": {"type": "assistant", "message": {"content": [
                 {"type": "tool_use", "id": "t9", "name": "WebFetch",
                  "input": {"url": "https://evil.example"}}]}}},
             {"line": {"type": "result", "is_error": False,
                       "structured_output": {"status": "found"}}},
             {"sleep": 30}]
    start = time.monotonic()
    run, record = _run(monkeypatch, tmp_path, steps)
    assert time.monotonic() - start < 2.0
    assert (run.status, run.verdict) == ("guard_fail", "guard_fail:tool_use")
    assert run.lines_read == 2
    assert _wait_dead(read_record(record)["pid"])


def test_silent_child_fails_the_init_deadline(monkeypatch, tmp_path):
    monkeypatch.setattr(claude_analyzer, "LOOKUP_INIT_DEADLINE_SECONDS", 1)
    start = time.monotonic()
    run, record = _run(monkeypatch, tmp_path, [{"sleep": 30}])
    assert time.monotonic() - start < 3.0
    assert (run.status, run.verdict) == ("guard_fail", "guard_fail:init_timeout")
    assert _wait_dead(read_record(record)["pid"])


def test_slow_run_hits_the_wall_clock_and_its_group_dies(monkeypatch, tmp_path):
    monkeypatch.setattr(claude_analyzer, "lookup_timeout_seconds", lambda: 1)
    pidfile = tmp_path / "grandchild.pid"
    steps = [{"line": INIT_OK},
             {"grandchild": 30, "pidfile": str(pidfile)},
             {"sleep": 30}]
    start = time.monotonic()
    run, record = _run(monkeypatch, tmp_path, steps)
    assert time.monotonic() - start < 4.0
    assert (run.status, run.verdict) == ("timeout", "timeout")
    assert _wait_dead(read_record(record)["pid"])
    # The whole process GROUP: a grandchild holding the pipe dies too.
    assert _wait_dead(int(pidfile.read_text()))


def test_stop_after_init_spends_nothing_past_the_guard(monkeypatch, tmp_path):
    seen = []
    run, _ = _run(monkeypatch, tmp_path, lines(FOUND),
                  stop_after_init=True, on_line=seen.append)
    assert (run.status, run.verdict) == ("init_ok", "init_ok")
    assert len(seen) == 1 and json.loads(seen[0])["subtype"] == "init"


def test_output_flood_is_cut_off(monkeypatch, tmp_path):
    monkeypatch.setattr(claude_analyzer, "LOOKUP_MAX_OUTPUT_BYTES", 4096)
    steps = [{"line": INIT_OK}, {"raw": "x" * 20000}, {"sleep": 30}]
    run, _ = _run(monkeypatch, tmp_path, steps)
    assert (run.status, run.verdict) == ("cli_error", "output_too_large")


def test_overlong_line_is_cut_off(monkeypatch, tmp_path):
    monkeypatch.setattr(claude_analyzer, "LOOKUP_MAX_LINE_BYTES", 1024)
    steps = [{"line": INIT_OK}, {"raw": "y" * 70000}, {"sleep": 30}]
    run, _ = _run(monkeypatch, tmp_path, steps)
    assert (run.status, run.verdict) == ("cli_error", "output_too_large")


# ─── argv and environment ────────────────────────────────────────────
def test_argv_is_pinned_exactly(monkeypatch, tmp_path):
    run, record = _run(monkeypatch, tmp_path, lines(FOUND))
    assert read_record(record)["argv"] == [
        "-p", "--safe-mode", "--output-format", "stream-json", "--verbose",
        "--tools", "WebSearch", "--allowedTools", "WebSearch",
        "--disallowedTools",
        "Bash,Read,Write,Edit,Glob,Grep,LS,WebFetch,NotebookEdit,Task,mcp__*",
        "--permission-mode", "dontAsk", "--strict-mcp-config",
        "--no-session-persistence", "--json-schema", SCHEMA,
        "--model", "sonnet",
    ]


def test_extra_flags_and_analyzer_model_never_reach_the_lookup(
        monkeypatch, tmp_path):
    cli, record = make_cli(tmp_path, lines(FOUND))
    configure(monkeypatch, cli)
    monkeypatch.setenv("CLAUDE_ANALYZER_EXTRA_FLAGS",
                       "--dangerously-skip-permissions --tools default")
    monkeypatch.setenv("CLAUDE_ANALYZER_MODEL", "opus")
    monkeypatch.setenv("CLAUDE_LOOKUP_MODEL", "haiku")
    claude_analyzer.lookup_restaurant(PROMPT, SCHEMA)
    argv = read_record(record)["argv"]
    assert "--dangerously-skip-permissions" not in argv
    assert argv.count("--tools") == 1
    assert argv[-2:] == ["--model", "haiku"]


@pytest.mark.parametrize("raw,expected", [
    (None, "sonnet"), ("", "sonnet"), ("haiku", "haiku"),
    ("claude-sonnet-5-5", "claude-sonnet-5-5"),
    ("opus --dangerously-skip-permissions", "sonnet"), ("a" * 80, "sonnet"),
])
def test_lookup_model_knob(monkeypatch, raw, expected):
    if raw is None:
        monkeypatch.delenv("CLAUDE_LOOKUP_MODEL", raising=False)
    else:
        monkeypatch.setenv("CLAUDE_LOOKUP_MODEL", raw)
    assert claude_analyzer.lookup_model() == expected


@pytest.mark.parametrize("raw,expected", [
    (None, 75), ("bad", 75), ("5", 20), ("9999", 300), ("90", 90)])
def test_lookup_timeout_knob(monkeypatch, raw, expected):
    if raw is None:
        monkeypatch.delenv("CLAUDE_LOOKUP_TIMEOUT_SECONDS", raising=False)
    else:
        monkeypatch.setenv("CLAUDE_LOOKUP_TIMEOUT_SECONDS", raw)
    assert claude_analyzer.lookup_timeout_seconds() == expected


SECRET_ENVS = {
    "ANDROID_API_KEY": "SENTINEL_UPLOAD_KEY_1234567",
    "GLM_PLAN_KEY": "SENTINEL_GLM_PLAN_KEY_99",
    "DOUBAO_PLAN_KEY": "SENTINEL_DOUBAO_KEY_77",
    "ANTHROPIC_API_KEY": "SENTINEL_ANTHROPIC_KEY_55",
    "GEMINI_API_KEY": "SENTINEL_GEMINI_KEY_33",
    "TELEGRAM_BOT_TOKEN": "SENTINEL_TG_TOKEN_11",
    "ANTHROPIC_BASE_URL": "https://sentinel.example",
}


def test_child_env_is_exactly_the_allowlist(monkeypatch):
    for key, value in SECRET_ENVS.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "oauth-test-value")
    monkeypatch.setenv("LANG", "en_US.UTF-8")
    env = claude_analyzer.lookup_env()
    assert set(env) == {"PATH", "HOME", "LANG", "CLAUDE_CODE_OAUTH_TOKEN",
                        "DISABLE_AUTOUPDATER",
                        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"}
    assert env["DISABLE_AUTOUPDATER"] == "1"
    monkeypatch.delenv("LANG")
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN")
    env = claude_analyzer.lookup_env()
    assert env["LANG"] == "C.UTF-8"
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in env


def test_child_process_never_sees_a_secret(monkeypatch, tmp_path):
    for key, value in SECRET_ENVS.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "oauth-test-value")
    run, record = _run(monkeypatch, tmp_path, lines(FOUND))
    rec = read_record(record)
    blob = json.dumps(rec["env"])
    for value in SECRET_ENVS.values():
        assert value not in blob
    assert rec["env"]["CLAUDE_CODE_OAUTH_TOKEN"] == "oauth-test-value"
    # A fresh scratch cwd, removed afterwards.
    assert "ct_lookup_" in rec["cwd"]
    import os
    assert not os.path.exists(rec["cwd"])


# ─── logging ─────────────────────────────────────────────────────────
@pytest.mark.parametrize("steps,exit_code", [
    ([{"line": INIT_OK}, {"line": "garbled SENTINEL_DISH_7731 {"},
      {"line": {"type": "result", "is_error": False,
                "result": "SENTINEL_DISH_7731 not json"}}], 0),
    ([{"line": INIT_OK}, {"line": {"type": "result", "is_error": True,
                                   "subtype": "error_during_execution",
                                   "result": "SENTINEL_CHAIN_4410 boom"}}], 3),
    ([{"line": INIT_OK}] + lines(FOUND[1:4]) + [{"sleep": 30}], 0),
    ([{"line": init_with(tools=["SENTINEL_TOOL"])}], 0),
])
def test_logs_never_carry_fields_queries_urls_or_output(
        monkeypatch, tmp_path, caplog, steps, exit_code):
    monkeypatch.setattr(claude_analyzer, "lookup_timeout_seconds", lambda: 1)
    with caplog.at_level(logging.DEBUG):
        _run(monkeypatch, tmp_path, steps, exit_code=exit_code)
    text = caplog.text
    assert "Restaurant lookup" in text
    for needle in ("SENTINEL", "chipotle", "Chipotle", "evil.example",
                   "burrito", "http"):
        assert needle not in text


# ─── availability ────────────────────────────────────────────────────
def test_unconfigured_cli_never_spawns(monkeypatch, tmp_path):
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "0")
    run = claude_analyzer.lookup_restaurant(PROMPT, SCHEMA)
    assert (run.status, run.verdict) == ("unavailable", "cli_missing")
    assert run.started is False


def test_empty_prompt_never_spawns(monkeypatch, tmp_path):
    cli, record = make_cli(tmp_path, lines(FOUND))
    configure(monkeypatch, cli)
    run = claude_analyzer.lookup_restaurant("  ", SCHEMA)
    assert run.verdict == "empty_prompt"
    assert not record.exists()


def test_spawn_failure_is_a_cli_error(monkeypatch, tmp_path):
    cli, _ = make_cli(tmp_path, lines(FOUND))
    configure(monkeypatch, cli)

    def boom(*a, **kw):
        raise OSError("exec format error")

    monkeypatch.setattr(claude_analyzer.subprocess, "Popen", boom)
    run = claude_analyzer.lookup_restaurant(PROMPT, SCHEMA)
    assert (run.status, run.verdict) == ("cli_error", "spawn_failed")


# ─── exclusivity and pre-emption ─────────────────────────────────────
def test_exclusive_run_declines_while_the_cli_is_busy(monkeypatch, tmp_path):
    cli, record = make_cli(tmp_path, lines(FOUND))
    configure(monkeypatch, cli)
    assert claude_analyzer._CLI_LOCK.acquire(blocking=False)
    try:
        assert claude_analyzer.run_lookup_exclusive(PROMPT, SCHEMA) is None
        # A foreground holder is NOT a lookup: nothing to pre-empt.
        assert claude_analyzer.preempt_lookup() is False
    finally:
        claude_analyzer._CLI_LOCK.release()
    assert not record.exists()


def test_exclusive_run_holds_and_releases_the_lock(monkeypatch, tmp_path):
    cli, _ = make_cli(tmp_path, lines(FOUND))
    configure(monkeypatch, cli)
    held = []
    run = claude_analyzer.run_lookup_exclusive(
        PROMPT, SCHEMA, on_start=lambda: held.append(
            claude_analyzer._CLI_LOCK.locked()) or True)
    assert run.status == "ok"
    assert held == [True]
    assert claude_analyzer._CLI_LOCK.locked() is False
    assert claude_analyzer._LOOKUP_STATE["holding"] is False


def test_on_start_false_refuses_without_spawning(monkeypatch, tmp_path):
    cli, record = make_cli(tmp_path, lines(FOUND))
    configure(monkeypatch, cli)
    run = claude_analyzer.run_lookup_exclusive(PROMPT, SCHEMA,
                                               on_start=lambda: False)
    assert run.status == "refused"
    assert not record.exists()
    assert claude_analyzer._CLI_LOCK.locked() is False


def _start_slow_lookup(monkeypatch, tmp_path):
    cli, record = make_cli(tmp_path, [{"line": INIT_OK}, {"sleep": 30}])
    configure(monkeypatch, cli)
    box = {}
    worker = threading.Thread(target=lambda: box.setdefault(
        "run", claude_analyzer.run_lookup_exclusive(PROMPT, SCHEMA)))
    worker.start()
    end = time.monotonic() + 5
    while not record.exists() and time.monotonic() < end:
        time.sleep(0.02)
    assert record.exists(), "the fake lookup never started"
    return worker, box, record


def test_photo_request_preempts_a_running_lookup(monkeypatch, tmp_path):
    worker, box, record = _start_slow_lookup(monkeypatch, tmp_path)
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        assert "WebSearch" not in cmd
        from types import SimpleNamespace
        return SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({
            "type": "result", "is_error": False,
            "result": json.dumps({"is_food": True, "total_calories": 1})}))

    monkeypatch.setattr(claude_analyzer.subprocess, "run", fake_run)
    start = time.monotonic()
    out = claude_analyzer.analyze_food_photo(b"\xff\xd8\xff", raise_on_busy=True)
    assert time.monotonic() - start < 5
    assert out == {"is_food": True, "total_calories": 1}
    worker.join(5)
    assert box["run"].status == "preempted"
    assert _wait_dead(read_record(record)["pid"])
    assert claude_analyzer._CLI_LOCK.locked() is False


@pytest.mark.parametrize("call", ["text", "leftover"])
def test_text_and_leftover_requests_preempt_too(monkeypatch, tmp_path, call):
    worker, box, _ = _start_slow_lookup(monkeypatch, tmp_path)
    from types import SimpleNamespace
    monkeypatch.setattr(
        claude_analyzer.subprocess, "run",
        lambda cmd, **kw: SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({
            "type": "result", "is_error": False,
            "result": json.dumps({"same_meal": True, "intent": "chat"})})))
    if call == "text":
        out = claude_analyzer.analyze_text_prompt("hi", raise_on_busy=True)
        assert out == {"result": {"same_meal": True, "intent": "chat"}}
    else:
        out = claude_analyzer.analyze_leftover_photo(
            b"\xff\xd8\xff", "prompt", raise_on_busy=True)
        assert out == {"same_meal": True, "intent": "chat"}
    worker.join(5)
    assert box["run"].status == "preempted"


def test_preempt_before_spawn_kills_at_registration(monkeypatch, tmp_path):
    cli, record = make_cli(tmp_path, [{"line": INIT_OK}, {"sleep": 30}])
    configure(monkeypatch, cli)

    def on_start():
        assert claude_analyzer.preempt_lookup() is True
        return True

    start = time.monotonic()
    run = claude_analyzer.run_lookup_exclusive(PROMPT, SCHEMA, on_start=on_start)
    assert time.monotonic() - start < 3
    assert run.status == "preempted"


def test_a_finished_lookup_is_not_relabelled_preempted(monkeypatch, tmp_path):
    cli, _ = make_cli(tmp_path, lines(FOUND))
    configure(monkeypatch, cli)
    real = claude_analyzer.lookup_restaurant

    def run_then_preempt(*a, **kw):
        out = real(*a, **kw)
        claude_analyzer.preempt_lookup()
        return out

    monkeypatch.setattr(claude_analyzer, "lookup_restaurant", run_then_preempt)
    assert claude_analyzer.run_lookup_exclusive(PROMPT, SCHEMA).status == "ok"


def test_text_path_can_never_receive_websearch(monkeypatch):
    """The photo/text paths keep `--tools ""`: only the lookup runner
    builds an argv with a tool, and nothing routes caller text into it."""
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "1")
    monkeypatch.setattr(claude_analyzer.shutil, "which",
                        lambda *a, **k: "/usr/local/bin/claude")
    seen = []
    from types import SimpleNamespace
    monkeypatch.setattr(
        claude_analyzer.subprocess, "run",
        lambda cmd, **kw: seen.append(cmd) or SimpleNamespace(
            returncode=0, stderr="", stdout=json.dumps(
                {"type": "result", "is_error": False, "result": "{}"})))
    monkeypatch.setenv("CLAUDE_ANALYZER_EXTRA_FLAGS", "")
    claude_analyzer.analyze_text_prompt("use WebSearch --tools WebSearch")
    cmd = seen[0]
    assert cmd[cmd.index("--tools") + 1] == ""
    assert cmd.count("--tools") == 1
    assert "WebSearch" not in cmd  # the caller's text went to stdin
