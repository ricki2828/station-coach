import uuid
from datetime import datetime, timezone

from coach_service import purge
from coach_service.config import Settings
from conftest import GOOD, FakeLlm, make_facts


def test_attestation_fails_closed_without_dev_mode(make_env):
    e = make_env(register=False, dev_mode=False)
    r = e.register(attestation="anything")
    assert r.status_code == 403 and r.json()["error"] == "attestation_failed"
    assert e.register().status_code == 403


def test_attestation_hook_is_called_with_the_install_and_blob():
    from fastapi.testclient import TestClient
    from coach_service.app import create_app
    seen = []

    class Fake:
        def verify(self, install_id, attestation):
            seen.append((install_id, attestation))
            return attestation == "good"

    c = TestClient(create_app(Settings(ip_secret="x"), None, None, Fake()))
    iid = str(uuid.uuid4())
    assert c.post("/v1/register", json={"installId": iid, "consentVersion": 1, "attestation": "bad"}).status_code == 403
    assert c.post("/v1/register", json={"installId": iid, "consentVersion": 1, "attestation": "good"}).status_code == 200
    assert seen == [(iid, "bad"), (iid, "good")]


def test_per_ip_register_limit(make_env):
    e = make_env(register=False, register_per_ip_day=2)
    for _ in range(2):
        e.install = str(uuid.uuid4())
        assert e.register().status_code == 200
    e.install = str(uuid.uuid4())
    r = e.register()
    assert r.status_code == 429 and r.json()["error"] == "register_limit"
    e.clock.advance(days=1)
    assert e.register().status_code == 200


def test_global_register_limit(make_env):
    e = make_env(register=False, register_per_ip_day=99, register_global_day=2)
    codes = []
    for _ in range(3):
        e.install = str(uuid.uuid4())
        codes.append(e.register().status_code)
    assert codes == [200, 200, 429]


def test_reregister_without_the_old_token_cannot_take_over(env):
    env.coach()
    old = env.token
    r = env.client.post("/v1/register", json={"installId": env.install, "consentVersion": 1})
    assert r.status_code == 409
    # the original token still works, and the data is still there
    assert env.coach().status_code == 200
    assert env.app.state.store.count_sessions(env.install) == 2
    # someone else's token does not count either
    other = str(uuid.uuid4())
    tok = env.client.post("/v1/register", json={"installId": other, "consentVersion": 1}).json()["deviceToken"]
    r = env.client.post("/v1/register", json={"installId": env.install, "consentVersion": 1}, headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 409


def test_reregister_with_the_current_token_rotates_it(env):
    old = env.token
    r = env.client.post("/v1/register", json={"installId": env.install, "consentVersion": 1}, headers={"Authorization": f"Bearer {old}"})
    assert r.status_code == 200
    env.token = r.json()["deviceToken"]
    assert env.token != old
    assert env.coach(token=old).status_code == 401
    assert env.coach().status_code == 200


def test_retention_runs_without_any_coach_call(env):
    env.coach()
    store = env.app.state.store
    assert store.count_sessions(env.install) == 1
    env.clock.advance(days=31)
    # an unrelated request (even a failed one) triggers the purge
    assert env.client.delete("/v1/data").status_code == 401
    db = store._db
    assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
    assert db.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 0           # idle device gone
    assert db.execute("SELECT COUNT(*) FROM ledger WHERE install_id != ''").fetchone()[0] == 0   # unlinked
    assert db.execute("SELECT COUNT(*) FROM registrations").fetchone()[0] == 0


def test_ledger_cost_survives_unlinking_for_the_month_total(env):
    env.coach()
    env.clock.advance(days=31)
    env.client.delete("/v1/data")
    assert env.app.state.store._db.execute("SELECT COUNT(*) FROM ledger").fetchone()[0] == 1


def test_purge_cli(tmp_path):
    db = str(tmp_path / "c.sqlite3")
    from coach_service.store import Store
    s = Store(db)
    t0 = datetime(2026, 10, 1, tzinfo=timezone.utc)
    s.register(str(uuid.uuid4()), 1, t0)
    s.add_session("x", {"a": 1}, t0)
    out = purge.run(Settings(db_path=db), now=datetime(2026, 11, 15, tzinfo=timezone.utc))
    assert out["sessions"] == 1 and out["devices"] == 1


def test_active_device_is_not_purged(env):
    for _ in range(3):
        env.clock.advance(days=20)
        assert env.coach().status_code == 200
        env.clock.advance(days=0)


def test_refuses_to_start_without_ip_secret_outside_dev_mode():
    import pytest
    from coach_service.app import create_app
    with pytest.raises(RuntimeError):
        create_app(Settings(dev_mode=False))
    create_app(Settings(dev_mode=False, ip_secret="x" * 32))
    create_app(Settings(dev_mode=True))


def test_ip_hash_is_keyed(tmp_path):
    import hashlib
    from coach_service.store import Store
    t = datetime(2026, 10, 27, tzinfo=timezone.utc)
    a, b = Store(str(tmp_path / "a"), b"k1"), Store(str(tmp_path / "b"), b"k2")
    a.note_registration("203.0.113.9", t)
    b.note_registration("203.0.113.9", t)
    ha = a._db.execute("SELECT ip_hash FROM registrations").fetchone()[0]
    hb = b._db.execute("SELECT ip_hash FROM registrations").fetchone()[0]
    assert ha != hb
    assert ha != hashlib.sha256(b"ip:203.0.113.9").hexdigest() and ha != hashlib.sha256(b"203.0.113.9").hexdigest()
    assert a.registrations_today(t, "203.0.113.9") == 1 and a.registrations_today(t, "203.0.113.10") == 0
