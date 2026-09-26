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
    "endedPhase": {"none", "warmup", "work", "recovery", "cooldown"},
    "nextPhase": {"none", "warmup", "work", "recovery", "cooldown"},
    "source": {"button", "notification", "volumeKey", "auto"},
    "cue": {"halfway", "thirtySeconds", "phaseEnd", "start", "stop", "distanceToGo", "lastRep", "minuteMark", "countdown", "projection"},
    "mode": {"intervals", "laps", "free", "cooper"},
    "fault": {"gpsLost", "gpsWeak", "hrDisconnected", "journalWriteFailed", "lowStorage", "osKilledMidRun", "startFailed", "lapIgnored", "volumeKeyUnavailable"},
}
# Enums inside status.spec (the Pigeon SessionSpec) and its steps.
SPEC_ENUMS = {"cueProfile": {"standard", "short", "cooper"}}
STEP_ENUMS = {
    "kind": {"work", "recovery"},
    "target": {"time", "distance", "equalToPreviousWork"},
    "style": {"run", "jog", "walk", "stand"},
}
REQUIRED_KINDS = {"tick", "lap", "phase", "state", "status", "cue"}
# Kinds the fixture scenario never produces but a real run legitimately can (the emulator has
# no GPS, so `gpsLost` fires). Their shape is pinned here instead: field -> JSON types.
KNOWN_SHAPES = {
    "fault": {"t": {"int"}, "kind": {"str"}, "fault": {"str"}, "message": {"str"}},
    # Pre-start GPS probe (Start screen only; never during a run).
    "gpsProbe": {"t": {"int"}, "kind": {"str"}, "fix": {"bool"}, "lat": {"num"}, "lon": {"num"}, "accuracyM": {"num"}, "fixAgeMs": {"int"}},
}


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
            spec = e.get("spec")
            if isinstance(spec, dict):
                for f, v in spec.items():
                    t = jtype(v)
                    if t is not None:
                        s["status.spec"][f].add(t)
                    else:
                        s["status.spec"][f]
                for step in spec.get("steps") or []:
                    for f, v in step.items():
                        t = jtype(v)
                        if t is not None:
                            s["status.spec.steps[]"][f].add(t)
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
    # Top-level kinds plus the nested shapes (status.laps[], status.spec, status.spec.steps[]).
    nested = {k for k in sf if "." in k}
    for k in sorted((kinds_c & set(sf)) | nested):
        if k not in sc:
            errors.append(f"{k}: in the fixture, never in the captured trace")
            continue
        fc, ff = set(sc[k]), set(sf[k])
        first = next(e for e in captured if e["kind"] == k.split(".")[0])
        if fc != ff:
            errors.append(f"{k}: field names differ; only in captured {sorted(fc - ff)}, only in fixture {sorted(ff - fc)}; first captured line: {json.dumps(first)}")
        for f in fc & ff:
            tc, tf = norm(sc[k][f]), norm(sf[k][f])
            if tc and tf and not tc <= tf:
                errors.append(f"{k}.{f}: type {sorted(tc)} in captured vs {sorted(tf)} in fixture; first captured line: {json.dumps(first)}")
    for k in kinds_c - set(sf):
        first = next(e for e in captured if e["kind"] == k)
        known = KNOWN_SHAPES.get(k)
        if known is None:
            errors.append(f"{k}: kind absent from the fixture and not a known shape; first line: {json.dumps(first)}")
            continue
        fc = set(sc[k])
        if fc != set(known):
            errors.append(f"{k}: field names {sorted(fc)} differ from the known shape {sorted(known)}; first line: {json.dumps(first)}")
        for f in fc & set(known):
            tc = norm(sc[k][f])
            if tc and not tc <= norm(known[f]):
                errors.append(f"{k}.{f}: type {sorted(tc)} vs known {sorted(known[f])}; first line: {json.dumps(first)}")
    # Enum vocabularies.
    for e in captured:
        for f, vocab in ENUMS.items():
            if f in e and e[f] is not None and e[f] not in vocab:
                errors.append(f"{e['kind']}.{f} = {e[f]!r} is not a Dart enum name {sorted(vocab)}; line: {json.dumps(e)}")
                break
    for e in captured:
        spec = e.get("spec") if e["kind"] == "status" else None
        if not isinstance(spec, dict):
            continue
        for f, vocab in SPEC_ENUMS.items():
            if spec.get(f) not in vocab:
                errors.append(f"status.spec.{f} = {spec.get(f)!r} is not a Dart enum name {sorted(vocab)}")
        for step in spec.get("steps") or []:
            for f, vocab in STEP_ENUMS.items():
                if step.get(f) not in vocab:
                    errors.append(f"status.spec.steps[].{f} = {step.get(f)!r} is not a Dart enum name {sorted(vocab)}")
    # Invariants.
    ticks = [e for e in captured if e["kind"] == "tick"]
    laps = [e for e in captured if e["kind"] == "lap"]
    states = [e for e in captured if e["kind"] == "state"]
    phases = [e["phase"] for e in captured if e["kind"] == "phase"]
    statuses = [e for e in captured if e["kind"] == "status"]
    ts = [e["elapsedMs"] for e in ticks]
    for a, b in zip(ticks, ticks[1:]):
        if b["elapsedMs"] < a["elapsedMs"]:
            errors.append(f"tick.elapsedMs decreased: {json.dumps(a)} -> {json.dumps(b)}")
            break
    bad = next((e for e in ticks if e["t"] != e["elapsedMs"]), None)
    if bad:
        errors.append(f"tick.t != tick.elapsedMs; first: {json.dumps(bad)}")
    bad = next((e for e in ticks if e["phaseRemainingMs"] < 0), None)
    if bad:
        errors.append(f"tick.phaseRemainingMs negative; first: {json.dumps(bad)}")
    prev = 0
    for i, lap in enumerate(laps):
        if lap["index"] != i:
            errors.append(f"lap index {lap['index']} at position {i}")
        wall = lap["tMs"] - prev
        if not (0 < lap["activeMs"] <= wall + 1):
            errors.append(f"lap {i}: activeMs {lap['activeMs']} outside (0, wall {wall}]; line: {json.dumps(lap)}")
        if lap["t"] != lap["tMs"]:
            errors.append(f"lap {i}: t != tMs; line: {json.dumps(lap)}")
        prev = lap["tMs"]
    if not states or states[0]["state"] != "recording":
        errors.append(f"first state is {states[0]['state'] if states else 'missing'}, expected recording")
    if states and states[-1]["state"] != "idle":
        errors.append(f"last state is {states[-1]['state']}, expected idle")
    # 4 reps = 4 work + 3 recovery phases; the last rep goes straight to cool-down.
    expected_prefix = ["warmup", "work", "recovery", "work", "recovery", "work", "recovery", "work", "cooldown"]
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
    if statuses and any(s["mode"] != "intervals" for s in statuses):
        errors.append("status.mode is not intervals for the replay 4x4")
    if statuses and any((s.get("spec") or {}).get("templateId") != "norwegian-4x4" for s in statuses):
        errors.append("status.spec is not the norwegian-4x4 session for the replay 4x4")
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
