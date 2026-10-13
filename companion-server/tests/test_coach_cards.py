"""Coach cards (today, today_verdict, moved, pinned_week): the worker's strict fact contract, escaping, colour meanings
and the edge cases (long names, 10+ hour weeks, a missed day, miles). The pixel goldens live in test_render_cards.py."""
from __future__ import annotations

import pytest

from render import brand
from render import protocol as PR
from render.cards import fixtures as F
from render.cards.coach import (build_moved_html, build_pinned_week_html, build_today_html, build_today_verdict_html)

KINDS = {
    "today": [F.today_4x4, F.today_easy_no_target, F.today_long_name, F.today_tempo_miles],
    "today_verdict": [F.verdict_faster, F.verdict_slower, F.verdict_in_range, F.verdict_pb, F.verdict_miles],
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
    # the caller sends a pace, never a verdict word: a result inside the band is never faster or slower
    for result, word in ((254, "FASTER"), (255, "IN RANGE"), (260, "IN RANGE"), (261, "SLOWER")):
        assert word in build_today_verdict_html(F.today_4x4() | {"result_pace_s": result}, {})


def test_violet_is_never_used():
    for kind, makers in KINDS.items():
        for make in makers:
            html = BUILD[kind](make(), {}).lower()
            assert brand.VIOLET.lower() not in html and brand.ON_VIOLET_SOFT.lower() not in html


def test_today_shows_the_target_and_the_verdict_shows_both():
    t = _body(build_today_html(F.today_4x4(), {}))
    assert "4:15-4:20" in t and "/KM WORK" in t and "TODAY" in t and "YOU RAN" not in t
    v = _body(build_today_verdict_html(F.verdict_faster(), {}))
    assert "4:15-4:20" in v and "4:14" in v and "YOU RAN" in v and "DONE" in v


def test_a_card_with_no_target_still_renders_without_a_placeholder():
    t = _body(build_today_html(F.today_easy_no_target(), {}))
    assert "TARGET" not in t and "Easy run" in t
    v = _body(build_today_verdict_html(F.today_easy_no_target() | {"result_pace_s": 330}, {}))
    assert "YOU RAN" not in v      # no band to judge against, so no verdict colour is invented


def test_miles_convert_distance_pace_and_units():
    t = _body(build_today_html(F.today_tempo_miles(), {}))
    assert "8:59-9:15" in t and "/MI WORK" in t and ">6<" in t and ">MI<" in t and ">KM<" not in t
    v = _body(build_today_verdict_html(F.verdict_miles(), {}))
    assert "8:46" in v and "13 s/mi FASTER" in v
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
