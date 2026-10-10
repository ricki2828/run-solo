"""Open-Meteo lookups (no API key). Off unless COMPANION_WEATHER is set.

Privacy: the only thing sent is the runner's suburb or place name (the `locality` the app already
sends us), to Open-Meteo's geocoder. No phone number, id or GPS leaves the server. Every failure
returns None and the card is written without weather.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Protocol
from zoneinfo import ZoneInfo

import httpx

from ..timeutil import UTC

log = logging.getLogger("companion.weather")
GEOCODE = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST = "https://api.open-meteo.com/v1/forecast"
HEAT_C = 28  # a run this warm counts as a heat slowdown
MAX_PAST_DAYS = 90


@dataclass(frozen=True)
class RunWeather:
    temp_c: int | None
    sunrise_local: datetime | None


@dataclass(frozen=True)
class Forecast:
    morning_temp_c: int
    rain_pct: int  # peak chance of rain between 06:00 and 10:00 local


class Weather(Protocol):
    def at_run(self, locality: str | None, zone_id: str, start_utc: datetime, now: datetime) -> RunWeather | None: ...
    def tomorrow(self, locality: str | None, zone_id: str, tomorrow: date) -> Forecast | None: ...


class NoWeather:
    def at_run(self, *_a, **_k) -> RunWeather | None:
        return None

    def tomorrow(self, *_a, **_k) -> Forecast | None:
        return None


class OpenMeteo:
    def __init__(self, http: httpx.Client, geocode: str = GEOCODE, forecast: str = FORECAST):
        self.http, self.geocode, self.forecast = http, geocode, forecast
        self._places: dict[str, tuple[float, float] | None] = {}

    def _latlon(self, locality: str) -> tuple[float, float] | None:
        key = locality.strip().lower()
        if key in self._places:
            return self._places[key]
        try:
            r = self.http.get(self.geocode, params={"name": locality, "count": 1, "format": "json"}, timeout=6)
            res = (r.json().get("results") or [None])[0] if r.status_code == 200 else None
            val = (round(float(res["latitude"]), 2), round(float(res["longitude"]), 2)) if res else None
        except (httpx.HTTPError, ValueError, KeyError, TypeError):
            return None  # not cached: try again next time
        self._places[key] = val
        return val

    def _get(self, ll: tuple[float, float], zone_id: str, past: int, ahead: int) -> dict | None:
        try:
            r = self.http.get(self.forecast, timeout=8, params={
                "latitude": ll[0], "longitude": ll[1], "timezone": zone_id,
                "hourly": "temperature_2m,precipitation_probability", "daily": "sunrise",
                "past_days": past, "forecast_days": ahead})
            return r.json() if r.status_code == 200 else None
        except (httpx.HTTPError, ValueError):
            return None

    def at_run(self, locality, zone_id, start_utc, now):
        if not locality or (now - start_utc) > timedelta(days=MAX_PAST_DAYS):
            return None
        ll = self._latlon(locality)
        d = self._get(ll, zone_id, min(MAX_PAST_DAYS, max(1, (now - start_utc).days + 1)), 1) if ll else None
        if not d:
            return None
        try:
            local = start_utc.astimezone(ZoneInfo(zone_id))
            hours = d["hourly"]["time"]
            hour_key = local.strftime("%Y-%m-%dT%H:00")
            temp = d["hourly"]["temperature_2m"][hours.index(hour_key)] if hour_key in hours else None
            day = local.strftime("%Y-%m-%d")
            sun = None
            if day in d["daily"]["time"]:
                sun = datetime.fromisoformat(d["daily"]["sunrise"][d["daily"]["time"].index(day)]).replace(
                    tzinfo=ZoneInfo(zone_id))
            return RunWeather(round(temp) if isinstance(temp, (int, float)) else None, sun)
        except (KeyError, ValueError, TypeError, IndexError):
            return None

    def tomorrow(self, locality, zone_id, tomorrow):
        if not locality:
            return None
        ll = self._latlon(locality)
        d = self._get(ll, zone_id, 0, 3) if ll else None
        if not d:
            return None
        try:
            times, temps, rain = d["hourly"]["time"], d["hourly"]["temperature_2m"], d["hourly"]["precipitation_probability"]
            day = tomorrow.isoformat()
            idx = {h: i for i, t in enumerate(times) for h in range(24) if t == f"{day}T{h:02d}:00"}
            morning = [idx[h] for h in range(6, 11) if h in idx]
            if not morning:
                return None
            t7 = temps[idx.get(7, morning[0])]
            peak = max(rain[i] for i in morning if rain[i] is not None)
            return Forecast(round(t7), int(peak))
        except (KeyError, ValueError, TypeError, IndexError):
            return None
