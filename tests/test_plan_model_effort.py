"""Per-request model/effort choice for the Claude plan (2026-08-05).

Closed whitelists, claude-only: these values become CLI argv, so the
endpoints must 400 anything unlisted BEFORE a CLI run exists, and the
vendor plans (which map model names server-side) must reject overrides.
"""
import base64

import claude_analyzer


ANALYSIS = {"is_food": True, "total_calories": 450}


def _photo_payload(**over):
    p = {"image_b64": base64.b64encode(b"jpegbytes").decode()}
    p.update(over)
    return p


def _stub(monkeypatch):
    captured = {}

    def fake(b, p=None, allow_file_fallback=True, backend="claude",
             raise_on_busy=False, model=None, effort=None):
        captured.update(model=model, effort=effort, backend=backend)
        return dict(ANALYSIS)

    monkeypatch.setattr(claude_analyzer, "is_configured", lambda: True)
    monkeypatch.setattr(claude_analyzer, "analyze_food_photo", fake)
    return captured


def test_valid_model_and_effort_reach_the_analyzer(client, monkeypatch):
    captured = _stub(monkeypatch)
    resp = client.http.post("/api/analyze_photo",
                            headers={"X-API-Key": "secret-key"},
                            json=_photo_payload(model="haiku", effort="low"))
    assert resp.status_code == 200
    assert captured["model"] == "haiku"
    assert captured["effort"] == "low"


def test_absent_choice_means_server_default(client, monkeypatch):
    captured = _stub(monkeypatch)
    resp = client.http.post("/api/analyze_photo",
                            headers={"X-API-Key": "secret-key"},
                            json=_photo_payload())
    assert resp.status_code == 200
    assert captured["model"] is None and captured["effort"] is None


def test_unlisted_values_are_400_not_argv(client, monkeypatch):
    captured = _stub(monkeypatch)
    for bad in ({"model": "opus-4.5-preview"}, {"model": "--tools"},
                {"effort": "max"}, {"effort": "9000"}):
        resp = client.http.post("/api/analyze_photo",
                                headers={"X-API-Key": "secret-key"},
                                json=_photo_payload(**bad))
        assert resp.status_code == 400, bad
    assert not captured, "no CLI call may happen for a rejected choice"


def test_vendor_plans_reject_overrides(client, monkeypatch):
    captured = _stub(monkeypatch)
    resp = client.http.post("/api/analyze_photo",
                            headers={"X-API-Key": "secret-key"},
                            json=_photo_payload(backend="glm", model="opus"))
    assert resp.status_code == 400
    assert not captured


def test_argv_carries_the_choice_only_for_claude():
    cmd = ["claude", "-p"]
    claude_analyzer._append_model_and_extra_flags(
        cmd, "claude", model="haiku", effort="high")
    assert cmd[cmd.index("--model") + 1] == "haiku"
    assert cmd[cmd.index("--effort") + 1] == "high"
    cmd2 = ["claude", "-p"]
    claude_analyzer._append_model_and_extra_flags(
        cmd2, "glm", model="haiku", effort="high")
    assert "--model" not in cmd2 and "--effort" not in cmd2


def test_argv_never_takes_unlisted_values_even_if_called_directly():
    # Defense in depth: even if endpoint validation regressed, the argv
    # builder itself refuses off-whitelist values.
    cmd = ["claude", "-p"]
    claude_analyzer._append_model_and_extra_flags(
        cmd, "claude", model="--dangerously-skip-permissions", effort="rm")
    assert "--dangerously-skip-permissions" not in cmd
    assert "rm" not in cmd


class TestPlanRefusal:
    """A plan that cannot serve the chosen model must say WHY.

    Live-verified 2026-08-06: Fable 5 on a Pro plan makes the CLI exit 1
    with a rate_limit_event (credits_required) and a human-readable
    result string. Before this, the app showed the generic 'the analysis
    ran but produced no usable result' — hiding a one-tap fix.
    """

    STREAM = "\n".join([
        '{"type":"system","subtype":"init","model":"claude-fable-5"}',
        '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected",'
        '"errorCode":"credits_required"}}',
        '{"type":"result","subtype":"success","is_error":true,'
        '"api_error_status":429,'
        '"result":"Fable 5 requires usage credits. /model to switch models."}',
    ])

    # The OTHER plan refusal (2026-10-07): the plan's own usage window.
    # Same 429 / rejected shape, but no credits_required and no "credit"
    # in the sentence — the window reopens by itself, the photo must
    # survive until then.
    WINDOW = "\n".join([
        '{"type":"system","subtype":"init","model":"claude-opus-5"}',
        '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected",'
        '"resetsAt":1790000000}}',
        '{"type":"result","subtype":"success","is_error":true,'
        '"api_error_status":429,'
        '"result":"You have hit your usage limit. It resets at 3pm."}',
    ])

    def test_refusal_is_detected_with_the_clis_own_words(self):
        refusal = claude_analyzer._plan_refusal(self.STREAM)
        assert isinstance(refusal, claude_analyzer.PlanRefused)
        assert (refusal.reason
                == "Fable 5 requires usage credits. /model to switch models.")
        assert refusal.terminal is True, "credits do not appear by waiting"

    def test_usage_window_is_a_refusal_but_not_terminal(self):
        refusal = claude_analyzer._plan_refusal(self.WINDOW)
        assert isinstance(refusal, claude_analyzer.PlanRefused)
        assert "usage limit" in refusal.reason
        assert refusal.terminal is False, "the window reopens on its own"
        # A bare 429 with no sentence at all is still the window, and
        # credits said in words (no errorCode) are still terminal.
        bare = claude_analyzer._plan_refusal(
            '{"type":"result","is_error":true,"api_error_status":429}')
        assert bare is not None and bare.terminal is False
        words = claude_analyzer._plan_refusal(
            '{"type":"result","is_error":true,'
            '"result":"This model requires usage credits."}')
        assert words is not None and words.terminal is True

    def test_ordinary_failures_are_not_refusals(self):
        assert claude_analyzer._plan_refusal("") is None
        assert claude_analyzer._plan_refusal("not json at all") is None
        assert claude_analyzer._plan_refusal(
            '{"type":"result","is_error":true,"result":"bad json from model"}'
        ) is None, "a junk answer must stay a retryable CLI-shape failure"

    def test_endpoint_returns_the_reason_not_the_generic_503(
            self, client, monkeypatch):
        def refuse(*a, **kw):
            raise claude_analyzer.PlanRefused(
                "Fable 5 requires usage credits. /model to switch models.",
                terminal=True)

        monkeypatch.setattr(claude_analyzer, "is_configured", lambda: True)
        monkeypatch.setattr(claude_analyzer, "analyze_food_photo", refuse)
        resp = client.http.post("/api/analyze_photo",
                                headers={"X-API-Key": "secret-key"},
                                json=_photo_payload(model="fable"))
        assert resp.status_code == 503
        body = resp.get_json()
        assert "usage credits" in body["reason"]
        assert body["retry"] is False, "retrying reproduces it exactly"

    def test_endpoint_says_come_back_later_for_a_closed_usage_window(
            self, client, monkeypatch):
        """The owner's real case (2026-10-07): the plan's window closed
        mid-afternoon, the server answered retry:false, and the app
        burned the photo for good while its UI promised an automatic
        retry. "later" keeps the photo and stops the in-place spin."""
        def refuse(*a, **kw):
            raise claude_analyzer.PlanRefused(
                "You have hit your usage limit. It resets at 3pm.",
                terminal=False)

        monkeypatch.setattr(claude_analyzer, "is_configured", lambda: True)
        monkeypatch.setattr(claude_analyzer, "analyze_food_photo", refuse)
        resp = client.http.post("/api/analyze_photo",
                                headers={"X-API-Key": "secret-key"},
                                json=_photo_payload())
        assert resp.status_code == 503
        body = resp.get_json()
        assert body["error"] == "claude_unavailable"
        assert "usage limit" in body["reason"], "the CLI's own words"
        assert body["retry"] == "later"
        assert not isinstance(body["retry"], bool), (
            "the installed app reads bools only: a non-bool is its "
            "keep-the-photo-but-do-not-spin branch")

    def test_plan_refused_defaults_to_the_temporary_reading(self):
        # A refusal nobody classified is a window, not a dead end: the
        # photo survives and the user keeps the CLI's sentence either way.
        assert claude_analyzer.PlanRefused("x").terminal is False
