"""Coach chat rails as pure units: red-flag table (B6), chat validator (B7), tool argument check (B4), prompt build (B12)."""
from __future__ import annotations

import os

import pytest

from companion.coach import prompt as coach_prompt
from companion.coach import redflag, validator
from companion.coach.tools import check_args, mmss
from companion.config import default_coach_dir


# ------------------------------------------------------------------------------------------------- red flags
from redflag_cases import HARMLESS, RED_FLAGS, REVIEW_RED_FLAGS  # noqa: E402

# Unambiguous: answered at once in the webhook, before any classifier, cap or model.
MUST_BE_HARD = {
    "my chest is killing me": "urgent", "chest pian": "urgent", "chest-pain": "urgent", "tightness in chest": "urgent",
    "sharp pain under my sternum": "urgent", "no warning, just collapsed": "urgent", "fainted": "urgent",
    "no sleep fainted at work": "urgent", "pased out": "urgent", "lost consciousness": "urgent", "left arm numb": "urgent",
    "kill myself": "wellbeing", "I want to kill myself": "wellbeing", "i wanna kms": "wellbeing", "overdose": "wellbeing",
    "going to take all my pills": "wellbeing", "i keep thinking about hurting myself": "wellbeing",
    "hurting myself": "wellbeing", "harming myself": "wellbeing", "been thinking about suicide": "wellbeing",
    "no one would miss me": "wellbeing", "nobody cares if im gone": "wellbeing", "I have zero energy and chest pain": "urgent",
    "chest pain and I feel hopeless": "urgent",   # a hard hit beats a soft one
}
# Plain training talk with no regex hit at all (still screened by the classifier, but never failed towards safety).
NO_HIT = ["no chest pain today", "ran 12 kms today", "10 kms easy", "no dizziness at all", "without any chest pain",
          "short break then breathe and go", "heavy legs chest fine", "can I move my long run to Sunday?",
          "how fast should my easy runs be", "never fainted"]


@pytest.mark.parametrize("text", RED_FLAGS)
def test_every_red_flag_phrasing_hits_a_regex_tier(text):
    level, kind = redflag.tier(text)
    assert level in (redflag.HARD, redflag.SOFT) and kind in (redflag.URGENT, redflag.WELLBEING), text


@pytest.mark.parametrize("text", HARMLESS)
def test_harmless_phrasings_are_never_hard(text):
    assert redflag.tier(text)[0] != redflag.HARD, text
    assert redflag.detect(text) is None


@pytest.mark.parametrize("text, kind", sorted(MUST_BE_HARD.items()))
def test_unambiguous_phrasings_are_hard(text, kind):
    assert redflag.tier(text) == (redflag.HARD, kind)
    assert redflag.detect(text) == kind


@pytest.mark.parametrize("text", NO_HIT)
def test_plain_training_talk_has_no_regex_hit(text):
    assert redflag.tier(text) == (None, None)


def test_regex_tier_counts_on_the_101_phrasings():
    """Recorded for the PR: on the reviewer's 81 red flags and 20 harmless phrasings."""
    pos = REVIEW_RED_FLAGS
    missed = [t for t in pos if redflag.tier(t)[0] is None]
    hard_false = [t for t in HARMLESS if redflag.tier(t)[0] == redflag.HARD]
    assert missed == [] and hard_false == []
    assert sum(redflag.tier(t)[0] == redflag.HARD for t in pos) >= 45


def test_templates_by_country():
    nz = redflag.template("urgent", "Pacific/Auckland")
    assert "111" in nz and "doctor today" in nz
    assert "000" in redflag.template("urgent", "Australia/Sydney")
    assert "999" in redflag.template("urgent", "Europe/London")
    assert "911" in redflag.template("urgent", "America/Chicago")
    assert "112 or 911" in redflag.template("urgent", "UTC")
    w_nz = redflag.template("wellbeing", "Pacific/Auckland")
    assert "1737" in w_nz and "111" in w_nz
    w_au = redflag.template("wellbeing", "Australia/Perth")
    assert "13 11 14" in w_au and "0477 13 11 14" in w_au and "000" in w_au
    w_uk = redflag.template("wellbeing", "Europe/London")
    assert "Samaritans" in w_uk and "116 123" in w_uk and "999" in w_uk
    w_us = redflag.template("wellbeing", "America/New_York")
    assert "988" in w_us and "911" in w_us
    w_za = redflag.template("wellbeing", "Africa/Johannesburg")
    assert "local crisis line" in w_za and "10111" in w_za   # unverified lines stay out
    w_sg = redflag.template("wellbeing", "Asia/Singapore")
    assert "local crisis line" in w_sg and "995" in w_sg
    for t in (nz, w_nz, w_au, w_uk):
        assert "http" not in t and "—" not in t   # plain, no links, no em dash


# ------------------------------------------------------------------------------------------------- validator
TOOLS = '{"ok":true,"runs":[{"distance_km":7.0,"pace_per_km":"5:42","duration":"40:00","day":"2026-10-20","weekday":"Tue"}]}'


@pytest.mark.parametrize("reply", [
    "That 7.0 km at 5:42 was a proper easy run.",
    "That 7 km took you 40 minutes, about right.",
    "Tuesday's run on the 20th was easy enough.",
    "Do 2 easy runs and a 4x4 this week.",
    "Take 3 days off running.",
    "If it keeps hurting, see a physio or a doctor.",
    "In NZ you can call or text 1737, or 111 if it's urgent.",
    "Keep long runs under 35% of the week.",
    # crisis numbers that end a sentence (re-review of #341, P1-3)
    "Call 111.", "In NZ you can text 1737.", "Call Lifeline on 13 11 14.", "You can call or text 988.",
    "Call Samaritans on 116 123.",
])
def test_validator_passes(reply):
    assert validator.check(reply, [TOOLS, "was today too fast?"]) is None


@pytest.mark.parametrize("reply, why", [
    ("You ran 21.3 km at 4:05.", "ungrounded"),
    ("Go for 15 km on Sunday.", "ungrounded"),   # 15 is a skill constant, but never as a measurement
    # the review of #341 (P2-3): constants and crisis digits are not data
    ("Do 20 km this week.", "ungrounded"), ("You ran 10 km.", "ungrounded"), ("Your 30 min tempo was fine.", "ungrounded"),
    ("Try 13 km on Sunday.", "ungrounded"), ("Aim for 11 km.", "ungrounded"),
    ("Go for twelve kilometres.", "spelled_measure"), ("Run ten minutes easy.", "spelled_measure"),
    ("Run 45 minutes tomorrow.", "ungrounded"),
    ("Check https://example.com for drills.", "link"),
    ("Read runsupreme.com tips.", "link"),
    ("Call me on 021 555 1234.", "phone_like"),
    ("That was about 4 miles.", "foreign_unit"),
    ("", "empty"),
])
def test_validator_rejects(reply, why):
    got = validator.check(reply, [TOOLS])
    if why is None:
        assert got is None
    else:
        assert got and got.startswith(why), got


def test_runner_numbers_count_as_grounded():
    assert validator.check("Going for 1:55 at the half is ambitious but fair.", [TOOLS, "am I on track for 1:55?"]) is None


def test_tidy_removes_markdown():
    assert validator.tidy("**Nice.**\n\n\n- do this\n# Heading\nok — fine") == "<b>Nice.</b>\n\n• do this\nHeading\nok — fine"


# ------------------------------------------------------------------------------------------------- tool args
SCHEMA = {"type": "object", "properties": {"days": {"type": "integer", "minimum": 1, "maximum": 365, "default": 42},
                                           "type": {"type": "string", "enum": ["any", "easy"], "default": "any"}},
          "additionalProperties": False}


def test_check_args():
    assert check_args(SCHEMA, {}) == ({"days": 42, "type": "any"}, None)
    assert check_args(SCHEMA, {"days": 7})[0] == {"days": 7, "type": "any"}
    assert check_args(SCHEMA, {"days": 0})[1] == "days is out of range"
    assert check_args(SCHEMA, {"days": True})[1] == "days must be a whole number"
    assert check_args(SCHEMA, {"type": "fast"})[1].startswith("type must be one of")
    assert check_args(SCHEMA, {"user_id": "u_x"})[1] == "unknown argument(s): user_id"
    assert check_args(SCHEMA, [1])[1] == "arguments must be an object"
    req = {"type": "object", "properties": {"run_id": {"type": "string"}}, "required": ["run_id"], "additionalProperties": False}
    assert check_args(req, {})[1] == "missing argument: run_id"


def test_mmss():
    assert mmss(342.0) == "5:42" and mmss(2400) == "40:00" and mmss(3725) == "1:02:05" and mmss(None) is None


# ------------------------------------------------------------------------------------------------- prompt (B12)
def test_prompt_is_built_from_the_skill_with_a_stable_hash():
    d = default_coach_dir()
    assert os.path.isfile(os.path.join(d, "scripts", "build_prompt.py"))
    a, b = coach_prompt.load(d), coach_prompt.load(d)
    assert a.prompt_hash == b.prompt_hash and len(a.prompt_hash) == 16
    assert a.text.startswith("# Run Supreme coach")
    assert '<reference name="safety">' in a.text and "<host name=" in a.text
    assert {t["name"] for t in a.tools} >= set(coach_prompt.READ_TOOLS) | {"calc_pace", "web_search", "get_weather"}


def test_prompt_hash_changes_with_the_skill(tmp_path):
    import shutil
    d = tmp_path / "coach"
    shutil.copytree(default_coach_dir(), d)
    before = coach_prompt.load(str(d)).prompt_hash
    with open(d / "references" / "voice.md", "a") as f:
        f.write("\nOne more line.\n")
    assert coach_prompt.load(str(d)).prompt_hash != before


def test_history_alternates_and_starts_with_the_runner():
    from companion.coach.chat import alternate
    h = [{"role": "assistant", "content": "a0"}, {"role": "user", "content": "u1"}, {"role": "user", "content": "u2"},
         {"role": "assistant", "content": "a1"}, {"role": "assistant", "content": "a2"}, {"role": "user", "content": "u3"}]
    assert alternate(h) == [{"role": "user", "content": "u1\nu2"}, {"role": "assistant", "content": "a1\na2"},
                            {"role": "user", "content": "u3"}]


# ------------------------------------------------------------------------------------------------- classifier parse
def _ans(content):
    return {"choices": [{"message": {"content": content}}]}


OK_JSON = '{"urgent_medical": false, "self_harm": true, "injury": false}'


@pytest.mark.parametrize("content", [
    OK_JSON,
    "  " + OK_JSON + "\n",
    "```json\n" + OK_JSON + "\n```",
    "```\n" + OK_JSON + "\n```",
])
def test_screen_parse_accepts_one_exact_object(content):
    from companion.coach import screen
    assert screen.parse(_ans(content)) == {"urgent_medical": False, "self_harm": True, "injury": False}


@pytest.mark.parametrize("content", [
    "Sure! " + OK_JSON,                                                              # prose before
    OK_JSON + " Hope that helps.",                                                   # prose after
    OK_JSON + "\n" + OK_JSON,                                                        # two objects
    '{"urgent_medical": false, "self_harm": false, "injury": false, "note": "x"}',   # extra key
    '{"urgent_medical": false, "self_harm": false}',                                 # missing key
    '{"urgent_medical": "false", "self_harm": false, "injury": false}',              # not a bool
    '{"urgent_medical": 0, "self_harm": false, "injury": false}',                    # 0 is not a bool
    "```json\n" + OK_JSON + "\n``` and more",                                        # prose after the fence
    "[" + OK_JSON + "]",                                                             # not an object
    "",
])
def test_screen_parse_rejects_anything_else(content):
    from companion.coach import screen
    assert screen.parse(_ans(content)) is None


def test_screen_turns_thinking_off():
    # Thinking ate the whole 60-token budget on ambiguous text in the real eval (19-Oct): no answer, fail-closed.
    from companion.coach import screen
    body = screen.request_body("anthropic/claude-haiku-5.5", "feel hopeless", 60)
    assert body["reasoning"] == {"enabled": False}
    assert body["provider"] == {"zdr": True, "data_collection": "deny", "allow_fallbacks": False}
