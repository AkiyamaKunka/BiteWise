#!/usr/bin/env python3
"""Owner-run smoke test of the restaurant-lookup runner ON THE VM.

Runs ONE lookup (brand Chipotle, "chicken burrito bowl") through the
exact runner the server uses — same argv, same allowlisted environment,
same init guard — and prints only non-secret facts: the CLI version, the
init event's tool list and apiKeySource, how long the init event took,
the guard verdict, status, timings, the search count and the cited
DOMAINS. It never prints the
OAuth token, the upload key, a plan key or any other environment value.

  --init-only   stop right after the init guard passes: checks the
                guard on this CLI version and spends NO plan usage
  --record PATH also write the stream, redacted (ids, paths and every
                secret-looking env value replaced), as a .jsonl fixture
                for tests/fixtures/lookup_streams/ (file mode 0600)
  --model NAME  override CLAUDE_LOOKUP_MODEL for this run

Run it from the app directory with the service's venv, while no photo is
being analyzed (it starts a second CLI process next to the service's):

  cd /home/ubuntu/CalorieTracker && venv/bin/python scripts/lookup_smoke.py --init-only
  cd /home/ubuntu/CalorieTracker && venv/bin/python scripts/lookup_smoke.py

It needs CLAUDE_ANALYZER_ENABLED=1 (read from .env like the service) but
NOT CLAUDE_LOOKUP_ENABLED: run it before switching the endpoint on.
Exit status: 0 = ok, 1 = the run failed (see status), 2 = not configured.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import claude_analyzer  # noqa: E402  (loads .env through config)
import lookup_contract  # noqa: E402
import restaurant_lookup  # noqa: E402
import shared_generated  # noqa: E402

SAMPLE = {
    "items": [{"name": "chicken burrito bowl", "qty": 1, "unit": "bowl",
               "brand": "Chipotle"}],
    "order_merchant": "",
    "country": "US",
}
_REDACT_KEYS = frozenset({"session_id", "uuid", "cwd", "memory_paths",
                          "messaging_socket_path", "request_id"})
_SECRET_NAME = re.compile(r"(KEY|TOKEN|SECRET|PASSWORD|PASS|AUTH)",
                          re.IGNORECASE)


def secret_values(environ=None):
    """Every env value that could be a credential (name looks secret,
    value at least 8 characters), longest first."""
    environ = os.environ if environ is None else environ
    values = {v for k, v in environ.items()
              if _SECRET_NAME.search(k) and isinstance(v, str) and len(v) >= 8}
    return sorted(values, key=len, reverse=True)


def _scrub(obj):
    if isinstance(obj, dict):
        return {k: ("<redacted>" if k in _REDACT_KEYS else _scrub(v))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [_scrub(v) for v in obj]
    return obj


def redact_line(line, secrets, home=None):
    """One stream line made safe to commit as a fixture."""
    try:
        event = json.loads(line)
    except ValueError:
        return json.dumps({"type": "_redacted_non_json_line"})
    text = json.dumps(_scrub(event), ensure_ascii=False)
    for value in secrets:
        text = text.replace(value, "<redacted-secret>")
        text = text.replace(json.dumps(value)[1:-1], "<redacted-secret>")
    if home and len(home) > 1:
        text = text.replace(home, "~")
    return text


def _cli_version(cli):
    try:
        out = subprocess.run([cli, "--version"], capture_output=True,
                             stdin=subprocess.DEVNULL, text=True, timeout=20,
                             env=claude_analyzer.lookup_env())
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    words = (out.stdout or "").split()
    return words[0][:20] if words else "unknown"


def _domain(url):
    host = (urlsplit(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def sample_request():
    payload = dict(SAMPLE)
    if lookup_contract.chain_known("chipotle"):
        payload["chains"] = [{"key": "chipotle", "size": "20_plus"}]
    return lookup_contract.sanitize_request(payload)


def main(argv=None, out=None):
    out = out or sys.stdout
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--init-only", action="store_true")
    parser.add_argument("--record", metavar="PATH")
    parser.add_argument("--model")
    args = parser.parse_args(argv)

    def say(label, value):
        out.write(f"{label:<18}: {value}\n")

    cli = claude_analyzer._cli_path()
    if not claude_analyzer.is_configured() or cli is None:
        say("analyzer", claude_analyzer.status_label())
        out.write("Set CLAUDE_ANALYZER_ENABLED=1 and install the claude CLI "
                  "first.\n")
        return 2
    model = claude_analyzer.lookup_model()
    if args.model:
        if not claude_analyzer._LOOKUP_MODEL_RE.match(args.model):
            out.write("--model: not a model name\n")
            return 2
        model = args.model
    say("claude CLI", _cli_version(cli))
    say("model", model)
    say("chain table", f"{len(restaurant_lookup.US_CHAINS)} chains, as of "
                       f"{shared_generated.US_CHAINS_AS_OF}")

    recorder = None
    record_file = None
    if args.record:
        secrets = secret_values()
        home = os.environ.get("HOME", "")
        fd = os.open(args.record, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        record_file = os.fdopen(fd, "w", encoding="utf-8")

        def recorder(line):
            record_file.write(redact_line(line, secrets, home) + "\n")

    request = sample_request()
    try:
        run = claude_analyzer.lookup_restaurant(
            lookup_contract.compose_prompt(request),
            lookup_contract.lookup_schema_json(), model,
            on_line=recorder, stop_after_init=args.init_only)
    finally:
        if record_file is not None:
            record_file.close()

    init = run.init or {}
    say("init tools", ", ".join(init.get("tools") or []) or "-")
    say("apiKeySource", init.get("apiKeySource") or "-")
    say("init version", init.get("claude_code_version") or "-")
    say("init latency", f"{run.init_s:.1f}s (limit "
                        f"{claude_analyzer.lookup_init_deadline_seconds():g}s, "
                        "CLAUDE_LOOKUP_INIT_SECONDS)" if run.lines_read
        else "-")
    say("memory_paths", "present" if init.get("memory_paths") else "absent")
    say("guard", "FAIL " + run.verdict if run.status == "guard_fail"
        else "pass")
    say("status", f"{run.status} ({run.verdict}) in {run.duration_s:.1f}s")
    if run.verdict == "guard_fail:apiKeySource" and init.get("apiKeySource"):
        out.write("  If this apiKeySource is expected for your login, add "
                  "CLAUDE_LOOKUP_KEY_SOURCE=<that value> to .env and rerun.\n")
    if args.init_only:
        return 0 if run.status == "init_ok" else 1

    domains = []
    for url in run.cited_urls:
        domain = _domain(url)
        if domain and domain not in domains:
            domains.append(domain)
    say("searches", run.searches)
    say("cited domains", ", ".join(domains) or "-")
    lookup = (lookup_contract.sanitize_lookup(run.result, request)
              if run.result is not None else None)
    if lookup is not None:
        source = _domain(lookup["source_url"] or "") or "-"
        say("lookup", f"{lookup['status']}, chain={lookup['chain_key']}, "
                      f"matches={len(lookup['matches'])}, source={source} "
                      f"({lookup['source_type']})")
    elif run.status == "ok":
        say("lookup", "answer failed the section-5 shape")
    say("chipotle.com cited", "yes" if any(
        d == "chipotle.com" or d.endswith(".chipotle.com") for d in domains)
        else "no")
    if args.record:
        say("recorded", args.record)
    return 0 if run.status == "ok" and lookup is not None else 1


if __name__ == "__main__":
    sys.exit(main())
