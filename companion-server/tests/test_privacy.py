"""Deletion (B5), logs (B5), config boundaries (B4), retention, backup."""
import json
import logging
import os
import re
import shutil
import sqlite3
import stat
import subprocess
from datetime import timedelta

import pytest

from companion import db
from companion.backup import backup
from companion.config import Settings
from companion.logs import redact
from companion.timeutil import iso, now_utc
from conftest import OWNER, TG_TOKEN, auth, enrol, post_tg, run_payload, tg_callback, tg_update

E164 = re.compile(r"\+?\d{9,15}")


def populate(client, fakes):
    """Touch every table that can hold user data."""
    t = enrol(client)
    client.post("/v1/runs", json=run_payload("r0", minutes_ago=30), headers=auth(t))   # easy: gets the weekly question
    client.post("/v1/runs", json=run_payload("r1", type="tempo"), headers=auth(t))    # hard: gets a suggestion
    client.svc.run_outbox(now_utc() + timedelta(seconds=1))
    c = sqlite3.connect(client.svc.s.db_path)
    for n, (card_id, buttons) in enumerate(c.execute("SELECT card_id, buttons_json FROM cards").fetchall()):
        for i, b in enumerate(json.loads(buttons)):
            if b["action"] in ("ans:goal_type:10k", "sugg:yes:recover", "feel:easy"):
                post_tg(client, tg_callback(8000 + n * 20 + i, f"{card_id}:{i}"))
    post_tg(client, tg_update(8100, "STOP"))
    return t


def test_delete_leaves_zero_rows_in_every_table_with_user_data(client, fakes):
    t = populate(client, fakes)
    path = client.svc.s.db_path
    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    uid = c.execute("SELECT id FROM users").fetchone()["id"]
    tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    # every table must be either user-keyed or explicitly declared free of user data
    user_tables = []
    for name in tables:
        cols = [r[1] for r in c.execute(f"PRAGMA table_info({name})")]
        if "user_id" in cols or name == "users":
            user_tables.append(name)
        else:
            assert name in db.NO_USER_TABLES, f"new table {name} has no user_id and is not declared user-free"
    populated = {n for n in user_tables if c.execute(
        f"SELECT COUNT(*) FROM {n} WHERE " + ("id" if n == "users" else "user_id") + "=?", (uid,)).fetchone()[0]}
    assert {"users", "devices", "runs", "memory", "cards", "outbox", "quota", "outcomes", "msglog", "inbound_seen", "enrolments"} <= populated, populated

    assert client.delete("/v1/me", headers=auth(t)).json() == {"status": "deleted"}

    c = sqlite3.connect(path)
    for n in user_tables:
        col = "id" if n == "users" else "user_id"
        assert c.execute(f"SELECT COUNT(*) FROM {n} WHERE {col}=?", (uid,)).fetchone()[0] == 0, n
    assert client.get("/v1/me", headers=auth(t)).status_code == 401
    # the chat id is gone from the file entirely, including free pages and the WAL
    raw = b"".join(open(p, "rb").read() for p in (path, path + "-wal") if os.path.exists(p))
    assert OWNER.encode() not in raw


def test_delete_only_touches_that_user(tmp_path, fakes):
    import httpx
    from fastapi.testclient import TestClient
    from companion.app import create_app
    from conftest import make_settings
    s = make_settings(tmp_path, allowed_ids=frozenset({f"telegram:{OWNER}", "telegram:444555666"}))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        a, b = enrol(c), enrol(c, ref="444555666")
        for tok in (a, b):
            c.post("/v1/runs", json=run_payload(), headers=auth(tok))
        c.delete("/v1/me", headers=auth(a))
        assert c.get("/v1/me", headers=auth(b)).json()["runs_received"][0]["run_id"] == "r1"


def test_export_shows_what_is_held_and_hides_the_chat_id(client, fakes):
    t = populate(client, fakes)
    me = client.get("/v1/me", headers=auth(t)).json()
    assert {"profile", "runs_received", "memory", "messages_sent_30d", "goes_to", "suggestion_outcomes"} <= set(me)
    assert me["memory"].get("goal_type") == "10k" and me["profile"]["paused"] is True
    assert OWNER not in json.dumps(me) and me["profile"]["chat_ref_hint"].endswith(OWNER[-3:])
    assert me["messages_sent_30d"] and any("OpenRouter" in g for g in me["goes_to"])


def test_secure_delete_and_file_modes(client):
    path = client.svc.s.db_path
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode) == 0o700
    with db.ro(path) as c:
        assert c.execute("PRAGMA secure_delete").fetchone()[0] == 1


def test_logs_never_contain_numbers_or_tokens(client, fakes, caplog):
    caplog.set_level(logging.DEBUG)
    t = populate(client, fakes)
    client.delete("/v1/me", headers=auth(t))
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert text and not E164.search(text), E164.search(text)
    assert t not in text and TG_TOKEN not in text and "AAFAKE" not in text
    assert "or-test-key" not in text


def test_httpx_request_log_with_bot_token_is_not_emitted(client):
    assert logging.getLogger("httpx").level >= logging.WARNING  # httpx logs full URLs; Telegram URLs hold the bot token


def test_redact_patterns():
    assert E164.search(redact("call +61400111222 now")) is None
    assert "[number]" in redact("chat 123456789 sent")
    assert TG_TOKEN not in redact(f"POST https://api.telegram.org/bot{TG_TOKEN}/sendMessage")
    assert "x" * 40 not in redact("token " + "x" * 40)
    assert redact("run 7.0 km in 40 min") == "run 7.0 km in 40 min"


def test_shared_openrouter_key_needs_explicit_opt_in():
    base = {"COMPANION_PEPPER": "p" * 20, "OPENROUTER_API_KEY": "shared-key"}
    assert Settings.from_env(base).openrouter_key is None
    assert Settings.from_env({**base, "COMPANION_ALLOW_SHARED_KEY": "1"}).openrouter_key == "shared-key"
    own = {**base, "COMPANION_ALLOW_SHARED_KEY": "1", "COMPANION_OPENROUTER_KEY": "own-key"}
    assert Settings.from_env(own).openrouter_key == "own-key"
    assert "own-key" not in repr(Settings.from_env(own))
    with pytest.raises(RuntimeError):
        Settings.from_env({})


def test_inactive_users_are_deleted_after_six_months(client):
    enrol(client)
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("UPDATE users SET created_at=?", (iso(now_utc() - timedelta(days=200)),))
    c.commit()
    client.svc.purge()
    assert sqlite3.connect(client.svc.s.db_path).execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0


def test_message_log_and_niggle_expire(client):
    t = enrol(client)
    c = sqlite3.connect(client.svc.s.db_path)
    uid = c.execute("SELECT id FROM users").fetchone()[0]
    old = iso(now_utc() - timedelta(days=60))
    c.execute("INSERT INTO msglog (user_id, ts, direction, kind) VALUES (?,?,?,?)", (uid, old, "out", "run"))
    c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", (uid, "niggle_area", "calf", old))
    c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", (uid, "goal_type", "10k", old))
    c.commit()
    assert "niggle_area" not in client.get("/v1/me", headers=auth(t)).json()["memory"]  # expired even before purge
    client.svc.purge()
    c = sqlite3.connect(client.svc.s.db_path)
    assert c.execute("SELECT COUNT(*) FROM msglog").fetchone()[0] == 0
    assert c.execute("SELECT key FROM memory").fetchall() == [("goal_type",)]


@pytest.mark.skipif(not shutil.which("openssl"), reason="openssl missing")
def test_backup_is_encrypted_restorable_and_pruned(client, tmp_path):
    enrol(client)
    key = tmp_path / "k.key"
    key.write_text("backup-key-for-test")
    out_dir = tmp_path / "bk"
    old = backup(client.svc.s.db_path, str(out_dir), str(key), now=now_utc().timestamp() - 20 * 86400)
    new = backup(client.svc.s.db_path, str(out_dir), str(key))
    assert not os.path.exists(old) and os.path.exists(new)  # 14 day retention
    assert b"SQLite format" not in open(new, "rb").read()
    restored = tmp_path / "restored.db"
    subprocess.run(["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-in", new, "-out", str(restored),
                    "-pass", f"file:{key}"], check=True)
    assert sqlite3.connect(restored).execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
    assert stat.S_IMODE(os.stat(new).st_mode) == 0o600
