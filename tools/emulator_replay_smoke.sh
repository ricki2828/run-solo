#!/usr/bin/env bash
# Replay smoke for NON-debuggable builds (dogfood): the full lifecycle test needs `run-as`,
# which Android only allows on debuggable packages. This checks the R8-shrunk recorder path
# through logcat only: install -> grant -> start a replay 4x4 at 20x -> two auto-laps fire ->
# no fatal exception.
# Usage: tools/emulator_replay_smoke.sh <apk> <package>
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
ACTIVITY="$PKG/app.runsolo.MainActivity"
log() { echo "[replay-smoke] $*"; }
dump() { adb logcat -d -s RunSolo/debug RunSolo/session RunSolo/service RunSolo/api AndroidRuntime | tail -n 200 >&2; }
fail() { echo "[replay-smoke] FAIL: $*" >&2; dump; exit 1; }
wait_for_log() { # <regex> <timeout-s>
  local re="$1" secs="$2" i=0
  while [ "$i" -lt "$secs" ]; do
    if adb logcat -d | grep -E "$re" > /dev/null; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
adb logcat -G 8M || true
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
adb logcat -c || true
adb install -r "$APK"
adb shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
adb shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION
if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
adb shell settings put secure location_mode 3 || true

log "start replay run (synthetic-4x4 @20x) on API $sdk"
start_replay() { adb shell am start -W -n "$ACTIVITY" --es runsolo.replay synthetic-4x4 --ef runsolo.speed 20 > /dev/null; wait_for_log 'RunSolo/debug.*startReplay .*runId=[0-9a-f-]+ error=null' 30; }
if ! start_replay; then
  log "replay did not start on the first launch; closing system dialogs and retrying once"
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
  adb shell am force-stop "$PKG" || true
  sleep 5
  adb logcat -c || true
  start_replay || fail "replay did not start"
fi
wait_for_log 'RunSolo/session.*lap index=2 source=auto' 90 || fail "auto-laps did not fire"
log "auto-laps fired"
if adb logcat -d | grep -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG" > /tmp/fatal.log; then
  cat /tmp/fatal.log >&2; fail "fatal exception during replay"
fi
adb shell am force-stop "$PKG" || true
log "ok on API $sdk"
