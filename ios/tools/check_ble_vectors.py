#!/usr/bin/env python3
"""Fails when the Kotlin BLE parse tests and the shared iOS vectors drift apart.

Every byte literal `b(0x..)` / `ByteArray(0)` in BleTest.kt must be a `kotlin: true` vector in
ios/RunnerTests/Resources/ble-hr-vectors.json, and vice versa. Also checks the expected bpm of
the Kotlin vectors that BleTest asserts through `assertEquals(<n>, ...bpm...(b(...)))`.
"""
import json, re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
kt = (root / "android/core-jvm/src/commonTest/kotlin/app/runsolo/core/ble/BleTest.kt").read_text()
data = json.loads((root / "ios/RunnerTests/Resources/ble-hr-vectors.json").read_text())

def lit(s):
    return tuple(int(x, 16) for x in re.findall(r"0x[0-9A-Fa-f]+", s))

kotlin_vecs = {lit(m) for m in re.findall(r"\bb\(([^)]*)\)", kt)}
if "ByteArray(0)" in kt:
    kotlin_vecs.add(())
json_vecs = {tuple(v["bytes"]) for v in data["vectors"] if v["kotlin"]}

bad = False
for label, a, b in (("in BleTest.kt but not in the iOS vectors", kotlin_vecs, json_vecs),
                    ("in the iOS vectors (kotlin:true) but not in BleTest.kt", json_vecs, kotlin_vecs)):
    for v in sorted(a - b):
        print(f"DRIFT: {label}: {[hex(x) for x in v]}")
        bad = True

# Expected bpm asserted directly on a literal, e.g. assertEquals(72, HeartRateMeasurement.bpmOrNull(b(0x06, 0x48)))
for exp, vec in re.findall(r"assertEquals\((\d+),\s*HeartRateMeasurement\.bpmOrNull\(b\(([^)]*)\)\)", kt):
    row = next((v for v in data["vectors"] if tuple(v["bytes"]) == lit(vec)), None)
    if row is None or row["parsed"] is None or row["parsed"]["bpm"] != int(exp):
        print(f"DRIFT: BleTest expects bpm {exp} for {vec}, vectors say {row and row['parsed']}")
        bad = True

print("ble vectors: DRIFT" if bad else f"ble vectors: in step ({len(json_vecs)} shared)")
sys.exit(1 if bad else 0)
