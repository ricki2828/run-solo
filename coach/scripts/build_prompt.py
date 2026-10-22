#!/usr/bin/env python3
"""Compile the run-coach skill into one system prompt for any chat model.

Usage: build_prompt.py [--with-tools] > prompt.txt
The order is fixed so prompt caching stays warm across calls: SKILL body, then references.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REFS = ["voice", "interpreting-messages", "coaching-method", "plan-building", "insight", "safety", "research", "injury-triage"]


def body(path: Path) -> str:
    text = path.read_text()
    if text.startswith("---"):
        text = text.split("---", 2)[2]   # drop YAML frontmatter
    return text.strip()


def extra_tools() -> list[dict]:
    """Tools a later PR adds by dropping `tools.d/<name>.json` ({"tools": [...]}): the same schema form as tools.json, plus an
    optional "module" (default: the file name) naming the server module that runs it. tools.json itself is never edited."""
    out: list[dict] = []
    for path in sorted((ROOT / "tools.d").glob("*.json")):
        for t in json.loads(path.read_text())["tools"]:
            out.append({"module": path.stem, **t})
    return out


def build(with_tools: bool = False) -> str:
    parts = [body(ROOT / "SKILL.md")]
    parts += [f"<reference name=\"{r}\">\n{body(ROOT / 'references' / f'{r}.md')}\n</reference>" for r in REFS]
    if with_tools:   # for engines without native tool calling
        parts.append("<tools>\n" + json.dumps(json.loads((ROOT / "tools.json").read_text())["tools"] + extra_tools(), indent=1) + "\n</tools>")
    return "\n\n".join(parts) + "\n"


if __name__ == "__main__":
    sys.stdout.write(build("--with-tools" in sys.argv))
