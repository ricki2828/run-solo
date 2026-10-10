"""Open-Meteo lookups (no API key). Off unless COMPANION_WEATHER is set.

Privacy: the only thing sent is a latitude and longitude rounded to 0.1 degree (about 11 km), taken
from the approximate area the app attaches to a run. No name, id or phone number, and no GPS track.
Every failure returns None and the card is written without weather.
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


CELL = 1  # decimal places kept: 0.1 degree is about 11 km


def cell(lat: float, lon: float) -> tuple[float, float]:
    """Round to 0.1 degree. The only location this module ever sends or stores."""
    return round(float(lat), CELL), round(float(lon), CELL)


class Weather(Protocol):
    def at_run(self, lat: float | None, lon: float | None, zone_id: str, start_utc: datetime,
               now: datetime) -> RunWeather | None: ...
    def tomorrow(self, lat: float | None, lon: float | None, zone_id: str, tomorrow: date) -> Forecast | None: ...


class NoWeather:
    def at_run(self, *_a, **_k) -> RunWeather | None:
        return None

    def tomorrow(self, *_a, **_k) -> Forecast | None:
        return None


class OpenMeteo:
    """Only a 0.1 degree cell goes out (never a name), cached per cell per kind of request per day."""

    def __init__(self, http: httpx.Client, forecast: str = FORECAST):
        self.http, self.forecast = http, forecast
        self._cache: dict[tuple, dict | None] = {}

    def _get(self, ll: tuple[float, float], zone_id: str, past: int, ahead: int, day_key: str) -> dict | None:
        key = (ll, zone_id, past, ahead, day_key)
        if key in self._cache:
            return self._cache[key]
        try:
            r = self.http.get(self.forecast, timeout=8, params={
                "latitude": ll[0], "longitude": ll[1], "timezone": zone_id,
                "hourly": "temperature_2m,precipitation_probability", "daily": "sunrise",
                "past_days": past, "forecast_days": ahead})
            d = r.json() if r.status_code == 200 else None
        except (httpx.HTTPError, ValueError):
            return None  # not cached: try again next time
        self._cache[key] = d
        return d

    def at_run(self, lat, lon, zone_id, start_utc, now):
        if lat is None or lon is None or (now - start_utc) > timedelta(days=MAX_PAST_DAYS):
            return None
        d = self._get(cell(lat, lon), zone_id, min(MAX_PAST_DAYS, max(1, (now - start_utc).days + 1)), 1,
                      now.date().isoformat())
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

    def tomorrow(self, lat, lon, zone_id, tomorrow):
        if lat is None or lon is None:
            return None
        d = self._get(cell(lat, lon), zone_id, 0, 3, tomorrow.isoformat())
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
