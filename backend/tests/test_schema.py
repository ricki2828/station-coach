import pytest

from conftest import make_facts


@pytest.mark.parametrize("extra", [
    {"heartRateSeries": [120, 130]},
    {"imu": [[0.1, 0.2, 0.3]]},
    {"name": "someone"},
    {"notes": "felt heavy today"},
    {"email": "a@b.c"},
    {"location": {"lat": 1, "lon": 2}},
])
def test_unknown_top_level_field_is_422(env, extra):
    r = env.coach(**extra)
    assert r.status_code == 422
    assert env.llm.calls == []


def test_unknown_nested_fields_are_422(env):
    steps = make_facts(env.install)["steps"]
    steps[0]["note"] = "x"
    assert env.coach(steps=steps).status_code == 422
    wb = make_facts(env.install)["wallBalls"]
    wb["heartRate"] = 150
    assert env.coach(wallBalls=wb).status_code == 422


@pytest.mark.parametrize("over", [
    {"date": "2026-10-27T09:00:00Z"},
    {"date": "27/10/2026"},
    {"date": "2026-13-40"},
    {"sessionType": "something_else"},
    {"division": "x"},
    {"totalSeconds": -1},
    {"totalSeconds": 99999},
    {"totalSeconds": "2472"},
    {"early": "yes"},
    {"installId": "not-a-uuid"},
    {"steps": [{"activity": "free text", "targetSeconds": 1, "actualSeconds": 1, "skipped": False}]},
    {"reference": "other"},
])
def test_bad_values_are_422(env, over):
    assert env.coach(**over).status_code == 422


def test_missing_required_field_is_422(env):
    f = make_facts(env.install)
    del f["totalSeconds"]
    assert env.coach(f).status_code == 422


def test_optional_fields_may_be_absent(env):
    f = make_facts(env.install)
    for k in ("wallBalls", "fadeSeconds", "reference", "referenceDeltaSeconds"):
        del f[k]
    assert env.coach(f).status_code == 200


def test_the_model_never_sees_the_install_id_or_consent_version(env):
    env.coach()
    _, user = env.llm.calls[0]
    assert env.install not in user and "consentVersion" not in user and "installId" not in user
