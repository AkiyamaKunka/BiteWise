"""
Claude-first food photo analysis via the Claude Code CLI.

Runs the analysis on the user's Claude subscription (headless `claude -p`
with a CLAUDE_CODE_OAUTH_TOKEN minted by `claude setup-token`) instead of a
metered API key. This module is a best-effort PRIMARY: any failure — CLI
absent, token invalid, usage-window exhausted, timeout, malformed output —
returns None and the caller falls back to Gemini, so the bot never degrades
below today's behavior.

Dispatch modes (CLAUDE_ANALYZER_DISPATCH):
  stream (default)  Single model turn: the image travels on stdin as a
                    base64 content block via `--input-format stream-json`,
                    so no temp file and no Read-tool round trip. Measured on
                    the production VM: ~8.2-8.4s wall vs 16.0s for the
                    two-turn path, num_turns=1, same-quality output. If the
                    attempt fails for CLI-shape reasons (older CLIs without
                    stream-json support exit nonzero here), the analyzer
                    logs once and retries ONCE via the file path below —
                    within the same _CLI_LOCK hold.
  file              Two model turns: the image is written to a temp file and
                    the model Reads it back. Forces the old path only —
                    a rollback knob, never combined with a stream attempt.

Configuration (env / .env):
  CLAUDE_ANALYZER_ENABLED           truthy to enable (default: off)
  CLAUDE_ANALYZER_BIN               CLI binary (default: "claude")
  CLAUDE_ANALYZER_MODEL             optional --model override (claude backend)
  CLAUDE_ANALYZER_TIMEOUT_SECONDS   per-analysis wall clock (default: 120)
  CLAUDE_ANALYZER_EXTRA_FLAGS       optional extra CLI flags (shlex-split)
  CLAUDE_ANALYZER_DISPATCH          'stream' (default) or 'file' (see above)
  CLAUDE_CODE_OAUTH_TOKEN           subscription token (read by the CLI itself)
  GLM_PLAN_KEY                      Zhipu GLM Coding Plan key → 'glm' backend
  DOUBAO_PLAN_KEY                   Volcengine Agent Plan key → 'doubao' backend

Subscription backends (the [backend] parameter):
  The SAME Claude Code CLI can run against two other vendors' subscription
  plans — both officially document Claude Code as a supported tool, so this
  is their sanctioned use, not impersonation (facts verified 2026-07-30):
    glm     Zhipu GLM Coding Plan: ANTHROPIC_BASE_URL=
            https://open.bigmodel.cn/api/anthropic + plan key as the auth
            token. That endpoint is TEXT-ONLY, so photos go through Zhipu's
            OFFICIAL vision MCP server (@z_ai/mcp-server, GLM-4.6V) reading
            a local temp file — needs npx on this machine.
    doubao  Volcengine Ark Agent Plan: ANTHROPIC_BASE_URL=
            https://ark.cn-beijing.volces.com/api/plan + plan key. Direct
            API calls with a plan key are a documented ban risk — the plan
            is valid ONLY through whitelisted tools, and running the real
            Claude Code CLI is exactly that. Image input over this endpoint
            is undocumented: the stream dispatch sends the photo as a
            base64 block and a rejection surfaces as an ordinary failed run
            (→ None → the caller's fallback), never a crash.
  Both backends scrub CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY from the
  child env so a vendor run can never accidentally spend the Anthropic
  subscription or an API key.
"""

import base64
import json
import logging
import os
import re
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

from config import FOOD_DETECTION_PROMPT
from utils import parse_ai_json, parse_boolish

log = logging.getLogger("claude_analyzer")

class AnalyzerBusy(Exception):
    """Another photo owns the single-flight CLI right now.

    Distinct from a None return, which means the run HAPPENED and failed
    (junk reply, blind GLM run) — those are terminal for this photo, and
    the app must not spend three more 120 s CLI runs on them. A timeout
    is neither: see AnalyzerTimeout. The endpoints map busy → retryable
    503, terminal → non-retryable, timeout → "come back later".
    """


class AnalyzerTimeout(Exception):
    """The CLI run hit the wall-clock limit before the model answered.

    Distinct from None (the model ANSWERED, with junk — terminal) and
    from PlanRefused (the plan said no). Nothing about the photo caused
    it — a slow model or a loaded VM did — and the same photo analyzes
    fine an hour later. Until 2026-10-07 this surfaced as the terminal
    "produced no usable result" and the app burned the photo for good
    while its UI promised an automatic retry. Raised ONLY to API callers
    (raise_on_busy=True); the Telegram path keeps its documented
    "None → use Gemini" contract.
    """

    def __init__(self, seconds: int):
        super().__init__(f"the analysis timed out after {seconds} s")
        self.seconds = seconds
        self.reason = f"the analysis timed out after {seconds} s"


# The CLI is a full Node process (hundreds of MB RSS). Single-flight: only
# one run at a time, and a contended caller does NOT queue — it returns None
# immediately so the photo falls through to Gemini instead of waiting out
# another photo's full CLI run (measured ~42-63s cards on album bursts). The
# subprocess timeout bounds how long the one holder keeps the lock.
#
# The one exception to "a contended caller does not wait": a background
# RESTAURANT LOOKUP (run_lookup_exclusive) never makes a photo, leftover
# or text request wait or fail. Those callers pre-empt it — the lookup's
# process group is killed and the caller waits at most
# PREEMPT_WAIT_SECONDS for the lock (_acquire_cli_for_foreground). The
# lookup job is requeued by lookup_jobs.
_CLI_LOCK = threading.Lock()
PREEMPT_WAIT_SECONDS = 5

# Who holds _CLI_LOCK for a lookup, and its process (for pre-emption).
_LOOKUP_STATE_LOCK = threading.Lock()
_LOOKUP_STATE: Dict[str, object] = {
    "holding": False, "proc": None, "preempted": False}


def _acquire_cli_for_foreground() -> bool:
    """_CLI_LOCK for a photo/leftover/text request. Contended by another
    FOREGROUND request: False at once, as always. Contended by a lookup:
    kill the lookup and wait (bounded) for the lock it releases."""
    if _CLI_LOCK.acquire(blocking=False):
        return True
    if not preempt_lookup():
        return False
    return _CLI_LOCK.acquire(timeout=PREEMPT_WAIT_SECONDS)


def _timeout_seconds() -> int:
    try:
        value = int(os.environ.get("CLAUDE_ANALYZER_TIMEOUT_SECONDS", "120"))
    except ValueError:
        return 120
    return min(max(value, 10), 600)


def _cli_path() -> Optional[str]:
    return shutil.which(os.environ.get("CLAUDE_ANALYZER_BIN", "claude") or "claude")


def is_enabled() -> bool:
    """The CLAUDE_ANALYZER_ENABLED knob alone, ignoring CLI presence."""
    return parse_boolish(os.environ.get("CLAUDE_ANALYZER_ENABLED")) is True


def is_configured() -> bool:
    """Enabled by knob AND the CLI is actually installed.

    The OAuth token is deliberately not required here: the CLI may hold its
    own stored login, and a missing/expired token simply fails the run —
    which the caller already treats as "fall back to Gemini".
    """
    return is_enabled() and _cli_path() is not None


def status_label() -> str:
    """One-phrase analyzer state for /config and /doctor."""
    if not is_enabled():
        return "off"
    if _cli_path() is None:
        return "enabled, CLI missing"
    return "enabled"


def _dispatch_mode() -> str:
    """'file' forces the two-turn temp-file path (the rollback knob);
    anything else — unset, 'stream', or a typo — takes the stream default."""
    raw = (os.environ.get("CLAUDE_ANALYZER_DISPATCH") or "").strip().lower()
    return "file" if raw == "file" else "stream"


# ─── Subscription backends ────────────────────────────────────────────
SUBSCRIPTION_BACKENDS = ("claude", "glm", "doubao")

_BACKEND_BASE_URLS = {
    "glm": "https://open.bigmodel.cn/api/anthropic",
    "doubao": "https://ark.cn-beijing.volces.com/api/plan",
}
_BACKEND_KEY_ENVS = {"glm": "GLM_PLAN_KEY", "doubao": "DOUBAO_PLAN_KEY"}
_BACKEND_LABELS = {
    "claude": "Claude (subscription)",
    "glm": "GLM (coding plan)",
    "doubao": "Doubao (agent plan)",
}


def _backend_key(backend: str) -> Optional[str]:
    env_name = _BACKEND_KEY_ENVS.get(backend)
    if not env_name:
        return None
    key = (os.environ.get(env_name) or "").strip()
    return key or None


def _npx_path() -> Optional[str]:
    return shutil.which("npx")


def backend_available(backend: str, for_photo: bool = False) -> bool:
    """Can [backend] serve a request right now? 'claude' rides the existing
    knobs; the vendor plans need their key — and, for GLM photos only, npx
    (the official vision MCP server is an npm package)."""
    if not is_configured():
        return False
    if backend == "claude":
        return True
    if backend not in _BACKEND_KEY_ENVS:
        return False
    if _backend_key(backend) is None:
        return False
    if backend == "glm" and for_photo and _npx_path() is None:
        return False
    return True


def login_state() -> str:
    """Whether this machine holds a Claude-plan sign-in for the CLI.

    'token' when the setup-token OAuth credential the phone's "Connect
    Claude" flow mints is present in the environment, else 'none'. Surfaced
    on /api/auth_check so a freshly provisioned phone can SEE that the
    server is already signed in instead of implying a re-connect is needed
    (2026-09-28). Presence, not validity: validity is proven by the next
    real analysis, whose auth failure the app reports explicitly.
    """
    return "token" if (os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or "").strip() else "none"


def backend_status() -> Dict[str, str]:
    """Per-backend one-phrase state for /api/auth_check — the phone's
    'Test connection' shows these so a missing server-side plan key is
    diagnosed from the couch, not from ssh."""
    status: Dict[str, str] = {"claude": status_label()}
    for backend in ("glm", "doubao"):
        if not is_enabled():
            status[backend] = "off"
        elif _cli_path() is None:
            status[backend] = "enabled, CLI missing"
        elif _backend_key(backend) is None:
            status[backend] = f"no key ({_BACKEND_KEY_ENVS[backend]})"
        elif backend == "glm" and _npx_path() is None:
            status[backend] = "key set, npx missing (vision MCP needs node)"
        else:
            status[backend] = "ready"
    return status


def _build_prompt(image_path: str, prompt: Optional[str] = None) -> str:
    return (
        f"Read the image file at {image_path} and analyze it.\n\n"
        f"{prompt or FOOD_DETECTION_PROMPT}"
    )


def _extra_flags() -> list:
    """CLAUDE_ANALYZER_EXTRA_FLAGS, shlex-split into argv elements.

    A malformed value (unbalanced quote) degrades to no extra flags — the
    analyzer must keep working rather than fail every photo on a typo.
    """
    raw = (os.environ.get("CLAUDE_ANALYZER_EXTRA_FLAGS") or "").strip()
    if not raw:
        return []
    try:
        return shlex.split(raw)
    except ValueError as e:
        log.warning(f"Ignoring malformed CLAUDE_ANALYZER_EXTRA_FLAGS: {e}")
        return []


# The app-facing per-request choices (2026-08-05). CLAUDE-ONLY, closed
# whitelists: these values become CLI argv, so free text is never accepted
# — the endpoints 400 anything else before a CLI run exists.
CLAUDE_PLAN_MODELS = ("opus", "sonnet", "haiku", "fable")
CLAUDE_PLAN_EFFORTS = ("low", "medium", "high")


def _append_model_and_extra_flags(
    cmd: list, backend: str = "claude",
    model: Optional[str] = None, effort: Optional[str] = None,
) -> None:
    """Shared argv tail: optional --model/--effort, then extra flags last.

    The overrides are CLAUDE-ONLY: the vendor plans map Anthropic model
    names to their own models server-side (GLM: sonnet→glm-5.2; Doubao:
    per plan tier), and an Anthropic model id pushed at them is at best
    ignored and at worst a 400 on every photo. [model]/[effort] come from
    the API endpoints PRE-VALIDATED against the whitelists above; the env
    knob remains the owner's default when no request override arrives.
    """
    if backend == "claude":
        chosen = (model or "").strip() if model in CLAUDE_PLAN_MODELS else ""
        if not chosen:
            chosen = (os.environ.get("CLAUDE_ANALYZER_MODEL") or "").strip()
        if chosen:
            cmd += ["--model", chosen]
        if effort in CLAUDE_PLAN_EFFORTS:
            cmd += ["--effort", effort]
    cmd += _extra_flags()


def _cli_env(backend: str = "claude") -> Dict[str, str]:
    # The CLI phones home for updates/telemetry on every run; both knobs
    # shave that off (and are harmless no-ops on CLIs that predate them).
    env = dict(os.environ)
    env["DISABLE_AUTOUPDATER"] = "1"
    env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    if backend in _BACKEND_BASE_URLS:
        env["ANTHROPIC_BASE_URL"] = _BACKEND_BASE_URLS[backend]
        env["ANTHROPIC_AUTH_TOKEN"] = _backend_key(backend) or ""
        # Scrub the Anthropic credentials: a vendor-plan run must never be
        # able to fall through to (and spend) the Claude subscription or an
        # API key — and the CLI prefers some of these over AUTH_TOKEN.
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        env.pop("ANTHROPIC_API_KEY", None)
        # Zhipu's own Claude Code setup doc prescribes a long API timeout;
        # harmless for Ark. Never override an operator's explicit value.
        env.setdefault("API_TIMEOUT_MS", "3000000")
    return env


def _stream_stdin(image_bytes: bytes, prompt: Optional[str] = None) -> str:
    """One stream-json user message: the analysis prompt plus the image as a
    base64 content block. Callers pass already-normalized JPEG bytes (the
    single-decode photo pipeline), hence the fixed image/jpeg media type."""
    message = {
        "type": "user",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Analyze the attached image.\n\n"
                            f"{prompt or FOOD_DETECTION_PROMPT}",
                },
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64.b64encode(image_bytes).decode("ascii"),
                    },
                },
            ],
        },
    }
    return json.dumps(message) + "\n"


def _parse_stream_result(stdout: str) -> Optional[Dict]:
    """The LAST {"type": "result"} line of the stream-json JSONL output —
    the same envelope shape as `--output-format json` (is_error, result,
    duration_ms, duration_api_ms, num_turns). Non-JSON lines and result-less
    events (init/assistant messages, stray warnings) are tolerated noise."""
    envelope = None
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            candidate = json.loads(line)
        except ValueError:
            continue
        if isinstance(candidate, dict) and candidate.get("type") == "result":
            envelope = candidate
    return envelope


def _result_text(envelope) -> Optional[str]:
    """The result string of a non-error envelope; None for any other shape."""
    if not isinstance(envelope, dict) or envelope.get("is_error"):
        return None
    text = envelope.get("result")
    if not isinstance(text, str) or not text.strip():
        return None
    return text


class PlanRefused(Exception):
    """The plan itself refused this run — not a CLI-shape failure.

    Distinct from None (the run happened and answered junk) and from
    AnalyzerBusy (contention). The model is simply not served by this
    subscription right now: a usage window is exhausted, or the chosen
    model needs purchased credits the plan does not include (Fable 5 on
    a Pro plan, verified live 2026-08-06). Retrying NOW — in place OR via
    the file path — reproduces it exactly, so callers must surface the
    REASON to the user instead of a generic 'no usable result'.

    [terminal] separates the two refusals, because only one of them is
    forever (2026-10-07): a model that needs credits stays refused until
    the user switches models, but a closed usage window reopens on its
    own schedule and the photo must survive until then. The API endpoints
    answer "retry": False for the first and "retry": "later" for the
    second; the installed app burned photos on False.
    """

    def __init__(self, reason: str, terminal: bool = False):
        super().__init__(reason)
        self.reason = reason
        self.terminal = terminal


def _plan_refusal(stdout: str) -> Optional[PlanRefused]:
    """The PlanRefused (not raised) a stream output describes, or None.

    The CLI reports these as a terminal result envelope carrying
    is_error with an api_error_status (429), and/or a rate_limit_event
    whose errorCode is credits_required. Its own `result` text is already
    written for a human ("Fable 5 requires usage credits."), so it is
    preferred verbatim over anything we could invent.

    terminal is True only for the credits case — the errorCode says
    credits_required, or the CLI's sentence says credits. A bare 429 or a
    rejected rate_limit_info without that code is the plan's usage
    window: closed now, open later.
    """
    refused = False
    terminal = False
    message = None
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "rate_limit_event":
            info = event.get("rate_limit_info")
            if isinstance(info, dict):
                if info.get("errorCode") == "credits_required":
                    refused = True
                    terminal = True
                elif info.get("status") == "rejected":
                    refused = True
        if event.get("type") == "result" and event.get("is_error"):
            status = event.get("api_error_status")
            text = event.get("result")
            says_credits = isinstance(text, str) and "credit" in text.lower()
            if status == 429 or says_credits:
                refused = True
            if says_credits:
                terminal = True
            if isinstance(text, str) and text.strip():
                message = text.strip()
    if not refused:
        return None
    return PlanRefused(
        message or "this plan cannot serve the selected model right now",
        terminal=terminal)


def _log_cli_exit(proc) -> None:
    text = (proc.stderr or proc.stdout or "").strip()
    # Redact BEFORE truncating: a CLI that echoes a bad argument back into
    # stderr (e.g. "MCP config file not found: {...Z_AI_API_KEY...}") must
    # not put a plan key into the server log — and truncating first could
    # leave a recognizable key fragment straddling the cut.
    for backend in _BACKEND_KEY_ENVS:
        key = _backend_key(backend)
        if key:
            text = text.replace(key, "[redacted-plan-key]")
    snippet = text[:300]
    if "limit" in snippet.lower():
        log.warning(f"Claude CLI usage window likely exhausted: {snippet}")
    else:
        log.warning(f"Claude CLI exited {proc.returncode}: {snippet}")


def _finish_analysis(
    envelope: Dict, result_text: str, start: float,
    backend: str = "claude",
    require_is_food: bool = True,
) -> Optional[Dict]:
    """is_food-contract validation + success instrumentation, shared by all
    dispatch paths. None here means the MODEL answered junk — callers must
    treat it as terminal and never retry-spend on a model that answered.

    [require_is_food] False is the LEFTOVER estimation contract
    (2026-08-05): those replies are {same_meal, leftover_fraction, items}
    — still a dict, but the food gate does not apply; the app's pure
    apply layer owns every numeric clamp."""
    try:
        analysis = parse_ai_json(result_text)
    except (json.JSONDecodeError, ValueError) as e:
        # Keep the evidence: an empty reply, a rate-limit sentence and a
        # truncated object all read as "Expecting value" — the snippet is
        # what tells them apart next time (2026-09-29, 1 of 46 photos).
        snippet = repr((result_text or "")[:200])
        log.warning(f"Could not parse Claude analysis JSON: {e} "
                    f"(len={len(result_text or '')}, head={snippet})")
        return None
    if not isinstance(analysis, dict):
        log.warning("Claude analysis JSON was not an object.")
        return None
    if require_is_food and "is_food" not in analysis:
        log.warning("Claude analysis JSON missing the is_food contract.")
        return None
    # The CLI has no JSON mode, so is_food may arrive as a quoted
    # "false" — truthy downstream. Coerce to a real bool or reject.
    if require_is_food and not isinstance(analysis["is_food"], bool):
        coerced = parse_boolish(analysis["is_food"])
        if coerced is None:
            log.warning("Claude analysis is_food was not boolean-like.")
            return None
        analysis["is_food"] = coerced
    # Envelope timings split CLI overhead from API time, and num_turns
    # proves which dispatch actually answered (1 = single-turn stream) —
    # the evidence trail for tuning without touching the model choice.
    wall = time.time() - start
    label = _BACKEND_LABELS.get(backend, backend)
    log.info(
        f"✅ Photo analyzed by {label} in {wall:.1f}s "
        f"(cli={envelope.get('duration_ms')}ms "
        f"api={envelope.get('duration_api_ms')}ms "
        f"turns={envelope.get('num_turns')})."
    )
    return analysis


def _attempt_stream(
    cli: str, image_bytes: bytes, env: Dict[str, str], start: float,
    prompt: Optional[str] = None, backend: str = "claude",
    require_is_food: bool = True,
    model: Optional[str] = None, effort: Optional[str] = None,
) -> Tuple[Optional[Dict], bool]:
    """Single-turn dispatch: image on stdin, no temp file, no tool turns.

    Returns (analysis, retry_via_file). retry_via_file is True only for
    CLI-shape failures — nonzero exit, no result line, unusable envelope —
    the cases an older CLI without stream-json support produces. A model
    that answered junk is terminal (None, False): retrying would
    double-spend the subscription for the same photo. A timeout raises
    AnalyzerTimeout — never a file-path retry either (it would double the
    wall clock for one photo), but the photo is fine to try again LATER.
    """
    cmd = [
        cli, "-p",
        # stdin carries the image; --input-format stream-json ERRORS unless
        # the output format matches, and -p only streams with --verbose.
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--tools", "",  # no tools: the answer must land in turn one
    ]
    _append_model_and_extra_flags(cmd, backend, model=model, effort=effort)
    try:
        proc = subprocess.run(
            cmd,
            input=_stream_stdin(image_bytes, prompt),
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            env=env,
        )
        if proc.returncode != 0:
            # A PLAN refusal exits nonzero too, but it is not a CLI-shape
            # failure: the file fallback would reproduce it verbatim and
            # the user needs the reason, not a retry (Fable-on-Pro,
            # 2026-08-06).
            refusal = _plan_refusal(proc.stdout)
            if refusal:
                log.warning(
                    f"Claude plan refused the run "
                    f"({'terminal' if refusal.terminal else 'usage window'})"
                    f": {refusal.reason}")
                raise refusal
            _log_cli_exit(proc)
            return None, True
        envelope = _parse_stream_result(proc.stdout)
        if envelope is None:
            log.warning("Claude CLI stream output had no result line.")
            return None, True
        text = _result_text(envelope)
        if text is None:
            log.warning("Claude CLI stream result envelope was unusable.")
            return None, True
        return _finish_analysis(envelope, text, start, backend,
                                require_is_food=require_is_food), False
    except subprocess.TimeoutExpired:
        log.warning(f"Claude CLI timed out after {_timeout_seconds()}s.")
        # Raised from inside the handler, so the catch-all below does not
        # see it (sibling clauses never catch each other's raises).
        raise AnalyzerTimeout(_timeout_seconds())
    except PlanRefused:
        # Must reach the caller: the catch-all below would turn an
        # actionable "this plan cannot serve that model" into a silent
        # None, which is exactly the failure this class exists to end.
        raise
    except Exception as e:
        log.warning(f"Claude analyzer failed unexpectedly: {type(e).__name__}: {e}")
        return None, False


def _zai_mcp_config(key: str) -> str:
    """Inline --mcp-config JSON for Zhipu's OFFICIAL vision MCP server
    (docs.bigmodel.cn coding-plan vision-mcp doc): the coding-plan key IS
    the intended credential, Z_AI_MODE=ZHIPU selects the mainland platform."""
    return json.dumps({
        "mcpServers": {
            "zai": {
                "command": "npx",
                "args": ["-y", "@z_ai/mcp-server"],
                "env": {"Z_AI_API_KEY": key, "Z_AI_MODE": "ZHIPU"},
            }
        }
    })


def _attempt_glm_vision(
    cli: str, image_bytes: bytes, env: Dict[str, str], start: float,
    prompt: Optional[str] = None,
    require_is_food: bool = True,
) -> Optional[Dict]:
    """GLM-backend photo dispatch: temp file + the official zai vision MCP.

    The GLM coding-plan Anthropic endpoint is TEXT-ONLY — an image content
    block never reaches a vision model there. Zhipu's sanctioned photo path
    for plan users is their first-party vision MCP server (GLM-4.6V) reading
    a LOCAL file, so this dispatch mirrors _attempt_file's temp-file shape
    but allows ONLY the zai MCP tools — never Read. A steered prompt could
    at worst point the vision tool at another IMAGE on this machine; it
    cannot read .env or any text secret, which is the exfiltration class the
    allow_file_fallback rule exists to stop.
    """
    key = _backend_key("glm")
    if key is None:
        return None
    if _npx_path() is None:
        log.warning("GLM vision needs npx (node) for @z_ai/mcp-server — "
                    "not installed on this machine.")
        return None
    tmp_path = None
    cfg_path = None
    work_dir = None
    try:
        # A dedicated EMPTY working directory: the image and the config
        # used to share /tmp, so the run's cwd contained the plan-key file.
        work_dir = tempfile.mkdtemp(prefix="ct_glm_run_")
        with tempfile.NamedTemporaryFile(
            prefix="ct_glm_", suffix=".jpg", delete=False, dir=work_dir
        ) as tmp:
            tmp_path = tmp.name
            tmp.write(image_bytes)
        # The mcp-config goes through a 0600 TEMP FILE, never inline argv:
        # inline JSON put the plan key into /proc/<pid>/cmdline for the
        # whole run, and a CLI that echoes a rejected argument into stderr
        # would hand it to _log_cli_exit (review 2026-07-30).
        # The config lives OUTSIDE work_dir on purpose (see above).
        with tempfile.NamedTemporaryFile(
            prefix="ct_glm_cfg_", suffix=".json", mode="w", delete=False
        ) as cfg:
            cfg_path = cfg.name
            cfg.write(_zai_mcp_config(key))

        cmd = [
            cli, "-p",
            (f"Use the zai vision tool to analyze the image file at "
             f"{tmp_path}, then answer.\n\n"
             f"{prompt or FOOD_DETECTION_PROMPT}"),
            "--output-format", "json",
            "--mcp-config", cfg_path,
            "--allowedTools", "mcp__zai",
            # --allowedTools is an AUTO-APPROVE list, not a disable list:
            # the built-in read-only tools stay available to a prompt that
            # carries caller-influenced text (the app's dietary profile).
            # Name them explicitly forbidden, and run in a scratch cwd —
            # the previous cwd held the temp MCP CONFIG with the plan key.
            "--disallowedTools", "Read,Glob,Grep,LS,Bash,Write,Edit,WebFetch",
            "--strict-mcp-config",
        ]
        _append_model_and_extra_flags(cmd, "glm")
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            cwd=work_dir,
            env=env,
        )
        if proc.returncode != 0:
            _log_cli_exit(proc)
            return None
        envelope = json.loads(proc.stdout)
        text = _result_text(envelope)
        if text is None:
            log.warning("GLM CLI returned an unusable result envelope.")
            return None
        # PROVE the vision tool actually ran. If the MCP server fails
        # after launch (npm registry unreachable, startup crash) the CLI
        # continues WITHOUT the tool and the model answers about an image
        # it never saw — and the prompt's "unclear → not food" rule makes
        # that a contract-valid wrong verdict. A real tool round-trip is
        # ≥2 turns; a single-turn envelope here is a blind run.
        turns = envelope.get("num_turns")
        if not isinstance(turns, int) or turns < 2:
            log.warning(
                f"GLM vision run had no tool round-trip (num_turns={turns})"
                " — the zai MCP server likely failed to start; discarding "
                "the blind answer.")
            return None
        return _finish_analysis(envelope, text, start, "glm",
                                require_is_food=require_is_food)
    except subprocess.TimeoutExpired:
        log.warning(f"GLM CLI timed out after {_timeout_seconds()}s.")
        raise AnalyzerTimeout(_timeout_seconds())
    except (json.JSONDecodeError, ValueError) as e:
        log.warning(f"Could not parse GLM CLI output: {e}")
        return None
    except Exception as e:
        log.warning(f"GLM analyzer failed unexpectedly: {type(e).__name__}: {e}")
        return None
    finally:
        for p in (tmp_path, cfg_path):
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        if work_dir:
            try:
                os.rmdir(work_dir)
            except OSError:
                pass


def _attempt_file(
    cli: str, image_bytes: bytes, env: Dict[str, str], start: float,
    prompt: Optional[str] = None,
    model: Optional[str] = None, effort: Optional[str] = None,
) -> Optional[Dict]:
    """Two-turn dispatch: temp image file + a Read-tool prompt. The
    compatibility fallback for CLIs without stream-json support, and the
    forced path under CLAUDE_ANALYZER_DISPATCH=file."""
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix="ct_claude_", suffix=".jpg", delete=False
        ) as tmp:
            # Record the path before writing so a failed write (e.g. ENOSPC)
            # still gets the file cleaned up by the finally block.
            tmp_path = tmp.name
            tmp.write(image_bytes)

        cmd = [
            cli, "-p", _build_prompt(tmp_path, prompt),
            "--output-format", "json",
            "--allowedTools", "Read",
        ]
        _append_model_and_extra_flags(cmd, model=model, effort=effort)
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            cwd=str(Path(tmp_path).parent),
            env=env,
        )
        if proc.returncode != 0:
            _log_cli_exit(proc)
            return None

        # `claude -p --output-format json` wraps the reply in a result envelope.
        envelope = json.loads(proc.stdout)
        text = _result_text(envelope)
        if text is None:
            log.warning("Claude CLI returned an unusable result envelope.")
            return None
        return _finish_analysis(envelope, text, start)
    except subprocess.TimeoutExpired:
        log.warning(f"Claude CLI timed out after {_timeout_seconds()}s.")
        raise AnalyzerTimeout(_timeout_seconds())
    except (json.JSONDecodeError, ValueError) as e:
        log.warning(f"Could not parse Claude CLI output: {e}")
        return None
    except Exception as e:
        log.warning(f"Claude analyzer failed unexpectedly: {type(e).__name__}: {e}")
        return None
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def analyze_text_prompt(prompt: str, backend: str = "claude",
                        model: Optional[str] = None,
                        effort: Optional[str] = None,
                        raise_on_busy: bool = False) -> Optional[Dict]:
    """Run an arbitrary JSON-answering prompt through the CLI (subscription).

    Used by the app-facing /api/text_intent endpoint so the phone's NL
    corrections cost no API money either. Same discipline as the photo path:
    single turn, no tools, serialized by _CLI_LOCK, and a contended CLI
    returns None (caller decides — the app falls back to its own provider)
    rather than queueing behind a 120 s photo run. Text works on ALL three
    backends: the vendor plans' Anthropic endpoints are text-native.
    """
    if backend not in SUBSCRIPTION_BACKENDS:
        return None
    if not backend_available(backend):
        return None
    cli = _cli_path()
    if cli is None or not (prompt or "").strip():
        return None
    if not _acquire_cli_for_foreground():
        log.info("Claude CLI busy — text intent declined.")
        if raise_on_busy:
            raise AnalyzerBusy()
        return None
    start = time.time()
    try:
        cmd = [cli, "-p", "--output-format", "json", "--tools", ""]
        _append_model_and_extra_flags(cmd, backend, model=model,
                                      effort=effort)
        proc = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=_timeout_seconds(),
            env=_cli_env(backend),
        )
        if proc.returncode != 0:
            _log_cli_exit(proc)
            return None
        try:
            envelope = json.loads(proc.stdout or "{}")
        except ValueError:
            log.warning("Claude CLI text output was not JSON.")
            return None
        text = _result_text(envelope)
        if text is None:
            log.warning("Claude CLI text envelope was unusable.")
            return None
        parsed = parse_ai_json(text)
        if not isinstance(parsed, (dict, list)):
            log.warning("Claude text reply was not a JSON object/array.")
            return None
        log.info(
            "Claude text intent ok in %.1fs (turns=%s)",
            time.time() - start,
            envelope.get("num_turns"),
        )
        return {"result": parsed}
    except subprocess.TimeoutExpired:
        log.warning(f"Claude CLI text intent timed out after {_timeout_seconds()}s.")
        if raise_on_busy:
            raise AnalyzerTimeout(_timeout_seconds())
        return None
    except Exception as e:
        log.warning(f"Claude text intent failed: {type(e).__name__}: {e}")
        return None
    finally:
        _CLI_LOCK.release()


def analyze_leftover_photo(
    image_bytes: bytes,
    prompt: str,
    backend: str = "claude",
    raise_on_busy: bool = False,
    model: Optional[str] = None,
    effort: Optional[str] = None,
) -> Optional[Dict]:
    """Estimate leftover fractions for a previously analyzed meal.

    [prompt] is ALWAYS composed server-side (the leftover template plus a
    re-sanitized compact original analysis) — and this path NEVER takes
    the Read-tool file fallback: the embedded original analysis came over
    the network, so the exfiltration rule for analyze_food_photo applies
    with no exceptions. The reply skips the is_food gate (leftover
    contract); every numeric clamp lives in the app's pure apply layer.
    """
    if backend not in SUBSCRIPTION_BACKENDS:
        return None
    if not backend_available(backend, for_photo=True):
        return None
    cli = _cli_path()
    if cli is None or not image_bytes or not (prompt or "").strip():
        return None
    if not _acquire_cli_for_foreground():
        log.info("Claude CLI busy — leftover estimation declined.")
        if raise_on_busy:
            raise AnalyzerBusy()
        return None
    start = time.time()
    try:
        env = _cli_env(backend)
        if backend == "glm":
            return _attempt_glm_vision(cli, image_bytes, env, start, prompt,
                                       require_is_food=False)
        try:
            analysis, _retry = _attempt_stream(cli, image_bytes, env, start,
                                               prompt, backend,
                                               require_is_food=False,
                                               model=model, effort=effort)
        except PlanRefused:
            if raise_on_busy:
                raise
            return None
        return analysis
    except AnalyzerTimeout:
        # Same opt-in as PlanRefused: only the API endpoints want the
        # distinct signal; every other caller keeps None.
        if raise_on_busy:
            raise
        return None
    finally:
        _CLI_LOCK.release()


def analyze_food_photo(
    image_bytes: bytes,
    prompt: Optional[str] = None,
    allow_file_fallback: bool = True,
    backend: str = "claude",
    raise_on_busy: bool = False,
    model: Optional[str] = None,
    effort: Optional[str] = None,
) -> Optional[Dict]:
    """Analyze a food photo via the Claude Code CLI; None means 'use Gemini'.

    [prompt] overrides the built-in FOOD_DETECTION_PROMPT (the API endpoint
    composes one from the app's dietary profile).

    [allow_file_fallback] MUST be False whenever any part of the prompt came
    from a network caller. The stream dispatch runs with `--tools ""`, but
    the file fallback necessarily enables the Read tool to load the temp
    image — and a caller who can steer that prompt could read arbitrary
    files (e.g. the .env holding the subscription token) and have the
    content returned inside the analysis JSON. Reaching the fallback does
    not even need the rollback knob: a prompt that produces no output makes
    the stream attempt look like a CLI-shape failure.

    [backend] selects whose subscription pays: 'claude' (default, the
    existing path), 'glm' (coding plan; photos via the official vision MCP),
    or 'doubao' (agent plan; stream dispatch only — its Read-file fallback
    is refused unconditionally since image-block support there is already
    the experiment, and a Read-enabled retry adds the exfiltration surface
    on top of an unknown).
    """
    if backend not in SUBSCRIPTION_BACKENDS:
        return None
    if not backend_available(backend, for_photo=True):
        return None
    cli = _cli_path()
    if cli is None or not image_bytes:
        return None

    # Contended-CLI bypass: another photo already owns the (up to 120s) CLI
    # run. Don't queue behind it — Gemini answers this photo in seconds.
    if not _acquire_cli_for_foreground():
        log.info("Claude CLI busy — falling back to Gemini for this photo.")
        # Default False keeps the TELEGRAM contract ("None → use Gemini")
        # byte-identical; only the API endpoints opt in, because only they
        # need to tell the app "retry in seconds" from "do not retry".
        if raise_on_busy:
            raise AnalyzerBusy()
        return None

    # One photo = one CLI occupancy: the lock is held across BOTH attempts
    # of the stream→file fallback chain, so a burst can never stack the
    # memory-heavy CLI even mid-fallback.
    start = time.time()
    try:
        env = _cli_env(backend)
        if backend == "glm":
            # Text-only Anthropic endpoint: the stream dispatch cannot
            # carry the image; the vision MCP path is the ONLY photo path.
            return _attempt_glm_vision(cli, image_bytes, env, start, prompt)
        if backend == "doubao":
            try:
                analysis, _ = _attempt_stream(
                    cli, image_bytes, env, start, prompt, backend)
            except PlanRefused:
                if raise_on_busy:
                    raise
                return None
            return analysis
        if _dispatch_mode() == "stream":
            try:
                analysis, retry_via_file = _attempt_stream(
                    cli, image_bytes, env, start, prompt,
                    model=model, effort=effort)
            except PlanRefused:
                # Only API callers want the reason; the Telegram path keeps
                # its documented "None -> fall back to Gemini" contract.
                if raise_on_busy:
                    raise
                return None
            if not retry_via_file:
                return analysis
            if not allow_file_fallback:
                # Caller-influenced prompt: refuse the Read-enabled path.
                log.warning(
                    "Claude stream dispatch failed for an API-originated "
                    "request — NOT falling back to the Read-tool path."
                )
                return None
            log.warning(
                "Claude stream-json dispatch failed — retrying once via the "
                "two-turn Read-file path."
            )
        return _attempt_file(cli, image_bytes, env, start, prompt,
                             model=model, effort=effort)
    except AnalyzerTimeout:
        # Every dispatch (stream, file, GLM vision) raises this on the
        # wall-clock limit. Only API callers want it as a signal — the
        # Telegram path keeps "None -> fall back to Gemini" — and no
        # dispatch is retried after it: the lock was held for the full
        # limit already.
        if raise_on_busy:
            raise
        return None
    finally:
        _CLI_LOCK.release()


# ─── Restaurant lookup (R3a): WebSearch-only runner, streaming init guard ──
#
# The ONLY CLI path that gets a network tool, so every part of it is
# pinned here rather than shared with the photo/text paths:
#   * argv: build_lookup_argv — one builder, never CLAUDE_ANALYZER_EXTRA_FLAGS
#     or a caller-chosen flag; the prompt goes in on stdin;
#   * env: exactly LOOKUP_ENV_KEYS plus two fixed knobs — no upload key,
#     plan key or API key reaches a process that reads web pages;
#   * the FIRST stdout line must be the system/init event and match
#     LOOKUP_INIT_EXPECT, or the process group is SIGKILLed before another
#     line is read. Verified on 2026-10-23 against the installed
#     claude 2.1.233 with this exact argv (offline: fake token, API base
#     on a closed localhost port): tools == [StructuredOutput, WebSearch]
#     (--json-schema adds StructuredOutput), mcp_servers == [],
#     plugins == [], permissionMode dontAsk, memory_paths absent under
#     --safe-mode (present without it), apiKeySource "none" with
#     CLAUDE_CODE_OAUTH_TOKEN set, init 1.2 s after spawn;
#   * a tool_use for any other tool later in the stream is also a kill;
#   * cited URLs come only from the structured WebSearch link list, never
#     from model-written text;
#   * its own logging: status, verdict, duration and counts. Never the
#     prompt, queries, URLs or output — those hold restaurant and dish
#     names (_finish_analysis / _log_cli_exit are never called here).

LOOKUP_DISALLOWED_TOOLS = ("Bash,Read,Write,Edit,Glob,Grep,LS,WebFetch,"
                           "NotebookEdit,Task,mcp__*")
LOOKUP_INIT_EXPECT = {
    "tools": frozenset({"WebSearch", "StructuredOutput"}),
    "mcp_servers": [],
    "plugins": [],
    "permissionMode": "dontAsk",
    "absent": ("memory_paths",),
}
LOOKUP_KEY_SOURCES_DEFAULT = ("none",)
LOOKUP_ENV_KEYS = ("PATH", "HOME", "LANG", "CLAUDE_CODE_OAUTH_TOKEN")
LOOKUP_MODEL_DEFAULT = "sonnet"
LOOKUP_INIT_DEADLINE_SECONDS = 10
LOOKUP_EXIT_GRACE_SECONDS = 5
LOOKUP_MAX_OUTPUT_BYTES = 8 * 1024 * 1024
LOOKUP_MAX_LINE_BYTES = 2 * 1024 * 1024
LOOKUP_EVIDENCE_TEXT_CAP = 4000
LOOKUP_MAX_URLS = 20
LOOKUP_URL_CAP = 500

_lookup_log = logging.getLogger("claude_analyzer.lookup")
_LOOKUP_MODEL_RE = re.compile(r"^[A-Za-z0-9._\[\]-]{1,64}$")
_LOOKUP_CODE_RE = re.compile(r"^[a-z_]{1,40}$")
_LINKS_PREFIX = "Links: "


def lookup_model() -> str:
    """CLAUDE_LOOKUP_MODEL (default 'sonnet'); anything that is not a
    plain model name/alias falls back to the default — it becomes argv."""
    raw = (os.environ.get("CLAUDE_LOOKUP_MODEL") or "").strip()
    return raw if raw and _LOOKUP_MODEL_RE.match(raw) else LOOKUP_MODEL_DEFAULT


def lookup_timeout_seconds() -> int:
    try:
        value = int(os.environ.get("CLAUDE_LOOKUP_TIMEOUT_SECONDS", "75"))
    except ValueError:
        return 75
    return min(max(value, 20), 300)


def lookup_key_sources() -> frozenset:
    """apiKeySource values the init guard accepts. Default {'none'} — what
    2.1.233 reports for an OAuth token; CLAUDE_LOOKUP_KEY_SOURCE
    (comma-separated) overrides it once the VM smoke shows its value."""
    raw = os.environ.get("CLAUDE_LOOKUP_KEY_SOURCE")
    parts = [p.strip() for p in (raw or "").split(",") if p.strip()]
    return frozenset(parts or LOOKUP_KEY_SOURCES_DEFAULT)


def build_lookup_argv(cli: str, schema_json: str, model: str) -> List[str]:
    """The lookup argv — the single builder, pinned by tests."""
    return [
        cli, "-p",
        "--safe-mode",
        "--output-format", "stream-json",
        "--verbose",
        "--tools", "WebSearch",
        "--allowedTools", "WebSearch",
        "--disallowedTools", LOOKUP_DISALLOWED_TOOLS,
        "--permission-mode", "dontAsk",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--json-schema", schema_json,
        "--model", model,
    ]


def lookup_env() -> Dict[str, str]:
    """The lookup child's ENTIRE environment: an allowlist, not a scrub."""
    env = {k: os.environ[k] for k in LOOKUP_ENV_KEYS if os.environ.get(k)}
    env.setdefault("LANG", "C.UTF-8")
    env["DISABLE_AUTOUPDATER"] = "1"
    env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    return env


def lookup_init_verdict(event, key_sources=None) -> Optional[str]:
    """None when the init event matches LOOKUP_INIT_EXPECT, else the name
    of the first field that does not (missing counts as different)."""
    if not isinstance(event, dict) or event.get("type") != "system" \
            or event.get("subtype") != "init":
        return "not_init"
    tools = event.get("tools")
    expected = LOOKUP_INIT_EXPECT["tools"]
    if not isinstance(tools, list) or len(tools) != len(expected) \
            or not all(isinstance(t, str) for t in tools) \
            or set(tools) != expected:
        return "tools"
    for key in ("mcp_servers", "plugins", "permissionMode"):
        if key not in event or event[key] != LOOKUP_INIT_EXPECT[key]:
            return key
    for key in LOOKUP_INIT_EXPECT["absent"]:
        if key in event:
            return key
    source = event.get("apiKeySource")
    sources = lookup_key_sources() if key_sources is None else key_sources
    if not isinstance(source, str) or source not in sources:
        return "apiKeySource"
    return None


def _init_summary(event) -> Dict:
    """The non-secret init facts the smoke script prints."""
    if not isinstance(event, dict):
        return {}
    tools = event.get("tools")
    source = event.get("apiKeySource")
    version = event.get("claude_code_version")
    mode = event.get("permissionMode")
    return {
        "tools": (sorted(t for t in tools if isinstance(t, str))
                  if isinstance(tools, list) else None),
        "apiKeySource": source[:40] if isinstance(source, str) else None,
        "claude_code_version": version[:20] if isinstance(version, str) else None,
        "permissionMode": mode[:20] if isinstance(mode, str) else None,
        "mcp_servers": (len(event["mcp_servers"])
                        if isinstance(event.get("mcp_servers"), list) else None),
        "plugins": (len(event["plugins"])
                    if isinstance(event.get("plugins"), list) else None),
        "memory_paths": "memory_paths" in event,
    }


@dataclass
class LookupRun:
    """One lookup CLI run. status: ok | init_ok (stop_after_init) |
    guard_fail | timeout | preempted | cli_error | bad_output |
    plan_refused | unavailable | refused. verdict refines it with a fixed
    code (guard_fail:<field>, no_result, …) — never caller or model text."""
    status: str
    verdict: str = ""
    result: Optional[Dict] = None
    cited_urls: List[str] = field(default_factory=list)
    evidence: List[Dict] = field(default_factory=list)
    searches: int = 0
    duration_s: float = 0.0
    lines_read: int = 0
    started: bool = False
    init: Dict = field(default_factory=dict)


class _ReadTimeout(Exception):
    pass


class _OutputOverflow(Exception):
    pass


class _LineReader:
    """Line-at-a-time reads from a pipe with a deadline (select + os.read),
    so the caller decides about EACH line before the next is parsed, and a
    silent or flooding child can never hold the CLI lock past the limit."""

    def __init__(self, fd: int):
        self._fd = fd
        self._buf = b""
        self._eof = False
        self._total = 0

    def readline(self, deadline: float) -> bytes:
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl + 1], self._buf[nl + 1:]
                return line
            if self._eof:
                line, self._buf = self._buf, b""
                return line
            if len(self._buf) > LOOKUP_MAX_LINE_BYTES:
                raise _OutputOverflow()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise _ReadTimeout()
            ready, _, _ = select.select([self._fd], [], [], remaining)
            if not ready:
                raise _ReadTimeout()
            chunk = os.read(self._fd, 65536)
            if not chunk:
                self._eof = True
                continue
            self._total += len(chunk)
            if self._total > LOOKUP_MAX_OUTPUT_BYTES:
                raise _OutputOverflow()
            self._buf += chunk


def _signal_group(proc) -> None:
    """SIGKILL the lookup's whole process group (it runs in its own
    session). Only while the leader is unreaped, so the group id cannot
    have been recycled. Never waits."""
    if proc is not None and proc.returncode is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass


def _safe_lookup_url(value) -> Optional[str]:
    if not isinstance(value, str) or len(value) > LOOKUP_URL_CAP:
        return None
    if not re.match(r"^https?://[^\s/?#]+", value):
        return None
    if any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return None
    return value


def _tool_result_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            b["text"] for b in content
            if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def _links_from_structured(tool_use_result) -> Optional[Tuple[list, str]]:
    """(urls, text) from the WebSearch tool's structured result
    {query, results: [{tool_use_id, content: [{title, url}]} | str],
    durationSeconds}; None when it is not that shape. Only the link
    objects' url fields count — strings are the search's prose."""
    if not isinstance(tool_use_result, dict):
        return None
    results = tool_use_result.get("results")
    if not isinstance(results, list):
        return None
    urls, texts = [], []
    for entry in results:
        if isinstance(entry, str):
            texts.append(entry)
        elif isinstance(entry, dict) and isinstance(entry.get("content"), list):
            urls.extend(link.get("url") for link in entry["content"]
                        if isinstance(link, dict))
    return urls, "\n".join(texts)


def _links_from_text(text: str) -> Tuple[list, str]:
    """(urls, prose) from a WebSearch tool_result's text: each line that
    STARTS with 'Links: ' followed by a JSON array of {title, url} objects
    and nothing else is parsed with json (raw_decode), never a URL regex;
    an array of any other shape is just prose. The header line (the
    search query) and the CLI's REMINDER line are not evidence."""
    decoder = json.JSONDecoder()
    urls, prose = [], []
    for line in text.splitlines():
        if line.startswith(_LINKS_PREFIX):
            try:
                arr, end = decoder.raw_decode(line, len(_LINKS_PREFIX))
            except ValueError:
                arr, end = None, 0
            if isinstance(arr, list) and arr and not line[end:].strip() \
                    and all(isinstance(e, dict) and set(e) <= {"title", "url"}
                            for e in arr):
                urls.extend(e.get("url") for e in arr)
                continue
        if line.startswith("Web search results for query:") \
                or line.startswith("REMINDER:"):
            continue
        prose.append(line)
    return urls, "\n".join(prose)


def _collect_search_results(event: Dict, ws_ids: set, searches: list) -> None:
    message = event.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    blocks = [b for b in content
              if isinstance(b, dict) and b.get("type") == "tool_result"
              and isinstance(b.get("tool_use_id"), str)
              and b["tool_use_id"] in ws_ids]
    # The event-level tool_use_result belongs to the event's tool result;
    # it is only unambiguous when there is exactly one.
    structured = (_links_from_structured(event.get("tool_use_result"))
                  if len(blocks) == 1 else None)
    for block in blocks:
        if block.get("is_error"):
            continue
        if structured is not None:
            urls, text = structured
        else:
            urls, text = _links_from_text(
                _tool_result_text(block.get("content")))
        clean: List[str] = []
        for url in urls:
            url = _safe_lookup_url(url)
            if url and url not in clean:
                clean.append(url)
        searches.append({"urls": clean,
                         "text": text.strip()[:LOOKUP_EVIDENCE_TEXT_CAP]})


def _unexpected_tool_use(event: Dict, ws_ids: set) -> bool:
    """Record WebSearch tool_use ids; True for any tool outside the
    expected set (the init guard's promise, re-checked per call)."""
    message = event.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return False
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name")
        if name == "WebSearch":
            if isinstance(block.get("id"), str):
                ws_ids.add(block["id"])
        elif name != "StructuredOutput":
            return True
    return False


def _finish_lookup(run: LookupRun, envelope: Dict, refused: bool) -> None:
    if envelope.get("is_error"):
        text = envelope.get("result")
        if refused or envelope.get("api_error_status") == 429 or (
                isinstance(text, str) and "credit" in text.lower()):
            run.status = run.verdict = "plan_refused"
        else:
            subtype = envelope.get("subtype")
            run.status = "cli_error"
            run.verdict = (subtype if isinstance(subtype, str)
                           and _LOOKUP_CODE_RE.match(subtype) else "is_error")
        return
    result = envelope.get("structured_output")
    if not isinstance(result, dict):
        result = None
        text = envelope.get("result")
        if isinstance(text, str) and text.strip():
            try:
                parsed = parse_ai_json(text)
            except (ValueError, RecursionError):
                parsed = None
            result = parsed if isinstance(parsed, dict) else None
    if result is None:
        run.status = run.verdict = "bad_output"
        return
    run.result = result
    run.status = run.verdict = "ok"


def _read_lookup_stream(proc, run: LookupRun, start: float,
                        on_line, stop_after_init: bool) -> None:
    reader = _LineReader(proc.stdout.fileno())
    deadline = start + lookup_timeout_seconds()
    ws_ids: set = set()
    searches: list = []
    envelope = None
    refused = False
    try:
        line = reader.readline(
            min(deadline, start + LOOKUP_INIT_DEADLINE_SECONDS))
        if not line:
            run.status, run.verdict = "cli_error", "no_init"
            return
        run.lines_read = 1
        try:
            event = json.loads(line)
        except (ValueError, RecursionError):
            event = None
        verdict = lookup_init_verdict(event)
        if verdict is not None:
            _signal_group(proc)  # before ANY further line is read
            run.status, run.verdict = "guard_fail", f"guard_fail:{verdict}"
            run.init = _init_summary(event)
            return
        run.init = _init_summary(event)
        if on_line is not None:
            on_line(line.decode("utf-8", "replace"))
        if stop_after_init:
            _signal_group(proc)
            run.status = run.verdict = "init_ok"
            return
        while True:
            line = reader.readline(deadline)
            if not line:
                break
            run.lines_read += 1
            if on_line is not None:
                on_line(line.decode("utf-8", "replace"))
            try:
                event = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if not isinstance(event, dict):
                continue
            kind = event.get("type")
            if kind == "assistant":
                if _unexpected_tool_use(event, ws_ids):
                    _signal_group(proc)
                    run.status, run.verdict = "guard_fail", "guard_fail:tool_use"
                    return
            elif kind == "user":
                _collect_search_results(event, ws_ids, searches)
            elif kind == "rate_limit_event":
                info = event.get("rate_limit_info")
                if isinstance(info, dict) and (
                        info.get("status") == "rejected"
                        or info.get("errorCode") == "credits_required"):
                    refused = True
            elif kind == "result":
                envelope = event
                break
    except _ReadTimeout:
        _signal_group(proc)
        if run.lines_read == 0:
            run.status, run.verdict = "guard_fail", "guard_fail:init_timeout"
        else:
            run.status, run.verdict = "timeout", "timeout"
        return
    except _OutputOverflow:
        _signal_group(proc)
        run.status, run.verdict = "cli_error", "output_too_large"
        return
    finally:
        run.searches = len(ws_ids)
        cited: List[str] = []
        for search in searches:
            for url in search["urls"]:
                if url not in cited and len(cited) < LOOKUP_MAX_URLS:
                    cited.append(url)
        run.cited_urls = cited
        run.evidence = searches
    _signal_group(proc)  # the answer is in; nothing else is needed
    if envelope is None:
        run.status, run.verdict = "cli_error", "no_result"
        return
    _finish_lookup(run, envelope, refused)


def lookup_restaurant(
    prompt_text: str,
    schema_json: str,
    model: Optional[str] = None,
    on_proc: Optional[Callable] = None,
    on_line: Optional[Callable[[str], None]] = None,
    stop_after_init: bool = False,
) -> LookupRun:
    """Run ONE restaurant lookup through the CLI (Claude backend only).

    [prompt_text] is composed server-side (lookup_contract.compose_prompt)
    and goes in on stdin. [on_proc] is called with the Popen right after
    spawn (False → kill at once: pre-empted before it began) and with None
    right before the child is reaped. [on_line] sees each raw line the
    runner processed (the smoke script's fixture recorder).
    [stop_after_init] kills the run right after a PASSING init guard —
    the smoke script's zero-usage check of the guard on the VM.

    Never raises for run failures; the LookupRun says what happened.
    Does NOT take _CLI_LOCK — run_lookup_exclusive does.
    """
    start = time.monotonic()
    run = LookupRun(status="unavailable", verdict="cli_missing")
    cli = _cli_path()
    if not is_configured() or cli is None:
        _log_lookup(run)
        return run
    if not (prompt_text or "").strip():
        run.verdict = "empty_prompt"
        _log_lookup(run)
        return run
    work_dir = tempfile.mkdtemp(prefix="ct_lookup_")
    proc = None
    try:
        try:
            proc = subprocess.Popen(
                build_lookup_argv(cli, schema_json, model or lookup_model()),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                cwd=work_dir,
                env=lookup_env(),
                start_new_session=True,
            )
        except OSError:
            run.status, run.verdict = "cli_error", "spawn_failed"
            return run
        run.started = True
        if on_proc is not None and on_proc(proc) is False:
            _signal_group(proc)
            run.status = run.verdict = "preempted"
            return run
        try:
            proc.stdin.write(prompt_text.encode("utf-8"))
            proc.stdin.close()
        except OSError:
            pass  # the child died early; the reader sees its exit
        _read_lookup_stream(proc, run, start, on_line, stop_after_init)
        return run
    finally:
        if proc is not None:
            if on_proc is not None:
                on_proc(None)
            _signal_group(proc)
            try:
                proc.wait(timeout=LOOKUP_EXIT_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
            for pipe in (proc.stdin, proc.stdout):
                try:
                    pipe.close()
                except (OSError, AttributeError):
                    pass
        shutil.rmtree(work_dir, ignore_errors=True)
        run.duration_s = round(time.monotonic() - start, 2)
        if run.status != "unavailable":
            _log_lookup(run)


def _log_lookup(run: LookupRun) -> None:
    level = logging.WARNING if run.status in (
        "guard_fail", "cli_error", "bad_output") else logging.INFO
    _lookup_log.log(
        level, "Restaurant lookup %s (%s) in %.1fs; searches=%d lines=%d",
        run.status, run.verdict, run.duration_s, run.searches, run.lines_read)


def _register_lookup_proc(proc) -> bool:
    with _LOOKUP_STATE_LOCK:
        _LOOKUP_STATE["proc"] = proc
        return not (proc is not None and _LOOKUP_STATE["preempted"])


def preempt_lookup() -> bool:
    """Kill a lookup that holds the CLI so a foreground request can run.
    True when a lookup held it (the caller then waits for the lock)."""
    with _LOOKUP_STATE_LOCK:
        if not _LOOKUP_STATE["holding"]:
            return False
        _LOOKUP_STATE["preempted"] = True
        _signal_group(_LOOKUP_STATE["proc"])
    _lookup_log.info("Restaurant lookup pre-empted by a foreground request.")
    return True


def run_lookup_exclusive(
    prompt_text: str,
    schema_json: str,
    model: Optional[str] = None,
    on_start: Optional[Callable[[], bool]] = None,
) -> Optional[LookupRun]:
    """lookup_restaurant under _CLI_LOCK, pre-emptible by any photo,
    leftover or text request. None = the CLI is busy right now (the job
    worker polls again). [on_start] runs once the lock is held and before
    the CLI starts; False aborts with status 'refused' (the daily cap)."""
    if not _CLI_LOCK.acquire(blocking=False):
        return None
    with _LOOKUP_STATE_LOCK:
        _LOOKUP_STATE.update(holding=True, proc=None, preempted=False)
    try:
        if on_start is not None and not on_start():
            return LookupRun(status="refused", verdict="refused")
        run = lookup_restaurant(prompt_text, schema_json, model,
                                on_proc=_register_lookup_proc)
        with _LOOKUP_STATE_LOCK:
            preempted = bool(_LOOKUP_STATE["preempted"])
        if preempted and run.status != "ok":
            run.status = run.verdict = "preempted"
        return run
    finally:
        with _LOOKUP_STATE_LOCK:
            _LOOKUP_STATE.update(holding=False, proc=None, preempted=False)
        _CLI_LOCK.release()
