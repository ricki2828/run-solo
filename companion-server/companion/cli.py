"""Operator commands: python -m companion.cli {status|pause|resume|ops|set-webhook|set-menu-button|set-consent|purge|replay|replay-stop|replay-abort}.
Never prints secrets."""
from __future__ import annotations

import argparse
import signal
import sys
from datetime import timedelta

import httpx

from . import db, logs, ops, replay
from .config import Settings
from .service import Service
from .timeutil import iso, now_utc, parse_iso


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
    ap.add_argument("--fresh", action="store_true",
                    help="first remove what an earlier replay created for this user (never real uploads), then start at item 1")
    a = ap.parse_args(argv)
    try:
        if a.dry_run:
            return replay.dry_run(s, a.facts_dir, a.every, a.from_date, a.full, a.fresh)
        with db.ro(s.db_path) as c:
            aware = c.execute("SELECT value FROM settings WHERE key='replay_aware_at'").fetchone()
        # the live worker refreshes this every tick; stale means it is not running this code (never restarted, or rolled back)
        if not aware or parse_iso(aware[0]) < now_utc() - timedelta(minutes=10):
            print("The live service is not running code that knows about replays (it would send this replay's "
                  "old items at once). Restart companion.service on this code first, then run this again.")
            return 3
        s = replay.replay_settings(s)
        runs = replay.load_facts(a.facts_dir)
        uid = replay.find_user(s)
        if a.fresh:
            plan = replay.fresh_apply(s, uid, runs)
            print("fresh start, removed: " + plan.summary())
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


def _replay_control(s: Settings, cmd: str) -> int:
    if cmd == "replay-stop":
        print(replay.stop(s))
        return 0
    code, msg = replay.abort(s) if cmd == "replay-abort" else replay.reset(s)
    print(msg)
    return code


def set_consent(s: Settings, svc: Service, who: str, version: str) -> int:
    """Record the consent version for one runner (user id or Telegram chat ref), exactly as the app's PUT does."""
    try:
        v = int(version)
    except ValueError:
        v = -1
    if not 0 <= v <= 1000:
        print("usage: set-consent <chat_ref|user_id> <version 0-1000>")
        return 2
    with db.ro(s.db_path) as c:
        rows = [r["id"] for r in c.execute("SELECT id FROM users WHERE id=? OR chat_ref=?", (who, who))]
    if len(set(rows)) != 1:
        print(f"set-consent: {'no' if not rows else 'more than one'} runner matches")
        return 1
    svc.set_checkin_consent(rows[0], v, source="cli")
    print(f"consent set: user={rows[0]} version={v}")
    return 0


def main(argv: list[str]) -> int:
    logs.setup()   # the operator commands log audit lines (set-consent); they must reach the journal, redacted
    s = Settings.from_env()
    cmd = argv[0] if argv else "status"
    if cmd == "replay":
        return _replay(s, argv[1:])
    if cmd == "ops":   # the tester programme: roster by T-number, pause one runner, spend and enrolment status
        db.init(s.db_path)
        return ops.main(s, argv[1:])
    svc = Service(s, httpx.Client(timeout=10))
    if cmd in ("replay-stop", "replay-abort", "replay-reset"):
        return _replay_control(s, cmd)
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
    elif cmd == "set-consent":
        if len(argv) != 3:
            print("usage: set-consent <chat_ref|user_id> <version>")
            return 2
        return set_consent(s, svc, argv[1], argv[2])
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
    elif cmd == "set-menu-button":  # the bot's default menu button opens the Mini App (needs COMPANION_MINIAPP=1)
        if not (s.telegram_enabled and s.miniapp_enabled):
            print("telegram or COMPANION_MINIAPP not configured")
            return 1
        r = svc.http.post(f"{s.telegram_api}/bot{s.telegram_token}/setChatMenuButton", json={
            "menu_button": {"type": "web_app", "text": "My week", "web_app": {"url": s.miniapp_url}}})
        print("setChatMenuButton:", r.status_code, r.json().get("description", ""))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
