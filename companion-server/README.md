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

The server never guesses a name. `plan_next` (the `POST /v1/runs` field) takes three OPTIONAL keys:
- `session_name`: accepted only if it is exactly one of the app's built-in session names (`facts.known_session`: Norwegian 4x4,
  30/30s, 1-minute reps, Pyramid, Tempo intervals, Yasso 800s, 1 km repeats, and "N × 400 m" with the real × sign). Anything
  else (a custom or typed name, a homoglyph, hidden or control characters, a link or handle, ASCII "x") drops the name.
- `session_id`: a hint, `^[a-z0-9_]{1,40}$`, the app's template id with hyphens as underscores (e.g. `norwegian_4x4`). It is kept
  only together with an accepted `session_name` and returned as `next_session.session_id`; without a hint the id is the name as a slug.
- `session_ref`: the app's opaque plan id, `^[a-z0-9_]{1,16}$` (e.g. `w1s1`), stored for dedupe only and never shown or returned.

An invalid key is dropped on its own and the plan still counts; old payloads without them pass unchanged; any other unknown key
is still a 422. `name_source` is "plan" when a name was accepted. A session the coach made easy loses the name (it is a different
session). Without a name, `name` is the kind name ("Quality session", "Easy run", "Long run"), `session_id` the kind and
`name_source` "none". Easy and long sessions have no built-in name, so they always show the kind name.

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

### Trail block (`POST /v1/runs`, optional `trail`)

Sent only for a run the app has matched to a trail. The app owns matching (like for like, pace-normalised per #274); the server
stores the block (`run_shape.trail_json`, 30 days after the run, deleted with the user) and draws the trail cards from it. Every
number is a whole number, there are no coordinates and no dates, and an unknown key or a bad block drops the trail, never the run.

```json
"trail": {
  "n": 5,                                   // int 1..999: runs of this trail including this one
  "board": [                                // 2..10 rows, your OWN runs only, no dates
    {"attempt": 4, "time_s": 3683, "rank": 1},      // attempt 1..999 (distinct), time_s 1..86400 = the pace-normalised time, rank 1..999 optional
    {"attempt": 5, "time_s": 3734, "today": true, "rank": 2}   // exactly one row has today:true. If n > 10, send the all-time best, today and the nearest
                                            // rows, EACH WITH ITS TRUE RANK among all n runs (ties share one). Without ranks and n > rows sent, the
                                            // card prints no ordinal and no rank numbers rather than a wrong one. n must be >= the number of rows.
  ],
  "profile": [0, 6, 14, "..."],             // optional, 2..64 ints, -2000..9000: metres RELATIVE to the start (start = 0), evenly spaced along the trail
  "elev_src": "baro",                       // optional "baro"|"gps": shading by steepness is drawn only for baro; absent counts as gps
  "ghost_gap": [0, 1, -2, "..."],           // optional, 2..64 ints, -3600..3600: seconds vs your old best along the same progress, POSITIVE = ahead (aheadBestMs)
  "turn": 31,                               // optional, index into profile (0..63), requires profile
  "shape": "out_and_back",                  // optional "out_and_back"|"loop"|"one_way"
  "name": "The Saddle Trail"                // optional, <=30 chars. The server keeps it only while the place opt-in is on (PUT /v1/me/settings {"place_names": true},
                                            // default false; turning it off deletes stored names). Dropped (trail kept) if it has 5+ digits, a +number,
                                            // @, a link, a ":handle", a control character, or the words insta/ig/tiktok/strava/fb/whatsapp/snap
}
```

Cards: `trail_record` when today's `time_s` is strictly under every other row (a trail PB; replaces the generic PB card, no video);
otherwise `trail_board` from the 3rd run (`n >= 3`, at least 3 rows). One card per run, built once. Both go to the runner's own
Telegram chat with `has_spoiler` and a neutral caption; the coach line follows as its own message inside Telegram spoiler formatting (tap to reveal; `COMPANION_TRAIL_SPOILER=0` turns it off, a refusal falls back to a plain photo).
`COMPANION_TRAIL_CARDS=0` turns the cards off.

Ghost race clip: a trail record whose block has `ghost_gap` and a profile (n >= 2) goes out as a silent 6 s, 1080x1350 MP4 of today
racing the old best along the relative profile, via Telegram `sendAnimation` (autoplays and loops; same spoiler and neutral caption as
the still), instead of the still. The static record card is rendered beside it as the fallback if Telegram refuses the animation, and
is sent alone when the clip cannot be made (worker down, ffmpeg missing). The render is the worker's `video` kind `ghostclip`
(PIL frames, about 10 s, serial like every render). Telegram's `file_id` is kept in `media_file_ids` (cascades with the run), so a
repeat send is one JSON call. Forwarding the clip from Telegram keeps the elevation profile in it (the clip is the record card's picture, moving), the same as forwarding the still. A repeat send also renders the still beside the cached id, so a refused id falls back to a photo, not text; the id is deleted with the 30-day trail block. `COMPANION_TRAIL_CLIP=0` keeps the still. The render worker's kinds `trail_board` and `trail_record` take the keys in
`render/protocol.py` `TRAIL_KEYS` (`elev_profile`, `elev_src`, `ghost_gap`, `trail_board`, `trail_runs`, `turn_idx`, `trail_shape`, `trail_name`).
