#!/usr/bin/env python3
"""Compact error digest for the iOS workflow (plan §6.1, eng review token controls).

Builders read this ~30-line digest, not the multi-thousand-line Xcode log. It takes the
step logs in order, keeps the first distinct error lines (compiler file:line errors,
CocoaPods, Flutter tool and xcodebuild failures) and ends with the tail of the last log
that has any content, so a failure with no recognised error line still shows something.

    error_digest.py OUT LOG [LOG ...]

Writes OUT and, when GITHUB_STEP_SUMMARY is set, appends the same text to the job summary.
Always exits 0: it reports, the build steps decide pass or fail.
"""
import os
import pathlib
import re
import sys

MAX_ERRORS = 22
TAIL = 6
ERROR = re.compile(
    r"(\berror:|\bfatal error\b|Error \(Xcode\)|\*\* (BUILD|ARCHIVE|EXPORT) FAILED \*\*"
    r"|^\[!\]|Error output from CocoaPods|Could not build|Failed to build"
    r"|Encountered error while|Undefined symbols?|ld: |clang: error|Exception:|Unhandled exception)",
    re.I,
)
NOISE = re.compile(r"warning:|^\s*$|error_digest\.py")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def main(argv):
    out, logs = pathlib.Path(argv[1]), [pathlib.Path(p) for p in argv[2:]]
    seen, errors, last = set(), [], None
    for log in logs:
        if not log.exists():
            continue
        lines = [ANSI.sub("", l).rstrip() for l in log.read_text(errors="replace").splitlines()]
        if any(lines):
            last = (log, lines)
        for line in lines:
            if NOISE.search(line) or not ERROR.search(line):
                continue
            key = re.sub(r"\s+", " ", line.strip())[:300]
            if key in seen:
                continue
            seen.add(key)
            errors.append(f"{log.name}: {key}")
    body = [f"## iOS digest: {len(errors)} distinct error line(s)" + (" (first shown)" if len(errors) > MAX_ERRORS else "")]
    body += errors[:MAX_ERRORS] or ["(no error lines matched)"]
    if last:
        log, lines = last
        body += ["", f"tail of {log.name}:"] + [l for l in lines if l.strip()][-TAIL:]
    text = "\n".join(body) + "\n"
    out.write_text(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("```\n" + text + "```\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
