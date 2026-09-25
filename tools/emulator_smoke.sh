#!/usr/bin/env bash
# Phase 0 emulator scaffold: install the debug APK, launch it, assert the process is alive
# and nothing fatal hit logcat. Phase 1 replaces the launch with the replay-mode lifecycle
# test (start -> auto-laps -> am kill -> relaunch -> recovery dialog -> finalise -> indexed).
# Usage: tools/emulator_smoke.sh <apk> <package>
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"

ACTIVITY="$PKG/app.runsolo.MainActivity"
adb wait-for-device
adb shell getprop ro.build.version.sdk
# Boot-complete + a settle: hosted-runner emulators are still starting GMS when adb is up,
# and a GMS ANR dialog steals the launch (seen on API 34: "com.google.android.gms.persistent
# is not responding", 0 monkey events injected).
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
sleep 15
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
adb logcat -c || true
adb install -r "$APK"
# Explicit start (not monkey): a system-app ANR aborts monkey before it injects anything.
# Retry once if the process is not up — only a FATAL in OUR process fails the run.
launch() { adb shell am start -W -n "$ACTIVITY" > /dev/null; sleep 12; adb shell pidof "$PKG" > /dev/null; }
if ! launch; then
  echo "first launch did not come up; closing system dialogs and retrying once"
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
  sleep 5
  launch || true
fi

if ! adb shell pidof "$PKG" > /dev/null; then
  # A dead emulator makes `adb logcat` block on "waiting for device" until the job timeout
  # (seen on API 29: "error: closed" after install, then 37 min idle). Fail fast instead.
  if [ "$(timeout 10 adb get-state 2>/dev/null | tr -d '\r')" != "device" ]; then
    echo "emulator went away during launch (runner infra, not an app crash); re-run the job" >&2
    exit 1
  fi
  echo "process $PKG is not running after launch" >&2
  timeout 60 adb logcat -d | tail -n 200
  exit 1
fi
echo "$PKG running (pid $(adb shell pidof "$PKG"))"

if timeout 60 adb logcat -d | grep -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG" > /tmp/fatal.log; then
  echo "fatal exception in logcat:" >&2
  cat /tmp/fatal.log
  exit 1
fi
echo "smoke ok on API $(adb shell getprop ro.build.version.sdk)"
