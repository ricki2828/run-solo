#!/bin/bash
# Sends the coach's queued alerts (spend at 50/80/100% of the cap, a runner paused for flooding) to Ricki through notify.
# Host cron, every 5 minutes. The companion service cannot reach notify (its sandbox hides $HOME), so it only queues rows
# in the `alerts` table; this reads them and marks each sent only after notify succeeded. Prints nothing when idle.
set -uo pipefail
DB="${COMPANION_DB:-$HOME/companion-data/companion.db}"
[ -f "$DB" ] || exit 0
python3 - "$DB" <<'PY'
import sqlite3, subprocess, sys
from datetime import datetime, timezone
con = sqlite3.connect(sys.argv[1], timeout=15)
rows = con.execute("SELECT id, title, body FROM alerts WHERE sent_at IS NULL ORDER BY id").fetchall()
for aid, title, body in rows:
    r = subprocess.run([f"{__import__('os').path.expanduser('~')}/ai/scripts/notify", "send", "--sender", "run-supreme-companion",
                        "--title", title, "--text", body], capture_output=True, timeout=60)
    if r.returncode != 0:
        print(f"alert {aid}: notify failed ({r.returncode}); will retry", file=sys.stderr)
        break
    con.execute("UPDATE alerts SET sent_at=? WHERE id=? AND sent_at IS NULL",
                (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), aid))
    con.commit()
PY
