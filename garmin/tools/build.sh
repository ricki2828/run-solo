#!/usr/bin/env bash
# Builds one signed .prg per target device.
#   CIQ_SDK   SDK root (contains bin/monkeybrains.jar)                          required
#   CIQ_KEY   developer key, DER                                                 required
#   OUT       output dir for <device>.prg and build-report.md                    default garmin/out
# Devices come from $HOME/.Garmin/ConnectIQ/Devices (where the SDK Manager and monkeyc keep them;
# confirmed with strace against SDK 9.3.0). Only ids in products.txt that exist there are built;
# unknown ids are warned about, not silently dropped. Any compile failure fails the script.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
: "${CIQ_SDK:?}" "${CIQ_KEY:?}"
OUT="${OUT:-$here/out}"
devdir="$HOME/.Garmin/ConnectIQ/Devices"
mkdir -p "$OUT" "$here/build"
rm -f "$OUT"/*.prg

python3 -I "$here/tools/check_ids.py"

ids=()
while read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs || true)"
  [ -n "$line" ] && ids+=("$line")
done < "$here/products.txt"

todo=(); missing=()
for id in "${ids[@]}"; do
  if [ -d "$devdir/$id" ]; then todo+=("$id"); else missing+=("$id"); fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "::warning::products.txt ids not in the Devices bundle (skipped): ${missing[*]}"
fi
if [ "${#todo[@]}" -eq 0 ]; then
  echo "::error::no product from products.txt exists in $devdir" >&2; exit 1
fi

# Generated manifest: same app, product list = todo. Jungle paths are relative to build/.
python3 -I - "$here" "${todo[@]}" <<'PY'
import re, sys
here, ids = sys.argv[1], sys.argv[2:]
m = open(f"{here}/manifest.xml").read()
block = "<iq:products>\n" + "".join(f'            <iq:product id="{i}"/>\n' for i in ids) + "        </iq:products>"
m, n = re.subn(r"<iq:products>.*?</iq:products>", block, m, flags=re.S)
assert n == 1
open(f"{here}/build/manifest.xml", "w").write(m)
open(f"{here}/build/monkey.jungle", "w").write(
    "project.manifest = manifest.xml\nbase.sourcePath = ../source\nbase.resourcePath = ../resources\n")
PY

{ echo "| device | result | .prg bytes | watch-app memory limit (compiler.json, best effort) |"; echo "|---|---|---|---|"; } > "$OUT/build-report.md"
failed=()
for id in "${todo[@]}"; do
  if java -Xms512m -Dfile.encoding=UTF-8 -cp "$CIQ_SDK/bin/monkeybrains.jar" com.garmin.monkeybrains.Monkeybrains \
       -f "$here/build/monkey.jungle" -o "$OUT/$id.prg" -y "$CIQ_KEY" -d "$id" -w -l 0 > "$here/build/$id.log" 2>&1; then
    size="$(stat -c %s "$OUT/$id.prg")"; res="ok"
  else
    size="-"; res="FAILED"; failed+=("$id"); echo "::group::compile log $id"; cat "$here/build/$id.log"; echo "::endgroup::"
  fi
  warn="$(grep -ci 'warning' "$here/build/$id.log" || true)"
  mem="$(python3 -I - "$devdir/$id/compiler.json" <<'PY' 2>/dev/null || echo "?"
import json, sys
d = json.load(open(sys.argv[1]))
def walk(x):
    if isinstance(x, dict):
        if x.get("type") == "watch-app" and "memoryLimit" in x: yield x["memoryLimit"]
        for v in x.values(): yield from walk(v)
    elif isinstance(x, list):
        for v in x: yield from walk(v)
print(next(walk(d), "?"))
PY
)"
  echo "| $id | $res ($warn warning lines) | $size | $mem |" >> "$OUT/build-report.md"
done
cat "$OUT/build-report.md"
if [ "${#failed[@]}" -gt 0 ]; then echo "::error::compile failed for: ${failed[*]}" >&2; exit 1; fi
