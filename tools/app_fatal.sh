#!/usr/bin/env bash
# Reads `adb logcat -d` (threadtime format) on stdin and prints the AndroidRuntime lines of every
# crash in OUR package; exit 0 if there was one (grep convention), 1 if not. A crash of any other
# process (a system app or GMS on the emulator image) is not ours and is ignored. The crash is
# identified by its "Process: <package>, PID: n" line, so an app that crashed and was restarted
# under a new pid is still caught.
# Usage: adb logcat -d | tools/app_fatal.sh <package>
set -euo pipefail
PKG="${1:?package}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
awk -v pkg="$PKG" '
  NR == FNR {
    if ($0 ~ /E AndroidRuntime/ && index($0, "Process: " pkg ",") > 0) pids[$3] = 1
    next
  }
  $0 ~ /E AndroidRuntime/ && ($3 in pids) { print; found = 1 }
  END { exit found ? 0 : 1 }
' "$tmp" "$tmp"
