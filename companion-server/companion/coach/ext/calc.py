"""calc_pace: pace, time and distance arithmetic, so the coach never does sums in its head. Every figure comes back as a ready
string (m:ss, h:mm:ss, km to one decimal), which is what lets the validator accept it."""
from __future__ import annotations

import re

from ..tools import km as _km, mmss

RULES = ("- calc_pace does pace, finish-time and distance arithmetic. Use it for every pace, time or distance you would otherwise "
         "work out yourself; say its figures as they come back.")

_TIME = re.compile(r"^(?:(\d{1,2}):)?(\d{1,2}):(\d{2})$")


def _seconds(text: str, what: str) -> int:
    m = _TIME.match((text or "").strip())
    if not m:
        raise ValueError(f"{what} must look like 1:55:00 or 5:40")
    h, mi, s = int(m.group(1) or 0), int(m.group(2)), int(m.group(3))
    if s > 59 or (m.group(1) and mi > 59):
        raise ValueError(f"{what} is not a valid time")
    total = h * 3600 + mi * 60 + s
    if total <= 0:
        raise ValueError(f"{what} must be more than zero")
    return total


def _need(args: dict, *names: str) -> None:
    missing = [n for n in names if args.get(n) is None]
    if missing:
        raise ValueError("needs " + ", ".join(missing))


def call(name: str, args: dict, ctx) -> dict:
    mode = args["mode"]
    if mode == "pace":
        _need(args, "distance_km", "time")
        dist, t = float(args["distance_km"]), _seconds(args["time"], "time")
        pace = t / dist
        return {"mode": mode, "distance_km": _km(dist * 1000), "time": mmss(t), "pace_per_km": mmss(pace),
                "speed_kmh": round(dist / (t / 3600), 1)}
    if mode == "time":
        _need(args, "distance_km", "pace")
        dist, p = float(args["distance_km"]), _seconds(args["pace"], "pace")
        return {"mode": mode, "distance_km": _km(dist * 1000), "pace_per_km": mmss(p), "time": mmss(dist * p)}
    if mode == "distance":
        _need(args, "time", "pace")
        t, p = _seconds(args["time"], "time"), _seconds(args["pace"], "pace")
        return {"mode": mode, "time": mmss(t), "pace_per_km": mmss(p), "distance_km": round(t / p, 1)}
    if mode == "adjust":
        _need(args, "pace", "seconds_per_km")
        p, delta = _seconds(args["pace"], "pace"), float(args["seconds_per_km"])
        new = p + delta
        if new <= 0:
            raise ValueError("that adjustment leaves no pace")
        return {"mode": mode, "pace_per_km": mmss(p), "adjust_s_per_km": round(delta),
                "adjusted_pace_per_km": mmss(new), "direction": "slower" if delta > 0 else "quicker" if delta < 0 else "same"}
    raise ValueError("unknown mode")
