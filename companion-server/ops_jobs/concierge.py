#!/usr/bin/env python3
"""rs-concierge: the daily, deterministic (no model) look at every tester, and the approved nudges that follow.

    python3 ops_jobs/concierge.py [--apply] [--link https://booking...] [--db PATH] [--now ISO]

Default is a dry run: it prints what it would do and why, sends nothing. `--apply` calls `ops send` for each decision.
`ops send` is the gate: it refuses a template Ricki has not approved, a paused or STOPped runner, a runner who has not
agreed to consent v2, a second ops message inside 7 days, and a template already sent. The decisions here only avoid
asking for things that are bound to be refused.

N1 no run by day 3 (once). N2 silent for 7 days (once). N3 chat invite in week 3 (once; needs --link or RS_BOOKING_LINK).
A tester gets at most one of them per day, in that order. The log goes to concierge-YYYY-MM-DD.md in the state dir.
"""
from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from ops_jobs import common  # noqa: E402

N1_DAY, N2_SILENT_DAYS = 3, 7
N3_FROM_DAY, N3_TO_DAY = 14, 20      # week 3 only
SPACING_DAYS = 7             # ops send's own rule (ops_send.SPACING_DAYS); checked here only to say "waiting" instead of "refused"
CONSENT_REQUIRED = int(os.environ.get("RS_CONSENT_REQUIRED") or 2)
STUCK_NO_CONSENT_DAYS = 2    # joined but never agreed to the companion terms
STUCK_NO_RUN_DAYS = 7        # consented, still no run after a week
STUCK_SILENT_DAYS = 14


@dataclass
class Tester:
    n: int
    channel: str = "telegram"
    paused: bool = False            # the runner sent STOP
    ops_paused: bool = False
    consent: int | None = None
    enrolled: bool = True           # finished enrolment (has a device)
    joined: datetime | None = None
    first_run: datetime | None = None
    last_activity: datetime | None = None   # newest run or message or tap; None = nothing since joining
    sent: dict[str, datetime] = field(default_factory=dict)   # template -> when it was queued

    @property
    def tag(self) -> str:
        return f"T{self.n}"


@dataclass
class Decision:
    tester: str
    action: str          # send | wait | skip | flag
    template: str | None
    reason: str


def decide(t: Tester, now: datetime, link: str | None = None) -> list[Decision]:
    """Pure: what to do about one tester. At most one `send`; any number of `flag`s."""
    out: list[Decision] = []

    def d(action: str, reason: str, template: str | None = None) -> None:
        out.append(Decision(t.tag, action, template, reason))

    if t.joined is None or not t.enrolled:
        d("skip", "not enrolled yet")
        return out
    age = (now - t.joined).days
    if t.ops_paused:
        d("flag", "paused by ops: nothing is sent")
        return out
    if t.paused:
        d("flag", "stopped by the runner (STOP): nothing is sent")
        return out
    if t.channel != "telegram":
        d("skip", "not on Telegram")
        return out
    if t.consent is None or t.consent < CONSENT_REQUIRED:
        if age >= STUCK_NO_CONSENT_DAYS:
            d("flag", f"joined {age} days ago but has not agreed to consent v{CONSENT_REQUIRED}: stuck")
        else:
            d("skip", "has not agreed to the companion terms yet")
        return out
    last = t.last_activity or t.joined
    silent = (now - last).days
    if t.first_run is None and age >= STUCK_NO_RUN_DAYS:
        d("flag", f"no run {age} days after joining: stuck")
    elif silent >= STUCK_SILENT_DAYS:
        d("flag", f"silent for {silent} days")
    recent = [(k, v) for k, v in t.sent.items() if v > now - timedelta(days=SPACING_DAYS)]

    want: tuple[str, str] | None = None
    if t.first_run is None and age >= N1_DAY and "N1" not in t.sent:
        want = ("N1", f"no run {age} days after joining")
    elif silent >= N2_SILENT_DAYS and "N2" not in t.sent and (t.first_run is not None or "N1" in t.sent):
        want = ("N2", f"silent for {silent} days")
    elif N3_FROM_DAY <= age <= N3_TO_DAY and t.first_run is not None and "N3" not in t.sent:
        want = ("N3", f"week {age // 7 + 1} and has run: chat invite")
    if want is None:
        d("skip", "nothing due")
        return out
    tpl, why = want
    if tpl == "N3" and not link:
        d("flag", f"N3 is due ({why}) but there is no booking link: pass --link or set RS_BOOKING_LINK")
    elif recent:
        d("wait", f"{tpl} is due ({why}) but {recent[0][0]} went out less than {SPACING_DAYS} days ago", tpl)
    else:
        d("send", why, tpl)
    return out


def load_testers(db: str) -> list[Tester]:
    """Read-only. T-numbers and times only: no name, chat id or user id leaves this function."""
    con = common.open_ro(db)
    try:
        has_events = common.has_table(con, "inbound_events")
        has_sends = common.has_table(con, "ops_sends")
        rows = con.execute(
            "SELECT u.id, u.tester_no, u.channel, u.paused, u.ops_paused, u.checkin_consent, u.consent_at, u.created_at, "
            "u.last_inbound_at, EXISTS (SELECT 1 FROM devices d WHERE d.user_id = u.id) AS enrolled, "
            "(SELECT MIN(r.received_at) FROM runs r WHERE r.user_id = u.id AND COALESCE(r.real_upload,1) != 0) AS first_run, "
            "(SELECT MAX(r.received_at) FROM runs r WHERE r.user_id = u.id AND COALESCE(r.real_upload,1) != 0) AS last_run, "
            + ("(SELECT MAX(e.ts) FROM inbound_events e WHERE e.user_id = u.id) AS last_event "
               if has_events else "NULL AS last_event") +
            " FROM users u WHERE u.tester_no IS NOT NULL ORDER BY u.tester_no").fetchall()
        sends: dict[str, dict[str, datetime]] = {}
        if has_sends:
            for r in con.execute("SELECT user_id, template, MAX(ts) AS ts FROM ops_sends WHERE result NOT LIKE 'skipped%' GROUP BY user_id, template"):
                sends.setdefault(r["user_id"], {})[r["template"]] = common.parse(r["ts"])
        out = []
        for r in rows:
            acts = [common.parse(x) for x in (r["last_run"], r["last_event"], r["last_inbound_at"]) if x]
            out.append(Tester(
                n=r["tester_no"], channel=r["channel"], paused=bool(r["paused"]), ops_paused=bool(r["ops_paused"]),
                consent=r["checkin_consent"], enrolled=bool(r["enrolled"]),
                joined=common.parse(r["consent_at"] or r["created_at"]),
                first_run=common.parse(r["first_run"]) if r["first_run"] else None,
                last_activity=max(acts) if acts else None, sent=sends.get(r["id"], {})))
        return out
    finally:
        con.close()


def run(testers: list[Tester], now: datetime, link: str | None, apply: bool, send=None) -> list[tuple[Decision, str]]:
    """Decide for everyone; with apply, call `ops send` for each `send`. -> [(decision, outcome)]."""
    send = send or common.run_ops
    results: list[tuple[Decision, str]] = []
    for t in testers:
        for dec in decide(t, now, link):
            outcome = ""
            if dec.action == "send":
                if not apply:
                    outcome = "dry run: not sent"
                else:
                    args = ["send", "--tester", dec.tester, "--template", dec.template]
                    if dec.template == "N3":
                        args += ["--link", link]
                    code, text = send(args)
                    text = common.redact(text)
                    kind = "queued" if code == 0 else ("OPS UNREACHABLE" if common.unreachable(code, text) else "REFUSED")
                    outcome = f"{kind}: {text.splitlines()[0] if text else code}"
            results.append((dec, outcome))
    return results


def render(results: list[tuple[Decision, str]], now: datetime, apply: bool) -> str:
    lines = [f"# rs-concierge {now.strftime('%Y-%m-%d')} ({'APPLY' if apply else 'DRY RUN, nothing sent'})", ""]
    sends = [(d, o) for d, o in results if d.action in ("send", "wait")]
    flags = [(d, o) for d, o in results if d.action == "flag"]
    lines.append(f"Testers checked: {len({d.tester for d, _ in results})}. Nudges due: {sum(1 for d, _ in sends if d.action == 'send')}. "
                 f"Flagged: {len(flags)}.")
    lines.append("")
    lines.append("## Nudges")
    lines += [f"- {d.tester} {d.template}: {d.reason}" + (f" -> {o}" if o else "") if d.action == "send"
              else f"- {d.tester} {d.template}: WAITING, {d.reason}" for d, o in sends] or ["- none"]
    lines.append("")
    lines.append("## Stuck or flagged")
    lines += [f"- {d.tester}: {d.reason}" for d, _ in flags] or ["- none"]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apply", action="store_true", help="really call `ops send` (default: dry run, decisions only)")
    p.add_argument("--link", default=os.environ.get("RS_BOOKING_LINK"), help="booking link for N3")
    p.add_argument("--db", default=None)
    p.add_argument("--now", default=None, help="ISO time, for tests")
    p.add_argument("--no-log", action="store_true")
    a = p.parse_args(argv)
    now = common.parse(a.now) if a.now else common.utcnow()
    testers = load_testers(a.db or common.db_path())
    results = run(testers, now, a.link, a.apply)
    text = render(results, now, a.apply)
    print(text, end="")
    if not a.no_log:
        d = common.state_dir()
        d.mkdir(parents=True, exist_ok=True)
        (d / f"concierge-{now.strftime('%Y-%m-%d')}{'' if a.apply else '-dryrun'}.md").write_text(text)
    broken = [d.tester for d, o in results if o.startswith("OPS UNREACHABLE")]
    if broken:
        print(f"ops command could not run for {', '.join(broken)}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
