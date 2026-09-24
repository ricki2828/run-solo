#!/usr/bin/env bash
# 16 KB page-size gate (plan §10/§11): every 64-bit native library in the APK/AAB must have
# its ELF LOAD segments aligned to >= 0x4000, and the zip entries must be 16 KB aligned.
# Usage: tools/check_16kb_alignment.sh <apk-or-aab> [zipalign-path]
set -euo pipefail
ARCHIVE="${1:?apk or aab path}"
ZIPALIGN="${2:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q -o "$ARCHIVE" -d "$WORK"
READELF="$(command -v llvm-readelf || command -v readelf)"
fail=0; checked=0
while IFS= read -r so; do
  case "$so" in
    *arm64-v8a*|*x86_64*) ;;
    *) continue ;;   # 32-bit ABIs are not subject to the 16 KB rule
  esac
  checked=$((checked+1))
  # Alignment column of every LOAD program header, e.g. 0x1000 or 0x4000.
  bad=$("$READELF" -lW "$so" | awk '$1=="LOAD" {print $NF}' | grep -vE '^0x(4000|8000|10000|20000|40000)$' || true)
  if [ -n "$bad" ]; then
    echo "MISALIGNED: ${so#$WORK/} (LOAD align: $(echo "$bad" | tr '\n' ' '))"
    fail=1
  else
    echo "ok: ${so#$WORK/}"
  fi
done < <(find "$WORK" -name '*.so' | sort)

if [ "$checked" -eq 0 ]; then
  echo "no 64-bit .so files found in $ARCHIVE" >&2
  exit 2
fi

if [ -n "$ZIPALIGN" ] && [[ "$ARCHIVE" == *.apk ]]; then
  if ! "$ZIPALIGN" -c -P 16 -v 4 "$ARCHIVE" > "$WORK/zipalign.log" 2>&1; then
    echo "zipalign -P 16 check failed:"; tail -n 20 "$WORK/zipalign.log"; fail=1
  else
    echo "ok: zipalign -P 16"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "16 KB page-size check FAILED" >&2
  exit 1
fi
echo "16 KB page-size check passed ($checked libraries)"
