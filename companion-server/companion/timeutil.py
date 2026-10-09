"""All time-zone logic lives here, in the user's local zone (eng-review C4)."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

UTC = timezone.utc


def now_utc() -> datetime:
    return datetime.now(UTC)


def iso(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(UTC)


def zone(zone_id: str | None) -> ZoneInfo:
    try:
        return ZoneInfo(zone_id or "UTC")
    except (ZoneInfoNotFoundError, ValueError, OSError):
        return ZoneInfo("UTC")


def valid_zone(zone_id: str) -> bool:
    try:
        ZoneInfo(zone_id)
        return True
    except (ZoneInfoNotFoundError, ValueError, OSError):
        return False


def to_local(dt: datetime, zone_id: str | None) -> datetime:
    return dt.astimezone(zone(zone_id))


def week_key(dt: datetime, zone_id: str | None) -> str:
    y, w, _ = to_local(dt, zone_id).isocalendar()
    return f"{y}-W{w:02d}"


def resolve_cap_week(cap_zone: str | None, cap_week: str | None, zone_id: str | None,
                     now: datetime) -> tuple[str, str]:
    """Weekly caps are pinned to the week the first send landed in.

    A zone change mid-week must not reset the cap: the old zone keeps defining the
    current week until it rolls over, then the user's current zone takes over.
    """
    if cap_zone and cap_week and week_key(now, cap_zone) == cap_week:
        return cap_zone, cap_week
    z = zone_id or "UTC"
    return z, week_key(now, z)


def in_quiet(now: datetime, zone_id: str | None, start_min: int, end_min: int) -> bool:
    loc = to_local(now, zone_id)
    m = loc.hour * 60 + loc.minute
    if start_min == end_min:
        return False
    if start_min < end_min:
        return start_min <= m < end_min
    return m >= start_min or m < end_min  # window wraps midnight


def quiet_end_utc(now: datetime, zone_id: str | None, end_min: int) -> datetime:
    """Next local `end_min` strictly after now, as UTC. Built from local wall time so DST is safe."""
    z = zone(zone_id)
    loc = now.astimezone(z)
    day = loc.date()
    for add in (0, 1, 2):
        d = day + timedelta(days=add)
        cand = datetime(d.year, d.month, d.day, end_min // 60, end_min % 60, tzinfo=z)
        if cand.astimezone(UTC) > now:
            return cand.astimezone(UTC)
    return now + timedelta(hours=12)
