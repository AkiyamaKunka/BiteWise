"""Async restaurant-lookup jobs (design stage R3b): queue, cache, TTL,
the single worker, pre-emption by photos, and the daily cap."""
import copy
import json
import threading
import time

import pytest

import claude_analyzer
import lookup_contract
import lookup_jobs
import service_health
from claude_analyzer import LookupRun
from lookup_fakes import (FOUND, INIT_OK, REQUEST_BODY, configure, make_cli,
                          use_chain_table)


@pytest.fixture(autouse=True)
def _table(monkeypatch):
    use_chain_table(monkeypatch)


def _request(name="Chicken burrito bowl"):
    body = copy.deepcopy(REQUEST_BODY)
    body["items"][0]["name"] = name
    return lookup_contract.sanitize_request(body)


def _ok_run():
    return LookupRun(
        status="ok", verdict="ok", result=copy.deepcopy(
            FOUND[-1]["structured_output"]),
        cited_urls=["https://www.chipotle.com/nutrition-calculator"],
        evidence=[{"urls": ["https://www.chipotle.com/nutrition-calculator"],
                   "text": "chicken 180 calories " + "z" * 3000}],
        searches=2, started=True)


class Clock:
    def __init__(self):
        self.now = 1_000_000.0

    def __call__(self):
        return self.now


class Counter:
    """In-memory stand-in for DailyRunCounter."""

    def __init__(self, cap=30):
        self.cap = cap
        self.runs = 0

    def remaining(self):
        return max(self.cap - self.runs, 0)

    def try_start(self):
        if self.runs >= self.cap:
            return False
        self.runs += 1
        return True


class ScriptedRunner:
    """Runs on the worker thread; each call pops the next outcome."""

    def __init__(self, outcomes, gate=None):
        self.outcomes = list(outcomes)
        self.calls = 0
        self.gate = gate

    def __call__(self, request, on_start):
        self.calls += 1
        outcome = self.outcomes.pop(0) if self.outcomes else _ok_run()
        if outcome is None:
            return None  # CLI busy
        if outcome == "raise":
            raise RuntimeError("bug")
        if not on_start():
            return LookupRun(status="refused", verdict="refused")
        if self.gate is not None:
            self.gate.wait(5)
        return outcome() if callable(outcome) else outcome


def _service(runner, counter=None, clock=None):
    return lookup_jobs.LookupService(
        counter or Counter(), runner=runner, clock=clock or Clock(),
        poll_seconds=0.01, model_fn=lambda: "sonnet")


def _wait_state(service, job_id, states, seconds=5.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        body = service.status(job_id)
        if body["state"] in states:
            return body
        time.sleep(0.01)
    raise AssertionError(f"job stuck at {service.status(job_id)}")


@pytest.fixture
def services():
    made = []
    yield made
    for service in made:
        service.stop()


def test_submit_runs_once_then_serves_the_cache(services):
    runner = ScriptedRunner([_ok_run])
    service = _service(runner)
    services.append(service)
    kind, body = service.submit(_request())
    assert kind == "accepted" and body["state"] in ("queued", "running")
    done = _wait_state(service, body["job_id"], {"done"})
    assert done["lookup"]["status"] == "found"
    assert done["analyzed_by"] == "claude" and done["searches"] == 2
    assert done["cited_urls"] == ["https://www.chipotle.com/nutrition-calculator"]
    assert done["evidence"][0]["url"] == done["cited_urls"][0]
    assert len(done["evidence"][0]["text"]) == lookup_jobs.EVIDENCE_TEXT_CAP
    kind, cached = service.submit(_request())
    assert kind == "cached" and cached == done
    assert runner.calls == 1


def test_same_request_twice_is_one_job(services):
    gate = threading.Event()
    runner = ScriptedRunner([_ok_run], gate=gate)
    service = _service(runner)
    services.append(service)
    _, first = service.submit(_request())
    _, second = service.submit(_request())
    assert first["job_id"] == second["job_id"]
    gate.set()
    _wait_state(service, first["job_id"], {"done"})
    assert runner.calls == 1


def test_queue_cap(services):
    gate = threading.Event()
    service = _service(ScriptedRunner([], gate=gate))
    services.append(service)
    _, running = service.submit(_request("first"))
    _wait_state(service, running["job_id"], {"running"})
    for i in range(lookup_jobs.QUEUE_MAX - 1):
        assert service.submit(_request(f"q{i}"))[0] == "accepted"
    assert service.submit(_request("overflow")) == ("queue_full", {})
    gate.set()


def test_unknown_job_and_ttl_expiry(services):
    clock = Clock()
    service = _service(ScriptedRunner([_ok_run]), clock=clock)
    services.append(service)
    assert service.status("nope-nope-nope") == {"state": "unknown",
                                                "job_id": "nope-nope-nope"}
    _, body = service.submit(_request())
    _wait_state(service, body["job_id"], {"done"})
    clock.now += lookup_jobs.CACHE_TTL_SECONDS + 1
    assert service.status(body["job_id"])["state"] == "unknown"
    assert service.submit(_request())[0] == "accepted"  # cache expired


def test_failed_run_reports_its_reason_and_a_resubmit_runs_again(services):
    runner = ScriptedRunner([LookupRun(status="guard_fail",
                                       verdict="guard_fail:tools")])
    service = _service(runner)
    services.append(service)
    _, body = service.submit(_request())
    failed = _wait_state(service, body["job_id"], {"failed"})
    assert failed == {"state": "failed", "job_id": body["job_id"],
                      "reason": "guard_fail"}
    kind, again = service.submit(_request())
    assert kind == "accepted" and again["job_id"] != body["job_id"]
    _wait_state(service, again["job_id"], {"done"})


@pytest.mark.parametrize("result", [None, {"status": "nonsense"}])
def test_unusable_answer_fails_as_bad_output(services, result):
    run = _ok_run()
    run.result = result
    service = _service(ScriptedRunner([run]))
    services.append(service)
    _, body = service.submit(_request())
    assert _wait_state(service, body["job_id"], {"failed"})["reason"] == \
        "bad_output"


def test_worker_waits_while_the_cli_is_busy(services):
    runner = ScriptedRunner([None, None, None, _ok_run])
    service = _service(runner)
    services.append(service)
    _, body = service.submit(_request())
    _wait_state(service, body["job_id"], {"done"})
    assert runner.calls == 4


def test_preempted_job_requeues_at_the_front_then_completes(services):
    pre = LookupRun(status="preempted", verdict="preempted")
    runner = ScriptedRunner([pre, pre, _ok_run])
    service = _service(runner)
    services.append(service)
    _, body = service.submit(_request())
    _wait_state(service, body["job_id"], {"done"})
    assert runner.calls == 3


def test_third_preemption_fails_the_job(services):
    pre = LookupRun(status="preempted", verdict="preempted")
    service = _service(ScriptedRunner([pre, pre, pre]))
    services.append(service)
    _, body = service.submit(_request())
    assert _wait_state(service, body["job_id"], {"failed"})["reason"] == \
        "preempted"


def test_runner_bug_fails_the_job_not_the_worker(services):
    service = _service(ScriptedRunner(["raise", _ok_run]))
    services.append(service)
    _, first = service.submit(_request("a"))
    assert _wait_state(service, first["job_id"], {"failed"})["reason"] == \
        "cli_error"
    _, second = service.submit(_request("b"))
    _wait_state(service, second["job_id"], {"done"})


def test_daily_cap_counts_started_runs(services):
    counter = Counter(cap=2)
    service = _service(ScriptedRunner([]), counter=counter)
    services.append(service)
    for name in ("a", "b"):
        _, body = service.submit(_request(name))
        _wait_state(service, body["job_id"], {"done"})
    assert counter.runs == 2
    assert service.submit(_request("c")) == ("daily_cap", {})


def test_cap_reached_between_submit_and_start_fails_the_job(services):
    counter = Counter(cap=1)
    gate = threading.Event()
    service = _service(ScriptedRunner([], gate=gate), counter=counter)
    services.append(service)
    _, first = service.submit(_request("a"))
    _wait_state(service, first["job_id"], {"running"})
    counter.cap = 2  # submit still sees room…
    _, second = service.submit(_request("b"))
    counter.cap = 1  # …but the cap shrank before the run could start
    gate.set()
    assert _wait_state(service, second["job_id"], {"failed"})["reason"] == \
        "daily_cap"


def test_eviction_keeps_the_store_bounded(services, monkeypatch):
    monkeypatch.setattr(lookup_jobs, "MAX_JOBS", 3)
    service = _service(ScriptedRunner([]))
    services.append(service)
    ids = []
    for i in range(5):
        _, body = service.submit(_request(f"e{i}"))
        _wait_state(service, body["job_id"], {"done"})
        ids.append(body["job_id"])
    states = [service.status(i)["state"] for i in ids]
    assert states == ["unknown", "unknown", "done", "done", "done"]


def test_stop_ends_the_worker():
    service = _service(ScriptedRunner([]))
    _, body = service.submit(_request())
    _wait_state(service, body["job_id"], {"done"})
    service.stop()
    assert not service._worker.is_alive()


# ─── the daily counter in the service-health ledger ─────────────────
def test_daily_counter_persists_and_resets_by_day(tmp_path):
    path = tmp_path / "health.json"
    day = {"d": "2026-10-23"}
    counter = lookup_jobs.DailyRunCounter(lambda: path, cap_fn=lambda: 2,
                                          today_fn=lambda: day["d"])
    assert counter.remaining() == 2
    assert counter.try_start() and counter.try_start()
    assert counter.try_start() is False
    assert counter.remaining() == 0
    record = service_health.load(path)["restaurant_lookup"]
    assert record["date"] == "2026-10-23" and record["runs"] == 2
    day["d"] = "2026-10-24"
    assert counter.remaining() == 2
    path.write_text(json.dumps({"restaurant_lookup": {
        "date": "2026-10-24", "runs": "lots"}}))
    assert counter.remaining() == 2


@pytest.mark.parametrize("raw,expected", [
    (None, 30), ("x", 30), ("-3", 0), ("9000", 500), ("12", 12)])
def test_daily_cap_knob(monkeypatch, raw, expected):
    if raw is None:
        monkeypatch.delenv("CLAUDE_LOOKUP_DAILY_CAP", raising=False)
    else:
        monkeypatch.setenv("CLAUDE_LOOKUP_DAILY_CAP", raw)
    assert lookup_jobs.daily_cap() == expected


@pytest.mark.parametrize("raw,expected", [
    (None, False), ("0", False), ("1", True), ("true", True), ("maybe", False)])
def test_enabled_knob_defaults_off(monkeypatch, raw, expected):
    if raw is None:
        monkeypatch.delenv("CLAUDE_LOOKUP_ENABLED", raising=False)
    else:
        monkeypatch.setenv("CLAUDE_LOOKUP_ENABLED", raw)
    assert lookup_jobs.is_enabled() is expected


def test_get_service_is_a_process_singleton(monkeypatch, tmp_path):
    monkeypatch.setattr(lookup_jobs, "_SERVICE", None)
    first = lookup_jobs.get_service(lambda: tmp_path / "h.json")
    assert lookup_jobs.get_service(lambda: None) is first


# ─── end to end: real runner, fake CLI, a photo pre-empts ───────────
def test_photo_during_a_running_lookup_wins_then_the_job_completes(
        monkeypatch, tmp_path, services):
    """The default runner against a fake CLI that stalls after init on
    its FIRST run (the job is mid-search) and answers on its second."""
    from types import SimpleNamespace

    stall_cli, stall_record = make_cli(
        tmp_path, [{"line": INIT_OK}, {"sleep": 30}], name="stall")
    found_cli, found_record = make_cli(
        tmp_path, [{"line": e} for e in FOUND], name="found")
    configure(monkeypatch, stall_cli)
    health = tmp_path / "health.json"
    service = lookup_jobs.LookupService(
        lookup_jobs.DailyRunCounter(lambda: health), poll_seconds=0.05)
    services.append(service)

    _, body = service.submit(_request())
    end = time.monotonic() + 5
    while not stall_record.exists() and time.monotonic() < end:
        time.sleep(0.02)
    assert service.status(body["job_id"])["state"] == "running"

    # The next CLI start (the requeued job) gets the answering fake.
    monkeypatch.setenv("CLAUDE_ANALYZER_BIN", found_cli)
    monkeypatch.setattr(
        claude_analyzer.subprocess, "run",
        lambda cmd, **kw: SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({
            "type": "result", "is_error": False,
            "result": json.dumps({"is_food": True, "total_calories": 640})})))
    start = time.monotonic()
    photo = claude_analyzer.analyze_food_photo(b"\xff\xd8\xff",
                                               raise_on_busy=True)
    assert time.monotonic() - start < 5
    assert photo == {"is_food": True, "total_calories": 640}

    done = _wait_state(service, body["job_id"], {"done"}, seconds=10)
    assert done["lookup"]["chain_key"] == "chipotle"
    assert found_record.exists()
    # Both CLI starts were counted against the daily cap.
    assert service_health.load(health)["restaurant_lookup"]["runs"] == 2
