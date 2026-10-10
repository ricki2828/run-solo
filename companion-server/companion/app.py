"""FastAPI surface: /v1 (device token), /hooks (signed/secret-checked), /healthz."""
from __future__ import annotations

import hmac
import logging
import threading
import time
from contextlib import asynccontextmanager
from collections import defaultdict, deque
from typing import Literal

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import logs
from .channels import TelegramChannel, WhatsAppChannel, verify_wa_signature
from .config import Settings
from .service import NotFound, RateLimited, RunIn, Service
from .timeutil import now_utc, valid_zone

log = logging.getLogger("companion")

V1_LIMIT = 8 * 1024
HOOK_LIMIT = 256 * 1024
ENROLS_PER_HOUR = 5
STATUS_PER_MIN = 60
CONFIRMS_PER_HOUR = 20


def safe_eq(a: str, b: str) -> bool:
    """Constant-time compare that never raises on non-ASCII input."""
    return hmac.compare_digest(a.encode(), b.encode())


class BodyLimit:
    """ASGI middleware: 8 KB on /v1, 256 KB on webhooks. Counts streamed bytes too."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        limit = HOOK_LIMIT if scope["path"].startswith("/hooks") else V1_LIMIT
        for k, v in scope["headers"]:
            if k == b"content-length" and v.isdigit() and int(v) > limit:
                return await self._reject(send)
        seen = 0

        async def guarded():
            nonlocal seen
            msg = await receive()
            if msg["type"] == "http.request":
                seen += len(msg.get("body", b""))
                if seen > limit:
                    raise _TooLarge()
            return msg

        try:
            await self.app(scope, guarded, send)
        except _TooLarge:
            await self._reject(send)

    @staticmethod
    async def _reject(send):
        await send({"type": "http.response.start", "status": 413, "headers": [(b"content-type", b"application/json")]})
        await send({"type": "http.response.body", "body": b'{"detail":"too large"}'})


class _TooLarge(Exception):
    pass


class FeelIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    feel: Literal["easy", "right", "hard"]


class EnrolStatusIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nonce: str = Field(min_length=8, max_length=64)
    poll_secret: str = Field(min_length=8, max_length=64)


class EnrolConfirmIn(EnrolStatusIn):
    code: str = Field(pattern=r"^\d{6}$")


ZONE_RE = r"^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+){0,2}$"


def _check_zone(v: str | None) -> str | None:
    if v is not None and not valid_zone(v):
        raise ValueError("unknown time zone")
    return v


class TimezoneIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    zone_id: str = Field(max_length=64, pattern=ZONE_RE)  # IANA name, e.g. Europe/Athens

    _zone = field_validator("zone_id")(_check_zone)


class SettingsIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    quiet_start_min: int | None = Field(default=None, ge=0, lt=1440)
    quiet_end_min: int | None = Field(default=None, ge=0, lt=1440)
    zone_id: str | None = Field(default=None, max_length=64, pattern=ZONE_RE)

    _zone = field_validator("zone_id")(_check_zone)


class IpLimiter:
    def __init__(self, n: int, window_s: int):
        self.n, self.w, self.hits = n, window_s, defaultdict(deque)
        self.lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self.lock:
            q = self.hits[key]
            while q and q[0] < now - self.w:
                q.popleft()
            if len(q) >= self.n:
                return False
            q.append(now)
            return True


def create_app(settings: Settings, http: httpx.Client | None = None, *, run_worker: bool = True) -> FastAPI:
    logs.setup()
    http = http or httpx.Client(timeout=10)
    svc = Service(settings, http)
    limiter = IpLimiter(ENROLS_PER_HOUR, 3600)
    status_limiter = IpLimiter(STATUS_PER_MIN, 60)
    confirm_limiter = IpLimiter(CONFIRMS_PER_HOUR, 3600)
    stop = threading.Event()

    def loop() -> None:
        while not stop.wait(30):
            try:
                svc.tick()
            except Exception as e:  # keep the loop alive
                log.error("tick failed: %s", type(e).__name__)

    @asynccontextmanager
    async def lifespan(_app):
        t = threading.Thread(target=loop, name="outbox", daemon=True) if run_worker else None
        if t:
            t.start()
        yield
        stop.set()

    app = FastAPI(title="Run Supreme companion", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(BodyLimit)
    app.state.svc = svc

    def client_ip(request: Request) -> str:
        return request.headers.get("cf-connecting-ip") or (request.client.host if request.client else "?")

    def current_user(authorization: str | None = Header(default=None)) -> str:
        if not authorization or not authorization.lower().startswith("bearer "):
            raise HTTPException(401, "unauthorised")
        uid = svc.authenticate(authorization[7:].strip())
        if not uid:
            raise HTTPException(401, "unauthorised")
        return uid

    @app.get("/healthz")
    def healthz():
        return {"ok": True, "overdue_outbox": svc.overdue_count()}

    # --- enrolment (no token yet) ---
    @app.post("/v1/enrol/start")
    def enrol_start(request: Request):
        if not limiter.allow(client_ip(request)):
            raise HTTPException(429, "slow down")
        return svc.enrol_start()

    @app.post("/v1/enrol/status")
    def enrol_status(body: EnrolStatusIn, request: Request):
        if not status_limiter.allow(client_ip(request)):
            raise HTTPException(429, "slow down")
        return svc.enrol_status(body.nonce, body.poll_secret)

    @app.post("/v1/enrol/confirm")
    def enrol_confirm(body: EnrolConfirmIn, request: Request):
        if not confirm_limiter.allow(client_ip(request)):
            raise HTTPException(429, "slow down")
        result, token, chat_name = svc.enrol_confirm(body.nonce, body.poll_secret, body.code)
        if result == "ok":
            return {"state": "claimed", "token": token, "chat_name": chat_name}
        if result == "wrong":
            raise HTTPException(403, "wrong code")
        raise HTTPException(410, "enrolment expired")

    # --- authenticated ---
    @app.post("/v1/runs")
    def post_run(run: RunIn, response: Response, uid: str = Depends(current_user)):
        try:
            out = svc.ingest_run(uid, run)
        except RateLimited:
            raise HTTPException(429, "daily limit")
        except ValueError:
            raise HTTPException(422, "start_utc is in the future")
        response.status_code = 200 if out["status"] == "duplicate" else 202
        return out

    @app.patch("/v1/runs/{run_id}/feel")
    def patch_feel(run_id: str, body: FeelIn, uid: str = Depends(current_user)):
        try:
            svc.set_feel(uid, run_id, body.feel)
        except NotFound:
            raise HTTPException(404, "unknown run")
        return {"status": "ok"}

    @app.get("/v1/me")
    def get_me(uid: str = Depends(current_user)):
        try:
            return svc.get_me(uid)
        except NotFound:
            raise HTTPException(404, "gone")

    @app.delete("/v1/me")
    def delete_me(uid: str = Depends(current_user)):
        svc.delete_me(uid)
        return {"status": "deleted"}

    @app.put("/v1/me/settings")
    def put_settings(body: SettingsIn, uid: str = Depends(current_user)):
        svc.set_settings(uid, body.quiet_start_min, body.quiet_end_min, body.zone_id)
        return {"status": "ok"}

    @app.put("/v1/me/timezone")
    def put_timezone(body: TimezoneIn, uid: str = Depends(current_user)):
        """The app calls this when the phone's zone changes (travel). The 8 pm suggestion and the 7 pm Sunday
        recap follow the new zone from the next planning tick."""
        try:
            return svc.set_timezone(uid, body.zone_id)
        except NotFound:
            raise HTTPException(404, "gone")

    # --- webhooks ---
    @app.post("/hooks/telegram")
    async def hook_telegram(request: Request):
        want = settings.telegram_webhook_secret or ""
        got = request.headers.get("x-telegram-bot-api-secret-token", "")
        if not want or not safe_eq(want, got):
            raise HTTPException(403, "forbidden")
        try:
            update = await request.json()
        except ValueError:
            return {"ok": True}
        try:
            inb = TelegramChannel.parse(update) if isinstance(update, dict) else None
        except (AttributeError, TypeError, KeyError, ValueError):
            inb = None  # odd shapes from a signed sender are ignored, never a 500
        if inb:
            await _run_sync(svc.handle_inbound, inb)
        return {"ok": True}

    @app.get("/hooks/whatsapp")
    def hook_wa_verify(hub_mode: str = Query("", alias="hub.mode"), hub_token: str = Query("", alias="hub.verify_token"),
                       hub_challenge: str = Query("", alias="hub.challenge")):
        if not settings.wa_ready or hub_mode != "subscribe" or not safe_eq(settings.wa_verify_token or "", hub_token):
            raise HTTPException(403, "forbidden")
        return Response(hub_challenge, media_type="text/plain")

    @app.post("/hooks/whatsapp")
    async def hook_wa(request: Request):
        if not settings.wa_ready:
            raise HTTPException(404, "disabled")
        raw = await request.body()  # signature is over the raw bytes, before any parsing
        if not verify_wa_signature(settings.wa_app_secret or "", raw, request.headers.get("x-hub-signature-256")):
            raise HTTPException(403, "bad signature")
        try:
            payload = await request.json()
        except ValueError:
            return {"ok": True}
        try:
            msgs = WhatsAppChannel.parse(payload) if isinstance(payload, dict) else []
        except (AttributeError, TypeError, KeyError, ValueError):
            msgs = []
        for inb in msgs:
            await _run_sync(svc.handle_inbound, inb)
        return {"ok": True}

    return app


async def _run_sync(fn, *a):
    import asyncio
    await asyncio.to_thread(fn, *a)


def app_from_env() -> FastAPI:
    return create_app(Settings.from_env())
