"""Tell Ricki: free text a runner typed to the operator after tapping "Tell Ricki" (or sending /feedback).

The text is kept for FEEDBACK_RETENTION_DAYS and read by one person, through `ops feedback`. It is NEVER put in a prompt,
a render request, a log line or a card, and no model sees it: the reply is one fixed line. It lives in its own table
(`feedback`), is left out of the nightly backup (backup.PRIVATE_TABLES) and goes with the runner on DELETE.
"""
from __future__ import annotations

FEEDBACK_MODE_MIN = 30         # "Tell Ricki" waits this long for the text
FEEDBACK_MAX_CHARS = 1000
FEEDBACK_RETENTION_DAYS = 30
FEEDBACK_ACTION = "fb:tell"
FEEDBACK_WORD = "FEEDBACK"     # /feedback or the bare word


def clean(text: str) -> str:
    """One line, printable characters only. The caller checks the length."""
    printable = "".join(ch if ch.isprintable() or ch.isspace() else " " for ch in text)
    return " ".join(printable.split())
