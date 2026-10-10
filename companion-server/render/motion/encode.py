"""ffmpeg pipe: raw RGB frames in, Telegram/WhatsApp-safe H.264 out. No frames touch disk."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from ._draw import FPS, H, W


def ffmpeg_bin() -> str:
    for c in (os.environ.get("FFMPEG"), shutil.which("ffmpeg"), str(Path.home() / "bin" / "ffmpeg")):
        if c and Path(c).exists():
            return c
    raise RuntimeError("ffmpeg not found (set FFMPEG)")


def encode(frames, out_path, max_kbps: int = 2200):
    """frames: iterable of PIL RGB images (W x H). Writes H.264 main, yuv420p, bt709, faststart, no audio."""
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg_bin(), "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
        "-an",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
        "-c:v", "libx264", "-preset", "medium", "-profile:v", "main", "-level", "4.0",
        "-crf", "21", "-maxrate", f"{max_kbps}k", "-bufsize", f"{max_kbps * 2}k",
        "-g", "30", "-bf", "2", "-r", str(FPS),
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
        "-movflags", "+faststart", str(out_path),
    ]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        for img in frames:
            p.stdin.write(img.tobytes())
        p.stdin.close()
        err = p.stderr.read().decode()
        if p.wait() != 0:
            raise RuntimeError(f"ffmpeg failed: {err[-400:]}")
    except BrokenPipeError:
        raise RuntimeError(f"ffmpeg exited early: {p.stderr.read().decode()[-400:]}")
    finally:
        if p.poll() is None:
            p.kill()
    return out_path
