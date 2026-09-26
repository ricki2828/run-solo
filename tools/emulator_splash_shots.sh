#!/usr/bin/env bash
# B3 evidence (plan §4): the system splash -> Lap Draw intro hand-off on this API level.
# A cold first launch (full intro) and a second cold launch (0.6 s intro), each as a short
# screen recording plus stills, into splash-shots/api<N>/ for the CI artifact. Runs last:
# `pm clear` wipes app data. Evidence only: it never fails the job.
# Note: the emulator job disables animations, which Flutter reads as reduced motion, so the
# intro shows its static final frame; the hand-off and the absence of a white flash are
# what these shots check. Usage: tools/emulator_splash_shots.sh <package>
set -uo pipefail
PKG="${1:?package}"
ACTIVITY="$PKG/app.runsolo.MainActivity"
SDK="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
OUT="splash-shots/api$SDK"
mkdir -p "$OUT"

shoot() { # <name> <record seconds>
  local name="$1" secs="$2"
  adb shell am force-stop "$PKG" || true
  sleep 2
  adb shell "screenrecord --time-limit $secs /sdcard/$name.mp4" &
  local rec=$!
  sleep 1
  adb shell am start -n "$ACTIVITY" > /dev/null || true
  for t in 0 1 2; do
    adb exec-out screencap -p > "$OUT/$name-still$t.png" 2> /dev/null || true
    sleep 0.3
  done
  wait "$rec" || true
  # The settled first route (onboarding on a first launch): cold debug starts
  # on CI take 3-5 s, so the stills above can all still be the system splash.
  adb exec-out screencap -p > "$OUT/$name-settled.png" 2> /dev/null || true
  adb pull "/sdcard/$name.mp4" "$OUT/$name.mp4" > /dev/null 2>&1 || true
}

adb shell pm clear "$PKG" > /dev/null || true
shoot first-launch-full 10
shoot second-launch-short 8
ls -la "$OUT" || true
exit 0
