#!/usr/bin/env python3
"""Run the red-flag phrasings through both safety layers: the regex tiers and the REAL classifier.

    OPENROUTER_API_KEY=... python3 scripts/redflag_eval.py [--model anthropic/claude-haiku-5.5]

Costs a few cents (one Haiku call per phrasing, max_tokens 60). Without OPENROUTER_API_KEY it does nothing and exits 2.
Prints each phrasing with its regex tier, the classifier verdict and the final decision (what the worker would do),
then false negatives (a red flag that would reach the main model) and false positives (a harmless message that would
get the safety reply). The classifier is called with the production settings (coach/screen.py).
"""
from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tests"))

import httpx  # noqa: E402

from companion.coach import redflag, screen  # noqa: E402
from redflag_cases import HARMLESS, RED_FLAGS  # noqa: E402


def decide(text: str, http: httpx.Client, key: str, model: str) -> tuple[str, str, bool]:
    level, _kind = redflag.tier(text)
    if level == redflag.HARD:
        return "hard", "-", True
    data, why = screen.call(http, "https://openrouter.ai/api/v1", key, screen.request_body(model, text, 60), 5.0)
    verdict = screen.parse(data) if data else None
    if verdict is None:
        return level or "none", f"error:{why or 'bad_output'}", level == redflag.SOFT
    hit = verdict[screen.SELF_HARM] or verdict[screen.URGENT_MEDICAL]
    return level or "none", ",".join(k for k, v in verdict.items() if v) or "clear", hit


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("COMPANION_COACH_SCREEN_MODEL", "anthropic/claude-haiku-5.5"))
    args = ap.parse_args()
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        print("OPENROUTER_API_KEY is not set: nothing run")
        return 2
    fn, fp = [], []
    with httpx.Client() as http:
        for text, want in [(t, True) for t in RED_FLAGS] + [(t, False) for t in HARMLESS]:
            tier, verdict, safety = decide(text, http, key, args.model)
            print(f"{'RED ' if want else 'OK  '} {tier:5} {verdict:28} {'SAFETY' if safety else 'coach '}  {text}")
            if want and not safety:
                fn.append(text)
            if not want and safety:
                fp.append(text)
    print(f"\nfalse negatives {len(fn)}/{len(RED_FLAGS)}: {fn}")
    print(f"false positives {len(fp)}/{len(HARMLESS)}: {fp}")
    return 1 if fn else 0


if __name__ == "__main__":
    sys.exit(main())
