"""Async restaurant-lookup jobs on the owner's server (design stage R3b).

A lookup runs the Claude CLI with WebSearch for 20-75 s — far longer
than a phone keeps a request open, and far too long to hold the single
CLI ahead of a photo. So /api/restaurant_lookup only ENQUEUES: it answers
202 with a job id (or 200 straight from the 24 h cache), and the app
polls /api/restaurant_lookup/status.

  * JobStore: in memory, one lock; at most MAX_JOBS jobs, results kept
    CACHE_TTL_SECONDS, at most QUEUE_MAX waiting. Keyed by the SHA-256 of
    the rebuilt request, so the same request twice is one job and a
    repeat after it finished is a cache hit with no CLI run. A server
    restart forgets everything; the app resubmits on "unknown".
  * One lazy worker thread runs one CLI process at a time under the
    analyzer's _CLI_LOCK. It never waits ON the lock: it polls it every
    POLL_SECONDS without blocking, so photos always come first; a photo,
    leftover or text request that arrives during a lookup pre-empts it
    (claude_analyzer.preempt_lookup). A pre-empted job goes back to the
    FRONT of the queue; the MAX_PREEMPTIONS-th pre-emption fails it.
  * Daily cap: CLAUDE_LOOKUP_DAILY_CAP (default 30) STARTED CLI runs per
    server-local day, counted in service_health.json under
    "restaurant_lookup" — counted when a run starts, whatever its outcome.

Knobs: CLAUDE_LOOKUP_ENABLED (default off: the endpoints answer 403
{reason: disabled}), CLAUDE_LOOKUP_DAILY_CAP, plus the runner's own
CLAUDE_LOOKUP_MODEL / _TIMEOUT_SECONDS / _KEY_SOURCE in claude_analyzer.
"""

import logging
import os
import secrets
import threading
import time
from collections import deque
from dataclasses import dataclass
from datetime import date
from typing import Callable, Dict, Optional, Tuple

import claude_analyzer
import lookup_contract
import service_health
from utils import parse_boolish

log = logging.getLogger("lookup_jobs")

MAX_JOBS = 50
QUEUE_MAX = 5
CACHE_TTL_SECONDS = 24 * 3600
MAX_PREEMPTIONS = 3
POLL_SECONDS = 2.0
DAILY_CAP_DEFAULT = 30
EVIDENCE_TEXT_CAP = 1500
HEALTH_KEY = "restaurant_lookup"


def is_enabled() -> bool:
    """CLAUDE_LOOKUP_ENABLED — off unless explicitly truthy."""
    return parse_boolish(os.environ.get("CLAUDE_LOOKUP_ENABLED")) is True


def daily_cap() -> int:
    try:
        value = int(os.environ.get("CLAUDE_LOOKUP_DAILY_CAP",
                                   str(DAILY_CAP_DEFAULT)))
    except ValueError:
        return DAILY_CAP_DEFAULT
    return min(max(value, 0), 500)


class DailyRunCounter:
    """Started lookup runs per server-local day, in the service-health
    ledger (so `systemctl restart` cannot reset the cap)."""

    def __init__(self, path_fn: Callable, cap_fn: Callable[[], int] = daily_cap,
                 today_fn: Callable[[], str] = lambda: date.today().isoformat()):
        self._path_fn = path_fn
        self._cap_fn = cap_fn
        self._today_fn = today_fn

    def _runs_today(self, data: Dict) -> int:
        record = data.get(HEALTH_KEY)
        if not isinstance(record, dict) or record.get("date") != self._today_fn():
            return 0
        runs = record.get("runs")
        return runs if isinstance(runs, int) and runs >= 0 else 0

    def remaining(self) -> int:
        data = service_health.load(self._path_fn(), warn=log.warning)
        return max(self._cap_fn() - self._runs_today(data), 0)

    def try_start(self) -> bool:
        """Count one started run; False (nothing counted) at the cap."""
        allowed = {"ok": False}

        def mutate(data):
            runs = self._runs_today(data)
            if runs >= self._cap_fn():
                return
            allowed["ok"] = True
            data[HEALTH_KEY] = {"date": self._today_fn(), "runs": runs + 1,
                                "last_start_at": service_health.timestamp()}

        service_health.update(mutate, self._path_fn(), warn=log.warning)
        return allowed["ok"]


@dataclass
class Job:
    job_id: str
    req_hash: str
    request: Dict
    state: str  # queued | running | done | failed
    created: float
    updated: float
    preemptions: int = 0
    payload: Optional[Dict] = None
    reason: Optional[str] = None


def default_runner(request: Dict, on_start: Callable[[], bool]):
    """Compose the prompt HERE (server-side, from the rebuilt request) and
    run it through the exclusive, pre-emptible CLI runner."""
    return claude_analyzer.run_lookup_exclusive(
        lookup_contract.compose_prompt(request),
        lookup_contract.lookup_schema_json(),
        claude_analyzer.lookup_model(),
        on_start=on_start,
    )


def _evidence_by_url(run) -> list:
    """[{url, text}] per cited URL: the text of the search result that
    listed it — the app's grounding check looks for the published number
    there."""
    out = []
    for url in run.cited_urls:
        text = next((s["text"] for s in run.evidence if url in s["urls"]), "")
        out.append({"url": url, "text": text[:EVIDENCE_TEXT_CAP]})
    return out


class LookupService:
    """The job store plus its single worker. One instance per process
    (get_service); tests build their own with a fake runner."""

    def __init__(self, counter: DailyRunCounter, runner: Callable = default_runner,
                 clock: Callable[[], float] = time.time,
                 poll_seconds: float = POLL_SECONDS,
                 model_fn: Callable[[], str] = claude_analyzer.lookup_model):
        self._counter = counter
        self._runner = runner
        self._clock = clock
        self._poll = poll_seconds
        self._model_fn = model_fn
        self._cond = threading.Condition(threading.Lock())
        self._jobs: Dict[str, Job] = {}
        self._by_hash: Dict[str, Job] = {}
        self._queue: deque = deque()
        self._worker: Optional[threading.Thread] = None
        self._stop = threading.Event()

    # ── API side ──────────────────────────────────────────────────────
    def submit(self, request: Dict) -> Tuple[str, Dict]:
        """('cached', body) → 200; ('accepted', body) → 202;
        ('daily_cap' | 'queue_full', {}) → 429."""
        req_hash = lookup_contract.request_hash(request, self._model_fn())
        with self._cond:
            self._prune_locked()
            job = self._by_hash.get(req_hash)
            if job is not None and job.state == "done":
                return "cached", self._body(job)
            if job is not None and job.state in ("queued", "running"):
                return "accepted", self._body(job)
            if len(self._queue) >= QUEUE_MAX:
                return "queue_full", {}
            if self._counter.remaining() <= 0:
                return "daily_cap", {}
            now = self._clock()
            job = Job(job_id=secrets.token_urlsafe(12), req_hash=req_hash,
                      request=request, state="queued", created=now,
                      updated=now)
            self._jobs[job.job_id] = job
            self._by_hash[req_hash] = job
            self._queue.append(job.job_id)
            self._evict_locked()
            self._ensure_worker_locked()
            self._cond.notify_all()
            return "accepted", self._body(job)

    def status(self, job_id: str) -> Dict:
        with self._cond:
            self._prune_locked()
            job = self._jobs.get(job_id)
            if job is None:
                return {"state": "unknown", "job_id": job_id}
            return self._body(job)

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        with self._cond:
            self._cond.notify_all()
            worker = self._worker
        if worker is not None:
            worker.join(timeout)

    @staticmethod
    def _body(job: Job) -> Dict:
        body = {"state": job.state, "job_id": job.job_id}
        if job.state == "done" and job.payload:
            body.update(job.payload)
        if job.state == "failed":
            body["reason"] = job.reason or "failed"
        return body

    # ── bookkeeping (call with the lock held) ─────────────────────────
    def _prune_locked(self) -> None:
        cutoff = self._clock() - CACHE_TTL_SECONDS
        for job_id, job in list(self._jobs.items()):
            if job.state in ("done", "failed") and job.updated < cutoff:
                self._drop_locked(job_id)

    def _evict_locked(self) -> None:
        if len(self._jobs) <= MAX_JOBS:
            return
        finished = sorted((j for j in self._jobs.values()
                           if j.state in ("done", "failed")),
                          key=lambda j: j.updated)
        for job in finished[:len(self._jobs) - MAX_JOBS]:
            self._drop_locked(job.job_id)

    def _drop_locked(self, job_id: str) -> None:
        job = self._jobs.pop(job_id, None)
        if job is not None and self._by_hash.get(job.req_hash) is job:
            del self._by_hash[job.req_hash]

    def _ensure_worker_locked(self) -> None:
        if self._worker is not None and self._worker.is_alive():
            return
        self._stop.clear()
        self._worker = threading.Thread(target=self._work, daemon=True,
                                        name="lookup-worker")
        self._worker.start()

    def _finish_locked(self, job: Job, state: str,
                       reason: Optional[str] = None,
                       payload: Optional[Dict] = None) -> None:
        job.state = state
        job.reason = reason
        job.payload = payload
        job.updated = self._clock()

    # ── worker side ───────────────────────────────────────────────────
    def _work(self) -> None:
        while not self._stop.is_set():
            with self._cond:
                job = None
                while self._queue and job is None:
                    job = self._jobs.get(self._queue[0])
                    if job is None or job.state != "queued":
                        self._queue.popleft()
                        job = None
                if job is None:
                    self._cond.wait(self._poll)
                    continue
            try:
                outcome = self._attempt(job)
            except Exception as e:  # never let one job kill the worker
                log.warning(
                    f"Restaurant lookup job failed: {type(e).__name__}")
                with self._cond:
                    if self._queue and self._queue[0] == job.job_id:
                        self._queue.popleft()
                    self._finish_locked(job, "failed", "worker_error")
                outcome = "failed"
            if outcome in ("busy", "preempted"):
                # Busy: a photo owns the CLI. Pre-empted: a photo is
                # about to own it — give it the lock before trying again.
                self._stop.wait(self._poll)

    def _attempt(self, job: Job) -> str:
        def on_start() -> bool:
            if not self._counter.try_start():
                return False
            with self._cond:
                job.state = "running"
                job.updated = self._clock()
            return True

        try:
            run = self._runner(job.request, on_start)
        except Exception as e:  # a bug must fail the job, not the worker
            log.warning(f"Restaurant lookup worker error: {type(e).__name__}")
            run = claude_analyzer.LookupRun(status="cli_error",
                                            verdict="worker_error")
        with self._cond:
            if run is None:
                return "busy"
            if self._queue and self._queue[0] == job.job_id:
                self._queue.popleft()
            if run.status == "refused":
                self._finish_locked(job, "failed", "daily_cap")
                return "failed"
            if run.status == "preempted":
                job.preemptions += 1
                if job.preemptions >= MAX_PREEMPTIONS:
                    self._finish_locked(job, "failed", "preempted")
                    return "failed"
                job.state = "queued"
                job.updated = self._clock()
                self._queue.appendleft(job.job_id)
                return "preempted"
            if run.status != "ok":
                self._finish_locked(job, "failed", run.status)
                return "failed"
            lookup = lookup_contract.sanitize_lookup(run.result, job.request)
            if lookup is None:
                self._finish_locked(job, "failed", "bad_output")
                return "failed"
            self._finish_locked(job, "done", payload={
                "lookup": lookup,
                "cited_urls": list(run.cited_urls),
                "evidence": _evidence_by_url(run),
                "searches": run.searches,
                "analyzed_by": "claude",
            })
            return "done"


_SERVICE: Optional[LookupService] = None
_SERVICE_LOCK = threading.Lock()


def get_service(health_path_fn: Callable) -> LookupService:
    """The process-wide service, created on first use. [health_path_fn]
    is read on every count, so a test that redirects the ledger path is
    honoured."""
    global _SERVICE
    with _SERVICE_LOCK:
        if _SERVICE is None:
            _SERVICE = LookupService(DailyRunCounter(health_path_fn))
        return _SERVICE
