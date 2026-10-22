"""get_weather: the forecast for a run (temperature, dew point, morning rain chance) and what the heat does to an easy
pace, on the existing Open-Meteo wrapper (convo/weather.py) and the heat table (heat.py). No key.

Where: a place the runner named (geocoded by Open-Meteo, only the typed name goes out) or, when they have switched weather
on in the app, their stored 0.1 degree area. Either way only a 0.1 degree cell reaches the forecast request. Nothing is
stored. With neither, the tool says it has no location and the coach asks for a suburb or city.
"""
from __future__ import annotations

import re
from datetime import timedelta

import httpx

from ... import db, heat
from ...convo.weather import OpenMeteo, cell
from ...timeutil import to_local

GEOCODE = "https://geocoding-api.open-meteo.com/v1/search"
DAYS = {"today": 0, "tomorrow": 1, "day_after": 2}   # the forecast covers three days
PLACE_RE = re.compile(r"^[^\W\d_][^\W\d_ ,.'-]*(?:[ ,.'-]+[^\W\d_][^\W\d_ ,.'-]*)*$")   # letters and separators: no digits, so no street number
MAX_PLACE = 60
DEFAULT_HOUR = 7


def _geocode(http, place: str) -> tuple[float, float, str, str] | None:
    """(lat, lon, display name, zone id) or None."""
    try:
        r = http.get(GEOCODE, timeout=6, params={"name": place, "count": 1, "language": "en", "format": "json"})
        hit = (r.json().get("results") or [None])[0] if r.status_code == 200 else None
        if not hit:
            return None
        name = ", ".join(x for x in (hit.get("name"), hit.get("country")) if isinstance(x, str))
        return float(hit["latitude"]), float(hit["longitude"]), name, str(hit.get("timezone") or "UTC")
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        return None


def _median_easy_pace(c, uid: str, now) -> float | None:
    from ...timeutil import iso
    paces = sorted(r["p"] for r in c.execute(
        "SELECT COALESCE(true_pace_s_per_km, pace_s_per_km) p FROM runs WHERE user_id=? AND type='easy' "
        "AND start_utc>=? AND COALESCE(true_pace_s_per_km, pace_s_per_km) IS NOT NULL "
        "ORDER BY start_utc DESC LIMIT 6", (uid, iso(now - timedelta(days=42)))))
    return paces[len(paces) // 2] if len(paces) >= 2 else None


def call(name: str, args: dict, ctx) -> dict:
    place = (args.get("place") or "").strip()
    when = args.get("when") or "tomorrow"
    hour = int(args["hour"]) if args.get("hour") is not None else DEFAULT_HOUR
    if when not in DAYS or not 0 <= hour <= 23:
        raise ValueError("when is today, tomorrow or day_after; hour is 0 to 23")
    with db.tx(ctx.settings.db_path) as c:
        u = c.execute("SELECT zone_id, weather_optin FROM users WHERE id=?", (ctx.user_id,)).fetchone()
        zone = u["zone_id"] if u else "UTC"
        lat = lon = None
        label = "your usual area"
        if place:
            if len(place) > MAX_PLACE or not PLACE_RE.match(place):
                raise ValueError("place must be just a suburb or city name, no street address or numbers")
        elif u and u["weather_optin"]:
            a = c.execute("SELECT lat, lon FROM convo_area WHERE user_id=? ORDER BY rowid DESC LIMIT 1", (ctx.user_id,)).fetchone()
            if a:
                lat, lon = a["lat"], a["lon"]
        pace = _median_easy_pace(c, ctx.user_id, ctx.now)
    if place:
        g = _geocode(ctx.http, place)
        if not g:
            raise ValueError("I could not find that place: ask for a nearby suburb or city")
        lat, lon, label, zone = g
    if lat is None or lon is None:
        raise ValueError("no location for the weather: ask the runner for their suburb or city")
    lat, lon = cell(lat, lon)
    day = to_local(ctx.now, zone).date() + timedelta(days=DAYS[when])
    om = OpenMeteo(ctx.http)
    td = om.heat_at(lat, lon, zone, day, hour)
    if td is None:
        raise ValueError("the forecast is not available right now: say you could not check it")
    rain = om.tomorrow(lat, lon, zone, day)
    f = heat.slowdown_fraction(td[0], td[1])
    out: dict = {"place": label, "date": day.isoformat(), "weekday": day.strftime("%A"), "local_hour": f"{hour:02d}:00",
                 "temp_c": td[0], "dew_point_c": td[1]}
    if rain:
        out["morning_rain_chance_pct"] = rain.rain_pct
    if f is None:
        out["heat"] = "too hot to compare: run by effort, or move it to a cooler hour"
    elif f < heat.LINE_MIN_FRACTION:
        out["heat"] = "no real heat slowdown"
    else:
        out["heat_slowdown_pct"] = round(f * 100, 1)
        extra = heat.extra_s_per_km(pace, td[0], td[1]) if pace else None
        if extra:
            out["easy_pace_extra_s_per_km"] = extra
        out["heat"] = "runs slower than in the cool; go by effort"
    return out
