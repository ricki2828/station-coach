"""Settings. Everything has a safe default: no provider, no spend authorised."""
from __future__ import annotations

import os
from dataclasses import dataclass

CURRENT_CONSENT_VERSION = 1
RETENTION_DAYS = 30   # D9: 30 days, deleted on turn-off


@dataclass(frozen=True)
class Settings:
    consent_version: int = CURRENT_CONSENT_VERSION
    db_path: str = ":memory:"
    daily_limit: int = 3                 # debriefs per device per UTC day
    monthly_cap_usd: float = 0.0         # 0 = no spend authorised: every model call is refused
    est_call_usd: float = 0.02           # reserved per call until the real cost is known
    max_reply_words: int = 90
    history_sessions: int = 3            # earlier sessions shown to the model for comparison
    retention_days: int = RETENTION_DAYS

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ
        return cls(
            consent_version=int(e.get("COACH_CONSENT_VERSION", CURRENT_CONSENT_VERSION)),
            db_path=e.get("COACH_DB_PATH", "coach.sqlite3"),
            daily_limit=int(e.get("COACH_DAILY_LIMIT", 3)),
            monthly_cap_usd=float(e.get("COACH_MONTHLY_CAP_USD", 0)),
            est_call_usd=float(e.get("COACH_EST_CALL_USD", 0.02)),
        )
