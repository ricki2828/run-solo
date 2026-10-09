import hashlib
import json
import re
import sqlite3
from datetime import timedelta

from fastapi.routing import APIRoute

from companion.timeutil import now_utc
from conftest import OWNER, auth, chat_code, confirm, enrol, post_tg, run_payload, start, status, tg_update


def test_start_returns_nonce_poll_secret_and_deep_links(client):
    r = client.post("/v1/enrol/start").json()
    assert re.fullmatch(r"[A-Za-z0-9_-]{16,}", r["nonce"]) and len(r["poll_secret"]) >= 24
    assert r["poll_secret"] not in json.dumps(r["links"]) and r["poll_secret"] != r["nonce"]
    assert r["links"]["telegram"] == f"https://t.me/RSBot?start={r['nonce']}"
    assert r["links"]["whatsapp"] == f"https://wa.me/61400000000?text=START%20{r['nonce']}"
    assert status(client, r) == {"state": "pending"}
    assert client.get("/v1/enrol/status", params={"nonce": r["nonce"]}).status_code in (404, 405)  # no query-string polling


def test_phishing_nonce_alone_gets_nothing(client, fakes):
    """An attacker starts enrolment and sends the t.me link to a victim; the victim taps Start."""
    st = start(client)
    post_tg(client, tg_update(1, f"/start {st['nonce']}"))
    code = chat_code(client, st["nonce"])
    assert code in fakes.tg_texts()[-1] and "never share" in fakes.tg_texts()[-1]   # the victim sees the code, not the attacker
    # the attacker has the nonce but not the poll secret
    guess = {"nonce": st["nonce"], "poll_secret": "x" * 24}
    assert client.post("/v1/enrol/status", json=guess).json() == {"state": "unknown"}
    assert client.post("/v1/enrol/confirm", json={**guess, "code": code}).status_code == 410
    # and does not hold a token even with the secret until the right code is typed in the app
    assert "token" not in status(client, st)


def test_token_only_from_confirm_with_the_chat_code_and_only_once(client, fakes):
    st = start(client)
    post_tg(client, tg_update(1, f"/start {st['nonce']}"))
    code = chat_code(client, st["nonce"])
    wrong = "000000" if code != "000000" else "111111"
    assert confirm(client, st, wrong).status_code == 403
    r = confirm(client, st, code)
    assert r.status_code == 200 and len(r.json()["token"]) >= 40 and r.json()["state"] == "claimed"
    assert confirm(client, st, code).status_code == 410          # single use
    assert status(client, st) == {"state": "claimed"}
    assert "connected" in fakes.tg_texts()[-1]                   # welcome lands in chat after confirm


def test_code_locks_after_five_wrong_tries(client):
    st = start(client)
    post_tg(client, tg_update(1, f"/start {st['nonce']}"))
    code = chat_code(client, st["nonce"])
    wrong = "000000" if code != "000000" else "111111"
    codes = [confirm(client, st, wrong).status_code for _ in range(5)]
    assert codes == [403, 403, 403, 403, 410]
    assert confirm(client, st, code).status_code == 410
    assert status(client, st) == {"state": "expired"}


def test_confirm_rejects_malformed_codes(client):
    st = start(client)
    assert confirm(client, st, "12ab56").status_code == 422
    assert confirm(client, st, "é" * 6).status_code == 422


def test_token_is_stored_hashed_with_pepper(client, settings):
    token = enrol(client)
    rows = sqlite3.connect(settings.db_path).execute("SELECT token_hash FROM devices").fetchall()
    assert len(rows) == 1 and rows[0][0] != token
    assert rows[0][0] != hashlib.sha256(token.encode()).hexdigest()  # peppered, not a bare sha256
    assert client.get("/v1/me", headers=auth(token)).status_code == 200
    assert client.get("/v1/me", headers=auth(token + "x")).status_code == 401


def test_nonce_is_single_use_and_expires(client):
    st = start(client)
    post_tg(client, tg_update(1, f"START {st['nonce']}"))
    post_tg(client, tg_update(2, f"/start {st['nonce']}", ref="999"))  # replay by someone else
    assert status(client, st)["state"] == "awaiting_code"
    svc = client.svc
    old = svc.enrol_start(now_utc() - timedelta(minutes=30))
    assert svc.enrol_status(old["nonce"], old["poll_secret"])["state"] == "expired"
    post_tg(client, tg_update(3, f"/start {old['nonce']}"))
    assert svc.enrol_status(old["nonce"], old["poll_secret"])["state"] == "expired"
    assert svc.enrol_confirm(old["nonce"], old["poll_secret"], "123456")[0] == "gone"


def test_allowlist_blocks_others_politely(client, fakes):
    st = start(client)
    post_tg(client, tg_update(1, f"/start {st['nonce']}", ref="555000111"))
    assert "isn't open yet" in fakes.tg_texts()[-1]
    assert status(client, st) == {"state": "denied"}
    assert sqlite3.connect(client.svc.s.db_path).execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0


def test_open_enrolment_flag(tmp_path, fakes):
    import httpx
    from fastapi.testclient import TestClient
    from companion.app import create_app
    from conftest import make_settings
    s = make_settings(tmp_path, open_enrolment=True, allowed_ids=frozenset())
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        assert enrol(c, ref="555000111")


def test_re_enrol_keeps_old_token_until_new_one_is_confirmed(client, settings):
    t1 = enrol(client)
    st = start(client)
    post_tg(client, tg_update(50, f"/start {st['nonce']}"))       # someone re-enrols this chat, never confirms
    assert client.get("/v1/me", headers=auth(t1)).status_code == 200
    t2 = confirm(client, st, chat_code(client, st["nonce"])).json()["token"]
    assert client.get("/v1/me", headers=auth(t1)).status_code == 401
    assert client.get("/v1/me", headers=auth(t2)).status_code == 200
    assert sqlite3.connect(settings.db_path).execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1


def test_unconfirmed_new_users_are_purged(client):
    st = start(client)
    post_tg(client, tg_update(1, f"/start {st['nonce']}"))
    assert sqlite3.connect(client.svc.s.db_path).execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
    client.svc.purge(now_utc() + timedelta(hours=2))
    assert sqlite3.connect(client.svc.s.db_path).execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0


def test_group_chats_cannot_enrol(client):
    st = start(client)
    post_tg(client, tg_update(1, f"/start {st['nonce']}", chat_type="group"))
    assert status(client, st)["state"] == "pending"


def test_enrol_start_rate_limited_per_ip(client):
    codes = [client.post("/v1/enrol/start").status_code for _ in range(7)]
    assert codes[:5] == [200] * 5 and codes[5:] == [429, 429]


def test_every_route_needs_a_token_except_the_public_ones(client):
    public = {"/healthz", "/v1/enrol/start", "/v1/enrol/status", "/v1/enrol/confirm", "/hooks/telegram", "/hooks/whatsapp"}
    checked = 0
    for r in client.app.routes:
        if not isinstance(r, APIRoute) or r.path in public:
            continue
        path = re.sub(r"\{[^}]+\}", "x", r.path)
        for m in r.methods - {"HEAD", "OPTIONS"}:
            resp = client.request(m, path, json={})
            assert resp.status_code == 401, (m, r.path, resp.status_code)
            checked += 1
    assert checked >= 5


def test_hooks_reject_without_credentials(client):
    assert client.post("/hooks/telegram", json={}).status_code == 403
    assert client.post("/hooks/telegram", json={}, headers={"X-Telegram-Bot-Api-Secret-Token": "nope"}).status_code == 403
    assert client.post("/hooks/whatsapp", json={}).status_code == 403


def test_body_cap_8kb_on_v1(client):
    token = enrol(client)
    big = {"run_id": "x" * 9000}
    assert client.post("/v1/runs", json=big, headers=auth(token)).status_code == 413


def test_unknown_fields_rejected(client):
    token = enrol(client)
    from conftest import run_payload
    p = run_payload(gps_track=[[1, 2]])
    assert client.post("/v1/runs", json=p, headers=auth(token)).status_code == 422


def test_status_and_confirm_are_rate_limited_per_ip(client):
    st = start(client)
    codes = [client.post("/v1/enrol/status", json={"nonce": st["nonce"], "poll_secret": st["poll_secret"]}).status_code
             for _ in range(62)]
    assert codes[:60] == [200] * 60 and codes[60:] == [429, 429]


def test_odd_webhook_inputs_never_500(client):
    h = {"X-Telegram-Bot-Api-Secret-Token": "hooksecret-hooksecret"}
    assert client.post("/hooks/telegram", content=b"[1]", headers={**h, "Content-Type": "application/json"}).status_code == 200
    assert client.post("/hooks/telegram", content=b"not json", headers={**h, "Content-Type": "application/json"}).status_code == 200
    odd = {"update_id": 1, "message": {"chat": 5, "text": "hi"}}
    assert client.post("/hooks/telegram", json=odd, headers=h).status_code == 200
    # non-ASCII secret header is a 403, not a crash
    assert client.post("/hooks/telegram", json={}, headers={"X-Telegram-Bot-Api-Secret-Token": "\u00e9".encode("latin-1")}).status_code == 403
    r = client.get("/hooks/whatsapp", params={"hub.mode": "subscribe", "hub.verify_token": "é", "hub.challenge": "1"})
    assert r.status_code == 403


def test_settings_repr_hides_secrets(settings):
    r = repr(settings)
    for secret in ("hooksecret-hooksecret", "watoken", "wa-app-secret", "verifyme", "or-test-key", "123456789:AAFAKE"):
        assert secret not in r
    assert "pppp" not in r


def test_future_dated_run_is_rejected(client):
    from datetime import datetime, timezone
    t = enrol(client)
    p = run_payload(start_utc=(datetime.now(timezone.utc) + timedelta(hours=3)).isoformat())
    assert client.post("/v1/runs", json=p, headers=auth(t)).status_code == 422
