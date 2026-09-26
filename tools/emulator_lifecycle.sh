#!/usr/bin/env bash
# Replay-mode lifecycle test (plan §12, B2/B3 proof), run on the CI emulator:
#   install -> grant permissions -> start a replay 4x4 at 20x -> auto-laps appear
#   -> kill -9 the process mid-run -> it must NOT come back (START_NOT_STICKY)
#   -> relaunch with recover -> orphan found, exit diagnosed, resumed -> stop
#   -> run file committed with the pre-kill laps, one gap span and samples after it,
#      journal gone, strictly increasing t, no FATAL in logcat at any phase.
# The Flutter "recovery dialog" itself is driven here by a debug intent, not the UI; the
# Dart store's index row is asserted by the Dart side once the store lands.
# MODE (3rd arg, default intervals: the Norwegian 4x4 session) runs the same lifecycle as a Laps run (manual laps from the
# debug intent + a volume key, no phases) or a Free run (every LAP ignored, no LAP action).
# Usage: tools/emulator_lifecycle.sh <apk> <package> [intervals|laps|free]
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
MODE="${3:-intervals}"
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
if [ "$MODE" != "intervals" ]; then LAP_EXTRA="--el runsolo.lapEveryMs 4000"; fi
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
  intervals)
    # 60 s warmup at 20x = 3 s, then rep 1 (4:00 = 12 s) auto-laps into recovery (3:00 = 9 s). Wait for 2 auto laps.
    wait_for_log 'RunSolo/session.*lap index=2 source=auto' 90 || fail "auto-laps did not fire"
    log "auto-laps fired"
    ;;
  laps)
    # Manual laps from the debug intent land; a volume key press must land too (MediaSession active).
    wait_for_log 'RunSolo/session.*lap index=2 source=notification' 90 || fail "manual laps did not land in laps mode"
    if [ "$sdk" -eq 34 ]; then
      # Android 14 never routes volume keys to an app's remote session, and swallows a lone key
      # press when nothing plays (it only shows the volume panel), so volume-key laps are off
      # there: no session, one volumeKeyUnavailable fault for the UI's "use the lock-screen LAP".
      wait_for_log 'RunSolo/lapinput.*volume-key laps unavailable' 5 || fail "API 34: volume-key laps were not reported unavailable"
      wait_for_log 'RunSolo/trace: \{"t":[0-9]+,"kind":"fault","fault":"volumeKeyUnavailable"' 20 || fail "API 34: no volumeKeyUnavailable fault"
      adb shell dumpsys media_session 2>&1 | grep -q 'RunSolo lap' && fail "API 34: the volume-key MediaSession was registered"
      adb shell input keyevent KEYCODE_VOLUME_UP
      sleep 3
      if adb logcat -d | grep -E 'RunSolo/session.*lap volumeKey' > /dev/null; then fail "API 34: a volume key reached the session"; fi
      n_unavail="$(adb logcat -d | grep -c '"fault":"volumeKeyUnavailable"' || true)"
      [ "$n_unavail" = 1 ] || fail "API 34: volumeKeyUnavailable fired $n_unavail times, expected once"
      log "API 34: volume-key laps off (no session, volumeKeyUnavailable once); manual laps landed"
    else
      wait_for_log 'RunSolo/lapinput.*volume-key lap enabled' 5 || fail "MediaSession for volume-key laps was never registered in laps mode"
      # A runner presses once. A press that REACHES our VolumeProvider (a lapinput `direction=`
      # line) and lands no lap is a product bug: fail at once. Only a press that never reached the
      # session (adb/emulator injection drop: no lapinput line at all) may be retried, and every
      # retry is a visible ::warning:: in the run summary.
      # `media volume` (older images) or `cmd media_session volume` (newer, `media` removed): pick
      # whichever the device has; both print "volume is N in range [..]".
      if shell cmd media_session volume --stream 3 --get 2>/dev/null | grep -q 'volume is'; then
        MEDIA_CMD="cmd media_session volume"
      elif shell media volume --stream 3 --get 2>/dev/null | grep -q 'volume is'; then
        MEDIA_CMD="media volume"
      else
        fail "neither 'cmd media_session volume' nor 'media volume' works on API $sdk; cannot read the music volume"
      fi
      music_volume() { shell $MEDIA_CMD --stream 3 --get | grep -oE 'volume is [0-9]+' | grep -oE '[0-9]+$'; }
      set_music_volume() { shell $MEDIA_CMD --stream 3 --set "$1" > /dev/null; }
      vol_before="$(music_volume)"
      log "music volume before the key: $vol_before"
      landed=0
      # The key reached us: a VolumeProvider `direction=` line.
      keys_seen() { adb logcat -d -s RunSolo/lapinput | grep -c "direction=" || true; }
      n_log() { adb logcat -d | grep -c "$1" || true; }
      # Press at a fixed point of the lap cycle: 1.5 s of wall time (30 s of run time at 20x)
      # after a notification LAP, 2.5 s before the next one. A Laps run ignores any manual press
      # within 1.5 s of run time of the previous one (RecorderCore), so a press at a random
      # moment would sometimes be a re-press by design.
      after_fresh_notification_lap() {
        local n waited=0
        n="$(n_log 'lap notification → accepted')"
        until [ "$(n_log 'lap notification → accepted')" -gt "$n" ]; do
          sleep 0.2
          waited=$((waited + 1))
          [ "$waited" -lt 50 ] || fail "no notification LAP within 10 s to time the volume key against"
        done
        sleep 1.5
      }
      media_state() { # what the system thinks the volume/media-key target is right now
        echo "--- dumpsys media_session ---" >&2
        adb shell dumpsys media_session 2>&1 | head -n 80 >&2 || true
        echo "--- display/keyguard ---" >&2
        adb shell dumpsys power 2>&1 | grep -E "mWakefulness=|Display Power: state=" | head -n 4 >&2 || true
        adb shell dumpsys window 2>&1 | grep -E "mDreamingLockscreen|isStatusBarKeyguard|mKeyguardShowing|mFocusedApp|mAwake" | head -n 6 >&2 || true
        echo "--- on screen (uiautomator text/desc) ---" >&2
        adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1 && adb shell cat /sdcard/ui.xml 2>/dev/null | grep -oE '(text|content-desc)="[^"]+"|focused="true"[^>]*' | head -n 40 >&2 || true
        echo "--- flutter log ---" >&2
        adb logcat -d -s flutter 2>/dev/null | tail -n 30 >&2 || true
        echo "--- system media/audio key logs ---" >&2
        adb logcat -d -s MediaSessionService MediaSessionStack MediaSessionRecord MediaSessionLegacyHelper AudioService WindowManager PhoneWindowManager 2>/dev/null | grep -iE "volume|session|KEYCODE" | tail -n 30 >&2 || true
      }
      for attempt in 1 2 3; do
        after_fresh_notification_lap
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
      path="$(adb logcat -d -s RunSolo/lapinput | grep -oE 'lap from [a-z]+' | tail -1 | sed 's/lap from //')"
      [ "$path" = session ] || fail "volume-key lap landed via '$path' on API $sdk, expected 'session'"
      # The key went to our session, not the music stream.
      vol_after="$(music_volume)"
      [ "$vol_after" = "$vol_before" ] || fail "music volume changed by the volume-key lap: $vol_before -> $vol_after"
      # A volume change that is not a key press (adb, 3 steps) must not lap.
      accepted_before="$(adb logcat -d | grep -c 'lap volumeKey → accepted' || true)"
      if [ "$vol_before" -ge 3 ]; then target=$((vol_before - 3)); else target=$((vol_before + 3)); fi
      set_music_volume "$target"
      sleep 3
      accepted_after="$(adb logcat -d | grep -c 'lap volumeKey → accepted' || true)"
      [ "$accepted_after" = "$accepted_before" ] || fail "an adb volume change without a key press produced a lap"
      set_music_volume "$vol_before"
      # Lockout (#40): two presses back to back, in one `input` call (a few ms apart), must record
      # exactly one lap. The second press dies in LapInput's 400 ms wall-clock debounce or, past
      # it, in RecorderCore's 1.5 s Laps lockout (run time; at 20x that is 75 ms of wall time, so
      # the emulator cannot separate the two: the exact boundaries are pinned in RecorderCoreTest).
      # Inconclusive only when fewer than two key-downs reached the session: retried, ::warning::.
      downs() { adb logcat -d -s RunSolo/lapinput | grep -c "direction=1" || true; }
      lockout=0
      for attempt in 1 2 3; do
        after_fresh_notification_lap
        k0="$(downs)"
        a0="$(n_log 'lap volumeKey → accepted')"
        d0="$(n_log 'lap volumeKey → ignoredDebounce')"
        adb shell input keyevent KEYCODE_VOLUME_UP KEYCODE_VOLUME_UP
        sleep 2
        keys=$(( $(downs) - k0 ))
        acc=$(( $(n_log 'lap volumeKey → accepted') - a0 ))
        deb=$(( $(n_log 'lap volumeKey → ignoredDebounce') - d0 ))
        if [ "$keys" -ge 2 ]; then
          [ "$acc" = 1 ] || fail "double press: $keys key-downs reached the session and $acc laps were accepted; expected exactly 1"
          log "double press: $keys key-downs, 1 lap ($deb ignored by the core lockout, the rest by the LapInput debounce)"
          lockout=1
          break
        fi
        echo "::warning::double press $attempt on API $sdk delivered $keys key-down(s) to the session; retrying"
      done
      [ "$lockout" = 1 ] || fail "the emulator never delivered both keys of a double press in 3 attempts; lockout unverified"
      log "manual + volume-key laps landed via $path (volume-key lap at run time ${vk_t} ms; volume $vol_before kept; adb change ignored; double press = 1 lap)"
    fi
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
if [ "$MODE" = laps ] && [ "$sdk" -eq 34 ]; then
  shell "run-as $PKG ls files/journals/$run_id" | grep -q volume-key-unavailable || fail "API 34: volumeKeyUnavailable marker missing from the journal dir"
fi
check_fatal "kill"

log "relaunch with recover; resume, then stop after 8 s"
adb logcat -c || true
adb shell am start -W -n "$ACTIVITY" --ez runsolo.recover true --el runsolo.stopAfterMs 8000 > /dev/null
wait_for_log "RunSolo/debug.*recover count=1 $run_id" 30 || fail "orphan not found on relaunch"
wait_for_log "RunSolo/debug.*exitDiagnosis runId=$run_id" 30 || fail "no exit diagnosis"
wait_for_log "RunSolo/debug.*resumeRecovered runId=$run_id error=null" 30 || fail "resume failed"
wait_for_log "RunSolo/session.*resumed $run_id after" 30 || fail "session did not resume"
if [ "$MODE" = laps ] && [ "$sdk" -eq 34 ]; then
  # Once per run: the recovered session must not show the note again.
  wait_for_log "RunSolo/session.*volumeKeyUnavailable already noted for $run_id" 10 || fail "API 34: recovered session did not see the volumeKeyUnavailable marker"
  if adb logcat -d | grep -q '"fault":"volumeKeyUnavailable"'; then fail "API 34: volumeKeyUnavailable fired again after recovery"; fi
fi
wait_for_log "RunSolo/debug.*stop .*runId=$run_id" 45 || fail "stop did not finalise"
check_fatal "recover/resume/stop"

runs="$(shell "run-as $PKG ls files/runs")"
echo "$runs" | grep -q "run-$run_id.json.gz" || fail "run file not committed"
shell "run-as $PKG ls files/journals" | grep -qx "$run_id" && fail "journal directory still present after finalise"
# A run file's own tmp must be gone once stop returned (Finaliser renames it before). The
# index and sidecar tmps are atomic writes the app finishes right after, so listing 0.6 s after
# finalise can catch one mid-write (#77 API 29, #61 API 34): those fail only if one outlives 60 s.
tmps="$(echo "$runs" | grep '\.tmp$' || true)"
if [ -n "$tmps" ]; then
  log "tmp files right after finalise: $(echo $tmps)"
  echo "$tmps" | grep -q '^run-.*\.json\.gz\.tmp$' && fail "run file tmp left behind: $(echo $tmps)"
  i=0
  while [ -n "$tmps" ] && [ "$i" -lt 60 ]; do
    sleep 1; i=$((i + 1))
    tmps="$(shell "run-as $PKG ls files/runs" | grep '\.tmp$' || true)"
  done
  [ -z "$tmps" ] || fail "tmp file left behind for 60 s: $(echo $tmps)"
  log "tmp files gone after ${i} s"
fi
shell pidof "$PKG" > /dev/null || fail "process died after finalise"

log "verify the run file contents"
adb exec-out "run-as $PKG cat files/runs/run-$run_id.json.gz" > /tmp/run.json.gz
python3 - "$run_id" "$MODE" "${vk_t:-}" "$sdk" <<'PY' || fail "run file assertions failed"
import gzip, json, sys
run_id, mode, vk_t, sdk = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
f = json.load(gzip.open("/tmp/run.json.gz"))
assert f["schema"] == 3 and f["id"] == run_id, f"header: schema {f['schema']}"
assert f["mode"] == mode, f"mode {f['mode']} != {mode}"
laps, gaps, samples = f["laps"], f["gaps"], f["samples"]
assert len(gaps) == 1 and gaps[0][1] > gaps[0][0] > 0, f"gaps={gaps}"
g0, g1 = gaps[0]
pre = [l for l in laps if l["t1"] <= g0]
assert "preset" not in f and "session" in f, f"schema-3 keys {list(f)}"
if mode == "intervals":
    s = f["session"]
    assert s["templateId"] == "norwegian-4x4" and s["hrBand"] == [0.85, 0.95], s
    assert [(st["kind"], st["value"], st["rep"]) for st in s["steps"]] == [("work", 240, 1), ("recovery", 180, 1), ("work", 240, 2), ("recovery", 180, 2), ("work", 240, 3), ("recovery", 180, 3), ("work", 240, 4)], s["steps"]
    assert len(pre) >= 3, f"laps before the kill: {len(pre)}"
    assert sum(1 for l in pre if l["kind"] == "auto") >= 2, "need >= 2 auto laps before the kill"
    # The warmup LAP is pressed on the fix 60 s of trace time after the first one (I5: presses
    # are keyed on trace time). The run clock starts when the service does, a few seconds before
    # the first fix arrives, so every time below is measured from the first sample. The auto-laps
    # that follow are landed on the exact phase boundary by the core, so their durations are exact.
    off = samples[0][0]
    assert 0 <= off <= 10000, f"first sample {off} ms after the start"
    assert pre[0]["kind"] == "manual" and pre[0]["t1"] - off == 60000, f"warmup lap {pre[0]} (first sample at {off} ms)"
    assert pre[1]["kind"] == "auto" and pre[1]["t1"] - pre[1]["t0"] == 240000, f"rep 1 work lap {pre[1]}"
    assert pre[2]["kind"] == "auto" and pre[2]["t1"] - pre[2]["t0"] == 180000, f"rep 1 recovery lap {pre[2]}"
    assert abs(pre[1]["t1"] - off - 300000) <= 1 and abs(pre[2]["t1"] - off - 480000) <= 1, "boundaries drifted"
elif mode == "laps":
    assert f["session"] is None, f["session"]
    assert len(pre) >= 3, f"manual laps before the kill: {len(pre)}"
    assert all(l["kind"] == "manual" for l in laps), "laps mode has no auto laps"
    # Laps from the debug intent are ~80 s of trace apart (4 s wall at 20x); the volume-key lap
    # arrives between two of them. Every lap must be strictly ordered and non-empty.
    assert all(b["t0"] == a["t1"] for a, b in zip(laps, laps[1:])), "laps must tile the run"
    assert all(l["t1"] > l["t0"] for l in laps), "empty lap"
    # The volume-key lap the session accepted must be in the file at that run time (same clock).
    # API 34 has no volume-key laps (asserted above), so no such lap there.
    if sdk == 34:
        assert not vk_t, f"API 34 logged a volume-key lap at {vk_t} ms"
    else:
        assert vk_t, "volume-key lap time missing from the log"
        assert any(abs(l["t1"] - int(vk_t)) <= 1000 for l in laps), f"no lap within 1 s of the volume-key press at {vk_t} ms: {[l['t1'] for l in laps]}"
elif mode == "free":
    assert f["session"] is None, f["session"]
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
assert len(before) >= (400 if mode == "intervals" else 60), f"samples before the kill: {len(before)}"
assert len(after) >= 3, f"samples after the gap: {len(after)}"
assert sum(1 for s in before if s[1] is not None) >= 0.95 * len(before), "replay samples should carry a fix (>= 95%)"
assert sum(1 for s in before if s[7] is not None) >= 0.9 * len(before), "HR missing on replay samples"
assert before[-1][6] > (900 if mode == "intervals" else 2.0 * g0 / 1000), f"distance before the kill too small: {before[-1][6]} m in {g0} ms"
print(f"ok [{mode}]: {len(laps)} laps ({len(pre)} pre-kill), gap {g0}->{g1} ms, {len(before)} samples before, {len(after)} after, {before[-1][6]:.0f} m")
PY

if [ "$MODE" != "intervals" ]; then
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
