"""Run notes ("Add a note"): note mode, limits, privacy, and the two deterministic uses. A note never reaches a model."""
import inspect
import json
import logging
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
from fastapi.testclient import TestClient

import companion.media
import companion.render_client
import companion.writer
from companion import db, notes
from companion.app import create_app
from companion.channels import Inbound, OutCard, WhatsAppChannel
from companion.convo import suggest
from companion.convo import touches as T
from companion.convo.weather import Forecast
from companion.service import (NOTE_CANCELLED, NOTE_DELETE_FIRST, NOTE_EXPIRED, NOTE_PAUSED, NOTE_PROMPT, NOTE_SAVED, NOTE_TOO_LONG, UNKNOWN, RunIn)
from companion.timeutil import iso, now_utc
from conftest import coach_week, OWNER, auth, enrol, make_settings, post_tg, run_payload, tg_callback, tg_update
from test_convo import NOW, ctx, run

SENTINEL = "ZEBRA-PANTS-4417"


def q(client, sql, *a):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    return c.execute(sql, a).fetchall()


_n = iter(range(50_000, 10**6))


def say(client, text, ref=OWNER):
    assert post_tg(client, tg_update(next(_n), text, ref)).status_code == 200


def send_run(client, token, run_id="r1", **kw):
    assert client.post("/v1/runs", json=run_payload(run_id, **kw), headers=auth(token)).status_code in (200, 202)
    client.svc.run_outbox(now_utc() + timedelta(seconds=1))


def note_idx(client, run_id):
    row = q(client, "SELECT card_id, buttons_json FROM cards WHERE run_id=? AND kind='run'", run_id)[0]
    acts = [b["action"] for b in json.loads(row["buttons_json"])]
    return row["card_id"], acts.index("note:add")


def tap_note(client, run_id="r1", ref=OWNER):
    card_id, i = note_idx(client, run_id)
    assert post_tg(client, tg_callback(next(_n), f"{card_id}:{i}", ref)).status_code == 200


def last_text(fakes):
    return fakes.tg_texts()[-1]


def notes_rows(client):
    return {r["run_id"]: r["note"] for r in q(client, "SELECT run_id, note FROM run_notes")}


def mode_rows(client):
    return q(client, "SELECT * FROM note_mode")


# --- the button -------------------------------------------------------------------------------------------------

def test_note_button_is_its_own_row_under_the_three_feel_buttons(client, fakes):
    t = enrol(client)
    send_run(client, t)
    sent = [b for m, b in fakes.tg if m == "sendMessage"][-1]
    kb = sent["reply_markup"]["inline_keyboard"]
    assert [b["text"] for b in kb[0]] == ["Easy", "Right", "Hard"] and [b["text"] for b in kb[1]] == ["Add a note"]
    card_id, i = note_idx(client, "r1")
    assert kb[1][0]["callback_data"] == f"{card_id}:{i}"


def test_feel_tap_keeps_only_the_note_button(client, fakes):
    t = enrol(client)
    send_run(client, t)
    card_id, _ = note_idx(client, "r1")
    post_tg(client, tg_callback(next(_n), f"{card_id}:0"))   # Easy
    edit = [b for m, b in fakes.tg if m == "editMessageReplyMarkup"][-1]
    kb = edit["reply_markup"]["inline_keyboard"]
    assert [b["text"] for row in kb for b in row] == ["Add a note"]
    assert q(client, "SELECT feel FROM runs")[0]["feel"] == "easy"


def test_whatsapp_keeps_three_reply_buttons_and_leaves_the_note_button_out(tmp_path):
    sent = []

    def h(req):
        sent.append(json.loads(req.content))
        return httpx.Response(200, json={"messages": [{"id": "wamid.1"}]})
    ch = WhatsAppChannel(make_settings(tmp_path), httpx.Client(transport=httpx.MockTransport(h)))
    buttons = [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]
    buttons.append({"label": "Add a note", "action": "note:add", "row": 1})
    ch.send_card("61400111222", OutCard("c1", "H", "B", buttons), in_window=True)
    inter = sent[0]["interactive"]
    assert inter["type"] == "button" and [b["reply"]["id"] for b in inter["action"]["buttons"]] == ["c1:0", "c1:1", "c1:2"]


# --- note mode ----------------------------------------------------------------------------------------------------

def test_tap_then_text_saves_the_note_and_confirms_in_the_voice(client, fakes):
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    assert last_text(fakes) == NOTE_PROMPT and len(mode_rows(client)) == 1
    say(client, "Left calf a bit tight on the hills")
    assert last_text(fakes) == NOTE_SAVED == "Noted. I'll keep it in mind."
    assert notes_rows(client) == {"r1": "Left calf a bit tight on the hills"} and not mode_rows(client)
    say(client, "and another thing")                      # note mode is over: today's reply
    assert last_text(fakes) == UNKNOWN and len(notes_rows(client)) == 1


def test_free_text_outside_note_mode_keeps_todays_reply(client, fakes):
    t = enrol(client)
    send_run(client, t)
    say(client, "how far did I run?")
    assert last_text(fakes) == UNKNOWN and not notes_rows(client)
    say(client, "hello")
    assert last_text(fakes) == UNKNOWN and not fakes.llm[1:] and not notes_rows(client)


def test_note_mode_expires_after_ten_minutes(client, fakes):
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    exp = datetime.fromisoformat(mode_rows(client)[0]["expires_at"].replace("Z", "+00:00"))
    assert timedelta(minutes=9) < exp - datetime.now(timezone.utc) <= timedelta(minutes=10)
    inb = Inbound("telegram", OWNER, "late1", text="too late to count")
    client.svc.handle_inbound(inb, now=now_utc() + timedelta(minutes=11))
    assert last_text(fakes) == NOTE_EXPIRED and not notes_rows(client) and not mode_rows(client)
    say(client, "and now?")
    assert last_text(fakes) == UNKNOWN
    # and just inside the window it still counts
    tap_note(client)
    client.svc.handle_inbound(Inbound("telegram", OWNER, "ontime", text="made it"), now=now_utc() + timedelta(minutes=9))
    assert notes_rows(client) == {"r1": "made it"}


def test_the_note_goes_to_the_card_tapped_last_and_never_to_another_runner(tmp_path, fakes):
    other = "444555666"
    s = make_settings(tmp_path, allowed_ids=frozenset({f"telegram:{OWNER}", f"telegram:{other}"}))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        a, b = enrol(c), enrol(c, ref=other)
        send_run(c, a, "r1", minutes_ago=300)
        send_run(c, a, "r2", minutes_ago=20)
        send_run(c, b, "rb")
        tap_note(c, "r1")
        tap_note(c, "r2")                                  # the wrong-card tap: the runner meant the newer run
        say(c, "this one", OWNER)
        assert notes_rows(c) == {"r2": "this one"}
        # someone else's card id: treated as expired, and B is not put in note mode
        card_a, i = note_idx(c, "r1")
        post_tg(c, tg_callback(next(_n), f"{card_a}:{i}", other))
        assert [r["user_id"] for r in mode_rows(c)] == [] and "expired" in fakes.tg[-1][1]["text"]
        say(c, "hi there", other)
        assert last_text(fakes) == UNKNOWN and set(notes_rows(c)) == {"r2"}
        # an unknown card id
        post_tg(c, tg_callback(next(_n), "deadbeef:0", OWNER))
        assert not mode_rows(c)


def test_a_note_over_500_characters_is_refused_and_note_mode_stays_open(client, fakes):
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    say(client, "x" * 501)
    assert last_text(fakes) == NOTE_TOO_LONG and not notes_rows(client) and len(mode_rows(client)) == 1
    say(client, "y" * 500)                                 # exactly the limit is fine
    assert last_text(fakes) == NOTE_SAVED and notes_rows(client) == {"r1": "y" * 500}


def test_nothing_is_stored_while_paused(client, fakes):
    t = enrol(client)
    send_run(client, t)
    say(client, "STOP")
    tap_note(client)                                       # a paused chat cannot start a note
    assert last_text(fakes) == NOTE_PAUSED and not mode_rows(client)
    say(client, "RESUME")
    tap_note(client)
    say(client, "STOP")                                    # STOP pauses and closes note mode
    assert q(client, "SELECT paused FROM users")[0]["paused"] == 1 and not mode_rows(client)
    say(client, "an unwanted note")
    assert last_text(fakes) == UNKNOWN and not notes_rows(client)


def _users(client):
    return q(client, "SELECT COUNT(*) n FROM users")[0]["n"], q(client, "SELECT COUNT(*) n FROM runs")[0]["n"]


def test_a_bare_delete_in_note_mode_does_not_erase_anything_the_second_one_does(client, fakes):
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    say(client, "delete")
    assert last_text(fakes) == NOTE_DELETE_FIRST and _users(client) == (1, 1)
    assert not mode_rows(client) and not notes_rows(client)     # never stored as a note
    say(client, "DELETE")                                       # note mode is gone: today's behaviour
    assert _users(client) == (0, 0) and "Everything we held about you is deleted" in last_text(fakes)


def test_delete_outside_note_mode_still_erases_at_once(client, fakes):
    t = enrol(client)
    send_run(client, t)
    say(client, "DELETE")
    assert _users(client) == (0, 0)


def test_delete_after_note_mode_lapsed_still_erases(client, fakes):
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    client.svc.handle_inbound(Inbound("telegram", OWNER, "lapsed", text="/delete"), now=now_utc() + timedelta(minutes=11))
    assert _users(client) == (0, 0)


def test_cancel_end_quit_just_leave_note_mode(client, fakes):
    t = enrol(client)
    send_run(client, t)
    for word in ("cancel", "End", "/quit"):
        tap_note(client)
        say(client, word)
        assert last_text(fakes) == NOTE_CANCELLED and not mode_rows(client) and not notes_rows(client)
        assert q(client, "SELECT paused FROM users")[0]["paused"] == 0
    say(client, "cancel")                                       # outside note mode: today's behaviour, it pauses
    assert q(client, "SELECT paused FROM users")[0]["paused"] == 1


def test_stop_and_unsubscribe_in_note_mode_pause_and_close_it(client, fakes):
    t = enrol(client)
    send_run(client, t)
    for word in ("STOP", "unsubscribe"):
        say(client, "RESUME")
        tap_note(client)
        say(client, word)
        assert q(client, "SELECT paused FROM users")[0]["paused"] == 1 and not mode_rows(client) and not notes_rows(client)


def test_a_second_note_on_the_same_run_replaces_the_first(client, fakes):
    t = enrol(client)
    send_run(client, t)
    for text in ("first", "second"):
        tap_note(client)
        say(client, text)
    assert notes_rows(client) == {"r1": "second"}


def test_notes_are_one_clean_line(client, fakes):
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    say(client, "line one\n\n  line\ttwo \x07")
    assert notes_rows(client) == {"r1": "line one line two"}


# --- keyword flags -------------------------------------------------------------------------------------------------

def test_flag_words():
    for ok in ("calf niggle", "Sore knee", "slight injury", "injured", "so tired", "felt sick", "NIGGLES"):
        assert notes.flagged(ok), ok
    for no in ("felt great", "windy but fun", "new shoes", "sorted the route"):
        assert not notes.flagged(no), no


def test_a_flagged_note_softens_for_a_week_only():
    at = NOW - timedelta(days=2)
    assert notes.soften([("calf is sore", at)], NOW)
    assert not notes.soften([("calf is sore", NOW - timedelta(days=8))], NOW)
    assert not notes.soften([("great run", at)], NOW)
    assert not notes.soften([("calf is sore", NOW + timedelta(days=1))], NOW)


def _push_history():
    return [run(i, 1 + 2 * i) for i in range(4)] + [run(9, 8, typ="tempo"), run(10, 20)]


def test_a_flagged_note_turns_a_quality_nudge_into_an_easy_one():
    hist = _push_history()
    plain = suggest.evening(hist, NOW, Forecast(24, 5), {}, "s")
    soft = suggest.evening(hist, NOW, Forecast(24, 5), {}, "s", soften=True)
    assert plain.suggestion.kind == "quality" and plain.rendered.situation == "sugg_weather_good"
    assert soft.suggestion.kind == "easy_next" and soft.rendered.situation == "sugg_soft"
    assert "tempo" not in soft.suggestion.text and "steady" not in soft.suggestion.text
    assert "easy" in soft.suggestion.text and "bite" not in soft.suggestion.text.lower() and "push" not in soft.suggestion.text.lower()
    gap = suggest.evening(hist, NOW, None, {}, "s")                 # no weather: the plain gap nudge
    assert gap.suggestion.kind == "quality"
    assert suggest.evening(hist, NOW, None, {}, "s", soften=True).rendered.situation == "sugg_soft"
    # an easy-session reason is unchanged by softening
    assert suggest.evening(hist, NOW, Forecast(33, 5), {}, "s", soften=True).suggestion.kind == "heat"


def test_softening_drops_the_pushy_touches():
    mem = {"runs_per_week": "3"}
    hist = []
    for w in (3, 2, 1):
        hist += [run(100 * w + k, 7 * w - k) for k in range(3)]
    hist.sort(key=lambda r: r["start_utc"], reverse=True)
    done = [run(3, 0.2), run(4, 0.4), *hist]
    assert "streak" in {t.kind for t in T.candidates(ctx(run(2, 0), done, mem))}
    assert "streak" not in {t.kind for t in T.candidates(ctx(run(2, 0), done, mem, soften=True))}


def test_a_note_changes_the_next_evening_card_end_to_end(client, fakes):
    t = enrol(client)
    uid = q(client, "SELECT id FROM users")[0]["id"]
    send_run(client, t, "old", minutes_ago=20 * 1440)         # not a new runner: those get no quality push (M6)
    for i, days in enumerate((9, 7, 5, 3)):                  # active, last hard session nine days back: a quality nudge
        send_run(client, t, f"h{i}", minutes_ago=days * 1440, type="tempo" if i == 0 else "easy")
    send_run(client, t, "fresh", minutes_ago=10)             # old runs are stored without a card; this one has the button
    coach_week(client.svc, "quality")   # the card follows the coach week for every runner; a note softens a planned push
    plain = client.svc._build_evening_card(uid, "2099-01-01", now_utc())
    assert plain and q(client, "SELECT situation FROM convo_cards WHERE card_id=?", plain)[0]["situation"] == "sugg_plan_session"
    c = sqlite3.connect(client.svc.s.db_path)               # start over: no card, no weekly allowance used
    c.execute("DELETE FROM cards WHERE kind='evening'")
    c.execute("DELETE FROM quota")
    c.commit()
    tap_note(client, "fresh")
    say(client, "calf is really sore today")
    soft = client.svc._build_evening_card(uid, "2099-01-02", now_utc())
    assert soft and q(client, "SELECT situation FROM convo_cards WHERE card_id=?", soft)[0]["situation"] == "sugg_soft"
    body = q(client, "SELECT body FROM cards WHERE card_id=?", soft)[0]["body"]
    assert "calf" not in body and "push" not in body.lower() and "bite" not in body.lower()


# --- the recap quote -----------------------------------------------------------------------------------------------

def _week(client, tz="UTC"):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    for i, d in enumerate((5, 7, 8, 10)):
        start = datetime(2026, 10, d, 6, 0, tzinfo=timezone.utc)
        client.svc.ingest_run(uid, RunIn.model_validate(run_payload(
            f"w{i}", start_utc=start.isoformat(), zone_id=tz, utc_offset_min=0, duration_s=1800, distance_m=5000)),
            start + timedelta(hours=1))
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("UPDATE users SET zone_id=?", (tz,))
    c.execute("UPDATE outbox SET state='done'")
    c.commit()
    return uid


def test_the_recap_quotes_the_weeks_newest_note(client, fakes):
    enrol(client)
    uid = _week(client)
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)", (uid, "w0", "older note", "2026-10-05T08:00:00Z"))
    c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)", (uid, "w3", "felt strong on the hill", "2026-10-10T08:00:00Z"))
    c.commit()
    sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
    assert client.svc.plan_recap(sunday) == 1
    client.svc.run_outbox(sunday + timedelta(seconds=1))
    text = last_text(fakes)
    assert "You said: “felt strong on the hill”" in text and "older note" not in text


def test_the_recap_quote_is_never_stored_and_follows_the_note(client, fakes):
    t = enrol(client)
    uid = _week(client)
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)", (uid, "w3", f"{SENTINEL} first", "2026-10-10T08:00:00Z"))
    c.commit()
    sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
    card_id = client.svc._build_recap_card(uid, "2026-W41", sunday)
    # the card row holds no note text anywhere, so a replaced or deleted note leaves no copy behind
    assert SENTINEL not in json.dumps([dict(r) for r in q(client, "SELECT * FROM cards")])
    assert SENTINEL not in json.dumps(client.get("/v1/me", headers=auth(t)).json()["messages_sent_30d"])
    c.execute("UPDATE run_notes SET note=? WHERE run_id='w3'", ("second thought",))   # the note is replaced before the send
    c.commit()
    user = dict(q(client, "SELECT * FROM users")[0])
    client.svc._send_card(user, card_id, sunday + timedelta(seconds=1))
    sent = fakes.tg_texts()[-1]
    assert "second thought" in sent and "first" not in sent and SENTINEL not in sent
    # a card still waiting when the note goes: nothing is quoted
    c.execute("UPDATE cards SET sent_at=NULL WHERE card_id=?", (card_id,))
    c.execute("DELETE FROM run_notes")
    c.commit()
    n = len(fakes.tg_texts())
    client.svc._send_card(user, card_id, sunday + timedelta(minutes=2))
    assert "You said" not in fakes.tg_texts()[n]


def test_a_long_note_is_clipped_in_the_recap_quote():
    long = "a" * 300
    out = notes.quote(long)
    assert out.startswith("You said: “") and len(out) < 230 and out.endswith("...”")


# --- privacy -------------------------------------------------------------------------------------------------------

def test_notes_are_exported_and_hard_deleted_with_their_run_and_user(client, fakes):
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    say(client, "calf niggle")
    me = client.get("/v1/me", headers=auth(t)).json()
    assert [(n["run_id"], n["note"]) for n in me["run_notes"]] == [("r1", "calf niggle")]
    # retention follows the run: when the run goes, so does its note
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("DELETE FROM runs WHERE run_id='r1'")
    c.commit()
    assert not notes_rows(client)
    # and the DELETE keyword takes a fresh note too
    send_run(client, t, "r2")
    tap_note(client, "r2")
    say(client, "second note")
    say(client, "DELETE")
    c = sqlite3.connect(client.svc.s.db_path)
    assert c.execute("SELECT COUNT(*) FROM run_notes").fetchone()[0] == 0 and c.execute("SELECT COUNT(*) FROM note_mode").fetchone()[0] == 0
    raw = open(client.svc.s.db_path, "rb").read()
    assert b"second note" not in raw


def test_purge_removes_orphaned_notes_and_old_note_mode(client, fakes):
    t = enrol(client)
    send_run(client, t)
    uid = q(client, "SELECT id FROM users")[0]["id"]
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("INSERT INTO note_mode (user_id, run_id, expires_at) VALUES (?,?,?)", (uid, "r1", iso(now_utc() - timedelta(hours=3))))
    c.commit()
    client.svc.purge(now_utc())
    assert not mode_rows(client)


def test_note_text_never_appears_in_logs(client, fakes, caplog):
    caplog.set_level(logging.DEBUG)
    t = enrol(client)
    send_run(client, t)
    tap_note(client)
    say(client, f"{SENTINEL} sore calf")
    say(client, "DELETE")
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert text and SENTINEL not in text


# --- no model exposure -----------------------------------------------------------------------------------------------

def test_a_note_is_never_sent_to_a_model(client, fakes):
    t = enrol(client)
    uid = q(client, "SELECT id FROM users")[0]["id"]
    for i, days in enumerate((9, 7, 5, 3)):
        send_run(client, t, f"h{i}", minutes_ago=days * 1440, type="tempo" if i == 0 else "easy")
    send_run(client, t, "fresh", minutes_ago=10)             # old runs are stored without a card; this one has the button
    tap_note(client, "fresh")
    say(client, f"{SENTINEL} my calf is sore and I am tired and a bit sick")
    assert notes_rows(client)["fresh"].startswith(SENTINEL)
    # every kind of card the writer makes after the note: run, evening, recap
    send_run(client, t, "after", minutes_ago=10)
    client.svc.run_outbox(now_utc() + timedelta(minutes=40))
    client.svc._build_evening_card(uid, "2099-02-01", now_utc())
    client.svc._build_recap_card(uid, "2099-W01", now_utc())
    assert fakes.llm, "the writer should have been called, or this test proves nothing"
    blob = json.dumps(fakes.llm)
    assert SENTINEL not in blob and "calf" not in blob.lower()
    for call in fakes.llm:
        assert "note" not in json.dumps(call["messages"][1]).lower()


def test_the_recap_quote_path_sends_nothing_to_the_writer_or_the_renderer(tmp_path, fakes):
    seen = []

    class Recorder:
        def render(self, plan, card, runs, memory=None, clip=True):
            seen.append(json.dumps({"plan": plan, "card": card, "runs": runs}, default=str))
            return None

    s = make_settings(tmp_path, media_enabled=True)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        c.svc.media = Recorder()
        enrol(c)
        uid = _week(c)
        db_ = sqlite3.connect(s.db_path)
        db_.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)",
                    (uid, "w3", f"{SENTINEL} sore calf", "2026-10-10T08:00:00Z"))
        db_.commit()
        sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
        assert c.svc.plan_recap(sunday) == 1
        c.svc.run_outbox(sunday + timedelta(seconds=1))
        assert any(SENTINEL in t for t in fakes.tg_texts()), "the quote path must have run"
        assert seen, "the renderer must have been called, or this proves nothing"
        assert not any(SENTINEL in x or "calf" in x for x in seen)
        assert not any(SENTINEL in json.dumps(call) for call in fakes.llm)
        card = json.loads(seen[0])["card"]
        assert set(card) == {"run_id", "headline"}                  # only the two fields the renderer uses


def test_nothing_that_talks_to_a_model_or_a_renderer_reads_the_notes_table():
    for mod in (companion.writer, companion.media, companion.render_client):
        src = inspect.getsource(mod)
        assert "run_notes" not in src and "note_mode" not in src, mod.__name__
    mem = sqlite3.connect(":memory:")
    mem.executescript(db.SCHEMA)
    cols = [r[1] for r in mem.execute("PRAGMA table_info(runs)")]
    assert not any("note" in col for col in cols)           # no SELECT * FROM runs can carry a note
