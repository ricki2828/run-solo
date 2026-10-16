"""`ops send`: the tester programme's only way to message a tester, and only with text Ricki has approved.

    python -m companion.cli ops send --tester T3 --template N1|N2|N3|INVITE [--link https://...] [--dry-run]
    python -m companion.cli ops sends [T3]
    python -m companion.cli ops templates

The text of a template lives in templates-draft.md (the `> ` lines under `## N1` and so on). Ricki approves it by putting
the text's SHA-256 in templates-approved.json. Edit one character and the hash no longer matches, so nothing goes out.
This module never calls Telegram: it checks the rules and queues one outbox item. The tick loop sends it, and so the
usual rails apply there (paused or STOPped runners, consent, quiet hours, the kill switch, the weekly cap).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from datetime import timedelta
from pathlib import Path
from typing import Callable

from . import db
from .config import Settings
from .rails import tag
from .timeutil import iso, now_utc

TEMPLATE_IDS = ("N1", "N2", "N3", "INVITE")
TESTER = re.compile(r"^[Tt](\d{1,6})$")
SPACING_DAYS = 3          # at most one ops message per tester in any 3 days (plan §3), on top of the coach's own caps
DAILY_CAP = 10            # across all testers, per UTC day
PLACEHOLDER = re.compile(r"\{[a-z_]+\}")
USAGE = ("usage: ops send --tester T<n> --template N1|N2|N3|INVITE [--link https://...] [--dry-run] | ops sends [T<n>] | "
         "ops templates")


def state_dir() -> Path:
    return Path(os.environ.get("COMPANION_OPS_STATE_DIR") or Path.home() / "ai/state/run-supreme-testers")


def text_hash(text: str) -> str:
    return hashlib.sha256(text.strip().encode("utf-8")).hexdigest()


def load_drafts(path: Path | None = None) -> dict[str, str]:
    """{template id: text}. The text is the `> ` lines under a `## <ID>` heading; everything else in the file is notes."""
    path = path or state_dir() / "templates-draft.md"
    out: dict[str, list[str]] = {}
    cur = None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    for ln in lines:
        if ln.startswith("## "):
            cur = ln[3:].strip().upper()
            out.setdefault(cur, [])
        elif cur is not None and ln.startswith(">"):
            out[cur].append(ln[1:].lstrip(" ") if ln[1:2] == " " else ln[1:])
    return {k: "\n".join(v).strip() for k, v in out.items() if k in TEMPLATE_IDS and "".join(v).strip()}


def approved(path: Path | None = None) -> set[tuple[str, str]]:
    """{(template id, sha256)} from templates-approved.json: {"approved": [{"id": "N1", "sha256": "..."}]}. A missing,
    unreadable or malformed file approves nothing."""
    path = path or state_dir() / "templates-approved.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return {(str(a["id"]).upper(), str(a["sha256"]).lower()) for a in data.get("approved", [])}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return set()


def is_approved(template: str, text: str) -> bool:
    return (template, text_hash(text)) in approved()


def render(template: str, text: str, link: str | None) -> tuple[str | None, str | None]:
    """-> (message, problem). {booking_link} is the only placeholder, and only the INVITE may carry it."""
    if "{booking_link}" in text:
        if not link:
            return None, "this template has a {booking_link} placeholder: pass --link https://..."
        if not re.fullmatch(r"https://[^\s{}]+", link):
            return None, "--link must be one https:// address with no spaces"
        text = text.replace("{booking_link}", link)
    elif link:
        return None, "--link given but this template has no {booking_link}"
    if PLACEHOLDER.search(text):
        return None, "the text still has a {placeholder}"
    return text, None


def _find(c, who: str):
    m = TESTER.match(who or "")
    if not m:
        return None
    return c.execute("SELECT * FROM users WHERE tester_no=?", (int(m.group(1)),)).fetchone()


def check(s: Settings, c, user, template: str, now) -> str | None:
    """The reason a send is refused, or None. Pure reads."""
    if user["paused"] or user["ops_paused"]:
        return f"{tag(user['tester_no'])} is paused or has stopped: nothing is sent"
    if user["channel"] != "telegram":
        return "ops messages go through Telegram only"
    if user["checkin_consent"] is None or user["checkin_consent"] < s.checkin_consent_required:
        return f"{tag(user['tester_no'])} has not agreed to consent v{s.checkin_consent_required}"
    if c.execute("SELECT 1 FROM ops_sends WHERE user_id=? AND template=?", (user["id"], template)).fetchone():
        return f"{template} was already sent to {tag(user['tester_no'])}: each template goes once per tester"
    if c.execute("SELECT 1 FROM ops_sends WHERE user_id=? AND ts>?", (user["id"], iso(now - timedelta(days=SPACING_DAYS)))).fetchone():
        return f"{tag(user['tester_no'])} had an ops message in the last {SPACING_DAYS} days"
    today = now.strftime("%Y-%m-%d")
    if c.execute("SELECT COUNT(*) FROM ops_sends WHERE ts>=?", (today,)).fetchone()[0] >= DAILY_CAP:
        return f"daily cap of {DAILY_CAP} ops messages reached"
    return None


def send(s: Settings, who: str, template: str, link: str | None = None, dry_run: bool = False,
         out: Callable[[str], None] = print, now=None) -> int:
    now = now or now_utc()
    template = (template or "").upper()
    if template not in TEMPLATE_IDS or not TESTER.match(who or ""):
        out(USAGE)
        return 2
    text = load_drafts().get(template)
    if text is None:
        out(f"no text for {template} in {state_dir() / 'templates-draft.md'}")
        return 1
    message, problem = render(template, text, link)
    if problem:
        out(problem)
        return 1
    h = text_hash(text)
    ok = (template, h) in approved()
    with db.ro(s.db_path) as c:
        user = _find(c, who)
        if not user:
            out(f"no runner {who.upper()}")
            return 1
        refusal = check(s, c, user, template, now)
    if dry_run:
        out(f"DRY RUN: nothing is sent or recorded. To {tag(user['tester_no'])}, template {template}, sha256 {h}")
        out(message)
        out("approved: yes" if ok else "approved: NO (a real send would refuse; put the sha256 in templates-approved.json)")
        if refusal:
            out(f"a real send would be refused: {refusal}")
        return 0 if ok and not refusal else 1
    if not ok:
        out(f"refused: {template} is not approved, or its text changed after approval (sha256 {h}). Nothing queued.")
        return 1
    if refusal:
        out(f"refused: {refusal}")
        return 1
    card_id = "ops_" + secrets.token_hex(8)
    with db.tx(s.db_path) as c:
        # re-check inside the write transaction: two operators or a cron overlap cannot both pass
        user = _find(c, who)
        refusal = check(s, c, user, template, now)
        if refusal:
            out(f"refused: {refusal}")
            return 1
        c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                  "VALUES (?,?,?,?,?,?,?,?,?)", (card_id, user["id"], None, "ops", "", message, "[]", "ops", iso(now)))
        c.execute("INSERT INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                  (user["id"], "ops", iso(now), f"ops:{user['id']}:{template}", card_id))
        c.execute("INSERT INTO ops_sends (user_id, template, text_hash, ts, result, card_id) VALUES (?,?,?,?,?,?)",
                  (user["id"], template, h, iso(now), "queued", card_id))
    out(f"queued {template} for {tag(user['tester_no'])}. The coach sends it on its next tick if the runner can be messaged.")
    return 0


def sends(s: Settings, who: str | None = None) -> list[str]:
    with db.ro(s.db_path) as c:
        rows = c.execute("SELECT u.tester_no, o.template, o.text_hash, o.ts, o.result FROM ops_sends o "
                         "JOIN users u ON u.id = o.user_id ORDER BY o.ts DESC, o.id DESC").fetchall()
    keep = [r for r in rows if not who or tag(r["tester_no"]) == who.upper()]
    return [f"{r['ts']} {tag(r['tester_no'])} {r['template']} sha256={r['text_hash'][:12]} {r['result']}" for r in keep] or ["no ops sends"]


def templates() -> list[str]:
    drafts, ok = load_drafts(), approved()
    return [f"{t} sha256={text_hash(drafts[t])} " + ("APPROVED" if (t, text_hash(drafts[t])) in ok else "not approved")
            if t in drafts else f"{t} no text" for t in TEMPLATE_IDS]


def main(s: Settings, argv: list[str], out: Callable[[str], None] = print) -> int:
    """argv starts at the sub-command: send ... | sends [T<n>] | templates."""
    cmd = argv[0]
    if cmd == "sends":
        for ln in sends(s, argv[1] if len(argv) > 1 else None):
            out(ln)
        return 0
    if cmd == "templates":
        for ln in templates():
            out(ln)
        return 0
    opts: dict[str, str] = {}
    dry = False
    it = iter(argv[1:])
    for a in it:
        if a == "--dry-run":
            dry = True
        elif a in ("--tester", "--template", "--link"):
            opts[a[2:]] = next(it, "")
        else:
            out(USAGE)
            return 2
    return send(s, opts.get("tester", ""), opts.get("template", ""), opts.get("link"), dry, out)
