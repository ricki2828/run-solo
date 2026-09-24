#!/usr/bin/env bash
# Phase 0 emulator scaffold: install the debug APK, launch it, assert the process is alive
# and nothing fatal hit logcat. Phase 1 replaces the launch with the replay-mode lifecycle
# test (start -> auto-laps -> am kill -> relaunch -> recovery dialog -> finalise -> indexed).
# Usage: tools/emulator_smoke.sh <apk> <package>
set -euo pipefail
APK="${1:?apk}"
PKG="${2:?package}"

adb wait-for-device
adb shell getprop ro.build.version.sdk
adb logcat -c || true
adb install -r "$APK"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
sleep 12

if ! adb shell pidof "$PKG" > /dev/null; then
  echo "process $PKG is not running after launch" >&2
  adb logcat -d | tail -n 200
  exit 1
fi
echo "$PKG running (pid $(adb shell pidof "$PKG"))"

if adb logcat -d | grep -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG" > /tmp/fatal.log; then
  echo "fatal exception in logcat:" >&2
  cat /tmp/fatal.log
  exit 1
fi
echo "smoke ok on API $(adb shell getprop ro.build.version.sdk)"
