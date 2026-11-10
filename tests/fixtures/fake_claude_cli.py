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
  {"escapee": seconds, "pidfile": path}
                               spawn a child that calls setsid() (it
                               LEAVES our process group, so killpg misses
                               it) and keeps our stdout open; it
                               writes its own pid to pidfile AFTER the
                               setsid()
Record JSON (written before any output): argv, env, cwd, stdin, pid, pgid.

The record and the pidfiles are written whole (_write_whole): a test
polls for one to exist and may get this process killed the moment it
does, so a path that exists must already hold its full content.
"""
import json
import os
import subprocess
import sys
import time


def _write_whole(path, text):
    """Whole file or no file: written under a temporary name, then
    renamed, so [path] never names a created-but-still-empty file."""
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def _escapee(seconds, pidfile):
    os.setsid()
    _write_whole(pidfile, str(os.getpid()))
    time.sleep(seconds)


def main(scenario_path, record_path, argv):
    if argv == ["--version"]:
        sys.stdout.write("2.1.233 (Claude Code)\n")
        return
    with open(scenario_path, encoding="utf-8") as f:
        scenario = json.load(f)
    stdin = sys.stdin.read() if scenario.get("read_stdin", True) else ""
    if record_path:
        _write_whole(record_path, json.dumps({
            "argv": argv, "env": dict(os.environ),
            "cwd": os.getcwd(), "stdin": stdin,
            "pid": os.getpid(), "pgid": os.getpgid(0)}))
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
            _write_whole(step["pidfile"], str(child.pid))
        elif "escapee" in step:
            subprocess.Popen([sys.executable, os.path.abspath(__file__),
                              str(step["escapee"]), step["pidfile"]])
    sys.exit(scenario.get("exit", 0))


if __name__ == "__main__":  # the child of an "escapee" step
    _escapee(float(sys.argv[1]), sys.argv[2])
