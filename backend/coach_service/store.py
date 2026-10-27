"""SQLite store: consent, device tokens, kept sessions (30 days), and the spend ledger."""
from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
import threading
from datetime import datetime, timedelta

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
  install_id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
  consent_version INTEGER NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, install_id TEXT NOT NULL,
  created_at TEXT NOT NULL, facts_json TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS sessions_install ON sessions(install_id, id);
CREATE TABLE IF NOT EXISTS ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT, install_id TEXT NOT NULL, ts TEXT NOT NULL,
  state TEXT NOT NULL, reserved_usd REAL NOT NULL, cost_usd REAL NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS ledger_ts ON ledger(ts);
"""


def _iso(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class Store:
    def __init__(self, path: str):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        self._db.executescript(SCHEMA)

    # consent and tokens
    def register(self, install_id: str, consent_version: int, now: datetime) -> str:
        """Record consent; returns a fresh token (a repeat call replaces the old one)."""
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._db.execute(
                "INSERT INTO devices (install_id, token_hash, consent_version, created_at) VALUES (?,?,?,?) "
                "ON CONFLICT(install_id) DO UPDATE SET token_hash=excluded.token_hash, consent_version=excluded.consent_version",
                (install_id, _hash(token), consent_version, _iso(now)))
        return token

    def device_for_token(self, token: str) -> sqlite3.Row | None:
        with self._lock:
            return self._db.execute("SELECT * FROM devices WHERE token_hash=?", (_hash(token),)).fetchone()

    # sessions
    def add_session(self, install_id: str, facts: dict, now: datetime) -> int:
        with self._lock:
            cur = self._db.execute("INSERT INTO sessions (install_id, created_at, facts_json) VALUES (?,?,?)",
                                   (install_id, _iso(now), json.dumps(facts, sort_keys=True)))
            return cur.lastrowid

    def recent_sessions(self, install_id: str, limit: int, before_id: int) -> list[dict]:
        with self._lock:
            rows = self._db.execute("SELECT facts_json FROM sessions WHERE install_id=? AND id<? ORDER BY id DESC LIMIT ?",
                                    (install_id, before_id, limit)).fetchall()
        return [json.loads(r["facts_json"]) for r in rows]

    def count_sessions(self, install_id: str) -> int:
        with self._lock:
            return self._db.execute("SELECT COUNT(*) FROM sessions WHERE install_id=?", (install_id,)).fetchone()[0]

    def purge_expired(self, now: datetime, days: int) -> int:
        with self._lock:
            return self._db.execute("DELETE FROM sessions WHERE created_at < ?", (_iso(now - timedelta(days=days)),)).rowcount

    def delete_install(self, install_id: str) -> int:
        """Turn-off: sessions, consent and token go. Spend rows stay (cost only) with the install id blanked."""
        with self._lock:
            n = self._db.execute("DELETE FROM sessions WHERE install_id=?", (install_id,)).rowcount
            self._db.execute("DELETE FROM devices WHERE install_id=?", (install_id,))
            self._db.execute("UPDATE ledger SET install_id='' WHERE install_id=?", (install_id,))
            return n

    # spend ledger
    def day_count(self, install_id: str, day_start: datetime) -> int:
        with self._lock:
            return self._db.execute("SELECT COUNT(*) FROM ledger WHERE install_id=? AND ts>=? AND state IN ('reserved','settled')",
                                    (install_id, _iso(day_start))).fetchone()[0]

    def month_spend(self, month_start: datetime) -> float:
        with self._lock:
            return float(self._db.execute(
                "SELECT COALESCE(SUM(CASE WHEN state='reserved' THEN reserved_usd WHEN state='settled' THEN cost_usd ELSE 0 END),0) "
                "FROM ledger WHERE ts>=?", (_iso(month_start),)).fetchone()[0])

    def reserve(self, install_id: str, est: float, now: datetime) -> int:
        with self._lock:
            return self._db.execute("INSERT INTO ledger (install_id, ts, state, reserved_usd) VALUES (?,?,?,?)",
                                    (install_id, _iso(now), "reserved", est)).lastrowid

    def settle(self, ledger_id: int, cost: float) -> None:
        with self._lock:
            self._db.execute("UPDATE ledger SET state='settled', cost_usd=? WHERE id=?", (cost, ledger_id))

    def release(self, ledger_id: int) -> None:
        with self._lock:
            self._db.execute("UPDATE ledger SET state='released' WHERE id=?", (ledger_id,))

    def tx(self):
        return self._lock
