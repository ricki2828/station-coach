import uuid

import pytest

from conftest import GOOD, make_facts
from coach_service import validator
from coach_service.schema import CoachFacts


def facts(**over):
    return CoachFacts.model_validate(make_facts(str(uuid.uuid4()), **over))


def test_good_reply_passes():
    assert validator.check(GOOD, facts()) is None


@pytest.mark.parametrize("reply,why", [
    ("", "empty"),
    ("word " * 91, "longer"),
    ("Your Sled push took 4:20. Great job. Next, Half sim.", "praise"),
    ("Your Sled push took 4:20. That was awesome. Next, Half sim.", "praise"),
    ("Sled push was slow. Next, Half sim.", "first sentence"),
    ("Sled push took 4:21 against 3:30. Next, Half sim.", "not in the session facts"),
    ("You ran 9 laps and Sled push took 4:20. Next, Half sim.", "not in the session facts"),
    ("Sled push took 4:20. The Row hurt too. Next, Half sim.", "exactly one station"),
    ("Total 41:12 with no station named. Next, Half sim.", "exactly one station"),
    ("Sled push took 4:20. Try something hard.", "next session"),
    ("Sled push took 4:20. Next, Half sim or Full sim.", "next session"),
    ("Sled push took 4:20. Do a Half sim, then rest. Next, Full sim.", "next session"),
    ("Sled push took 4:20 \U0001F4AA. Next, Half sim.", "emoji"),
    ("Sled push took 4:20 at " + "hy" + "rox pace. Next, Half sim.", "event or brand"),
])
def test_bad_replies_fail(reply, why):
    got = validator.check(reply, facts())
    assert got and why in got


def test_early_session_must_not_compare_to_target_or_plan():
    f = facts(early=True)
    assert validator.check("Sled push took 4:20 before you stopped at 41:12. Next, Half sim.", f) is None
    for bad in ("Sled push took 4:20 and the total of 41:12 is 1:12 over target. Next, Half sim.",
                "Sled push took 4:20 and 41:12 is behind the 40:00 plan. Next, Half sim.",
                "Sled push took 4:20 against 40:00. Next, Half sim."):
        assert validator.check(bad, f), bad


def test_praise_with_a_number_is_allowed():
    r = "Great Sled push: 3:30 target, 4:20 actual, so the number says otherwise. Next, Half sim."
    assert validator.check(r, facts()) is None


def test_derived_differences_are_grounded():
    # 4:20 - 3:30 = 0:50 ; 100 reps - 3 no-reps = 97
    r = "Wall balls: 97 counted reps, 0:10 over target. Next, Wall-ball focus."
    assert validator.check(r, facts()) is None
