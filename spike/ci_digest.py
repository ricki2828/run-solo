#!/usr/bin/env python3
"""K0 spike CI digest: ~40 lines a builder reads instead of the full log.

Usage: ci_digest.py <logs dir>. Reads <logs>/*.log, <logs>/status.txt (step=rc), timings.txt,
versions.txt; JUnit XML under kmp-core/build/test-results; conformance reports; XCFramework size.
"""
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
logs = sys.argv[1]
out = []


def read(name):
    p = os.path.join(logs, name)
    return open(p, errors="replace").read() if os.path.exists(p) else ""


out.append("## K0 KMP spike digest")
out.append("versions: " + " | ".join(l for l in read("versions.txt").splitlines() if l.strip()))
out.append("steps (rc, seconds): " + " | ".join(l.strip() for l in read("status.txt").splitlines() if l.strip()))

# Tests per target.
res = {}
for x in glob.glob(os.path.join(HERE, "kmp-core/build/test-results/*/*.xml")):
    target = os.path.basename(os.path.dirname(x))
    r = res.setdefault(target, [0, 0, []])
    for tc in ET.parse(x).getroot().iter("testcase"):
        r[0] += 1
        f = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
        if f is not None:
            r[1] += 1
            msg = (f.get("message") or "").splitlines()[0][:160] if f.get("message") else ""
            r[2].append(f"{tc.get('classname', '').rsplit('.', 1)[-1]}.{tc.get('name')}: {msg}")
for t, (n, nf, fails) in sorted(res.items()):
    out.append(f"tests {t}: {n} run, {nf} failed")
    out += [f"  FAIL {f}" for f in fails[:8]]
    if len(fails) > 8:
        out.append(f"  ... {len(fails) - 8} more")

# Conformance reports: only the lines that matter.
for rpt in sorted(glob.glob(os.path.join(HERE, "kmp-core/build/reports/conformance/*.txt"))):
    lines = open(rpt).read().splitlines()
    keep = [l for l in lines if l.startswith("#") or "DIFFER" in l or "ERROR" in l or l.startswith(("parsed-equal", "double probe", "edge doubles", "  edge", "iso"))]
    out.append(f"conformance {os.path.basename(rpt)}:")
    out += ["  " + l[:300] for l in keep[:14]]

sizes = read("sizes.txt").strip()
if sizes:
    out.append("sizes: " + " | ".join(sizes.splitlines()))

# First compiler / build errors per log.
pat = re.compile(r"^(e: |.*error: |\* What went wrong|> .*(failed|Failed)|Testing failed|.*\*\* TEST FAILED|.*Test Case .* failed|BUILD FAILED)")
for log in sorted(glob.glob(os.path.join(logs, "*.log"))):
    hits = []
    lines = open(log, errors="replace").read().splitlines()
    for i, l in enumerate(lines):
        if pat.match(l):
            hits.append(l.strip()[:220])
            if l.startswith("* What went wrong") and i + 1 < len(lines):
                hits.append("  " + lines[i + 1].strip()[:220])
    if hits:
        out.append(f"errors {os.path.basename(log)} ({len(hits)}):")
        seen = []
        for h in hits:
            if h not in seen:
                seen.append(h)
        out += ["  " + h for h in seen[:8]]

text = "\n".join(out) + "\n"
open(os.path.join(logs, "digest.txt"), "w").write(text)
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as f:
        f.write("```\n" + text + "```\n")
print(text)
