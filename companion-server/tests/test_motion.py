"""Motion renders: video contract (Telegram autoplay / WhatsApp header) and key-frame goldens.

Regenerate goldens after an intended visual change: RS_UPDATE_GOLDENS=1 pytest tests/test_motion.py
"""
import os
import re
import subprocess
from pathlib import Path

import pytest

pytest.importorskip("PIL")
from PIL import Image, ImageChops, ImageStat  # noqa: E402

from render.motion import samples  # noqa: E402
from render.motion._geom import prepare_route  # noqa: E402
from render.motion.encode import ffmpeg_bin  # noqa: E402
from render.motion.run_video import N_FRAMES, RunVideo, render_run_video  # noqa: E402
from render.motion.weekly_video import WeeklyVideo, render_weekly_video  # noqa: E402

GOLD = Path(__file__).parent / "golden_motion"
KEY_T = [1.5, 3.7, 6.0, 9.0, 12.5]


def _info(path):
    r = subprocess.run([ffmpeg_bin(), "-hide_banner", "-i", str(path)], capture_output=True, text=True)
    return r.stderr


def _frames(path):
    r = subprocess.run([ffmpeg_bin(), "-hide_banner", "-stats", "-i", str(path), "-map", "0:v:0", "-f", "null", "-"],
                       capture_output=True, text=True)
    return int(re.findall(r"frame=\s*(\d+)", r.stderr)[-1])


@pytest.fixture(scope="module")
def run_mp4(tmp_path_factory):
    return render_run_video(samples.hard_run(), tmp_path_factory.mktemp("m") / "run.mp4")


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
    r = prepare_route(samples.sample_route())
    xs = {round(p[0], 6) for p in r}
    assert len(r) == 600 and len(xs) > 100


def test_unknown_verdict_rejected():
    spec = samples.easy_run()
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
    _check(f"run_easy_{t}", RunVideo(samples.easy_run()).frame(t))


@pytest.mark.parametrize("t", [3.7, 9.0])
def test_run_goldens_flood(t):
    _check(f"run_flood_{t}", RunVideo(samples.hard_run()).frame(t))


@pytest.mark.parametrize("t", [3.0, 7.0, 10.0])
def test_weekly_goldens(t):
    _check(f"weekly_{t}", WeeklyVideo(samples.weekly()).frame(t))
