#!/usr/bin/env bash
# T0 spike (draft PR only): install the spike APK offline, let it walk the map stages, and
# collect logcat, meminfo samples, screenshots and the takeSnapshot PNGs into topo-spike/.
# Usage: tools/emulator_topo_spike.sh <apk> <package>
set -uo pipefail
APK="${1:?apk}"
PKG="${2:?package}"
OUT=topo-spike
mkdir -p "$OUT/shots" "$OUT/snaps"

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
sleep 15
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
adb install -r "$APK"
# Offline from here on: any tile, glyph or style request over the network would show as a failure.
adb shell svc wifi disable || true
adb shell svc data disable || true
adb shell cmd connectivity airplane-mode enable || true
adb logcat -c || true
adb logcat -v time > "$OUT/logcat.txt" 2>&1 &
LOGCAT_PID=$!

adb shell am start -W -n "$PKG/app.runsolo.MainActivity" > /dev/null
START=$(date +%s)
i=0
while [ $(( $(date +%s) - START )) -lt 120 ]; do
  i=$((i + 1))
  adb exec-out screencap -p > "$OUT/shots/$(printf %03d $i).png" 2>/dev/null || true
  {
    echo "t=$(( $(date +%s) - START )) pid=$(adb shell pidof "$PKG" | tr -d '\r')"
    adb shell dumpsys meminfo "$PKG" | grep -E "TOTAL PSS|TOTAL:|Native Heap|Graphics|Java Heap" | head -6
  } >> "$OUT/meminfo.txt"
  grep -q "TOPO_SPIKE DONE" "$OUT/logcat.txt" && break
  sleep 3
done
sleep 3
kill "$LOGCAT_PID" 2>/dev/null || true

for f in $(adb shell ls "/sdcard/Android/data/$PKG/files/" 2>/dev/null | tr -d '\r' | grep '^snap_'); do
  adb pull "/sdcard/Android/data/$PKG/files/$f" "$OUT/snaps/$f" > /dev/null || true
done

echo "---- TOPO_SPIKE lines"
grep "TOPO_SPIKE" "$OUT/logcat.txt" || true
echo "---- native map errors"
grep -iE "mbgl|maplibre|glyph|pmtiles" "$OUT/logcat.txt" | grep -iE "error|fail|warn|cannot|unable" | head -40 || true
echo "---- fatal"
grep -E "FATAL EXCEPTION|Fatal signal|SIGSEGV" "$OUT/logcat.txt" | head -10 || true
ls -la "$OUT/snaps"

grep -q "TOPO_SPIKE DONE" "$OUT/logcat.txt" || { echo "spike did not reach DONE" >&2; exit 1; }
if grep -qE "FATAL EXCEPTION|Fatal signal" "$OUT/logcat.txt"; then echo "crash in logcat" >&2; exit 1; fi
