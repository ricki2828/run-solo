"""`ops send`: template approval, once per tester, the rails, the audit, delete-with-user, and that a dry run sends nothing.
Every send here goes to the Fakes Telegram transport. Nothing in this file can reach a real chat."""
import json
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from companion import db, ops, ops_send
from companion.service import Service
from companion.timeutil import iso
from conftest import Fakes, make_settings

UTC = timezone.utc
NOW = datetime(2026, 10, 20, 2, 0, tzinfo=UTC)    # 10:00 in Singapore: outside the default quiet hours below
N1 = "Any run counts, even 20 easy minutes. Next time out is fine."
N2 = "Quiet week. No stress."
INVITE = "Keen for a chat? {booking_link}"
LINK = "https://calendar.app.google/abc123"


@pytest.fixture
def env(tmp_path, monkeypatch):
    d = tmp_path / "state"
    d.mkdir()
    monkeypatch.setenv("COMPANION_OPS_STATE_DIR", str(d))
    fakes = Fakes()
    s = make_settings(tmp_path, openrouter_key=None, weather_enabled=False, default_quiet=(21 * 60 + 30, 7 * 60))
    svc = Service(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    with db.tx(s.db_path) as c:
        for n, (chat, consent) in enumerate((("8001", 2), ("8002", 2), ("8003", None)), 1):
            c.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_version, consent_at, zone_id, utc_offset_min, "
                      "last_inbound_at, tester_no, checkin_consent) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                      (f"u{n}", "telegram", chat, iso(NOW), "2", iso(NOW), "Asia/Singapore", 480, iso(NOW), n, consent))

    class E:
        pass
    e = E()
    e.d, e.fakes, e.s, e.svc = d, fakes, s, svc
    e.out = []
    e.say = e.out.append

    def draft(**texts):
        (d / "templates-draft.md").write_text("\n".join(f"## {k}\n" + "\n".join("> " + ln for ln in v.split("\n")) + "\n" for k, v in texts.items()))

    def approve(*ids, link=LINK):
        drafts = ops_send.load_drafts()
        ent = []
        for i in ids:
            if "{booking_link}" in drafts[i]:
                ent.append({"id": i, "sha256": ops_send.text_hash(drafts[i].replace("{booking_link}", link)), "link": link})
            else:
                ent.append({"id": i, "sha256": ops_send.text_hash(drafts[i])})
        (d / "templates-approved.json").write_text(json.dumps({"approved": ent}))

    def send(who, tpl, link=None, dry=False, now=NOW):
        e.out.clear()
        return ops_send.send(s, who, tpl, link, dry, e.say, now)

    def rows(sql, *a):
        c = sqlite3.connect(s.db_path)
        c.row_factory = sqlite3.Row
        return c.execute(sql, a).fetchall()

    def sent():
        return [b for m, b in fakes.tg if m == "sendMessage"]

    e.draft, e.approve, e.send, e.rows, e.sent = draft, approve, send, rows, sent
    e.draft(N1=N1, N2=N2, INVITE=INVITE)
    return e


def test_approved_list_starts_empty_and_nothing_is_approved(env):
    assert env.send("T1", "N1") == 1 and "not approved" in env.out[0]
    assert env.rows("SELECT * FROM ops_sends") == [] and env.rows("SELECT * FROM outbox") == []
    assert not any("APPROVED" in ln for ln in ops_send.templates(LINK))


def test_an_edited_template_is_refused_even_after_it_was_approved(env):
    env.approve("N1")
    env.draft(N1=N1 + " Cheers.", N2=N2, INVITE=INVITE)
    assert env.send("T1", "N1") == 1 and "changed after approval" in env.out[0]
    assert env.rows("SELECT * FROM outbox") == []


def test_an_approved_template_is_queued_then_sent_through_the_outbox(env):
    env.approve("N1")
    assert env.send("T1", "N1") == 0
    assert env.sent() == []                                   # nothing goes out from the CLI itself
    env.svc.run_outbox(NOW)
    msgs = env.sent()
    assert len(msgs) == 1 and msgs[0]["chat_id"] == 8001 and msgs[0]["text"] == N1   # no blank first line
    [row] = env.rows("SELECT * FROM ops_sends")
    assert (row["template"], row["result"], row["text_hash"]) == ("N1", "sent", ops_send.text_hash(N1))
    assert "T1 N1" in ops_send.sends(env.s)[0] and N1 not in ops_send.sends(env.s)[0]    # the audit holds a hash, not text


def test_each_template_goes_once_per_tester(env):
    env.approve("N1", "N2")
    assert env.send("T1", "N1") == 0
    assert env.send("T1", "N1", now=NOW + timedelta(days=10)) == 1 and "already sent" in env.out[0]
    assert env.send("T2", "N1") == 0                           # another tester is unaffected


def test_one_ops_message_per_tester_per_week_and_a_daily_cap(env, monkeypatch):
    env.approve("N1", "N2")
    assert env.send("T1", "N1") == 0
    assert env.send("T1", "N2", now=NOW + timedelta(days=4)) == 1 and "last 7 days" in env.out[0]
    assert env.send("T1", "N2", now=NOW + timedelta(days=8)) == 0
    monkeypatch.setattr(ops_send, "DAILY_CAP", 1)
    assert env.send("T2", "N1", now=NOW + timedelta(days=8)) == 1 and "daily cap" in env.out[0]


def test_invite_needs_a_https_link_and_no_placeholder_leaks(env):
    assert env.send("T1", "INVITE") == 1 and "link" in env.out[0]       # nothing approved: no link to use
    env.approve("INVITE")
    assert env.send("T1", "INVITE", link="http://x") == 1
    assert env.send("T1", "N1", link=LINK) == 1
    assert env.send("T1", "INVITE", link=LINK) == 0
    env.svc.run_outbox(NOW)
    assert LINK in env.sent()[0]["text"] and "{" not in env.sent()[0]["text"]


def test_the_link_is_part_of_the_approval(env):
    env.approve("INVITE")
    assert env.send("T1", "INVITE", link="https://calendar.app.google/other") == 1 and "approved with" in env.out[0]
    assert env.send("T1", "INVITE", link="https://evil.example.com/x", dry=True) == 1
    assert env.rows("SELECT * FROM outbox") == []
    assert env.send("T1", "INVITE") == 0                       # no --link: the approved one is used
    env.svc.run_outbox(NOW)
    assert LINK in env.sent()[0]["text"]


def test_a_link_off_the_calendar_allowlist_cannot_be_approved_or_sent(env):
    env.approve("INVITE", link="https://cal.example.com/ricki")
    assert env.send("T1", "INVITE") == 1 and "calendar" in env.out[0]
    assert env.send("T1", "INVITE", link="http://calendar.app.google/x") == 1
    assert env.rows("SELECT * FROM outbox") == []


def test_a_skipped_send_does_not_burn_the_template_and_can_be_queued_again(env):
    env.approve("N1")
    assert env.send("T1", "N1") == 0
    (env.d / "templates-approved.json").write_text(json.dumps({"approved": []}))
    env.svc.run_outbox(NOW)                                    # skipped: approval withdrawn
    env.approve("N1")
    assert env.send("T1", "N1", now=NOW + timedelta(hours=2)) == 0
    env.svc.run_outbox(NOW + timedelta(hours=2))
    assert [r["result"] for r in env.rows("SELECT result FROM ops_sends ORDER BY id")] == ["skipped: approval withdrawn", "sent"]


def test_the_runner_export_lists_template_and_date_only(env):
    env.approve("N1")
    env.send("T1", "N1")
    env.svc.run_outbox(NOW)
    exp = env.svc.get_me("u1", NOW)
    assert exp["ops_messages"] == [{"template": "N1", "date": "2026-10-20"}]
    assert N1 not in json.dumps(exp["ops_messages"])


def test_the_audit_is_purged_when_the_test_ends(env):
    env.approve("N1")
    env.send("T1", "N1")
    env.svc.purge(NOW)
    assert len(env.rows("SELECT * FROM ops_sends")) == 1
    env.svc.purge(datetime(2026, 12, 15, 3, 0, tzinfo=UTC))
    assert env.rows("SELECT * FROM ops_sends") == []


def test_dry_run_prints_the_exact_message_and_sends_and_records_nothing(env):
    assert env.send("T1", "N1", dry=True) == 1                 # unapproved: dry run says so, still prints the text
    assert N1 in env.out[1] and "approved: NO" in "\n".join(env.out)
    env.approve("N1")
    assert env.send("T1", "N1", dry=True) == 0
    assert env.out[1] == N1 and "approved: yes" in env.out[2]
    assert env.rows("SELECT * FROM ops_sends") == [] and env.rows("SELECT * FROM outbox") == [] and env.fakes.tg == []


def test_a_runner_without_consent_v2_or_who_stopped_gets_nothing(env):
    env.approve("N1")
    assert env.send("T3", "N1") == 1 and "consent" in env.out[0]            # never agreed to v2
    with db.tx(env.s.db_path) as c:
        c.execute("UPDATE users SET paused=1 WHERE id='u1'")                # STOP
    assert env.send("T1", "N1") == 1 and "paused" in env.out[0]
    assert env.fakes.tg == []


def test_stop_after_queueing_still_sends_nothing_and_the_audit_says_why(env):
    env.approve("N1")
    assert env.send("T1", "N1") == 0
    with db.tx(env.s.db_path) as c:
        c.execute("UPDATE users SET paused=1 WHERE id='u1'")
    env.svc.run_outbox(NOW)
    assert env.sent() == [] and env.rows("SELECT result FROM ops_sends")[0]["result"].startswith("skipped: paused")


def test_quiet_hours_defer_and_the_kill_switch_holds_it(env):
    env.approve("N1")
    late = datetime(2026, 10, 20, 15, 0, tzinfo=UTC)          # 23:00 in Singapore
    assert env.send("T1", "N1", now=late) == 0
    env.svc.run_outbox(late)
    assert env.sent() == []
    assert env.rows("SELECT state FROM outbox")[0]["state"] != "done"
    env.svc.run_outbox(late + timedelta(hours=9))             # 08:00 next morning
    assert len(env.sent()) == 1
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('sends_paused', '1')")
    assert env.send("T2", "N1", now=NOW + timedelta(days=5)) == 0
    env.svc.run_outbox(NOW + timedelta(days=5))
    assert len(env.sent()) == 1                                 # held by the global kill switch


def test_approval_withdrawn_before_the_tick_stops_the_send(env):
    env.approve("N1")
    assert env.send("T1", "N1") == 0
    (env.d / "templates-approved.json").write_text(json.dumps({"approved": []}))
    env.svc.run_outbox(NOW)
    assert env.sent() == [] and "withdrawn" in env.rows("SELECT result FROM ops_sends")[0]["result"]


def test_weekly_cap_blocks_a_second_ops_message_in_a_week(env):
    env.approve("N1", "N2")
    assert env.send("T1", "N1") == 0
    env.svc.run_outbox(NOW)
    c = sqlite3.connect(env.s.db_path)                          # a hand-queued second one inside the week, past the CLI's checks
    c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) VALUES "
              "('ops_x','u1',NULL,'ops','',?, '[]','ops',?)", (N2, iso(NOW)))
    c.execute("INSERT INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES ('u1','ops',?,'ops:x','ops_x')", (iso(NOW),))
    c.execute("INSERT INTO ops_sends (user_id, template, text_hash, ts, result, card_id) VALUES ('u1','N2',?,?,'queued','ops_x')",
              (ops_send.text_hash(N2), iso(NOW + timedelta(days=1))))
    c.commit()
    env.svc.run_outbox(NOW + timedelta(days=1))
    assert len(env.sent()) == 1 and env.rows("SELECT result FROM ops_sends WHERE template='N2'")[0]["result"] == "skipped: weekly cap"


def test_the_audit_goes_with_the_user(env):
    env.approve("N1")
    env.send("T1", "N1")
    with db.tx(env.s.db_path) as c:
        c.execute("DELETE FROM users WHERE id='u1'")
    assert env.rows("SELECT * FROM ops_sends") == []


def test_cli_wiring(env, capsys):
    out = []
    assert ops.main(env.s, ["templates"], out.append) == 0 and any(ln.startswith("N1 sha256=") for ln in out)
    assert ops.main(env.s, ["send", "--tester", "T1", "--template", "N9"], out.append) == 2
    assert ops.main(env.s, ["send", "--bogus"], out.append) == 2
    assert ops.main(env.s, ["sends"], out.append) == 0 and out[-1] == "no ops sends"


def test_a_bad_test_end_date_falls_back_to_the_default_and_never_purges_early(env, monkeypatch):
    from companion.config import Settings, _iso_date
    for bad in ("", "soon", "2026-13-40", None):
        assert _iso_date(bad) == "2026-12-15"
    assert _iso_date(" 2027-01-02 ") == "2027-01-02"
    env.approve("N1")
    env.send("T1", "N1")
    env.svc.purge(NOW)                                         # well before the default end: the audit stays
    assert len(env.rows("SELECT * FROM ops_sends")) == 1


def test_nothing_is_sent_after_the_test_ends_even_if_queued_before(env):
    env.approve("N1", "N2")
    assert env.send("T1", "N1") == 0
    end = datetime(2026, 12, 15, 2, 0, tzinfo=UTC)
    assert env.send("T2", "N2", now=end) == 1 and "test ended" in env.out[0]
    env.svc.run_outbox(end)
    assert env.sent() == [] and env.rows("SELECT result FROM ops_sends")[0]["result"] == "skipped: test ended"
