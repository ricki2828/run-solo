"""Shared bits for the tester-programme host jobs (concierge, digest). Standard library only.

These run from the host crontab, outside the companion's sandbox. They read the companion database read-only, and they
reach the coach only through its CLI (`ops ...`), so every rail in the coach (consent, quiet hours, pauses, template
approval) stays where it is. Testers are T-numbers everywhere here: no name, chat id or user id is read or printed.
"""
from __future__ import annotations

import os
import re
import shlex
import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
DEFAULT_DB = HOME / "companion-data/companion.db"
DEFAULT_STATE = HOME / "ai/state/run-supreme-testers"
# the CLI with the service's env files, as in DEPLOY.md section 7b ("OPS"): override with RS_OPS_CMD
DEFAULT_OPS = ("systemd-run --user --wait --pipe -p EnvironmentFile=%(h)s/.secrets/run-supreme-companion.env "
               "-p EnvironmentFile=%(h)s/.secrets/run-supreme-companion-internal.env "
               "-p WorkingDirectory=%(h)s/services/run-supreme-companion "
               "%(h)s/services/run-supreme-companion/.venv/bin/python -m companion.cli") % {"h": str(HOME)}


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc)


def state_dir() -> Path:
    return Path(os.environ.get("RS_STATE_DIR") or DEFAULT_STATE).expanduser()


def db_path() -> str:
    return str(Path(os.environ.get("COMPANION_DB") or DEFAULT_DB).expanduser())


def open_ro(path: str) -> sqlite3.Connection:
    con = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=15)
    con.row_factory = sqlite3.Row
    return con


def has_table(con: sqlite3.Connection, name: str) -> bool:
    return con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def ops_argv() -> list[str]:
    return shlex.split(os.environ.get("RS_OPS_CMD") or DEFAULT_OPS) + ["ops"]


_SECRET = re.compile(r"(bot\d+:[\w-]+|\b\d{6,}:[A-Za-z0-9_-]{20,}|(?i:token|secret|password|api[_-]?key)\S*[=: ]+\S+)")


def redact(text: str) -> str:
    """Strip anything that looks like a bot token or credential before text is printed, logged or filed."""
    return _SECRET.sub("[redacted]", text or "")


def ops_env() -> dict[str, str]:
    """cron has no user bus: `systemd-run --user` needs these two."""
    env = dict(os.environ)
    uid = os.getuid()
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path=/run/user/{uid}/bus")
    return env


def unreachable(code: int, text: str) -> bool:
    """True when the ops command itself did not run (as opposed to `ops send` legitimately refusing: exit 1 or 2 with a message)."""
    return code >= 3 or not (text or "").strip() or "Failed to connect" in (text or "") or "Traceback" in (text or "")


def run_ops(args: list[str], timeout: int = 120) -> tuple[int, str]:
    """Run `companion.cli ops <args>`. -> (exit code, combined output). Never raises on a failing command."""
    try:
        r = subprocess.run(ops_argv() + args, capture_output=True, text=True, timeout=timeout, env=ops_env())
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, f"could not run the ops command: {type(e).__name__}"
    text = ((r.stdout or "") + (r.stderr or "")).strip()
    # a success carries data (feedback is the runner's own words: leave it alone); only a failure's output is an error message
    return r.returncode, text if r.returncode == 0 else redact(text)
