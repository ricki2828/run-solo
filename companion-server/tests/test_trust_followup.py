"""A "Not really" trust answer gets a one-tap "what was off?" card and an ops alert."""
import json

from companion import db
from companion.timeutil import now_utc
from test_feedback import agree
from test_measure import tap, tok, trust_card  # noqa: F401  (tok is a fixture)
from test_notes import q


def _why_card(client):
    client.svc.run_outbox(now_utc())
    rows = q(client, "SELECT card_id, buttons_json FROM cards WHERE kind='trust_why'")
    return rows[0] if rows else None


def test_not_really_sends_a_what_was_off_card_and_one_alert(client, fakes, tok):
    card_id, uid = trust_card(client, fakes)
    tap(client, card_id, "trust:not")
    card = _why_card(client)
    assert [b["label"] for b in json.loads(card["buttons_json"])] == ["Too generic", "Wrong numbers", "Bad timing", "Something else"]
    alerts = q(client, "SELECT title, body FROM alerts")
    assert len(alerts) == 1 and "not right" in alerts[0]["title"]
    tap(client, card_id, "trust:not")   # a repeat tap does not send a second card or alert
    client.svc.run_outbox(now_utc())
    assert len(q(client, "SELECT 1 FROM cards WHERE kind='trust_why'")) == 1 and len(q(client, "SELECT 1 FROM alerts")) == 1


def test_a_mostly_or_spot_on_answer_gets_no_follow_up(client, fakes, tok):
    card_id, _ = trust_card(client, fakes)
    tap(client, card_id, "trust:mostly")
    assert _why_card(client) is None and q(client, "SELECT 1 FROM alerts") == []


def test_the_reason_tap_is_stored_and_alerts_ops(client, fakes, tok):
    card_id, _ = trust_card(client, fakes)
    tap(client, card_id, "trust:not")
    why = _why_card(client)
    tap(client, why["card_id"], "whyoff:timing")
    assert [tuple(r) for r in q(client, "SELECT kind, value FROM survey_answers ORDER BY kind")] == [("trust", "not"), ("trust_why", "timing")]
    assert any(a["body"] == "Bad timing." for a in q(client, "SELECT body FROM alerts"))


def test_something_else_opens_the_runners_own_words_feedback_mode(client, fakes, tok):
    card_id, _ = trust_card(client, fakes)
    tap(client, card_id, "trust:not")
    tap(client, _why_card(client)["card_id"], "whyoff:other")
    assert q(client, "SELECT 1 FROM feedback_mode")
