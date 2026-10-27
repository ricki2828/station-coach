"""SQLite store: consent, device tokens, kept sessions (30 days), registrations and the spend ledger.

Timestamps are stored at day precision (D11): the server does not keep when in the day a session ended."""
from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
  install_id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
  consent_version INTEGER NOT NULL, created_at TEXT NOT NULL, last_seen TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, install_id TEXT NOT NULL,
  created_at TEXT NOT NULL, facts_json TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS sessions_install ON sessions(install_id, id);
CREATE TABLE IF NOT EXISTS ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT, install_id TEXT NOT NULL, ts TEXT NOT NULL,
  state TEXT NOT NULL, reserved_usd REAL NOT NULL, cost_usd REAL NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS ledger_ts ON ledger(ts);
CREATE TABLE IF NOT EXISTS registrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT NOT NULL, ip_hash TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS registrations_day ON registrations(day);
"""


def day(t: datetime) -> str:
    return t.strftime("%Y-%m-%d")


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class Store:
    def __init__(self, path: str):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=10)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        self._db.executescript(SCHEMA)

    @contextmanager
    def transaction(self):
        """BEGIN IMMEDIATE so a second process cannot interleave between a check and its insert."""
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            self._db.execute("COMMIT")

    # consent and tokens
    def register(self, install_id: str, consent_version: int, now: datetime) -> str:
        """Record consent; returns a fresh token (the caller has already checked a re-register is allowed)."""
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._db.execute(
                "INSERT INTO devices (install_id, token_hash, consent_version, created_at, last_seen) VALUES (?,?,?,?,?) "
                "ON CONFLICT(install_id) DO UPDATE SET token_hash=excluded.token_hash, consent_version=excluded.consent_version, "
                "last_seen=excluded.last_seen",
                (install_id, _hash(token), consent_version, day(now), day(now)))
        return token

    def device_for_token(self, token: str) -> sqlite3.Row | None:
        with self._lock:
            return self._db.execute("SELECT * FROM devices WHERE token_hash=?", (_hash(token),)).fetchone()

    def device_exists(self, install_id: str) -> bool:
        with self._lock:
            return self._db.execute("SELECT 1 FROM devices WHERE install_id=?", (install_id,)).fetchone() is not None

    def touch(self, install_id: str, now: datetime) -> None:
        with self._lock:
            self._db.execute("UPDATE devices SET last_seen=? WHERE install_id=?", (day(now), install_id))

    # registrations (rate limits)
    def note_registration(self, ip: str, now: datetime) -> None:
        with self._lock:
            self._db.execute("INSERT INTO registrations (day, ip_hash) VALUES (?,?)", (day(now), _hash("ip:" + ip)))

    def registrations_today(self, now: datetime, ip: str | None = None) -> int:
        q, args = "SELECT COUNT(*) FROM registrations WHERE day=?", [day(now)]
        if ip is not None:
            q += " AND ip_hash=?"
            args.append(_hash("ip:" + ip))
        with self._lock:
            return self._db.execute(q, args).fetchone()[0]

    # sessions
    def add_session(self, install_id: str, facts: dict, now: datetime) -> int:
        with self._lock:
            cur = self._db.execute("INSERT INTO sessions (install_id, created_at, facts_json) VALUES (?,?,?)",
                                   (install_id, day(now), json.dumps(facts, sort_keys=True)))
            return cur.lastrowid

    def recent_sessions(self, install_id: str, limit: int) -> list[dict]:
        with self._lock:
            rows = self._db.execute("SELECT facts_json FROM sessions WHERE install_id=? ORDER BY id DESC LIMIT ?",
                                    (install_id, limit)).fetchall()
        return [json.loads(r["facts_json"]) for r in rows]

    def count_sessions(self, install_id: str) -> int:
        with self._lock:
            return self._db.execute("SELECT COUNT(*) FROM sessions WHERE install_id=?", (install_id,)).fetchone()[0]

    def purge_expired(self, now: datetime, days: int) -> dict:
        """Everything older than the retention window: sessions, idle devices, install ids on ledger rows (the cost stays,
        it is needed for the month's total), and registration rows."""
        cutoff = day(now - timedelta(days=days))
        with self._lock:
            return {
                "sessions": self._db.execute("DELETE FROM sessions WHERE created_at < ?", (cutoff,)).rowcount,
                "devices": self._db.execute("DELETE FROM devices WHERE last_seen < ?", (cutoff,)).rowcount,
                "ledger_unlinked": self._db.execute("UPDATE ledger SET install_id='' WHERE ts < ? AND install_id != ''", (cutoff,)).rowcount,
                "registrations": self._db.execute("DELETE FROM registrations WHERE day < ?", (cutoff,)).rowcount,
            }

    def delete_install(self, install_id: str) -> int:
        """Turn-off: sessions, consent and token go. Spend rows stay (cost only) with the install id blanked."""
        with self._lock:
            n = self._db.execute("DELETE FROM sessions WHERE install_id=?", (install_id,)).rowcount
            self._db.execute("DELETE FROM devices WHERE install_id=?", (install_id,))
            self._db.execute("UPDATE ledger SET install_id='' WHERE install_id=?", (install_id,))
            return n

    # spend ledger
    def day_count(self, install_id: str, since: datetime) -> int:
        with self._lock:
            return self._db.execute("SELECT COUNT(*) FROM ledger WHERE install_id=? AND ts>=? AND state IN ('reserved','settled')",
                                    (install_id, day(since))).fetchone()[0]

    def spend_since(self, since: datetime) -> float:
        with self._lock:
            return float(self._db.execute(
                "SELECT COALESCE(SUM(CASE WHEN state='reserved' THEN reserved_usd WHEN state='settled' THEN cost_usd ELSE 0 END),0) "
                "FROM ledger WHERE ts>=?", (day(since),)).fetchone()[0])

    def reserve(self, install_id: str, est: float, now: datetime) -> int:
        with self._lock:
            return self._db.execute("INSERT INTO ledger (install_id, ts, state, reserved_usd) VALUES (?,?,?,?)",
                                    (install_id, day(now), "reserved", est)).lastrowid

    def settle(self, ledger_id: int, cost: float) -> None:
        with self._lock:
            self._db.execute("UPDATE ledger SET state='settled', cost_usd=? WHERE id=?", (cost, ledger_id))

    def release(self, ledger_id: int) -> None:
        with self._lock:
            self._db.execute("UPDATE ledger SET state='released' WHERE id=?", (ledger_id,))
