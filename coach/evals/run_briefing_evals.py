#!/usr/bin/env python3
"""Score the coach's session BRIEFING (C2b) through OpenRouter, the production engine path.

Same request as the server's briefing job: the compiled skill + host rules as the cached system prompt, the production
instruction (companion.coach.briefing.instruction) as the user turn, ZDR provider block, reasoning low and excluded, no
temperature, usage included. The reply is the TEMPLATE; it is checked by the server's own validator
(companion.coach.briefing.check_template) plus the scenario rules in briefing_scenarios.json:
  - the kind is named in the first sentence
  - the pacing instruction matches the kind (an easy run never says push)
  - warm-up rules survive (Norwegian 4x4: "warm up as long as you like")
  - no medical advice, no talk of a niggle
  - an active injury / urgent / wellbeing flag means no briefing at all (offline check of the server's blocking set)

NOT run by CI and not run by the agent that wrote it: it needs the OpenRouter key. Ricki runs it:
    OPENROUTER_API_KEY=... python3 coach/evals/run_briefing_evals.py [--runs 3] [--only id,id] [--out results.json]
The key is read from the environment only; it is never printed or written. Exit 0 only if every scenario passes every run.
Run it before widening the allowlist or after any change to the skill, the briefing instruction or the validator.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "companion-server"))
from companion.coach import briefing as bf  # noqa: E402
from companion.coach import prompt as coach_prompt  # noqa: E402


def load_scenarios() -> list[dict]:
    return json.loads((HERE / "briefing_scenarios.json").read_text())["scenarios"]


def first_sentence(text: str) -> str:
    m = re.split(r"(?<=[.!?])\s", text.strip(), maxsplit=1)
    return m[0]


def check(sc: dict, text: str) -> list[str]:
    misses = []
    bad = bf.check_template(text, set(sc["slots"]))
    if bad:
        misses.append(f"validator rejected it: {bad}")
    low = text.lower()
    fs = first_sentence(text).lower()
    if not any(w.lower() in fs for w in sc["first_any"]):
        misses.append(f"first sentence does not name the kind (wanted one of {sc['first_any']}): {first_sentence(text)!r}")
    if sc.get("pacing_any") and not any(w.lower() in low for w in sc["pacing_any"]):
        misses.append(f"no pacing instruction matching the kind (wanted one of {sc['pacing_any']})")
    for w in sc.get("must_all", []):
        if w.lower() not in low:
            misses.append(f"missing required phrase {w!r}")
    for rx in sc.get("never", []):
        if re.search(rx, low):
            misses.append(f"matched a forbidden pattern {rx!r}")
    return misses


def generate(sc: dict, system: list[dict], tools: list[dict], model: str, spend, chat) -> str:
    user = bf.instruction(sc["kind"], bool(sc["named"]), sc["slots"], sc["facts"])
    body = {"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "tools": [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                                        "parameters": t["input_schema"]}} for t in tools],
            "tool_choice": "none", "max_tokens": 2000, "reasoning": {"effort": "low", "exclude": True}}
    resp = chat(body, spend)
    choice = resp["choices"][0]
    if choice.get("finish_reason") == "length":
        raise RuntimeError("hit max_tokens (finish_reason=length)")
    content = choice["message"].get("content") or ""
    if isinstance(content, list):
        content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return bf.tidy(content)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="anthropic/claude-sonnet-5.5")
    ap.add_argument("--only", default="")
    ap.add_argument("--runs", type=int, default=2, help="generations per scenario; every one must pass")
    ap.add_argument("--max-spend", type=float, default=1.5)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    scenarios = load_scenarios()
    if a.only:
        keep = set(a.only.split(","))
        scenarios = [s for s in scenarios if s["id"] in keep]
    results = []
    for sc in (s for s in scenarios if s.get("expect") == "none"):   # offline: the server never writes one for these flags
        ok = sc["flag"] in bf.BLOCKING_FLAGS
        results.append({"id": sc["id"], "pass": ok, "misses": [] if ok else [f"{sc['flag']} is not in the server's blocking flags"],
                        "replies": []})
    live = [s for s in scenarios if s.get("expect") != "none"]
    if live:
        from run_evals_openrouter import Spend, SpendCap, api_key, chat   # lazy: it needs pyyaml; the offline checks do not
        api_key()   # fail fast
        prompt = coach_prompt.load(str(ROOT / "coach"))
        system = [{"type": "text", "text": prompt.text, "cache_control": {"type": "ephemeral"}}]
        spend = Spend(a.max_spend)
        for sc in live:
            row = {"id": sc["id"], "pass": True, "misses": [], "replies": []}
            try:
                for _ in range(a.runs):
                    text = generate(sc, system, prompt.tools, a.model, spend, chat)
                    row["replies"].append(text)
                    miss = check(sc, text)
                    row["misses"] += miss
                    row["pass"] = row["pass"] and not miss
            except SpendCap as e:
                row |= {"pass": False, "misses": row["misses"] + [f"not run: {e}"]}
            except Exception as e:   # a broken call is a fail, never a skip
                row |= {"pass": False, "misses": row["misses"] + [f"call failed: {e}"]}
            results.append(row)
        total = f"spend=${spend.total:.2f}/${a.max_spend:.2f} prompt_hash={prompt.prompt_hash}"
    else:
        total = "offline only"
    for r in results:
        print(f"{'PASS' if r['pass'] else 'FAIL'} {r['id']}")
        for t in r["replies"]:
            print(f"      > {t}")
        for m in r["misses"]:
            print(f"      - {m}")
    n = sum(r["pass"] for r in results)
    print(f"\n{n}/{len(results)} scenarios passed ({a.runs} runs each; coach={a.model}; {total})")
    if a.out:
        Path(a.out).write_text(json.dumps({"coach": a.model, "briefing_module_hash": hashlib.sha256(
            Path(bf.__file__).read_bytes()).hexdigest()[:16], "results": results}, indent=1))
    return 0 if n == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
