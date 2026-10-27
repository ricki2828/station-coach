import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from coach_service.app import create_app
from coach_service.config import Settings
from coach_service.llm import LlmResult, ProviderError

GOOD = ("Your total of 41:12 came in 1:12 over the 40:00 plan, and Sled push gave back most of it: 4:20 against a 3:30 target. "
        "Next, Half sim.")


class FakeLlm:
    """Scripted replies; records every call. No network."""

    def __init__(self, *replies, cost=0.01):
        self.replies = list(replies) or [GOOD]
        self.calls: list[tuple[str, str]] = []
        self.cost = cost

    def complete(self, system, user):
        self.calls.append((system, user))
        r = self.replies[min(len(self.calls) - 1, len(self.replies) - 1)]
        if isinstance(r, Exception):
            raise r
        return LlmResult(r, self.cost)


class Clock:
    def __init__(self):
        self.t = datetime(2026, 10, 27, 9, 0, tzinfo=timezone.utc)

    def __call__(self):
        return self.t

    def advance(self, **kw):
        self.t += timedelta(**kw)


def make_facts(install, **over):
    f = {
        "consentVersion": 1, "installId": install, "date": "2026-10-27", "sessionType": "half_sim", "division": "open_men",
        "raceTargetSeconds": 4800, "totalSeconds": 2472, "plannedSeconds": 2400, "early": False,
        "steps": [
            {"activity": "run", "targetSeconds": 312, "actualSeconds": 325, "skipped": False},
            {"activity": "sled_push", "targetSeconds": 210, "actualSeconds": 260, "skipped": False},
            {"activity": "wall_balls", "targetSeconds": 300, "actualSeconds": 310, "skipped": False},
        ],
        "wallBalls": {"reps": 100, "noReps": 3, "setSizes": [15, 15, 20], "restSeconds": [12, 18]},
        "fadeSeconds": 27, "reference": "ghost", "referenceDeltaSeconds": -48,
    }
    f.update(over)
    return f


class Env:
    def __init__(self, llm, **settings):
        self.llm = llm
        self.clock = Clock()
        base = dict(ip_secret="test-secret", monthly_cap_usd=5.0, daily_ceiling_usd=5.0, daily_limit=3, dev_mode=True)
        base.update(settings)
        self.app = create_app(Settings(**base), llm, self.clock)
        self.client = TestClient(self.app)
        self.install = str(uuid.uuid4())
        self.token = None

    def register(self, version=1, **extra):
        r = self.client.post("/v1/register", json={"installId": self.install, "consentVersion": version, **extra})
        if r.status_code == 200:
            self.token = r.json()["deviceToken"]
        return r

    def coach(self, facts=None, token="default", **over):
        facts = facts if facts is not None else make_facts(self.install, **over)
        tok = self.token if token == "default" else token
        headers = {"Authorization": f"Bearer {tok}"} if tok else {}
        return self.client.post("/v1/coach", json=facts, headers=headers)


@pytest.fixture
def env():
    e = Env(FakeLlm())
    e.register()
    return e


@pytest.fixture
def make_env():
    def _make(llm=None, register=True, **settings):
        e = Env(llm or FakeLlm(), **settings)
        if register:
            e.register()
        return e
    return _make
