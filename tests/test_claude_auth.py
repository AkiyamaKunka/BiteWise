"""Phone-driven OAuth re-connect (claude_auth + its endpoints).

The PTY session machinery is exercised against a SCRIPTED fake CLI (a tiny
python script that mimics setup-token's dialogue), so URL harvesting, code
paste, token extraction, one-shot semantics and expiry run for real. The
contract that matters:

  * the token never appears in any HTTP response or log line;
  * one session at a time, one completion attempt per session;
  * .env update is atomic-ish, chmod 600, and effective via os.environ.
"""
import os
import stat
import sys
import textwrap
from types import SimpleNamespace

import pytest

import claude_analyzer
import claude_auth
import database
import telegram_bot


# A real authorize URL is ~350 characters and a real token ~108: long
# enough that the CLI's hard wrap at the PTY width cuts them (2026-11-11).
FAKE_URL = ("https://claude.ai/oauth/authorize?code=true&client_id="
            "9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code"
            "&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode"
            "%2Fcallback&scope=user%3Ainference&code_challenge="
            "Xw2oS9kq1LrB7mT3vZp0YcE5nH8aJ4uG6dF1sQ9wR2t"
            "&code_challenge_method=S256&state="
            "N7bV2cX9zL4kJ1hG6fD3sA8pO5iU0yT2rE7wQ9mB1nC")
FAKE_TOKEN = ("sk-ant-oat01-" + "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9fG1"
              "hJ3kL5mN7pQ9rS1tU3vW5xY7zA9bC1dE3fG5hJ7kL9mN1pQ3rS5tU7v-AA")


def make_fake_cli(tmp_path, behavior="ok"):
    """A stand-in for `claude setup-token` speaking the same dialogue, the
    way the real CLI does: it hard-wraps every line at the PTY's width (80
    when the PTY reports none), and reads the code in raw mode, where only
    a carriage return submits (a line feed is Ctrl+J, not Enter)."""
    script = tmp_path / "fake_setup_token.py"
    script.write_text(textwrap.dedent(f"""
        import os, sys, tty
        behavior = {behavior!r}
        try:
            cols = os.get_terminal_size(1).columns or 80
        except OSError:
            cols = 80
        def show(text):
            rows = [text[i:i + cols] for i in range(0, len(text), cols)]
            sys.stdout.write("\\r\\n".join(rows) + "\\r\\n")
            sys.stdout.flush()
        if behavior == "no_url":
            show("something went wrong before any url")
            sys.exit(1)
        show("Visit: " + {FAKE_URL!r})
        tty.setraw(0)
        code = b""
        while True:
            ch = os.read(0, 1)
            if not ch or ch == b"\\r":
                break
            if ch == b"\\n":
                continue  # Ctrl+J: not a submit
            code += ch
        if behavior == "bad_code" or code != b"good-code#state":
            show("Invalid code.")
            sys.exit(1)
        show("Success! Your token: " + {FAKE_TOKEN!r})
    """))
    wrapper = tmp_path / "fakecli"
    wrapper.write_text(f"#!/bin/sh\nexec {sys.executable} {script} \"$@\"\n")
    wrapper.chmod(0o755)
    return str(wrapper)


@pytest.fixture(autouse=True)
def clean_sessions():
    claude_auth.cancel_session()
    yield
    claude_auth.cancel_session()


def test_full_flow_start_complete_applies_token(tmp_path):
    cli = make_fake_cli(tmp_path)
    started = claude_auth.start_session(cli, dict(os.environ))
    assert started.get("url") == FAKE_URL, "the whole URL, not one 80-column row"
    applied = []
    done = claude_auth.complete_session("good-code#state", applied.append)
    assert done == {"ok": True}
    assert applied == [FAKE_TOKEN], "the whole token, submitted with Enter"


def test_wrong_code_fails_without_applying(tmp_path):
    cli = make_fake_cli(tmp_path)
    claude_auth.start_session(cli, dict(os.environ))
    applied = []
    done = claude_auth.complete_session("wrong", applied.append)
    assert "error" in done
    assert applied == []


def test_sessions_are_one_shot_and_singular(tmp_path):
    cli = make_fake_cli(tmp_path)
    claude_auth.start_session(cli, dict(os.environ))
    # A second start replaces the first (its verifier died with it).
    claude_auth.start_session(cli, dict(os.environ))
    done = claude_auth.complete_session("good-code#state", lambda t: None)
    assert done == {"ok": True}
    # The consumed session cannot be completed twice.
    again = claude_auth.complete_session("good-code#state", lambda t: None)
    assert "error" in again


def test_no_url_from_cli_is_a_clean_error(tmp_path):
    cli = make_fake_cli(tmp_path, behavior="no_url")
    started = claude_auth.start_session(cli, dict(os.environ))
    assert "error" in started
    assert not claude_auth.session_active()


def test_expired_session_refuses_completion(tmp_path, monkeypatch):
    cli = make_fake_cli(tmp_path)
    claude_auth.start_session(cli, dict(os.environ))
    monkeypatch.setattr(claude_auth, "SESSION_TTL_SECONDS", -1)
    done = claude_auth.complete_session("good-code#state", lambda t: None)
    assert "error" in done and "expired" in done["error"]


def test_whitespace_or_giant_codes_are_rejected_before_the_pty(tmp_path):
    cli = make_fake_cli(tmp_path)
    for bad in ["has space", "x" * 600, "", "  "]:
        claude_auth.start_session(cli, dict(os.environ))
        done = claude_auth.complete_session(bad, lambda t: None)
        assert "error" in done, repr(bad)


def test_apply_token_updates_env_file_and_process(tmp_path, monkeypatch):
    env = tmp_path / ".env"
    env.write_text("OTHER=1\nCLAUDE_CODE_OAUTH_TOKEN=old-token\nMORE=2\n")
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    claude_auth.apply_token_to_env("sk-ant-oat01-NEW", env_path=env)
    text = env.read_text()
    assert "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-NEW" in text
    assert "old-token" not in text
    assert "OTHER=1" in text and "MORE=2" in text  # neighbours untouched
    assert os.environ["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-NEW"
    mode = stat.S_IMODE(env.stat().st_mode)
    assert mode == 0o600


def test_apply_token_appends_when_key_absent(tmp_path):
    env = tmp_path / ".env"
    env.write_text("OTHER=1")  # no trailing newline on purpose
    claude_auth.apply_token_to_env("sk-ant-oat01-NEW", env_path=env)
    assert env.read_text().endswith("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-NEW\n")


def make_gated_cli(tmp_path, gate, url=FAKE_URL, name="gated"):
    """A fake setup-token that prints [url] only once [gate] exists, so a
    test can hold starts inside the URL harvest and choose the order their
    URLs arrive in. Afterwards it waits on stdin like the real CLI."""
    script = tmp_path / f"{name}_setup_token.py"
    script.write_text(textwrap.dedent(f"""
        import os, sys, time
        while not os.path.exists({str(gate)!r}):
            time.sleep(0.02)
        sys.stdout.write("Visit: " + {url!r} + "\\r\\n")
        sys.stdout.flush()
        sys.stdin.readline()
        time.sleep(60)
    """))
    wrapper = tmp_path / f"{name}cli"
    wrapper.write_text(f"#!/bin/sh\nexec {sys.executable} {script} \"$@\"\n")
    wrapper.chmod(0o755)
    return str(wrapper)


def _record_spawns(monkeypatch):
    """The setup-token processes start_session spawns, in spawn order."""
    spawned = []
    real_popen = claude_auth.subprocess.Popen

    def recording_popen(*args, **kwargs):
        proc = real_popen(*args, **kwargs)
        spawned.append(proc)
        return proc

    monkeypatch.setattr(claude_auth.subprocess, "Popen", recording_popen)
    return spawned


def _wait_until(predicate, timeout=10.0):
    import time
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        time.sleep(0.01)
    return predicate()


def _exits(proc, timeout=10):
    import subprocess
    try:
        proc.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        return False


def _kill_leftovers(spawned):
    for proc in spawned:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)


def test_concurrent_starts_leave_no_orphan_process(tmp_path, monkeypatch):
    """Two starts racing through the URL harvest (Flask serves requests on
    threads; the app can tap Connect again from a fresh screen). The later
    publish used to overwrite the earlier one without killing it: a
    setup-token process holding a PTY that neither cancel nor the TTL
    reaper could see, alive until the service restarted, on a 1 GB VM.
    Whatever the interleaving, one start publishes, the other kills its own
    CLI, and cancel_session() then leaves no process."""
    import threading

    gate = tmp_path / "print-the-url-now"
    cli = make_gated_cli(tmp_path, gate)
    spawned = _record_spawns(monkeypatch)
    results = []

    def start():
        results.append(claude_auth.start_session(cli, dict(os.environ)))

    threads = [threading.Thread(target=start) for _ in range(2)]
    try:
        for t in threads:
            t.start()
        assert _wait_until(lambda: len(spawned) == 2), \
            "both starts must be inside the harvest"
        gate.touch()
        for t in threads:
            t.join(timeout=40)
        assert sorted("url" in r for r in results) == [False, True], results

        claude_auth.cancel_session()

        for proc in spawned:
            if not _exits(proc):
                pytest.fail("a setup-token process outlived cancel_session(): "
                            "an orphan no reaper can see")
    finally:
        gate.touch()
        _kill_leftovers(spawned)


@pytest.mark.parametrize("printed_first", ["newer", "older"])
def test_the_newest_start_wins_whichever_cli_prints_first(
        tmp_path, monkeypatch, printed_first):
    """Tapping Connect again from a fresh screen while the first start
    still harvests (a slow Node cold start on the 1 GB VM): the first
    screen is gone, so the user signs in with the NEWER start's URL. The
    publish order used to decide instead: when the older CLI printed last,
    its publish replaced (and killed) the session behind that URL, and the
    pasted code reached the wrong process ("the code was not accepted").
    Now the newer start's session is the published one whichever CLI
    prints first, and the older start answers an error, never a URL whose
    process is already dead."""
    import threading

    names = ("older", "newer")
    gates = {n: tmp_path / f"print-{n}" for n in names}
    urls = {n: f"{FAKE_URL}&tap={n}" for n in names}
    clis = {n: make_gated_cli(tmp_path, gates[n], urls[n], name=n)
            for n in names}
    spawned = _record_spawns(monkeypatch)
    results = {}

    def start(n):
        results[n] = claude_auth.start_session(clis[n], dict(os.environ))

    threads = {n: threading.Thread(target=start, args=(n,)) for n in names}
    try:
        threads["older"].start()
        assert _wait_until(lambda: len(spawned) == 1)
        threads["newer"].start()
        assert _wait_until(lambda: len(spawned) == 2)
        older_cli, newer_cli = spawned
        release = ["newer", "older"] if printed_first == "newer" else names
        for n in release:
            gates[n].touch()
            threads[n].join(timeout=40)
            assert not threads[n].is_alive(), n

        assert results["newer"] == {"url": urls["newer"]}
        assert "error" in results["older"], results["older"]
        assert claude_auth._session["url"] == urls["newer"]
        assert _exits(older_cli), "the superseded start must kill its CLI"
        assert newer_cli.poll() is None, "the newest session stays live"
        claude_auth.cancel_session()
        assert _exits(newer_cli)
    finally:
        for gate in gates.values():
            gate.touch()
        _kill_leftovers(spawned)


def test_a_cancel_during_the_harvest_stops_that_start(tmp_path, monkeypatch):
    """A cancel that landed while a start was still harvesting found
    nothing to kill; the start then published anyway and its process lived
    until the TTL reaper. Now the start sees the cancel at publish time,
    kills its own CLI and answers an error: nothing is published."""
    import threading

    gate = tmp_path / "print-the-url-now"
    cli = make_gated_cli(tmp_path, gate)
    spawned = _record_spawns(monkeypatch)
    result = {}
    thread = threading.Thread(target=lambda: result.update(
        claude_auth.start_session(cli, dict(os.environ))))
    try:
        thread.start()
        assert _wait_until(lambda: len(spawned) == 1)
        assert claude_auth.cancel_session() is False, "nothing published yet"
        gate.touch()
        thread.join(timeout=40)
        assert not thread.is_alive()

        assert "error" in result, result
        assert claude_auth._session is None
        assert _exits(spawned[0]), "the cancelled start must kill its CLI"
    finally:
        gate.touch()
        _kill_leftovers(spawned)


# ── endpoint layer ────────────────────────────────────────────────


class FakeBot:
    def __init__(self):
        self.messages = []

    def send_message(self, chat_id, text, **kw):
        self.messages.append((chat_id, text))
        return {"ok": True}

    def _redact(self, e):
        return str(e)


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(database, "DB_PATH", tmp_path / "auth.db")
    database.init_db()
    monkeypatch.setattr(telegram_bot, "ALLOWED_CHAT_ID", 12345)
    monkeypatch.setattr(telegram_bot, "ANDROID_API_KEY", "secret-key")
    monkeypatch.setattr(telegram_bot, "API_UPLOAD_PENDING_DIR",
                        tmp_path / "pending")
    monkeypatch.setattr(telegram_bot, "API_UPLOAD_FAILED_DIR",
                        tmp_path / "failed")
    monkeypatch.setattr(telegram_bot, "SERVICE_HEALTH_PATH",
                        tmp_path / "health.json")
    monkeypatch.setattr(telegram_bot, "maybe_warn_android_vpn_inactive",
                        lambda *a, **kw: None)
    app = telegram_bot._build_api_app(FakeBot(), object())
    return app.test_client()


def test_start_requires_auth_and_cli(client, monkeypatch):
    assert client.post("/api/claude_auth/start").status_code == 401
    monkeypatch.setattr(claude_analyzer, "_cli_path", lambda: None)
    resp = client.post("/api/claude_auth/start",
                       headers={"X-API-Key": "secret-key"})
    assert resp.status_code == 503


def test_start_and_complete_via_http_never_leak_the_token(
        client, monkeypatch, tmp_path):
    cli = make_fake_cli(tmp_path)
    monkeypatch.setattr(claude_analyzer, "_cli_path", lambda: cli)
    applied = []
    monkeypatch.setattr(claude_auth, "apply_token_to_env",
                        lambda tok: applied.append(tok))
    h = {"X-API-Key": "secret-key"}
    started = client.post("/api/claude_auth/start", headers=h)
    assert started.status_code == 200
    body = started.get_json()
    assert body["url"].startswith("https://claude.ai/oauth/authorize")

    done = client.post("/api/claude_auth/complete", headers=h,
                       json={"code": "good-code#state"})
    assert done.status_code == 200
    payload = done.get_json()
    assert payload["ok"] is True
    assert applied == [FAKE_TOKEN]
    # The token must never appear in ANY response body.
    assert "sk-ant-oat" not in started.get_data(as_text=True)
    assert "sk-ant-oat" not in done.get_data(as_text=True)


def test_complete_without_start_is_a_clean_502(client):
    resp = client.post("/api/claude_auth/complete",
                       headers={"X-API-Key": "secret-key"},
                       json={"code": "whatever"})
    assert resp.status_code == 502
    assert resp.get_json()["error"] == "complete_failed"


def test_cancel_reports_whether_a_session_existed(
        client, monkeypatch, tmp_path):
    h = {"X-API-Key": "secret-key"}
    assert client.post("/api/claude_auth/cancel",
                       headers=h).get_json()["cancelled"] is False
    cli = make_fake_cli(tmp_path)
    monkeypatch.setattr(claude_analyzer, "_cli_path", lambda: cli)
    client.post("/api/claude_auth/start", headers=h)
    assert client.post("/api/claude_auth/cancel",
                       headers=h).get_json()["cancelled"] is True


def test_expired_sessions_are_reaped_not_just_reported(monkeypatch):
    """An abandoned consent (the ordinary 'tapped Connect then closed the
    sheet' path — the app never calls /cancel) used to leave a full Node
    process holding a PTY fd forever on the 1 GB VM: the TTL was consulted
    but nothing ever acted on it."""
    killed = []
    fake = SimpleNamespace(proc=SimpleNamespace(pid=4242), master=-1,
                           url="https://claude.com/x", started_at=0.0)
    # Far in the past on ANY monotonic clock (macOS reports uptime, which
    # is small right after a reboot — 0.0 was not reliably "expired").
    monkeypatch.setattr(claude_auth, "_session", {
        "proc": fake.proc, "master": fake.master, "url": fake.url,
        "started_at": -10_000.0,
    })
    monkeypatch.setattr(claude_auth, "_kill_session",
                        lambda sess: killed.append(sess))
    # monotonic() is far past started_at=0 in any real process.
    assert claude_auth.session_active() is False
    assert killed, "the expired session must be KILLED, not just reported"
    assert claude_auth._session is None

    # And the explicit sweep is idempotent.
    killed.clear()
    assert claude_auth.reap_expired_session() is False
    assert killed == []


def test_a_live_session_is_never_reaped(monkeypatch):
    import time as _time
    monkeypatch.setattr(claude_auth, "_session", {
        "proc": SimpleNamespace(pid=1), "master": -1, "url": "u",
        "started_at": _time.monotonic(),
    })
    killed = []
    monkeypatch.setattr(claude_auth, "_kill_session",
                        lambda sess: killed.append(sess))
    assert claude_auth.session_active() is True
    assert killed == []
