#!/usr/bin/env bash
# Replay-mode lifecycle test (plan §12, B2/B3 proof), run on the CI emulator:
#   install -> grant permissions -> start a replay 4x4 at 20x -> auto-laps appear
#   -> kill -9 the process mid-run -> it must NOT come back (START_NOT_STICKY)
#   -> relaunch with recover -> orphan found, exit diagnosed, resumed -> stop
#   -> run file committed with the pre-kill laps, one gap span and samples after it,
#      journal gone, strictly increasing t, no FATAL in logcat at any phase.
# The Flutter "recovery dialog" itself is driven here by a debug intent, not the UI; the
# Dart store's index row is asserted by the Dart side once the store lands.
# Usage: tools/emulator_lifecycle.sh <apk> <package>
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
ACTIVITY="$PKG/app.runsolo.MainActivity"

log() { echo "[lifecycle] $*"; }
dump() { adb logcat -d -s RunSolo/debug RunSolo/session RunSolo/service RunSolo/api RunSolo/action AndroidRuntime | tail -n 200 >&2; }
fail() { echo "[lifecycle] FAIL: $*" >&2; dump; exit 1; }
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
wait_for_log() { # <regex> <timeout-s>
  local re="$1" secs="$2" i=0
  while [ "$i" -lt "$secs" ]; do
    if adb logcat -d | grep -E "$re" > /dev/null; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}
check_fatal() { # <phase>; call BEFORE every logcat -c
  if adb logcat -d | grep -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG" > /tmp/fatal.log; then
    echo "[lifecycle] fatal exception during $1:" >&2; cat /tmp/fatal.log >&2; dump; exit 1
  fi
}
shell() { adb shell "$@" | tr -d '\r'; }

adb wait-for-device
adb logcat -c || true
adb install -r "$APK"
adb shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
adb shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION
if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
adb shell settings put secure location_mode 3 || true
adb shell settings put secure location_providers_allowed +gps || true

log "start replay run (synthetic-4x4 @20x) on API $sdk"
adb shell am start -W -n "$ACTIVITY" --es runsolo.replay synthetic-4x4 --ef runsolo.speed 20 > /dev/null
wait_for_log 'RunSolo/debug.*startReplay .*runId=[0-9a-f-]+ error=null' 30 || fail "replay did not start"
run_id="$(adb logcat -d | grep -oE 'startReplay .*runId=[0-9a-f-]+' | tail -1 | sed 's/.*runId=//')"
log "runId=$run_id"

# 60 s warmup at 20x = 3 s, then rep 1 (4:00 = 12 s) auto-laps into recovery (3:00 = 9 s). Wait for 2 auto laps.
wait_for_log 'RunSolo/session.*lap index=2 source=auto' 90 || fail "auto-laps did not fire"
log "auto-laps fired"
shell "run-as $PKG ls files/runs/$run_id" | grep -q journal.ndjson || fail "journal missing during recording"
check_fatal "replay"

log "kill -9 the process mid-run"
pid="$(shell pidof "$PKG")"
[ -n "$pid" ] || fail "no pid"
adb shell "run-as $PKG kill -9 $pid" || adb shell am force-stop "$PKG"
sleep 10
if shell pidof "$PKG" > /dev/null 2>&1; then fail "process came back after the kill (sticky restart?)"; fi
log "process stayed dead for 10 s (START_NOT_STICKY)"
shell "run-as $PKG ls files/runs/$run_id" | grep -q journal.ndjson || fail "journal lost by the kill"
check_fatal "kill"

log "relaunch with recover; resume, then stop after 8 s"
adb logcat -c || true
adb shell am start -W -n "$ACTIVITY" --ez runsolo.recover true --el runsolo.stopAfterMs 8000 > /dev/null
wait_for_log "RunSolo/debug.*recover count=1 $run_id" 30 || fail "orphan not found on relaunch"
wait_for_log "RunSolo/debug.*exitDiagnosis runId=$run_id" 30 || fail "no exit diagnosis"
wait_for_log "RunSolo/debug.*resumeRecovered runId=$run_id error=null" 30 || fail "resume failed"
wait_for_log "RunSolo/session.*resumed $run_id after" 30 || fail "session did not resume"
wait_for_log "RunSolo/debug.*stop .*runId=$run_id" 45 || fail "stop did not finalise"
check_fatal "recover/resume/stop"

runs="$(shell "run-as $PKG ls files/runs")"
echo "$runs" | grep -q "run-$run_id.json.gz" || fail "run file not committed"
echo "$runs" | grep -qx "$run_id" && fail "journal directory still present after finalise"
echo "$runs" | grep -q ".tmp" && fail "tmp file left behind"
shell pidof "$PKG" > /dev/null || fail "process died after finalise"

log "verify the run file contents"
adb exec-out "run-as $PKG cat files/runs/run-$run_id.json.gz" > /tmp/run.json.gz
python3 - "$run_id" <<'PY' || fail "run file assertions failed"
import gzip, json, sys
run_id = sys.argv[1]
f = json.load(gzip.open("/tmp/run.json.gz"))
assert f["schema"] == 1 and f["id"] == run_id, "header"
assert f["mode"] == "fourByFour" and f["preset"] == {"reps": 4, "workSeconds": 240, "recoverySeconds": 180}, f["preset"]
laps, gaps, samples = f["laps"], f["gaps"], f["samples"]
assert len(gaps) == 1 and gaps[0][1] > gaps[0][0] > 0, f"gaps={gaps}"
g0, g1 = gaps[0]
pre = [l for l in laps if l["t1"] <= g0]
assert len(pre) >= 3, f"laps before the kill: {len(pre)}"
assert sum(1 for l in pre if l["kind"] == "auto") >= 2, "need >= 2 auto laps before the kill"
assert pre[0]["kind"] == "manual" and pre[0]["t1"] == 60000, f"warmup lap {pre[0]}"
assert pre[1]["kind"] == "auto" and pre[1]["t1"] == 300000, f"rep 1 work lap {pre[1]}"
assert pre[2]["kind"] == "auto" and pre[2]["t1"] == 480000, f"rep 1 recovery lap {pre[2]}"
ts = [s[0] for s in samples]
assert all(b > a for a, b in zip(ts, ts[1:])), "t not strictly increasing"
assert all(s[6] >= p[6] for p, s in zip(samples, samples[1:])), "dist decreased"
before = [s for s in samples if s[0] <= g0]
after = [s for s in samples if s[0] > g1]
assert len(before) >= 400, f"samples before the kill: {len(before)}"
assert len(after) >= 3, f"samples after the gap: {len(after)}"
assert all(s[1] is not None for s in before), "replay samples should all carry a fix"
assert sum(1 for s in before if s[7] is not None) >= 0.9 * len(before), "HR missing on replay samples"
assert before[-1][6] > 900, f"distance before the kill too small: {before[-1][6]}"
print(f"ok: {len(laps)} laps ({len(pre)} pre-kill), gap {g0}->{g1} ms, {len(before)} samples before, {len(after)} after, {before[-1][6]:.0f} m")
PY

log "lifecycle ok on API $sdk (run $run_id: replay -> auto-laps -> kill -> not restarted -> recover -> resume -> finalise -> verified)"
