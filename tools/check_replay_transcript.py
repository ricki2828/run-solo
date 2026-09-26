#!/usr/bin/env python3
"""Compare what the real service said in a T4 replay with the core-jvm transcript fixture
(Phase 4 §5 T4, `TranscriptFixture`).

Usage: check_replay_transcript.py <logcat.txt> <transcripts/<kind>.json>

The service logs `RunSolo/session: said <trace ms> <text>` for each cue it speaks in replay mode
(the stop cue excepted); replay time is trace time, so times and text must match exactly, in
order. Exits 1 with the first differences listed.
"""
import json
import re
import sys

SAID = re.compile(r"RunSolo/session: said (\d+) (.*)$")


def main() -> int:
    got = []
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        for line in f:
            m = SAID.search(line.rstrip("\r\n"))
            if m:
                got.append((int(m.group(1)), m.group(2)))
    want = [(s["t"], s["text"]) for s in json.load(open(sys.argv[2], encoding="utf-8"))["said"]]
    if got == want:
        print(f"transcript matches: {len(want)} lines")
        return 0
    print(f"transcript differs: device said {len(got)} lines, fixture has {len(want)}", file=sys.stderr)
    shown = 0
    for i in range(max(len(got), len(want))):
        a = got[i] if i < len(got) else None
        b = want[i] if i < len(want) else None
        if a != b:
            print(f"  #{i}: device {a}\n       fixture {b}", file=sys.stderr)
            shown += 1
            if shown == 10:
                break
    return 1


if __name__ == "__main__":
    sys.exit(main())
