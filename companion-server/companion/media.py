"""Turns a stored card (convo_cards.media_json) into bytes a channel can upload.

Numbers come only from the stored run rows (B4): the card text is already validated, and the image facts are
read straight from the same rows, never from the LLM. The server holds no GPS track and no per-km splits, so a
run video (which needs both) is not rendered from server data; those moments get the still card instead. A
weekly recap video only needs per-day zone time, which the rows have.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .convo.touches import _zone_minutes
from render import protocol as P

from .render_client import RenderClient
from .timeutil import parse_iso, to_local

log = logging.getLogger("companion")

PHOTO_MAX_BYTES = P.PHOTO_MAX_BYTES    # Telegram sendPhoto; the worker protocol enforces the same caps
VIDEO_MAX_BYTES = P.VIDEO_MAX_BYTES    # Telegram bot upload ceiling
WIDTH, HEIGHT = 1080, 1350
SCORE_KEYS = ("aerobic", "speed", "mid", "long")
PB_LABEL = {"5k": "5 KM BEST", "10k": "10 KM BEST", "half": "HALF MARATHON BEST", "longest": "LONGEST RUN",
            "fastest_km": "FASTEST KM"}
VERDICTS = frozenset({"faster", "holding", "slower", "noRealChange", "baselineSet", "indoorRun"})


class MediaError(Exception):
    """A render failed. The caller falls back to the text card."""


@dataclass(frozen=True)
class Media:
    photo: bytes | None = None
    video: bytes | None = None
    width: int = WIDTH
    height: int = HEIGHT
    duration_s: int = 0


def _zone_s(row: Mapping[str, Any]) -> list[float]:
    z = _zone_minutes(row)
    return [round(z.get(i, 0.0) * 60, 1) for i in range(1, 6)]


def run_facts(run: Mapping[str, Any], headline: str) -> dict[str, Any]:
    """Image facts for one run, from its stored row only."""
    facts: dict[str, Any] = {
        "type": run["type"],
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
    return facts


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
        d["distance_km"] += r["distance_m"] / 1000
        d["zone_s"] = [a + b for a, b in zip(d["zone_s"], _zone_s(r))]
        sd = r.get("scores_delta")
        sd = json.loads(sd) if isinstance(sd, str) else (sd or {})
        for k in SCORE_KEYS:
            if isinstance(sd.get(k), (int, float)):
                moves[k] += sd[k]
                seen_move = True
    from .convo.recap import best_moment
    facts: dict[str, Any] = {
        "week_label": f"Week {int(week_ref.split('-W')[1])}",
        "distance_km": sum(r["distance_m"] for r in mine) / 1000,
        "runs": len(mine),
        "duration_s": sum(r["duration_s"] for r in mine),
        "days": days,
    }
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
CARD_KINDS = ("light", "flood", "pb", "weekly_recap", "suggestion", "milestone", "race_countdown", "monthly")
ROW_KINDS = ("light", "flood", "pb", "weekly_recap", "monthly")


def _default_card_fns(client: RenderClient) -> dict[str, Callable[..., bytes]]:
    """Cards come from the render worker. `memory` is never sent: nothing the worker draws needs a name."""
    def make(kind: str) -> Callable[..., bytes]:
        return lambda facts, memory=None: client.card(kind, facts)
    return {k: make(k) for k in CARD_KINDS}


def _default_video_fns(client: RenderClient | None = None) -> dict[str, Callable[..., Any]]:
    def run(facts: dict, out: Path) -> Any:
        if not facts.get("splits"):  # the server holds no per-km splits: decide here, without a worker round trip
            raise MediaError("run video needs splits")
        out.write_bytes(_client(client).video("run", facts))

    def weekly(facts: dict, out: Path) -> Any:
        out.write_bytes(_client(client).video("weekly", facts))
    return {"run": run, "weekly": weekly}


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

    def render(self, plan: Mapping[str, Any], card: Mapping[str, Any], runs: Sequence[Mapping[str, Any]],
               memory: Mapping[str, Any] | None = None) -> Media | None:
        """None when the plan has no media. Raises MediaError when a planned still card cannot be made."""
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
            else:
                run = next(r for r in runs if r["run_id"] == card["run_id"])
                facts = run_facts(run, card["headline"])
                vkind, vfacts = "run", facts
            photo = self.cards[kind](facts, memory or {})
        except Exception as e:
            raise MediaError(f"{kind}: {type(e).__name__}") from None
        if not photo or len(photo) > PHOTO_MAX_BYTES:
            raise MediaError(f"{kind}: photo size {len(photo or b'')}")
        video = self._video(vkind, vfacts) if plan.get("video") else None
        return Media(photo=photo, video=video, duration_s=13 if video else 0)


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

    def render_touch(self, plan: Mapping[str, Any]) -> Media | None:
        """The second picture a touch earned (a milestone, a race countdown), from the facts stored in the plan. None
        when the plan has none (older cards). Raises MediaError when the worker cannot make it."""
        kind, facts = plan.get("touch_card"), plan.get("touch_facts")
        if kind not in ("milestone", "race_countdown") or not isinstance(facts, dict) or not facts:
            return None
        return self._still(kind, facts, None)


def from_settings(socket_path: str) -> MediaRenderer:
    return MediaRenderer(client=RenderClient(socket_path))
