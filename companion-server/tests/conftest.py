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


def parse_request_body(req: httpx.Request) -> dict:
    """JSON bodies as-is. Multipart uploads become {field: text, "_files": {name: (filename, bytes, content type)}}."""
    if not req.content:
        return {}
    ct = req.headers.get("content-type", "")
    if ct.startswith("multipart/form-data"):
        from email.parser import BytesParser
        from email.policy import default
        msg = BytesParser(policy=default).parsebytes(b"Content-Type: " + ct.encode() + b"\r\n\r\n" + req.content)
        out: dict = {"_files": {}}
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if part.get_filename():
                out["_files"][name] = (part.get_filename(), part.get_payload(decode=True), part.get_content_type())
            else:
                out[name] = part.get_content()
        return out
    return json.loads(req.content)


class Fakes:
    """Stand-ins for Telegram, OpenRouter and the WhatsApp Graph API, behind httpx.MockTransport."""

    def __init__(self):
        self.tg: list[tuple[str, dict]] = []
        self.wa: list[dict] = []
        self.llm: list[dict] = []
        self.llm_mode = "ok"
        self.mid = 100
        self.fails: dict[str, list[tuple]] = {}   # Telegram method -> queued failures (see fail())

    def fail(self, method: str, status: int = 400, description: str = "", retry_after: float | None = None,
             times: int = 1, timeout: bool = False) -> None:
        """The next `times` calls to this Telegram method fail: an HTTP error (optionally a 429 with retry_after) or a
        timeout, in which case the call may or may not have been delivered (it is recorded, then times out)."""
        self.fails.setdefault(method, []).extend([(status, description, retry_after, timeout)] * times)

    def handler(self, req: httpx.Request) -> httpx.Response:
        host, path = req.url.host, req.url.path
        body = parse_request_body(req)
        if host == "api.telegram.org":
            method = path.rsplit("/", 1)[-1]
            queued = self.fails.get(method)
            if queued:
                status, description, retry_after, timeout = queued.pop(0)
                if timeout:
                    self.tg.append((method, body))   # delivered, but the answer never arrives
                    raise httpx.ReadTimeout("slow")
                err: dict = {"ok": False, "error_code": status, "description": description}
                if retry_after is not None:
                    err["parameters"] = {"retry_after": retry_after}
                return httpx.Response(status, json=err)
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

    def tg_methods(self):
        return [m for m, _ in self.tg]

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
        checkins_enabled=True,
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


def weather_on(client, token: str, on: bool = True):
    """The app's "Weather in suggestions" switch (PUT /v1/me/settings {weather})."""
    r = client.put("/v1/me/settings", json={"weather": on}, headers=auth(token))
    assert r.status_code == 200, r.text
    return r


def run_payload(run_id="r1", minutes_ago=20, **over):
    start = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago + 40)
    p = {"run_id": run_id, "type": "easy", "start_utc": start.isoformat(), "utc_offset_min": 780,
         "zone_id": "Pacific/Auckland", "duration_s": 2400, "distance_m": 7000,
         "pace_s_per_km": 342.0, "true_pace_s_per_km": 338.0, "verdict": "holding"}
    p.update(over)
    return p


@pytest.fixture
def render_socket():
    """A real render worker (render/worker.py) serving a unix socket in a thread; renders run in real child processes."""
    import tempfile
    import threading
    from render.worker import Worker
    d = tempfile.mkdtemp(prefix="rsw-")  # short: unix socket paths top out near 108 bytes
    w = Worker(os.path.join(d, "render.sock"))
    srv = w.bind()
    threading.Thread(target=w.serve_forever, args=(srv,), daemon=True).start()
    yield w.sock_path
    srv.close()


def shape_route(n: int = 60) -> list[list[int]]:
    """A canonical route shape, like the phone's normaliser makes: whole numbers on a 0..255 grid, a unit box that
    touches x=0 and y=0 with its longer side the full grid."""
    import math
    pts = [(math.cos(2 * math.pi * i / n), 0.6 * math.sin(2 * math.pi * i / n)) for i in range(n)]
    x0, y0 = min(p[0] for p in pts), min(p[1] for p in pts)
    span = max(max(p[0] for p in pts) - x0, max(p[1] for p in pts) - y0)
    return [[round((x - x0) / span * 255), round((y - y0) / span * 255)] for x, y in pts]


def shape_payload(distance_m: int = 7000, duration_s: int = 2400, reps: bool = False, **over):
    """The route, splits (and reps) fields of a run, consistent with `distance_m` and `duration_s`."""
    full, rest = divmod(distance_m, 1000)
    kms = [1.0] * full + ([round(rest / 1000, 3)] if rest >= 20 else [])
    pace = round(duration_s / (distance_m / 1000), 1)
    p = {"route": shape_route(),
         "splits": [{"km": km, "pace_s": pace, "zone": 2 + (i % 2)} for i, km in enumerate(kms)]}
    if reps:
        p["reps"] = [{"time_s": 84.0 - i, "zone": 5} for i in range(6)]
    p.update(over)
    return p
