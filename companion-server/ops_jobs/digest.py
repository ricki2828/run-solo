#!/usr/bin/env python3
"""rs-digest: Monday's one-page readout for Ricki, and a 6-line summary to his own Telegram topic.

    python3 ops_jobs/digest.py [--dry-run] [--no-narrative] [--week YYYY-WW] [--repo OWNER/NAME]

Gathers (all through the coach's CLI, read-only except the snapshot file): the scorecard snapshot, the ops-send log, the
feedback inbox, LLM cost, STOP/DELETE counts and open P0/P1 issues. Writes digest-YYYY-WW.md in the state dir. A `claude -p`
pass (Max login, API keys stripped) writes the narrative.

Rules this file keeps:
- Feedback text is the runner's own words. It is read by this code and Ricki only: it goes into the private digest file under
  "Feedback inbox" and nowhere else. It is NEVER given to the model and never put in the Telegram summary.
- The Telegram summary is built by code from numbers, goes to one place (Ricki's topic), and is sent only without --dry-run.
- No GitHub issues are created here. Candidates are listed for Ricki; issues must be paraphrased, never quoted (public repo).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from ops_jobs import common  # noqa: E402

REPO = "ricki2828/run-solo"
TG_CHAT, TG_THREAD = "-1003885786157", "4"
TG_TOOL = Path.home() / "telegram-assistant/tools/send_telegram_text.py"
ASSISTANT_ENV = Path.home() / "ai/scripts/assistant_env.sh"
FEEDBACK_DAYS = 7


def week_label(now: datetime) -> str:
    y, w, _ = now.isocalendar()
    return f"{y}-{w:02d}"


# ------------------------------------------------------------------ gather
def gather_snapshot(run_ops=common.run_ops) -> tuple[dict | None, str]:
    code, out = run_ops(["scorecard-snapshot"])
    path = out.splitlines()[-1].strip() if out else ""
    if code != 0 or not path.endswith(".json"):
        return None, f"scorecard snapshot failed (exit {code}): {out[:200]}"
    try:
        return json.loads(Path(path).read_text()), path
    except (OSError, ValueError) as e:
        return None, f"could not read the snapshot {path}: {type(e).__name__}"


def gather_sends(run_ops=common.run_ops, now: datetime | None = None) -> list[str]:
    code, out = run_ops(["sends"])
    if code != 0:
        return [f"ops sends failed (exit {code})"]
    cut = common.iso((now or common.utcnow()) - timedelta(days=7))
    lines = [ln for ln in out.splitlines() if ln[:20] >= cut]
    return lines or ["no ops sends in the last 7 days"]


def gather_feedback(run_ops=common.run_ops) -> list[str]:
    code, out = run_ops(["feedback", str(FEEDBACK_DAYS)])
    if code != 0:
        return [f"ops feedback failed (exit {code})"]
    return [ln for ln in out.splitlines() if ln.strip()]


def feedback_count(lines: list[str]) -> dict[str, int]:
    """Per T-number counts from `ops feedback` lines (`T3 2026-10-16T08:01:02Z text`). Counts only: no text leaves this."""
    out: dict[str, int] = {}
    for ln in lines:
        m = re.match(r"^(T\d+) \d{4}-\d\d-\d\dT", ln)
        if m:
            out[m.group(1)] = out.get(m.group(1), 0) + 1
    return out


def gather_status(run_ops=common.run_ops) -> list[str]:
    code, out = run_ops(["status"])
    return out.splitlines() if code == 0 else [f"ops status failed (exit {code})"]


def gather_issues(repo: str = REPO, runner=subprocess.run) -> tuple[list[str], str | None]:
    """Open issues labelled P0 or P1. -> (lines, error). A failure is reported, never read as 'none open'."""
    found: dict[int, str] = {}
    for label in ("P0", "P1"):
        try:
            r = runner(["gh", "issue", "list", "--repo", repo, "--label", label, "--state", "open", "--json", "number,title",
                        "--limit", "50"], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            return [], f"gh failed: {type(e).__name__}"
        if r.returncode != 0:
            return [], f"gh exited {r.returncode}: {(r.stderr or '').strip()[:150]}"
        try:
            for i in json.loads(r.stdout or "[]"):
                found[i["number"]] = f"#{i['number']} [{label}] {i['title']}"
        except (ValueError, KeyError, TypeError):
            return [], "gh returned something unreadable"
    return [found[k] for k in sorted(found)], None


# ------------------------------------------------------------------ numbers
def gate_by_name(sc: dict | None) -> dict[str, dict]:
    return {g["signal"]: g for g in (sc or {}).get("gate", [])}


def frac(g: dict | None) -> str:
    if not g:
        return "n/a"
    n = g["n"]
    n = "-" if n is None else (f"{n:g}" if isinstance(n, float) else str(n))
    return f"{n}/{g['N']}" + (f" ({g['pct']:g}%)" if g.get("pct") is not None else " (too few for a %)")


def summary_lines(sc: dict | None, sends: list[str], fb: dict[str, int], issues: list[str], issues_err: str | None,
                  week: str, path: str) -> list[str]:
    """The 6-line Telegram summary. Built from numbers only: no feedback text, no tester words, no model output."""
    g = gate_by_name(sc)
    find = lambda prefix: next((v for k, v in g.items() if k.startswith(prefix)), None)  # noqa: E731
    active, w4, trust = find("Coach-enrolled"), find("Return"), find("Trust: recap")
    ellis, cost, optout = find("Sean Ellis"), find("Guard: cost"), find("Guard: opt-outs")
    sent = sum(1 for s in sends if re.match(r"^\d{4}-", s))
    return [
        f"Run Supreme testers, week {week}",
        f"Active {frac(active)}. Week 4 engaged {frac(w4)}. Trust {frac(trust)}.",
        f"Sean Ellis {frac(ellis)}. Cost guard {frac(cost)}.",
        f"Opt-outs: {optout['deleted_total']} deleted, {optout['stopped_total']} stopped." if optout else "Opt-outs: n/a",
        f"Nudges sent {sent}. Feedback from {len(fb)} testers ({sum(fb.values())} messages). "
        + ("Open P0/P1: " + (str(len(issues)) if issues_err is None else "unknown, gh failed")),
        f"Full digest: {path}",
    ]


# ------------------------------------------------------------------ narrative (claude -p)
def narrative_input(sc: dict | None, prev: dict | None, sends: list[str], fb: dict[str, int], issues: list[str],
                    status: list[str]) -> str:
    """Everything the model sees. Structured numbers and issue titles only: NEVER a tester's words (plan §3 guardrail 3)."""
    return json.dumps({
        "gate": (sc or {}).get("gate"), "surveys": (sc or {}).get("surveys"), "optouts": (sc or {}).get("optouts"),
        "week4": (sc or {}).get("week4"), "week_starts": (sc or {}).get("week_starts"),
        "previous_week_gate": (prev or {}).get("gate"),
        "testers": [{"id": t["id"], "active_weeks": t["active_weeks"], "week4_retained": t["week4_retained"],
                     "replies_by_week": [w["replies"] for w in t["weeks"]]} for t in (sc or {}).get("testers", [])],
        "ops_sends_last_7d": len([s for s in sends if re.match(r"^\d{4}-", s)]),
        "feedback_messages_by_tester_last_7d": fb,       # counts only
        "open_p0_p1_issues": issues, "coach_status": status,
    }, indent=1)


PROMPT = """You write the Monday readout for Ricki, who runs a small closed test of a running-coach app (Run Supreme). Below is
this week's numbers as JSON. Write ONE page, at most 170 words, plain and direct, like a sharp chief of staff.

Start with the single most important thing the numbers say about whether the coach is working and what changed since last
week. Then at most two things that need his decision this week, each with one action. Finish with one line on what you are
watching. Do not list metrics one after another, do not restate the table, no headings, no bullets, no em-dashes. Say plainly
when there are too few answers to tell (the gate shows n/N and a percentage only from 8 answers). Tester numbers like T3 are
fine. Never guess at what a tester said: you have no access to their words.

JSON:
"""


def claude_narrative(data: str, runner=subprocess.run) -> tuple[str | None, str]:
    """-> (text or None, note). Max login: the API key is stripped by assistant_env. The prompt goes in on stdin."""
    script = f'source "{ASSISTANT_ENV}" && strip_claude_env && cd "$(mktemp -d)" && exec claude -p --model sonnet'
    try:
        r = runner(["bash", "-c", script], input=PROMPT + data, capture_output=True, text=True, timeout=240)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"claude -p failed: {type(e).__name__}"
    text = (r.stdout or "").strip()
    if r.returncode != 0 or len(text) < 40:
        return None, f"claude -p returned exit {r.returncode} and {len(text)} characters"
    return text.replace("—", ",").replace("–", "-"), "claude -p (Max login)"


# ------------------------------------------------------------------ write
def build(week: str, now: datetime, sc: dict | None, snap_note: str, sends: list[str], feedback: list[str],
          fb: dict[str, int], issues: list[str], issues_err: str | None, status: list[str],
          narrative: str | None, narrative_note: str) -> str:
    g = sc.get("gate", []) if sc else []
    out = [f"# Run Supreme testers, week {week}", f"Generated {common.iso(now)}. Private: this file holds testers' own words.", ""]
    out += ["## What it says", narrative or f"(No narrative: {narrative_note}. Read the gate below.)", ""]
    out += ["## Gate (n/N; a percentage only from 8 answers)"]
    for r in g:
        out.append(f"- {r['signal']}: {frac(r)} against {r['threshold']}"
                   + {True: ". MET", False: ". NOT MET", None: ""}[r.get("met")] + (f" ({r['note']})" if r.get("note") else ""))
    if not g:
        out.append(f"- no scorecard: {snap_note}")
    out += ["", "## Nudges sent by ops (last 7 days)"] + [f"- {s}" for s in sends]
    out += ["", "## Cost and opt-outs"]
    if sc:
        out.append(f"- LLM cost USD per week (all calls): {sc.get('llm_cost_usd_total')}")
        o = sc.get("optouts", {})
        out.append(f"- Deleted by week: {o.get('deleted')}. Stopped by week: {o.get('stopped')}.")
    out += [f"- {s}" for s in status]
    out += ["", "## Open P0/P1 issues"] + ([f"- {i}" for i in issues] or [f"- none open" if issues_err is None else f"- UNKNOWN: {issues_err}"])
    out += ["", "## Triage candidates (nothing is filed from here)",
            "A GitHub issue must be paraphrased, never a quote: the repo is public. Ricki decides which to file."]
    cands = [f"- {t}: {n} feedback message(s) this week: read below, then paraphrase into an issue if it is a bug" for t, n in sorted(fb.items())]
    cands += [f"- {r['signal']}: {r['n']} \"Not really\" answer(s): review each" for r in g if r["signal"].startswith("Trust: misreads") and r["n"]]
    out += cands or ["- none"]
    out += ["", "## Feedback inbox (private: the testers' own words, last 7 days)"] + (feedback or ["none"])
    out += ["", "## Notes", f"- Scorecard: {snap_note}", f"- Narrative: {narrative_note}", ""]
    return "\n".join(out)


def send_telegram(text: str, runner=subprocess.run) -> tuple[bool, str]:
    """To Ricki's own topic only. The bot token comes from RS_TELEGRAM_ENV_FILE (a file that sets TELEGRAM_BOT_TOKEN), if set."""
    env = dict(os.environ, TELEGRAM_CHAT_ID=TG_CHAT, TELEGRAM_THREAD_ID=TG_THREAD)
    script = 'set -a; [ -n "$RS_TELEGRAM_ENV_FILE" ] && . "$RS_TELEGRAM_ENV_FILE"; set +a; ' \
             'TELEGRAM_CHAT_ID=%s TELEGRAM_THREAD_ID=%s exec python3 "$1" --text "$2"' % (TG_CHAT, TG_THREAD)
    try:
        r = runner(["bash", "-c", script, "_", str(TG_TOOL), text], capture_output=True, text=True, timeout=60, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"telegram send failed: {type(e).__name__}"
    return r.returncode == 0, (r.stderr or r.stdout or "").strip()[:200]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dry-run", action="store_true", help="write the digest file, print the summary, send nothing")
    p.add_argument("--no-narrative", action="store_true", help="skip the claude -p pass")
    p.add_argument("--week", default=None)
    p.add_argument("--repo", default=REPO)
    a = p.parse_args(argv)
    now = common.utcnow()
    week = a.week or week_label(now)
    sc, snap_note = gather_snapshot()
    prev = None
    if sc:
        y, w = int(week[:4]), int(week[5:])
        pw = (datetime.fromisocalendar(y, w, 1) - timedelta(days=7)).isocalendar()
        try:
            prev = json.loads((common.state_dir() / f"scorecard-{pw[0]}-{pw[1]:02d}.json").read_text())
        except (OSError, ValueError):
            prev = None
    sends, feedback, status = gather_sends(), gather_feedback(), gather_status()
    fb = feedback_count(feedback)
    issues, issues_err = gather_issues(a.repo)
    narrative, note = (None, "skipped (--no-narrative)") if a.no_narrative else (
        claude_narrative(narrative_input(sc, prev, sends, fb, issues, status)) if sc else (None, "no scorecard to write about"))
    d = common.state_dir()
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"digest-{week}.md"
    path.write_text(build(week, now, sc, snap_note, sends, feedback, fb, issues, issues_err, status, narrative, note))
    summary = "\n".join(summary_lines(sc, sends, fb, issues, issues_err, week, str(path)))
    if a.dry_run:
        print(f"DRY RUN: digest written to {path}; nothing sent. The Telegram summary would be:\n{summary}")
        return 0
    ok, msg = send_telegram(summary)
    print(summary)
    if not ok:
        print(f"TELEGRAM SEND FAILED: {msg}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
