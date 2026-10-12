"""Phase A tester scorecard: per tester per week, the trust and return numbers for the closed-test gate.

Read-only: SELECTs only. Testers appear as T1, T2... (order of sign-up), never a handle, chat id or name.

  python -m companion.scorecard --db PATH [--weeks N] [--format text|json]

Definitions (weeks are Monday 00:00 UTC to Monday, the last one being the current week):
  runs      real uploads received (replay-created rows excluded)
  cards     cards actually sent (sent_at set; replay cards excluded)
  taps      cards with any button answered (cards.answered_at)
  feel      runs carrying a feel tap (easy/right/hard), by upload week
  replies   inbound messages seen from the user (inbound_seen)
  notes     run notes typed
  engaged   a week with at least one run, tap, reply or note (opens are not logged, so a tap/reply is the proof of return)
  w4        week-4 retention: engaged in days 21..27 after sign-up; None until that week has fully passed
LLM cost: llm_calls has cost_usd but no user column, so cost is a weekly total, and the per-user figure is that total
split evenly across the users who were sent a card that week (an allocation, not a measurement).
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

UTC = timezone.utc
_KEY = {"run": "runs", "card": "cards", "tap": "taps", "feel": "feel", "reply": "replies", "note": "notes"}


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


def _blank() -> dict:
    return dict(runs=0, cards=0, taps=0, feel=0, replies=0, notes=0)


def compute_scorecard(c: sqlite3.Connection, now: datetime | None = None, weeks: int = 4) -> dict:
    now = (now or datetime.now(UTC)).astimezone(UTC)
    weeks = max(1, weeks)
    cur_start = _week_start(now)
    starts = [cur_start - timedelta(weeks=weeks - 1 - i) for i in range(weeks)]
    end = starts[-1] + timedelta(weeks=1)

    users = _rows(c, "SELECT id, created_at FROM users ORDER BY created_at, id")
    alias = {uid: f"T{i + 1}" for i, (uid, _) in enumerate(users)}
    signup = {uid: _parse(ts) for uid, ts in users}

    replay_cards = ({r[0] for r in _rows(c, "SELECT card_id FROM replay_items WHERE card_id IS NOT NULL")}
                    if _has(c, "replay_items") else set())

    ev: list[tuple[str, str, datetime]] = []
    for uid, ts, feel in _rows(c, "SELECT user_id, received_at, feel FROM runs WHERE COALESCE(real_upload,1) != 0"):
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
    for uid, ts in _rows(c, "SELECT user_id, ts FROM inbound_seen WHERE user_id IS NOT NULL"):
        ev.append((uid, "reply", _parse(ts)))
    for uid, ts in _rows(c, "SELECT user_id, created_at FROM run_notes"):
        ev.append((uid, "note", _parse(ts)))

    engaging = {"run", "tap", "reply", "note"}
    per_week: dict[str, list[dict]] = {}
    engaged_days: dict[str, set[int]] = {}
    for uid, kind, ts in ev:
        if uid not in alias:
            continue
        if kind in engaging:
            engaged_days.setdefault(uid, set()).add((ts - signup[uid]).days)
        if ts < starts[0] or ts >= end:
            continue
        wi = (_week_start(ts) - starts[0]).days // 7
        per_week.setdefault(uid, [_blank() for _ in starts])[wi][_KEY[kind]] += 1

    cost = [0.0] * weeks
    if _has(c, "llm_calls"):
        for ts, usd in _rows(c, "SELECT ts, cost_usd FROM llm_calls WHERE ts >= ?", (_iso(starts[0]),)):
            wi = (_week_start(_parse(ts)) - starts[0]).days // 7
            if 0 <= wi < weeks:
                cost[wi] += usd or 0.0

    testers = []
    for uid, _ in users:
        days = engaged_days.get(uid, set())
        age_days = (now - signup[uid]).days
        testers.append({
            "id": alias[uid], "signed_up": signup[uid].strftime("%Y-%m-%d"), "weeks_since_signup": age_days // 7,
            "active_weeks": len({d // 7 for d in days if d >= 0}),
            "week4_retained": any(21 <= d < 28 for d in days) if age_days >= 28 else None,
            "weeks": per_week.get(uid) or [_blank() for _ in starts],
        })

    sent_users = [sum(1 for t in testers if t["weeks"][i]["cards"] > 0) for i in range(weeks)]
    for t in testers:
        t["llm_cost_usd_alloc"] = [round(cost[i] / sent_users[i], 4) if sent_users[i] and t["weeks"][i]["cards"] else 0.0
                                   for i in range(weeks)]
    eligible = [t for t in testers if t["week4_retained"] is not None]
    return {
        "generated": _iso(now), "week_starts": [s.strftime("%Y-%m-%d") for s in starts], "testers": testers,
        "llm_cost_usd_total": [round(x, 4) for x in cost],
        "llm_cost_note": "llm_calls has no user column: per-tester cost is the weekly total split evenly across testers sent a card that week",
        "week4": {"retained": sum(1 for t in eligible if t["week4_retained"]), "eligible": len(eligible)},
    }


def format_text(sc: dict) -> str:
    ws = sc["week_starts"]
    n = len(ws)
    out = [f"Run Supreme Phase A scorecard ({sc['generated'][:10]})",
           f"Weeks from {ws[0]} (Mon, UTC). Per week: runs/cards/taps/replies/notes + f=feel taps",
           "act = engaged weeks / weeks since sign-up", ""]
    for t in sc["testers"]:
        w4 = {None: "n/a", True: "yes", False: "NO"}[t["week4_retained"]]
        cells = " ".join(f"{w['runs']}/{w['cards']}/{w['taps']}/{w['replies']}/{w['notes']}f{w['feel']}" for w in t["weeks"])
        out.append(f"{t['id']} act {t['active_weeks']}/{t['weeks_since_signup'] + 1} w4 {w4} | {cells}")
    out.append("")
    out.append("Cards sent/wk: " + " ".join(str(sum(t["weeks"][i]["cards"] for t in sc["testers"])) for i in range(n)))
    out.append("LLM cost USD/wk (total): " + " ".join(f"{x:.2f}" for x in sc["llm_cost_usd_total"]))
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
    c = sqlite3.connect("file:" + a.db + "?mode=ro", uri=True, timeout=15)
    try:
        sc = compute_scorecard(c, weeks=a.weeks)
    finally:
        c.close()
    print(json.dumps(sc, indent=2) if a.format == "json" else format_text(sc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
