import hashlib
import re
import sqlite3
from datetime import timedelta

from fastapi.routing import APIRoute

from companion.timeutil import now_utc
from conftest import OWNER, auth, enrol, post_tg, tg_update


def test_start_returns_nonce_and_deep_links(client):
    r = client.post("/v1/enrol/start").json()
    assert re.fullmatch(r"[A-Za-z0-9_-]{16,}", r["nonce"])
    assert r["links"]["telegram"] == f"https://t.me/RSBot?start={r['nonce']}"
    assert r["links"]["whatsapp"] == f"https://wa.me/61400000000?text=START%20{r['nonce']}"
    assert client.get("/v1/enrol/status", params={"nonce": r["nonce"]}).json() == {"state": "pending"}


def test_token_issued_only_after_inbound_message_and_only_once(client, fakes):
    nonce = client.post("/v1/enrol/start").json()["nonce"]
    assert "token" not in client.get("/v1/enrol/status", params={"nonce": nonce}).json()
    post_tg(client, tg_update(1, f"/start {nonce}"))
    first = client.get("/v1/enrol/status", params={"nonce": nonce}).json()
    assert first["state"] == "bound" and len(first["token"]) >= 40
    assert client.get("/v1/enrol/status", params={"nonce": nonce}).json() == {"state": "claimed"}
    assert "connected" in fakes.tg_texts()[-1]


def test_token_is_stored_hashed_with_pepper(client, settings):
    token = enrol(client)
    rows = sqlite3.connect(settings.db_path).execute("SELECT token_hash FROM devices").fetchall()
    assert len(rows) == 1 and rows[0][0] != token
    assert rows[0][0] != hashlib.sha256(token.encode()).hexdigest()  # peppered, not a bare sha256
    assert client.get("/v1/me", headers=auth(token)).status_code == 200
    assert client.get("/v1/me", headers=auth(token + "x")).status_code == 401


def test_nonce_is_single_use_and_expires(client, settings):
    nonce = client.post("/v1/enrol/start").json()["nonce"]
    post_tg(client, tg_update(1, f"START {nonce}"))
    post_tg(client, tg_update(2, f"/start {nonce}", ref="999"))  # replay by someone else
    assert client.get("/v1/enrol/status", params={"nonce": nonce}).json()["state"] == "bound"
    svc = client.svc
    n2 = svc.enrol_start(now_utc() - timedelta(minutes=30))["nonce"]
    assert svc.enrol_status(n2)["state"] == "expired"
    post_tg(client, tg_update(3, f"/start {n2}"))
    assert svc.enrol_status(n2)["state"] == "expired"


def test_allowlist_blocks_others_politely(client, fakes):
    nonce = client.post("/v1/enrol/start").json()["nonce"]
    post_tg(client, tg_update(1, f"/start {nonce}", ref="555000111"))
    assert "isn't open yet" in fakes.tg_texts()[-1]
    st = client.get("/v1/enrol/status", params={"nonce": nonce}).json()
    assert st == {"state": "denied"}


def test_open_enrolment_flag(tmp_path, fakes):
    import httpx
    from fastapi.testclient import TestClient
    from companion.app import create_app
    from conftest import make_settings
    s = make_settings(tmp_path, open_enrolment=True, allowed_ids=frozenset())
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        assert enrol(c, ref="555000111")


def test_re_enrol_rotates_token_and_keeps_user(client, settings):
    t1 = enrol(client)
    t2 = enrol(client)
    assert client.get("/v1/me", headers=auth(t1)).status_code == 401
    assert client.get("/v1/me", headers=auth(t2)).status_code == 200
    c = sqlite3.connect(settings.db_path)
    assert c.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1


def test_group_chats_cannot_enrol(client):
    nonce = client.post("/v1/enrol/start").json()["nonce"]
    post_tg(client, tg_update(1, f"/start {nonce}", chat_type="group"))
    assert client.get("/v1/enrol/status", params={"nonce": nonce}).json()["state"] == "pending"


def test_enrol_start_rate_limited_per_ip(client):
    codes = [client.post("/v1/enrol/start").status_code for _ in range(7)]
    assert codes[:5] == [200] * 5 and codes[5:] == [429, 429]


def test_every_route_needs_a_token_except_the_public_ones(client):
    public = {"/healthz", "/v1/enrol/start", "/v1/enrol/status", "/hooks/telegram", "/hooks/whatsapp"}
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
