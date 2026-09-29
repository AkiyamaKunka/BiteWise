"""/api/auth_check must say whether the server already holds a Claude-plan
sign-in, so a freshly provisioned phone does not imply a re-connect."""
import claude_analyzer


def test_login_state_reflects_the_oauth_token(monkeypatch):
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    assert claude_analyzer.login_state() == "none"
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "   ")
    assert claude_analyzer.login_state() == "none"
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-example")
    assert claude_analyzer.login_state() == "token"
