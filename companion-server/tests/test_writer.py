import httpx

from companion import db
from companion.facts import Fact, FactsResult, Suggestion
from companion.writer import (CardText, Writer, clean, digest_lines, grounded, numbers_in, template_card)
from conftest import make_settings


def result(*texts, suggestion=None, tone="steady"):
    return FactsResult(tuple(Fact(f"f{i}", t) for i, t in enumerate(texts)), suggestion, tone, False, "ok")


def writer(tmp_path, fakes, **over):
    s = make_settings(tmp_path, **over)
    db.init(s.db_path)
    return Writer(s, httpx.Client(transport=httpx.MockTransport(fakes.handler))), s


R = result("Easy run: 7.0 km in 40 min at 5:42/km", "12 s/km faster than your last similar easy run (5:54/km)")


def test_llm_happy_path_sends_strict_schema_and_privacy_prefs(tmp_path, fakes):
    w, _ = writer(tmp_path, fakes)
    out = w.write(R, {"goal_type": "10k"})
    assert out.source == "llm" and out.headline == "Run in the bank"
    req = fakes.llm[0]
    assert req["response_format"]["type"] == "json_schema" and req["response_format"]["json_schema"]["strict"]
    assert req["provider"]["data_collection"] == "deny" and req["provider"]["zdr"] is True
    assert "buttons" not in str(req["response_format"])  # the model never writes buttons


def test_only_facts_and_enum_digest_reach_the_model(tmp_path, fakes):
    w, _ = writer(tmp_path, fakes)
    w.write(R, digest_lines({"goal_type": "10k", "race_month": "2026-12", "free_text": "call me on +61400111222"}, {"easy": 2}))
    sent = str(fakes.llm[0])
    assert "+61400111222" not in sent and "free_text" not in sent
    assert "10k" in sent and "recent_feel" in sent


def test_ungrounded_number_falls_back_to_template(tmp_path, fakes):
    fakes.llm_mode = "ungrounded"
    w, _ = writer(tmp_path, fakes)
    out = w.write(R, {})
    assert out.source == "template" and out.note == "ungrounded_number" and "7.0 km" in out.body


def test_banned_phrase_invalid_json_overlong_and_no_number_all_fall_back(tmp_path, fakes):
    for mode, note in (("banned", "banned:great effort"), ("bad_json", "invalid_output"),
                       ("too_long", "invalid_output"), ("no_number", "no_number")):
        fakes.llm_mode = mode
        w, _ = writer(tmp_path, fakes)
        out = w.write(R, {})
        assert out.source == "template" and out.note == note, mode


def test_timeout_retries_once_then_template(tmp_path, fakes):
    fakes.llm_mode = "timeout"
    w, _ = writer(tmp_path, fakes)
    out = w.write(R, {})
    assert out.source == "template" and out.note == "timeout" and len(fakes.llm) == 2


def test_5xx_retries_once_then_template(tmp_path, fakes):
    fakes.llm_mode = "500"
    w, _ = writer(tmp_path, fakes)
    assert w.write(R, {}).note == "http_500" and len(fakes.llm) == 2


def test_spend_cap_trips_to_template_only(tmp_path, fakes):
    w, s = writer(tmp_path, fakes, monthly_cap_usd=0.0008)
    assert w.write(R, {}).source == "llm"   # 0.0004
    assert w.write(R, {}).source == "llm"   # 0.0008 total
    n = len(fakes.llm)
    out = w.write(R, {})
    assert out.source == "template" and out.note == "spend_cap" and len(fakes.llm) == n
    assert w.month_spend() >= 0.0008


def test_no_key_means_template(tmp_path, fakes):
    w, _ = writer(tmp_path, fakes, openrouter_key=None)
    assert w.write(R, {}).note == "no_key" and not fakes.llm


def test_grounding_is_whole_token():
    allowed = "Easy run: 7.0 km in 40 min at 5:42/km"
    assert grounded(CardText(headline="h", body="7.0 km at 5:42/km"), allowed)
    assert not grounded(CardText(headline="h", body="7 km"), allowed)          # 7 != 7.0
    assert not grounded(CardText(headline="h", body="42 seconds"), allowed)    # fragment of 5:42
    assert numbers_in("a 5:42 b 7.0 c 40") == {"5:42", "7.0", "40"}


def test_clean_rejects_medical_links_and_phone_numbers():
    assert clean(CardText(headline="h", body="see a doctor")) == "banned:doctor"
    assert clean(CardText(headline="h", body="visit www.x.io")) == "banned:www."
    assert clean(CardText(headline="h", body="call 0412 345 678")) == "phone_like"
    assert clean(CardText(headline="h", body="Steady 7.0 km")) is None


def test_template_respects_length_and_suggestion_only_headline():
    long = result(*[f"Fact number {i} " + "x" * 60 for i in range(5)])
    assert len(template_card(long.facts).body) <= 220
    t = template_card((Fact("suggestion", "Keep tomorrow easy."),))
    assert t.headline == "For tomorrow" and t.body == "Keep tomorrow easy."


def test_suggestion_text_is_part_of_the_grounded_facts(tmp_path, fakes):
    w, _ = writer(tmp_path, fakes)
    res = result("Easy run: 7.0 km in 40 min", suggestion=Suggestion("quality", "gap", "It has been 8 days since a hard session."))
    w.write(res, {})
    assert "8 days" in str(fakes.llm[0]["messages"][1]["content"])


FACTS = "Easy run: 5.2 km in 30 min at 5:46/km. 12 s/km faster than your last similar easy run (5:58/km)"


def g(body, allowed=FACTS, headline="h"):
    return grounded(CardText(headline=headline, body=body), allowed)


def test_spelled_out_numbers_are_rejected():
    assert not g("Five km easy, 30 min")
    assert not g("Twenty minutes in, you eased off, 5.2 km")
    assert not g("5.2 km, one of your faster easy days")
    assert g("5.2 km in 30 min, steady.")
    assert g("Half marathon pace work, 5.2 km today")  # 'half' is not treated as a number word


def test_units_must_match_the_facts():
    assert not g("5.2 miles in 30 min")
    assert not g("You covered fewer miles but 5.2 km held")
    assert g("5.2 kilometres in 30 minutes")         # same units, other spelling
    assert not g("5.2 km in 30 hours")
    assert g("5:46/km, 12 s/km faster")
    assert g("It was a second easy day, 5.2 km")     # ordinary English is fine


def test_memory_numbers_are_not_grounding(tmp_path, fakes):
    w, _ = writer(tmp_path, fakes)
    fakes.llm_mode = "ungrounded"
    # a feel count of 3 is in the digest but not in the facts: "3 km" must not pass
    out = w.write(result("Easy run: 7.0 km in 40 min"), {"recent_feel": {"easy": 3}})
    assert out.source == "template"


def _bad_response(tmp_path, fakes, payload):
    import httpx as _h
    s = make_settings(tmp_path)
    db.init(s.db_path)
    transport = _h.MockTransport(lambda req: _h.Response(200, json=payload))
    return Writer(s, _h.Client(transport=transport))


def test_any_odd_response_shape_falls_back_to_template(tmp_path):
    for payload in ([], [1, 2], "str", None, {"usage": "x"}, {"choices": "x"}, {"choices": [None]},
                    {"usage": {"prompt_tokens": None, "completion_tokens": "a"}, "provider": {"x": 1},
                     "choices": [{"message": {"content": "{\"headline\": \"h\", \"body\": \"5.0 km\"}"}}]}):
        w = _bad_response(tmp_path / str(abs(hash(str(payload)))), None, payload)
        out = w.write(R, {})
        assert out.headline and out.body, payload      # never raises, always a card
        assert out.source in ("template", "llm")


def test_null_token_counts_do_not_crash_cost_and_card_still_sent(tmp_path):
    payload = {"usage": {"prompt_tokens": None, "completion_tokens": None}, "provider": 5,
               "choices": [{"message": {"content": json_ok("Easy run: 7.0 km in 40 min")}}]}
    w = _bad_response(tmp_path, None, payload)
    out = w.write(result("Easy run: 7.0 km in 40 min"), {})
    assert out.source == "llm" and out.note == ""


def json_ok(body):
    import json as _j
    return _j.dumps({"headline": "Run in the bank", "body": body})
