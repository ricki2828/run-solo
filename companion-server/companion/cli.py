"""Operator commands: python -m companion.cli {status|pause|resume|set-webhook|purge|replay|replay-stop|replay-abort}.
Never prints secrets."""
from __future__ import annotations

import argparse
import signal
import sys
from datetime import timedelta

import httpx

from . import db, replay
from .config import Settings
from .service import Service
from .timeutil import iso, now_utc


def _replay_status(s: Settings) -> str:
    with db.ro(s.db_path) as c:
        r = c.execute("SELECT * FROM replay_state").fetchone()
    if not r:
        return "replay=none"
    return (f"replay={r['status']} virtual_clock={r['vnow']} items_sent={r['items']} every_s={r['every_s']} "
            f"folder={r['facts_dir']}")


def _replay(s: Settings, argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="companion.cli replay")
    ap.add_argument("facts_dir")
    ap.add_argument("--every", type=int, default=300, help="wall seconds between messages (default 300)")
    ap.add_argument("--dry-run", action="store_true", help="print the whole schedule, send and change nothing")
    ap.add_argument("--from", dest="from_date", help="YYYY-MM-DD: earlier runs are context only, no cards")
    ap.add_argument("--full", action="store_true", help="with --dry-run: print every message in full")
    a = ap.parse_args(argv)
    try:
        if a.dry_run:
            return replay.dry_run(s, a.facts_dir, a.every, a.from_date, a.full)
        with db.ro(s.db_path) as c:
            aware = c.execute("SELECT value FROM settings WHERE key='replay_aware_at'").fetchone()
        if not aware:
            print("The live service has not restarted on code that knows about replays yet (it would send this "
                  "replay's old items at once). Restart companion.service first, then run this again.")
            return 3
        s = replay.replay_settings(s)
        runs = replay.load_facts(a.facts_dir)
        uid = replay.find_user(s)
        svc = Service(s, httpx.Client(timeout=10))
        r = replay.Replayer(svc, uid, runs, a.every, facts_dir=a.facts_dir,
                            from_dt=replay.from_datetime(a.from_date, runs[0].zone_id))
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: r.request_stop())  # finish the current item, save, exit
        print(f"replaying {len(runs)} runs for one user, one message every {a.every} s. Ctrl-C or replay-stop to pause.")
        outcome = r.run()
        print(f"replay {outcome}: {len(r.items)} messages sent in this process")
        return 0
    except replay.ReplayError as e:
        print(f"replay: {e}")
        return 2


def _replay_halt(s: Settings, abort: bool) -> int:
    with db.tx(s.db_path) as c:
        r = c.execute("SELECT user_id, status, heartbeat_at FROM replay_state").fetchone()
        if not r:
            print("no replay")
            return 1
        if abort:
            # release the user to the live worker; anything the replay still had queued from its past is dropped
            c.execute("UPDATE outbox SET state='skipped' WHERE user_id=? AND state IN ('pending','sending') AND due_at < ?",
                      (r["user_id"], iso(now_utc())))
            c.execute("UPDATE replay_state SET status='done', updated_at=?", (iso(now_utc()),))
            print("replay aborted; the live coach has the user back")
            return 0
        alive = bool(r["heartbeat_at"]) and r["heartbeat_at"] > iso(now_utc() - timedelta(seconds=replay.HEARTBEAT_FRESH_S))
        new = "stopping" if r["status"] == "running" and alive else "stopped"
        c.execute("UPDATE replay_state SET status=? WHERE status IN ('running','stopping','stopped')", (new,))
    print("stopping after the current message" if new == "stopping" else "replay stopped (resume with the same replay command)")
    return 0


def main(argv: list[str]) -> int:
    s = Settings.from_env()
    cmd = argv[0] if argv else "status"
    if cmd == "replay":
        return _replay(s, argv[1:])
    svc = Service(s, httpx.Client(timeout=10))
    if cmd in ("replay-stop", "replay-abort"):
        return _replay_halt(s, abort=cmd == "replay-abort")
    if cmd in ("pause", "resume"):
        with db.tx(s.db_path) as c:
            c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('sends_paused', ?)",
                      ("1" if cmd == "pause" else "0",))
        print(f"sends {cmd}d")
    elif cmd == "status":
        with db.ro(s.db_path) as c:
            n = c.execute("SELECT COUNT(*) FROM users").fetchone()[0]
            p = c.execute("SELECT value FROM settings WHERE key='sends_paused'").fetchone()
        print(f"users={n} overdue_outbox={svc.overdue_count()} kill_switch={'on' if (p and p[0]=='1') or s.sends_paused else 'off'} "
              f"llm={'key set' if s.openrouter_key else 'no key (templates only)'} spend_month_usd={svc.writer.month_spend():.4f} "
              f"{_replay_status(s)}")
    elif cmd == "purge":
        svc.purge()
        print("purged")
    elif cmd == "set-webhook":
        if not s.telegram_enabled:
            print("telegram not configured")
            return 1
        base = argv[1] if len(argv) > 1 else None
        if not base:
            print("usage: set-webhook https://companion.taiaroa.xyz")
            return 2
        r = svc.http.post(f"{s.telegram_api}/bot{s.telegram_token}/setWebhook", json={
            "url": f"{base.rstrip('/')}/hooks/telegram", "secret_token": s.telegram_webhook_secret,
            "allowed_updates": ["message", "callback_query"], "drop_pending_updates": True})
        print("setWebhook:", r.status_code, r.json().get("description", ""))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
