"""python -m render.motion <milos|intervals|slow|pb|weekly> out.mp4  (sample facts; prints render time)"""
import sys
import time

from . import samples
from .run_video import render_run_video


def main(argv):
    which, out = argv[1], argv[2]
    t0 = time.time()
    if which == "weekly":
        from .weekly_video import render_weekly_video

        render_weekly_video(samples.weekly(), out)
    else:
        render_run_video(samples.run_spec(which), out)
    print(f"{out}: {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main(sys.argv)
