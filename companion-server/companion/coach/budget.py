"""Coach spend control (eng-review B9): a persistent ledger with reserve/settle, a monthly cap shared with the cards,
and per-runner daily caps that live in the database (a restart does not reset them).

Month spend = card calls (llm_calls) + coach calls (cost_ledger: settled cost, plus open reservations at their reserved
amount). A coach call may reserve only if month spend + its estimate stays under the coach cap less what the cards still
have reserved (coach_card_reserve_usd minus the cards' own spend this month), so chat can never use the cards' share.
The card writer keeps its own cap (COMPANION_MONTHLY_CAP_USD) unchanged.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

from ..config import Settings
from ..rails import add_alert
from ..timeutil import iso, to_local

STALE_RESERVATION = timedelta(minutes=10)


def month_start(now: datetime) -> str:
    return now.strftime("%Y-%m-01T00:00:00Z")


def day_start(now: datetime, zone_id: str | None = None) -> str:
    """The runner's local midnight, as a UTC timestamp: the daily caps reset when their day does, not at 00:00 UTC."""
    local = to_local(now, zone_id or "UTC")
    return iso(local.replace(hour=0, minute=0, second=0, microsecond=0))


def _ledger_sum(c, since: str, user_id: str | None = None) -> float:
    q = ("SELECT COALESCE(SUM(CASE WHEN state='reserved' THEN reserved_usd WHEN state='settled' THEN cost_usd ELSE 0 END),0) "
         "FROM cost_ledger WHERE ts >= ?")
    args: list[Any] = [since]
    if user_id is not None:
        q += " AND user_id = ?"
        args.append(user_id)
    return float(c.execute(q, args).fetchone()[0])


def card_spend(c, now: datetime) -> float:
    return float(c.execute("SELECT COALESCE(SUM(cost_usd),0) FROM llm_calls WHERE ts >= ?", (month_start(now),)).fetchone()[0])


def month_spend(c, now: datetime) -> float:
    return card_spend(c, now) + _ledger_sum(c, month_start(now))


def user_month_spend(c, user_id: str, now: datetime) -> float:
    """One runner's model spend this month: their chat calls (ledger) and their card calls."""
    cards = float(c.execute("SELECT COALESCE(SUM(cost_usd),0) FROM llm_calls WHERE user_id=? AND ts >= ?",
                            (user_id, month_start(now))).fetchone()[0])
    return cards + _ledger_sum(c, month_start(now), user_id)


def chat_headroom(c, s: Settings, now: datetime) -> float:
    cards = card_spend(c, now)
    card_hold = max(0.0, s.coach_card_reserve_usd - cards)
    return s.coach_monthly_cap_usd - card_hold - (cards + _ledger_sum(c, month_start(now)))


CACHE_WRITE_PREMIUM = 1.25


def estimate(s: Settings, prompt_chars: int, first: bool = False) -> float:
    """Upper-bound cost of one call: every prompt token at the uncached rate (2.5 chars a token covers JSON tool results),
    the cache-write premium on a job's first call, plus a full max_tokens reply."""
    tokens_in = prompt_chars / 2.5
    rate_in = s.coach_usd_per_mtok_in * (CACHE_WRITE_PREMIUM if first else 1.0)
    return (tokens_in * rate_in + s.coach_max_tokens * s.coach_usd_per_mtok_out) / 1e6


def screen_estimate(s: Settings, chars: int) -> float:
    """Upper bound for one classifier call, priced at the main model's rates (Haiku is cheaper, so this over-reserves)."""
    return ((chars + 2000) / 2.5 * s.coach_usd_per_mtok_in + s.coach_screen_max_tokens * s.coach_usd_per_mtok_out) / 1e6


def daily_msgs(c, user_id: str, now: datetime, zone_id: str | None = None) -> int:
    """Chat turns charged today: jobs that were (or are being) answered, not merged ones, not safety replies."""
    return int(c.execute("SELECT COUNT(*) FROM coach_jobs WHERE user_id=? AND kind='chat' AND created_at>=? "
                         "AND state IN ('running','replied','sending','sent','failed')", (user_id, day_start(now, zone_id))).fetchone()[0])


def reserve(c, s: Settings, user_id: str, job_id: int, est: float, now: datetime, prompt_hash: str | None = None,
            zone_id: str | None = None, *, purpose: str = "chat") -> tuple[int | None, str]:
    """Inside the caller's write transaction. -> (ledger id, "") or (None, why): 'month_cap' (everyone), 'user_month' (this
    runner's own month) or 'daily_usd'."""
    if est > chat_headroom(c, s, now):
        return None, "month_cap"
    if s.user_monthly_cap_usd > 0 and user_month_spend(c, user_id, now) + est > s.user_monthly_cap_usd:
        return None, "user_month"
    if _ledger_sum(c, day_start(now, zone_id), user_id) + est > s.coach_daily_usd:
        return None, "daily_usd"
    model = s.coach_screen_model if purpose == "screen" else s.coach_model
    cur = c.execute("INSERT INTO cost_ledger (ts, user_id, job_id, model, prompt_hash, purpose, state, reserved_usd) "
                    "VALUES (?,?,?,?,?,?,?,?)", (iso(now), user_id, job_id, model, prompt_hash, purpose, "reserved", est))
    return cur.lastrowid, ""


def _num(v: Any) -> int | None:
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def usage_fields(usage: Any, s: Settings) -> dict:
    """Cost and token counts from OpenRouter's usage block. Cached tokens are recorded so cache hits can be verified
    on the first real messages (eng-review W5)."""
    u = usage if isinstance(usage, dict) else {}
    details = u.get("prompt_tokens_details") if isinstance(u.get("prompt_tokens_details"), dict) else {}
    pt, ct = _num(u.get("prompt_tokens")), _num(u.get("completion_tokens"))
    cost = u.get("cost")
    if isinstance(cost, (int, float)) and not isinstance(cost, bool):
        usd = float(cost)
    else:
        usd = ((pt or 0) * s.coach_usd_per_mtok_in + (ct or 0) * s.coach_usd_per_mtok_out) / 1e6
    return {"cost_usd": usd, "prompt_tokens": pt, "completion_tokens": ct,
            "cached_tokens": _num(details.get("cached_tokens")),
            "cache_write_tokens": _num(details.get("cache_write_tokens"))}


def settle(c, s: Settings, ledger_id: int, now: datetime, *, provider: str | None, outcome: str, fields: dict | None) -> None:
    """Replace the reservation with the real cost (or release it when the call cost nothing), then the spend alerts."""
    if fields is None:
        c.execute("UPDATE cost_ledger SET state='released', outcome=? WHERE id=? AND state='reserved'", (outcome, ledger_id))
        return
    c.execute("UPDATE cost_ledger SET state='settled', provider=?, outcome=?, cost_usd=?, prompt_tokens=?, completion_tokens=?, "
              "cached_tokens=?, cache_write_tokens=? WHERE id=? AND state='reserved'",
              (provider, outcome, fields["cost_usd"], fields["prompt_tokens"], fields["completion_tokens"],
               fields["cached_tokens"], fields["cache_write_tokens"], ledger_id))
    cap_alerts(c, s, now)


def release_stale(c, now: datetime) -> int:
    """A reservation whose call never settled (the process died mid-call) stops holding budget after 10 minutes."""
    return c.execute("UPDATE cost_ledger SET state='released', outcome='stale' WHERE state='reserved' AND ts < ?",
                     (iso(now - STALE_RESERVATION),)).rowcount


def cap_alerts(c, s: Settings, now: datetime) -> None:
    """One alert the first time the month's total model spend reaches 50%, 80% and 100% of the coach cap."""
    cap = s.coach_monthly_cap_usd
    if cap <= 0:
        return
    month = now.strftime("%Y-%m")
    spend = month_spend(c, now)
    crossed = [f for f in sorted(s.cap_alert_fractions) if spend >= cap * f]
    for i, f in enumerate(crossed):
        pct = round(f * 100)
        title = (f"Run Supreme coach: model spend hit the ${cap:g} coach cap" if f >= 1.0
                 else f"Run Supreme coach: model spend at {pct}% of the ${cap:g} coach cap")
        body = (f"US${spend:.2f} of US${cap:g} spent this month (cards + chat). "
                + ("Coach chat now answers with a template until the 1st, or until COMPANION_COACH_MONTHLY_CAP_USD is raised."
                   if f >= 1.0 else "At 100% the coach chat switches to a template reply."))
        add_alert(c, f"coachcap:{month}:{cap:g}:{pct}", title, body, now, sent=i < len(crossed) - 1)
