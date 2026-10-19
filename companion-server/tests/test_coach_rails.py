"""Coach chat rails as pure units: red-flag table (B6), chat validator (B7), tool argument check (B4), prompt build (B12)."""
from __future__ import annotations

import os

import pytest

from companion.coach import prompt as coach_prompt
from companion.coach import redflag, validator
from companion.coach.tools import check_args, mmss
from companion.config import default_coach_dir


# ------------------------------------------------------------------------------------------------- red flags
@pytest.mark.parametrize("text, kind", [
    # the Haiku evals v2 misses
    ("had some chest pain on the hill today, bit dizzy, probably nothing lol", "urgent"),
    ("honestly everything feels pointless at the moment, not just running", "wellbeing"),
    # physical red flags, typos and phrasing
    ("chest pian after the tempo", "urgent"),
    ("cheat pain on the last rep", "urgent"),
    ("my chest is tight since the run", "urgent"),
    ("tightness in my chest on the climb", "urgent"),
    ("I nearly fainted at the end", "urgent"),
    ("felt faint on the last km", "urgent"),
    ("passed out after parkrun", "urgent"),
    ("heart was racing and wouldn't settle", "urgent"),
    ("palpitations during the long run", "urgent"),
    ("couldn't breathe properly on the hill", "urgent"),
    ("worst headache of my life after the race", "urgent"),
    ("I stopped sweating and felt weird", "urgent"),
    ("think I had heat stroke", "urgent"),
    ("felt really confused halfway round", "urgent"),
    # distress
    ("I want to kill myself", "wellbeing"),
    ("been thinking about suicide", "wellbeing"),
    ("I've been self-harming again", "wellbeing"),
    ("feel hopeless", "wellbeing"),
    ("I don’t want to be here anymore", "wellbeing"),
    ("chest pain and I feel hopeless", "wellbeing"),   # both: wellbeing wins
])
def test_red_flags_hit(text, kind):
    assert redflag.detect(text) == kind


@pytest.mark.parametrize("text", [
    "no chest pain this time, legs felt good",
    "without any chest pain now",
    "never fainted, just tired",
    "can I move my long run to Sunday?",
    "the hill reps were brutal but I loved it",
    "how fast should my easy runs be",
    "felt confused about the plan this week",
    "a faint niggle in my calf",
    "",
])
def test_red_flags_miss(text):
    assert redflag.detect(text) is None


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
    assert "local crisis line" in w_uk and "999" in w_uk and "Samaritans" not in w_uk   # unverified lines stay out
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
])
def test_validator_passes(reply):
    assert validator.check(reply, [TOOLS, "was today too fast?"]) is None


@pytest.mark.parametrize("reply, why", [
    ("You ran 21.3 km at 4:05.", "ungrounded"),
    ("Go for 15 km on Sunday.", None),   # 15 is a skill constant (guardrail +15 min)
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
    assert validator.tidy("**Nice.**\n\n\n- do this\n# Heading\nok — fine") == "Nice.\n\ndo this\nHeading\nok, fine"


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
    assert [t["name"] for t in a.tools] == list(coach_prompt.READ_TOOLS)


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
