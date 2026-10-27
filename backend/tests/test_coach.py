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
    app = create_app(Settings(monthly_cap_usd=5.0, daily_ceiling_usd=5.0, dev_mode=True))   # no provider passed: the stub
    c = TestClient(app)
    iid = str(uuid.uuid4())
    tok = c.post("/v1/register", json={"installId": iid, "consentVersion": 1}).json()["deviceToken"]
    r = c.post("/v1/coach", json=make_facts(iid), headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 503 and r.json()["error"] == "not_configured"
    assert app.state.store.count_sessions(iid) == 0
    assert app.state.store.spend_since(__import__("datetime").datetime(2000, 1, 1)) == 0


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


# red-flag language: a validator failure on a facts-only debrief, never emergency copy
def test_medical_language_in_the_reply_is_repaired_then_refused(make_env):
    e = make_env(FakeLlm("You mentioned chest pain at 41:12 on the Run. Next, Half sim."))
    r = e.coach()
    assert r.status_code == 502 and r.json()["error"] == "reply_rejected"
    assert "chest" not in r.text and "doctor" not in r.text
    assert len(e.llm.calls) == 2 and "medical language" in e.llm.calls[1][1]


def test_medical_language_then_clean_repair_succeeds(make_env):
    e = make_env(FakeLlm("It sounds hopeless. 41:12 on the Run. Next, Half sim.", GOOD))
    j = e.coach().json()
    assert j["kind"] == "debrief" and j["reply"] == GOOD


def test_everyday_debrief_words_are_not_red_flags(make_env):
    from coach_service import redflag
    for ok in ("Your pace collapsed on the last Run.", "Wall balls left you short of breath.", "Dizzy numbers, 41:12."):
        assert redflag.detect(ok) is None
    e = make_env(FakeLlm("Your pace collapsed after 41:12, and Sled push cost 4:20. Next, Half sim."))
    r = e.coach()
    assert r.status_code == 200 and r.json()["kind"] == "debrief"


def test_red_flag_patterns_and_template_still_exist_for_a_future_free_text_version():
    from coach_service import redflag
    assert redflag.detect("I had chest pain on the run") == redflag.URGENT
    assert redflag.detect("I want to die") == redflag.WELLBEING
    assert redflag.detect("No chest pain reported.") is None
    for k in (redflag.URGENT, redflag.WELLBEING):
        t = redflag.template(k).lower()
        assert "local emergency number" in t and not any(w in t for w in ("half sim", "full sim"))


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
    e = make_env(FakeLlm(cost=0.04), monthly_cap_usd=0.09, daily_limit=10, est_call_usd=0.03)
    assert e.coach().status_code == 200          # reserves 0.06, settles 0.04
    assert e.coach().status_code == 429          # 0.04 + 0.06 worst case > 0.09
    e.clock.advance(days=2)                      # Oct 29, same month
    assert e.coach().status_code == 429
    e.clock.advance(days=10)                     # November
    assert e.coach().status_code == 200


# retention and deletion
def test_sessions_expire_after_30_days_and_so_does_an_idle_device(env):
    env.coach()
    store = env.app.state.store
    assert store.count_sessions(env.install) == 1
    env.clock.advance(days=31)
    assert env.coach().status_code == 401        # the idle device was purged with its sessions
    assert store.count_sessions(env.install) == 0


def test_delete_removes_sessions_and_reports_count(env):
    env.coach()
    env.coach()
    r = env.client.delete("/v1/data", headers={"Authorization": f"Bearer {env.token}"})
    assert r.json() == {"deletedSessions": 2}
    assert env.app.state.store.count_sessions(env.install) == 0


def test_delete_without_token_is_401(env):
    assert env.client.delete("/v1/data").status_code == 401


def test_worst_case_two_calls_is_reserved_up_front(make_env):
    # one call would fit under the cap, the two a repair turn can use would not
    e = make_env(monthly_cap_usd=0.05, est_call_usd=0.03)
    r = e.coach()
    assert r.status_code == 429 and r.json()["error"] == "month_cap" and e.llm.calls == []


def test_repair_turn_spend_is_recorded(make_env):
    e = make_env(FakeLlm("Great job today! Next, Half sim.", GOOD, cost=0.05), est_call_usd=0.06)
    assert e.coach().status_code == 200
    assert round(e.app.state.store.spend_since(e.clock.t.replace(day=1)), 4) == 0.10


def test_provider_error_on_the_repair_turn_still_settles_the_first_call(make_env):
    e = make_env(FakeLlm("Great job today! Next, Half sim.", ProviderError("boom"), cost=0.05))
    assert e.coach().status_code == 503
    assert round(e.app.state.store.spend_since(e.clock.t.replace(day=1)), 4) == 0.05


def test_global_daily_ceiling(make_env):
    e = make_env(daily_ceiling_usd=0.05, est_call_usd=0.02, daily_limit=10)
    assert e.coach().status_code == 200      # settles 0.01
    assert e.coach().status_code == 200
    # 0.02 spent + 0.04 worst case > 0.05
    r = e.coach()
    assert r.status_code == 429 and r.json()["error"] == "day_ceiling"
    e.clock.advance(days=1)
    assert e.coach().status_code == 200


def test_zero_cap_refuses_even_with_a_zero_estimate(make_env):
    e = make_env(monthly_cap_usd=0.0, est_call_usd=0.0)
    assert e.coach().status_code == 429 and e.llm.calls == []
    e2 = make_env(daily_ceiling_usd=0.0, est_call_usd=0.0)
    assert e2.coach().status_code == 429 and e2.llm.calls == []


def test_skipped_step_has_no_actual_seconds(env):
    steps = make_facts(env.install)["steps"]
    steps[0] = {"activity": "run", "targetSeconds": 312, "skipped": True}
    assert env.coach(steps=steps).status_code == 200
    steps[0]["actualSeconds"] = 0
    assert env.coach(steps=steps).status_code == 422          # never 0
    steps[0] = {"activity": "run", "targetSeconds": 312, "skipped": False}
    assert env.coach(steps=steps).status_code == 422          # done steps need a time


def test_skipped_step_numbers_are_not_quotable(make_env):
    e = make_env(FakeLlm("Sled push was skipped, 3:30 target, 0:00 shown. Next, Half sim."))
    steps = make_facts(e.install)["steps"]
    steps[1] = {"activity": "sled_push", "targetSeconds": 210, "skipped": True}
    assert e.coach(steps=steps).status_code == 502


def test_body_size_cap(env):
    f = make_facts(env.install)
    f["steps"] = f["steps"] * 40
    big = env.client.post("/v1/coach", content=b"x" * 9000, headers={"Authorization": f"Bearer {env.token}"})
    assert big.status_code == 413


def test_server_timestamps_are_day_precision(env):
    env.coach()
    db = env.app.state.store._db
    for table, col in (("sessions", "created_at"), ("ledger", "ts"), ("devices", "created_at"), ("devices", "last_seen")):
        v = db.execute(f"SELECT {col} FROM {table}").fetchone()[0]
        assert len(v) == 10, (table, col, v)
