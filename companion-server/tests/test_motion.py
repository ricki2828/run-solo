"""Motion renders: video contract (Telegram autoplay / WhatsApp header) and key-frame goldens.

Regenerate goldens after an intended visual change: RS_UPDATE_GOLDENS=1 pytest tests/test_motion.py
"""
import os
import re
import subprocess
from pathlib import Path

import pytest

from PIL import Image, ImageChops, ImageStat  # noqa: E402

from render.motion import samples  # noqa: E402
from render.motion._geom import prepare_route  # noqa: E402
from render.motion.encode import ffmpeg_bin  # noqa: E402
from render.motion.run_video import N_FRAMES, RunVideo, render_run_video  # noqa: E402
from render.motion.weekly_video import WeeklyVideo, render_weekly_video  # noqa: E402

GOLD = Path(__file__).parent / "golden_motion"
KEY_T = [1.5, 3.7, 6.0, 9.0, 12.5]


def test_ffmpeg_is_on_path():
    """A missing ffmpeg must fail the suite, not skip it."""
    import shutil

    assert shutil.which("ffmpeg"), "ffmpeg not on PATH (CI installs it; locally put it on PATH or set FFMPEG)"
    assert ffmpeg_bin()


def _info(path):
    r = subprocess.run([ffmpeg_bin(), "-hide_banner", "-i", str(path)], capture_output=True, text=True)
    return r.stderr


def _frames(path):
    r = subprocess.run([ffmpeg_bin(), "-hide_banner", "-stats", "-i", str(path), "-map", "0:v:0", "-f", "null", "-"],
                       capture_output=True, text=True)
    return int(re.findall(r"frame=\s*(\d+)", r.stderr)[-1])


@pytest.fixture(scope="module")
def run_mp4(tmp_path_factory):
    return render_run_video(samples.run_spec("pb"), tmp_path_factory.mktemp("m") / "run.mp4")


@pytest.fixture(scope="module")
def weekly_mp4(tmp_path_factory):
    return render_weekly_video(samples.weekly(), tmp_path_factory.mktemp("w") / "week.mp4")


@pytest.mark.parametrize("fx", ["run_mp4", "weekly_mp4"])
def test_video_contract(fx, request):
    p = request.getfixturevalue(fx)
    info = _info(p)
    assert "Video: h264 (Main)" in info
    assert "yuv420p" in info and "1080x1350" in info and "30 fps" in info
    assert "Audio:" not in info
    dur = re.search(r"Duration: 00:00:(\d+\.\d+)", info)
    assert 10 <= float(dur.group(1)) <= 15
    assert p.stat().st_size < 4 * 1024 * 1024
    assert _frames(p) == N_FRAMES
    # faststart: moov before mdat
    data = p.read_bytes()
    assert data.find(b"moov") < data.find(b"mdat")


def test_route_prep_handles_closed_loop():
    r = prepare_route(samples.run_spec("milos").route)
    xs = {round(p[0], 6) for p in r}
    assert len(r) == 600 and len(xs) > 100


def test_unknown_verdict_rejected():
    spec = samples.run_spec("slow")
    spec.verdict.kind = "sideways"
    with pytest.raises(ValueError):
        RunVideo(spec)


def _small(img):
    return img.resize((270, 338), Image.LANCZOS)


def _check(name, img):
    path = GOLD / f"{name}.png"
    small = _small(img)
    if os.environ.get("RS_UPDATE_GOLDENS"):
        GOLD.mkdir(exist_ok=True)
        small.save(path, optimize=True)
    assert path.exists(), f"missing golden {name}; run with RS_UPDATE_GOLDENS=1"
    diff = ImageChops.difference(small, Image.open(path).convert("RGB"))
    assert sum(ImageStat.Stat(diff).mean) / 3 < 2.0, f"{name} drifted"


@pytest.mark.parametrize("t", KEY_T)
def test_run_goldens_light(t):
    _check(f"run_light_{t}", RunVideo(samples.run_spec("milos")).frame(t))


@pytest.mark.parametrize("t", [3.7, 9.0])
def test_run_goldens_flood(t):
    _check(f"run_flood_{t}", RunVideo(samples.run_spec("pb")).frame(t))


@pytest.mark.parametrize("t", [3.0, 7.0, 10.0])
def test_weekly_goldens(t):
    _check(f"weekly_{t}", WeeklyVideo(samples.weekly()).frame(t))


@pytest.mark.parametrize("which", ["milos", "intervals", "slow", "pb"])
def test_facts_agree(which):
    spec = samples.run_spec(which)
    v = spec.verdict
    if v.kind == "pb":
        assert v.new == spec.duration_s and v.hero == v.old - v.new == 48  # 22:29 -> 21:41
    elif v.fmt == "mss" and v.unit == "/KM AVG":
        assert abs(v.hero - spec.duration_s / spec.distance_km) < 1e-6  # hero is the avg pace shown in the stats
    # the splits cover every km and add up to the run
    assert len(spec.splits) == -(-spec.distance_km // 1)
    assert abs(sum(s.dist_km * s.pace_s for s in spec.splits) - spec.duration_s) < 0.015 * spec.duration_s


def test_wrong_hero_rejected():
    spec = samples.run_spec("pb")
    spec.verdict.hero = 41
    with pytest.raises(ValueError, match="hero"):
        spec.validate()


def test_missing_km_rejected():
    spec = samples.run_spec("pb")
    spec.splits = spec.splits[:3]
    with pytest.raises(ValueError):
        spec.validate()


def test_distance_lands_exactly():
    v = RunVideo(samples.run_spec("milos"))
    from render.motion.run_video import ROUTE

    # the count-up has finished (and holds the exact value) before the route head arrives
    f = v.frame(ROUTE[1] - 0.2)
    g = v.frame(ROUTE[1] + 0.2)
    assert f.crop((0, 880, 700, 1150)).tobytes() == g.crop((0, 880, 700, 1150)).tobytes()


def test_weekly_facts_must_add_up():
    f = samples.weekly_facts()
    f["duration_s"] += 3600
    from render.motion.weekly_video import weekly_from_facts

    with pytest.raises(ValueError, match="add up"):
        weekly_from_facts(f)


def test_weekly_runs_must_match_days():
    f = samples.weekly_facts()
    f["runs"] = 4
    from render.motion.weekly_video import weekly_from_facts

    with pytest.raises(ValueError, match="runs"):
        weekly_from_facts(f)


def test_each_fixture_has_its_own_route():
    from render.motion._geom import fit, prepare_route

    shapes = {}
    for w in ("milos", "intervals", "slow", "pb"):
        r = prepare_route(samples.run_spec(w).route)
        shapes[w] = fit(r, (0, 0, 100, 100))
    names = list(shapes)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            d = sum(abs(p[0] - q[0]) + abs(p[1] - q[1]) for p, q in zip(shapes[a], shapes[b])) / len(shapes[a])
            assert d > 3, f"{a} and {b} draw the same route"


def test_interval_session_shows_rep_bars():
    spec = samples.run_spec("intervals")
    v = RunVideo(spec)
    assert [b.pace_s for b in v.bars] == [86, 85, 84, 84, 82, 81, 85, 85]
    assert v.bars is spec.reps and len(v.bars) == 8
    assert min(v.bars, key=lambda b: b.pace_s).label == "6"  # rep 6, 1:21: same fact the weekly best moment quotes
    assert all(b.zone for b in v.bars)


def test_rep_facts_must_agree():
    f = samples.facts("intervals")
    f["hero"] = {"value": "1:30", "unit": "/400 M AVG"}
    with pytest.raises(ValueError, match="rep"):
        samples.spec_from_facts(f)


@pytest.mark.parametrize("t", [6.8])
def test_run_goldens_intervals(t):
    _check(f"run_intervals_{t}", RunVideo(samples.run_spec("intervals")).frame(t))


def test_interval_stats_are_reps_and_best():
    assert RunVideo(samples.run_spec("intervals"))._extra_stats() == [("8", "REPS"), ("1:21", "BEST")]
    assert RunVideo(samples.run_spec("pb"))._extra_stats()[0][1].startswith("AVG PACE")


@pytest.mark.parametrize("which,want", [("milos", "AVERAGE PACE"), ("intervals", "AVERAGE REP"),
                                        ("slow", "AVERAGE PACE"), ("pb", "5 KM BEST")])
def test_verdict_label_never_comes_from_place_note(which, want):
    f = samples.facts(which)
    spec = samples.spec_from_facts(f)
    assert spec.verdict.context == want
    assert f["place_note"].upper() not in spec.verdict.context


def _ink_cols(img, bg, y0, y1):
    px = img.convert("RGB").load()
    xs = [x for x in range(img.width) for y in range(y0, y1)
          if sum(abs(a - b) for a, b in zip(px[x, y], bg)) > 60]
    return min(xs), max(xs)


@pytest.mark.parametrize("flood", [None, 3])
def test_signoff_mark_and_wordmark_are_centred(flood):
    from render.motion import _common
    th = _common.Theme(flood)
    cv = th.canvas()
    _common.signoff(cv, th, 10.0, 0.0, "")
    img = cv.img if cv.img.width == _common.W else cv.img.resize((_common.W, _common.H))
    bg = img.getpixel((2, 2))
    for y0, y1 in ((430, 760), (850, 924)):  # mark band, wordmark band
        lo, hi = _ink_cols(img, bg, y0, y1)
        assert abs((lo + hi) / 2 - _common.W / 2) <= 2, (y0, lo, hi)


def test_mark_svg_is_sized_from_its_own_aspect():
    from render import brand
    for v in ("on-light", "on-dark", "mono-black", "mono-white"):
        s = brand.mark_svg(v, 64)
        assert 'height="64"' in s and f'width="{round(64 * brand.svg_aspect("mark-" + v))}"' in s
