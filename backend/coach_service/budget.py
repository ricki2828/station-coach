"""Spend control, in the shape of an earlier internal coach service's budget (reserve before the call, settle after,
release when nothing was spent), cut down to what this service needs: a per-device daily count, a global daily ceiling and
a monthly cap. Days and months are UTC because the facts carry no time zone."""
from __future__ import annotations

from datetime import datetime, timezone

from .config import Settings
from .store import Store

CALLS_PER_DEBRIEF = 2   # the first reply plus at most one repair turn


class Capped(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code   # "daily_cap" | "month_cap" | "day_ceiling"


def day_start(now: datetime) -> datetime:
    return now.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)


def month_start(now: datetime) -> datetime:
    return day_start(now).replace(day=1)


def remaining_today(store: Store, s: Settings, install_id: str, now: datetime) -> int:
    return max(0, s.daily_limit - store.day_count(install_id, day_start(now)))


def reserve(store: Store, s: Settings, install_id: str, now: datetime) -> int:
    """Raises Capped. Reserves the worst case (two model calls). Check and insert share one IMMEDIATE transaction."""
    worst = s.est_call_usd * CALLS_PER_DEBRIEF
    with store.transaction():
        if store.day_count(install_id, day_start(now)) >= s.daily_limit:
            raise Capped("daily_cap")
        if s.monthly_cap_usd <= 0 or store.spend_since(month_start(now)) + worst > s.monthly_cap_usd:
            raise Capped("month_cap")
        if s.daily_ceiling_usd <= 0 or store.spend_since(day_start(now)) + worst > s.daily_ceiling_usd:
            raise Capped("day_ceiling")
        return store.reserve(install_id, worst, now)
