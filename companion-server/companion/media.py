"""Turns a stored card (convo_cards.media_json) into bytes a channel can upload.

Numbers come only from the stored run rows (B4): the card text is already validated, and the image facts are
read straight from the same rows, never from the LLM. The server holds no GPS track. It holds the route SHAPE the app
sends (a unit-box outline, no coordinates) and per-km splits and rep times, in the run_shape table. With a shape and
splits a run video (route, then splits, then the verdict) is rendered; a run without them gets the still card. A
weekly recap video only needs per-day zone time, which the rows have.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .convo.touches import _zone_minutes
from .facts import GOAL_PURPOSE, known_session
from render import protocol as P

from .render_client import RenderClient
from .trail import card_facts as trail_card_facts
from .timeutil import parse_iso, to_local

log = logging.getLogger("companion")

PHOTO_MAX_BYTES = P.PHOTO_MAX_BYTES    # Telegram sendPhoto; the worker protocol enforces the same caps
VIDEO_MAX_BYTES = P.VIDEO_MAX_BYTES    # Telegram bot upload ceiling
WIDTH, HEIGHT = 1080, 1350
SCORE_KEYS = ("aerobic", "speed", "mid", "long")
PB_LABEL = {"5k": "5 KM BEST", "10k": "10 KM BEST", "half": "HALF MARATHON BEST", "longest": "LONGEST RUN",
            "fastest_km": "FASTEST KM"}
VERDICTS = frozenset({"faster", "holding", "slower", "noRealChange", "baselineSet", "indoorRun"})
GHOST_CLIP_S = 6      # the clip's length (render/motion/ghost_clip.py DURATION)
CLIP_CACHE_MAX = 4    # rendered clips kept for an outbox retry, so a retried send does not render again


class MediaError(Exception):
    """A render failed. The caller falls back to the text card."""


@dataclass(frozen=True)
class Media:
    photo: bytes | None = None
    video: bytes | None = None
    width: int = WIDTH
    height: int = HEIGHT
    duration_s: int = 0
    spoiler: bool = False   # Telegram has_spoiler on the photo: a tap to reveal
    animation: bool = False             # send `video` with sendAnimation: it autoplays and loops in the chat (the ghost race clip)
    animation_file_id: str | None = None   # Telegram's id of an animation this bot already sent: re-sent without an upload
    sent: dict = field(default_factory=dict, compare=False)   # the channel notes what Telegram answered here (file_id)

    @property
    def has_content(self) -> bool:
        return bool(self.photo or self.video or self.animation_file_id)


def _zone_s(row: Mapping[str, Any]) -> list[float]:
    z = _zone_minutes(row)
    return [round(z.get(i, 0.0) * 60, 1) for i in range(1, 6)]


TITLE = {"easy": "Easy run", "long": "Long run", "tempo": "Tempo", "interval": "Intervals", "race": "Race",
         "cooper": "Cooper test", "trail": "Trail run"}
VIDEO_VERDICT = {"faster": "faster", "holding": "holding", "slower": "slower", "noRealChange": "holding"}


def run_facts(run: Mapping[str, Any], headline: str) -> dict[str, Any]:
    """Image facts for one run, from its stored row only. The run_shape row, when the caller joined it as `_shape`,
    adds `route_xy` (the unit-box outline), `splits` and, for an interval run, `reps`."""
    facts: dict[str, Any] = {
        # the app's own name wins for test and trail runs: a Cooper test is not a "Race"
        "type": run["app_type"] if run.get("app_type") in ("cooper", "trail") else run["type"],
        "start_local": to_local(parse_iso(run["start_utc"]), run["zone_id"]).strftime("%Y-%m-%dT%H:%M"),
        "distance_km": run["distance_m"] / 1000,
        "duration_s": run["duration_s"],
        "headline": headline,
    }
    if run.get("pace_s_per_km"):
        facts["pace_s_per_km"] = run["pace_s_per_km"]
    zs = _zone_s(run)
    if any(zs):
        facts["zone_s"] = zs
    if run.get("climb_m"):
        facts["climb_m"] = run["climb_m"]
    if run.get("locality"):
        facts["place_note"] = run["locality"]
    if run.get("verdict") in VERDICTS:
        facts["verdict"] = run["verdict"]
    if run.get("pb") in PB_LABEL:
        facts["pb"] = run["pb"]
        facts["pb_detail"] = {"label": PB_LABEL[run["pb"]]}
    shape = run.get("_shape") or {}
    if shape.get("route"):
        facts["route_xy"] = shape["route"]
    if shape.get("splits"):
        facts["splits"] = shape["splits"]
    if shape.get("reps") and run["type"] == "interval":
        facts["reps"] = shape["reps"]
    if run.get("work_pace_s_per_km") and run["type"] == "interval":
        facts["work_pace_s_per_km"] = run["work_pace_s_per_km"]
    return facts


SHARE_PICTURE_KINDS = ("light", "flood", "pb")   # the run cards whose picture is the share image


def share_optins(facts: Mapping[str, Any]) -> dict[str, bool]:
    """What the share image may show for a run card. The picture goes to the runner's own chat, so their own numbers are
    fine; place names stay off (no place switch here) and the route follows its switch via the shape's presence."""
    return {"route": bool(facts.get("route_xy")), "time": True, "climb": True, "reps": True, "pace": True}


NEUTRAL_RUN_TYPE = {"goal": "tempo", "free": "long"}   # the colour a no-verdict run takes: goal violet (MID), free ice (LONG)


def video_facts(facts: Mapping[str, Any], session_name: str | None = None,
                app_type: str | None = None) -> dict[str, Any] | None:
    """Facts for the route -> splits -> verdict video, or None when this run cannot have one (no shape or no splits). A run
    whose verdict is missing or has no faster/slower/holding word (free, goal and trail runs have no comparison) gets the
    neutral "done" treatment: its name, distance and time, never a pace claim. The name is the built-in session name
    (`session_name`; a custom code is not one) else the run type, and goes out only as the allowed `title`. A goal or free
    run takes its brand colour through `type`. A PB run uses its ordinary verdict: the server never holds the old best
    time that the PB layout needs, so it is not drawn, and a PB with no verdict is neutral too."""
    verdict = VIDEO_VERDICT.get(str(facts.get("verdict")), "done")
    if not facts.get("route_xy") or not facts.get("splits"):
        return None
    out = {k: v for k, v in facts.items() if k not in ("pb", "pb_detail")}
    out["verdict"], out["title"] = verdict, TITLE.get(str(facts.get("type")), "Run")
    if verdict == "done":
        known = known_session(session_name)
        if known and len(known[0]) <= P.TITLE_MAX:
            out["title"] = known[0]
        elif app_type in ("free", "laps"):
            out["title"] = "Free run"
        kind = "goal" if known and known[1] == GOAL_PURPOSE else app_type
        if kind in NEUTRAL_RUN_TYPE and facts.get("type") not in ("interval", "race"):   # keep a hard run's flood
            out["type"] = NEUTRAL_RUN_TYPE[kind]
    return out


def week_bounds(week_ref: str) -> tuple[date, date]:
    y, w = week_ref.split("-W")
    monday = date.fromisocalendar(int(y), int(w), 1)
    return monday, monday + timedelta(days=6)


def week_facts(week_ref: str, runs: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Weekly recap facts from the week's rows. `runs` may hold other weeks; only this ISO week is used."""
    monday, _ = week_bounds(week_ref)
    days = [{"date": (monday + timedelta(days=i)).isoformat(), "distance_km": 0.0, "zone_s": [0.0] * 5} for i in range(7)]
    mine, moves = [], {k: 0.0 for k in SCORE_KEYS}
    seen_move = False
    for r in runs:
        loc = to_local(parse_iso(r["start_utc"]), r["zone_id"])
        if loc.date() < monday or loc.date() > monday + timedelta(days=6):
            continue
        mine.append(r)
        d = days[(loc.date() - monday).days]
        if r["distance_m"] >= d.get("_longest", 0):  # the day's longest run names its type
            d["_longest"], d["type"] = r["distance_m"], r["type"]
        d["distance_km"] += r["distance_m"] / 1000
        d["zone_s"] = [a + b for a, b in zip(d["zone_s"], _zone_s(r))]
        sd = r.get("scores_delta")
        sd = json.loads(sd) if isinstance(sd, str) else (sd or {})
        for k in SCORE_KEYS:
            if isinstance(sd.get(k), (int, float)):
                moves[k] += sd[k]
                seen_move = True
    for d in days:
        d.pop("_longest", None)
    from .convo.recap import best_moment
    facts: dict[str, Any] = {
        "week_label": f"Week {int(week_ref.split('-W')[1])}",
        "distance_km": sum(r["distance_m"] for r in mine) / 1000,
        "runs": len(mine),
        "duration_s": sum(r["duration_s"] for r in mine),
        "days": days,
    }
    paced = [(r["duration_s"] / (r["distance_m"] / 1000)) for r in mine if r["distance_m"] >= 1000 and r["duration_s"] > 0]
    km = facts["distance_km"]
    if km >= 1 and facts["duration_s"] > 0:  # the week's total time over its total km, runs only
        facts["pace_s_per_km"] = facts["duration_s"] / km
    if len(paced) >= 2:  # a lone run's pace is the average, so "quickest" only shows with two or more
        facts["quickest_pace_s_per_km"] = min(paced)
    if seen_move:
        facts["score_moves"] = {k: round(v) for k, v in moves.items()}
    text = best_moment(mine, mine[0]["zone_id"]) if mine else ""
    if text:
        facts["best_moment"] = {"text": text}
    return facts


def month_facts(month_ref: str, runs: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Monthly poster facts ('YYYY-MM') from the stored run rows: the route-less calendar layout. Per run only its day,
    type, distance and duration, the same fields /v1/me already lists; no route, place, run id or zones."""
    from .convo.recap import MONTH_NAMES, month_runs
    y, m = int(month_ref[:4]), int(month_ref[5:])
    mine = sorted(month_runs(runs, runs[0]["zone_id"] if runs else "UTC", month_ref), key=lambda r: r["start_utc"])
    out_runs = [{"date": to_local(parse_iso(r["start_utc"]), r["zone_id"]).date().isoformat(), "type": r["type"],
                 "distance_km": round(r["distance_m"] / 1000, 1), "duration_s": r["duration_s"]} for r in mine]
    return {
        "month_label": MONTH_NAMES[m - 1],
        "month_start": date(y, m, 1).isoformat(),
        "run_count": len(mine),
        "distance_km": round(sum(r["distance_m"] for r in mine) / 1000, 1),
        "duration_s": sum(r["duration_s"] for r in mine),
        "runs": out_runs,
    }


# Cards the worker can draw from stored rows (run, week, month) or from facts persisted in the plan (suggestion).
CARD_KINDS = ("light", "flood", "pb", "share", "weekly_recap", "suggestion", "milestone", "race_countdown", "monthly",
              "trail_board", "trail_record", "trail_heart")
# Coach check-in cards (stream S2): drawn from facts the caller builds, never from stored rows.
CHECKIN_KINDS = ("today", "today_verdict", "moved", "pinned_week")
ROW_KINDS = ("light", "flood", "pb", "weekly_recap", "monthly", "trail_board", "trail_record", "trail_heart")


def _default_card_fns(client: RenderClient) -> dict[str, Callable[..., bytes]]:
    """Cards come from the render worker. `memory` is never sent: nothing the worker draws needs a name."""
    def make(kind: str) -> Callable[..., bytes]:
        return lambda facts, memory=None: client.card(kind, facts)
    return {k: make(k) for k in (*CARD_KINDS, *CHECKIN_KINDS)}


def _default_video_fns(client: RenderClient | None = None) -> dict[str, Callable[..., Any]]:
    def run(facts: dict, out: Path) -> Any:
        if not facts.get("splits") or not facts.get("route_xy"):  # decide here, without a worker round trip
            raise MediaError("run video needs a route shape and splits")
        out.write_bytes(_client(client).video("run", facts))

    def weekly(facts: dict, out: Path) -> Any:
        out.write_bytes(_client(client).video("weekly", facts))
    def ghostclip(facts: dict, out: Path) -> Any:
        out.write_bytes(_client(client).video("ghostclip", facts))
    return {"run": run, "weekly": weekly, "ghostclip": ghostclip}


def _client(client: RenderClient | None) -> RenderClient:
    return client or RenderClient(default_socket_path())


def default_socket_path() -> str:
    return os.environ.get("COMPANION_RENDER_SOCKET") or os.path.expanduser("~/companion-data/render/render.sock")


class MediaRenderer:
    """Renders through the worker socket by default (Chromium and ffmpeg live in the worker unit, never here);
    tests inject fakes."""

    def __init__(self, card_fns: Mapping[str, Callable[..., bytes]] | None = None,
                 video_fns: Mapping[str, Callable[..., Any]] | None = None, client: RenderClient | None = None):
        self._cards, self._videos = card_fns, video_fns
        self._clips: dict[tuple[str, str], bytes] = {}   # (user_id, run_id): a run id is only unique per runner
        self._client = client or RenderClient(default_socket_path())

    @property
    def cards(self) -> Mapping[str, Callable[..., bytes]]:
        if self._cards is None:
            self._cards = _default_card_fns(self._client)
        return self._cards

    @property
    def videos(self) -> Mapping[str, Callable[..., Any]]:
        if self._videos is None:
            self._videos = _default_video_fns(self._client)
        return self._videos

    def _video(self, kind: str, facts: dict) -> bytes | None:
        """None means 'no video for this one' (missing data, ffmpeg absent, too big). Never raises."""
        try:
            fn = self.videos[kind]
            with tempfile.TemporaryDirectory(prefix="rs-video-") as d:
                out = Path(d) / "m.mp4"
                fn(facts, out)
                data = out.read_bytes()
        except Exception as e:  # missing splits, ffmpeg absent, validation: the still card still goes
            log.warning("video skipped: %s", type(e).__name__)
            return None
        if not data or len(data) > VIDEO_MAX_BYTES:
            log.warning("video skipped: size %d", len(data))
            return None
        return data

    @staticmethod
    def ghost_clip_ok(facts: Mapping[str, Any]) -> bool:
        """The ghost race clip needs a hill to run along, a ghost series and another run to race: n >= 2 on the trail."""
        return (int(facts.get("trail_runs") or 0) >= 2 and isinstance(facts.get("ghost_gap"), list)
                and isinstance(facts.get("elev_profile"), list) and len(facts["elev_profile"]) >= 8)

    def _ghost_media(self, key: tuple[str, str], facts: dict, memory: Mapping[str, Any] | None) -> Media | None:
        """The race clip for a trail record, with the static record card beside it as the fallback the channel uses when
        Telegram refuses the animation. None when the clip cannot be made: the caller then sends the card as before. One
        render at a time, in the worker: the clip first, then the card."""
        video = self._clips.get(key) or self._video("ghostclip", facts)
        if video is None:
            return None
        while len(self._clips) >= CLIP_CACHE_MAX:
            self._clips.pop(next(iter(self._clips)))
        self._clips[key] = video
        try:
            photo = self.cards["trail_record"](facts, memory or {})
        except Exception as e:   # the clip alone is enough to send
            log.warning("ghost clip fallback card skipped: %s", type(e).__name__)
            photo = None
        if photo and len(photo) > PHOTO_MAX_BYTES:
            photo = None
        return Media(photo=photo or None, video=video, duration_s=GHOST_CLIP_S, animation=True)

    def render(self, plan: Mapping[str, Any], card: Mapping[str, Any], runs: Sequence[Mapping[str, Any]],
               memory: Mapping[str, Any] | None = None, clip: bool = True) -> Media | None:
        """None when the plan has no media. Raises MediaError when a planned still card cannot be made. A trail record
        with a ghost series goes out as the race clip instead of the still (`clip=False` keeps the still)."""
        kind = plan.get("card")
        if kind == "suggestion":
            # The evening suggestion's facts were stored when the coach decided to send it. An older card, written
            # before they were kept, has none: it stays text.
            facts = plan.get("facts")
            if not isinstance(facts, dict) or not facts:
                return None
            return self._still(kind, facts, memory)
        if kind not in ROW_KINDS:
            return None
        try:
            if kind == "monthly":
                facts = month_facts(str(card["run_id"]).split("monthly:", 1)[1], runs)
                if not facts["run_count"]:
                    raise MediaError("monthly: no runs")
                return self._still(kind, facts, memory)
            if kind == "weekly_recap":
                week_ref = str(card["run_id"]).split("recap:", 1)[1]
                facts = week_facts(week_ref, runs)
                vkind, vfacts = "weekly", {**facts, "duration_s": sum(sum(d["zone_s"]) for d in facts["days"])}
            elif kind in ("trail_board", "trail_record", "trail_heart"):
                run = next(r for r in runs if r["run_id"] == card["run_id"])
                trail = (run.get("_shape") or {}).get("trail")
                if not trail:
                    raise MediaError("trail block gone")
                facts = trail_card_facts(run, trail)
                if kind == "trail_heart" and "hr_series" not in facts:
                    kind = "trail_board"   # the runner turned the switch off while this was queued: the board, not text
                if kind != "trail_heart":   # heart rate goes to the worker only for the card that draws it
                    facts.pop("hr_series", None)
                    facts.pop("hr_zones", None)
                if kind == "trail_record" and clip and self.ghost_clip_ok(facts):
                    ghost = self._ghost_media((str(run.get("user_id") or ""), str(card["run_id"])), facts, memory)
                    if ghost is not None:
                        return ghost
                vkind, vfacts = "run", None   # no video: the picture is the moment
            else:
                run = next(r for r in runs if r["run_id"] == card["run_id"])
                facts = run_facts(run, card["headline"])
                vkind, vfacts = "run", video_facts(facts, run.get("session_name"), run.get("app_type"))
            photo = None
            if kind in SHARE_PICTURE_KINDS:
                photo = self._share_picture(facts)
            if photo is None:
                photo = self.cards[kind](facts, memory or {})
        except Exception as e:
            raise MediaError(f"{kind}: {type(e).__name__}") from None
        if not photo or len(photo) > PHOTO_MAX_BYTES:
            raise MediaError(f"{kind}: photo size {len(photo or b'')}")
        if plan.get("video") and vfacts is None:
            log.warning("planned video dropped for %s run %s: no route shape or splits", kind, card.get("run_id"))
        video = self._video(vkind, vfacts) if plan.get("video") and vfacts is not None else None
        return Media(photo=photo, video=video, duration_s=13 if video else 0)


    def _share_picture(self, facts: Mapping[str, Any]) -> bytes | None:
        """The 9:16 share image sent with a run's post-run message. None on any failure (or an oversized file): the caller
        then draws the older card. The route is drawn only when the app sent its shape, which its "Show route shape on
        cards" switch controls (switching it off forgets every stored shape), so the opt-in is the shape's presence."""
        try:
            photo = self.cards["share"]({**facts, "share": share_optins(facts)}, {})
        except Exception as e:
            log.warning("share picture failed, falling back to the older card: %s", type(e).__name__)
            return None
        return photo if photo and len(photo) <= PHOTO_MAX_BYTES else None

    def _still(self, kind: str, facts: Mapping[str, Any], memory: Mapping[str, Any] | None) -> Media:
        try:
            photo = self.cards[kind](dict(facts), memory or {})
        except MediaError:
            raise
        except Exception as e:
            raise MediaError(f"{kind}: {type(e).__name__}") from None
        if not photo or len(photo) > PHOTO_MAX_BYTES:
            raise MediaError(f"{kind}: photo size {len(photo or b'')}")
        return Media(photo=photo)

    def render_checkin(self, kind: str, facts: Mapping[str, Any]) -> Media | None:
        """A coach check-in card (today, today_verdict, moved, pinned_week) from caller-built facts. None on ANY failure
        (unknown kind, refused facts, worker down, oversize): the caller sends text only. Never raises."""
        if kind not in CHECKIN_KINDS or not isinstance(facts, Mapping):
            return None
        try:
            return self._still(kind, dict(facts), None)
        except Exception as e:
            log.warning("check-in card skipped: %s %s", kind, type(e).__name__)
            return None

    def render_touch(self, plan: Mapping[str, Any]) -> Media | None:
        """The second picture a touch earned (a milestone, a race countdown), from the facts stored in the plan. None
        when the plan has none (older cards). Raises MediaError when the worker cannot make it."""
        kind, facts = plan.get("touch_card"), plan.get("touch_facts")
        if kind not in ("milestone", "race_countdown") or not isinstance(facts, dict) or not facts:
            return None
        return self._still(kind, facts, None)


def from_settings(socket_path: str) -> MediaRenderer:
    return MediaRenderer(client=RenderClient(socket_path))
