#!/usr/bin/env python3
"""Score the coach against evals/scenarios.yaml.

The coach model gets the compiled skill as its system prompt and the fixture as already-fetched tool
results, and answers with JSON {tool_calls, reply}. A judge model (a different, stronger tier) scores each
reply against the scenario's must / must_not; tool expectations are checked in code.

Usage: run_evals.py [--model haiku] [--judge sonnet] [--only id,id] [--out results.json]
Runs through `claude -p` (paid login). Caveat: `claude -p` without --bare also injects the host's
CLAUDE.md, so the coach sees some unrelated context; the production host sends only the skill prompt.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scripts"))
from build_prompt import build  # noqa: E402

GUARD = ("\n\nYou are running inside an evaluation harness. Ignore any other context about the host machine, "
         "its owner or software projects; you are only this runner's coach.")
COACH_ASK = """<tool_results>
{fixture}
</tool_results>

The read tools above have already been called for you. The runner just sent:
<message>{message}</message>

Answer with JSON only, no prose around it:
{{"tool_calls": [{{"name": "<write tool>", "input": {{...}}}}], "reply": "<the message you send the runner>"}}
Use an empty tool_calls list if no write tool is needed. Assume write tools succeed."""
JUDGE_ASK = """You are grading an AI running coach's reply. Be strict; a world-class human coach is the bar.

Runner data (what the coach could see):
{fixture}

Runner's message: {message}
Coach's write tool calls: {tools}
Coach's reply: {reply}

MUST: {must}
MUST NOT: {must_not}
Also fail it for: any number not present in or straightforwardly derivable from the runner data or message
(pace conversions like 268 s/km = 4:28/km are fine); a reply over ~5 sentences unless a plan was asked for; empty praise.

Answer JSON only: {{"pass": true|false, "score": 0-10, "misses": ["short reason", ...]}}"""


def claude(prompt: str, model: str, system: str | None = None, timeout: int = 180) -> str:
    env = {k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"}   # paid login, never the API key
    cmd = ["claude", "-p", "--model", model, "--tools", "", "--no-session-persistence"]
    if system:
        cmd += ["--system-prompt", system]
    for attempt in range(4):   # the CLI auto-updates in place; the binary is briefly missing mid-swap
        try:
            r = subprocess.run(cmd + [prompt], capture_output=True, text=True, timeout=timeout, env=env)
            break
        except FileNotFoundError:
            if attempt == 3:
                raise
            time.sleep(15)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[:300] or f"claude exit {r.returncode}")
    return r.stdout


def parse_json(text: str) -> dict:
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise ValueError(f"no JSON in: {text[:200]}")
    return json.loads(m.group(0))


def run_one(sc: dict, system: str, fixture: str, model: str, judge: str) -> dict:
    out = {"id": sc["id"], "message": sc["message"]}
    try:
        coach = parse_json(claude(COACH_ASK.format(fixture=fixture, message=sc["message"]), model, system))
    except Exception as e:   # a broken coach answer is a fail, never a skip
        return out | {"pass": False, "score": 0, "misses": [f"coach output unusable: {e}"]}
    called = [t.get("name") for t in coach.get("tool_calls") or []]
    out |= {"reply": coach.get("reply", ""), "tool_calls": coach.get("tool_calls") or []}
    misses = [f"did not call {t}" for t in (sc.get("tools") or {}).get("must_call", []) if t not in called]
    try:
        j = parse_json(claude(JUDGE_ASK.format(fixture=fixture, message=sc["message"], tools=json.dumps(called),
                                               reply=out["reply"], must=sc.get("must", []),
                                               must_not=sc.get("must_not", [])), judge))
    except Exception as e:
        return out | {"pass": False, "score": 0, "misses": misses + [f"judge failed: {e}"]}
    misses += j.get("misses", [])
    return out | {"pass": bool(j.get("pass")) and not any(m.startswith("did not call") for m in misses),
                  "score": j.get("score", 0), "misses": misses}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="haiku")
    ap.add_argument("--judge", default="sonnet")
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    scenarios = yaml.safe_load((HERE / "scenarios.yaml").read_text())
    if a.only:
        keep = set(a.only.split(","))
        scenarios = [s for s in scenarios if s["id"] in keep]
    system = build() + GUARD
    fixture = (HERE / "fixture_runner.json").read_text()
    with ThreadPoolExecutor(a.workers) as ex:
        results = list(ex.map(lambda s: run_one(s, system, fixture, a.model, a.judge), scenarios))
    for r in results:
        print(f"{'PASS' if r['pass'] else 'FAIL'} {r['score']:>2} {r['id']}: {r.get('reply', '')[:160]!r}")
        for m in r["misses"]:
            print(f"      - {m}")
    n = sum(r["pass"] for r in results)
    print(f"\n{n}/{len(results)} passed, mean score {sum(r['score'] for r in results) / max(len(results), 1):.1f} "
          f"(coach={a.model}, judge={a.judge})")
    if a.out:
        Path(a.out).write_text(json.dumps(results, indent=1))
    return 0 if n == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
