"""Trail facts the app sends with a run matched to one of its trails, and the two trail cards they earn.

The app owns trail matching (like for like, pace-normalised per #274); the server only stores what the card draws: whole
numbers and a fixed enum. The elevation profile is metres relative to the start, never absolute altitude, and there are no
coordinates and no dates anywhere in it. `name` is a place, so the app sends it only with the runner's place opt-in.
"""
from __future__ import annotations

import json
from typing import Any, Mapping

from render.protocol import normalize_trail_name, trail_name_ok
from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, ValidationError, field_validator, model_validator

PROFILE_MAX = 64
BOARD_MAX = 10
BOARD_CARD_MIN_RUNS = 3     # the board starts from the 3rd run of a trail
TRAIL_KINDS = ("trail_record", "trail_board", "trail_heart")
HR_MIN, HR_MAX = 30, 250     # bpm bounds of one heart-rate point


class BoardRow(BaseModel):
    model_config = ConfigDict(extra="forbid")
    attempt: StrictInt = Field(ge=1, le=999)
    time_s: StrictInt = Field(ge=1, le=86400)   # the pace-normalised time (#274)
    today: StrictBool = False
    rank: StrictInt | None = Field(default=None, ge=1, le=999)   # the app's true rank among ALL runs of this trail, ties sharing one


class TrailIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    n: StrictInt = Field(ge=1, le=999)   # runs of this trail including this one
    board: list[BoardRow] = Field(min_length=2, max_length=BOARD_MAX)
    profile: list[StrictInt] | None = Field(default=None, min_length=2, max_length=PROFILE_MAX)
    ghost_gap: list[StrictInt] | None = Field(default=None, min_length=2, max_length=PROFILE_MAX)
    elev_src: str | None = Field(default=None, pattern=r"^(baro|gps)$")   # how the profile was measured; absent counts as gps
    turn: StrictInt | None = Field(default=None, ge=0, le=PROFILE_MAX - 1)
    shape: str | None = Field(default=None, pattern=r"^(out_and_back|loop|one_way)$")
    name: str | None = Field(default=None, min_length=1, max_length=30)
    hr: list[StrictInt] | None = Field(default=None, min_length=2, max_length=PROFILE_MAX)   # bpm along the same progress axis as the profile; strap runs with the app's switch on
    hr_z: list[StrictInt] | None = Field(default=None, min_length=2, max_length=PROFILE_MAX)   # the runner's own zone (1-5) of each hr point, so the card never guesses their zones

    @field_validator("hr")
    @classmethod
    def _hr_range(cls, v):
        if v is not None and not all(HR_MIN <= x <= HR_MAX for x in v):
            raise ValueError("hr out of range")
        return v

    @field_validator("hr_z")
    @classmethod
    def _hr_z_range(cls, v):
        if v is not None and not all(1 <= x <= 5 for x in v):
            raise ValueError("hr_z out of range")
        return v

    @field_validator("profile")
    @classmethod
    def _profile_range(cls, v):
        if v is not None and not all(-2000 <= x <= 9000 for x in v):
            raise ValueError("profile out of range")
        return v

    @field_validator("ghost_gap")
    @classmethod
    def _gap_range(cls, v):
        if v is not None and not all(-3600 <= x <= 3600 for x in v):
            raise ValueError("ghost_gap out of range")
        return v

    @model_validator(mode="after")
    def _consistent(self):
        if sum(1 for r in self.board if r.today) != 1 or len({r.attempt for r in self.board}) != len(self.board):
            raise ValueError("board needs exactly one today row and distinct attempts")
        if self.n < len(self.board):
            raise ValueError("n is smaller than the board")
        if self.turn is not None and (self.profile is None or self.turn >= len(self.profile)):
            raise ValueError("turn is not an index into the profile")
        if self.hr is not None and (self.profile is None or len(self.hr) != len(self.profile)):
            raise ValueError("hr must have one point per profile point")
        if (self.hr_z is None) != (self.hr is None) or (self.hr is not None and len(self.hr_z) != len(self.hr)):
            raise ValueError("hr and hr_z come together, one zone per point")
        return self

    @field_validator("name", mode="wrap")
    @classmethod
    def _name_is_a_label(cls, v, handler):
        """A name that is digits only, has an @ or looks like a link is dropped (the card says "Your trail"); the trail stays."""
        try:
            out = handler(normalize_trail_name(v))   # NFKC first: a fullwidth @ or dot must not slip past the filter
        except ValidationError:
            return None
        return out if out is None or trail_name_ok(out) else None


def parse(raw: Any) -> TrailIn | None:
    """A bad trail block drops the trail, never the run: it only adds a card."""
    try:
        return TrailIn.model_validate(raw)
    except ValidationError:
        return None


def dump(t: TrailIn | None, keep_name: bool = False, keep_hr: bool = False) -> str | None:
    """The stored form. A trail name is a place: it is kept only while the runner's place opt-in is on. A heart-rate series is
    health data: it is kept only while the "Heart rate on cards" switch is on (the app sends it only then, this is the second lock)."""
    if t is None:
        return None
    d = t.model_dump(exclude_none=True)
    if not keep_name:
        d.pop("name", None)
    if not keep_hr:
        d.pop("hr", None)
        d.pop("hr_z", None)
    return json.dumps(d, separators=(",", ":"))


def load(raw: str | None) -> dict | None:
    try:
        d = json.loads(raw) if raw else None
    except ValueError:
        return None
    t = parse(d) if isinstance(d, dict) else None
    return t.model_dump(exclude_none=True) if t else None


def card_kind(trail: Mapping[str, Any] | None) -> str | None:
    """trail_record on a trail best (today strictly under every other row); else trail_board from the 3rd run. A record
    outranks a board, and a trail run never also gets the generic PB card. A board run with a heart-rate series (strap, switch
    on) is drawn as trail_heart, the heart against the hill, in the board's place."""
    if not trail:
        return None
    rows = trail["board"]
    today = next(r for r in rows if r.get("today"))
    others = [r["time_s"] for r in rows if not r.get("today")]
    if others and today["time_s"] < min(others):
        return "trail_record"
    if trail["n"] >= BOARD_CARD_MIN_RUNS and len(rows) >= BOARD_CARD_MIN_RUNS:
        return "trail_heart" if trail.get("hr") and trail.get("profile") else "trail_board"
    return None


def card_facts(run: Mapping[str, Any], trail: Mapping[str, Any]) -> dict[str, Any]:
    """The render facts for a trail card, from the stored run row and trail block."""
    facts: dict[str, Any] = {
        "type": "trail", "duration_s": run["duration_s"], "trail_runs": trail["n"],
        "trail_board": [dict(r) for r in trail["board"]],
    }
    if run["distance_m"] >= 10:   # the protocol wants 0.01 km or more: a 0 m run keeps its card, minus the distance
        facts["distance_km"] = run["distance_m"] / 1000
    if run.get("pace_s_per_km"):
        facts["pace_s_per_km"] = run["pace_s_per_km"]
    if run.get("climb_m"):
        facts["climb_m"] = run["climb_m"]
    for src, dst in (("profile", "elev_profile"), ("elev_src", "elev_src"), ("ghost_gap", "ghost_gap"), ("turn", "turn_idx"), ("shape", "trail_shape"),
                     ("name", "trail_name"), ("hr", "hr_series"), ("hr_z", "hr_zones")):
        if trail.get(src) is not None:
            facts[dst] = trail[src]
    return facts
