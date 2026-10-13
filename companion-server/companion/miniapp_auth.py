"""Telegram Mini App initData validation (eng-review A1).

Algorithm per core.telegram.org/bots/webapps ("Validating data received via the Mini App"):
  secret = HMAC_SHA256(key="WebAppData", msg=bot_token)
  hash   = hex(HMAC_SHA256(key=secret, msg=data_check_string))
where the data-check-string is every received field except `hash` (`signature` stays in), as `key=value`,
sorted by key and joined with "\\n". The hash is compared in constant time, then auth_date must be recent and not
in the future. Nothing here logs or echoes initData: an error carries only a short code.
"""
from __future__ import annotations

import hashlib
import hmac
import json
from datetime import datetime
from urllib.parse import parse_qsl

MAX_INIT_DATA = 4096
MAX_AGE_S = 3600   # a Mini App session older than an hour must be reopened from Telegram
MAX_SKEW_S = 60    # clock drift allowed for an auth_date slightly ahead of us


class InitDataError(Exception):
    """`code` is one of: missing, malformed, bad_hash, stale, future, no_user."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _fields(raw: str) -> dict[str, str]:
    if not raw or len(raw) > MAX_INIT_DATA:
        raise InitDataError("missing" if not raw else "malformed")
    try:
        pairs = parse_qsl(raw, keep_blank_values=True, strict_parsing=True, max_num_fields=32)
    except ValueError:
        raise InitDataError("malformed") from None
    out: dict[str, str] = {}
    for k, v in pairs:
        if k in out:  # a duplicated key could make two parsers disagree about what was signed
            raise InitDataError("malformed")
        out[k] = v
    return out


def verify_init_data(raw: str, bot_token: str, now: datetime, *, max_age_s: int = MAX_AGE_S,
                     skew_s: int = MAX_SKEW_S) -> dict:
    """The verified `user` object (a dict with an int `id`) plus `auth_date`, or InitDataError."""
    f = _fields(raw)
    got = f.pop("hash", "")
    if not got or not bot_token:
        raise InitDataError("malformed")
    secret = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
    check = "\n".join(f"{k}={f[k]}" for k in sorted(f))
    want = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(want.encode(), got.encode()):
        raise InitDataError("bad_hash")
    try:
        auth_date = int(f["auth_date"])
    except (KeyError, ValueError):
        raise InitDataError("malformed") from None
    age = now.timestamp() - auth_date
    if age > max_age_s:
        raise InitDataError("stale")
    if age < -skew_s:
        raise InitDataError("future")
    try:
        user = json.loads(f.get("user", ""))
        uid = user["id"]
    except (ValueError, KeyError, TypeError):
        raise InitDataError("no_user") from None
    if not isinstance(uid, int) or isinstance(uid, bool) or uid <= 0:
        raise InitDataError("no_user")
    return {"user_id": uid, "auth_date": auth_date}
