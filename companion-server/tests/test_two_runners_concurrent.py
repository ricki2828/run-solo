"""Plan §5 multi-user check, for real: two new runners upload, get cards, questions, evening nudges and the Sunday recap
while their requests genuinely interleave (threads on one database, the way the server's thread pool and tick loop run).
Every outbound Telegram call and every model request is checked for the other runner's data."""
import json
import threading
from datetime import datetime, timedelta, timezone

import httpx

from companion import db
from companion.service import RunIn, Service
from companion.timeutil import iso

from conftest import Fakes, make_settings

UTC = timezone.utc
USERS = {
    "A": dict(chat="7001", zone="Pacific/Auckland", place="Mission Bay", route="routeAAA1", session="Auckland Hills",
              pace0=420, step=-5),      # 7:00/km and quicker
    "B": dict(chat="7002", zone="Europe/London", place="Hackney Marshes", route="routeBBB2", session="Lea Valley 5s",
              pace0=300, step=-6),      # 5:00/km and quicker: no pace string is shared
}
T0 = datetime(2026, 10, 8, 6, 0, tzinfo=UTC)   # a Thursday


def mmss(p):
    return f"{int(p // 60)}:{int(p % 60):02d}"


def body(u, i, start):
    d = USERS[u]
    pace = d["pace0"] + d["step"] * i
    return {"run_id": f"{u}-run-{i}", "type": "easy", "start_utc": start.isoformat(), "utc_offset_min": 0,
            "zone_id": d["zone"], "duration_s": round(5 * pace), "distance_m": 5000 + 250 * i,
            "pace_s_per_km": float(pace), "locality": d["place"], "route_id": d["route"],
            "session_name": d["session"], "verdict": [None, "baselineSet", "faster", "noRealChange", "faster"][i]}


def tokens(u):
    d = USERS[u]
    paces = {mmss(d["pace0"] + d["step"] * i) for i in range(5)}
    return {d["place"], d["route"], d["session"], f"{u}-run-", d["chat"]} | paces


def test_two_runners_interleaved_never_leak_into_each_other(tmp_path):
    fakes = Fakes()
    s = make_settings(tmp_path, weather_enabled=False, checkins_enabled=False,
                      allowed_ids=frozenset(f"telegram:{d['chat']}" for d in USERS.values()))
    svc = Service(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    with db.tx(s.db_path) as c:
        for u, d in USERS.items():
            c.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_version, consent_at, zone_id, "
                      "utc_offset_min, last_inbound_at) VALUES (?,?,?,?,?,?,?,?,?)",
                      (f"u_{u}", "telegram", d["chat"], iso(T0), "2", iso(T0), d["zone"], 0, iso(T0)))
    errors: list[BaseException] = []
    gate = threading.Barrier(3)

    def uploader(u):
        try:
            gate.wait()
            for i in range(5):
                start = T0 + timedelta(days=2 * i, hours=0 if u == "A" else 1)
                now = start + timedelta(minutes=40)
                svc.ingest_run(f"u_{u}", RunIn.model_validate(body(u, i, start)), now)
                svc.run_outbox(now)          # both runners drain the one outbox at the same moment
        except BaseException as e:           # noqa: BLE001 - surfaced by the assertion below
            errors.append(e)

    def worker():
        """The server's tick loop, running while the uploads land: evening nudges, the recap and the outbox."""
        try:
            gate.wait()
            t = T0
            while t < T0 + timedelta(days=11):
                svc.plan_evening(t)
                svc.plan_recap(t)
                svc.run_outbox(t)
                t += timedelta(minutes=30)
        except BaseException as e:           # noqa: BLE001
            errors.append(e)

    threads = [threading.Thread(target=uploader, args=(u,)) for u in USERS] + [threading.Thread(target=worker)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(120)
    assert not errors, errors
    # the tick loop ran before some uploads: run the whole window once more, single-threaded, so late runs get their turn
    t = T0
    while t < T0 + timedelta(days=11):
        svc.plan_evening(t)
        svc.plan_recap(t)
        svc.run_outbox(t + timedelta(hours=1))
        t += timedelta(minutes=30)

    sent = [(b, json.dumps(b, ensure_ascii=False)) for m, b in fakes.tg if m.startswith("send")]
    assert sent, "nothing was sent"
    chats = {str(b.get("chat_id")) for b, _ in sent}
    assert chats == {d["chat"] for d in USERS.values()}, chats
    per_chat: dict[str, list[str]] = {}
    for b, raw in sent:
        chat = str(b["chat_id"])
        mine = next(u for u, d in USERS.items() if d["chat"] == chat)
        other = "B" if mine == "A" else "A"
        leaked = [tok for tok in tokens(other) if tok in raw]
        assert not leaked, (chat, leaked, raw)
        per_chat.setdefault(chat, []).append(raw)
    for u, d in USERS.items():
        assert len(per_chat[d["chat"]]) >= 5      # at least a card per run
        recaps = [r for r in per_chat[d["chat"]] if "Starting" in r]     # the two Sunday recaps, 11 and 18 Oct
        assert len(recaps) == 2, (u, len(recaps))
        mine = " ".join(per_chat[d["chat"]])
        assert d["place"] in mine and any(tok in mine for tok in tokens(u) if ":" in tok), u   # the check can see a runner's own data
    # nothing the model was asked about mixes two runners
    for req in fakes.llm:
        raw = json.dumps(req, ensure_ascii=False)
        who = [u for u in USERS if any(tok in raw for tok in tokens(u) if tok != USERS[u]["chat"])]
        assert len(who) <= 1, raw
    # at-most-once: no card row was sent twice, no run has two run cards
    with db.ro(s.db_path) as c:
        for u in USERS:
            rows = c.execute("SELECT run_id FROM cards WHERE user_id=? AND kind='run'", (f"u_{u}",)).fetchall()
            ids = sorted(r[0] for r in rows)
            assert ids == [f"{u}-run-{i}" for i in range(5)], ids
