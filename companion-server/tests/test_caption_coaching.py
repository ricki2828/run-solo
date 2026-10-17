"""A run card's photo caption keeps the coaching sentence, within the 1024 limit."""
from companion.channels import CAPTION_MAX, OutCard, caption_text, utf16_len

NUMS = "4.7 km in 28 min, 3 s/km faster than last time at 5:27/km."
COACH = "Steady work on uneven ground."
NEXT = "Next: easy 5 km tomorrow"


def cap(body, headline="Tempo on the trail"):
    return caption_text(OutCard("c", headline, body, [], None, (), short_caption=True))


def test_judgement_sentence_is_kept_with_next_line():
    out = cap(f"{NUMS} {COACH}\n{NEXT}\n\nRun number 10 logged here.")
    assert out == f"Tempo on the trail\n{NUMS} {COACH} {NEXT}\nRun number 10 logged here."


def test_restated_numbers_still_dropped():
    out = cap(f"4.7 km in 28 min at 5:27/km. {COACH}\n{NEXT}")
    assert "4.7 km" not in out and COACH in out and NEXT in out


def test_over_limit_drops_comparison_then_later_paragraph_never_judgement():
    out = cap(f"{NUMS} {COACH}\n{NEXT}\n\n" + "Quoted note. " * 90)
    assert utf16_len(out) <= CAPTION_MAX and COACH in out and NEXT in out
    out2 = cap(f"{'Faster than last time. ' * 50}{COACH}\n{NEXT}")
    assert utf16_len(out2) <= CAPTION_MAX and COACH in out2 and NEXT in out2


def test_noted_line_without_label_rides_the_caption():
    out = cap(f"{NUMS} {COACH}\nNoted. {NEXT}")
    assert "Noted. Next: easy 5 km tomorrow" in out and COACH in out
