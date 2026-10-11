"""The four newer card kinds through a real render worker and a real Chromium (CI installs both; this fails, never skips,
when they are missing). The fact shapes are the ones the companion stores and sends (tests/test_more_cards.py)."""
import io

import pytest
from PIL import Image

from companion.render_client import RenderClient
from render import protocol as P

from test_more_cards import GOOD


@pytest.mark.parametrize("kind,size", [("suggestion", (1080, 1350)), ("milestone", (1080, 1350)),
                                       ("race_countdown", (1080, 1350)), ("monthly", (1080, 1920))])
def test_new_card_round_trip_through_the_socket(render_socket, kind, size):
    png = RenderClient(render_socket).card(kind, GOOD[kind])
    img = Image.open(io.BytesIO(png))
    assert png[:8] == b"\x89PNG\r\n\x1a\n" and img.size == size
    assert len(png) <= P.PHOTO_MAX_BYTES
