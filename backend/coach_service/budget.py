"""Spend control, in the shape of run-solo's coach budget (reserve before the call, settle after, release on failure),
cut down to what this service needs: a per-device daily count and one monthly USD cap. Days and months are UTC because
the facts carry no time zone."""
from __future__ import annotations

from datetime import datetime, timezone

from .config import Settings
from .store import Store


class Capped(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code   # "daily_cap" | "month_cap"


def day_start(now: datetime) -> datetime:
    return now.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)


def month_start(now: datetime) -> datetime:
    return day_start(now).replace(day=1)


def remaining_today(store: Store, s: Settings, install_id: str, now: datetime) -> int:
    return max(0, s.daily_limit - store.day_count(install_id, day_start(now)))


def reserve(store: Store, s: Settings, install_id: str, now: datetime) -> int:
    """Raises Capped. The check and the insert share the store lock so two requests cannot both take the last slot."""
    with store.tx():
        if store.day_count(install_id, day_start(now)) >= s.daily_limit:
            raise Capped("daily_cap")
        if store.month_spend(month_start(now)) + s.est_call_usd > s.monthly_cap_usd:
            raise Capped("month_cap")
        return store.reserve(install_id, s.est_call_usd, now)
