"""Deep links back into the app: runsupreme://run/<id> and runsupreme://week/<iso-week>.

Telegram and WhatsApp URL buttons only accept http(s), so a channel button carries the https twin
(`<deeplink_base>/run/<id>`), which the web host redirects or opens as an Android App Link.
"""
from __future__ import annotations

import re
from urllib.parse import quote, unquote

SCHEME = "runsupreme"
RUN_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")  # same alphabet as RunIn.run_id
WEEK_RE = re.compile(r"^\d{4}-W(0[1-9]|[1-4]\d|5[0-3])$")
_LINK_RE = re.compile(rf"^{SCHEME}://(run|week)/([^/?#]+)$")


def _run_ok(run_id: str) -> bool:
    """The RunIn.run_id alphabet, minus ids made only of dots: `..` would climb out of /run/ in the https twin."""
    return bool(RUN_ID_RE.match(run_id or "")) and run_id.strip(".") != ""


def run_link(run_id: str) -> str | None:
    return f"{SCHEME}://run/{quote(run_id, safe='')}" if _run_ok(run_id) else None


def week_link(iso_week: str) -> str | None:
    return f"{SCHEME}://week/{iso_week}" if WEEK_RE.match(iso_week or "") else None


def parse(uri: str) -> tuple[str, str] | None:
    """('run', id) | ('week', iso-week) for a link this module could have produced, else None."""
    m = _LINK_RE.match(uri or "")
    if not m:
        return None
    kind, val = m.group(1), unquote(m.group(2))
    ok = _run_ok(val) if kind == "run" else WEEK_RE.match(val)
    return (kind, val) if ok else None


def web_twin(base: str | None, uri: str | None) -> str | None:
    """The https URL a chat button can carry for `uri`, or None when no https base is configured."""
    if not base or not uri or not base.startswith("https://") or parse(uri) is None:
        return None
    return f"{base.rstrip('/')}/{uri[len(SCHEME) + 3:]}"
