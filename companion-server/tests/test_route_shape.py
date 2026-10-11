"""The route shape, per-km splits and rep times the app sends for richer cards and the run videos.

Nothing here needs Chromium or ffmpeg: cards are checked as HTML, videos as specs, and the worker is a fake on a real
unix socket that applies the real protocol checks. The real renderers run in the card, motion and worker suites.
"""
import json
import os
import socket
import sqlite3
import tempfile
import threading
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import db
from companion.app import create_app
from companion.media import Media, MediaRenderer, run_facts, video_facts
from companion.service import RunIn
from companion.timeutil import now_utc
from conftest import auth, enrol, make_settings, run_payload, shape_payload, shape_route
from render import protocol as P

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64
MP4 = b"\x00\x00\x00\x18ftypmp42" + b"0" * 64


def post(client, token, **fields):
    return client.post("/v1/runs", json=run_payload("r1", **fields), headers=auth(token))


def tables(client, sql, *args):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in c.execute(sql, args)]
    finally:
        c.close()


# --- validation ------------------------------------------------------------------------------

def test_a_good_shape_is_accepted_and_stored_beside_the_run(client):
    t = enrol(client)
    r = post(client, t, **shape_payload(reps=True))
    assert r.status_code == 202, r.text
    (row,) = tables(client, "SELECT * FROM run_shape")
    assert json.loads(row["route_json"]) == shape_route()
    assert len(json.loads(row["splits_json"])) == 7 and len(json.loads(row["reps_json"])) == 6
    # never in the runs table, where a SELECT * could carry it into a prompt
    cols = [c["name"] for c in tables(client, "PRAGMA table_info(runs)")]
    assert not {"route", "route_json", "splits", "splits_json", "reps", "reps_json"} & set(cols)


def test_all_three_are_optional(client):
    t = enrol(client)
    assert post(client, t).status_code == 202
    assert tables(client, "SELECT COUNT(*) n FROM run_shape")[0]["n"] == 0
    only_splits = {"splits": shape_payload()["splits"]}
    assert client.post("/v1/runs", json=run_payload("x", **only_splits), headers=auth(t)).status_code == 202
    assert client.post("/v1/runs", json=run_payload("y", reps=[{"time_s": 80}]), headers=auth(t)).status_code == 202


def bad_routes():
    good = shape_route()
    yield "float coordinates", [[1.3631, 103.8478], [1.3640, 103.8490]]
    yield "whole floats", [[0.0, 0.0], [255.0, 100.0]]
    yield "latitude-sized ints", [[0, 0], [255, 1300]]
    yield "negative", [[-1, 0], [255, 10]]
    yield "over the grid", [[0, 0], [256, 10]]
    yield "one point", [[0, 0]]
    yield "empty", []
    yield "121 points", (good * 3)[:121]
    yield "three numbers", [[0, 0, 5], [255, 10, 5]]
    yield "one number", [[0], [255]]
    yield "strings", [["0", "0"], ["255", "10"]]
    yield "bools", [[False, False], [True, True]]
    yield "not translated to the origin", [[10, 10], [255, 200]]
    yield "not scaled to the grid", [[0, 0], [100, 50]]
    yield "a number, not a list", 5


@pytest.mark.parametrize("name,route", list(bad_routes()), ids=lambda v: v if isinstance(v, str) else "")
def test_bad_routes_are_refused(client, name, route):
    t = enrol(client)
    assert post(client, t, route=route).status_code == 422, name
    assert tables(client, "SELECT COUNT(*) n FROM run_shape")[0]["n"] == 0
    assert tables(client, "SELECT COUNT(*) n FROM runs")[0]["n"] == 0   # the whole run is refused, nothing half-stored


def test_120_points_is_the_most_a_route_can_have(client):
    t = enrol(client)
    ok = [[i, 0] for i in range(120)]
    ok[-1] = [255, 255]
    ok[0] = [0, 0]
    assert post(client, t, route=ok).status_code == 202


def bad_splits():
    one = {"km": 1.0, "pace_s": 342.0, "zone": 3}
    yield "no splits", []
    yield "km zero", [{**one, "km": 0}]
    yield "km over one", [{**one, "km": 1.5}]
    yield "pace too fast", [{**one, "pace_s": 59}]
    yield "pace too slow", [{**one, "pace_s": 3601}]
    yield "zone 0", [{**one, "zone": 0}]
    yield "zone 6", [{**one, "zone": 6}]
    yield "extra key", [{**one, "lat": 1.3}]
    yield "101 splits", [one] * 101
    yield "longer than the run", [one] * 9
    yield "text pace", [{**one, "pace_s": "fast"}]


@pytest.mark.parametrize("name,splits", list(bad_splits()), ids=lambda v: v if isinstance(v, str) else "")
def test_bad_splits_are_refused(client, name, splits):
    t = enrol(client)
    assert post(client, t, splits=splits).status_code == 422, name


@pytest.mark.parametrize("name,reps", [
    ("none", []), ("zero time", [{"time_s": 0}]), ("an hour and a second", [{"time_s": 3601}]),
    ("zone 9", [{"time_s": 80, "zone": 9}]), ("extra key", [{"time_s": 80, "note": "sore"}]),
    ("61 reps", [{"time_s": 80}] * 61)])
def test_bad_reps_are_refused(client, name, reps):
    t = enrol(client)
    assert post(client, t, reps=reps).status_code == 422, name


def test_zone_is_optional_for_a_run_with_no_heart_rate(client):
    t = enrol(client)
    assert post(client, t, splits=[{"km": 1.0, "pace_s": 342.0}] * 7, reps=[{"time_s": 80}]).status_code == 202
    (row,) = tables(client, "SELECT splits_json, reps_json FROM run_shape")
    assert "zone" not in row["splits_json"] and "zone" not in row["reps_json"]


def test_the_biggest_allowed_run_still_fits_the_8_kb_request_limit(client):
    """120 points, 100 splits, 60 reps, as the phone encodes them (compact, one decimal)."""
    t = enrol(client)
    route = [[i % 256, 0] for i in range(120)]
    route[0], route[1], route[-1] = [0, 0], [255, 255], [255, 255]
    body = run_payload("big", distance_m=100000, duration_s=36000, pace_s_per_km=360.0, true_pace_s_per_km=358.0,
                       locality="Kallang", climb_m=1200, zone_min={"z1": 1.5, "z2": 2.5, "z3": 3.5, "z4": 4.5, "z5": 5.5},
                       route=route, splits=[{"km": 1.0, "pace_s": 360.0, "zone": 4}] * 100,
                       reps=[{"time_s": 3599.9, "zone": 5}] * 60)
    raw = json.dumps(body, separators=(",", ":")).encode()
    assert len(raw) < 8 * 1024, len(raw)
    r = client.post("/v1/runs", content=raw, headers={**auth(t), "content-type": "application/json"})
    assert r.status_code == 202, r.text


# --- export and delete -----------------------------------------------------------------------

def test_me_shows_the_shape_the_server_holds(client):
    t = enrol(client)
    post(client, t, **shape_payload(reps=True))
    me = client.get("/v1/me", headers=auth(t)).json()
    (shape,) = me["run_shapes"]
    assert shape["run_id"] == "r1" and shape["route"] == shape_route()
    assert len(shape["splits"]) == 7 and shape["reps"][0] == {"time_s": 84.0, "zone": 5}
    assert me["profile"]["route_shape_on_cards"] is True
    assert "route_json" not in json.dumps(me["runs_received"])


def test_delete_everything_leaves_no_shape_anywhere(client):
    t = enrol(client)
    post(client, t, **shape_payload(
        reps=True, splits=[{"km": 1.0, "pace_s": 342.8571, "zone": 3}] * 7))
    path = client.svc.s.db_path
    assert tables(client, "SELECT COUNT(*) n FROM run_shape")[0]["n"] == 1
    assert client.delete("/v1/me", headers=auth(t)).json() == {"status": "deleted"}
    assert tables(client, "SELECT COUNT(*) n FROM run_shape")[0]["n"] == 0
    raw = b"".join(open(p, "rb").read() for p in (path, path + "-wal") if os.path.exists(p))
    assert b"342.8571" not in raw and json.dumps(shape_route()[:6], separators=(",", ":"))[1:-1].encode() not in raw


def test_the_shape_goes_when_its_run_goes(client):
    t = enrol(client)
    post(client, t, **shape_payload())
    with db.tx(client.svc.s.db_path) as c:
        c.execute("DELETE FROM runs WHERE run_id='r1'")
    assert tables(client, "SELECT COUNT(*) n FROM run_shape")[0]["n"] == 0


def test_a_late_upload_from_the_app_adds_its_shape_to_a_replayed_run(client):
    """The coach replay inserts a run from an export file; the app's own upload is the same run and brings the shape."""
    t = enrol(client)
    uid = tables(client, "SELECT id FROM users")[0]["id"]
    body = run_payload("rep1")
    client.svc.ingest_run(uid, RunIn.model_validate(body))
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO replay_runs (user_id, run_id, inserted) VALUES (?,?,1)", (uid, "rep1"))
    r = client.post("/v1/runs", json={**body, **shape_payload()}, headers=auth(t))
    assert r.status_code == 200 and r.json()["status"] == "updated"
    assert tables(client, "SELECT COUNT(*) n FROM run_shape")[0]["n"] == 1


# --- the switch ------------------------------------------------------------------------------

def put(client, t, **body):
    return client.put("/v1/me/settings", json=body, headers=auth(t))


def test_switching_the_route_off_deletes_stored_routes_and_keeps_splits(client):
    t = enrol(client)
    post(client, t, **shape_payload())
    assert put(client, t, route_shape=False).status_code == 200
    (row,) = tables(client, "SELECT * FROM run_shape")
    assert row["route_json"] is None and row["splits_json"] is not None
    me = client.get("/v1/me", headers=auth(t)).json()
    assert me["profile"]["route_shape_on_cards"] is False and me["run_shapes"][0]["route"] is None


def test_with_the_route_off_a_new_run_stores_no_route_even_if_one_arrives(client):
    t = enrol(client)
    put(client, t, route_shape=False)
    assert post(client, t, **shape_payload()).status_code == 202
    (row,) = tables(client, "SELECT * FROM run_shape")
    assert row["route_json"] is None and row["splits_json"] is not None
    put(client, t, route_shape=True)
    client.post("/v1/runs", json=run_payload("r2", **shape_payload()), headers=auth(t))
    assert tables(client, "SELECT route_json FROM run_shape WHERE run_id='r2'")[0]["route_json"]


def test_route_off_with_no_splits_leaves_no_row_at_all(client):
    t = enrol(client)
    post(client, t, route=shape_route())
    put(client, t, route_shape=False)
    assert tables(client, "SELECT COUNT(*) n FROM run_shape")[0]["n"] == 0


def test_the_switch_takes_a_real_boolean_only(client):
    t = enrol(client)
    for bad in ("false", 0, None, "no"):
        r = client.put("/v1/me/settings", json={"route_shape": bad}, headers=auth(t))
        assert r.status_code == (200 if bad is None else 422), bad
    assert put(client, t, bogus=True).status_code == 422


# --- never into a prompt ---------------------------------------------------------------------

def test_the_shape_never_reaches_the_writer_or_the_chat(client, fakes):
    t = enrol(client)
    marker = 977.7
    post(client, t, **shape_payload(splits=[{"km": 1.0, "pace_s": marker, "zone": 3}] * 2, distance_m=2000, duration_s=1955,
                                    pace_s_per_km=977.5, reps=[{"time_s": 51.2, "zone": 5}]))
    client.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert fakes.llm and fakes.tg
    blob = json.dumps([fakes.llm, [b for _, b in fakes.tg]], default=str)
    for leaked in (str(marker), "51.2", "route_xy", "route_json", "splits", '"reps"', json.dumps(shape_route()[1])):
        assert leaked not in blob, leaked


# --- media facts -----------------------------------------------------------------------------

def stored(run_type="easy", **shape):
    row = {"run_id": "r", "type": run_type, "start_utc": "2026-10-10T20:00:00Z", "zone_id": "Asia/Singapore",
           "distance_m": 7000, "duration_s": 2400, "pace_s_per_km": 342.9, "zone_min": json.dumps({"z2": 30, "z3": 10}),
           "climb_m": None, "locality": "Kallang", "verdict": "faster", "pb": None}
    p = shape_payload(reps=True)
    row["_shape"] = {"route": p["route"], "splits": p["splits"], "reps": p["reps"], **shape}
    return row


def test_run_facts_carry_the_shape_and_reps_only_for_intervals():
    f = run_facts(stored(), "h")
    assert f["route_xy"] == shape_route() and len(f["splits"]) == 7 and "reps" not in f and "route" not in f
    assert len(run_facts(stored("interval"), "h")["reps"]) == 6
    bare = run_facts({**stored(), "_shape": None}, "h")
    assert not {"route_xy", "splits", "reps"} & set(bare)


def test_video_facts_need_a_shape_splits_and_a_verdict_the_video_has_a_word_for():
    ok = video_facts(run_facts(stored(), "h"))
    assert ok and ok["title"] == "Easy run" and ok["verdict"] == "faster"
    assert video_facts(run_facts(stored(route=None), "h")) is None
    assert video_facts(run_facts(stored(splits=None), "h")) is None
    assert video_facts(run_facts({**stored(), "verdict": "baselineSet"}, "h")) is None
    assert video_facts(run_facts({**stored(), "verdict": None}, "h")) is None
    assert video_facts(run_facts({**stored(), "verdict": "noRealChange"}, "h"))["verdict"] == "holding"
    # the server never holds the old best a PB layout needs, so a PB run uses its ordinary verdict
    pb = video_facts(run_facts({**stored("race"), "pb": "5k"}, "h"))
    assert pb and "pb" not in pb and "pb_detail" not in pb


def test_the_video_spec_accepts_what_the_server_builds():
    from render.motion.run_video import RunVideo, spec_from_facts
    spec = spec_from_facts(video_facts(run_facts(stored(), "A steady one.")))
    assert spec.latlon is False and len(spec.splits) == 7 and spec.verdict.kind == "faster"
    RunVideo(spec)   # lays out the route, splits and verdict without drawing a frame
    inter = stored("interval")
    inter["zone_min"] = json.dumps({"z4": 10, "z5": 12})
    spec = spec_from_facts(video_facts(run_facts(inter, "Hard session.")))
    assert len(spec.reps) == 6
    RunVideo(spec)


def test_a_video_whose_splits_do_not_match_the_run_is_not_made():
    from render.motion.run_video import spec_from_facts
    bad = video_facts(run_facts(stored(splits=shape_payload()["splits"][:3]), "h"))
    with pytest.raises(ValueError):
        spec_from_facts(bad)


# --- cards (as HTML) -------------------------------------------------------------------------

def card_html(facts, kind="post_run"):
    from render.cards.pb import build_pb_html
    from render.cards.post_run import build_post_run_html
    return (build_pb_html if kind == "pb" else build_post_run_html)(facts, {})


def body(html):
    return html.split("</style>", 1)[1]


def test_a_card_draws_the_shape_when_it_has_one_and_splits_bars_when_it_does_not():
    base = run_facts(stored(route=None, reps=None), "Steady.")
    assert 'class="abs route"' not in body(card_html(base)) and 'class="abs bars"' in body(card_html(base))
    with_shape = run_facts(stored(reps=None), "Steady.")
    html = body(card_html(with_shape))
    assert 'class="abs route"' in html and 'stroke-linecap="round"' in html
    plain = run_facts(stored(route=None, splits=None, reps=None), "Steady.")
    assert ">MIN<" in body(card_html(plain)).replace("MIN</span>", ">MIN<")   # the zone block, as before


def test_a_pb_card_draws_the_shape_too():
    f = run_facts({**stored("race", reps=None), "pb": "5k", "verdict": "faster"}, "A new best.")
    assert 'class="abs route"' in body(card_html(f, "pb"))


def test_reps_bars_replace_the_splits_on_an_interval_card():
    html = body(card_html(run_facts(stored("interval", route=None), "Hard.")))
    assert ">REPS<" in html and "BEST REP" in html and html.count("<rect") >= 6


def test_a_planar_route_is_fitted_not_projected():
    from render.cards import _parts as P2
    wide = [[0, 0], [255, 0], [255, 60], [0, 60]]
    pts = P2.project_route(wide, 400, 300, pad=10, planar=True)
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    assert min(xs) == pytest.approx(10) and max(xs) == pytest.approx(390)
    assert (max(ys) - min(ys)) == pytest.approx(380 * 60 / 255)        # aspect kept, nothing cos-scaled or flipped
    assert pts[0] == pytest.approx((10, 150 - 380 * 60 / 255 / 2))     # y grows downward, first point stays top-left


# --- the worker protocol ---------------------------------------------------------------------

def req(**facts):
    return {"v": 1, "op": "card", "kind": "light", "facts": {"headline": "x", **facts}}


def test_the_worker_protocol_allows_the_shape_keys_and_not_coordinates():
    P.check_request(req(route_xy=shape_route(), splits=shape_payload()["splits"], reps=[{"time_s": 80, "zone": 5}], title="Run"))
    for bad in (dict(route=[[1.3, 103.8], [1.4, 103.9]]), dict(lat=1.3), dict(lon=103.8), dict(area_lat=1.3),
                dict(route_xy=[[1.3, 103.8], [1.4, 103.9]]), dict(route_xy=[[0, 0], [256, 1]]),
                dict(route_xy=[[0, 0]] * 121), dict(route_xy=[[0, 0]]), dict(route_xy=[[0, 0, 1], [1, 1, 1]]),
                dict(route_xy=[[True, False], [1, 1]]), dict(route_xy="abc"),
                dict(splits=[{"km": 1.0, "pace_s": 300, "lat": 1.3}]), dict(splits=[{"km": 1.0}]),
                dict(splits=[{"km": 1.0, "pace_s": 300, "zone": 7}]), dict(splits=[{"km": 1.0, "pace_s": 300}] * 101),
                dict(reps=[{"time_s": 80, "note": "x"}]), dict(reps=[]), dict(reps=[{"time_s": 80}] * 61)):
        with pytest.raises(P.ProtocolError):
            P.check_request(req(**bad))


# --- cards and videos end to end, through a fake worker --------------------------------------

class FakeWorker:
    """A render worker that draws nothing: it applies the real protocol checks, records what it was asked, and answers
    with a stub PNG or MP4. Real RenderClient, real unix socket."""

    def __init__(self):
        self.path = os.path.join(tempfile.mkdtemp(prefix="rsw-"), "fake.sock")
        self.asked: list[tuple[str, str, dict]] = []
        self.refused = 0
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.path)
        self.srv.listen(8)
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            with conn:
                try:
                    op, kind, facts = P.check_request(P.read_request(conn, 5))
                except P.ProtocolError as e:
                    self.refused += 1
                    P.send_error(conn, e.code)
                    continue
                self.asked.append((op, kind, facts))
                P.send_ok(conn, PNG if op == "card" else MP4)

    def kinds(self):
        return [(op, kind) for op, kind, _ in self.asked]


@pytest.fixture
def worker():
    w = FakeWorker()
    yield w
    w.srv.close()


def media_client(tmp_path, fakes, worker):
    s = make_settings(tmp_path, media_enabled=True, render_socket=worker.path)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    return app


PB_RUN = dict(type="race", pb="5k", distance_m=5000, duration_s=1301, pace_s_per_km=260.2,
              zone_min={"z4": 10, "z5": 11.7})
BIG_SESSION = dict(type="tempo", distance_m=8000, duration_s=2400, pace_s_per_km=300.0,
                   zone_min={"z2": 5, "z4": 20, "z5": 2})


def no_coordinates(obj):
    """No float with a fractional part in a route, and no key that names a place."""
    if isinstance(obj, dict):
        assert not {"lat", "lon", "latitude", "longitude", "route", "area_lat", "area_lon"} & set(obj)
        for k, v in obj.items():
            if k == "route_xy":
                assert all(type(c) is int and 0 <= c <= 255 for p in v for c in p)
            no_coordinates(v)
    elif isinstance(obj, list):
        for v in obj:
            no_coordinates(v)


@pytest.mark.parametrize("name,fields,card", [("pb", PB_RUN, "pb"), ("big session", BIG_SESSION, "flood")])
def test_pb_and_big_session_runs_get_the_card_with_the_route_and_the_video(tmp_path, fakes, worker, name, fields, card):
    app = media_client(tmp_path, fakes, worker)
    shape = shape_payload(distance_m=fields["distance_m"], duration_s=fields["duration_s"], reps=fields["type"] == "tempo")
    with TestClient(app) as c:
        t = enrol(c)
        assert c.post("/v1/runs", json=run_payload("r1", verdict="faster", **fields, **shape), headers=auth(t)).status_code == 202
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert worker.refused == 0
    assert worker.kinds() == [("card", card), ("video", "run")], worker.kinds()
    card_facts, video_facts_ = worker.asked[0][2], worker.asked[1][2]
    assert card_facts["route_xy"] == shape["route"] and len(card_facts["splits"]) == len(shape["splits"])
    assert video_facts_["route_xy"] == shape["route"] and video_facts_["title"] and "pb" not in video_facts_
    assert "reps" not in card_facts   # reps are drawn for interval runs only
    for _, _, f in worker.asked:
        no_coordinates(f)
    assert "sendVideo" in fakes.tg_methods() and "sendPhoto" not in fakes.tg_methods()
    video = [b for m, b in fakes.tg if m == "sendVideo"][0]
    assert video["_files"]["video"][1] == MP4


def test_an_interval_run_sends_its_rep_times_to_the_card_and_the_video(tmp_path, fakes, worker):
    app = media_client(tmp_path, fakes, worker)
    shape = shape_payload(distance_m=9600, duration_s=3170, reps=True)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1", type="interval", distance_m=9600, duration_s=3170, pace_s_per_km=330.2,
                                            verdict="faster", zone_min={"z4": 12, "z5": 10}, **shape), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert worker.kinds() == [("card", "flood"), ("video", "run")]
    assert [r["time_s"] for r in worker.asked[0][2]["reps"]] == [84.0, 83.0, 82.0, 81.0, 80.0, 79.0]
    assert worker.asked[1][2]["reps"] == worker.asked[0][2]["reps"]


def test_without_a_shape_the_card_is_still_made_and_there_is_no_video(tmp_path, fakes, worker):
    app = media_client(tmp_path, fakes, worker)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1", verdict="faster", **PB_RUN), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert worker.kinds() == [("card", "pb")] and "sendVideo" not in fakes.tg_methods()
    assert not {"route_xy", "splits", "reps"} & set(worker.asked[0][2])


def test_with_the_route_switch_off_the_card_has_splits_but_no_route_and_there_is_no_video(tmp_path, fakes, worker):
    app = media_client(tmp_path, fakes, worker)
    with TestClient(app) as c:
        t = enrol(c)
        assert put(c, t, route_shape=False).status_code == 200
        c.post("/v1/runs", json=run_payload("r1", verdict="faster", **PB_RUN, **shape_payload(5000, 1301)), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert worker.kinds() == [("card", "pb")]
    facts = worker.asked[0][2]
    assert "route_xy" not in facts and len(facts["splits"]) == 5


def test_a_broken_worker_still_sends_the_text_card(tmp_path, fakes):
    s = make_settings(tmp_path, media_enabled=True, render_socket=os.path.join(tempfile.mkdtemp(prefix="rsw-"), "none.sock"))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1", verdict="faster", **PB_RUN, **shape_payload(5000, 1301)), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert fakes.tg_methods().count("sendMessage") >= 1 and "sendVideo" not in fakes.tg_methods()


def test_media_renderer_hands_the_worker_only_allow_listed_facts():
    seen = []
    r = MediaRenderer({"flood": lambda f, m: (seen.append(f), PNG)[1]}, {"run": lambda f, out: out.write_bytes(MP4)})
    run = {**stored("tempo"), "type": "tempo", "zone_min": json.dumps({"z4": 20, "z5": 2})}
    m = r.render({"card": "flood", "video": True}, {"run_id": "r", "headline": "h"}, [run])
    assert isinstance(m, Media) and m.video == MP4
    assert set(seen[0]) <= P.ALLOWED_FACT_KEYS


# --- review of PR 259: retention, switch-off scrubbing, worker bounds -------------------------

def test_purge_drops_a_route_after_30_days_and_keeps_its_splits(client):
    t = enrol(client)
    uid = tables(client, "SELECT id FROM users")[0]["id"]
    for rid, days in (("old", 40), ("new", 5)):
        start = now_utc() - timedelta(days=days)
        client.svc.ingest_run(uid, RunIn.model_validate(
            run_payload(rid, start_utc=start.isoformat(), **shape_payload(reps=True))), start + timedelta(hours=2))
    client.svc.purge(now_utc())
    rows = {r["run_id"]: r for r in tables(client, "SELECT * FROM run_shape")}
    assert rows["old"]["route_json"] is None and rows["old"]["splits_json"] and rows["old"]["reps_json"]
    assert rows["new"]["route_json"]
    me = client.get("/v1/me", headers=auth(t)).json()
    assert {s["run_id"]: s["route"] is None for s in me["run_shapes"]} == {"old": True, "new": False}


def test_purge_removes_an_orphaned_shape_row(client):
    t = enrol(client)
    uid = tables(client, "SELECT id FROM users")[0]["id"]
    post(client, t, route=shape_route())
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("PRAGMA foreign_keys=OFF")
    c.execute("INSERT INTO run_shape (user_id, run_id, route_json) VALUES (?, 'ghost', '[[0,0],[255,1]]')", (uid,))
    c.commit()
    c.close()
    client.svc.purge(now_utc())
    assert [r["run_id"] for r in tables(client, "SELECT run_id FROM run_shape")] == ["r1"]


def test_switching_the_route_off_leaves_the_outline_nowhere_in_the_files(client):
    t = enrol(client)
    marker = [[0, 0], [255, 1], [254, 99], [13, 77], [200, 201]]
    post(client, t, route=marker)
    path = client.svc.s.db_path
    put(client, t, route_shape=False)
    raw = b"".join(open(p, "rb").read() for p in (path, path + "-wal") if os.path.exists(p))
    assert b"[[0,0],[255,1],[254,99]" not in raw


def test_the_worker_checks_the_title_and_bounds_the_numbers():
    for bad in (dict(title=5), dict(title=""), dict(title="x" * 25), dict(title=["Run"]),
                dict(splits=[{"km": 1.0, "pace_s": 5}]), dict(splits=[{"km": 1.0, "pace_s": 99999}]),
                dict(splits=[{"km": 2.0, "pace_s": 300}]), dict(splits=[{"km": 0, "pace_s": 300}]),
                dict(splits=[{"km": float("nan"), "pace_s": 300}]), dict(reps=[{"time_s": 0}]),
                dict(reps=[{"time_s": 7200}])):
        with pytest.raises(P.ProtocolError):
            P.check_request(req(**bad))
    P.check_request(req(title="Intervals", splits=[{"km": 0.4, "pace_s": 300.5}], reps=[{"time_s": 3600}]))
