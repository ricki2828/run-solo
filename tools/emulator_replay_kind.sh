#!/usr/bin/env bash
# I5 replay per session kind (Phase 3 §3.9), run on the CI emulator: install -> start the
# ReplayScenarios kind through the real service at SPEED x -> the replay ends the run (or the
# core auto-stops it: parkrun) -> run file committed -> compared with the core-jvm fixture
# `replay_<kind>.json` recorded from the same trace (tools/check_replay_run.py), no FATAL.
# Usage: tools/emulator_replay_kind.sh <apk> <package> <kind> [speed]
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
KIND="${3:?kind}"
SPEED="${4:-30}"
# `t4`: every Phase 4 T4 kind in turn (one per transcript fixture), each checked as below.
if [ "$KIND" = "t4" ]; then
  for f in android/core-jvm/src/test/fixtures/transcripts/*.json; do
    "$0" "$APK" "$PKG" "$(basename "$f" .json)" "$SPEED" || exit 1
  done
  exit 0
fi
ACTIVITY="$PKG/app.runsolo.MainActivity"
FIXTURE="packages/run_engine/test/fixtures/contract/replay_${KIND//-/_}.json"
TRANSCRIPT="android/core-jvm/src/test/fixtures/transcripts/$KIND.json"

log() { echo "[replay:$KIND] $*"; }
dump() { adb logcat -d -s RunSolo/debug RunSolo/session RunSolo/service RunSolo/api AndroidRuntime | tail -n 150 >&2; }
fail() { echo "[replay:$KIND] FAIL: $*" >&2; dump; exit 1; }
shell() { adb shell "$@" | tr -d '\r'; }
wait_for_log() { # <regex> <timeout-s>
  local re="$1" secs="$2" i=0
  while [ "$i" -lt "$secs" ]; do
    if adb logcat -d | grep -E "$re" > /dev/null; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}
check_fatal() {
  if adb logcat -d | grep -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG" > /tmp/fatal.log; then
    echo "[replay:$KIND] fatal exception during $1:" >&2; cat /tmp/fatal.log >&2; dump; exit 1
  fi
}

[ -f "$FIXTURE" ] || fail "no fixture $FIXTURE"
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
adb logcat -G 8M || true
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
adb install -r "$APK" > /dev/null
adb shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
adb shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION
if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
adb shell am force-stop "$PKG" || true
adb logcat -c || true

log "start the $KIND replay at ${SPEED}x on API $sdk"
start_replay() { adb shell am start -W -n "$ACTIVITY" --es runsolo.kind "$KIND" --ef runsolo.speed "$SPEED" > /dev/null; wait_for_log "RunSolo/debug.*startReplay .*kind=$KIND .*runId=[0-9a-f-]+ error=null" 30; }
if ! start_replay; then
  # A system-app ANR dialog (GMS on a cold hosted emulator) can swallow the first launch.
  check_fatal "first launch"
  log "replay did not start on the first launch; closing system dialogs and retrying once"
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
  adb shell am force-stop "$PKG" || true
  sleep 5
  adb logcat -c || true
  start_replay || fail "replay did not start"
fi
run_id="$(adb logcat -d | grep -oE 'startReplay .*runId=[0-9a-f-]+' | tail -1 | sed 's/.*runId=//')"
log "runId=$run_id"

# The longest scenario (Yasso) is ~25 min of trace: under a minute at 30x; the bound is generous.
wait_for_log "RunSolo/session.*finalised $run_id .*run-$run_id" 300 || fail "the replay never finalised"
check_fatal "replay"
shell "run-as $PKG ls files/journals" | grep -qx "$run_id" && fail "journal directory still present after finalise"

adb exec-out "run-as $PKG cat files/runs/run-$run_id.json.gz" > /tmp/run.json.gz
python3 tools/check_replay_run.py /tmp/run.json.gz "$FIXTURE" || fail "run file differs from $FIXTURE"
# T4: what was said, and when, against the JVM transcript.
if [ -f "$TRANSCRIPT" ]; then
  adb logcat -d -s RunSolo/session > /tmp/said.log
  python3 tools/check_replay_transcript.py /tmp/said.log "$TRANSCRIPT" || fail "transcript differs from $TRANSCRIPT"
fi
log "ok on API $sdk (run $run_id)"
