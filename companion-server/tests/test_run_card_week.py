"""The post-run card carries the runner's week so far: the numbers (companion/media.week_track), the protocol's check of
them, the still (light, flood, PB) and the run loop's end band. The numbers come from stored rows only."""
import io
import re
import subprocess

import pytest
from PIL import Image

from companion.media import MediaRenderer, run_facts, week_track
from render import protocol as P
from render.cards import fixtures as F
from render.cards.pb import build_pb_html
from render.cards.post_run import build_post_run_html
from render.motion import _loopkit as K
from render.motion import loop
from render.motion.encode import ffmpeg_bin

AKL = "Pacific/Auckland"   # UTC+13 on 2026-10-10 (NZDT)


def row(utc, km, zone=AKL):
    return {"start_utc": utc, "zone_id": zone, "distance_m": km * 1000, "type": "easy", "duration_s": km * 400,
            "run_id": utc}


# Mon 5 Oct 2026 is the week's Monday. Auckland local = UTC + 13h.
THIS = row("2026-10-08T19:00:00+00:00", 10)                       # Fri 9 Oct 08:00 local (the run)
HIST = [row("2026-10-04T22:00:00+00:00", 5),                      # Mon 5 Oct 11:00 local, this week
        row("2026-10-06T19:00:00+00:00", 8),                      # Wed 7 Oct 08:00 local, this week
        THIS,
        row("2026-10-10T19:00:00+00:00", 9),                      # Sun 11 Oct, after the run: left out
        row("2026-09-30T19:00:00+00:00", 20),                     # last week
        row("2026-09-22T19:00:00+00:00", 10)]                     # two weeks back


def test_the_week_so_far_counts_up_to_this_run_only():
    w = week_track(THIS, HIST)
    assert w["days"] == [5.0, 0.0, 8.0, 0.0, 10.0, 0.0, 0.0] and w["today_idx"] == 4
    assert w["runs"] == 3 and w["km"] == 23.0


def test_the_usual_week_is_the_mean_of_the_earlier_weeks_back_to_the_first_run():
    # history starts 22 Sep (two weeks before Monday 5 Oct is Mon 21 Sep): weeks back 0 and 1 only
    assert week_track(THIS, HIST)["usual_km"] == 15.0   # (20 + 10) / 2


def test_a_quiet_week_inside_the_span_counts_as_zero():
    hist = [THIS, row("2026-09-30T19:00:00+00:00", 20), row("2026-09-10T19:00:00+00:00", 10)]   # first run 4 weeks back
    assert week_track(THIS, hist)["usual_km"] == 7.5   # (20 + 0 + 0 + 10) / 4


def test_the_week_boundary_is_the_runners_local_monday():
    # Sun 4 Oct 22:00 UTC is Mon 5 Oct 11:00 in Auckland (this week) but still Sunday 4 Oct in Honolulu (last week)
    r = row("2026-10-04T22:00:00+00:00", 6)
    assert week_track(r, [r])["today_idx"] == 0
    r = row("2026-10-04T22:00:00+00:00", 6, "Pacific/Honolulu")
    assert week_track(r, [r])["today_idx"] == 6
    # a Sunday-night run belongs to the week that ends that night, not the next
    late = row("2026-10-04T10:30:00+00:00", 7)   # Sun 4 Oct 23:30 Auckland
    w = week_track(late, [late, row("2026-10-03T19:00:00+00:00", 5)])   # Sun 4 Oct 08:00 Auckland
    assert w["today_idx"] == 6 and w["km"] == 12.0 and w["runs"] == 2


def test_the_first_run_of_the_week_has_one_bar():
    w = week_track(THIS, [THIS, row("2026-09-30T19:00:00+00:00", 12)])
    assert w["runs"] == 1 and w["km"] == 10.0 and w["days"][4] == 10.0 and sum(w["days"]) == 10.0
    assert w["usual_km"] == 12.0


def test_no_earlier_weeks_means_no_usual_week():
    w = week_track(THIS, [THIS, row("2026-10-04T22:00:00+00:00", 5)])
    assert "usual_km" not in w and w["runs"] == 2


def test_two_runs_on_one_day_share_the_bar_and_a_missing_distance_is_no_week():
    a, b = row("2026-10-08T19:00:00+00:00", 4), row("2026-10-08T21:00:00+00:00", 3)
    w = week_track(b, [a, b])
    assert w["days"][4] == 7.0 and w["runs"] == 2
    assert week_track({**b, "distance_m": 0}, [a, b]) is None


def test_run_facts_carries_the_week_only_when_the_rows_ride_beside_the_run():
    base = {**THIS, "app_type": "easy", "pace_s_per_km": 400, "run_id": "r1", "start_utc": THIS["start_utc"]}
    assert "week_track" not in run_facts(base, "x")
    f = run_facts({**base, "_history": HIST}, "x")
    assert f["week_track"]["km"] == 23.0 and set(f) <= P.ALLOWED_FACT_KEYS


@pytest.mark.parametrize("fixture", [F.week_first_run, F.week_third_run, F.week_big])
def test_the_protocol_accepts_the_fixtures_on_every_run_kind(fixture):
    facts = {k: v for k, v in fixture().items() if k in P.RUN_KEYS}
    for op, kind in (("video", "run_loop"), ("card", "light"), ("card", "flood"), ("card", "pb"), ("card", "share")):
        P.check_request({"v": 1, "op": op, "kind": kind, "facts": facts})


@pytest.mark.parametrize("bad", [
    {"days": [1, 0, 0, 0, 0, 0], "today_idx": 0, "runs": 1, "km": 1},                          # six days
    {"days": [5, 0, 0, 0, 0, 0, 0], "today_idx": 0, "runs": 1, "km": 9},                       # days do not add up
    {"days": [5, 0, 0, 0, 0, 0, 0], "today_idx": 7, "runs": 1, "km": 5},                       # no such weekday
    {"days": [5, 0, 3, 0, 0, 0, 0], "today_idx": 0, "runs": 2, "km": 8},                       # km after the run's day
    {"days": [5, 0, 0, 0, 0, 0, 0], "today_idx": 0, "runs": 0, "km": 5},                       # no runs
    {"days": [5, 0, 0, 0, 0, 0, 0], "today_idx": 0, "runs": 1, "km": 5, "run_id": "r1"},       # a key off the list
    {"days": [5, 0, 0, 0, 0, 0, 0], "today_idx": 0, "runs": 1, "km": 5, "usual_km": "31"},     # not a number
])
def test_the_protocol_refuses_a_malformed_week(bad):
    facts = {k: v for k, v in F.week_first_run().items() if k in P.RUN_KEYS}
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "light", "facts": {**facts, "week_track": bad}})


def test_the_week_never_reaches_the_share_poster_or_the_weekly_recap():
    assert "week_track" not in P.WEEK_KEYS and "week_track" not in P.KIND_FACT_KEYS["week_loop"]
    from render.cards import share
    assert "THIS WEEK" not in share.build_share_html({**F.week_big(), "share": {"time": True}})


def test_the_still_shows_the_week_and_a_card_without_it_is_unchanged():
    for build, fix in ((build_post_run_html, F.week_first_run), (build_post_run_html, F.week_third_run), (build_pb_html, F.week_big)):
        html = build(fix(), {"name": "Ricki"})
        assert "THIS WEEK" in html
    plain = F.slow_hot_day()
    assert "THIS WEEK" not in build_post_run_html(plain, {})
    html = build_post_run_html(F.week_first_run(), {})
    assert "1 RUN / USUAL 31 KM" in html and ">6.2<" in html
    assert "USUAL" not in build_post_run_html(F.with_week(plain, [0, 6.2, 0, 0, 0, 0, 0], None), {})


@pytest.mark.parametrize("fixture", [F.week_first_run, F.week_big])
def test_the_run_loop_keeps_its_length_and_size_and_lands_the_band(tmp_path, fixture):
    facts = {k: v for k, v in fixture().items() if k in P.RUN_KEYS}
    path = tmp_path / "w.mp4"
    loop.render_run_loop(facts, path)
    info = subprocess.run([ffmpeg_bin(), "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr
    m = re.search(r"Duration: 00:00:(\d+\.\d+)", info)
    assert m and float(m.group(1)) <= K.LOOP_S + 0.05 and path.stat().st_size <= 2_000_000

    def frame(t):
        raw = subprocess.run([ffmpeg_bin(), "-loglevel", "error", "-ss", str(t), "-i", str(path), "-frames:v", "1",
                              "-f", "image2pipe", "-vcodec", "png", "-"], capture_output=True, check=True).stdout
        return Image.open(io.BytesIO(raw)).convert("RGB")
    held, first = frame(4.5), frame(0.0)
    band = (0, 1080, 1080, 1340)   # the "this week" band's rows
    lit = lambda im: sum(1 for p in im.crop(band).resize((108, 26)).getdata() if max(p) > 90)   # noqa: E731
    assert lit(held) > 60 and lit(first) == 0   # the band is there when the loop holds and gone on frame 0 (the seam)


def test_a_loop_without_the_week_is_laid_out_as_before():
    r = loop.RunLoopRenderer(loop.run_loop_from_facts(F.slow_hot_day()))
    assert r.hero_y == loop.HERO_Y and r.stats_y == 1238 and r.s.week is None
    r = loop.RunLoopRenderer(loop.run_loop_from_facts(F.week_first_run()))
    assert r.hero_y == loop.WEEK_HERO_Y and r.s.week["km"] == 6.2
