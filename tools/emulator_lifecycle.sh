#!/usr/bin/env bash
# Replay-mode lifecycle test (plan §12, B2/B3 proof), run on the CI emulator:
#   install -> grant permissions -> start a replay 4x4 at 20x -> auto-laps appear
#   -> kill -9 the process mid-run -> it must NOT come back (START_NOT_STICKY)
#   -> relaunch with recover -> orphan found, exit diagnosed, resumed -> stop
#   -> run file committed with the pre-kill laps, one gap span and samples after it,
#      journal gone, strictly increasing t, no FATAL in logcat at any phase.
# The Flutter "recovery dialog" itself is driven here by a debug intent, not the UI; the
# Dart store's index row is asserted by the Dart side once the store lands.
# MODE (3rd arg, default fourByFour) runs the same lifecycle as a Laps run (manual laps from the
# debug intent + a volume key, no phases) or a Free run (every LAP ignored, no LAP action).
# Usage: tools/emulator_lifecycle.sh <apk> <package> [fourByFour|laps|free]
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
MODE="${3:-fourByFour}"
ACTIVITY="$PKG/app.runsolo.MainActivity"

log() { echo "[lifecycle:$MODE] $*"; }
dump() { adb logcat -d -s RunSolo/debug RunSolo/session RunSolo/service RunSolo/api RunSolo/action RunSolo/lapinput AndroidRuntime | tail -n 200 >&2; }
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
TRACE=/tmp/trace.ndjson; : > "$TRACE"
capture_trace() { adb logcat -d -s RunSolo/trace 2>/dev/null | sed -n 's/^.*RunSolo\/trace: //p' >> "$TRACE"; }
check_fatal() { # <phase>; call BEFORE every logcat -c
  capture_trace
  if adb logcat -d | grep -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG" > /tmp/fatal.log; then
    echo "[lifecycle] fatal exception during $1:" >&2; cat /tmp/fatal.log >&2; dump; exit 1
  fi
}
shell() { adb shell "$@" | tr -d '\r'; }

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
# The trace at 20x is ~20 lines/s on a shared ring buffer; the default 256 KB evicts the early part.
adb logcat -G 8M || true
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
adb logcat -c || true
adb install -r "$APK"
adb shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
adb shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION
if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
adb shell settings put secure location_mode 3 || true
adb shell settings put secure location_providers_allowed +gps || true

log "start replay run (synthetic-4x4 trace @20x, mode $MODE) on API $sdk"
# Laps/Free: the debug intent presses a notification LAP every 4 s of wall time (~80 s of trace).
LAP_EXTRA=""
if [ "$MODE" != "fourByFour" ]; then LAP_EXTRA="--el runsolo.lapEveryMs 4000"; fi
start_replay() { adb shell am start -W -n "$ACTIVITY" --es runsolo.replay synthetic-4x4 --es runsolo.mode "$MODE" --ef runsolo.speed 20 $LAP_EXTRA > /dev/null; wait_for_log "RunSolo/debug.*startReplay .*mode=$MODE .*runId=[0-9a-f-]+ error=null" 30; }
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

case "$MODE" in
  fourByFour)
    # 60 s warmup at 20x = 3 s, then rep 1 (4:00 = 12 s) auto-laps into recovery (3:00 = 9 s). Wait for 2 auto laps.
    wait_for_log 'RunSolo/session.*lap index=2 source=auto' 90 || fail "auto-laps did not fire"
    log "auto-laps fired"
    ;;
  laps)
    # Manual laps from the debug intent land; a volume key press must land too (MediaSession active).
    wait_for_log 'RunSolo/session.*lap index=2 source=notification' 90 || fail "manual laps did not land in laps mode"
    wait_for_log 'RunSolo/lapinput.*volume-key lap enabled' 5 || fail "MediaSession for volume-key laps was never registered in laps mode"
    # A runner presses once. A press that REACHES our VolumeProvider (a lapinput `direction=`
    # line) and lands no lap is a product bug: fail at once. Only a press that never reached the
    # session (adb/emulator injection drop: no lapinput line at all) may be retried, and every
    # retry is a visible ::warning:: in the run summary.
    landed=0
    # Either path counts as "the key reached us": the VolumeProvider (`direction=`) or the
    # Android-14 stream-change fallback (`volume changed`).
    keys_seen() { adb logcat -d -s RunSolo/lapinput | grep -cE "direction=|volume changed" || true; }
    media_state() { # what the system thinks the volume/media-key target is right now
      echo "--- dumpsys media_session ---" >&2
      adb shell dumpsys media_session 2>&1 | head -n 80 >&2 || true
      echo "--- display/keyguard ---" >&2
      adb shell dumpsys power 2>&1 | grep -E "mWakefulness=|Display Power: state=" | head -n 4 >&2 || true
      adb shell dumpsys window 2>&1 | grep -E "mDreamingLockscreen|isStatusBarKeyguard|mKeyguardShowing|mFocusedApp|mAwake" | head -n 6 >&2 || true
      echo "--- system media/audio key logs ---" >&2
      adb logcat -d -s MediaSessionService MediaSessionStack MediaSessionRecord MediaSessionLegacyHelper AudioService WindowManager PhoneWindowManager 2>/dev/null | grep -iE "volume|session|KEYCODE" | tail -n 30 >&2 || true
    }
    for attempt in 1 2 3; do
      before_keys="$(keys_seen)"
      adb shell input keyevent KEYCODE_VOLUME_UP
      if wait_for_log 'RunSolo/session.*lap volumeKey → accepted' 10; then landed=1; break; fi
      after_keys="$(keys_seen)"
      if [ "$after_keys" -gt "$before_keys" ]; then
        adb logcat -d -s RunSolo/lapinput RunSolo/session | tail -n 20 >&2 || true
        fail "volume key press $attempt reached the session (lapinput direction line) but no lap was accepted"
      fi
      echo "::warning::volume key press $attempt on API $sdk was dropped before reaching the session (no lapinput line); retrying"
      log "volume key press $attempt never reached the session; system state:"
      media_state
    done
    if [ "$landed" != 1 ]; then
      # Evidence for the product question, not a pass: does the key land once the screen is on?
      log "trying once more with the display awake, to tell screen-off routing from a dead session"
      adb shell input keyevent KEYCODE_WAKEUP; sleep 2
      adb shell input keyevent KEYCODE_VOLUME_UP
      if wait_for_log 'RunSolo/session.*lap volumeKey → accepted' 10; then
        fail "volume key lands only with the display awake on API $sdk: screen-off volume-key laps are broken here"
      fi
      media_state
      fail "volume-key lap never reached the session in 3 presses (see system state above)"
    fi
    vk_t="$(adb logcat -d | grep -oE 'lap index=[0-9]+ source=volumeKey t=[0-9]+' | tail -1 | sed 's/.*t=//')"
    log "manual + volume-key laps landed (volume-key lap at run time ${vk_t} ms)"
    ;;
  free)
    # Every LAP is ignored: API presses log ignoredModeNoLaps + a lapIgnored fault; the volume key reaches nothing.
    wait_for_log 'RunSolo/session.*lap notification → ignoredModeNoLaps' 60 || fail "free mode did not ignore the LAP press"
    wait_for_log 'RunSolo/trace: \{"t":[0-9]+,"kind":"fault","fault":"lapIgnored"' 20 || fail "no lapIgnored fault in free mode"
    adb shell input keyevent KEYCODE_VOLUME_UP
    sleep 3
    if adb logcat -d | grep -E 'RunSolo/session.*lap volumeKey' > /dev/null; then fail "volume key reached the session in free mode"; fi
    if adb logcat -d | grep -E 'RunSolo/session.*lap .* → accepted' > /dev/null; then fail "a lap was accepted in free mode"; fi
    log "free mode ignored every LAP source"
    ;;
  *) fail "unknown mode $MODE" ;;
esac
shell "run-as $PKG ls files/journals/$run_id" | grep -q journal.ndjson || fail "journal missing during recording"
check_fatal "replay"

log "kill -9 the process mid-run"
pid="$(shell pidof "$PKG")"
[ -n "$pid" ] || fail "no pid"
adb shell "run-as $PKG kill -9 $pid" || adb shell am force-stop "$PKG"
sleep 10
if shell pidof "$PKG" > /dev/null 2>&1; then fail "process came back after the kill (sticky restart?)"; fi
log "process stayed dead for 10 s (START_NOT_STICKY)"
shell "run-as $PKG ls files/journals/$run_id" | grep -q journal.ndjson || fail "journal lost by the kill"
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
shell "run-as $PKG ls files/journals" | grep -qx "$run_id" && fail "journal directory still present after finalise"
echo "$runs" | grep -q ".tmp" && fail "tmp file left behind"
shell pidof "$PKG" > /dev/null || fail "process died after finalise"

log "verify the run file contents"
adb exec-out "run-as $PKG cat files/runs/run-$run_id.json.gz" > /tmp/run.json.gz
python3 - "$run_id" "$MODE" "${vk_t:-}" <<'PY' || fail "run file assertions failed"
import gzip, json, sys
run_id, mode, vk_t = sys.argv[1], sys.argv[2], sys.argv[3]
f = json.load(gzip.open("/tmp/run.json.gz"))
assert f["schema"] == 2 and f["id"] == run_id, "header"
assert f["mode"] == mode, f"mode {f['mode']} != {mode}"
laps, gaps, samples = f["laps"], f["gaps"], f["samples"]
assert len(gaps) == 1 and gaps[0][1] > gaps[0][0] > 0, f"gaps={gaps}"
g0, g1 = gaps[0]
pre = [l for l in laps if l["t1"] <= g0]
if mode == "fourByFour":
    assert f["preset"] == {"reps": 4, "workSeconds": 240, "recoverySeconds": 180}, f["preset"]
    assert len(pre) >= 3, f"laps before the kill: {len(pre)}"
    assert sum(1 for l in pre if l["kind"] == "auto") >= 2, "need >= 2 auto laps before the kill"
    # The warmup LAP is pressed on the first tick at/after 60 s of trace time (ticks are 1 s of
    # trace apart), so its boundary carries up to a tick of slack; the auto-laps that follow are
    # landed on the exact phase boundary by the core, so their durations are exact.
    assert pre[0]["kind"] == "manual" and 60000 <= pre[0]["t1"] <= 63000, f"warmup lap {pre[0]}"
    assert pre[1]["kind"] == "auto" and pre[1]["t1"] - pre[1]["t0"] == 240000, f"rep 1 work lap {pre[1]}"
    assert pre[2]["kind"] == "auto" and pre[2]["t1"] - pre[2]["t0"] == 180000, f"rep 1 recovery lap {pre[2]}"
    assert abs(pre[1]["t1"] - 300000) <= 3000 and abs(pre[2]["t1"] - 480000) <= 3000, "boundaries drifted"
elif mode == "laps":
    assert f["preset"] is None, f["preset"]
    assert len(pre) >= 3, f"manual laps before the kill: {len(pre)}"
    assert all(l["kind"] == "manual" for l in laps), "laps mode has no auto laps"
    # Laps from the debug intent are ~80 s of trace apart (4 s wall at 20x); the volume-key lap
    # arrives between two of them. Every lap must be strictly ordered and non-empty.
    assert all(b["t0"] == a["t1"] for a, b in zip(laps, laps[1:])), "laps must tile the run"
    assert all(l["t1"] > l["t0"] for l in laps), "empty lap"
    # The volume-key lap the session accepted must be in the file at that run time (same clock).
    assert vk_t, "volume-key lap time missing from the log"
    assert any(abs(l["t1"] - int(vk_t)) <= 1000 for l in laps), f"no lap within 1 s of the volume-key press at {vk_t} ms: {[l['t1'] for l in laps]}"
elif mode == "free":
    assert f["preset"] is None, f["preset"]
    assert len(laps) == 1 and laps[0]["t0"] == 0, f"free mode must have exactly one lap segment: {laps}"
    assert laps[0]["kind"] == "manual" and laps[0]["t1"] >= samples[-1][0], laps
else:
    raise AssertionError(mode)
ts = [s[0] for s in samples]
assert all(b > a for a, b in zip(ts, ts[1:])), "t not strictly increasing"
assert all(s[6] >= p[6] for p, s in zip(samples, samples[1:])), "dist decreased"
before = [s for s in samples if s[0] <= g0]
after = [s for s in samples if s[0] > g1]
# 1 Hz sampling up to the kill: the count must track the kill time (the kill lands ~480 s in
# for the 4x4, but right after the third lap + volume key for laps/free, so no absolute number).
assert len(before) >= 0.95 * (g0 / 1000) - 2, f"samples before the kill: {len(before)} for {g0} ms (1 Hz expected)"
assert len(before) >= (400 if mode == "fourByFour" else 60), f"samples before the kill: {len(before)}"
assert len(after) >= 3, f"samples after the gap: {len(after)}"
assert sum(1 for s in before if s[1] is not None) >= 0.95 * len(before), "replay samples should carry a fix (>= 95%)"
assert sum(1 for s in before if s[7] is not None) >= 0.9 * len(before), "HR missing on replay samples"
assert before[-1][6] > (900 if mode == "fourByFour" else 2.0 * g0 / 1000), f"distance before the kill too small: {before[-1][6]} m in {g0} ms"
print(f"ok [{mode}]: {len(laps)} laps ({len(pre)} pre-kill), gap {g0}->{g1} ms, {len(before)} samples before, {len(after)} after, {before[-1][6]:.0f} m")
PY

if [ "$MODE" != "fourByFour" ]; then
  log "lifecycle ok on API $sdk in $MODE mode (run $run_id: replay -> laps -> kill -> not restarted -> recover -> resume -> finalise -> verified)"
  exit 0
fi

log "verify the real Pigeon event trace against the JVM contract fixture"
# Events are posted to the main looper; on a slow emulator the idle state line can land a few
# seconds after stop() returned. Wait for it (bounded) - never seeing it is a real bug.
wait_for_log 'RunSolo/trace: \{"t":[0-9]+,"kind":"state","state":"idle"' 15 || fail "idle state event never reached the trace after stop"
capture_trace
# The buffer is captured before each clear and once at the end; drop exact repeats from overlapping captures.
awk '!seen[$0]++' "$TRACE" > "$TRACE.dedup" && mv "$TRACE.dedup" "$TRACE"
wc -l "$TRACE"
python3 tools/check_event_trace.py "$TRACE" packages/run_engine/test/fixtures/contract-events/events_4x4_pause_kill.ndjson || fail "event trace structure differs from the contract fixture"

log "lifecycle ok on API $sdk (run $run_id: replay -> auto-laps -> kill -> not restarted -> recover -> resume -> finalise -> verified -> trace checked)"
