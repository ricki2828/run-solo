#!/usr/bin/env python3
"""Compare a real event trace captured from the Android emulator (RunSolo/trace logcat lines)
with the JVM-generated contract fixture (packages/run_engine/test/fixtures/contract-events/).

The two runs are different scenarios (the emulator run is killed in rep 1 and has no pause),
so values are not compared. Structure is: every kind present carries exactly the fixture's
field names with the same JSON types, enum spellings come from the same vocabulary, and the
recorder's invariants hold (monotonic time, lap active time within wall time, laps counted in
status, the phase order, the first state). Any mismatch exits 1 — that is an Android-side
mapping bug the JVM fixture alone cannot catch.

Usage: check_event_trace.py <captured.ndjson> <fixture.ndjson>
"""
import json
import sys
from collections import defaultdict

ENUMS = {
    "state": {"idle", "recording", "paused", "finalising"},
    "phase": {"none", "warmup", "work", "recovery", "cooldown"},
    "source": {"button", "notification", "volumeKey", "auto"},
    "cue": {"halfway", "thirtySeconds", "phaseEnd", "start", "stop"},
    "mode": {"fourByFour", "free"},
    "fault": {"gpsLost", "gpsWeak", "hrDisconnected", "journalWriteFailed", "lowStorage", "osKilledMidRun", "startFailed"},
}
REQUIRED_KINDS = {"tick", "lap", "phase", "state", "status", "cue"}


def load(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as e:
                sys.exit(f"{path}:{n}: not JSON ({e}): {line[:120]}")
    return out


def jtype(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "num"
    if isinstance(v, str):
        return "str"
    if isinstance(v, list):
        return "list"
    if isinstance(v, dict):
        return "dict"
    return type(v).__name__


def shape(events):
    """kind -> {field: set(types)} (None ignored), plus lap-summary shape from status.laps."""
    s = defaultdict(lambda: defaultdict(set))
    for e in events:
        k = e["kind"]
        for f, v in e.items():
            t = jtype(v)
            if t is not None:
                s[k][f].add(t)
            else:
                s[k][f]  # present, null
        if k == "status":
            for lap in e.get("laps") or []:
                for f, v in lap.items():
                    t = jtype(v)
                    if t is not None:
                        s["status.laps[]"][f].add(t)
    return s


# distanceM etc. print as int when integral (the Kotlin Json writer does that); treat int/num alike.
def norm(types):
    return {"num" if t in ("int", "num") else t for t in types}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    captured, fixture = load(sys.argv[1]), load(sys.argv[2])
    errors = []
    kinds_c = {e["kind"] for e in captured}
    missing = REQUIRED_KINDS - kinds_c
    if missing:
        errors.append(f"captured trace has no {sorted(missing)} events ({len(captured)} lines)")
    sc, sf = shape(captured), shape(fixture)
    for k in sorted(kinds_c & set(sf)):
        fc, ff = set(sc[k]), set(sf[k])
        if fc != ff:
            errors.append(f"{k}: field names differ; only in captured {sorted(fc - ff)}, only in fixture {sorted(ff - fc)}")
        for f in fc & ff:
            tc, tf = norm(sc[k][f]), norm(sf[k][f])
            if tc and tf and not tc <= tf:
                errors.append(f"{k}.{f}: type {sorted(tc)} in captured vs {sorted(tf)} in fixture")
    for k in kinds_c - set(sf):
        errors.append(f"{k}: kind absent from the fixture")
    # Enum vocabularies.
    for e in captured:
        for f, vocab in ENUMS.items():
            if f in e and e[f] is not None and e[f] not in vocab:
                errors.append(f"{e['kind']}.{f} = {e[f]!r} is not a Dart enum name {sorted(vocab)}")
                break
    # Invariants.
    ticks = [e for e in captured if e["kind"] == "tick"]
    laps = [e for e in captured if e["kind"] == "lap"]
    states = [e for e in captured if e["kind"] == "state"]
    phases = [e["phase"] for e in captured if e["kind"] == "phase"]
    statuses = [e for e in captured if e["kind"] == "status"]
    ts = [e["elapsedMs"] for e in ticks]
    if any(b < a for a, b in zip(ts, ts[1:])):
        errors.append("tick.elapsedMs decreased")
    if any(e["t"] != e["elapsedMs"] for e in ticks):
        errors.append("tick.t != tick.elapsedMs")
    if any(e["phaseRemainingMs"] < 0 for e in ticks):
        errors.append("tick.phaseRemainingMs negative")
    prev = 0
    for i, lap in enumerate(laps):
        if lap["index"] != i:
            errors.append(f"lap index {lap['index']} at position {i}")
        wall = lap["tMs"] - prev
        if not (0 < lap["activeMs"] <= wall + 1):
            errors.append(f"lap {i}: activeMs {lap['activeMs']} outside (0, wall {wall}]")
        if lap["t"] != lap["tMs"]:
            errors.append(f"lap {i}: t != tMs")
        prev = lap["tMs"]
    if not states or states[0]["state"] != "recording":
        errors.append(f"first state is {states[0]['state'] if states else 'missing'}, expected recording")
    if states and states[-1]["state"] != "idle":
        errors.append(f"last state is {states[-1]['state']}, expected idle")
    expected_prefix = ["warmup", "work", "recovery", "work", "recovery", "work", "recovery", "work", "recovery", "cooldown"]
    if phases != expected_prefix[: len(phases)]:
        errors.append(f"phase order {phases}")
    # Every status snapshot lists exactly the laps emitted so far.
    seen = 0
    for e in captured:
        if e["kind"] == "lap":
            seen += 1
        elif e["kind"] == "status" and len(e["laps"]) != seen:
            errors.append(f"status at t={e['t']} lists {len(e['laps'])} laps, {seen} lap events so far")
            break
    if statuses and any(s["mode"] != "fourByFour" for s in statuses):
        errors.append("status.mode is not fourByFour for the replay 4x4")
    if errors:
        print("event trace check FAILED:")
        for err in errors:
            print(f"  - {err}")
        sys.exit(1)
    print(
        f"event trace ok: {len(captured)} lines, {len(ticks)} ticks, {len(laps)} laps, {len(phases)} phases, "
        f"{len(states)} states, {len(statuses)} status snapshots; structure matches the fixture"
    )


if __name__ == "__main__":
    main()
