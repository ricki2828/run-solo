"""Log hygiene (eng-review B5): redact phone numbers, chat ids and tokens; keep HTTP client chatter quiet."""
from __future__ import annotations

import logging
import re

PATTERNS = [
    (re.compile(r"\d{6,}:[A-Za-z0-9_-]{20,}"), "[bot-token]"),   # Telegram bot token
    (re.compile(r"[A-Za-z0-9_-]{32,}"), "[secret]"),             # device tokens, nonces, keys
    (re.compile(r"\+?\d[\d\s-]{6,}\d"), "[number]"),             # phone numbers, chat ids, long ids
]


def redact(text: str) -> str:
    for pat, repl in PATTERNS:
        text = pat.sub(repl, text)
    return text


class RedactFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = redact(record.getMessage())
        record.args = None
        return True


def setup(level: int = logging.INFO) -> None:
    root = logging.getLogger()
    if not any(isinstance(h, logging.StreamHandler) for h in root.handlers):
        root.addHandler(logging.StreamHandler())
    root.setLevel(level)
    for h in root.handlers:  # on handlers, so records from every logger are covered
        if not any(isinstance(f, RedactFilter) for f in h.filters):
            h.addFilter(RedactFilter())
    # httpx logs full request URLs at INFO, and Telegram puts the bot token in the URL path.
    for name in ("httpx", "httpcore", "uvicorn.access"):
        logging.getLogger(name).setLevel(logging.WARNING)
