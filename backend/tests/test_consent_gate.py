"""The consent gate (eng review: BLOCK until this test exists). No consent at the current version means no model call,
no stored facts, and nothing read past the version field."""
import uuid

from conftest import make_facts


def test_register_without_consent_version_is_403(make_env):
    e = make_env(register=False)
    r = e.client.post("/v1/register", json={"installId": e.install})
    assert r.status_code == 403 and r.json()["currentConsentVersion"] == 1


def test_register_with_old_or_future_version_is_403(make_env):
    e = make_env(register=False)
    assert e.register(version=0 + 2).status_code == 403
    assert e.client.post("/v1/register", json={"installId": e.install, "consentVersion": True}).status_code == 403


def test_coach_without_consent_version_is_403_and_never_calls_the_model(env):
    f = make_facts(env.install)
    del f["consentVersion"]
    r = env.coach(f)
    assert r.status_code == 403
    assert env.llm.calls == []
    assert env.app.state.store.count_sessions(env.install) == 0


def test_coach_with_wrong_consent_version_is_403(env):
    for v in (0, 2, "1", None, True):
        r = env.coach(make_facts(env.install, consentVersion=v))
        assert r.status_code == 403, v
    assert env.llm.calls == []


def test_consent_is_checked_before_the_schema(env):
    # A bad payload with the wrong version is a 403, so nothing about the facts is examined or echoed.
    r = env.coach(make_facts(env.install, consentVersion=2, heartRate=[150, 160]))
    assert r.status_code == 403
    assert "heartRate" not in r.text


def test_token_registered_at_an_old_version_is_refused_after_a_version_bump(make_env):
    e = make_env(consent_version=2, register=False)
    assert e.register(version=2).status_code == 200
    # a phone still sending version 1 (stale consent screen) is refused
    assert e.coach(make_facts(e.install, consentVersion=1)).status_code == 403
    assert e.coach(make_facts(e.install, consentVersion=2)).status_code == 200


def test_no_token_or_unknown_token_is_401(env):
    assert env.coach(token=None).status_code == 401
    assert env.coach(token="nope").status_code == 401
    assert env.llm.calls == []


def test_token_cannot_be_used_for_another_install(env):
    r = env.coach(make_facts(str(uuid.uuid4())))
    assert r.status_code == 403
    assert env.llm.calls == []


def test_turning_off_revokes_consent(env):
    assert env.coach().status_code == 200
    assert env.client.delete("/v1/data", headers={"Authorization": f"Bearer {env.token}"}).status_code == 200
    assert env.coach().status_code == 401   # token gone, so consent is gone
    assert len(env.llm.calls) == 1
