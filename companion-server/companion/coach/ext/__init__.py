"""The coach's extension tools: drop a module in `companion/coach/ext/` and its schemas in `coach/tools.d/` and the coach has a
new tool. Nothing else is edited (PR2 research and weather, PR3 triage and care, PR4 actions and memory all arrive this way).

Pairing. `coach/tools.d/<name>.json` is `{"tools": [{"name", "description", "input_schema", "module"?}]}`, the same form as
tools.json. A tool runs in `companion/coach/ext/<module>.py`; "module" defaults to the json file's name, so one json file
may name several modules (care.json -> triage, places). The skill stays the portable source of the schemas.

A module defines:
    def call(name: str, args: dict, ctx: ToolContext) -> dict      required. `args` already passed the schema check
                                                                    (types, enum, range, required, no extras). Return a
                                                                    plain dict. Raise ValueError("what to tell the model") for
                                                                    bad input; any other exception reaches the model only as
                                                                    "tool failed".
    RULES: str                                                      optional. A paragraph appended to the host rules in the
                                                                    system prompt (and so to the prompt hash).
    def context(ctx: ToolContext) -> str                            optional. A block added to the runner's turn (PR4 memory).

Results. The registry returns `{"ok": true, **result}` (or `{"ok": false, "error": ...}`) and the chat loop JSON-encodes it into
the tool message AND into the validator's sources. So a number, a link or a phone number the reply uses is allowed exactly when
it appears in a tool result (links and phones: character for character). Put every figure and URL the model may say in the
result, ready to say. Anything a tool gets from the runner's words or the web goes out as {"quoted_runner_text": ...}-style data.

A module that fails to import, or has no `call`, is skipped with a log line: the coach carries on without its tools.
"""
from __future__ import annotations

import importlib
import json
import logging
import os
import pkgutil
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable

from ..tools import check_args

log = logging.getLogger("companion")


@dataclass
class ToolContext:
    """Bound to one runner for one job."""
    svc: Any                      # the Service: svc.s settings, svc.http client, svc.s.db_path
    user_id: str
    now: datetime
    job_id: int | None = None
    # Send a one-line "on it" message that the final answer then replaces (edited in place). A no-op until a channel is bound.
    placeholder: Callable[[str], None] = field(default=lambda text: None)
    # Model spend a tool made itself (research): the chat loop folds it into the job's footer figures after each tool call.
    cost_usd: float = 0.0
    calls: int = 0

    @property
    def settings(self) -> Any:
        return self.svc.s

    @property
    def http(self) -> Any:
        return self.svc.http


class Registry:
    def __init__(self) -> None:
        self.tools: list[dict] = []                  # model-facing schemas: name, description, input_schema
        self._by_name: dict[str, tuple[Any, dict]] = {}
        self._modules: list[Any] = []

    def schemas(self) -> list[dict]:
        return list(self.tools)

    def has(self, name: str) -> bool:
        return name in self._by_name

    def rules(self) -> str:
        return "\n".join(str(r).strip() for m in self._modules if (r := getattr(m, "RULES", "")))

    def call(self, name: str, raw_args: Any, ctx: ToolContext) -> dict:
        """Never raises. Same contract as ReadTools.call."""
        if name not in self._by_name:
            return {"ok": False, "error": f"unknown tool: {name}"}
        mod, schema = self._by_name[name]
        if isinstance(raw_args, str):
            try:
                raw_args = json.loads(raw_args) if raw_args.strip() else {}
            except ValueError:
                return {"ok": False, "error": "arguments are not valid JSON"}
        try:
            args, err = check_args(schema, raw_args)
        except Exception:   # e.g. a string where a number was expected
            return {"ok": False, "error": "arguments do not match the schema"}
        if err:
            return {"ok": False, "error": err}
        try:
            out = mod.call(name, args, ctx)
        except ValueError as e:
            return {"ok": False, "error": str(e)[:200] or "bad input"}
        except Exception as e:
            log.warning("coach ext tool %s failed: %s", name, type(e).__name__)
            return {"ok": False, "error": f"tool failed: {type(e).__name__}"}
        if not isinstance(out, dict):
            return {"ok": False, "error": "tool failed: bad result"}
        return {"ok": True, **out}

    def context(self, ctx: ToolContext) -> str:
        parts = []
        for m in self._modules:
            fn = getattr(m, "context", None)
            if fn:
                try:
                    text = fn(ctx)
                except Exception as e:
                    log.warning("coach ext context %s failed: %s", m.__name__, type(e).__name__)
                    continue
                if text:
                    parts.append(str(text))
        return "\n".join(parts)


def load_registry(coach_dir: str, core_names: set[str] | frozenset[str] = frozenset()) -> Registry:
    """Discover the modules with pkgutil and pair them with `<coach_dir>/tools.d/*.json`. `core_names` are tools.json names an
    extension may not shadow."""
    reg = Registry()
    d = os.path.join(coach_dir, "tools.d")
    if not os.path.isdir(d):
        return reg
    available = {n for _, n, _ in pkgutil.iter_modules(__path__) if not n.startswith("_")}
    loaded: dict[str, Any] = {}
    for fname in sorted(os.listdir(d)):
        if not fname.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, fname), encoding="utf-8") as f:
                tools = json.load(f)["tools"]
        except (OSError, ValueError, KeyError, TypeError):
            log.error("coach tools.d/%s unreadable: skipped", fname)
            continue
        for t in tools if isinstance(tools, list) else []:
            try:
                name, desc, schema = t["name"], t["description"], t["input_schema"]
                module = t.get("module") or fname[:-5]
            except (KeyError, TypeError):
                log.error("coach tools.d/%s has a malformed tool: skipped", fname)
                continue
            if name in core_names or name in reg._by_name or module not in available:
                log.error("coach ext tool %s skipped (shadowed, duplicate or no module %s)", name, module)
                continue
            if module not in loaded:
                try:
                    mod = importlib.import_module(f"{__name__}.{module}")
                    if not callable(getattr(mod, "call", None)):
                        raise AttributeError("call")
                    loaded[module] = mod
                    reg._modules.append(mod)
                except Exception as e:
                    log.error("coach ext module %s skipped: %s", module, type(e).__name__)
                    loaded[module] = None
            if loaded[module] is None:
                continue
            reg._by_name[name] = (loaded[module], schema)
            reg.tools.append({"name": name, "description": desc, "input_schema": schema})
    return reg
