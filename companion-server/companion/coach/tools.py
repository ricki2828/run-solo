"""The coach's read tools (C1) and the server-side argument check (eng-review B4).

Every tool is called with the user id the worker bound to the job. No argument names a runner: a run id that belongs to
someone else is simply "not found". Arguments are checked against the tools.json schema in code (types, ranges, enums,
required keys, additionalProperties: false); a bad call returns {"ok": false, "error": ...} to the model and never
raises. Results carry ready-to-say values (pace as m:ss, km to one decimal) plus a weekday on every date, because the
chat validator only accepts numbers that appear in a tool result.

Text the runner typed (run notes) goes out inside {"quoted_runner_text": ...}: the prompt tells the model that is data,
never instructions (B5).
"""
from __future__ import annotations

import json
from datetime import date, datetime, timedelta
from typing import Any, Callable

from .. import db
from ..timeutil import iso, parse_iso, to_local

MAX_RESULT_CHARS = 12000
MAX_RECENT_RUNS = 30
LOAD_STATE_DAYS = 7   # a load_state older than this is not shown to the model
MAX_SPLITS = 50
COACH_TYPES = {"easy": ("easy",), "long": ("long",), "quality": ("tempo", "interval"), "race": ("race",)}
# Memory answers the coach may see: the same enumerated digest the card writer gets (writer.digest_lines), minus the
# "weight" reason for running, which stays on the server.
MEMORY_KEYS = ("goal_type", "race_month", "usual_days", "niggle_area", "runs_per_week", "surface", "time_of_day", "run_why")
TRAIL_DROP = {"name", "trail_name", "hr", "hr_z", "profile", "route"}


def weekday(d: date) -> str:
    return d.strftime("%a")


def day_of(d: date) -> dict:
    return {"day": d.isoformat(), "weekday": weekday(d)}


def mmss(seconds: float | None) -> str | None:
    if seconds is None or seconds <= 0:
        return None
    s = int(round(seconds))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def km(metres: float | None) -> float | None:
    return None if metres is None else round(metres / 1000.0, 1)


def quoted(text: str | None) -> dict | None:
    return {"quoted_runner_text": text} if text else None


# ------------------------------------------------------------------------------------------- schema check
def check_args(schema: dict, args: Any) -> tuple[dict | None, str | None]:
    """Validate against the subset of JSON Schema tools.json uses. -> (args with defaults filled, None) or (None, error)."""
    if args is None:
        args = {}
    if not isinstance(args, dict):
        return None, "arguments must be an object"
    props = schema.get("properties", {})
    if schema.get("additionalProperties") is False:
        extra = sorted(set(args) - set(props))
        if extra:
            return None, f"unknown argument(s): {', '.join(extra)}"
    for k in schema.get("required", []):
        if k not in args:
            return None, f"missing argument: {k}"
    out: dict[str, Any] = {}
    for k, spec in props.items():
        if k not in args:
            if "default" in spec:
                out[k] = spec["default"]
            continue
        v = args[k]
        t = spec.get("type")
        if t == "integer" and (not isinstance(v, int) or isinstance(v, bool)):
            return None, f"{k} must be a whole number"
        if t == "string" and not isinstance(v, str):
            return None, f"{k} must be a string"
        if t == "object" and not isinstance(v, dict):
            return None, f"{k} must be an object"
        if t == "array" and not isinstance(v, list):
            return None, f"{k} must be a list"
        if "enum" in spec and v not in spec["enum"]:
            return None, f"{k} must be one of {spec['enum']}"
        if "minimum" in spec and v < spec["minimum"] or "maximum" in spec and v > spec["maximum"]:
            return None, f"{k} is out of range"
        if "maxLength" in spec and isinstance(v, str) and len(v) > spec["maxLength"]:
            return None, f"{k} is too long"
        out[k] = v
    return out, None


class ReadTools:
    """Bound to one runner for one job. `svc` is the Service (for the next-session resolver and memory)."""

    def __init__(self, svc: Any, schemas: list[dict], user_id: str, now: datetime):
        self.svc, self.uid, self.now = svc, user_id, now
        self.schemas = {t["name"]: t["input_schema"] for t in schemas}
        self._impl: dict[str, Callable[..., dict]] = {
            "get_runner": self.get_runner, "get_recent_runs": self.get_recent_runs, "get_run": self.get_run,
            "get_stats": self.get_stats, "get_plan": self.get_plan, "get_checkins": self.get_checkins,
        }

    def call(self, name: str, raw_args: Any) -> dict:
        """Never raises. Unknown tools (the C2 write tools included) and bad arguments come back as ok:false."""
        if name not in self.schemas or name not in self._impl:
            return {"ok": False, "error": f"unknown tool: {name}"}
        if isinstance(raw_args, str):
            try:
                raw_args = json.loads(raw_args) if raw_args.strip() else {}
            except ValueError:
                return {"ok": False, "error": "arguments are not valid JSON"}
        try:
            args, err = check_args(self.schemas[name], raw_args)
            if err:
                return {"ok": False, "error": err}
            out = self._impl[name](**args)
        except Exception as e:   # a tool must never take the job down; the model is told it failed
            return {"ok": False, "error": f"tool failed: {type(e).__name__}"}
        return {"ok": True, **out}

    @staticmethod
    def encode(result: dict) -> str:
        s = json.dumps(result, separators=(",", ":"), ensure_ascii=False)
        if len(s) > MAX_RESULT_CHARS:
            s = json.dumps({"ok": result.get("ok", True), "truncated": True, "error": "result too large, ask for fewer days"})
        return s

    # -------------------------------------------------------------------------------------- helpers
    def _user(self, c) -> dict:
        u = c.execute("SELECT * FROM users WHERE id=?", (self.uid,)).fetchone()
        if not u:
            raise LookupError("gone")
        return dict(u)

    def _local_day(self, utc_iso: str, zone_id: str) -> date:
        return to_local(parse_iso(utc_iso), zone_id).date()

    def _fresh_load(self, r) -> str | None:
        """A run's load_state only while it is recent: a flag from weeks ago says nothing about now."""
        return r["load_state"] if parse_iso(r["start_utc"]) >= self.now - timedelta(days=LOAD_STATE_DAYS) else None

    def _run_row(self, r, zone_id: str, note: str | None = None) -> dict:
        d = self._local_day(r["start_utc"], r["zone_id"] or zone_id)
        out: dict[str, Any] = {
            "run_id": r["run_id"], **day_of(d), "type": r["type"], "app_type": r["app_type"],
            "session_name": r["session_name"], "distance_km": km(r["distance_m"]), "duration": mmss(r["duration_s"]),
            "pace_per_km": mmss(r["pace_s_per_km"]), "true_pace_per_km": mmss(r["true_pace_s_per_km"]),
            "work_pace_per_km": mmss(r["work_pace_s_per_km"]), "reps_done": r["reps_done"],
            "rep_spread_s": round(r["rep_spread_s"]) if r["rep_spread_s"] is not None else None,
            "recovery_pace_per_km": mmss(r["recovery_pace_s_per_km"]), "goal_reached": r["goal_reached"],
            "goal_target": mmss(r["goal_target_s"]), "goal_target_from": r["goal_target_from"],
            "goal_retarget": mmss(r["goal_retarget_s"]),
            "climb_m": r["climb_m"], "verdict": r["verdict"], "feel": r["feel"], "pb": r["pb"],
            "load_state": self._fresh_load(r),
        }
        try:
            zones = json.loads(r["zone_min"] or "{}")
            if zones:
                out["zone_minutes"] = {k: round(v) for k, v in zones.items() if isinstance(v, (int, float))}
        except ValueError:
            pass
        if note:
            out["note"] = quoted(note)
        return {k: v for k, v in out.items() if v is not None}

    # -------------------------------------------------------------------------------------- tools
    def get_runner(self) -> dict:
        with db.ro(self.svc.s.db_path) as c:
            u = self._user(c)
            mem = self.svc._memory_get(c, self.uid, self.now)
            flags = [r["kind"] for r in c.execute(
                "SELECT kind FROM health_flags WHERE user_id=? AND state='active' ORDER BY kind", (self.uid,))]
            latest = c.execute("SELECT plan_kind, plan_target_m, plan_weeks_to_race, plan_week, plan_weeks FROM runs "
                               "WHERE user_id=? ORDER BY start_utc DESC LIMIT 1", (self.uid,)).fetchone()
            since = iso(self.now - timedelta(weeks=8))
            longest = c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? AND start_utc>=? "
                                "ORDER BY distance_m DESC LIMIT 4", (self.uid, since)).fetchall()
        today = to_local(self.now, u["zone_id"]).date()
        name = (u["chat_name"] or "").split("(@")[0].strip()
        first = name.split()[0] if name and not name.startswith("@") else None
        remembered = {k: mem[k] for k in MEMORY_KEYS if k in mem}
        if remembered.get("run_why") == "weight":
            del remembered["run_why"]
        goal: dict[str, Any] = {}
        for k in ("goal_type", "race_month"):
            if k in mem:
                goal[k] = mem[k]
        if latest and latest["plan_target_m"]:
            goal.update({"plan_kind": latest["plan_kind"], "target_km": km(latest["plan_target_m"]),
                         "weeks_to_race": latest["plan_weeks_to_race"], "plan_week": latest["plan_week"],
                         "plan_weeks": latest["plan_weeks"]})
        days = [weekday(self._local_day(r["start_utc"], r["zone_id"] or u["zone_id"])) for r in longest]
        long_day = max(set(days), key=days.count) if days else None
        return {"first_name": first, "units": "km", "timezone": u["zone_id"], "today": day_of(today),
                "goal": {k: v for k, v in goal.items() if v is not None} or None,
                "days_available": mem.get("usual_days") or mem.get("runs_per_week"),
                "long_run_day": long_day, "health_flags": flags, "remembered": remembered}

    def get_recent_runs(self, days: int = 42, type: str = "any") -> dict:   # "type" is the contract argument name
        with db.ro(self.svc.s.db_path) as c:
            u = self._user(c)
            q = "SELECT * FROM runs WHERE user_id=? AND start_utc>=?"
            args: list[Any] = [self.uid, iso(self.now - timedelta(days=days))]
            if type in COACH_TYPES:
                q += f" AND type IN ({','.join('?' * len(COACH_TYPES[type]))})"
                args += COACH_TYPES[type]
            elif type == "trail":
                q += " AND app_type='trail'"
            rows = c.execute(q + " ORDER BY start_utc DESC LIMIT ?", (*args, MAX_RECENT_RUNS + 1)).fetchall()
            notes = {r["run_id"]: r["note"] for r in c.execute("SELECT run_id, note FROM run_notes WHERE user_id=?", (self.uid,))}
        more = len(rows) > MAX_RECENT_RUNS
        out = [self._run_row(r, u["zone_id"], notes.get(r["run_id"])) for r in rows[:MAX_RECENT_RUNS]]
        return {"runs": out, "count": len(out), **({"more_not_shown": True} if more else {})}

    def get_run(self, run_id: str) -> dict:
        with db.ro(self.svc.s.db_path) as c:
            u = self._user(c)
            r = c.execute("SELECT * FROM runs WHERE user_id=? AND run_id=?", (self.uid, run_id)).fetchone()
            if not r:
                return {"found": False}
            shape = c.execute("SELECT splits_json, reps_json, trail_json FROM run_shape WHERE user_id=? AND run_id=?",
                              (self.uid, run_id)).fetchone()
            note = c.execute("SELECT note FROM run_notes WHERE user_id=? AND run_id=?", (self.uid, run_id)).fetchone()
        out = {"found": True, "run": self._run_row(r, u["zone_id"], note["note"] if note else None)}
        if shape:
            splits = json.loads(shape["splits_json"]) if shape["splits_json"] else []
            if splits and len(splits) <= MAX_SPLITS:
                out["splits"] = [{"km": s.get("km"), "pace_per_km": mmss(s.get("pace_s")), "zone": s.get("zone")} for s in splits]
            reps = json.loads(shape["reps_json"]) if shape["reps_json"] else []
            if reps:
                out["reps"] = [{"rep": i + 1, "time": mmss(x.get("time_s")), "zone": x.get("zone")} for i, x in enumerate(reps)]
            if shape["trail_json"]:
                t = json.loads(shape["trail_json"])
                if isinstance(t, dict):
                    out["trail"] = {k: v for k, v in t.items() if k not in TRAIL_DROP}
        return out

    def get_stats(self, weeks: int = 8) -> dict:
        with db.ro(self.svc.s.db_path) as c:
            u = self._user(c)
            today = to_local(self.now, u["zone_id"]).date()
            monday = today - timedelta(days=today.weekday())
            first = monday - timedelta(weeks=weeks - 1)
            rows = c.execute("SELECT start_utc, zone_id, distance_m, duration_s, pb, load_state, run_id FROM runs "
                             "WHERE user_id=? AND start_utc>=? ORDER BY start_utc",
                             (self.uid, iso(self.now - timedelta(weeks=weeks, days=7)))).fetchall()
            pbs = c.execute("SELECT pb, run_id, start_utc, zone_id, distance_m, duration_s FROM runs WHERE user_id=? AND pb IS NOT NULL "
                            "ORDER BY start_utc DESC LIMIT 20", (self.uid,)).fetchall()
            longest = c.execute("SELECT run_id, start_utc, zone_id, distance_m, duration_s FROM runs WHERE user_id=? "
                                "ORDER BY distance_m DESC LIMIT 1", (self.uid,)).fetchone()
        totals = {first + timedelta(weeks=i): [0.0, 0] for i in range(weeks)}
        for r in rows:
            d = self._local_day(r["start_utc"], r["zone_id"] or u["zone_id"])
            wk = d - timedelta(days=d.weekday())
            if wk in totals:
                totals[wk][0] += r["distance_m"] or 0
                totals[wk][1] += 1
        weekly = [{"week_of": day_of(wk), "km": km(t[0]), "runs": t[1]} for wk, t in sorted(totals.items())]
        seen, best = set(), []
        for r in pbs:
            if r["pb"] in seen:
                continue
            seen.add(r["pb"])
            best.append({"pb": r["pb"], "run_id": r["run_id"], **day_of(self._local_day(r["start_utc"], r["zone_id"] or u["zone_id"])),
                         "distance_km": km(r["distance_m"]), "duration": mmss(r["duration_s"])})
        out: dict[str, Any] = {"weekly_km": weekly, "pbs": best,
                               "load_state": self._fresh_load(rows[-1]) if rows else None}   # the newest run's own state, null stays null
        if longest:
            out["longest_run"] = {"run_id": longest["run_id"], "distance_km": km(longest["distance_m"]),
                                  "duration": mmss(longest["duration_s"]),
                                  **day_of(self._local_day(longest["start_utc"], longest["zone_id"] or u["zone_id"]))}
        return out

    def get_plan(self) -> dict:
        """Before C3 the server holds only the next session the app shared (eng-review W2)."""
        view = self.svc.next_session(self.uid, self.now)
        s = view.get("next_session")
        sessions = []
        if s:
            d = date.fromisoformat(s["date"])
            item = {**day_of(d), "type": s["type"], "name": s["name"], "minutes": s.get("minutes"),
                    "distance_km": km(s.get("distance_m")), "moved": s.get("moved"),
                    "plan_week": s.get("week"), "plan_weeks": s.get("weeks"),
                    "source": "default coach week" if s.get("derived") else "app plan"}
            sessions.append({k: v for k, v in item.items() if v is not None})
        return {"source": "app_next_only", "sessions": sessions,
                "note": "Only the next session is visible to the coach; the full plan lives in the app."}

    def get_checkins(self) -> dict:
        cut = iso(self.now - timedelta(days=14))
        with db.ro(self.svc.s.db_path) as c:
            u = self._user(c)
            rows = c.execute("SELECT kind, local_date, value, created_at FROM checkin_answers WHERE user_id=? AND created_at>? "
                             "ORDER BY created_at DESC", (self.uid, cut)).fetchall()
            notes = c.execute("SELECT n.run_id, n.note, r.start_utc, r.zone_id FROM run_notes n JOIN runs r ON "
                              "r.user_id=n.user_id AND r.run_id=n.run_id WHERE n.user_id=? AND n.created_at>? "
                              "ORDER BY n.created_at DESC LIMIT 10", (self.uid, cut)).fetchall()
        answers = []
        for r in rows:
            try:
                d = date.fromisoformat(r["local_date"])
            except ValueError:
                continue
            answers.append({"kind": r["kind"], **day_of(d), "value": r["value"]})
        typed = [{"run_id": n["run_id"], **day_of(self._local_day(n["start_utc"], n["zone_id"] or u["zone_id"])),
                  "note": quoted(n["note"])} for n in notes]
        return {"answers": answers, "run_notes": typed,
                "kinds": {"ready": "evening before", "today": "morning of", "why": "why they skipped",
                          "postrun": "what affected the run", "shape": "how the week felt"}}
