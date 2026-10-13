# Run Supreme companion server (phase 1)

FastAPI + SQLite, one uvicorn worker, no ML libraries. The app posts compact run summaries; a deterministic
facts engine decides what is worth saying (or nothing); OpenRouter phrases it under a strict schema with number
grounding and a template fallback; cards go out over Telegram (WhatsApp adapter is built but disabled).

```
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/python -m pytest
```

Dependencies are hash-pinned: `pip install --require-hashes -r requirements-dev.txt`.

| Module | Job |
|---|---|
| `facts.py` | pure rules: facts, suggestions, weekly question |
| `writer.py` | OpenRouter call, validation, grounding, template fallback, spend cap |
| `service.py` | enrolment (inbound-message binding), run ingest, cards, outbox worker, memory, retention |
| `channels.py` | Telegram + WhatsApp Cloud adapters, webhook parsing, signature check |
| `timeutil.py` | all local-time logic: quiet hours, ISO-week caps pinned across zone changes |
| `db.py` | schema, `hard_delete_user` (walks every table with a `user_id`) |
| `checkins.py` | pure: the answer enums, the next-session resolver, the "worth asking" rule, usual start time |
| `checkin_copy.py` | every check-in line as a fixed template (no model ever writes one) |
| `checkin_service.py` | planning, the at-most-once send, taps that edit in place, the next-session view, the 14-day purge |

API: `POST /v1/enrol/start` (returns nonce + poll_secret), `POST /v1/enrol/status`, `POST /v1/enrol/confirm` (chat code, returns the token), `POST /v1/runs`, `PATCH /v1/runs/{id}/feel`, `GET|DELETE /v1/me`,
`PUT /v1/me/settings`, webhooks `/hooks/telegram` and `/hooks/whatsapp`. See `DEPLOY.md` for deployment.

### `GET /v1/me/next-session` (read-only, device token, same as `POST /v1/runs`)

For the app's Home (stream S3). `Cache-Control: no-store`. A server without check-ins answers 404: treat that as "nothing".

```json
{
  "v": 1,
  "generated_at": "2026-10-15T09:00:00Z",
  "next_session": {
    "date": "2026-10-19",            // the runner's local date the session is on now
    "type": "quality",              // the plan's type: easy | long | quality ("easy" when the coach made it easy)
    "kind": "quality",              // same as type (the plan's kind)
    "name": "Norwegian 4x4",        // plan_next.session_name when the app sent it, else the kind name ("Quality session")
    "session_id": "norwegian_4x4",  // that name as a slug, else the kind ("quality")
    "name_source": "plan",          // plan: the app named it | none: kind-level name
    "minutes": null,                // the plan's size, when it has one (null when made easy)
    "distance_m": 6000,
    "week": 3, "weeks": 4,          // the plan's week, when the app sent it
    "moved": true,                  // true: "moved by your coach"
    "original_date": "2026-10-15",  // null unless moved
    "label": "Quality session, 6 km"
  },
  "coach_line": { "kind": "run", "headline": "...", "body": "...", "sent_at": "2026-10-15T05:46:00Z" }
}
```

The server never guesses a name. `plan_next` (the `POST /v1/runs` field) takes two OPTIONAL keys: `session_name` (1-40
printable characters, no control or format characters; shown to the runner, so a built-in session name only, never one the
runner typed) and `session_ref` (the app's opaque plan id, `^[a-z0-9_]{1,16}$`, e.g. "w1s1"; stored for dedupe only and never
shown or returned by next-session). Each is independent; an invalid one is dropped on its own and the plan still counts (old
payloads without them pass unchanged; any other unknown key is still a 422). `name` is `session_name` when sent, `session_id`
is that name as a slug, and `name_source` is "plan". A session the coach made easy loses the name (it is a different session).
Without a name, `name` is the kind name ("Quality session", "Easy run", "Long run"), `session_id` the kind, `name_source` "none".

`next_session` is `null` when the app's newest run carries no planned session or its date has passed; `coach_line` is `null`
before the first card. `kind` is one of `run`, `evening`, `recap`, `monthly`. Nothing here holds a check-in answer, only the
fact that a session moved: no reason, no readiness, no skip. The same resolver feeds the evening rules and the morning card.

### Check-ins

Four slots, each a button-only message the coach starts and then edits in place: `ready` (evening before, 20:00-21:00 local),
`today` (about 15 minutes before the usual start), `postrun` (20 minutes after the card of an easy run that came out slower and
harder), `shape` (Sunday 19:05). At most one *question* (an unprompted message with a keyboard, including the evening suggestion
and the weekly question) per runner local day, claimed through `question_cap`'s unique key before sending. A slot is claimed in
`checkin_slots` (user, slot, date) before the send and its message id stored after: at most once, and one past its window is
dropped, never sent late. Answers are `checkin_answers` (enums only), purged after 14 days, never read by `writer.py` or `facts.py`.
