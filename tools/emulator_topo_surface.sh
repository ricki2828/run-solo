#!/usr/bin/env bash
# Topo map surface on an emulator: install the harness APK (online, so it can fetch the Milos
# pack from the live R2 hosting), switch to airplane mode the moment the pack is installed, then
# let it show run detail, the live map, a Home card and a run with no pack. Collects logcat,
# meminfo and screenshots into topo-surface/.
# Usage: tools/emulator_topo_surface.sh <apk> <package>
set -uo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
OUT=topo-surface
mkdir -p "$OUT/shots"

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
sleep 15
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
adb install -r "$APK"
adb logcat -c || true
adb logcat -v time > "$OUT/logcat.txt" 2>&1 &
LOGCAT_PID=$!

adb shell am start -W -n "$PKG/app.runsolo.MainActivity" > /dev/null
START=$(date +%s)
OFFLINE=0
i=0
while [ $(( $(date +%s) - START )) -lt 240 ]; do
  i=$((i + 1))
  if [ "$OFFLINE" = 0 ] && grep -q "TOPO_SURFACE pack_installed" "$OUT/logcat.txt"; then
    # Offline from here on: a tile, glyph or style request over the network would fail loudly.
    adb shell svc wifi disable || true
    adb shell svc data disable || true
    adb shell cmd connectivity airplane-mode enable || true
    OFFLINE=1
    echo "airplane mode on at t=$(( $(date +%s) - START ))"
  fi
  adb exec-out screencap -p > "$OUT/shots/$(printf %03d $i).png" 2>/dev/null || true
  {
    echo "t=$(( $(date +%s) - START )) pid=$(adb shell pidof "$PKG" | tr -d '\r')"
    adb shell dumpsys meminfo "$PKG" | grep -E "TOTAL PSS|TOTAL:|Native Heap|Graphics" | head -4
  } >> "$OUT/meminfo.txt"
  grep -q "TOPO_SURFACE DONE" "$OUT/logcat.txt" && break
  sleep 3
done
sleep 3
kill "$LOGCAT_PID" 2>/dev/null || true

echo "---- TOPO_SURFACE lines"
grep "TOPO_SURFACE" "$OUT/logcat.txt" || true
echo "---- map verdicts"
grep -E "flutter.*map: " "$OUT/logcat.txt" | head -20 || true
echo "---- native map errors"
grep -iE "mbgl|maplibre|glyph|pmtiles" "$OUT/logcat.txt" | grep -iE "error|fail|cannot|unable" | head -40 || true
echo "---- fatal"
grep -E "FATAL EXCEPTION|Fatal signal|SIGSEGV" "$OUT/logcat.txt" | head -10 || true

FAIL=0
grep -q "TOPO_SURFACE pack_installed" "$OUT/logcat.txt" || { echo "pack was never installed" >&2; FAIL=1; }
grep -q "TOPO_SURFACE DONE" "$OUT/logcat.txt" || { echo "harness did not reach DONE" >&2; FAIL=1; }
if grep -qE "FATAL EXCEPTION|Fatal signal" "$OUT/logcat.txt"; then echo "crash in logcat" >&2; FAIL=1; fi
# The Home card must have produced a verified, non-blank Topo snapshot while offline.
grep -E "flutter.*map: card passed.*topo" "$OUT/logcat.txt" > /dev/null || { echo "no passing Topo card snapshot" >&2; FAIL=1; }
if grep -E "flutter.*map: .*failed" "$OUT/logcat.txt" | grep -q topo; then echo "a Topo map reported failed" >&2; FAIL=1; fi
if grep -iE "mbgl|maplibre|glyph" "$OUT/logcat.txt" | grep -iE "glyph.*(fail|error|not found)|failed to load glyph" > /dev/null; then echo "glyph errors" >&2; FAIL=1; fi
exit "$FAIL"
