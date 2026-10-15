"""Nightly encrypted backup: SQLite online backup -> AES-256-GCM (authenticated) -> 14 day retention.

File format: b"RSB1" + 12-byte nonce + ciphertext||tag. The AES key is HKDF-SHA256 of the key file's contents,
so tampering or a wrong key fails loudly on restore instead of yielding garbage.

Key file: ~/.secrets/companion-backup.key (never printed).
Restore:  python -m companion.backup restore FILE.db.enc OUT.db
The plaintext snapshot lives only in memory; nothing unencrypted is written under the backup directory.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

RETENTION_DAYS = 14
MAGIC = b"RSB1"
# The runner's check-in answers are kept 14 days on the live database, so they must not outlive that in a backup that is
# itself kept 14 days (eng-review P1). They are emptied from the snapshot: a restore comes back without them.
PRIVATE_TABLES = ("checkin_answers", "checkin_slots", "question_cap")


def _key(key_file: str) -> bytes:
    with open(key_file, "rb") as f:
        material = f.read().strip()
    if len(material) < 16:
        raise ValueError("backup key file is too short")
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"companion-backup-v1").derive(material)


def _snapshot(db_path: str) -> bytes:
    src = sqlite3.connect(db_path)
    mem = sqlite3.connect(":memory:")
    try:
        src.backup(mem)
        for t in PRIVATE_TABLES:
            try:
                mem.execute(f"DELETE FROM {t}")
            except sqlite3.OperationalError:   # a database from before the check-ins has no such table
                pass
        # Heart rate is health data behind an off-by-default switch: turning it off deletes the live copy at once, so a
        # backup must not keep one for 14 days. The series is emptied from the snapshot's trail blocks (the rest stays).
        try:
            for run_id, user_id, raw in mem.execute("SELECT run_id, user_id, trail_json FROM run_shape WHERE trail_json LIKE '%\"hr\"%'").fetchall():
                d = json.loads(raw)
                d.pop("hr", None)
                d.pop("hr_z", None)
                mem.execute("UPDATE run_shape SET trail_json=? WHERE user_id=? AND run_id=?",
                            (json.dumps(d, separators=(",", ":")), user_id, run_id))
        except sqlite3.OperationalError:
            pass
        mem.commit()
        mem.execute("VACUUM")   # so the deleted rows are not left in free pages of the snapshot
        return mem.serialize()
    finally:
        mem.close()
        src.close()


def backup(db_path: str, out_dir: str, key_file: str, now: float | None = None) -> str:
    now = now or time.time()
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(out_dir, f"companion-{stamp}.db.enc")
    nonce = os.urandom(12)
    blob = MAGIC + nonce + AESGCM(_key(key_file)).encrypt(nonce, _snapshot(db_path), MAGIC)
    tmp = dest + ".part"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(blob)
    os.replace(tmp, dest)
    cutoff = datetime.fromtimestamp(now - RETENTION_DAYS * 86400, timezone.utc).strftime("%Y%m%d-%H%M%S")
    for name in os.listdir(out_dir):  # prune on the stamp in the name; mtime changes when files are copied
        if name.startswith("companion-") and name.endswith(".db.enc") and name[10:25] < cutoff:
            os.remove(os.path.join(out_dir, name))
    return dest


def restore(enc_path: str, out_path: str, key_file: str) -> None:
    with open(enc_path, "rb") as f:
        blob = f.read()
    if blob[:4] != MAGIC:
        raise ValueError("not a companion backup")
    try:
        plain = AESGCM(_key(key_file)).decrypt(blob[4:16], blob[16:], MAGIC)
    except InvalidTag:
        raise ValueError("wrong key or the backup was tampered with") from None
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(plain)


if __name__ == "__main__":
    home = os.path.expanduser("~")
    key = os.environ.get("COMPANION_BACKUP_KEY", f"{home}/.secrets/companion-backup.key")
    if len(sys.argv) == 4 and sys.argv[1] == "restore":
        restore(sys.argv[2], sys.argv[3], key)
        print("restored to", os.path.basename(sys.argv[3]))
    else:
        path = backup(os.environ.get("COMPANION_DB", f"{home}/companion-data/companion.db"),
                      os.environ.get("COMPANION_BACKUP_DIR", f"{home}/backups/companion"), key)
        print("backup written:", os.path.basename(path))
