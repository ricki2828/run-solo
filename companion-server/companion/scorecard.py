"""Phase A tester scorecard: per tester per week, the trust and return numbers for the closed-test gate.

Read-only: SELECTs only. Testers appear as T1, T2... (order of sign-up), never a handle, chat id or name.

  python -m companion.scorecard --db PATH [--weeks N] [--format text|json]

Definitions (weeks are Monday 00:00 UTC to Monday, the last one being the current week):
  runs      real uploads received (replay-created rows excluded)
  cards     cards actually sent (sent_at set; replay cards excluded)
  taps      cards with any button answered (cards.answered_at)
  feel      runs carrying a feel tap (easy/right/hard), by upload week
  notes     run notes typed
  engaged   a calendar week with at least one run or note. Opens are not logged, and inbound_seen / msglog cannot separate
            a free-text reply from a button tap, /start, STOP or a note (msglog holds outbound only), so there is no
            replies column.
  w4        week-4 retention: engaged in days 21..27 after sign-up; None until that week has fully passed
Retention: purge() deletes cards (and msglog) older than 30 days. cards and taps for weeks that start before the 30-day
window are partial and are marked "~". Engagement and w4 use runs and run_notes only, which are not purged, so they
never flip later.
Testers: users with a device (a finished enrolment). Runs with real_upload 0, or NULL and tagged inserted=1 in
replay_runs, are replay-created and skipped. llm_calls cannot be told apart for replays, so cost includes any replay calls.
LLM cost: a call with llm_calls.user_id is that runner's own cost. Calls without one (made before the column existed, or by
a runner since deleted) are a weekly total split evenly across the users sent a card that week (an allocation).
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from datetime import datetime, timedelta, timezone

UTC = timezone.utc
_KEY = {"run": "runs", "card": "cards", "tap": "taps", "feel": "feel", "note": "notes"}


def _iso(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(UTC)


def _week_start(dt: datetime) -> datetime:
    d = dt.astimezone(UTC).replace(hour=0, minute=0, second=0, microsecond=0)
    return d - timedelta(days=d.weekday())


def _rows(c: sqlite3.Connection, sql: str, args: tuple = ()) -> list[tuple]:
    return [tuple(r) for r in c.execute(sql, args)]


def _has(c: sqlite3.Connection, table: str) -> bool:
    return c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


RUNS_SQL = ("SELECT user_id, received_at, feel FROM runs WHERE COALESCE(real_upload,1) != 0 AND NOT (real_upload IS NULL "
            "AND EXISTS (SELECT 1 FROM replay_runs p WHERE p.user_id = runs.user_id AND p.run_id = runs.run_id AND p.inserted = 1))")
RETENTION_DAYS = 30  # service.RETENTION_LOG_DAYS


def _blank() -> dict:
    return dict(runs=0, cards=0, taps=0, feel=0, notes=0)


def open_ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=15)


def compute_scorecard(c: sqlite3.Connection, now: datetime | None = None, weeks: int = 4) -> dict:
    """All SELECTs run in one read transaction, so the sections agree with each other."""
    opened = not c.in_transaction
    if opened:
        c.execute("BEGIN")
    try:
        return _compute(c, now, weeks)
    finally:
        if opened:
            c.rollback()


def _compute(c: sqlite3.Connection, now: datetime | None, weeks: int) -> dict:
    now = (now or datetime.now(UTC)).astimezone(UTC)
    weeks = max(1, weeks)
    cur_start = _week_start(now)
    starts = [cur_start - timedelta(weeks=weeks - 1 - i) for i in range(weeks)]
    cutoff = now - timedelta(days=RETENTION_DAYS)  # purge cut point; a week starting before it has lost its earliest days
    end = starts[-1] + timedelta(weeks=1)

    users = _rows(c, "SELECT id, created_at FROM users WHERE EXISTS (SELECT 1 FROM devices d WHERE d.user_id = users.id) ORDER BY created_at, id")
    alias = {uid: f"T{i + 1}" for i, (uid, _) in enumerate(users)}
    if any(r[1] == "tester_no" for r in c.execute("PRAGMA table_info(users)")):
        # the same T-number the ops CLI shows, so the scorecard and `ops roster` talk about the same people
        nums = dict(_rows(c, "SELECT id, tester_no FROM users"))
        if all(nums.get(uid) for uid, _ in users) and len({nums[uid] for uid, _ in users}) == len(users):
            alias = {uid: f"T{nums[uid]}" for uid, _ in users}
    signup = {uid: _parse(ts) for uid, ts in users}

    replay_cards = ({r[0] for r in _rows(c, "SELECT card_id FROM replay_items WHERE card_id IS NOT NULL")}
                    if _has(c, "replay_items") else set())

    ev: list[tuple[str, str, datetime]] = []
    for uid, ts, feel in _rows(c, RUNS_SQL):
        ev.append((uid, "run", _parse(ts)))
        if feel:
            ev.append((uid, "feel", _parse(ts)))
    for uid, cid, sent, ans in _rows(c, "SELECT user_id, card_id, sent_at, answered_at FROM cards"):
        if cid in replay_cards:
            continue
        if sent:
            ev.append((uid, "card", _parse(sent)))
        if ans:
            ev.append((uid, "tap", _parse(ans)))
    for uid, ts in _rows(c, "SELECT user_id, created_at FROM run_notes"):
        ev.append((uid, "note", _parse(ts)))

    engaging = {"run", "note"}
    per_week: dict[str, list[dict]] = {}
    engaged_days: dict[str, set[int]] = {}
    engaged_weeks: dict[str, set[datetime]] = {}
    for uid, kind, ts in ev:
        if uid not in alias:
            continue
        if kind in engaging:
            engaged_days.setdefault(uid, set()).add((ts - signup[uid]).days)
            engaged_weeks.setdefault(uid, set()).add(_week_start(ts))
        if ts < starts[0] or ts >= end:
            continue
        wi = (_week_start(ts) - starts[0]).days // 7
        per_week.setdefault(uid, [_blank() for _ in starts])[wi][_KEY[kind]] += 1

    cost = [0.0] * weeks              # every call, attributed or not
    user_cost: dict[str, list[float]] = {}   # calls that carry a user_id, by user and week
    if _has(c, "llm_calls"):
        has_uid = any(r[1] == "user_id" for r in c.execute("PRAGMA table_info(llm_calls)"))
        sql = ("SELECT ts, cost_usd, user_id FROM llm_calls WHERE ts >= ?" if has_uid
               else "SELECT ts, cost_usd, NULL FROM llm_calls WHERE ts >= ?")
        for ts, usd, cuid in _rows(c, sql, (_iso(starts[0]),)):
            wi = (_week_start(_parse(ts)) - starts[0]).days // 7
            if 0 <= wi < weeks:
                cost[wi] += usd or 0.0
                if cuid:
                    user_cost.setdefault(cuid, [0.0] * weeks)[wi] += usd or 0.0
    attributed = [sum(v[i] for v in user_cost.values()) for i in range(weeks)]

    testers = []
    for uid, _ in users:
        days = engaged_days.get(uid, set())
        age_days = (now - signup[uid]).days
        sw = _week_start(signup[uid])
        wk = per_week.get(uid) or [_blank() for _ in starts]
        wk = [dict(w, pre_signup=True) if st < sw else dict(w, pre_signup=False) for w, st in zip(wk, starts)]
        for w, st in zip(wk, starts):
            w["partial"] = st < cutoff  # cards/taps older than the purge window are incomplete
        testers.append({
            "id": alias[uid], "signed_up": signup[uid].strftime("%Y-%m-%d"), "weeks_since_signup": (cur_start - sw).days // 7,
            "active_weeks": len({w for w in engaged_weeks.get(uid, ()) if w >= sw}),
            "week4_retained": any(21 <= d < 28 for d in days) if age_days >= 28 else None,
            "weeks": wk,
        })

    sent_users = [sum(1 for t in testers if t["weeks"][i]["cards"] > 0) for i in range(weeks)]
    by_alias = {alias[u]: u for u, _ in users}
    for t in testers:
        own = user_cost.get(by_alias[t["id"]], [0.0] * weeks)
        # a call with a user_id is that runner's; calls without one (made before the column, or by a runner since deleted)
        # are split evenly across the runners sent a card that week, as before
        t["llm_cost_usd_alloc"] = [round(own[i] + ((cost[i] - attributed[i]) / sent_users[i]
                                                   if sent_users[i] and t["weeks"][i]["cards"] else 0.0), 4)
                                   for i in range(weeks)]
    eligible = [t for t in testers if t["week4_retained"] is not None]
    return {
        "generated": _iso(now), "week_starts": [s.strftime("%Y-%m-%d") for s in starts], "testers": testers,
        "llm_cost_usd_total": [round(x, 4) for x in cost],
        "llm_cost_note": "per-tester cost is that runner's own calls (llm_calls.user_id); calls with no runner id are split evenly across testers sent a card that week",
        "enrol_refused_by_day": (dict(_rows(c, "SELECT day, n FROM enrol_refused ORDER BY day")) if _has(c, "enrol_refused") else {}),
        "week4": {"retained": sum(1 for t in eligible if t["week4_retained"]), "eligible": len(eligible)},
    }


def format_text(sc: dict) -> str:
    ws = sc["week_starts"]
    n = len(ws)
    out = [f"Run Supreme Phase A scorecard ({sc['generated'][:10]})",
           f"Weeks from {ws[0]} (Mon, UTC). Per week: runs/cards/taps/notes + f=feel taps",
           "act = calendar weeks with a run or note / weeks since sign-up (incl. current); - = before sign-up;",
           "~ = cards/taps incomplete (older than 30-day purge); w4 uses runs+notes only", ""]
    for t in sc["testers"]:
        w4 = {None: "n/a", True: "yes", False: "NO"}[t["week4_retained"]]
        cells = " ".join("-" if w["pre_signup"] else
                         f"{w['runs']}/{w['cards']}/{w['taps']}/{w['notes']}f{w['feel']}" + ("~" if w["partial"] else "")
                         for w in t["weeks"])
        out.append(f"{t['id']} act {t['active_weeks']}/{t['weeks_since_signup'] + 1} w4 {w4} | {cells}")
    out.append("")
    out.append("Cards sent/wk: " + " ".join(str(sum(t["weeks"][i]["cards"] for t in sc["testers"])) + ("~" if sc["testers"] and sc["testers"][0]["weeks"][i]["partial"] else "") for i in range(n)))
    out.append("LLM cost USD/wk (total, replay calls not separable): " + " ".join(f"{x:.2f}" for x in sc["llm_cost_usd_total"]))
    per = []
    for i in range(n):
        k = sum(1 for t in sc["testers"] if t["weeks"][i]["cards"] > 0)
        per.append(f"{sc['llm_cost_usd_total'][i] / k:.3f}" if k else "-")
    out.append("LLM cost/user/wk (even split, not measured per user): " + " ".join(per))
    w4 = sc["week4"]
    out.append(f"Week-4 retention: {w4['retained']}/{w4['eligible']} eligible")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="companion.scorecard", description="Phase A tester scorecard (read-only)")
    p.add_argument("--db", required=True)
    p.add_argument("--weeks", type=int, default=4)
    p.add_argument("--format", choices=("text", "json"), default="text")
    a = p.parse_args(argv)
    c = open_ro(a.db)
    try:
        sc = compute_scorecard(c, weeks=a.weeks)
    finally:
        c.close()
    print(json.dumps(sc, indent=2) if a.format == "json" else format_text(sc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
