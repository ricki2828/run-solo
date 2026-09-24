#!/usr/bin/env bash
# Replay-mode lifecycle test (plan §12, B2/B3 proof), run on the CI emulator:
#   install -> grant permissions -> start a replay 4x4 at 20x -> auto-laps appear
#   -> kill the process mid-run -> relaunch with recover -> orphan found, resumed
#   -> stop -> run file committed, journal gone, no fatal exception in logcat.
# "Indexed" (the sqflite row) is asserted by the Dart side once the store lands; this script
# proves the Kotlin half: journal -> kill -> recover -> resume -> finalise.
# Usage: tools/emulator_lifecycle.sh <apk> <package>
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
ACTIVITY="$PKG/app.runsolo.MainActivity"

log() { echo "[lifecycle] $*"; }
fail() { echo "[lifecycle] FAIL: $*" >&2; adb logcat -d -s RunSolo/debug RunSolo/session RunSolo/service RunSolo/api AndroidRuntime | tail -n 200 >&2; exit 1; }
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
wait_for_log() { # <regex> <timeout-s>
  local re="$1" secs="$2" i=0
  while [ "$i" -lt "$secs" ]; do
    if adb logcat -d | grep -E "$re" > /dev/null; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

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

# 60 s warmup at 20x = 3 s, then rep 1 (4:00 = 12 s) auto-laps into recovery. Wait for 2 auto laps.
wait_for_log 'RunSolo/session.*lap index=2 source=auto' 90 || fail "auto-laps did not fire"
log "auto-laps fired"
adb shell "run-as $PKG ls files/runs/$run_id" | grep -q journal.ndjson || fail "journal missing during recording"

log "kill the process mid-run"
pid="$(adb shell pidof "$PKG" | tr -d '\r')"
[ -n "$pid" ] || fail "no pid"
adb shell "run-as $PKG kill -9 $pid" || adb shell am force-stop "$PKG"
sleep 2
if adb shell pidof "$PKG" > /dev/null 2>&1; then fail "process still alive after kill"; fi
adb shell "run-as $PKG ls files/runs/$run_id" | grep -q journal.ndjson || fail "journal lost by the kill"

log "relaunch with recover; resume, then stop after 6 s"
adb logcat -c || true
adb shell am start -W -n "$ACTIVITY" --ez runsolo.recover true --el runsolo.stopAfterMs 6000 > /dev/null
wait_for_log "RunSolo/debug.*recover count=1 $run_id" 30 || fail "orphan not found on relaunch"
wait_for_log "RunSolo/debug.*resumeRecovered runId=$run_id error=null" 30 || fail "resume failed"
wait_for_log "RunSolo/session.*resumed $run_id after" 30 || fail "session did not resume"
wait_for_log "RunSolo/debug.*stop .*runId=$run_id" 40 || fail "stop did not finalise"
adb shell "run-as $PKG ls files/runs" | grep -q "run-$run_id.json.gz" || fail "run file not committed"
if adb shell "run-as $PKG ls files/runs" | grep -q "^$run_id\$"; then fail "journal directory still present after finalise"; fi
adb shell "run-as $PKG ls files/runs" | grep -q ".tmp" && fail "tmp file left behind"

if adb logcat -d | grep -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG" > /tmp/fatal.log; then
  echo "fatal exception in logcat:" >&2; cat /tmp/fatal.log; exit 1
fi
adb shell pidof "$PKG" > /dev/null || fail "process died after finalise"
log "lifecycle ok on API $sdk (run $run_id: replay -> auto-laps -> kill -> recover -> resume -> finalise)"
