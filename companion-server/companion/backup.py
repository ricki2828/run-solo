"""Nightly encrypted backup: SQLite online backup -> openssl AES-256 (pbkdf2) -> 14 day retention.

Key file: ~/.secrets/companion-backup.key (read by openssl via -pass file:, never printed).
Restore: openssl enc -d -aes-256-cbc -pbkdf2 -in X.db.enc -out restored.db -pass file:<key>
"""
from __future__ import annotations

import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

RETENTION_DAYS = 14


def backup(db_path: str, out_dir: str, key_file: str, now: float | None = None) -> str:
    now = now or time.time()
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(out_dir, f"companion-{stamp}.db.enc")
    with tempfile.TemporaryDirectory(dir=out_dir) as tmp:
        plain = os.path.join(tmp, "snap.db")
        src = sqlite3.connect(db_path)
        dst = sqlite3.connect(plain)
        try:
            src.backup(dst)
        finally:
            dst.close()
            src.close()
        subprocess.run(["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-salt", "-in", plain, "-out", dest,
                        "-pass", f"file:{key_file}"], check=True)
        os.chmod(dest, 0o600)
    cutoff = datetime.fromtimestamp(now - RETENTION_DAYS * 86400, timezone.utc).strftime("%Y%m%d-%H%M%S")
    for name in os.listdir(out_dir):  # prune on the stamp in the name; mtime changes when files are copied
        if name.startswith("companion-") and name.endswith(".db.enc") and name[10:25] < cutoff:
            os.remove(os.path.join(out_dir, name))
    return dest


if __name__ == "__main__":
    home = os.path.expanduser("~")
    path = backup(os.environ.get("COMPANION_DB", f"{home}/companion-data/companion.db"),
                  os.environ.get("COMPANION_BACKUP_DIR", f"{home}/backups/companion"),
                  os.environ.get("COMPANION_BACKUP_KEY", f"{home}/.secrets/companion-backup.key"))
    print("backup written:", os.path.basename(path))
    sys.exit(0)
