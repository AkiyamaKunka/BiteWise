"""Shared service-health ledger stored in logs/service_health.json.

telegram_bot.py and daily_report.py both record into this file; the load/save
mechanics and the daily_report + activity-sync record schemas live here so the
two writers cannot drift.
"""

import fcntl
import json
import os
import threading
from datetime import datetime
from pathlib import Path
from typing import Optional

DEFAULT_PATH = Path.home() / "CalorieTracker" / "logs" / "service_health.json"

MAX_EVENTS = 50


def timestamp() -> str:
    return datetime.now().isoformat(timespec="seconds")


def load(path=DEFAULT_PATH, warn=print) -> dict:
    try:
        data = json.loads(Path(path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    except OSError as e:
        warn(f"Could not read service health file: {e}")
        return {}
    # Valid JSON that is not an object gets the same fail-open treatment as
    # invalid JSON: every consumer (and update()'s mutate callbacks) assumes
    # a dict, and a crash here at boot would be unrecoverable.
    return data if isinstance(data, dict) else {}


def save(data, path=DEFAULT_PATH, warn=print):
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
        tmp_path.write_text(json.dumps(data, indent=2, sort_keys=True))
        tmp_path.replace(path)
    except OSError as e:
        warn(f"Could not write service health file: {e}")


def update(mutate, path=DEFAULT_PATH, warn=print) -> dict:
    """Read-modify-write the health file under an inter-process lock.

    The bot process and the cron daily_report process write the same file;
    without the lock, overlapping read-modify-write cycles can silently drop
    the other writer's record (e.g. erase an active Gemini quota pause).
    """
    path = Path(path)
    lock_path = path.with_name(path.name + ".lock")
    data = {}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(lock_path, "w") as lock_file:
            fcntl.flock(lock_file, fcntl.LOCK_EX)
            data = load(path, warn=warn)
            mutate(data)
            save(data, path, warn=warn)
    except OSError as e:
        warn(f"Could not update service health file: {e}")
    return data


def _apply_attempt(data: dict, key: str, ok: bool, target_date: str, *,
                   source: str, error_summary: str = "",
                   extra: Optional[dict] = None) -> dict:
    """Mutate `data` in place with one attempt record under ``data[key]``.

    The daily_report and activity records share this schema, so a fix to
    it (the event cap, the summary truncation) lands once. [extra] holds
    record-specific fields written with the attempt.
    """
    record = data.setdefault(key, {})
    now = timestamp()
    record["last_attempt_at"] = now
    record["last_target_date"] = target_date
    record["last_source"] = source
    record["last_ok"] = ok
    record.update(extra or {})

    if ok:
        record["last_success_at"] = now
        record["consecutive_failures"] = 0
        record.pop("last_error_summary", None)
    else:
        record["last_error_at"] = now
        record["last_error_summary"] = str(error_summary or "")[:500]
        record["consecutive_failures"] = int(record.get("consecutive_failures", 0)) + 1

    events = record.setdefault("events", [])
    events.append({
        "at": now,
        "ok": ok,
        "target_date": target_date,
        "source": source,
    })
    record["events"] = events[-MAX_EVENTS:]
    return data


def apply_report_health(data: dict, ok: bool, target_date: str, *, source: str,
                        report_path: str = "", error_summary: str = "") -> dict:
    """Mutate `data` in place with a daily_report attempt record."""
    return _apply_attempt(
        data, "daily_report", ok, target_date, source=source,
        error_summary=error_summary,
        extra={"last_report_path": report_path} if report_path else None)


def apply_activity_health(data: dict, ok: bool, target_date: str, *, source: str,
                          error_summary: str = "") -> dict:
    """Mutate `data` in place with an activity-sync attempt record.

    The same schema as :func:`apply_report_health`, written to
    ``data['activity']`` so the Garmin (or other source) daily pull is
    observable in the shared health ledger without colliding with the
    daily_report record.
    """
    return _apply_attempt(data, "activity", ok, target_date, source=source,
                          error_summary=error_summary)
