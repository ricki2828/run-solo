"""Coach cards (today, today_verdict, moved, pinned_week): the worker's strict fact contract, escaping, colour meanings
and the edge cases (long names, 10+ hour weeks, a missed day, miles). The pixel goldens live in test_render_cards.py."""
from __future__ import annotations

import pytest

from render import brand
from render import protocol as PR
from render.cards import fixtures as F
from render.cards.coach import (build_moved_html, build_pinned_week_html, build_today_html, build_today_verdict_html)

KINDS = {
    "today": [F.today_two_digit_km, F.today_two_digit_mi, F.today_4x4, F.today_easy_no_target, F.today_long_name, F.today_tempo_miles, F.today_easy_hr_ceiling, F.today_bare],
    "today_verdict": [F.verdict_two_digit_km, F.verdict_two_digit_mi, F.verdict_enum_small_gap_faster,
                      F.verdict_enum_big_gap_in_range, F.verdict_no_target, F.verdict_faster, F.verdict_slower, F.verdict_in_range, F.verdict_pb, F.verdict_miles],
    "moved": [F.moved_tempo_tired, F.moved_next_week_long_name, F.moved_miles_no_reason],
    "pinned_week": [F.pinned_week_midweek, F.pinned_week_big_missed, F.pinned_week_miles],
}
BUILD = {"today": build_today_html, "today_verdict": build_today_verdict_html, "moved": build_moved_html,
         "pinned_week": build_pinned_week_html}


def _body(html: str) -> str:
    return html.split("</style>", 1)[1]


def _req(kind, facts):
    return {"v": 1, "op": "card", "kind": kind, "facts": facts}


@pytest.mark.parametrize("kind", sorted(KINDS))
def test_every_fixture_passes_the_worker_contract_and_builds(kind):
    for make in KINDS[kind]:
        PR.check_request(_req(kind, make()))
        html = _body(BUILD[kind](make(), {}))
        assert "—" not in html and "undefined" not in html and "None" not in html


def test_kinds_are_registered_with_their_own_key_lists():
    for kind in KINDS:
        assert kind in PR.OP_KINDS["card"] and kind in PR.KIND_FACT_KEYS
    assert PR.KIND_FACT_KEYS["today"] < PR.KIND_FACT_KEYS["today_verdict"]


@pytest.mark.parametrize("kind,bad", [
    ("today", {"place_note": "Takapuna"}), ("today", {"route_xy": [[1, 1], [2, 2]]}), ("today", {"reason": "free text"}),
    ("today", {"result_pace_s": 250}),                                    # a result belongs on today_verdict only
    ("today", {"type": "walk"}), ("today", {"units": "furlong"}), ("today", {"session": "x" * 33}),
    ("today", {"session": ""}), ("today", {"target_pace_lo_s": 300, "target_pace_hi_s": 250}),
    ("today", {"target_pace_lo_s": 10}), ("today", {"distance_km": True}), ("today", {"target_kind": "free"}),
    ("today_verdict", {"pb": "5k"}), ("today_verdict", {"result_pace_s": 99999}),
    ("moved", {"skip_reason": "my knee hurts"}), ("moved", {"to_day": "someday"}), ("moved", {"from_day": "next_week"}),
    ("moved", {"reason": "Tired"}),
    ("pinned_week", {"today_idx": 7}), ("pinned_week", {"days": []}), ("pinned_week", {"days": [{"type": "easy"}] * 8}),
    ("pinned_week", {"days": [{"type": "easy", "note": "sore knee"}]}),
    ("pinned_week", {"days": [{"type": "easy", "done_km": -1}]}), ("pinned_week", {"days": [{"type": "easy", "done_km": "9"}]}),
    ("pinned_week", {"days": [{"type": "easy", "planned_km": float("nan")}]}),
])
def test_worker_refuses_anything_outside_the_strict_facts(kind, bad):
    base = {"today": F.today_4x4, "today_verdict": F.verdict_faster, "moved": F.moved_tempo_tired,
            "pinned_week": F.pinned_week_midweek}[kind]()
    with pytest.raises(PR.ProtocolError):
        PR.check_request(_req(kind, base | bad))


def test_required_facts_are_enforced():
    for kind, key in (("today", "session"), ("moved", "to_day"), ("pinned_week", "days"), ("today_verdict", "type")):
        facts = {"today": F.today_4x4, "moved": F.moved_tempo_tired, "pinned_week": F.pinned_week_midweek,
                 "today_verdict": F.verdict_faster}[kind]()
        facts.pop(key)
        with pytest.raises(PR.ProtocolError):
            PR.check_request(_req(kind, facts))


def test_encode_request_roundtrips_a_coach_card():
    assert PR.encode_request("card", "pinned_week", F.pinned_week_big_missed())


def test_text_is_escaped_everywhere():
    evil = "<img src=x onerror=alert(1)>"
    for kind, make in (("today", F.today_4x4), ("today_verdict", F.verdict_faster), ("moved", F.moved_tempo_tired)):
        html = _body(BUILD[kind](make() | {"session": evil}, {}))
        assert "<img src=x" not in html and "&lt;img" in html, kind
    html = _body(build_pinned_week_html(F.pinned_week_midweek() | {"week_label": evil}, {}))
    assert "<img src=x" not in html and "&lt;img" in html


def test_the_lane_colour_follows_the_session_type():
    for kind, lane in (("easy", "aerobic"), ("interval", "speed"), ("tempo", "mid"), ("long", "long")):
        html = build_today_html(F.today_4x4() | {"type": kind}, {})
        assert f"background:{brand.LANE[lane]}" in html, kind


def test_verdict_colours_follow_the_numbers():
    faster, slower = build_today_verdict_html(F.verdict_faster(), {}), build_today_verdict_html(F.verdict_slower(), {})
    inside, pb = build_today_verdict_html(F.verdict_in_range(), {}), build_today_verdict_html(F.verdict_pb(), {})
    assert f"background:{brand.MINT}" in faster and "FASTER" in faster and brand.VERMILLION not in faster
    assert f"background:{brand.VERMILLION}" in slower and "SLOWER" in slower and brand.MINT not in slower
    assert "IN RANGE" in inside and brand.MINT not in inside and brand.VERMILLION not in inside and brand.ARC not in inside
    assert f"color:{brand.ARC}" in pb and "A NEW BEST" in pb
    for html in (faster, slower, inside):                       # cyan is for a PB only
        assert brand.ARC not in html


def test_the_verdict_cannot_disagree_with_its_numbers():
    # band 4:15-4:20 (255-260). The caller sends a pace, never a verdict word. Outside the band by under the noise
    # floor (10 s/km) is noise, so it reads IN RANGE in the neutral colour; the colours need the full 10 s.
    from render.cards.coach import NOISE_FLOOR_S
    assert NOISE_FLOOR_S == 10
    cases = ((235, "FASTER"), (245, "FASTER"), (246, "IN RANGE"), (254, "IN RANGE"), (255, "IN RANGE"), (260, "IN RANGE"),
             (261, "IN RANGE"), (269, "IN RANGE"), (270, "SLOWER"), (290, "SLOWER"))
    for result, word in cases:
        html = build_today_verdict_html(F.today_4x4() | {"result_pace_s": result}, {})
        assert word in _body(html), (result, word)
        assert (brand.MINT in html) == (word == "FASTER") and (brand.VERMILLION in html) == (word == "SLOWER"), result


def test_one_second_per_km_is_noise_not_a_win():
    html = _body(build_today_verdict_html(F.today_4x4() | {"result_pace_s": 254}, {}))
    assert "IN RANGE" in html and "FASTER" not in html and "1 s/km" not in html and brand.MINT not in html


def test_just_outside_the_range_is_still_in_range_until_the_noise_floor():
    just_out = build_today_verdict_html(F.today_4x4() | {"result_pace_s": 269}, {})     # 9 s/km over the band
    assert "IN RANGE" in just_out and brand.VERMILLION not in just_out
    at_floor = build_today_verdict_html(F.today_4x4() | {"result_pace_s": 270}, {})      # 10 s/km over
    assert "10 s/km SLOWER" in at_floor and f"background:{brand.VERMILLION}" in at_floor


def test_the_fallback_floor_is_the_engines_base_floor():
    import re
    from pathlib import Path
    from render.cards.coach import NOISE_FLOOR_S
    consts = (Path(__file__).resolve().parents[2] / "packages/run_engine/lib/src/engine/constants.dart").read_text()
    assert int(re.search(r"this\.runFloorSecPerKm = (\d+)", consts).group(1)) == NOISE_FLOOR_S


def test_violet_is_never_used():
    for kind, makers in KINDS.items():
        for make in makers:
            html = BUILD[kind](make(), {}).lower()
            assert brand.VIOLET.lower() not in html and brand.ON_VIOLET_SOFT.lower() not in html


def test_today_shows_the_target_and_the_verdict_shows_both():
    t = _body(build_today_html(F.today_4x4(), {}))
    assert "4:15-4:20" in t and "/KM WORK" in t and "TODAY" in t and "YOU RAN" not in t
    v = _body(build_today_verdict_html(F.verdict_faster(), {}))
    assert "4:15-4:20" in v and "4:03" in v and "YOU RAN" in v and "DONE" in v


def test_an_easy_card_shows_the_sessions_own_guide_in_the_lower_plate():
    t = _body(build_today_html(F.today_easy_no_target(), {}))
    assert "TARGET" not in t and "GUIDE" in t and "ZONE 2" in t and "CHATTY PACE" in t
    hr = _body(build_today_html(F.today_easy_hr_ceiling(), {}))
    assert "KEEP IT UNDER" in hr and ">148<" in hr and "BPM" in hr and "ZONE" not in hr      # a measured ceiling wins
    v = _body(build_today_verdict_html(F.today_easy_no_target() | {"result_pace_s": 330}, {}))
    assert "YOU RAN" in v and "FASTER" not in v and "SLOWER" not in v      # no band to judge against: no verdict colour invented


def test_a_bare_card_with_no_target_or_guide_keeps_one_block_and_no_placeholder():
    t = _body(build_today_html(F.today_bare(), {}))
    assert "TARGET" not in t and "GUIDE" not in t and "KEEP IT UNDER" not in t and "Easy run" in t


def test_guide_and_hr_ceiling_are_strict_enum_and_number():
    PR.check_request(_req("today", F.today_easy_hr_ceiling()))
    for bad in ({"guide": "feel it out"}, {"hr_ceiling_bpm": 30}, {"hr_ceiling_bpm": 148.5}, {"hr_ceiling_bpm": "148"}):
        with pytest.raises(PR.ProtocolError):
            PR.check_request(_req("today", F.today_easy_no_target() | bad))
    with pytest.raises(PR.ProtocolError):
        PR.check_request(_req("moved", F.moved_tempo_tired() | {"guide": "chatty"}))


def test_miles_convert_distance_pace_and_units():
    t = _body(build_today_html(F.today_tempo_miles(), {}))
    assert "8:59-9:15" in t and "/MI WORK" in t and ">6<" in t and ">MI<" in t and ">KM<" not in t
    v = _body(build_today_verdict_html(F.verdict_miles(), {}))
    assert "8:38" in v and "21 s/mi FASTER" in v
    m = _body(build_moved_html(F.moved_miles_no_reason(), {}))
    assert "12 MI" in m
    w = _body(build_pinned_week_html(F.pinned_week_miles(), {}))
    assert "5.2" in w and "MI PLANNED" in w and "MI TO GO" in w


def test_long_session_names_shrink_instead_of_overflowing():
    short = build_today_html(F.today_4x4() | {"session": "Tempo"}, {})
    longer = build_today_html(F.today_long_name(), {})
    size = lambda h: int(h.split("class=\"abs saira head\" style=\"")[1].split("font-size:")[1].split("px")[0])  # noqa: E731
    assert size(short) > size(longer) >= 80


def test_moved_card_shows_only_fixed_reason_labels():
    assert "TIRED" in build_moved_html(F.moved_tempo_tired(), {})
    assert "TRAVELLING" in build_moved_html(F.moved_next_week_long_name(), {})
    no_reason = _body(build_moved_html(F.moved_miles_no_reason(), {}))
    assert "SUN" in no_reason and "WAS" not in no_reason
    assert "NEXT" in _body(build_moved_html(F.moved_next_week_long_name(), {}))
    assert "moved to" in _body(build_moved_html(F.moved_tempo_tired(), {})).lower()


def test_pinned_week_totals_come_from_the_days():
    w = _body(build_pinned_week_html(F.pinned_week_midweek(), {}))
    assert "8.4" in w and "OF 37.4 KM PLANNED" in w and "1/4" in w and "1:32:40" in w
    assert "29.0" in w          # still to go: 6 today + 9 + 14, nothing from the finished Tuesday


def test_pinned_week_big_week_and_missed_day():
    w = _body(build_pinned_week_html(F.pinned_week_big_missed(), {}))
    assert "12:31:45" in w and "45.0" in w and "OF 96.0 KM PLANNED" in w
    assert w.count("MISSED") == 1 and "4/7" in w       # Tuesday missed; the unplanned rest-day run counts as a run
    assert "stroke-dasharray" in w


def test_pinned_week_without_a_missed_day_draws_no_missed_mark():
    assert "MISSED" not in _body(build_pinned_week_html(F.pinned_week_midweek(), {}))


def test_pinned_week_handles_a_week_with_nothing_planned_or_run():
    html = _body(build_pinned_week_html({"week_label": "Week 1", "days": [{"type": "rest"}]}, {}))
    assert "0.0" in html and "0/0" in html and "PLANNED" not in html


def test_the_worker_dispatches_every_coach_kind():
    from render import worker
    import inspect
    src = inspect.getsource(worker._render_one)
    for kind in KINDS:
        assert f'"{kind}"' in src


def test_render_checkin_returns_media_or_none_and_never_raises():
    from companion.media import CHECKIN_KINDS, MediaRenderer
    assert CHECKIN_KINDS == tuple(KINDS)
    seen = []
    fns = {k: (lambda facts, memory=None, k=k: seen.append(k) or b"\x89PNG-fake") for k in CHECKIN_KINDS}
    r = MediaRenderer(card_fns=fns)
    for kind, makers in KINDS.items():
        m = r.render_checkin(kind, makers[0]())
        assert m is not None and m.photo == b"\x89PNG-fake"
    assert seen == list(KINDS)
    assert r.render_checkin("suggestion", {}) is None and r.render_checkin("nope", {}) is None

    def boom(facts, memory=None):
        raise RuntimeError("worker down")
    assert MediaRenderer(card_fns={"today": boom}).render_checkin("today", F.today_4x4()) is None
    assert MediaRenderer(card_fns={"today": lambda f, m=None: b""}).render_checkin("today", F.today_4x4()) is None


def test_the_today_card_never_prints_a_clock_time():
    html = _body(build_today_html(F.today_4x4(), {}))
    assert "06:45" not in html and "6:45" not in html


def test_the_callers_verdict_beats_the_pace_rule():
    small = build_today_verdict_html(F.verdict_enum_small_gap_faster(), {})       # 3 s/km under: flat floor says in range
    assert f"background:{brand.MINT}" in small and "3 s/km FASTER" in _body(small)
    big = build_today_verdict_html(F.verdict_enum_big_gap_in_range(), {})         # 15 s/km under: flat floor says faster
    assert "IN RANGE" in _body(big) and brand.MINT not in big and brand.VERMILLION not in big
    for verdict, ground in (("faster", brand.MINT), ("slower", brand.VERMILLION), ("in_range", brand.INK)):
        html = build_today_verdict_html(F.today_4x4() | {"result_pace_s": 257, "verdict": verdict}, {})
        assert f"background:{ground}" in html, verdict
    assert brand.ARC in build_today_verdict_html(F.today_4x4() | {"result_pace_s": 257, "verdict": "pb"}, {})
    # a verdict with the result inside the band says the bare word, never a made-up gap
    assert "0 s/km" not in _body(build_today_verdict_html(F.today_4x4() | {"result_pace_s": 257, "verdict": "faster"}, {}))


def test_the_pace_rule_only_applies_when_there_is_no_verdict():
    assert "IN RANGE" in _body(build_today_verdict_html(F.today_4x4() | {"result_pace_s": 250}, {}))   # 5 s under
    assert "10 s/km FASTER" in _body(build_today_verdict_html(F.today_4x4() | {"result_pace_s": 245}, {}))


def test_verdict_enum_is_strict():
    PR.check_request(_req("today_verdict", F.verdict_enum_small_gap_faster()))
    for bad in ("fast", "holding", ["faster"], {"a": 1}, 1, True):
        with pytest.raises(PR.ProtocolError):
            PR.check_request(_req("today_verdict", F.verdict_faster() | {"verdict": bad}))
    with pytest.raises(PR.ProtocolError):
        PR.check_request(_req("today", F.today_4x4() | {"verdict": "faster"}))      # a verdict needs a result


@pytest.mark.parametrize("key,bad", [("type", ["easy"]), ("units", {"a": 1}), ("skip_reason", ["tired"]), ("to_day", ["mon"]),
                                     ("from_day", {"x": 1}), ("guide", ["chatty"]), ("target_kind", ["work"])])
def test_unhashable_enum_values_are_a_clean_refusal(key, bad):
    facts = {"type": "easy", "session": "Easy run", "to_day": "tue", "units": "km", "target_kind": "work",
             "guide": "chatty", "from_day": "mon", "skip_reason": "busy"}
    kind = "moved" if key in ("skip_reason", "to_day", "from_day") else "today"
    keep = PR.KIND_FACT_KEYS[kind]
    facts = {k: v for k, v in facts.items() if k in keep} | {key: bad}
    with pytest.raises(PR.ProtocolError) as e:
        PR.check_request(_req(kind, facts))
    assert e.value.code == "bad_request"
    with pytest.raises(PR.ProtocolError):
        PR.check_request(_req("pinned_week", {"days": [{"type": ["easy"]}]}))


def test_two_digit_minute_paces_get_a_smaller_figure():
    import re
    size = lambda h, cls: int(re.search(rf'class="saira {cls}" style="font-size:(\d+)px', h).group(1))  # noqa: E731
    wide = _body(build_today_html(F.today_two_digit_mi(), {}))
    normal = _body(build_today_html(F.today_4x4(), {}))
    assert "12:30-13:10" in wide and "/MI" in wide and size(wide, "tgt") < size(normal, "tgt") == 230
    narrow = _body(build_today_verdict_html(F.verdict_two_digit_mi(), {}))
    base = _body(build_today_verdict_html(F.verdict_faster(), {}))
    assert size(narrow, "tgt") < size(base, "tgt") and size(narrow, "ran") < size(base, "ran")
    assert "13:57" in narrow


def test_a_result_with_no_target_still_shows_neutral():
    v = _body(build_today_verdict_html(F.verdict_no_target(), {}))
    assert "YOU RAN" in v and "5:45" in v and "FASTER" not in v and "SLOWER" not in v and "IN RANGE" not in v
    assert brand.MINT not in v and brand.VERMILLION not in v


def test_the_moved_headline_is_clamped_to_two_lines_and_shrinks():
    long = F.moved_next_week_long_name() | {"session": "x" * 32}
    html = build_moved_html(long, {})
    assert "-webkit-line-clamp:2" in html and "font-size:64px" in html.split("saira head")[1][:200]
