"""find_care: nearby physios, sports doctors, GPs and urgent care from OpenStreetMap (Nominatim to geocode a typed place, Overpass
to search). Information, not a referral: no ratings, ordered by distance only.

PRIVACY. A location is used for this one call and never persisted. The only thing kept is a 24 h in-memory cache keyed by
(kind, latitude and longitude rounded to 0.01 degree, about 1 km), which is also the point the search is centred on, so a more
exact position never leaves the server. The typed place text is not cached, logged or stored. Nothing is written to the database.
Where the position comes from, in order: the place the runner typed; else the coarse start of their latest run (convo_area, only
there while they opted in, already rounded to 0.1 degree); else a `need_place` result so the coach asks for one."""
from __future__ import annotations

import math
import re
import threading
import time
from collections import OrderedDict
from urllib.parse import urlparse

from .. import redflag
from ... import db

RULES = (
    "- find_care finds nearby care from OpenStreetMap. Use it when a runner wants a physio, sports doctor, GP or urgent care, "
    "or after triage_check says amber or red. If it returns need_place, ask which suburb or town they are in; never guess one. "
    "Say the results are from OpenStreetMap, not a recommendation, and to check they are open and treat running injuries. Only "
    "say a phone number or website that appears in the result.")

NOMINATIM = "https://nominatim.openstreetmap.org/search"
OVERPASS = "https://overpass-api.de/api/interpreter"
USER_AGENT = "RunSupremeCoach/1.0 (+https://github.com/ricki2828/run-solo; coach care finder)"
MIN_GAP_S = 1.0          # at most one request a second to OSM services
CACHE_TTL_S = 24 * 3600
CACHE_MAX = 512           # least recently used goes first
MAX_FIELD = 80            # name, hours
MAX_ADDRESS = 120
MAX_URL = 200
RADII_M = (5000, 10000)  # widen once if fewer than WIDEN_BELOW results
WIDEN_BELOW = 3
MAX_RESULTS = 5
ATTRIBUTION = ("Data from OpenStreetMap contributors (openstreetmap.org/copyright). Listed by distance only, not a "
               "recommendation: check they are open and treat running injuries.")

_clock = time.monotonic
_sleep = time.sleep
_lock = threading.Lock()
_last_request = [-1e9]
_cache: "OrderedDict[tuple, tuple[float, list[dict]]]" = OrderedDict()

# kind -> Overpass selector fragments applied to nodes, ways and relations
_SELECTORS = {
    "physio": ['["healthcare"="physiotherapist"]'],
    "sports_med": ['["healthcare:speciality"~"sports"]', '["healthcare"="doctor"]["name"~"sport",i]'],
    "gp": ['["amenity"="doctors"]', '["healthcare"="doctor"]', '["amenity"="clinic"]'],
    "urgent": ['["amenity"="hospital"]["emergency"="yes"]', '["amenity"="hospital"]', '["amenity"="clinic"]["emergency"="yes"]'],
}


def _throttle() -> None:
    with _lock:
        wait = MIN_GAP_S - (_clock() - _last_request[0])
        if wait > 0:
            _sleep(wait)
        _last_request[0] = _clock()


def _get(http, method: str, url: str, **kw):
    _throttle()
    r = http.request(method, url, headers={"User-Agent": USER_AGENT}, timeout=20, **kw)
    r.raise_for_status()
    return r.json()


def _geocode(http, place: str) -> tuple[float, float]:
    hits = _get(http, "GET", NOMINATIM, params={"q": place, "format": "jsonv2", "limit": 1})
    if not hits:
        raise ValueError("could not find that place; ask for a suburb or town name")
    return float(hits[0]["lat"]), float(hits[0]["lon"])


def _latest_run_area(ctx) -> tuple[float, float] | None:
    c = db.connect(ctx.settings.db_path)
    try:
        r = c.execute("SELECT a.lat, a.lon FROM convo_area a JOIN runs r ON r.user_id=a.user_id AND r.run_id=a.run_id "
                      "WHERE a.user_id=? ORDER BY r.start_utc DESC LIMIT 1", (ctx.user_id,)).fetchone()
        return (r["lat"], r["lon"]) if r else None
    finally:
        c.close()


def _zone(ctx) -> str | None:
    c = db.connect(ctx.settings.db_path)
    try:
        r = c.execute("SELECT zone_id FROM users WHERE id=?", (ctx.user_id,)).fetchone()
        return r["zone_id"] if r else None
    finally:
        c.close()


def _haversine_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(h))


def _query(kind: str, lat: float, lon: float, radius: int) -> str:
    parts = "".join(f"nwr{s}(around:{radius},{lat},{lon});" for s in _SELECTORS[kind])
    return f"[out:json][timeout:20];({parts});out center tags 60;"


# OSM text is written by anyone, so it is cleaned before the model or Telegram sees it: control characters and markup characters
# out, whitespace collapsed, capped; a website must be http(s) with a host; a phone number only digits and phone punctuation.
_BAD_CHARS = re.compile(r"[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2060-\u2064<>`*_\[\]{}\\|]")
_PHONE_OK = re.compile(r"^\+?[0-9][0-9 ()./-]{4,28}$")


def _clean(value, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    t = " ".join(_BAD_CHARS.sub(" ", value).split())
    return t[:limit].rstrip() or None


def _website(value) -> str | None:
    if not isinstance(value, str):
        return None
    v = value.strip()
    if v.lower().startswith("www."):
        v = "https://" + v
    if len(v) > MAX_URL or re.search(r"[\s\x00-\x1f\x7f<>\"'`\\]", v):
        return None
    try:
        u = urlparse(v)
        host = u.hostname
    except ValueError:
        return None
    return v if u.scheme in ("http", "https") and host and "." in host else None


def _phone(value) -> str | None:
    v = value.strip() if isinstance(value, str) else ""
    return v if _PHONE_OK.match(v) else None


def _address(t: dict) -> str | None:
    street = " ".join(x for x in (t.get("addr:housenumber"), t.get("addr:street")) if x)
    bits = [b for b in (street, t.get("addr:unit") and f"#{t['addr:unit']}", t.get("addr:suburb") or t.get("addr:city"),
                        t.get("addr:postcode")) if b]
    return _clean(", ".join(bits) or t.get("addr:full"), MAX_ADDRESS)


def _parse(data: dict, centre: tuple[float, float]) -> list[dict]:
    out, seen = [], set()
    for el in data.get("elements", []):
        t = el.get("tags") or {}
        name = _clean(t.get("name"), MAX_FIELD) or ""
        pt = (el.get("lat"), el.get("lon")) if "lat" in el else ((el.get("center") or {}).get("lat"), (el.get("center") or {}).get("lon"))
        if not name or pt[0] is None or pt[1] is None or (name.lower(), round(pt[0], 3), round(pt[1], 3)) in seen:
            continue
        seen.add((name.lower(), round(pt[0], 3), round(pt[1], 3)))
        row = {"name": name, "distance_km": round(_haversine_km(centre, (pt[0], pt[1])), 1), "address": _address(t),
               "phone": _phone(t.get("phone") or t.get("contact:phone")),
               "website": _website(t.get("website") or t.get("contact:website")),
               "opening_hours": _clean(t.get("opening_hours"), MAX_FIELD)}
        out.append({k: v for k, v in row.items() if v is not None and v != ""})
    out.sort(key=lambda r: r["distance_km"])
    return out[:MAX_RESULTS]


def _search(http, kind: str, centre: tuple[float, float]) -> list[dict]:
    key = (kind, centre[0], centre[1])
    hit = _cache.get(key)
    if hit and _clock() - hit[0] < CACHE_TTL_S:
        _cache.move_to_end(key)
        return hit[1]
    results: list[dict] = []
    for radius in RADII_M:
        data = _get(http, "POST", OVERPASS, data={"data": _query(kind, centre[0], centre[1], radius)})
        results = _parse(data, centre)
        if len(results) >= WIDEN_BELOW:
            break
    _cache[key] = (_clock(), results)
    _cache.move_to_end(key)
    while len(_cache) > CACHE_MAX:
        _cache.popitem(last=False)
    return results


def call(name: str, args: dict, ctx) -> dict:
    if name != "find_care":
        raise ValueError("unknown tool")
    kind = args["kind"]
    place = (args.get("place") or "").strip()
    if place:
        lat, lon = _geocode(ctx.http, place)
    else:
        area = _latest_run_area(ctx)
        if not area:
            return {"need_place": True, "kind": kind, "message": "No location is known. Ask the runner which suburb or town they are in."}
        lat, lon = area
    centre = (round(lat, 2), round(lon, 2))       # ~1 km: the cache key and the point searched
    results = _search(ctx.http, kind, centre)
    out: dict = {"kind": kind, "count": len(results), "results": results, "attribution": ATTRIBUTION}
    if not results:
        out["message"] = "Nothing found within 10 km on OpenStreetMap. Suggest searching a map or asking a GP."
    if kind == "urgent":
        em = redflag.EMERGENCY.get(redflag.country(_zone(ctx)) or "")
        if em:
            out["emergency_number"] = em
    return out
