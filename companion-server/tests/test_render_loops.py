"""The v4 moment loops (render/motion/loop.py): run, intervals, PB, week and milestone.

They render for real (Pillow + ffmpeg, like test_motion.py) and fail, never skip, when a dependency is missing.
Each loop renders once per module, one after another, to keep the peak memory low.
"""
import re
import subprocess
import time

import pytest
from PIL import Image, ImageChops

from render import brand
from render import protocol as P
from render.cards import fixtures as F
from render.motion import _loopkit as K
from render.motion import loop
from render.motion._draw import FPS, W
from render.motion.encode import ffmpeg_bin

BUDGET_S = 20.0   # the worker's video timeout is 120 s; a loop must stay far under it even on a loaded host
MAX_BYTES = 2_000_000

CASES = {
    "route": ("run_loop", F.milos_trail),
    "intervals": ("run_loop", F.singapore_intervals),
    "pb": ("run_loop", F.pb_5k),
    "slow": ("run_loop", F.slow_hot_day),
    "week": ("week_loop", F.weekly_recap),
    "milestone": ("milestone_loop", F.milestone_1000km),
}
RENDER = {"run_loop": loop.render_run_loop, "week_loop": loop.render_week_loop,
          "milestone_loop": loop.render_milestone_loop}


@pytest.fixture(scope="module")
def rendered(tmp_path_factory):
    out, d = {}, tmp_path_factory.mktemp("loops")
    for name, (kind, fix) in CASES.items():
        t = time.monotonic()
        RENDER[kind](fix(), d / f"{name}.mp4")
        out[name] = (d / f"{name}.mp4", time.monotonic() - t)
    return out


def _frame(path, t):
    raw = subprocess.run([ffmpeg_bin(), "-loglevel", "error", "-ss", str(t), "-i", str(path), "-frames:v", "1",
                          "-f", "image2pipe", "-vcodec", "png", "-"], capture_output=True, check=True).stdout
    import io
    return Image.open(io.BytesIO(raw)).convert("RGB")


def _has(img, hex_col, tol=24, min_px=200):
    c = tuple(int(hex_col[i:i + 2], 16) for i in (1, 3, 5))
    px = list(img.resize((W // 4, img.height // 4)).getdata())
    return sum(all(abs(a - b) <= tol for a, b in zip(p, c)) for p in px) * 16 >= min_px


@pytest.mark.parametrize("name", CASES)
def test_the_protocol_accepts_each_fixture(name):
    kind, fix = CASES[name]
    keys = P.KIND_FACT_KEYS[kind]   # the fixtures also carry card-only keys that media.run_facts never sends
    P.check_request({"v": 1, "op": "video", "kind": kind, "facts": {k: v for k, v in fix().items() if k in keys}})


@pytest.mark.parametrize("kind", ["run_loop", "week_loop", "milestone_loop"])
def test_the_protocol_takes_loops_as_video_only(kind):
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": kind, "facts": {}})


def test_a_loop_carries_no_new_fact_key():
    assert P.KIND_FACT_KEYS["run_loop"] == P.RUN_KEYS and P.KIND_FACT_KEYS["week_loop"] == P.WEEK_KEYS
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "video", "kind": "run_loop", "facts": {**{k: v for k, v in F.milos_trail().items() if k in P.RUN_KEYS},
                                                                        "session_name": "x"}})


@pytest.mark.parametrize("name", CASES)
def test_duration_size_and_render_time(rendered, name):
    path, secs = rendered[name]
    info = subprocess.run([ffmpeg_bin(), "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr
    m = re.search(r"Duration: 00:00:(\d+\.\d+)", info)
    assert m and float(m.group(1)) <= K.LOOP_S + 0.05
    assert path.stat().st_size <= MAX_BYTES
    assert secs <= BUDGET_S, f"{name} took {secs:.1f}s"
    assert "Audio" not in info


@pytest.mark.parametrize("name", ["route", "intervals", "pb", "week", "milestone"])
def test_the_loop_is_seamless(name):
    """The last frame fades back to frame 0 (the chrome only), so the loop has no visible seam."""
    kind, fix = CASES[name]
    r = {"route": lambda: loop.RunLoopRenderer(loop.run_loop_from_facts(fix())),
         "intervals": lambda: loop.RunLoopRenderer(loop.run_loop_from_facts(fix())),
         "pb": lambda: loop.RunLoopRenderer(loop.run_loop_from_facts(fix())),
         "week": lambda: loop.WeekLoopRenderer(fix()), "milestone": lambda: loop.MilestoneLoopRenderer(fix())}[name]()
    keep = r._img(0.0)
    last = K.loop_out(r._img((K.N_FRAMES - 1) / FPS), (K.N_FRAMES - 1) / FPS, keep)
    diff = ImageChops.difference(keep, last).convert("L")
    assert sum(list(diff.resize((W // 8, diff.height // 8)).getdata())) / (W // 8 * (diff.height // 8)) < 2.0


def test_the_hero_reveal_is_all_or_nothing_per_row():
    """No rolling digits: a revealed row of the number is exactly the final row."""
    hero = K.Hero("12.4", 300, K.M, 900)   # no unit: it fades in separately
    final = K.Frame()
    hero.draw(final, brand.BONE, 1.0)
    fin = final.cv.img.convert("L")
    for p in (0.2, 0.5, 0.8):
        fr = K.Frame()
        hero.draw(fr, brand.BONE, p)
        part = fr.cv.img.convert("L")
        w, h = part.size
        revealed = 0
        blank = Image.new("L", (w, 1), fin.getpixel((0, 0)))   # the ground
        for y in range(0, h, 2):
            row, want = part.crop((0, y, w, y + 1)), fin.crop((0, y, w, y + 1))
            if ImageChops.difference(row, blank).getbbox():
                revealed += 1
                assert ImageChops.difference(row, want).getbbox() is None, f"row {y} at p={p} is not the final row"
        assert revealed


def test_only_a_pb_uses_cyan(rendered):
    for name in CASES:
        has = _has(_frame(rendered[name][0], 4.5), brand.ARC)
        assert has == (name == "pb"), f"{name}: cyan {'missing' if name == 'pb' else 'present'}"


def test_zone_colours_are_the_brand_ramp():
    assert K.ZONE == brand.ZONE_RAMP


def test_the_zone_strip_paints_the_ramp(rendered):
    img = _frame(rendered["route"][0], 4.5)
    zs = F.milos_trail()["zone_s"]
    first = next(z for z, s_ in enumerate(zs) if s_ > 0)
    px = img.getpixel((K.M + 6, loop.HERO_Y + 24))
    want = tuple(int(brand.ZONE_RAMP[first][i:i + 2], 16) for i in (1, 3, 5))
    assert all(abs(a - b) <= 20 for a, b in zip(px, want))


def test_goal_is_mid_violet_and_free_is_long_ice():
    """media.NEUTRAL_RUN_TYPE maps goal to tempo and free to long before the facts reach the worker."""
    for kind, lane in (("tempo", "MID"), ("long", "LONG")):
        s = loop.run_loop_from_facts({**F.slow_hot_day(), "type": kind})
        assert s.label_col == loop.SCORES_DARK[lane]


def test_the_session_name_is_only_the_title():
    s = loop.run_loop_from_facts({**F.milos_trail(), "title": "Kastro loop"})
    assert s.label == "KASTRO LOOP"


def test_spec_validation_is_reused():
    bad = F.milos_trail()
    bad["splits"] = [{**bad["splits"][0], "dist_km": 99.0}] if "dist_km" in bad["splits"][0] else bad["splits"][:1]
    with pytest.raises(ValueError):
        loop.run_loop_from_facts(bad)


def test_a_run_without_a_route_still_loops(tmp_path):
    f = F.slow_hot_day()
    f.pop("route_xy", None)
    f.pop("route", None)
    s = loop.run_loop_from_facts(f)
    assert s.route is None and s.bars


def test_a_week_with_no_distance_has_no_loop():
    with pytest.raises(ValueError):
        loop.WeekLoopRenderer({**F.weekly_recap(), "distance_km": 0})


def test_the_worker_dispatches_the_loops(tmp_path):
    from render.worker import _render_one
    out = tmp_path / "m.mp4"
    _render_one("video", "milestone_loop", F.milestone_100th(), out)
    assert out.stat().st_size > 1000


def _real_pb_facts():
    """What media.run_facts / video_facts send for a PB: the label only, no old best and no delta."""
    f = {k: v for k, v in F.pb_5k().items() if k in P.RUN_KEYS}
    f.update(pb="5k", pb_detail={"label": "5 KM BEST"}, verdict="done")
    f.pop("hero", None)
    return f


def test_a_pb_with_only_its_label_still_gets_the_pb_loop(tmp_path):
    f = _real_pb_facts()
    P.check_request({"v": 1, "op": "video", "kind": "run_loop", "facts": f})
    s = loop.run_loop_from_facts(f)
    assert s.label == "NEW 5 KM BEST" and s.label_col == brand.ARC and s.pb and s.pb["old_s"] is None
    assert [lab for _, lab in s.stats] == ["/KM", "KM"]   # no OLD BEST / FASTER without the old best
    out = tmp_path / "pb.mp4"
    loop.render_run_loop(f, out)
    assert out.stat().st_size > 1000
    assert _has(_frame(out, 4.5), brand.ARC)   # the cyan time


def test_a_pb_with_its_old_best_keeps_the_comparison():
    s = loop.run_loop_from_facts(F.pb_5k())
    assert s.pb and s.pb["old_s"] and [lab for _, lab in s.stats] == ["/KM", "OLD BEST", "FASTER"]


def test_the_rep_unit_does_not_claim_a_distance():
    s = loop.run_loop_from_facts(F.singapore_intervals())
    assert s.unit == "AVG REP"


def test_a_short_zone_list_is_padded_not_an_error():
    f = F.weekly_recap()
    f["days"] = [{**d, "zone_s": list(d["zone_s"])[:3]} for d in f["days"]]
    f["duration_s"] = sum(sum(d["zone_s"]) for d in f["days"])   # the spec's own check: days add up to the week
    r = loop.WeekLoopRenderer(f)
    r._img(2.0)
    run = {**F.milos_trail(), "zone_s": [100.0, 200.0]}
    assert len(loop.run_loop_from_facts(run).zone_s) == 5


@pytest.mark.parametrize("label,km,secs,time_hero", [
    ("5 KM BEST", 5.0, 1301, True),
    ("10 KM BEST", 10.0, 2700, True),
    ("HALF MARATHON BEST", 21.1, 5900, True),
    ("5 KM BEST", 10.0, 3000, False),        # a 5 K inside a 10 km run: not the whole-run time
    ("FASTEST KM", 8.0, 2500, False),
    ("LONGEST RUN", 18.4, 6500, False),
])
def test_a_label_only_pb_never_shows_a_mislabelled_time(label, km, secs, time_hero):
    f = _real_pb_facts()
    f.update(distance_km=km, duration_s=secs, pace_s_per_km=secs / km, pb_detail={"label": label},
             splits=[{"km": 1.0, "pace_s": secs / km, "zone": 3}] * int(km) + ([{"km": km % 1, "pace_s": secs / km, "zone": 3}] if km % 1 else []))
    s = loop.run_loop_from_facts(f)
    assert s.label == f"NEW {label}" and s.pb and s.label_col == brand.ARC
    if time_hero:
        assert s.hero == loop.fmt_dur(secs) and s.unit == ""
    else:
        assert s.hero == f"{km:.1f}" and s.unit == "KM" and [lab for _, lab in s.stats] == ["TIME", "/KM"]
