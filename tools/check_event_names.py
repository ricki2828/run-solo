#!/usr/bin/env python3
"""K1: the Saturday 5 km event's name is a registered trademark.

Fail when the word appears in a string literal of app, engine or native
source outside the one flavour config (lib/app/event_names.dart), unless the
line carries `event-name-ok` (a data key such as ComparisonKey.parkrun, never
shown or spoken). Comments are not copy and are ignored. Android resources
(strings, store text) are checked whole, comments included.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORD = re.compile(r"parkrun", re.I)
INTERP = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_]\w*")
LITERAL = re.compile(r"""('([^'\\\n]|\\.)*'|"([^"\\\n]|\\.)*")""")
SOURCES = [
    ("lib", "*.dart"),
    ("packages/run_engine/lib", "*.dart"),
    ("android/app/src/main/kotlin", "*.kt"),
    ("android/core-jvm/src/main/kotlin", "*.kt"),
]
RESOURCES = ["android/app/src/main/res", "android/app/src/play", "fastlane", "store"]
ALLOWED_FILES = {"lib/app/event_names.dart"}


def is_generated(p: pathlib.Path) -> bool:
    return p.name.endswith((".g.dart", ".g.kt"))


def main() -> int:
    bad = []
    for root, pattern in SOURCES:
        for p in sorted((ROOT / root).rglob(pattern)):
            rel = p.relative_to(ROOT).as_posix()
            if is_generated(p) or rel in ALLOWED_FILES:
                continue
            for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                code = line.strip()
                if code.startswith(("//", "*", "/*", "import ", "export ")) or "event-name-ok" in line:
                    continue
                code = code.split(" //", 1)[0]
                # Interpolated identifiers (`$parkrun`, `${names.parkrun}`) are not text.
                texts = [INTERP.sub("", m.group(0)) for m in LITERAL.finditer(code)]
                if any(WORD.search(t) for t in texts):
                    bad.append(f"{rel}:{n}: {line.strip()}")
    for root in RESOURCES:
        base = ROOT / root
        if not base.exists():
            continue
        for p in sorted(base.rglob("*")):
            if not p.is_file() or p.suffix not in {".xml", ".txt", ".json", ".md"}:
                continue
            for n, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if WORD.search(line):
                    bad.append(f"{p.relative_to(ROOT).as_posix()}:{n}: {line.strip()}")
    if bad:
        print("The event name must come from lib/app/event_names.dart (EventNames), not a literal:")
        print("\n".join(bad))
        return 1
    print("event names: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
