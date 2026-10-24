"""POST /api/restaurant_lookup and /api/restaurant_lookup/status
(design stage R3b, data_contracts section 6)."""
import copy
import logging
import threading
import time

import pytest

import claude_analyzer
import lookup_jobs
import telegram_bot
from claude_analyzer import LookupRun
from conftest import _ledger_rows, _meals
from lookup_fakes import FOUND, REQUEST_BODY

KEY = {"X-API-Key": "secret-key", "X-Client-Platform": "app"}


class FakeRunner:
    def __init__(self, gate=None):
        self.requests = []
        self.gate = gate

    def __call__(self, request, on_start):
        self.requests.append(request)
        if not on_start():
            return LookupRun(status="refused", verdict="refused")
        if self.gate is not None:
            self.gate.wait(5)
        return LookupRun(status="ok", verdict="ok",
                         result=copy.deepcopy(FOUND[-1]["structured_output"]),
                         cited_urls=["https://www.chipotle.com/nutrition-calculator"],
                         evidence=[{"urls": ["https://www.chipotle.com/nutrition-calculator"],
                                    "text": "180 calories"}],
                         searches=1, started=True)


@pytest.fixture
def lookup(client, monkeypatch):
    monkeypatch.setenv("CLAUDE_LOOKUP_ENABLED", "1")
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "1")
    monkeypatch.setattr(claude_analyzer.shutil, "which",
                        lambda *a, **k: "/usr/local/bin/claude")
    runner = FakeRunner()
    service = lookup_jobs.LookupService(
        lookup_jobs.DailyRunCounter(lambda: telegram_bot.SERVICE_HEALTH_PATH),
        runner=runner, poll_seconds=0.01)
    monkeypatch.setattr(lookup_jobs, "_SERVICE", service)
    yield client, runner, service
    service.stop()


def _post(client, body, path="/api/restaurant_lookup", headers=KEY):
    return client.http.post(path, json=body, headers=headers)


def _poll_done(client, job_id, seconds=5):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        resp = _post(client, {"job_id": job_id},
                     path="/api/restaurant_lookup/status")
        assert resp.status_code == 200
        if resp.get_json()["state"] in ("done", "failed"):
            return resp.get_json()
        time.sleep(0.01)
    raise AssertionError("job never finished")


def test_requires_the_api_key(lookup):
    client, runner, _ = lookup
    for path in ("/api/restaurant_lookup", "/api/restaurant_lookup/status"):
        resp = client.http.post(path, json=REQUEST_BODY)
        assert resp.status_code == 401
    assert runner.requests == []


def test_knob_off_is_403_disabled_and_never_runs(lookup, monkeypatch):
    client, runner, _ = lookup
    monkeypatch.delenv("CLAUDE_LOOKUP_ENABLED")
    resp = _post(client, REQUEST_BODY)
    assert resp.status_code == 403
    assert resp.get_json()["reason"] == "disabled"
    status = _post(client, {"job_id": "abcdefgh"},
                   path="/api/restaurant_lookup/status")
    assert status.status_code == 403
    assert runner.requests == []


def test_accepts_polls_and_then_serves_the_cache_purely(lookup):
    client, runner, _ = lookup
    resp = _post(client, REQUEST_BODY)
    assert resp.status_code == 202
    body = resp.get_json()
    assert body["state"] in ("queued", "running") and body["job_id"]
    done = _poll_done(client, body["job_id"])
    assert done["state"] == "done"
    assert done["lookup"]["status"] == "found"
    assert done["analyzed_by"] == "claude"
    assert done["cited_urls"] == ["https://www.chipotle.com/nutrition-calculator"]
    # Search prose, labelled as such: never page text (verbatim false).
    assert done["evidence"] == [{"url": done["cited_urls"][0],
                                 "text": "180 calories",
                                 "verbatim": False, "scope": "search"}]
    cached = _post(client, REQUEST_BODY)
    assert cached.status_code == 200
    assert cached.get_json() == done
    assert len(runner.requests) == 1
    # Pure: no meal row, no ledger entry, no Telegram message.
    assert _meals() == 0 and _ledger_rows() == 0
    assert client.bot.messages == []


def test_the_runner_only_ever_sees_the_rebuilt_request(lookup):
    client, runner, _ = lookup
    body = copy.deepcopy(REQUEST_BODY)
    body["client_version"] = "9"
    body["chains"][0]["name"] = "Evil Name"
    assert _post(client, body).status_code == 202
    end = time.monotonic() + 5
    while not runner.requests and time.monotonic() < end:
        time.sleep(0.01)
    req = runner.requests[0]
    assert set(req) == {"items", "order_merchant", "chains", "country"}
    assert req["chains"][0]["name"] == "Chipotle"


def test_same_request_twice_is_one_job(lookup):
    client, runner, _ = lookup
    runner.gate = threading.Event()
    first = _post(client, REQUEST_BODY).get_json()
    second = _post(client, REQUEST_BODY)
    assert second.status_code == 202
    assert second.get_json()["job_id"] == first["job_id"]
    runner.gate.set()
    _poll_done(client, first["job_id"])
    assert len(runner.requests) == 1


@pytest.mark.parametrize("payload,reason,field", [
    ({"items": [{"name": "bowl", "brand": "x"}], "backend": "glm"},
     "unsupported_backend", "backend"),
    ({"items": [{"name": "bowl", "brand": "x"}], "lat": 43.07, "lon": -89.4},
     "bad_request", "lat"),
    ({"items": [{"name": "bowl", "brand": "x"}], "city": "Madison"},
     "bad_request", "city"),
    ({"items": [{"name": "bowl", "brand": "x"}], "prompt": "do evil"},
     "bad_request", "prompt"),
    ({"items": [{"name": "bowl near 43.0731,-89.4012", "brand": "x"}]},
     "bad_request", "items[0].name"),
    ({"items": [{"name": "x" * 1000, "brand": "x"}]},
     "bad_request", "items[0].name"),
    ({"items": [{"name": "pho"}]}, "bad_request", "chains"),
    ([1, 2], "bad_request", "body"),
])
def test_bad_requests_are_400_before_any_run(lookup, payload, reason, field):
    client, runner, _ = lookup
    resp = _post(client, payload)
    assert resp.status_code == 400
    assert resp.get_json() == {"error": reason, "reason": reason,
                               "field": field}
    assert runner.requests == []


def test_non_json_body_is_400(lookup):
    client, runner, _ = lookup
    resp = client.http.post("/api/restaurant_lookup", data=b"\x00garbage",
                            headers=KEY, content_type="application/json")
    assert resp.status_code == 400
    assert runner.requests == []


def test_unavailable_claude_backend_is_503(lookup, monkeypatch):
    client, runner, _ = lookup
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "0")
    resp = _post(client, REQUEST_BODY)
    assert resp.status_code == 503
    assert resp.get_json()["error"] == "claude_unavailable"
    assert runner.requests == []


def test_daily_cap_and_queue_full_are_429(lookup, monkeypatch):
    client, runner, service = lookup
    monkeypatch.setenv("CLAUDE_LOOKUP_DAILY_CAP", "0")
    resp = _post(client, REQUEST_BODY)
    assert resp.status_code == 429
    assert resp.get_json() == {"error": "daily_cap", "reason": "daily_cap",
                               "retry": "later"}
    monkeypatch.setenv("CLAUDE_LOOKUP_DAILY_CAP", "30")
    monkeypatch.setattr(service, "submit", lambda req: ("queue_full", {}))
    resp = _post(client, REQUEST_BODY)
    assert resp.status_code == 429
    assert resp.get_json()["retry"] is True


def test_daily_cap_counts_runs_in_the_health_ledger(lookup, monkeypatch):
    client, runner, _ = lookup
    monkeypatch.setenv("CLAUDE_LOOKUP_DAILY_CAP", "1")
    first = _post(client, REQUEST_BODY).get_json()
    _poll_done(client, first["job_id"])
    other = copy.deepcopy(REQUEST_BODY)
    other["items"][0]["name"] = "Steak bowl"
    resp = _post(client, other)
    assert resp.status_code == 429
    import service_health
    record = service_health.load(telegram_bot.SERVICE_HEALTH_PATH)
    assert record["restaurant_lookup"]["runs"] == 1


@pytest.mark.parametrize("payload", [
    {}, {"job_id": 5}, {"job_id": "short"}, {"job_id": "x" * 65},
    {"job_id": "bad id with spaces"}, [1]])
def test_status_validates_the_job_id(lookup, payload):
    client, _, _ = lookup
    resp = _post(client, payload, path="/api/restaurant_lookup/status")
    assert resp.status_code == 400
    assert resp.get_json()["field"] == "job_id"


def test_status_of_an_unknown_job(lookup):
    client, _, _ = lookup
    resp = _post(client, {"job_id": "abcdefghijkl"},
                 path="/api/restaurant_lookup/status")
    assert resp.status_code == 200
    assert resp.get_json() == {"state": "unknown", "job_id": "abcdefghijkl"}


def test_endpoint_logs_never_carry_the_payload(lookup, caplog):
    client, _, _ = lookup
    body = copy.deepcopy(REQUEST_BODY)
    body["items"][0]["name"] = "SENTINEL_DISH_8812"
    body["items"][0]["brand"] = "SENTINEL_BRAND_8812"
    body["unknown_extra"] = "SENTINEL_EXTRA"
    with caplog.at_level(logging.DEBUG):
        accepted = _post(client, body).get_json()
        _poll_done(client, accepted["job_id"])
        _post(client, body)  # cache hit
        _post(client, dict(body, city="SENTINEL_CITY"))
        _post(client, dict(body, backend="glm"))
    assert "restaurant_lookup accepted" in caplog.text
    assert "1 unknown key(s) dropped" in caplog.text
    assert "SENTINEL" not in caplog.text


def test_the_default_service_uses_the_redirected_health_path(
        client, monkeypatch, tmp_path):
    monkeypatch.setattr(lookup_jobs, "_SERVICE", None)
    monkeypatch.setenv("CLAUDE_LOOKUP_ENABLED", "1")
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "1")
    monkeypatch.setattr(claude_analyzer.shutil, "which",
                        lambda *a, **k: "/usr/local/bin/claude")
    monkeypatch.setenv("CLAUDE_LOOKUP_DAILY_CAP", "0")
    resp = _post(client, REQUEST_BODY)
    assert resp.status_code == 429
    assert lookup_jobs._SERVICE is not None
    lookup_jobs._SERVICE.stop()


# ─── /api/auth_check features ───────────────────────────────────────
def test_auth_check_reports_lookup_features(client, monkeypatch):
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "1")
    monkeypatch.setattr(claude_analyzer.shutil, "which",
                        lambda *a, **k: "/usr/local/bin/claude")
    monkeypatch.delenv("CLAUDE_LOOKUP_ENABLED", raising=False)
    resp = client.http.post("/api/auth_check", headers=KEY)
    features = resp.get_json()["features"]
    assert features["restaurant_lookup"] is False
    assert features["lookup_jobs"] is True
    # Honest: true only once the shared photo prompt asks for it.
    assert features["estimate_confidence"] is (
        "estimate_confidence" in telegram_bot.FOOD_DETECTION_PROMPT)
    monkeypatch.setenv("CLAUDE_LOOKUP_ENABLED", "1")
    features = client.http.post("/api/auth_check",
                                headers=KEY).get_json()["features"]
    assert features["restaurant_lookup"] is True
    monkeypatch.setenv("CLAUDE_ANALYZER_ENABLED", "0")
    features = client.http.post("/api/auth_check",
                                headers=KEY).get_json()["features"]
    assert features["restaurant_lookup"] is False


def test_estimate_confidence_follows_the_prompt(monkeypatch):
    monkeypatch.setattr(telegram_bot, "FOOD_DETECTION_PROMPT",
                        "... estimate_confidence ...")
    assert telegram_bot._api_features()["estimate_confidence"] is True
    monkeypatch.setattr(telegram_bot, "FOOD_DETECTION_PROMPT", "old prompt")
    assert telegram_bot._api_features()["estimate_confidence"] is False


# ─── API_BIND_HOST (docs/SERVER_TLS.md) ─────────────────────────────
@pytest.mark.parametrize("raw,expected", [
    (None, "0.0.0.0"), ("", "0.0.0.0"), ("127.0.0.1", "127.0.0.1"),
    ("::1", "::1"), ("localhost", "0.0.0.0"), ("0.0.0.0; rm", "0.0.0.0")])
def test_api_bind_host_knob(monkeypatch, raw, expected):
    if raw is None:
        monkeypatch.delenv("API_BIND_HOST", raising=False)
    else:
        monkeypatch.setenv("API_BIND_HOST", raw)
    assert telegram_bot._api_bind_host() == expected
