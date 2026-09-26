#!/usr/bin/env python3
"""Compare a run file recorded by the real service in replay mode with the core-jvm fixture
recorded from the same ReplayScenarios trace (I5, Phase 3 §3.9).

Usage: check_replay_run.py <run.json.gz> <replay_<kind>.json>

The service starts its clock a moment before the first fix arrives, so every time in the device
file is the fixture's time plus one constant offset (the service start, a few seconds at most); everything else must match:
mode, session, lap count and kinds, lap times (after the offset), lap distances, and the sample
stream (positions, cumulative distance, HR). An auto-stopped run (parkrun) may run a few more
samples on the device before the stop lands, so its last lap end and the sample tail are bounded,
not exact. Exits 1 with every mismatch listed.
"""
import gzip
import json
import sys

DIST_TOL_M = 1.0
T_TOL_MS = 2
MAX_OFFSET_MS = 10_000
AUTO_STOP_TAIL_S = 5


def main() -> int:
    run = json.load(gzip.open(sys.argv[1]))
    fx = json.load(open(sys.argv[2]))
    errors = []

    def check(ok, msg):
        if not ok:
            errors.append(msg)

    check(run["schema"] == 3, f"schema {run['schema']}")
    check(run["mode"] == fx["mode"], f"mode {run['mode']} != {fx['mode']}")
    check(run["session"] == fx["session"], f"session differs:\n  device  {run['session']}\n  fixture {fx['session']}")
    check(run["gaps"] == [], f"gaps {run['gaps']}")
    auto_stop = bool((fx.get("session") or {}).get("autoStop"))

    laps, flaps = run["laps"], fx["laps"]
    check(len(laps) == len(flaps), f"{len(laps)} laps, fixture has {len(flaps)}")
    check([l["kind"] for l in laps] == [l["kind"] for l in flaps],
          f"lap kinds {[l['kind'] for l in laps]} != {[l['kind'] for l in flaps]}")
    offset = laps[0]["t1"] - flaps[0]["t1"] if laps and flaps else 0
    check(0 <= offset < MAX_OFFSET_MS, f"clock offset {offset} ms outside [0, {MAX_OFFSET_MS})")
    for i, (a, b) in enumerate(zip(laps, flaps)):
        last = i == len(flaps) - 1
        check(a["t0"] == 0 if b["t0"] == 0 else abs(a["t0"] - b["t0"] - offset) <= T_TOL_MS, f"lap {i} t0 {a['t0']} vs {b['t0']}+{offset}")
        check(abs(a["d0"] - b["d0"]) <= DIST_TOL_M, f"lap {i} d0 {a['d0']:.2f} vs {b['d0']:.2f}")
        if last and auto_stop:
            check(0 <= a["t1"] - b["t1"] - offset <= AUTO_STOP_TAIL_S * 1000, f"last lap t1 {a['t1']} vs {b['t1']}+{offset} (auto-stop)")
            check(-DIST_TOL_M <= a["d1"] - b["d1"] <= AUTO_STOP_TAIL_S * 5.0, f"last lap d1 {a['d1']:.2f} vs {b['d1']:.2f} (auto-stop)")
        else:
            check(abs(a["t1"] - b["t1"] - offset) <= T_TOL_MS, f"lap {i} t1 {a['t1']} vs {b['t1']}+{offset}")
            check(abs(a["d1"] - b["d1"]) <= DIST_TOL_M, f"lap {i} d1 {a['d1']:.2f} vs {b['d1']:.2f}")

    s, fs = run["samples"], fx["samples"]
    if auto_stop:
        check(len(fs) <= len(s) <= len(fs) + AUTO_STOP_TAIL_S, f"{len(s)} samples, fixture {len(fs)} (+{AUTO_STOP_TAIL_S} allowed)")
    else:
        check(len(s) == len(fs), f"{len(s)} samples, fixture {len(fs)}")
    bad = 0
    for i, (a, b) in enumerate(zip(s, fs)):
        # [t, lat, lon, alt, acc, speed, dist, hr]
        ok = (abs(a[0] - b[0] - offset) <= T_TOL_MS and a[1] == b[1] and a[2] == b[2]
              and abs(a[6] - b[6]) <= DIST_TOL_M and a[7] == b[7])
        if not ok:
            bad += 1
            if bad <= 5:
                errors.append(f"sample {i}: device {a} fixture {b} (offset {offset})")
    check(bad == 0, f"{bad} samples differ")

    if errors:
        print(f"replay run differs from {sys.argv[2]}:", file=sys.stderr)
        for e in errors:
            print("  " + e, file=sys.stderr)
        return 1
    print(f"ok: {run['mode']} {(run['session'] or {}).get('templateId')}: {len(laps)} laps, {len(s)} samples, "
          f"{s[-1][6]:.0f} m, clock offset {offset} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
