"""Tester rails: the inbound rate limiter and the alert queue.

The limiter lives in memory and is keyed by channel and chat, so a stranger's chat is never written to the database
for it. Only a known runner's slow-downs are stored (inbound_strikes, 2 days), to pause a repeat offender.
Alerts are rows in `alerts`; the host cron (deploy/flush-alerts.sh) sends them through notify, because the service
sandbox cannot reach it. Nothing here puts a name or a chat id in an alert: runners are T-numbers.
"""
from __future__ import annotations

import threading
from collections import deque
from datetime import datetime, timedelta

from . import db
from .timeutil import iso

SLOW_DOWN = "You're sending messages faster than I can keep up with. Give it a minute, then try again."
SLOW_DOWN_DAY = "That's a lot of messages for one day. I'll be quiet until tomorrow; your runs still sync as normal."
NOTICE_EVERY = timedelta(minutes=10)   # at most one slow-down note (and one strike) per chat per this long
_FORGET_AFTER = timedelta(days=1)


class RateLimiter:
    """Sliding windows of `per_min` messages a minute and `per_day` a day, per key. A message over a limit is not counted,
    so a flood does not lock a chat out for longer than the window."""

    def __init__(self, per_min: int, per_day: int):
        self.per_min, self.per_day = per_min, per_day
        self._hits: dict[str, deque[datetime]] = {}
        self._noticed: dict[str, datetime] = {}
        self._lock = threading.Lock()

    def check(self, key: str, now: datetime) -> str:
        """-> 'ok' | 'notice' (over a limit, send the slow-down note once) | 'silent' (over a limit, already told)."""
        with self._lock:
            if len(self._hits) > 5000:
                self._prune(now)
            q = self._hits.setdefault(key, deque())
            while q and q[0] <= now - timedelta(days=1):
                q.popleft()
            minute = sum(1 for t in q if t > now - timedelta(minutes=1))
            day_hit = len(q) >= self.per_day
            if minute < self.per_min and not day_hit:
                q.append(now)
                return "ok"
            last = self._noticed.get(key)
            if last is not None and now - last < NOTICE_EVERY:
                return "silent"
            self._noticed[key] = now
            return "notice-day" if day_hit else "notice"

    def _prune(self, now: datetime) -> None:
        for k in [k for k, q in self._hits.items() if not q or q[-1] <= now - _FORGET_AFTER]:
            del self._hits[k]
        for k in [k for k, t in self._noticed.items() if t <= now - _FORGET_AFTER]:
            del self._noticed[k]


def add_alert(c, key: str, title: str, body: str, now: datetime, *, sent: bool = False) -> bool:
    """Queue an alert once per `key` (inside the caller's transaction). True when this call queued it."""
    cur = c.execute("INSERT OR IGNORE INTO alerts (key, ts, title, body, sent_at) VALUES (?,?,?,?,?)",
                    (key, iso(now), title, body, iso(now) if sent else None))
    return cur.rowcount == 1


def tag(tester_no: int | None) -> str:
    return f"T{tester_no}" if tester_no else "a runner"


def pending_alerts(path: str) -> list[dict]:
    with db.ro(path) as c:
        return [dict(r) for r in c.execute("SELECT id, ts, title, body FROM alerts WHERE sent_at IS NULL ORDER BY id")]
