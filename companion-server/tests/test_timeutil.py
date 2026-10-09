from datetime import datetime, timezone

from companion.timeutil import in_quiet, quiet_end_utc, resolve_cap_week, week_key

U = timezone.utc
QS, QE = 21 * 60 + 30, 7 * 60


def test_quiet_window_wraps_midnight_in_local_time():
    # 22:00 NZDT = 09:00 UTC
    assert in_quiet(datetime(2026, 1, 10, 9, 0, tzinfo=U), "Pacific/Auckland", QS, QE)
    assert not in_quiet(datetime(2026, 1, 10, 2, 0, tzinfo=U), "Pacific/Auckland", QS, QE)  # 15:00 local
    assert in_quiet(datetime(2026, 1, 10, 17, 30, tzinfo=U), "Pacific/Auckland", QS, QE)      # 06:30 local
    assert not in_quiet(datetime(2026, 1, 10, 18, 30, tzinfo=U), "Pacific/Auckland", QS, QE)  # 07:30 local


def test_quiet_equal_bounds_means_never():
    assert not in_quiet(datetime(2026, 1, 1, 3, tzinfo=U), "UTC", 0, 0)


def test_quiet_end_across_dst_forward_uses_local_wall_clock():
    # US DST starts 2026-03-08. 23:00 local on Mar 7 (EST, UTC-5) -> 07:00 local Mar 8 is EDT (UTC-4) = 11:00 UTC
    now = datetime(2026, 3, 8, 4, 0, tzinfo=U)  # 23:00 EST on Mar 7
    assert quiet_end_utc(now, "America/New_York", QE) == datetime(2026, 3, 8, 11, 0, tzinfo=U)


def test_quiet_end_across_dst_back():
    # DST ends 2026-11-01. 23:00 EDT Oct 31 = 03:00 UTC Nov 1; 07:00 local Nov 1 is EST = 12:00 UTC
    now = datetime(2026, 11, 1, 3, 0, tzinfo=U)
    assert quiet_end_utc(now, "America/New_York", QE) == datetime(2026, 11, 1, 12, 0, tzinfo=U)


def test_week_key_is_local():
    # Sunday 23:30 UTC is already Monday in Auckland: different ISO week
    t = datetime(2026, 10, 11, 23, 30, tzinfo=U)
    assert week_key(t, "UTC") == "2026-W41"
    assert week_key(t, "Pacific/Auckland") == "2026-W42"


def test_local_midnight_straddle():
    a = datetime(2026, 10, 11, 10, 59, tzinfo=U)  # Sun 23:59 NZDT
    b = datetime(2026, 10, 11, 11, 1, tzinfo=U)   # Mon 00:01 NZDT
    assert week_key(a, "Pacific/Auckland") != week_key(b, "Pacific/Auckland")


def test_cap_week_does_not_reset_on_zone_change_mid_week():
    mon_nz = datetime(2026, 10, 12, 1, 0, tzinfo=U)       # Mon 14:00 NZDT, week 42 in NZ
    z, w = resolve_cap_week(None, None, "Pacific/Auckland", mon_nz)
    assert (z, w) == ("Pacific/Auckland", "2026-W42")
    # Thursday, user has flown to Singapore; still the same cap week
    thu = datetime(2026, 10, 15, 4, 0, tzinfo=U)
    assert resolve_cap_week(z, w, "Asia/Singapore", thu) == ("Pacific/Auckland", "2026-W42")
    # Next Monday in NZ the week rolls and Singapore takes over
    nxt = datetime(2026, 10, 18, 20, 0, tzinfo=U)         # Mon 09:00 NZDT
    assert resolve_cap_week(z, w, "Asia/Singapore", nxt) == ("Asia/Singapore", week_key(nxt, "Asia/Singapore"))


def test_date_line_travel_week_key_stays_pinned():
    # NZ (UTC+13) to Honolulu (UTC-10): the same instant is a different local day
    t = datetime(2026, 10, 13, 9, 0, tzinfo=U)
    z, w = resolve_cap_week("Pacific/Auckland", week_key(t, "Pacific/Auckland"), "Pacific/Honolulu", t)
    assert z == "Pacific/Auckland"
