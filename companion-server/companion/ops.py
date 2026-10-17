"""Operator commands for the tester programme: python -m companion.cli ops {status|roster|pause T3|resume T3|alerts}.

Runners are named by tester number (T1, T2 ...) everywhere: output, logs and alerts. This module never prints a chat id,
a chat name or a user id. The T-number to person map lives only on Ricki's host (~/Files/RunSupreme/testers/roster.md).
"""
from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable

from . import db
from .config import Settings
from .rails import pending_alerts, tag
from .timeutil import iso, now_utc

log = logging.getLogger("companion")
TESTER = re.compile(r"^[Tt](\d{1,6})$")
USAGE = "usage: ops status | roster | pause T<n> | resume T<n> | alerts | feedback [days] | survey purge --yes | scorecard-snapshot [dir] | send ... | sends | templates"


def _month_start() -> str:
    return now_utc().strftime("%Y-%m-01T00:00:00Z")


def _state(r) -> str:
    if r["ops_paused"]:
        return f"ops-paused({r['ops_paused_reason'] or 'ops'})"
    return "stopped-by-runner" if r["paused"] else "active"


def roster(s: Settings) -> list[str]:
    start = _month_start()
    with db.ro(s.db_path) as c:
        rows = c.execute(
            "SELECT u.tester_no, u.channel, u.created_at, u.last_run_utc, u.paused, u.ops_paused, u.ops_paused_reason, "
            "(SELECT COUNT(*) FROM runs r WHERE r.user_id=u.id) AS runs, "
            "(SELECT COALESCE(SUM(cost_usd),0) FROM llm_calls l WHERE l.user_id=u.id AND l.ts >= ?) AS cost "
            "FROM users u ORDER BY u.tester_no", (start,)).fetchall()
    return [f"{tag(r['tester_no'])} {r['channel']} state={_state(r)} joined={(r['created_at'] or '')[:10]} "
            f"last_run={(r['last_run_utc'] or '-')[:10]} runs={r['runs']} llm_month_usd={r['cost']:.4f}" for r in rows]


def status(s: Settings) -> list[str]:
    start = _month_start()
    today = now_utc().strftime("%Y-%m-%d")
    with db.ro(s.db_path) as c:
        n = c.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        held = [f"{r['channel']}:{r['chat_ref']}" for r in c.execute(
            "SELECT channel, chat_ref FROM users WHERE EXISTS (SELECT 1 FROM devices d WHERE d.user_id = users.id) OR created_at >= ?",
            (iso(now_utc() - timedelta(hours=1)),))]
        places = sum(1 for h in held if h not in s.allowed_ids)
        stale = c.execute("SELECT COUNT(*) FROM alerts WHERE sent_at IS NULL AND ts < ?", (iso(now_utc() - timedelta(hours=24)),)).fetchone()[0]
        ops = c.execute("SELECT COUNT(*) FROM users WHERE ops_paused=1").fetchone()[0]
        stopped = c.execute("SELECT COUNT(*) FROM users WHERE paused=1 AND ops_paused=0").fetchone()[0]
        spend = c.execute("SELECT COALESCE(SUM(cost_usd),0) FROM llm_calls WHERE ts >= ?", (start,)).fetchone()[0]
        refused = c.execute("SELECT n FROM enrol_refused WHERE day=?", (today,)).fetchone()
        refused_all = c.execute("SELECT COALESCE(SUM(n),0) FROM enrol_refused").fetchone()[0]
        kill = c.execute("SELECT value FROM settings WHERE key='sends_paused'").fetchone()
    cap = s.monthly_cap_usd
    return [
        f"runners={n} places={places}/{s.max_users} (allowlisted runners take none) open_enrolment={'on' if s.open_enrolment else 'off'} "
        f"ops_paused={ops} stopped_by_runner={stopped}",
        f"llm_month_usd={spend:.2f} cap_usd={cap:g} used={spend / cap * 100 if cap else 0:.0f}% "
        f"{'(templates only)' if cap and spend >= cap else ''}".rstrip(),
        f"enrol_refused_today={refused[0] if refused else 0} enrol_refused_total={refused_all}",
        f"global_pause={'ON' if (kill and kill[0] == '1') or s.sends_paused else 'off'} "
        f"alerts_unsent={len(pending_alerts(s.db_path))}"
        + (f" ALERTS_STALE={stale} unsent for over 24h: the alert cron is not delivering (crontab -l | grep flush-alerts)" if stale else ""),
    ]


def set_ops_pause(s: Settings, who: str, pause: bool) -> tuple[int, str]:
    m = TESTER.match(who or "")
    if not m:
        return 2, USAGE
    n = int(m.group(1))
    with db.tx(s.db_path) as c:
        r = c.execute("SELECT id FROM users WHERE tester_no=?", (n,)).fetchone()
        if not r:
            return 1, f"no runner T{n}"
        if pause:
            c.execute("UPDATE users SET ops_paused=1, ops_paused_reason='ops' WHERE id=?", (r["id"],))
        else:
            c.execute("UPDATE users SET ops_paused=0, ops_paused_reason=NULL WHERE id=?", (r["id"],))
            c.execute("DELETE FROM inbound_strikes WHERE user_id=?", (r["id"],))   # a fresh start, or the next flood re-pauses at once
    log.info("ops %s tester=T%d", "pause" if pause else "resume", n)
    return 0, f"T{n} {'paused: they get no messages and their chat is ignored (DELETE still works)' if pause else 'resumed'}"


def alerts(s: Settings) -> list[str]:
    return [f"#{a['id']} {a['ts']} {a['title']} | {a['body']}" for a in pending_alerts(s.db_path)] or ["no unsent alerts"]


def feedback(s: Settings, days: int = 7, limit: int = 200) -> list[str]:
    """Recent Tell Ricki feedback, newest first, one line each: `T3 2026-10-16T08:01:02Z text`. Runners are named by
    tester number only. The text is the runner's own words and is printed to the operator and nowhere else."""
    since = iso(now_utc() - timedelta(days=days))
    with db.ro(s.db_path) as c:
        rows = c.execute(
            "SELECT u.tester_no, f.ts, f.text FROM feedback f JOIN users u ON u.id = f.user_id "
            "WHERE f.ts >= ? ORDER BY f.ts DESC, f.id DESC LIMIT ?", (since, limit)).fetchall()
        total = c.execute("SELECT COUNT(*) FROM feedback WHERE ts >= ?", (since,)).fetchone()[0]
    out = [f"{tag(r['tester_no'])} {r['ts']} {r['text']}" for r in rows]
    if total > len(rows):
        out.insert(0, f"showing latest {len(rows)} of {total}")
    return out


SNAPSHOT_DIR = "~/ai/state/run-supreme-testers"


def scorecard_snapshot(s: Settings, directory: str | None = None, now: datetime | None = None) -> str:
    """Write this week's scorecard as JSON to scorecard-YYYY-WW.json (T-numbers only) and return the path. Cards purge at
    30 days, so the week-1 numbers would be gone by the readout without these. Rewriting the same week replaces the file."""
    from . import scorecard
    now = now or now_utc()
    y, w, _ = now.isocalendar()
    d = Path(directory or SNAPSHOT_DIR).expanduser()
    d.mkdir(parents=True, exist_ok=True)
    con = scorecard.open_ro(s.db_path)
    try:
        sc = scorecard.compute_scorecard(con, now=now)
    finally:
        con.close()
    path = d / f"scorecard-{y}-{w:02d}.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(sc, indent=2))
    tmp.replace(path)
    return str(path)


def main(s: Settings, argv: list[str], out: Callable[[str], None] = print) -> int:
    cmd = argv[0] if argv else "status"
    if cmd == "status":
        lines = status(s)
    elif cmd == "roster":
        lines = roster(s) or ["no runners"]
    elif cmd in ("pause", "resume"):
        code, msg = set_ops_pause(s, argv[1] if len(argv) > 1 else "", cmd == "pause")
        out(msg)
        return code
    elif cmd in ("send", "sends", "templates"):
        from . import ops_send   # the approved-template sender lives in its own module
        return ops_send.main(s, argv, out)
    elif cmd == "alerts":
        lines = alerts(s)
    elif cmd == "scorecard-snapshot":
        out(scorecard_snapshot(s, argv[1] if len(argv) > 1 else None))
        return 0
    elif cmd == "survey" and argv[1:2] == ["purge"]:
        from . import measure
        if "--yes" not in argv:
            out("this deletes every survey answer now; run `ops survey purge --yes` to confirm")
            return 2
        out(f"deleted {measure.purge_surveys(s.db_path, now_utc(), force=True)} survey answers")
        return 0
    elif cmd == "feedback":
        arg = argv[1] if len(argv) > 1 else "7"
        if not arg.isdigit() or not 1 <= int(arg) <= 30:
            out(USAGE)
            return 2
        lines = feedback(s, int(arg)) or [f"no feedback in the last {arg} days"]
    else:
        out(USAGE)
        return 2
    for ln in lines:
        out(ln)
    return 0
