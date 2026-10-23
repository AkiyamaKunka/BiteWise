"""A fake `claude` CLI for the restaurant-lookup runner tests.

The runner hands its child an allowlisted environment only, so a scenario
cannot travel in env vars: tests/lookup_fakes.make_cli writes a tiny
executable wrapper (shebang = the test interpreter) that calls main()
with the scenario and record paths baked in.

Scenario JSON: {"steps": [...], "exit": int, "read_stdin": bool}
  {"line": <obj or str>}       one stdout line (objects are JSON-encoded)
  {"raw": "<text>"}            raw stdout text, no newline added
  {"sleep": seconds}
  {"grandchild": seconds, "pidfile": path}
                               spawn `sleep` sharing our stdout and
                               process group, its pid written to pidfile
Record JSON (written before any output): argv, env, cwd, stdin, pid, pgid.
"""
import json
import os
import subprocess
import sys
import time


def main(scenario_path, record_path, argv):
    if argv == ["--version"]:
        sys.stdout.write("2.1.233 (Claude Code)\n")
        return
    with open(scenario_path, encoding="utf-8") as f:
        scenario = json.load(f)
    stdin = sys.stdin.read() if scenario.get("read_stdin", True) else ""
    if record_path:
        with open(record_path, "w", encoding="utf-8") as f:
            json.dump({"argv": argv, "env": dict(os.environ),
                       "cwd": os.getcwd(), "stdin": stdin,
                       "pid": os.getpid(), "pgid": os.getpgid(0)}, f)
    for step in scenario.get("steps", []):
        if "line" in step:
            line = step["line"]
            if not isinstance(line, str):
                line = json.dumps(line)
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        elif "raw" in step:
            sys.stdout.write(step["raw"])
            sys.stdout.flush()
        elif "sleep" in step:
            time.sleep(step["sleep"])
        elif "grandchild" in step:
            child = subprocess.Popen(["sleep", str(step["grandchild"])])
            with open(step["pidfile"], "w", encoding="utf-8") as f:
                f.write(str(child.pid))
    sys.exit(scenario.get("exit", 0))
