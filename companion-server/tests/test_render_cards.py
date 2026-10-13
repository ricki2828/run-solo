"""Card renderer: brand contrast, effort mode, privacy of the share card, and golden PNGs."""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from render import brand
from render.cards import _parts as P
from render.cards import fixtures as F
from render.cards import share as share_mod
from render.cards.post_run import build_post_run_html

GOLDEN_DIR = Path(__file__).parent / "golden_cards"
MEMORY = F.MEMORY


def _body(html: str) -> str:
    """The page without its inlined font data, which is base64 and can contain any short token."""
    return html.split("</style>", 1)[1]


def test_bone_on_every_flood_is_7_to_1():
    for flood in brand.ZONE_FLOOD:
        assert brand.contrast(brand.BONE, flood) >= 7.0, flood


def test_flood_stays_close_to_the_spec_hue():
    # the text-safe floods only darken the spec colours, never shift them
    for spec, safe in zip(brand.ZONE_FLOOD_SPEC, brand.ZONE_FLOOD):
        a = [int(spec[i:i + 2], 16) for i in (1, 3, 5)]
        b = [int(safe[i:i + 2], 16) for i in (1, 3, 5)]
        assert all(y <= x for x, y in zip(a, b)) or a == b


def test_effort_mode_picks_flood_for_hard_and_light_for_easy():
    assert P.effort_mode(F.singapore_intervals()) == ("flood", 5)
    assert P.effort_mode(F.pb_5k())[0] == "flood"
    assert P.effort_mode(F.milos_trail())[0] == "light"
    assert P.effort_mode(F.slow_hot_day())[0] == "light"
    z4z5 = {"type": "easy", "zone_s": [0, 100, 300, 800, 400]}
    assert P.effort_mode(z4z5)[0] == "flood"


def test_route_projection_fits_the_box_and_is_simplified():
    route = F.milos_trail()["route"]
    pts = P.project_route(route, 400, 300, pad=10)
    assert 2 < len(pts) < len(route)
    assert all(10 - 1e-6 <= x <= 390 + 1e-6 and 10 - 1e-6 <= y <= 290 + 1e-6 for x, y in pts)
    assert P.project_route([[1.0, 1.0]], 100, 100) == []


def test_weekly_fixture_is_consistent():
    from datetime import date
    w = F.weekly_recap()
    assert sum(sum(d["zone_s"]) for d in w["days"]) == w["duration_s"]
    assert abs(sum(d["distance_km"] for d in w["days"]) - w["distance_km"]) < 1e-9
    assert [date.fromisoformat(d["date"]).weekday() for d in w["days"]] == list(range(7))
    sg = F.singapore_intervals()
    assert w["days"][3]["date"] == sg["start_local"][:10] and w["days"][3]["zone_s"] == sg["zone_s"]


def test_fixture_runs_are_self_consistent_with_splits():
    for make in (F.singapore_intervals, F.milos_trail, F.slow_hot_day, F.pb_5k):
        r = make()
        assert sum(r["zone_s"]) == r["duration_s"] or abs(sum(r["zone_s"]) - r["duration_s"]) <= 1, make.__name__
        sp = r["splits"]
        assert abs(sum(s["km"] for s in sp) - r["distance_km"]) < 0.02
        assert abs(sum(s["km"] * s["pace_s"] for s in sp) - r["duration_s"]) < len(sp)
        assert all(1 <= s["zone"] <= 5 for s in sp)


def test_singapore_reps_match_the_story():
    reps = F.singapore_intervals()["reps"]
    times = [r["time_s"] for r in reps]
    assert len(reps) == 8 and sum(times) / 8 == 84 and times.index(min(times)) == 5 and min(times) == 81


def test_routeless_cards_reflow_with_no_placeholder():
    from render.cards.pb import build_pb_html
    for build, facts in ((build_post_run_html, F.milos_trail()), (build_post_run_html, F.singapore_intervals()), (build_pb_html, F.pb_5k())):
        html = _body(build(_noroute(facts), MEMORY))
        assert 'class="abs route"' not in html and "<path d=\"M" not in html.split('class="abs bars"')[0].split("</style>")[-1]
        assert 'class="abs bars"' in html and "<rect" in html
        assert 'class="abs route"' in _body(build(facts, MEMORY))


def test_cards_render_from_the_minimal_facts_the_server_stores():
    from render.cards.pb import build_pb_html
    for build, make in ((build_post_run_html, F.milos_trail), (build_post_run_html, F.singapore_intervals), (build_pb_html, F.pb_5k)):
        facts = _minimal(make())
        assert "route" not in facts and "splits" not in facts and "reps" not in facts
        html = _body(build(facts, MEMORY))
        assert 'class="abs route"' not in html and ">MIN<" in html.replace("MIN</span>", ">MIN<") and "Z5" in html
    # no HR at all: no zone_s either. It must still render, with the hero taking the space.
    bare = {k: v for k, v in _minimal(F.slow_hot_day()).items() if k != "zone_s"}
    assert "Z1" not in _body(build_post_run_html(bare, MEMORY))


def test_minimal_headline_numbers_come_from_the_stored_facts():
    import re
    spelled = re.compile(r"\b(one|two|three|four|five|six|seven|eight|nine|ten|first|second|third|fourth|fifth|twice|double|triple)\b", re.I)
    for make in (F.singapore_intervals, F.milos_trail, F.slow_hot_day, F.pb_5k):
        facts = _minimal(make())
        allowed = {f"{facts['distance_km']:.1f}", str(round(facts["duration_s"] / 60)), str(round(facts["distance_km"]))}
        for key in ("climb_m",):
            if facts.get(key):
                allowed.add(str(round(facts[key])))
        if facts.get("pace_s_per_km"):
            allowed.add(f"{int(facts['pace_s_per_km']) // 60}:{int(facts['pace_s_per_km']) % 60:02d}")
        allowed |= {str(round(s / 60)) for s in facts.get("zone_s", [])}
        for num in re.findall(r"\d+(?::\d+|\.\d+)?", facts["headline"]):
            assert num in allowed, (make.__name__, num)
        assert not spelled.search(facts["headline"]), facts["headline"]
        assert "reps" not in facts["headline"].lower()


def test_out_and_back_is_drawn_once():
    out = F._out_and_back(1.3, 103.86, 1250, seed=3)
    assert len(P.collapse_out_and_back(out)) == len(out) // 2 + 1
    loop = F.milos_trail()["route"]
    assert P.collapse_out_and_back(loop) is loop


def test_interval_card_shows_reps_not_average_pace():
    old_app = {k: v for k, v in F.singapore_intervals().items() if k != "work_pace_s_per_km"}
    html = _body(build_post_run_html(old_app, MEMORY))
    assert "BEST REP" in html and ">REPS<" in html and "/KM" not in html


def test_text_is_escaped():
    facts = F.milos_trail() | {"headline": "<script>alert(1)</script>"}
    html = build_post_run_html(facts, MEMORY)
    html = _body(html)
    assert "<script>alert" not in html and "&lt;script&gt;" in html


def test_copy_has_no_em_dashes():
    for facts in (F.singapore_intervals(), F.milos_trail(), F.slow_hot_day(), F.pb_5k()):
        assert "—" not in build_post_run_html(facts, MEMORY)


def test_share_card_without_opt_in_has_no_location_or_extras():
    facts = F.milos_trail()
    facts["share"] = {"time": True, "headline": "A good one."}
    html = _body(share_mod.build_share_html(facts, MEMORY))
    for leak in ("Milos", "Kastro", "Ricki", "RICKI", "SUN 27 SEP", "234 m"):
        assert leak not in html, leak
    assert 'stroke-linecap="round"' not in html  # no route drawn
    assert "CLIMB" not in html and "BPM" not in html


def test_share_card_ignores_the_post_run_headline():
    facts = F.milos_trail()
    facts["share"] = {}
    assert "Kastro" not in _body(share_mod.build_share_html(facts, MEMORY))


def test_share_card_shows_only_what_was_opted_in():
    html = _body(share_mod.build_share_html(F.share_opted_in(), MEMORY))
    assert "Milos" in html and "stroke-linecap" in html and "RICKI" in html.upper() and "CLIMB" in html


# --- goldens ---------------------------------------------------------------------------

def _noroute(facts):
    return {k: v for k, v in facts.items() if k != "route"}


# What the server stores (companion/media.py run_facts): no route, splits or reps, and pb_detail is only a label.
SERVER_KEYS = ("type", "start_local", "distance_km", "duration_s", "headline", "pace_s_per_km", "zone_s", "climb_m",
               "place_note", "verdict", "pb", "work_pace_s_per_km")


# The headline of a minimal card can only use what the stored facts hold: no reps, no place counts ("third time").
MINIMAL_HEADLINES = {"trail": "12.4 km and 234 m of climb.", "interval": "Hard session, 9.6 km done.", "long": "12.4 km and 234 m of climb.",
                     "race": "A new best.", "easy": "Slow, and fair enough."}


def _minimal(facts):
    out = {k: facts[k] for k in SERVER_KEYS if k in facts}
    out["headline"] = MINIMAL_HEADLINES[facts["type"]]
    if facts.get("pb"):
        out["pb_detail"] = {"label": facts["pb_detail"]["label"]}
    return out


def _with_shape(facts):
    """What the server holds for a run whose app sent a route shape, splits and (for intervals) rep times."""
    out = _minimal(facts) | {"route_xy": F.shape_xy(facts["route"]), "splits": facts["splits"]}
    if facts.get("reps"):
        out["reps"] = facts["reps"]
    return out


def test_interval_card_shows_work_pace_and_keeps_reps():
    facts = F.singapore_intervals()
    html = _body(build_post_run_html(facts, MEMORY))
    assert "3:30" in html and "/KM WORK" in html and "REPS" in html
    assert "BEST REP" not in html
    old = {k: v for k, v in facts.items() if k != "work_pace_s_per_km"}   # an old app: today's card
    html = _body(build_post_run_html(old, MEMORY))
    assert "BEST REP" in html and "/KM WORK" not in html


def test_work_pace_is_an_allowed_run_fact_and_not_a_week_fact():
    from render import protocol as PR
    assert "work_pace_s_per_km" in PR.ALLOWED_FACT_KEYS and "work_pace_s_per_km" in PR.RUN_KEYS
    assert "work_pace_s_per_km" not in PR.WEEK_KEYS


GOLDENS = {
    "post_run_singapore_intervals": ("render_post_run", F.singapore_intervals),
    "post_run_milos_trail": ("render_post_run", F.milos_trail),
    "post_run_light_noroute": ("render_post_run", lambda: _noroute(F.milos_trail())),
    "post_run_flood_noroute": ("render_post_run", lambda: _noroute(F.singapore_intervals())),
    "pb_noroute": ("render_pb", lambda: _noroute(F.pb_5k())),
    "post_run_light_minimal": ("render_post_run", lambda: _minimal(F.milos_trail())),
    "post_run_flood_minimal": ("render_post_run", lambda: _minimal(F.singapore_intervals())),
    "pb_minimal": ("render_pb", lambda: _minimal(F.pb_5k())),
    "post_run_light_shape": ("render_post_run", lambda: _with_shape(F.milos_trail())),
    "post_run_trail_shape": ("render_post_run", lambda: _with_shape(F.milos_trail_run())),
    "post_run_flood_shape": ("render_post_run", lambda: _with_shape(F.singapore_intervals())),
    "pb_shape": ("render_pb", lambda: _with_shape(F.pb_5k())),
    "post_run_slow_hot_day": ("render_post_run", F.slow_hot_day),
    "pb_5k": ("render_pb", F.pb_5k),
    "pb_half_marathon": ("render_pb", F.pb_marathon_half),
    "weekly_recap_big": ("render_weekly_recap", F.weekly_recap_big),
    "milestone_1000km": ("render_milestone", F.milestone_1000km),
    "milestone_100th": ("render_milestone", F.milestone_100th),
    "suggestion_easy_hot": ("render_suggestion", F.suggestion_easy_hot),
    "suggestion_tempo_rain": ("render_suggestion", F.suggestion_quality_rain),
    "weekly_recap": ("render_weekly_recap", F.weekly_recap),
    "race_countdown": ("render_race_countdown", F.race_countdown),
    "monthly_poster": ("render_monthly_poster", F.monthly_poster),
    "monthly_poster_noroute": ("render_monthly_poster", F.monthly_poster_noroute),
    "share_private": ("render_share_card", F.share_private),
    "share_opted_in": ("render_share_card", F.share_opted_in),
    "today_4x4": ("render_today", F.today_4x4),
    "today_easy_no_target": ("render_today", F.today_easy_no_target),
    "today_long_name": ("render_today", F.today_long_name),
    "today_miles": ("render_today", F.today_tempo_miles),
    "verdict_faster": ("render_today_verdict", F.verdict_faster),
    "verdict_slower": ("render_today_verdict", F.verdict_slower),
    "verdict_in_range": ("render_today_verdict", F.verdict_in_range),
    "verdict_pb": ("render_today_verdict", F.verdict_pb),
    "verdict_miles": ("render_today_verdict", F.verdict_miles),
    "moved_tempo_tired": ("render_moved", F.moved_tempo_tired),
    "moved_next_week_long_name": ("render_moved", F.moved_next_week_long_name),
    "moved_miles_no_reason": ("render_moved", F.moved_miles_no_reason),
    "pinned_week_midweek": ("render_pinned_week", F.pinned_week_midweek),
    "pinned_week_big_missed": ("render_pinned_week", F.pinned_week_big_missed),
    "pinned_week_miles": ("render_pinned_week", F.pinned_week_miles),
}
SIZES = {"monthly_poster": (1080, 1920), "monthly_poster_noroute": (1080, 1920)}


# RS_REQUIRE_RENDER=1 (set in CI) turns every "cannot render here" skip into a failure.
REQUIRE = os.environ.get("RS_REQUIRE_RENDER") == "1"
ACTUAL_DIR = os.environ.get("RS_ACTUAL_DIR")


def _need(module: str) -> None:
    if not REQUIRE:
        pytest.importorskip(module)
    else:
        __import__(module)


@pytest.fixture(scope="module")
def cards():
    _need("playwright")
    from render.cards import _engine
    try:
        _engine._ensure_browser()
    except _engine.RendererUnavailable as e:
        if REQUIRE:
            raise
        pytest.skip(str(e))
    import render.cards as C
    yield C
    _engine.close()


def _diff(a: bytes, b: bytes) -> tuple[float, float]:
    from io import BytesIO

    from PIL import Image, ImageChops
    ia, ib = Image.open(BytesIO(a)).convert("RGB"), Image.open(BytesIO(b)).convert("RGB")
    assert ia.size == ib.size, (ia.size, ib.size)
    d = ImageChops.difference(ia, ib).convert("L")
    hist = d.histogram()
    n = ia.size[0] * ia.size[1]
    mean = sum(i * c for i, c in enumerate(hist)) / n
    over = sum(hist[40:]) / n
    return mean, over


@pytest.mark.parametrize("name", sorted(GOLDENS))
def test_card_matches_golden(cards, name):
    _need("PIL")
    fn_name, make = GOLDENS[name]
    png = getattr(cards, fn_name)(make(), MEMORY)
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    path = GOLDEN_DIR / f"{name}.png"
    if ACTUAL_DIR:  # CI publishes these so goldens can be regenerated from CI output (also when a golden is missing)
        Path(ACTUAL_DIR).mkdir(parents=True, exist_ok=True)
        (Path(ACTUAL_DIR) / f"{name}.png").write_bytes(png)
    if REQUIRE and not path.exists():
        pytest.fail(f"no golden for {name}")
    if os.environ.get("RS_UPDATE_GOLDENS") == "1" or not path.exists():
        GOLDEN_DIR.mkdir(exist_ok=True)
        path.write_bytes(png)
        pytest.skip(f"golden written: {path.name}")
    mean, over = _diff(png, path.read_bytes())
    # anti-aliasing and font hinting differ a little between hosts; layout or colour changes do not hide in this
    assert mean < 0.6 and over < 0.004, f"{name}: mean {mean:.3f}, over {over:.4f}"


def test_trail_card_leads_with_the_route_when_the_shape_is_there():
    """A `trail` run is drawn like any other: the route under the headline, splits only when there is no route. The
    route is only there when the app sent it, which its "Show route shape on cards" switch controls."""
    with_shape = _with_shape(F.milos_trail_run())
    assert with_shape["type"] == "trail"
    html = _body(build_post_run_html(with_shape, MEMORY))
    assert 'class="abs route"' in html and 'class="abs bars"' not in html
    assert "TRAIL RUN" in html.upper() and "234 m" in html
    no_shape = {k: v for k, v in with_shape.items() if k != "route_xy"}
    html = _body(build_post_run_html(no_shape, MEMORY))
    assert 'class="abs route"' not in html and 'class="abs bars"' in html


def test_poster_size(cards):
    from io import BytesIO

    from PIL import Image
    assert Image.open(BytesIO(cards.render_monthly_poster(F.monthly_poster(), MEMORY))).size == (1080, 1920)
    for fn, make in ((cards.render_milestone, F.milestone_1000km), (cards.render_pb, F.pb_5k), (cards.render_share_card, F.share_private)):
        assert Image.open(BytesIO(fn(make(), MEMORY))).size == (1080, 1350)
    assert Image.open(BytesIO(cards.render_race_countdown(F.race_countdown(), MEMORY))).size == (1080, 1350)


def test_share_card_shows_pace_by_default_and_the_runner_can_turn_it_off():
    facts = F.milos_trail()
    for share, shown in (({}, True), ({"pace": True}, True), ({"pace": False}, False)):
        html = _body(share_mod.build_share_html({**facts, "share": share}, MEMORY))
        assert ("/KM" in html) is shown, share
    # intervals: the reps replace the session's average pace, whatever the option says
    # (the work pace, labelled /KM WORK, sits beside the reps when the app sent it)
    iv = F.singapore_intervals()
    old = {k: v for k, v in iv.items() if k != "work_pace_s_per_km"}
    assert "/KM WORK" in _body(share_mod.build_share_html({**iv, "share": {"reps": True}}, MEMORY))
    assert "/KM" not in _body(share_mod.build_share_html({**old, "share": {"reps": True}}, MEMORY))
    assert "/KM" not in _body(share_mod.build_share_html({**iv, "share": {"pace": True}}, MEMORY))


def test_weekly_card_shows_average_and_quickest_pace_only_when_given():
    from render.cards import weekly
    w = F.weekly_recap()
    html = _body(weekly.build_weekly_html(w, MEMORY))
    assert P.fmt_pace(w["pace_s_per_km"]) in html and "AVG /KM" in html
    assert P.fmt_pace(w["quickest_pace_s_per_km"]) in html and "QUICKEST" in html
    bare = {k: v for k, v in w.items() if "pace" not in k}
    html = _body(weekly.build_weekly_html(bare, MEMORY))
    assert "/KM" not in html and "QUICKEST" not in html


def test_monthly_poster_shows_the_months_average_pace_in_both_layouts():
    from render.cards import monthly
    for facts, build in ((F.monthly_poster_noroute(), monthly.build_monthly_calendar_html),
                         (F.monthly_poster(), monthly.build_monthly_html)):
        html = _body(build(facts, MEMORY))
        assert P.fmt_pace(facts["duration_s"] / facts["distance_km"]) in html and "AVG /KM" in html
    no_time = {**F.monthly_poster_noroute(), "duration_s": 0}
    assert "AVG /KM" not in _body(monthly.build_monthly_calendar_html(no_time, MEMORY))


def test_zone_bar_has_the_same_margins_on_every_minimal_card():
    PIL = pytest.importorskip("PIL.Image")
    spans = []
    for name, y in (("post_run_light_minimal", 840), ("post_run_flood_minimal", 840), ("pb_minimal", 840)):
        im = PIL.open(GOLDEN_DIR / f"{name}.png").convert("RGB")
        bg = im.getpixel((5, y))
        xs = [x for x in range(im.width) if sum(abs(a - b) for a, b in zip(im.getpixel((x, y)), bg)) > 60]
        spans.append((min(xs), max(xs)))
    assert all(abs(s[0] - spans[0][0]) <= 2 and abs(s[1] - spans[0][1]) <= 2 for s in spans), spans


def test_route_less_poster_draws_one_bar_per_stored_run():
    import re

    from render.cards import monthly
    facts = F.monthly_poster_noroute()
    assert not any("route" in r for r in facts["runs"]) and not monthly.has_routes(facts)
    html = monthly.build_monthly_calendar_html(facts, MEMORY)
    assert html.count('class="abs run"') == len(facts["runs"]) == facts["run_count"]
    grid = html[html.index('class="abs grid"'):html.index('class="abs legend"')]
    assert "<svg" not in grid                                        # no route shapes, only bars from stored numbers
    for r in facts["runs"]:                                          # each bar carries its run's type and distance
        assert f'data-type="{r["type"]}" data-km="{r["distance_km"]:.1f}"' in html
    for t in ("EASY", "LONG", "TEMPO", "INTERVAL / RACE"):           # legend lists the types present
        assert t in html.upper()
    # bar height follows distance: the 15.5 km long run is taller than the 3 km easy run
    h = {m[0]: float(m[1]) for m in re.findall(r'data-km="([\d.]+)" style="[^"]*?height:([\d.]+)px', html)}
    assert h["15.5"] > h["3.0"] > 0
    assert monthly.has_routes(F.monthly_poster())                   # the route layout is still used when routes are supplied


def test_countdown_fixture_matches_the_simulated_race():
    from datetime import date

    from companion.convo.sim import RACE_DAY
    f = F.race_countdown()
    assert RACE_DAY.strftime("%A") == "Sunday"
    assert f["race_line"].startswith(f"Sunday {RACE_DAY.day} {RACE_DAY:%b}.")
    assert (RACE_DAY - date(2026, 10, 6)).days == f["days_to_race"] and f["race_name"] == "Half Marathon"
    assert f["days_to_race"] // 7 == 8      # the 6 Oct card says "8 weeks to go"


def test_work_pace_fact_is_range_checked_by_the_worker():
    from render import protocol as PR
    base = {"type": "interval", "distance_km": 9.6, "duration_s": 3170}
    assert PR._shapes_ok({**base, "work_pace_s_per_km": 257.1})
    for bad in ("fast", True, 10, 99999, float("nan")):
        assert not PR._shapes_ok({**base, "work_pace_s_per_km": bad})
