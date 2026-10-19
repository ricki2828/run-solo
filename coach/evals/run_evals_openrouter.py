#!/usr/bin/env python3
"""Score the coach through OpenRouter chat completions, the production engine path.

Same scenarios, same judge prompt and tool checks as run_evals.py, but:
- the coach call is a real tool-calling loop: tools.json is passed as `tools`, read tools are answered from the
  fixture, write tools from the scenario's `tool_results` (default ok:true), and the reply is plain text;
- only the compiled skill is sent as the system prompt, so no host CLAUDE.md leaks in (the claude -p caveat);
- every request carries provider {zdr: true, data_collection: "deny"};
- a per-run spend cap stops the run before it overspends, and borderline scores are re-run once (n=2).

Key: env OPENROUTER_API_KEY only. It is never read from a file, printed or written to results.

Usage: run_evals_openrouter.py [--model anthropic/claude-sonnet-5.5] [--judge anthropic/claude-opus-5.5]
       [--only id,id] [--out results.json] [--max-spend 3.00] [--workers 3]
Exit 0 only if every scenario passes. Results include the prompt_hash of the compiled skill (eng-review B12).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "scripts"))
from build_prompt import build  # noqa: E402
from run_evals import (JUDGE_ASK, fake_results, parse_json, scenario_fixture,  # noqa: E402
                       tool_failed, tool_misses)

URL = "https://openrouter.ai/api/v1/chat/completions"
PROVIDER = {"zdr": True, "data_collection": "deny"}
DEFAULT_COACH = "anthropic/claude-sonnet-5.5"
DEFAULT_JUDGE = "anthropic/claude-opus-5.5"   # pin the judge; change it deliberately, results are not comparable across judges
MAX_TOOL_TURNS = 6
READ_TOOLS = {"get_runner", "get_recent_runs", "get_stats", "get_plan", "get_checkins", "get_run"}
# Fallback price estimate (USD per 1M tokens) when the response carries no cost. Deliberately high: the cap
# should trip early rather than late. Replace with real numbers once a run has reported usage.cost.
FALLBACK_PRICE = {"in": 15.0, "out": 75.0}
BORDERLINE = range(5, 8)   # judge scores 5-7 get one re-run


class SpendCap(Exception):
    pass


class Spend:
    """Thread-safe running total. check() is called before every request."""

    def __init__(self, cap: float):
        self.cap, self.total, self.lock = cap, 0.0, threading.Lock()

    def check(self) -> None:
        with self.lock:
            if self.total >= self.cap:
                raise SpendCap(f"spend cap ${self.cap:.2f} reached (${self.total:.2f} spent)")

    def add(self, usd: float) -> None:
        with self.lock:
            self.total += usd


def tools_for_api() -> list[dict]:
    """tools.json (Anthropic-style input_schema) as OpenAI-style function tools, passed to the model as real tools."""
    spec = json.loads((HERE.parent / "tools.json").read_text())["tools"]
    return [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                              "parameters": t["input_schema"]}} for t in spec]


def api_key() -> str:
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        raise SystemExit("OPENROUTER_API_KEY is not set in the environment (the only place this script reads it).")
    return key


def chat(body: dict, spend: Spend, timeout: int = 120) -> dict:
    """One chat-completions call with ZDR + no data collection. Retries 429/5xx; never echoes the key."""
    spend.check()
    body = body | {"provider": PROVIDER, "usage": {"include": True}}
    data = json.dumps(body).encode()
    for attempt in range(4):
        req = urllib.request.Request(URL, data=data, headers={
            "Authorization": f"Bearer {api_key()}", "Content-Type": "application/json",
            "X-Title": "run-supreme-coach-evals"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                out = json.load(r)
            break
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise RuntimeError(f"openrouter HTTP {e.code}: {e.read()[:200].decode(errors='replace')}") from None
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise RuntimeError(f"openrouter network error: {type(e).__name__}") from None
    u = out.get("usage") or {}
    cost = u.get("cost")
    if cost is None:   # no reported cost: estimate from tokens, pessimistically
        cost = (u.get("prompt_tokens", 0) * FALLBACK_PRICE["in"] + u.get("completion_tokens", 0) * FALLBACK_PRICE["out"]) / 1e6
    spend.add(float(cost))
    if not out.get("choices"):
        raise RuntimeError(f"openrouter returned no choices: {json.dumps(out.get('error'))[:200]}")
    return out


def serve_read_tool(name: str, args: dict, fix: dict) -> object:
    if name == "get_run":
        run = next((r for r in fix.get("get_recent_runs", []) if r.get("run_id") == args.get("run_id")), None)
        return run or {"error": "no such run"}
    return fix.get(name, {"error": f"{name} unavailable"})


def coach_turn(sc: dict, system: list[dict], fix: dict, model: str, spend: Spend, tools: list[dict]) -> dict:
    """Run the tool loop for one scenario. Returns {reply, tool_calls (write only), results}."""
    messages = [{"role": "system", "content": system},
                {"role": "user", "content": f"(today is {fix.get('today', 'unknown')})\n{sc['message']}"}]
    write_calls: list[dict] = []
    results: list[dict] = []
    for _ in range(MAX_TOOL_TURNS):
        resp = chat({"model": model, "messages": messages, "tools": tools, "max_tokens": 700, "temperature": 0.3}, spend)
        msg = resp["choices"][0]["message"]
        calls = msg.get("tool_calls") or []
        if not calls:
            return {"reply": (msg.get("content") or "").strip(), "tool_calls": write_calls, "results": results}
        messages.append({"role": "assistant", "content": msg.get("content") or "", "tool_calls": calls})
        for c in calls:
            name = c["function"]["name"]
            try:
                args = json.loads(c["function"].get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            if name in READ_TOOLS:
                result = serve_read_tool(name, args, fix)
            else:
                call = {"name": name, "input": args}
                write_calls.append(call)
                result = fake_results(sc, [call])[0]["result"]
                results.append({"name": name, "result": result})
            messages.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(result)})
    raise RuntimeError(f"no final reply after {MAX_TOOL_TURNS} tool turns")


def judge_call(sc: dict, fixture: str, out: dict, judge: str, spend: Spend) -> dict:
    called = [c["name"] for c in out["tool_calls"]]
    prompt = JUDGE_ASK.format(fixture=fixture, message=sc["message"], tools=json.dumps(called),
                              results=json.dumps(out["results"]) if out["results"] else "none (write calls are assumed to have succeeded)", reply=out["reply"],
                              must=sc.get("must", []), must_not=sc.get("must_not", []))
    resp = chat({"model": judge, "messages": [{"role": "user", "content": prompt}], "max_tokens": 600, "temperature": 0}, spend)
    return parse_json(resp["choices"][0]["message"].get("content") or "")


def run_once(sc: dict, system: list[dict], fixture: str, model: str, judge: str, spend: Spend, tools: list[dict]) -> dict:
    fixture = scenario_fixture(sc, fixture)
    fix = json.loads(fixture)
    row: dict = {"id": sc["id"], "message": sc["message"]}
    try:
        out = coach_turn(sc, system, fix, model, spend, tools)
    except SpendCap:
        raise
    except Exception as e:   # a broken coach answer is a fail, never a skip
        return row | {"pass": False, "score": 0, "misses": [f"coach output unusable: {e}"]}
    row |= {"reply": out["reply"], "tool_calls": out["tool_calls"]}
    misses = tool_misses(sc, out["tool_calls"])
    if not out["reply"]:
        misses.append("empty reply")
    try:
        j = judge_call(sc, fixture, out, judge, spend)
    except SpendCap:
        raise
    except Exception as e:
        return row | {"pass": False, "score": 0, "misses": misses + [f"judge failed: {e}"]}
    misses += j.get("misses", [])
    ok = bool(j.get("pass")) and not tool_failed(misses) and bool(out["reply"])
    return row | {"pass": ok, "score": j.get("score", 0), "misses": misses}


def run_scenario(sc: dict, system: list[dict], fixture: str, model: str, judge: str, spend: Spend, tools: list[dict]) -> dict:
    """W12: one run; if the score is borderline, run once more. Both runs must pass to count as a pass.
    A disagreement is reported as flaky and counted as a fail (safety scenarios must be reliable)."""
    first = run_once(sc, system, fixture, model, judge, spend, tools)
    if first["score"] not in BORDERLINE:
        return first | {"runs": 1}
    second = run_once(sc, system, fixture, model, judge, spend, tools)
    both = first["pass"] and second["pass"]
    worse = min((first, second), key=lambda r: (r["pass"], r["score"]))
    return worse | {"pass": both, "runs": 2, "scores": [first["score"], second["score"]],
                    "flaky": first["pass"] != second["pass"],
                    "score": min(first["score"], second["score"])}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=DEFAULT_COACH)
    ap.add_argument("--judge", default=DEFAULT_JUDGE)
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--max-spend", type=float, default=3.0, help="USD cap for the whole run (coach + judge + re-runs)")
    a = ap.parse_args()
    api_key()   # fail fast, before building anything
    scenarios = yaml.safe_load((HERE / "scenarios.yaml").read_text())
    if a.only:
        keep = set(a.only.split(","))
        scenarios = [s for s in scenarios if s["id"] in keep]
    prompt = build()
    prompt_hash = hashlib.sha256(prompt.encode()).hexdigest()[:16]
    system = [{"type": "text", "text": prompt, "cache_control": {"type": "ephemeral"}}]   # stable prefix, cacheable
    fixture = (HERE / "fixture_runner.json").read_text()
    tools = tools_for_api()
    spend = Spend(a.max_spend)

    def one(sc: dict) -> dict:
        try:
            return run_scenario(sc, system, fixture, a.model, a.judge, spend, tools)
        except SpendCap as e:   # not run is not passed
            return {"id": sc["id"], "message": sc["message"], "pass": False, "score": 0, "skipped": True,
                    "misses": [f"not run: {e}"]}

    with ThreadPoolExecutor(a.workers) as ex:
        results = list(ex.map(one, scenarios))
    for r in results:
        tag = "SKIP" if r.get("skipped") else ("PASS" if r["pass"] else "FAIL")
        print(f"{tag} {r['score']:>2}{' flaky' if r.get('flaky') else ''} {r['id']}: {r.get('reply', '')[:160]!r}")
        for m in r["misses"]:
            print(f"      - {m}")
    n = sum(r["pass"] for r in results)
    skipped = sum(bool(r.get("skipped")) for r in results)
    print(f"\n{n}/{len(results)} passed ({skipped} not run), mean score "
          f"{sum(r['score'] for r in results) / max(len(results), 1):.1f} "
          f"(coach={a.model}, judge={a.judge}, prompt_hash={prompt_hash}, spend=${spend.total:.2f}/${a.max_spend:.2f})")
    if a.out:
        Path(a.out).write_text(json.dumps({"prompt_hash": prompt_hash, "coach": a.model, "judge": a.judge,
                                           "spend_usd": round(spend.total, 4), "results": results}, indent=1))
    return 0 if n == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
