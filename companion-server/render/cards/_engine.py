"""One shared headless Chromium, rendered serially. The host is memory-tight, so never one browser per card."""
from __future__ import annotations

import atexit
import os
import shutil
import threading
from typing import Any

_lock = threading.Lock()
_pw: Any = None
_browser: Any = None


class RendererUnavailable(RuntimeError):
    pass


def _chromium_path() -> str | None:
    env = os.environ.get("RS_CHROMIUM_PATH")
    if env == "bundled":  # CI: use the Chromium that `playwright install` fetched
        return None
    if env:
        return env
    for name in ("chromium-browser", "chromium", "google-chrome", "google-chrome-stable"):
        found = shutil.which(name)
        if found:
            return found
    return None  # fall back to Playwright's own download


def _ensure_browser() -> Any:
    global _pw, _browser
    if _browser is not None and _browser.is_connected():
        return _browser
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as e:  # pragma: no cover
        raise RendererUnavailable("playwright is not installed") from e
    if _pw is None:
        _pw = sync_playwright().start()
    args = ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--font-render-hinting=none"]
    path = _chromium_path()
    try:
        _browser = _pw.chromium.launch(executable_path=path, args=args) if path else _pw.chromium.launch(args=args)
    except Exception as e:
        raise RendererUnavailable(f"chromium would not start: {e}") from e
    return _browser


def close() -> None:
    global _pw, _browser
    with _lock:
        try:
            if _browser is not None:
                _browser.close()
            if _pw is not None:
                _pw.stop()
        finally:
            _browser = _pw = None


atexit.register(close)


def render_html(html: str, width: int, height: int) -> bytes:
    """Render a full HTML document to PNG bytes at exactly width x height."""
    with _lock:
        browser = _ensure_browser()
        page = browser.new_page(viewport={"width": width, "height": height}, device_scale_factor=1)
        try:
            # Defence in depth (sec-review-225 F2): the templates are self-contained (fonts and marks are inlined),
            # so nothing may be fetched. A facts string that smuggled in a tag still cannot reach a network.
            page.route("**/*", lambda route: route.abort())
            page.set_content(html, wait_until="load")
            page.evaluate("document.fonts.ready.then(() => true)")
            return page.screenshot(type="png", clip={"x": 0, "y": 0, "width": width, "height": height})
        finally:
            page.close()
