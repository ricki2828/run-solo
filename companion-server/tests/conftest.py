import json
import os
import sys
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from companion.app import create_app  # noqa: E402
from companion.config import Settings  # noqa: E402

TG_TOKEN = "123456789:AAFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
HOOK_SECRET = "hooksecret-hooksecret"
WA_SECRET = "wa-app-secret"
OWNER = "111222333"


class Fakes:
    """Stand-ins for Telegram, OpenRouter and the WhatsApp Graph API, behind httpx.MockTransport."""

    def __init__(self):
        self.tg: list[tuple[str, dict]] = []
        self.wa: list[dict] = []
        self.llm: list[dict] = []
        self.llm_mode = "ok"
        self.mid = 100

    def handler(self, req: httpx.Request) -> httpx.Response:
        host, path = req.url.host, req.url.path
        body = json.loads(req.content) if req.content else {}
        if host == "api.telegram.org":
            method = path.rsplit("/", 1)[-1]
            self.tg.append((method, body))
            self.mid += 1
            return httpx.Response(200, json={"ok": True, "result": {"message_id": self.mid}})
        if host == "graph.facebook.com":
            self.wa.append(body)
            self.mid += 1
            return httpx.Response(200, json={"messages": [{"id": f"wamid.{self.mid}"}]})
        if host == "openrouter.ai":
            self.llm.append(body)
            return self._llm(body)
        return httpx.Response(404)

    def _llm(self, body):
        mode = self.llm_mode
        if mode == "timeout":
            raise httpx.ReadTimeout("slow")
        if mode == "500":
            return httpx.Response(500, json={})
        facts = json.loads(body["messages"][1]["content"])["facts"]
        if mode == "ungrounded":
            text = {"headline": "Quick one", "body": "You ran 99.9 km today."}
        elif mode == "banned":
            text = {"headline": "Great effort", "body": f"{facts[0]}"}
        elif mode == "bad_json":
            return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})
        elif mode == "too_long":
            text = {"headline": "x", "body": "y" * 400}
        elif mode == "no_number":
            text = {"headline": "Nice", "body": "Solid run."}
        else:
            text = {"headline": "Run in the bank", "body": facts[0][:200]}
        return httpx.Response(200, json={
            "provider": "FakeProvider", "usage": {"cost": 0.0004},
            "choices": [{"message": {"content": json.dumps(text)}}]})

    def tg_texts(self):
        return [b["text"] for m, b in self.tg if m == "sendMessage"]


@pytest.fixture
def fakes():
    return Fakes()


def make_settings(tmp_path, **over) -> Settings:
    base = dict(
        db_path=str(tmp_path / "data" / "c.db"), pepper=b"p" * 32,
        allowed_ids=frozenset({f"telegram:{OWNER}"}),
        telegram_token=TG_TOKEN, telegram_bot="RSBot", telegram_webhook_secret=HOOK_SECRET,
        wa_enabled=True, wa_number="61400000000", wa_phone_id="PHONEID", wa_token="watoken",
        wa_app_secret=WA_SECRET, wa_verify_token="verifyme",
        openrouter_key="or-test-key", monthly_cap_usd=5.0,
        default_quiet=(0, 0),  # never quiet unless a test says so
        weather_enabled=True,  # fake Open-Meteo answers 404, so weather simply stays absent
    )
    base.update(over)
    return Settings(**base)


@pytest.fixture
def settings(tmp_path):
    return make_settings(tmp_path)


@pytest.fixture
def client(settings, fakes):
    http = httpx.Client(transport=httpx.MockTransport(fakes.handler))
    app = create_app(settings, http, run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        yield c


def tg_update(uid: int, text: str, ref: str = OWNER, chat_type: str = "private", frm: dict | None = None):
    return {"update_id": uid, "message": {"message_id": uid, "text": text,
                                          "chat": {"id": int(ref), "type": chat_type},
                                          "from": frm if frm is not None else {"id": int(ref)}}}


def tg_callback(uid: int, data: str, ref: str = OWNER, mid: int = 5):
    return {"update_id": uid, "callback_query": {"id": f"cb{uid}", "data": data, "from": {"id": int(ref)},
                                                 "message": {"message_id": mid, "chat": {"id": int(ref), "type": "private"}}}}


_uid = iter(range(1000, 10**6))


def post_tg(client, update, secret=HOOK_SECRET):
    h = {"X-Telegram-Bot-Api-Secret-Token": secret} if secret is not None else {}
    return client.post("/hooks/telegram", json=update, headers=h)


def start(client) -> dict:
    return client.post("/v1/enrol/start").json()


def status(client, st: dict) -> dict:
    return client.post("/v1/enrol/status", json={"nonce": st["nonce"], "poll_secret": st["poll_secret"]}).json()


def chat_code(client, nonce: str) -> str:
    """The code the bot sent into the chat (read from the DB; one test also checks the message text)."""
    import sqlite3
    path = client.app.state.svc.s.db_path
    return sqlite3.connect(path).execute("SELECT code FROM enrolments WHERE nonce=?", (nonce,)).fetchone()[0]


def confirm(client, st: dict, code: str):
    return client.post("/v1/enrol/confirm", json={"nonce": st["nonce"], "poll_secret": st["poll_secret"], "code": code})


def enrol(client, ref: str = OWNER) -> str:
    """Full flow: app starts, user messages the bot with the nonce, bot sends a code, app confirms it."""
    st = start(client)
    assert post_tg(client, tg_update(next(_uid), f"/start {st['nonce']}", ref)).status_code == 200
    assert status(client, st)["state"] == "awaiting_code"
    r = confirm(client, st, chat_code(client, st["nonce"]))
    assert r.status_code == 200, r.text
    return r.json()["token"]


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def run_payload(run_id="r1", minutes_ago=20, **over):
    start = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago + 40)
    p = {"run_id": run_id, "type": "easy", "start_utc": start.isoformat(), "utc_offset_min": 780,
         "zone_id": "Pacific/Auckland", "duration_s": 2400, "distance_m": 7000,
         "pace_s_per_km": 342.0, "true_pace_s_per_km": 338.0, "verdict": "holding"}
    p.update(over)
    return p
