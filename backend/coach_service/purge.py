"""Retention on demand: `python -m coach_service.purge` (reads COACH_DB_PATH). Safe to run from cron at any time; the
server also purges on every request, so this covers a quiet service."""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone

from .config import Settings
from .store import Store


def run(settings: Settings | None = None, now: datetime | None = None) -> dict:
    s = settings or Settings.from_env()
    return Store(s.db_path).purge_expired(now or datetime.now(timezone.utc), s.retention_days)


if __name__ == "__main__":
    print(json.dumps(run()))
    sys.exit(0)
