"""Telegram Mini App v1: a read-only view of the runner's week, latest run and lanes (COMPANION_MINIAPP=1).

Auth (eng-review A1): the runner is derived only from Telegram's signed initData, sent as `Authorization: tma <initData>`.
The Telegram user id must match a linked Telegram chat (private chat id == user id), else 403. No runner_id, user id or
token is ever read from the URL, query or body. Everything shown is already stored; nothing new is collected, and the
pack, age band, route shape, place name and heart-rate zones never leave this module.
"""
from __future__ import annotations

import json
import logging
from datetime import date, datetime, timedelta
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import db
from .config import Settings
from .facts import session_label
from .media import SCORE_KEYS, week_bounds
from .miniapp_auth import InitDataError, verify_init_data
from .timeutil import now_utc, parse_iso, to_local, week_key

log = logging.getLogger("companion")

STATIC_DIR = Path(__file__).resolve().parent.parent / "miniapp"
FONTS = {"SairaExtraCondensed-ExtraBold.ttf", "SairaExtraCondensed-Bold.ttf", "SchibstedGrotesk-Variable.ttf"}
LANE_DAYS = 28
CSP = ("default-src 'none'; script-src 'self' https://telegram.org; style-src 'self'; font-src 'self'; "
       "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; "
       "frame-ancestors https://web.telegram.org https://webk.telegram.org https://webz.telegram.org "
       "https://*.telegram.org")
LANE_OF = {"easy": "aerobic", "long": "long", "tempo": "mid", "interval": "speed", "race": "speed",
           "cooper": "speed", "trail": "long"}


def _num(v, nd: int = 1):
    return None if v is None else round(float(v), nd)


def build_view(c, uid: str, zone_id: str, now: datetime) -> dict:
    """The Mini App payload from rows the companion already holds. Read-only; geometry and zones are not selected."""
    wk = week_key(now, zone_id)
    monday, sunday = week_bounds(wk)
    rows = [dict(r) for r in c.execute(
        "SELECT run_id, type, start_utc, zone_id, duration_s, distance_m, pace_s_per_km, true_pace_s_per_km, "
        "scores_delta, climb_m, plan_next_type, plan_next_day, plan_next_week, plan_next_min, plan_next_m, "
        "session_name, work_pace_s_per_km, reps_done, rep_spread_s FROM runs WHERE user_id=? AND start_utc >= ? "
        "ORDER BY start_utc DESC", (uid, (now - timedelta(days=max(LANE_DAYS, 35))).isoformat()))]
    latest = dict(c.execute(
        "SELECT run_id, type, start_utc, zone_id, duration_s, distance_m, pace_s_per_km, true_pace_s_per_km, "
        "climb_m, plan_next_type, plan_next_day, plan_next_week, plan_next_min, plan_next_m, session_name, "
        "work_pace_s_per_km, reps_done, rep_spread_s FROM runs WHERE user_id=? ORDER BY start_utc DESC LIMIT 1",
        (uid,)).fetchone() or {}) or None

    days = [{"date": (monday + timedelta(days=i)).isoformat(), "runs": []} for i in range(7)]
    done_m = done_n = 0
    for r in rows:
        loc = to_local(parse_iso(r["start_utc"]), zone_id)
        if monday <= loc.date() <= sunday:
            days[(loc.date() - monday).days]["runs"].append(
                {"type": r["type"], "lane": LANE_OF.get(r["type"], "aerobic"), "km": _num(r["distance_m"] / 1000)})
            done_m += r["distance_m"]
            done_n += 1

    cutoff = now - timedelta(days=LANE_DAYS)
    moves = {k: 0.0 for k in SCORE_KEYS}
    seen = False
    for r in rows:
        if parse_iso(r["start_utc"]) < cutoff:
            continue
        try:
            sd = json.loads(r["scores_delta"] or "{}")
        except ValueError:
            sd = {}
        for k in SCORE_KEYS:
            if isinstance(sd.get(k), (int, float)):
                moves[k] += sd[k]
                seen = True
    lanes = [{"lane": k, "change": round(moves[k]) if seen else None} for k in SCORE_KEYS]

    out: dict = {"week": {"label": f"Week {int(wk.split('-W')[1])}", "days": days,
                          "done_km": _num(done_m / 1000), "done_runs": done_n, "next": None},
                 "latest": None, "lanes": lanes, "lane_days": LANE_DAYS}
    if latest:
        today = to_local(now, zone_id).date()
        nd = latest["plan_next_day"]
        if latest["plan_next_type"] and nd and date.fromisoformat(nd) >= today:
            out["week"]["next"] = {"type": latest["plan_next_type"], "day": nd, "minutes": latest["plan_next_min"],
                                   "km": _num(latest["plan_next_m"] / 1000) if latest["plan_next_m"] else None}
        sh = c.execute("SELECT splits_json, reps_json FROM run_shape WHERE user_id=? AND run_id=?",
                       (uid, latest["run_id"])).fetchone()
        splits = json.loads(sh["splits_json"]) if sh and sh["splits_json"] else None
        reps = json.loads(sh["reps_json"]) if sh and sh["reps_json"] else None
        interval = latest["type"] == "interval"
        out["latest"] = {
            "type": latest["type"], "lane": LANE_OF.get(latest["type"], "aerobic"),
            "title": session_label(latest) if interval else None,
            "date": to_local(parse_iso(latest["start_utc"]), latest["zone_id"]).date().isoformat(),
            "km": _num(latest["distance_m"] / 1000), "duration_s": latest["duration_s"],
            "pace_s": _num(latest["pace_s_per_km"], 0), "true_pace_s": _num(latest["true_pace_s_per_km"], 0),
            "climb_m": latest["climb_m"], "work_pace_s": _num(latest["work_pace_s_per_km"], 0),
            "rep_spread_s": _num(latest["rep_spread_s"]),
            "splits": [{"km": _num(s["km"], 2), "pace_s": _num(s["pace_s"], 0)} for s in splits] if splits else None,
            "reps": [{"time_s": _num(x["time_s"], 0)} for x in reps] if reps else None,
        }
    return out


def install(app: FastAPI, settings: Settings, svc) -> None:
    from .app import IpLimiter  # late: app imports this module
    ip_limit = IpLimiter(60, 60)
    bad_limit = IpLimiter(20, 60)

    def client_ip(request: Request) -> str:
        return request.headers.get("cf-connecting-ip") or (request.client.host if request.client else "?")

    @app.middleware("http")
    async def miniapp_headers(request: Request, call_next):
        resp = await call_next(request)
        if request.url.path.startswith("/miniapp"):
            resp.headers["Content-Security-Policy"] = CSP
            resp.headers["Referrer-Policy"] = "no-referrer"
            resp.headers["X-Content-Type-Options"] = "nosniff"
            resp.headers["Cache-Control"] = ("no-store" if request.url.path.startswith("/miniapp/api")
                                             else "no-cache" if request.url.path.rstrip("/") == "/miniapp"
                                             else "public, max-age=300")
        return resp

    @app.get("/miniapp/api/me")
    def miniapp_me(request: Request, authorization: str | None = Header(default=None)):
        # Only the Authorization header is read. Query, path and body carry no identity.
        ip = client_ip(request)
        if not ip_limit.allow(ip):
            raise HTTPException(429, "slow down")
        if not authorization or not authorization.lower().startswith("tma "):
            raise HTTPException(401, "unauthorised")
        now = now_utc()
        try:
            who = verify_init_data(authorization[4:].strip(), settings.telegram_token or "", now)
        except InitDataError as e:
            if not bad_limit.allow(ip):
                raise HTTPException(429, "slow down") from None
            log.info("miniapp auth refused: %s", e.code)
            raise HTTPException(401, "unauthorised") from None
        with db.ro(settings.db_path) as c:
            u = c.execute("SELECT id, zone_id FROM users WHERE channel='telegram' AND chat_ref=?",
                          (str(who["user_id"]),)).fetchone()
            if not u:
                raise HTTPException(403, "not linked")
            return build_view(c, u["id"], u["zone_id"], now)

    @app.get("/miniapp/fonts/{name}")
    def miniapp_font(name: str):
        from render.brand import FONT_DIR
        if name not in FONTS or not (FONT_DIR / name).is_file():
            raise HTTPException(404, "not found")
        return FileResponse(FONT_DIR / name, media_type="font/ttf")

    app.mount("/miniapp", StaticFiles(directory=STATIC_DIR, html=True), name="miniapp")
