"""Weekly recap: a run with no zone_s is a km bar in its run-type colour (never grey); old facts fail cleanly."""
import pytest

from render import brand
from render.cards import fixtures as F
from render.cards.weekly import build_weekly_html
from render.motion import samples
from render.motion.weekly_video import WeeklyVideo, weekly_from_facts


def _no_hr_facts():
    f = samples.weekly_facts()
    f["days"][0] = {**f["days"][0], "zone_s": [], "type": "long"}
    f["duration_s"] = sum(sum(d["zone_s"]) for d in f["days"])
    return f


def test_video_no_zone_day_uses_run_type_colour():
    spec = weekly_from_facts(_no_hr_facts())
    assert spec.days[0].run_type == "long" and spec.days[0].km == 7.2
    img = WeeklyVideo(spec).frame(3.0).convert("RGB")
    h = brand.RUN_TYPE_COLOUR["long"].lstrip("#")
    want = tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    near = sum(1 for px in img.getdata() if max(abs(a - b) for a, b in zip(px, want)) <= 6)
    assert near > 2000


def test_card_no_zone_day_uses_run_type_colour():
    f = F.weekly_recap()
    f["days"][0] = {**f["days"][0], "zone_s": [], "type": "long"}
    svg = build_weekly_html(f, {}).split('<div class="abs bars">', 1)[1].split("</svg>")[0]
    assert f'fill="{brand.RUN_TYPE_COLOUR["long"]}"' in svg
    assert f'fill="{brand.QUIET}"/>' not in svg


def test_video_old_facts_without_day_km_raise_a_clean_valueerror():
    f = samples.weekly_facts()
    for d in f["days"]:
        d.pop("distance_km")
    with pytest.raises(ValueError, match="distance_km"):
        weekly_from_facts(f)
