"""A note or feel landing soon after a run card updates that card in place, once (never a new message)."""
import json
import sqlite3
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from companion import notes
from companion.timeutil import now_utc
from conftest import OWNER, auth, enrol, post_tg, run_payload, tg_callback, tg_update
from test_notes import q, say, send_run, tap_note, note_idx, _n


def tomorrow():
    return (datetime.now(ZoneInfo("Pacific/Auckland")).date() + timedelta(days=1)).isoformat()


def quality_run(client, token, run_id="r1"):
    # the plan puts a quality session tomorrow; a flagged note or a hard feel turns that into an easy run
    send_run(client, token, run_id, plan_weeks=4, plan_next={"type": "quality", "day": tomorrow(), "week": 2, "distance_m": 6000})
    c = sqlite3.connect(client.svc.s.db_path)   # send_run's outbox clock runs a second ahead of real time
    c.execute("UPDATE cards SET sent_at=?", (now_utc().isoformat(),))
    c.commit()


def edits(fakes):
    return [(m, b) for m, b in fakes.tg if m in ("editMessageText", "editMessageCaption")]


def card_row(client, run_id="r1"):
    return q(client, "SELECT * FROM cards WHERE run_id=? AND kind='run'", run_id)[0]


def test_flagged_note_updates_next_line_in_place(client, fakes):
    t = enrol(client)
    quality_run(client, t)
    row = card_row(client)
    assert "Next: quality session 6 km tomorrow" in row["body"] and row["next_line"] and row["tg_message_id"]
    sent_before = fakes.tg_methods().count("sendMessage")
    tap_note(client)
    say(client, "haze, 12h flight")
    ed = edits(fakes)
    assert len(ed) == 1 and ed[0][0] == "editMessageText"
    body = ed[0][1]
    assert body["message_id"] == int(row["tg_message_id"])
    assert "Noted: the travel. Next: an easy run tomorrow" in body["text"] and "quality session" not in body["text"]
    assert "haze" not in body["text"] and "flight" not in body["text"]   # the note's words stay off the card
    kb = [b["text"] for r in body["reply_markup"]["inline_keyboard"] for b in r]
    assert kb == ["Easy", "Right", "Hard", "Add a note"]
    assert fakes.tg_methods().count("sendMessage") == sent_before + 2   # the note prompt and the "Noted" reply, no new card
    assert card_row(client)["note_edit_at"]


def test_second_note_never_edits_again(client, fakes):
    t = enrol(client)
    quality_run(client, t)
    tap_note(client)
    say(client, "haze, 12h flight")
    tap_note(client)
    say(client, "also very sore")
    assert len(edits(fakes)) == 1


def test_note_after_the_window_does_not_edit(client, fakes):
    t = enrol(client)
    quality_run(client, t)
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("UPDATE cards SET sent_at=?", ((now_utc() - timedelta(minutes=16)).isoformat(),))
    c.commit()
    tap_note(client)
    say(client, "haze, 12h flight")
    assert edits(fakes) == []


def test_unflagged_note_leaves_the_card_alone(client, fakes):
    t = enrol(client)
    quality_run(client, t)
    tap_note(client)
    say(client, "lovely morning")
    assert edits(fakes) == []


def test_hard_feel_updates_the_card_once(client, fakes):
    t = enrol(client)
    quality_run(client, t)
    card_id, _ = note_idx(client, "r1")
    acts = [b["action"] for b in json.loads(card_row(client)["buttons_json"])]
    assert post_tg(client, tg_callback(next(_n), f"{card_id}:{acts.index('feel:hard')}")).status_code == 200
    ed = edits(fakes)
    assert len(ed) == 1 and "Noted: that it felt hard. Next: an easy run tomorrow" in ed[0][1]["text"]
    kb = [b["text"] for r in ed[0][1]["reply_markup"]["inline_keyboard"] for b in r]
    assert kb == ["Add a note"]   # the feel row is gone once answered
    cb = [b["callback_data"] for r in ed[0][1]["reply_markup"]["inline_keyboard"] for b in r]
    assert cb == [f"{card_id}:{acts.index('note:add')}"]   # the stored index, not its place on screen


def test_add_a_note_still_opens_note_mode_after_the_edit(client, fakes):
    t = enrol(client)
    quality_run(client, t)
    card_id, _ = note_idx(client, "r1")
    acts = [b["action"] for b in json.loads(card_row(client)["buttons_json"])]
    post_tg(client, tg_callback(next(_n), f"{card_id}:{acts.index('feel:hard')}"))
    (cb,) = [b["callback_data"] for r in edits(fakes)[0][1]["reply_markup"]["inline_keyboard"] for b in r]
    assert post_tg(client, tg_callback(next(_n), cb)).status_code == 200
    assert q(client, "SELECT feel FROM runs WHERE run_id='r1'")[0]["feel"] == "hard"   # not re-read as "Easy"
    assert q(client, "SELECT run_id FROM note_mode")[0]["run_id"] == "r1"


def test_short_caption_keeps_the_noted_line():
    from companion.channels import OutCard, caption_text
    body = "Steady 6.2 km at 5:40/km. A good solid run.\nNoted: the travel. Next: an easy run tomorrow"
    cap = caption_text(OutCard("x", "Nice run", body, [], short_caption=True))
    assert "Noted: the travel. Next: an easy run tomorrow" in cap


def test_edit_failure_releases_the_claim(client, fakes):
    t = enrol(client)
    quality_run(client, t)
    fakes.fail("editMessageText", status=500)
    tap_note(client)
    say(client, "haze, 12h flight")
    assert card_row(client)["note_edit_at"] is None
    tap_note(client)
    say(client, "still hazy, long flight")
    assert len(edits(fakes)) == 1 and card_row(client)["note_edit_at"]


def test_flag_label_never_echoes_the_note():
    assert notes.flag_label("haze, 12h flight") == "the travel"
    assert notes.flag_label("legs sore") == "the niggle"
    assert notes.flag_label("lovely morning") is None


def test_flag_label_priority_and_unmatched_flag():
    assert notes.flag_label("smoked it, so hot") == "the heat"
    assert notes.flag_label("hazy and smoky") == "the haze"
    assert notes.flag_label("hazy, cheated the last km") == "the haze"   # "cheated" is not the heat
    assert notes.flag_label("hills were a grind") == "the hills"
    assert notes.flagged("legs dead on the climbs") and notes.flag_label("legs dead on the climbs") == "the hills"
    assert notes.flagged("was hot and sticky") and notes.flag_label("was hot and sticky") == "the heat"


def test_flagged_note_no_label_match_says_plain_noted(client, fakes, monkeypatch):
    monkeypatch.setattr(notes, "flag_label", lambda n: None)
    t = enrol(client)
    quality_run(client, t)
    tap_note(client)
    say(client, "haze, 12h flight")
    text = edits(fakes)[0][1]["text"]
    assert "Noted. Next: an easy run tomorrow" in text and "Noted: that" not in text
