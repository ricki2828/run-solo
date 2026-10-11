"""Coach replay with COMPANION_MEDIA on: picture cards through the same path as live, text on any render failure."""
import pytest

from companion.media import MediaError, MediaRenderer
from test_replay import Env, texts

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64
KINDS = ("light", "flood", "pb", "weekly_recap", "suggestion", "milestone", "race_countdown", "monthly")


def media_env(tmp_path, name="m", fail=False):
    e = Env(tmp_path, name, media_enabled=True)
    calls: list[str] = []

    def render(kind):
        def fn(facts, *_a, **_k):
            calls.append(kind)
            if fail:
                raise MediaError("worker down")
            return PNG
        return fn

    e.svc.media = MediaRenderer({k: render(k) for k in KINDS}, {})  # a fake worker
    return e, calls


def test_run_and_recap_cards_go_out_as_pictures_with_the_replay_line_in_the_caption(tmp_path):
    e, calls = media_env(tmp_path)
    waits: list[float] = []
    assert e.replayer(every_s=300, sleep=waits.append).run() == "done"
    photos = [b for m, b in e.fakes.tg if m == "sendPhoto"]
    assert photos and calls
    assert all(p["caption"].startswith("Replay ") for p in photos)  # (the test parser mis-decodes the middle dot)
    assert all(p["_files"]["photo"][1] == PNG for p in photos)
    assert any(c["kind"] == "recap" for c in e.cards()) and "weekly_recap" in calls
    # every message, picture or text, is one paced item: 5 minutes apart
    n = len(e.sent())
    assert sum(waits) == 300 * n and n == len(e.fakes.tg)
    # picture cards carry at most the three feel buttons plus "Add a note"; the question travels as its own text message
    for p in photos:
        rm = p.get("reply_markup")
        if rm:
            import json
            kb = json.loads(rm)["inline_keyboard"] if isinstance(rm, str) else rm["inline_keyboard"]
            assert sum(len(r) for r in kb if r[0].get("text") != "Add a note") <= 3
            assert sum(len(r) for r in kb) <= 4


def test_a_render_failure_sends_the_text_card_with_the_same_line(tmp_path):
    e, calls = media_env(tmp_path, fail=True)
    assert e.replayer().run() == "done"
    assert calls and not [m for m, _ in e.fakes.tg if m == "sendPhoto"]
    texts_sent = [b["text"] for m, b in e.fakes.tg if m == "sendMessage"]
    assert texts_sent and all(t.startswith("Replay · ") for t in texts_sent)


def test_pictures_change_nothing_about_what_is_said_or_capped(tmp_path):
    with_media, _ = media_env(tmp_path, "on")
    with_media.replayer().run()
    plain = Env(tmp_path, "off")
    plain.replayer().run()
    assert texts(with_media) == texts(plain)  # same cards, same order: caps, quiet hours and no-repeat are unchanged


def test_the_monthly_poster_rides_the_replay_with_the_replay_line(tmp_path):
    e, calls = media_env(tmp_path)
    assert e.replayer(every_s=0).run() == "done"
    monthly = [c for c in e.cards() if c["kind"] == "monthly"]
    assert len(monthly) == 1 and monthly[0]["run_id"] == "monthly:2026-09"   # Oct 1 09:00 for September, once
    assert "monthly" in calls
    captions = [b["caption"] for m, b in e.fakes.tg if m == "sendPhoto" and "month" in b["caption"].lower()]
    assert captions and all(c.startswith("Replay ") for c in captions)
