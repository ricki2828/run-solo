"""Operator commands: python -m companion.cli {status|pause|resume|set-webhook|purge}. Never prints secrets."""
from __future__ import annotations

import sys

import httpx

from . import db
from .config import Settings
from .service import Service


def main(argv: list[str]) -> int:
    s = Settings.from_env()
    cmd = argv[0] if argv else "status"
    svc = Service(s, httpx.Client(timeout=10))
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
              f"llm={'key set' if s.openrouter_key else 'no key (templates only)'} spend_month_usd={svc.writer.month_spend():.4f}")
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
