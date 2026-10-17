"""rs-concierge decisions and rs-digest assembly: fresh fixtures, no live database, nothing sent anywhere."""
import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from companion import db
from ops_jobs import common, concierge, digest

NOW = datetime(2026, 10, 27, 1, 0, tzinfo=timezone.utc)
SENTINEL = "ZXQ-private-feedback-words"


def T(n=1, days=0, **kw):
    """A tester who joined `days` ago."""
    kw.setdefault("consent", 2)
    return concierge.Tester(n=n, joined=NOW - timedelta(days=days), **kw)


def acts(t, link=None):
    return [(d.action, d.template) for d in concierge.decide(t, NOW, link)]


# --- decisions ---------------------------------------------------------------------------------------------------

def test_n1_at_day_3_with_no_run_and_never_twice():
    assert ("send", "N1") not in acts(T(days=2))
    assert ("send", "N1") in acts(T(days=3))
    assert ("send", "N1") not in acts(T(days=3, sent={"N1": NOW - timedelta(days=1)}))
    assert ("send", "N1") not in acts(T(days=3, first_run=NOW - timedelta(days=1), last_activity=NOW - timedelta(days=1)))


def test_n2_after_7_silent_days_once_and_not_before_n1():
    ran = NOW - timedelta(days=10)
    silent = T(days=12, first_run=ran, last_activity=ran)
    assert ("send", "N2") in acts(silent)
    assert ("send", "N2") not in acts(T(days=12, first_run=ran, last_activity=ran, sent={"N2": NOW - timedelta(days=4)}))
    assert ("send", "N2") not in acts(T(days=8, first_run=ran, last_activity=NOW - timedelta(days=6)))
    # never ran and N1 not sent yet: N1 comes first, not N2
    assert acts(T(days=8))[-1] == ("send", "N1")
    assert ("send", "N2") in acts(T(days=10, sent={"N1": NOW - timedelta(days=8)}))
    assert ("wait", "N2") in acts(T(days=10, sent={"N1": NOW - timedelta(days=4)}))   # ops send spaces messages 7 days apart


def test_n3_in_week_3_for_a_tester_who_has_run_and_needs_a_link():
    recent = NOW - timedelta(days=1)
    t = T(days=16, first_run=NOW - timedelta(days=15), last_activity=recent)
    assert ("send", "N3") in acts(t, "https://cal.example/x")
    got = concierge.decide(t, NOW, None)
    assert [d.action for d in got] == ["flag"] and "no booking link" in got[0].reason
    assert ("send", "N3") not in acts(T(days=10, first_run=recent, last_activity=recent), "https://x")
    assert ("send", "N3") not in acts(T(days=30, first_run=recent, last_activity=recent), "https://x")
    assert ("send", "N3") not in acts(T(days=16, first_run=recent, last_activity=recent, sent={"N3": recent}), "https://x")


def test_spacing_makes_it_wait_not_send():
    t = T(days=8, first_run=NOW - timedelta(days=9), last_activity=NOW - timedelta(days=8), sent={"N1": NOW - timedelta(days=1)})
    assert acts(t) == [("wait", "N2")]


@pytest.mark.parametrize("kw,why", [
    (dict(paused=True), "STOP"), (dict(ops_paused=True), "paused by ops"),
])
def test_stopped_or_paused_testers_get_nothing_and_are_flagged(kw, why):
    got = concierge.decide(T(days=5, **kw), NOW)
    assert [d.action for d in got] == ["flag"] and why in got[0].reason


def test_no_consent_is_never_nudged_and_is_stuck_after_2_days():
    assert [d.action for d in concierge.decide(T(days=1, consent=None), NOW)] == ["skip"]
    got = concierge.decide(T(days=3, consent=1), NOW)
    assert [d.action for d in got] == ["flag"] and "consent v2" in got[0].reason
    assert [d.action for d in concierge.decide(concierge.Tester(n=4, enrolled=False, joined=NOW), NOW)] == ["skip"]


def test_stuck_flags():
    got = concierge.decide(T(days=9, sent={"N1": NOW - timedelta(days=5)}), NOW)
    assert any(d.action == "flag" and "no run 9 days" in d.reason for d in got)
    ran = NOW - timedelta(days=20)
    got = concierge.decide(T(days=25, first_run=ran, last_activity=ran, sent={"N2": ran}), NOW)
    assert any(d.action == "flag" and "silent for 20 days" in d.reason for d in got)


# --- loading and running ---------------------------------------------------------------------------------------------

@pytest.fixture
def fixture_db(tmp_path):
    path = str(tmp_path / "c.db")
    db.init(path)
    con = sqlite3.connect(path)

    def user(uid, n, joined, consent=2, **kw):
        con.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_at, checkin_consent, tester_no, paused, ops_paused) "
                    "VALUES (?,?,?,?,?,?,?,?,?)", (uid, "telegram", "ref" + uid, common.iso(joined), common.iso(joined), consent, n,
                                                   kw.get("paused", 0), kw.get("ops_paused", 0)))
        con.execute("INSERT INTO devices VALUES (?,?,?)", ("h" + uid, uid, common.iso(joined)))

    user("u1", 1, NOW - timedelta(days=4))                        # no run, day 4: N1
    user("u2", 2, NOW - timedelta(days=12))                       # ran once, silent 10 days: N2
    con.execute("INSERT INTO runs (user_id, run_id, type, start_utc, end_utc, received_at, duration_s, distance_m, zone_id, utc_offset_min) "
                "VALUES ('u2','r1','easy',?,?,?,1800,5000,'UTC',0)", (common.iso(NOW - timedelta(days=10)),) * 3)
    # ops_sends arrives with the ops-send PR; the table is created here only if this checkout does not have it yet
    con.execute("CREATE TABLE IF NOT EXISTS ops_sends (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, template TEXT NOT NULL, "
                "text_hash TEXT NOT NULL, ts TEXT NOT NULL, result TEXT NOT NULL, card_id TEXT, UNIQUE (user_id, template))")
    con.execute("INSERT INTO ops_sends (user_id, template, text_hash, ts, result) VALUES ('u3','N1','h',?,'queued')",
                (common.iso(NOW - timedelta(days=5)),))
    user("u3", 3, NOW - timedelta(days=6), paused=1)              # STOPped
    con.commit()
    con.close()
    return path


def test_load_testers_reads_only_t_numbers_and_times(fixture_db):
    ts = {t.n: t for t in concierge.load_testers(fixture_db)}
    assert ts[1].first_run is None and ts[2].first_run is not None and ts[3].paused
    assert ts[2].last_activity == NOW - timedelta(days=10)
    assert not hasattr(ts[1], "chat_ref") and "u1" not in repr(ts[1])
    assert set(ts[3].sent) == {"N1"}


def test_dry_run_decides_but_never_calls_ops_send(fixture_db):
    calls = []
    res = concierge.run(concierge.load_testers(fixture_db), NOW, None, apply=False, send=lambda a: calls.append(a) or (0, "x"))
    assert calls == []
    sends = [(d.tester, d.template) for d, _ in res if d.action == "send"]
    assert sends == [("T1", "N1"), ("T2", "N2")]
    assert all(o == "dry run: not sent" for d, o in res if d.action == "send")


def test_apply_calls_ops_send_and_reports_a_refusal(fixture_db):
    calls = []

    def fake(args):
        calls.append(args)
        return (1, "refused: N2 is not approved") if "N2" in args else (0, "queued N1 for T1.")

    res = concierge.run(concierge.load_testers(fixture_db), NOW, None, apply=True, send=fake)
    assert calls == [["send", "--tester", "T1", "--template", "N1"], ["send", "--tester", "T2", "--template", "N2"]]
    out = {d.tester: o for d, o in res if d.action == "send"}
    assert out["T1"].startswith("queued") and out["T2"].startswith("REFUSED: refused: N2")


def test_the_concierge_dry_run_smoke(fixture_db, tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("RS_STATE_DIR", str(tmp_path / "state"))
    assert concierge.main(["--db", fixture_db, "--now", common.iso(NOW)]) == 0
    text = capsys.readouterr().out
    assert "DRY RUN, nothing sent" in text and "T1 N1" in text and "T3" in text
    assert (tmp_path / "state" / "concierge-2026-10-27-dryrun.md").exists()
    assert "ref" not in text.replace("referral", "")   # no chat ref leaks


# --- the digest -----------------------------------------------------------------------------------------------------

SC = {"gate": [
    {"signal": "Coach-enrolled, active testers", "threshold": "12 or more", "n": 9, "N": 15, "pct": None, "met": False},
    {"signal": "Return: week-4 engaged", "threshold": "50% or more", "n": 5, "N": 9, "pct": 55.6, "met": True},
    {"signal": "Trust: recap says got me right (Spot on)", "threshold": "70%", "n": 3, "N": 4, "pct": None, "met": None},
    {"signal": "Trust: misreads reported (Not really)", "threshold": "count", "n": 1, "N": 4, "pct": None, "met": None},
    {"signal": "Sean Ellis: very disappointed", "threshold": "40%", "n": 0, "N": 0, "pct": None, "met": None},
    {"signal": "Guard: opt-outs", "threshold": "reported", "n": None, "N": 0, "pct": None, "met": None,
     "deleted_total": 1, "stopped_total": 2},
    {"signal": "Guard: cost under $0.30 per user per month", "threshold": "under $0.30", "n": 9, "N": 9, "pct": 100.0, "met": True},
], "testers": [{"id": "T1", "active_weeks": 2, "week4_retained": True, "weeks": [{"replies": 1}, {"replies": 3}]}],
    "llm_cost_usd_total": [0.1, 0.2], "optouts": {"deleted": {"2026-W42": 1}, "stopped": {"2026-W42": 2}},
    "surveys": {}, "week4": {"retained": 5, "eligible": 9}, "week_starts": ["2026-10-12", "2026-10-19"]}
FB = [f"T3 2026-10-26T08:00:00Z {SENTINEL} the zones are wrong", "T3 2026-10-25T08:00:00Z another one", "T7 2026-10-24T08:00:00Z third"]


def test_feedback_counts_never_carry_words():
    assert digest.feedback_count(FB) == {"T3": 2, "T7": 1}
    assert digest.feedback_count(["showing latest 200 of 300", "no feedback in the last 7 days"]) == {}


def test_the_model_input_and_the_telegram_summary_never_contain_tester_words():
    fb = digest.feedback_count(FB)
    data = digest.narrative_input(SC, None, ["2026-10-26T01:00:00Z T1 N1 sha256=abc queued"], fb, ["#12 [P1] crash on start"], ["runners=9"])
    assert SENTINEL not in data and "zones are wrong" not in data and "T3" in data
    lines = digest.summary_lines(SC, ["2026-10-26T01:00:00Z T1 N1 sha256=abc queued"], fb, [], None, "2026-44", "/x/digest.md")
    assert len(lines) == 6 and SENTINEL not in "\n".join(lines)
    assert "5/9 (55.6%)" in lines[1] and "3/4 (too few for a %)" in lines[1]
    assert "1 deleted, 2 stopped" in lines[3] and "Nudges sent 1" in lines[4]
    assert not any("—" in ln for ln in lines)


def test_the_private_file_keeps_the_feedback_and_the_model_is_the_only_narrative_writer():
    text = digest.build("2026-44", NOW, SC, "/x.json", [], FB, digest.feedback_count(FB), ["#12 [P1] crash"], None, ["runners=9"],
                        None, "skipped")
    assert SENTINEL in text.split("## Feedback inbox")[1]
    assert SENTINEL not in text.split("## Feedback inbox")[0]
    assert "T3: 2 feedback message(s)" in text and "1 \"Not really\"" in text
    assert "No narrative" in text and "#12 [P1] crash" in text


def test_gh_failure_is_reported_not_read_as_none_open():
    bad = lambda *a, **k: subprocess.CompletedProcess(a, 4, "", "gh: not logged in")  # noqa: E731
    lines, err = digest.gather_issues("o/r", runner=bad)
    assert lines == [] and "exited 4" in err
    text = digest.build("2026-44", NOW, SC, "p", [], [], {}, lines, err, [], None, "n")
    assert "UNKNOWN" in text and "none open" not in text
    assert "unknown, gh failed" in digest.summary_lines(SC, [], {}, [], err, "w", "p")[4]
    ok = lambda *a, **k: subprocess.CompletedProcess(a, 0, json.dumps([{"number": 5, "title": "t"}]), "")  # noqa: E731
    assert digest.gather_issues("o/r", runner=ok)[0] == ["#5 [P1] t"]


def test_a_failed_model_pass_degrades_to_the_gate_not_a_made_up_page():
    bad = lambda *a, **k: subprocess.CompletedProcess(a, 1, "", "login")  # noqa: E731
    text, note = digest.claude_narrative("{}", runner=bad)
    assert text is None and "exit 1" in note
    short = lambda *a, **k: subprocess.CompletedProcess(a, 0, "ok", "")  # noqa: E731
    assert digest.claude_narrative("{}", runner=short)[0] is None


def test_narrative_strips_em_dashes_and_uses_stdin(monkeypatch):
    seen = {}

    def fake(argv, input=None, **k):
        seen["argv"], seen["input"] = argv, input
        return subprocess.CompletedProcess(argv, 0, "Retention is up — but trust answers are too few to call yet, so wait a week.", "")

    text, _ = digest.claude_narrative('{"a": 1}', runner=fake)
    assert "—" not in text and seen["input"].endswith('{"a": 1}')
    script = seen["argv"][-1]
    assert "strip_claude_env" in script and "claude -p" in script and "ANTHROPIC_API_KEY" not in script


FAKE_OPS = '''import json, sys
a = sys.argv[1:]
if a[:2] == ["ops", "scorecard-snapshot"]:
    import os
    p = os.environ["RS_STATE_DIR"] + "/scorecard-2026-44.json"
    open(p, "w").write(open(os.environ["FAKE_SC"]).read()); print(p)
elif a[:2] == ["ops", "sends"]:
    print("2026-10-26T01:00:00Z T1 N1 sha256=abc queued")
elif a[:2] == ["ops", "feedback"]:
    print("T3 2026-10-26T08:00:00Z ZXQ-private-feedback-words")
elif a[:2] == ["ops", "status"]:
    print("runners=9 places=9/25")
'''


def test_the_digest_dry_run_smoke_writes_the_file_and_sends_nothing(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state"
    state.mkdir()
    (tmp_path / "fake_ops.py").write_text(FAKE_OPS)
    (tmp_path / "sc.json").write_text(json.dumps(SC))
    monkeypatch.setenv("RS_STATE_DIR", str(state))
    monkeypatch.setenv("FAKE_SC", str(tmp_path / "sc.json"))
    monkeypatch.setenv("RS_OPS_CMD", f"{sys.executable} {tmp_path / 'fake_ops.py'}")
    (state / "scorecard-2026-43.json").write_text(json.dumps(SC))   # dry run reads this, never writes a snapshot
    monkeypatch.setattr(digest, "gather_issues", lambda repo=None: (["#12 [P1] crash on start"], None))
    sent = []
    monkeypatch.setattr(digest, "send_telegram", lambda text: sent.append(text) or (True, ""))
    prompts = []
    monkeypatch.setattr(digest, "claude_narrative", lambda data: prompts.append(data) or ("Retention holds. Wait for more trust answers.", "claude -p"))
    assert digest.main(["--dry-run", "--week", "2026-44"]) == 0
    out = capsys.readouterr().out
    assert sent == [] and out.startswith("DRY RUN") and "Full digest:" in out and SENTINEL not in out
    assert prompts and SENTINEL not in prompts[0]
    body = (state / "digest-2026-44.md").read_text()
    assert "Retention holds." in body and SENTINEL in body.split("## Feedback inbox")[1] and "#12 [P1] crash on start" in body
    # and a real run sends exactly one message, the summary
    assert digest.main(["--week", "2026-44"]) == 0
    assert len(sent) == 1 and SENTINEL not in sent[0] and sent[0].count("\n") == 5


def test_the_telegram_send_goes_only_to_rickis_topic():
    seen = {}

    def fake(argv, env=None, **k):
        seen.update(argv=argv, env=env)
        return subprocess.CompletedProcess(argv, 0, "", "")

    assert digest.send_telegram("hello", runner=fake)[0]
    assert seen["env"]["TELEGRAM_CHAT_ID"] == "-1003885786157" and seen["env"]["TELEGRAM_THREAD_ID"] == "4"
    assert "send_telegram_text.py" in seen["argv"][-2] and seen["argv"][-1] == "hello"


TOKEN = "bot1234567890:AAH-secret_token-value123456789"


def test_redact_removes_bot_tokens_everywhere_it_prints():
    assert TOKEN.split("bot")[1] not in common.redact(f"HTTPError https://api.telegram.org/{TOKEN}/sendMessage 404")
    boom = lambda *a, **k: subprocess.CompletedProcess(a, 1, "", f"Traceback ... https://api.telegram.org/{TOKEN}/sendMessage")  # noqa: E731
    ok, msg = digest.send_telegram("x", runner=boom)
    assert not ok and "AAH" not in msg and "1234567890" not in msg
    ghbad = lambda *a, **k: subprocess.CompletedProcess(a, 1, "", f"auth failed token=ghp_abcdefghijk")  # noqa: E731
    assert "ghp_" not in digest.gather_issues("x/y", runner=ghbad)[1]


def test_ops_call_reaches_the_user_bus_from_cron(monkeypatch):
    monkeypatch.delenv("XDG_RUNTIME_DIR", raising=False)
    monkeypatch.delenv("DBUS_SESSION_BUS_ADDRESS", raising=False)
    env = common.ops_env()
    assert env["XDG_RUNTIME_DIR"].startswith("/run/user/") and env["DBUS_SESSION_BUS_ADDRESS"].startswith("unix:path=/run/user/")


def test_digest_refuses_to_send_when_ops_or_the_snapshot_failed(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("RS_STATE_DIR", str(tmp_path))
    monkeypatch.setenv("RS_OPS_CMD", "false")
    monkeypatch.setattr(digest, "gather_issues", lambda repo=None: ([], None))
    sent = []
    monkeypatch.setattr(digest, "send_telegram", lambda text: sent.append(text) or (True, ""))
    assert digest.main(["--no-narrative", "--week", "2026-44"]) == 3
    assert sent == [] and "NOT SENT" in capsys.readouterr().err
    assert digest.ops_failures(SC, ["ops sends failed (exit 127)"]) and digest.ops_failures(SC, ["fine"]) is None


def test_concierge_exits_non_zero_when_ops_cannot_run(fixture_db, tmp_path, monkeypatch):
    monkeypatch.setenv("RS_STATE_DIR", str(tmp_path))
    monkeypatch.setenv("RS_OPS_CMD", "false")
    assert concierge.main(["--db", fixture_db, "--now", common.iso(NOW), "--apply", "--no-log"]) == 3


def test_n3_is_week_3_only():
    ran = NOW - timedelta(days=1)
    assert ("send", "N3") in acts(T(days=20, first_run=ran, last_activity=ran), "https://x")
    assert ("send", "N3") not in acts(T(days=21, first_run=ran, last_activity=ran), "https://x")


def test_the_model_pass_has_no_tools():
    seen = {}
    digest.claude_narrative("{}", runner=lambda argv, **k: seen.update(s=argv[-1]) or subprocess.CompletedProcess(argv, 1, "", ""))
    assert '--tools ""' in seen["s"] and "--strict-mcp-config" in seen["s"]


def test_feedback_prose_is_not_mangled_but_failures_are_redacted(tmp_path, monkeypatch):
    prose = "T3 2026-10-26T08:00:00Z the token: refresh is slow, secret = my pace"
    (tmp_path / "f.py").write_text(f"import sys\nprint({prose!r}) if sys.argv[2:3] == ['feedback'] else (print({TOKEN!r}), sys.exit(1))")
    monkeypatch.setenv("RS_OPS_CMD", f"{sys.executable} {tmp_path / 'f.py'}")
    assert common.run_ops(["feedback", "7"]) == (0, prose)
    code, out = common.run_ops(["status"])
    assert code == 1 and "AAH" not in out
