import json

from conftest import GOOD, FakeLlm, make_facts
from coach_service.llm import ProviderError


def test_happy_path_returns_one_reply(env):
    r = env.coach()
    assert r.status_code == 200
    j = r.json()
    assert j["reply"] == GOOD and j["kind"] == "debrief" and j["remainingToday"] == 2
    assert len(env.llm.calls) == 1


def test_default_stub_provider_is_not_configured_and_costs_nothing():
    from conftest import Env
    from coach_service.app import create_app
    from coach_service.config import Settings
    from fastapi.testclient import TestClient
    import uuid
    app = create_app(Settings(monthly_cap_usd=5.0))   # no provider passed: the stub
    c = TestClient(app)
    iid = str(uuid.uuid4())
    tok = c.post("/v1/register", json={"installId": iid, "consentVersion": 1}).json()["deviceToken"]
    r = c.post("/v1/coach", json=make_facts(iid), headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 503 and r.json()["error"] == "not_configured"
    assert app.state.store.count_sessions(iid) == 0
    assert app.state.store.month_spend(__import__("datetime").datetime(2000, 1, 1)) == 0


def test_history_goes_to_the_model_for_comparison(env):
    env.coach(date="2026-10-20")
    env.coach(date="2026-10-27")
    user = json.loads(env.llm.calls[1][1])
    assert [h["date"] for h in user["earlier_sessions"]] == ["2026-10-20"]
    assert user["this_session"]["date"] == "2026-10-27"


def test_repair_turn_then_success(make_env):
    e = make_env(FakeLlm("Great job today! Next, Half sim.", GOOD))
    r = e.coach()
    assert r.status_code == 200 and r.json()["reply"] == GOOD
    assert len(e.llm.calls) == 2
    assert "not sent" in e.llm.calls[1][1]


def test_two_bad_replies_is_502_and_nothing_is_stored(make_env):
    e = make_env(FakeLlm("Great job today! Next, Half sim."))
    r = e.coach()
    assert r.status_code == 502 and r.json()["error"] == "reply_rejected"
    assert "Great job" not in r.text
    assert e.app.state.store.count_sessions(e.install) == 0


def test_provider_failure_is_503_and_releases_the_slot(make_env):
    e = make_env(FakeLlm(ProviderError("boom"), GOOD))
    assert e.coach().status_code == 503
    r = e.coach()
    assert r.status_code == 200 and r.json()["remainingToday"] == 2


# red-flag escalation copy
def test_urgent_topic_in_the_reply_is_replaced_by_fixed_safety_copy(make_env):
    from coach_service import redflag
    e = make_env(FakeLlm("You mentioned chest pain at 41:12. Next, Half sim."))
    j = e.coach().json()
    assert j["kind"] == "safety" and j["reply"] == redflag.template(redflag.URGENT)
    assert "chest" not in j["reply"].lower().replace("chest pain", "")  # model words are gone
    assert "doctor" in j["reply"] and "local emergency number" in j["reply"]


def test_wellbeing_topic_gets_the_wellbeing_copy(make_env):
    from coach_service import redflag
    e = make_env(FakeLlm("It sounds hopeless. 41:12. Next, Half sim."))
    j = e.coach().json()
    assert j["kind"] == "safety" and j["reply"] == redflag.template(redflag.WELLBEING)
    assert "crisis line" in j["reply"]


def test_negated_red_flag_is_not_escalated():
    from coach_service import redflag
    assert redflag.detect("No chest pain reported.") is None
    assert redflag.detect("Your pace faded after 41:12.") is None


def test_safety_copy_has_no_training_advice():
    from coach_service import redflag
    for k in (redflag.URGENT, redflag.WELLBEING):
        t = redflag.template(k).lower()
        assert not any(w in t for w in ("next session", "half sim", "full sim", "pace"))


# budget
def test_daily_cap_per_device_then_resets_next_day(make_env):
    e = make_env(daily_limit=2)
    assert e.coach().json()["remainingToday"] == 1
    assert e.coach().json()["remainingToday"] == 0
    r = e.coach()
    assert r.status_code == 429 and r.json()["error"] == "daily_cap"
    assert len(e.llm.calls) == 2
    e.clock.advance(days=1)
    assert e.coach().status_code == 200


def test_daily_cap_is_per_device(make_env):
    a = make_env(daily_limit=1)
    assert a.coach().status_code == 200
    assert a.coach().status_code == 429
    import uuid
    other = str(uuid.uuid4())
    tok = a.client.post("/v1/register", json={"installId": other, "consentVersion": 1}).json()["deviceToken"]
    r = a.client.post("/v1/coach", json=make_facts(other), headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 200


def test_monthly_cap_zero_authorises_no_spend(make_env):
    e = make_env(monthly_cap_usd=0.0)
    r = e.coach()
    assert r.status_code == 429 and r.json()["error"] == "month_cap"
    assert e.llm.calls == []


def test_monthly_cap_counts_real_cost(make_env):
    e = make_env(FakeLlm(cost=0.04), monthly_cap_usd=0.065, daily_limit=10, est_call_usd=0.03)
    assert e.coach().status_code == 200          # 0.04 settled
    assert e.coach().status_code == 429          # 0.04 + 0.03 reserve > 0.07
    e.clock.advance(days=2)                      # Oct 29, same month
    assert e.coach().status_code == 429
    e.clock.advance(days=10)                     # November
    assert e.coach().status_code == 200


# retention and deletion
def test_sessions_expire_after_30_days(env):
    env.coach()
    store = env.app.state.store
    assert store.count_sessions(env.install) == 1
    env.clock.advance(days=31)
    env.coach(date="2026-11-27")
    # the old one was purged before the new one was stored
    assert store.count_sessions(env.install) == 1
    assert json.loads(env.llm.calls[1][1])["earlier_sessions"] == []


def test_delete_removes_sessions_and_reports_count(env):
    env.coach()
    env.coach()
    r = env.client.delete("/v1/data", headers={"Authorization": f"Bearer {env.token}"})
    assert r.json() == {"deletedSessions": 2}
    assert env.app.state.store.count_sessions(env.install) == 0


def test_delete_without_token_is_401(env):
    assert env.client.delete("/v1/data").status_code == 401
