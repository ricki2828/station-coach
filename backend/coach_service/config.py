"""Settings. Everything has a safe default: no provider, no spend authorised, attestation fails closed."""
from __future__ import annotations

import os
from dataclasses import dataclass

CURRENT_CONSENT_VERSION = 1
RETENTION_DAYS = 30   # D9: 30 days, deleted on turn-off


def _flag(name: str) -> bool:
    return os.environ.get(name, "").lower() in ("1", "true", "yes")


@dataclass(frozen=True)
class Settings:
    consent_version: int = CURRENT_CONSENT_VERSION
    db_path: str = ":memory:"
    daily_limit: int = 3                 # debriefs per device per UTC day
    monthly_cap_usd: float = 0.0         # <= 0 means no spend is authorised: every model call is refused
    daily_ceiling_usd: float = 0.0       # global spend per UTC day across all devices; <= 0 refuses
    est_call_usd: float = 0.02           # reserved per model call (a debrief may take two) until the real cost is known
    max_reply_words: int = 90
    history_sessions: int = 3            # earlier sessions shown to the model for comparison
    retention_days: int = RETENTION_DAYS
    register_per_ip_day: int = 5         # new installs per client address per UTC day
    register_global_day: int = 200       # new installs across everyone per UTC day
    max_body_bytes: int = 8192           # a valid payload is under 5 KB
    dev_mode: bool = False               # True accepts any attestation. Never set outside local development

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ
        cap = float(e.get("COACH_MONTHLY_CAP_USD", 0))
        return cls(
            consent_version=int(e.get("COACH_CONSENT_VERSION", CURRENT_CONSENT_VERSION)),
            db_path=e.get("COACH_DB_PATH", "coach.sqlite3"),
            daily_limit=int(e.get("COACH_DAILY_LIMIT", 3)),
            monthly_cap_usd=cap,
            daily_ceiling_usd=float(e.get("COACH_DAILY_CEILING_USD", 0)),
            est_call_usd=float(e.get("COACH_EST_CALL_USD", 0.02)),
            register_per_ip_day=int(e.get("COACH_REGISTER_PER_IP_DAY", 5)),
            register_global_day=int(e.get("COACH_REGISTER_GLOBAL_DAY", 200)),
            dev_mode=_flag("COACH_DEV_MODE"),
        )
