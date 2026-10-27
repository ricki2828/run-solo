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
| `coach/` | coach chat (C1, off by default): gate, red-flag rail, job worker, Sonnet agent loop with read tools, chat validator, cost ledger |
| `checkin_service.py` | planning, the at-most-once send, taps that edit in place, the next-session view, the 14-day purge |

API: `POST /v1/enrol/start` (returns nonce + poll_secret), `POST /v1/enrol/status`, `POST /v1/enrol/confirm` (chat code, returns the token), `POST /v1/runs`, `PATCH /v1/runs/{id}/feel`, `GET|DELETE /v1/me`,
`PUT /v1/me/settings`, webhooks `/hooks/telegram` and `/hooks/whatsapp`. See `DEPLOY.md` for deployment.

### `GET /v1/me/next-session` (read-only, device token, same as `POST /v1/runs`)

With no 4-week plan on the newest run, the session comes from the default coach week (`default_week.py`: usual days, runs a week, recent distances, one quality and one long run) and `next_session` carries `"derived": true` and `week`/`weeks` null. A real plan always wins; the key is absent then.

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
  "coach_line": { "kind": "run", "headline": "...", "body": "...", "sent_at": "2026-10-15T05:46:00Z" },
  "quest": { "id": "q_2026-11_trail_visits_ab12", "state": "accepted", "accepted_at": "2026-11-02T10:04:00Z" },
  "care_weeks": ["2026-10-05", "2026-10-12"]
}
```

`next_session` also carries the briefing's match keys (C2b, additive): `session_ref` (`w3s2` for an app plan session, `cw<yyyymmdd><e|l|q>` for a
coach-week one), `fingerprint` (the content fingerprint below) and, for a quality session with a rep count, `reps`. They are the
keys `GET /v1/me/briefing` stores and serves under, so Start can match a cached briefing to today's session from memory. They are
absent when there is nothing to brief (an app plan whose upload sent no `session_ref`).

`quest` and `care_weeks` are additive keys on the same `v: 1` (the app ignores unknown keys and blanks Home's coach card on any other `v`, so a bump is not allowed):
- `quest` is the quest the runner has accepted that has not ended (taken in Telegram or sent by the app), or `null`. The app adopts it only
  when the id matches one of its own offer candidates, and only if it has no active quest of its own.
- `care_weeks` is the Mondays, within the last 8 weeks, that overlap an `ill` or `sore` check-in window (a skip because ill or sore, or a
  sore answer the evening before), oldest first. Dates only: never which of the two, and never a skip's reason. It is `[]` without check-in consent, and
  check-in answers last 14 days, so in practice it covers the last two weeks. The app pauses its streak on those weeks.

The server never guesses a name. `plan_next` (the `POST /v1/runs` field) takes three OPTIONAL keys:
- `session_name`: accepted only if it is exactly one of the app's built-in session names (`facts.known_session`: Norwegian 4x4,
  30/30s, 1-minute reps, Pyramid, Tempo intervals, Yasso 800s, 1 km repeats, and "N × 400 m" with the real × sign). Anything
  else (a custom or typed name, a homoglyph, hidden or control characters, a link or handle, ASCII "x") drops the name.
- `session_id`: a hint, `^[a-z0-9_]{1,40}$`, the app's template id with hyphens as underscores (e.g. `norwegian_4x4`). It is kept
  only together with an accepted `session_name` and returned as `next_session.session_id`; without a hint the id is the name as a slug.
- `session_ref`: the app's opaque plan id, `^[a-z0-9_]{1,16}$` (e.g. `w1s1`), never shown to the runner; returned to the app only as `next_session.session_ref`, the briefing match key (below).

An invalid key is dropped on its own and the plan still counts; old payloads without them pass unchanged; any other unknown key
is still a 422. `name_source` is "plan" when a name was accepted. A session the coach made easy loses the name (it is a different
session). Without a name, `name` is the kind name ("Quality session", "Easy run", "Long run"), `session_id` the kind and
`name_source` "none". Easy and long sessions have no built-in name, so they always show the kind name.

`next_session` is `null` when the app's newest run carries no planned session or its date has passed; `coach_line` is `null`
before the first card. `kind` is one of `run`, `evening`, `recap`, `monthly`. Nothing here holds a check-in answer, only the
fact that a session moved: no reason, no readiness, no skip. The same resolver feeds the evening rules and the morning card.

### `GET /v1/me/briefing` (C2b: the coach's spoken session briefing, device token)

A TEMPLATE for the runner's next planned session, with slots and never a number. The app (Kotlin) renders the slots on the device, in the
runner's units, from the same values the in-run cues use. The server never renders a number. `Cache-Control: no-store`. Never calls a model.

- `200` `{"session_ref", "fingerprint", "template", "generated_at", "prompt_hash"}`: serve it only to the session whose fingerprint matches. (A `200` without `template` is the suppress answer below.)
- `202` `{"status":"pending"}`: a job is queued or running. Keep the cache.
- `200 {"status":"suppress"}` (no `template`, no reason, never a flag kind): the gates pass but a safety block is on (an active health flag, a sore/ill check-in window, or an injury the chat screen saw in the last 7 days). Clear the cache and speak NO briefing at all, the app's own offline briefing included: use the plain start line (`SummaryWords.start`).
- `204`: nothing to say, and nothing is implied about why (gate closed: kill switch off, flag off, not allowlisted, no consent, paused; or no session, nothing generated, expired after 36 h). Clear the cache; the app's own offline briefing may still be spoken.

Every gate is re-read on every call: `COMPANION_COACH_CHAT`, the allowlist, consent at or above 3, not paused, and no active `urgent`, `wellbeing`
(self-harm), `injury` or `ill` flag (injury is a plain 204, the review's simplest option; `ill` is added for the same reason). Nothing writes an `injury` or `ill` flag row today, so the rule also fires on what exists: a check-in that says ill or sore (a skip because ill or sore, or a sore answer, until its window ends), or the chat safety classifier seeing an injury in the last 7 days (`coach_jobs.screen = 'clear:injury'`). `niggle_area` memory is never sent to the model. Withdrawing consent deletes the rows. Off by default behind `COMPANION_COACH_BRIEFING=1` (needs the chat gates too).
Generation: queued after a run upload or a check-in answer, run by the coach worker (same gate again at claim, per-runner daily cap
`COMPANION_COACH_BRIEFING_DAILY` default 8 model calls, the shared cost ledger, at most one retry), coalesced on a hash of the facts.

Slots (each speaks as words; worst-case length is what the 40-word cap counts):

| slot | spoken as | worst case | present when |
|---|---|---|---|
| `{session}` | "Norwegian four by four" | 4 words | the plan names the session |
| `{pace}` | "five ten per kilometre" (or per mile), the same value as `VoiceCoachConfig.targetPaceSecPerKm` | 6 | a quality session with a target pace |
| `{minutes}` | "forty five minutes" | 4 | the plan holds minutes |
| `{distance}` | "ten point five kilometres" | 5 | the plan holds a distance |
| `{reps}` | "four reps" (spoken WITH the word reps) | 2 | the session id or name carries `NxM` |

A template only uses slots its session has. Kotlin renders, re-counts words (cap 40), and on any problem (unknown slot, over cap) uses the Dart template, then
`SummaryWords.start`; it never truncates. Outside a slot a template has no digit, no number word at all (one, twenty five, fours, tens, dozens, twice, half, a few, several, a pair, a quarter) and no unit word (hour, minute, mile, kilometre, metre): each slot speaks its own unit, so the template never writes one, and never writes "reps" next to `{reps}`.

Fingerprint (the app matches the session it actually starts against it): the SHA-256 of
`v1|kind=<easy|long|quality>|min=<int>|dist_m=<int>|reps=<int>|pace_lo=<int>|pace_hi=<int>`, first 16 hex characters. Fields in exactly that order, an absent value
is empty, and EVERY number (minutes, metres, reps, paces in s/km) is converted with round-half-up, `floor(x + 0.5)` (29.5 gives 30), then written as a plain integer. Shared fixture, tested here and for the Dart side to test against the same file:
`companion-server/tests/fixtures/briefing_fingerprint.json`. `plan_next` carries no rep count, so the server takes `reps` from an `NxM` in the session id or name
(`norwegian_4x4` gives 4); the Dart side must derive it the same way for a plan session, or the match is simply missed and the app's own line is spoken.

### Quest block (`POST /v1/runs`, optional `quest`)

The app owns quests (history, trail grouping, True Pace); the server keeps what it last said so it can issue the month's Telegram card, add the
done line and nudge once. It never computes progress. Every number is a whole number; no coordinates, run ids or dates other than `ends_on`.
Unknown keys, a bad value or a mismatch drop the whole block, never the run (`extra="forbid"`, so **the app must not send it until this server is live**).

```json
"quest": {
  "offers": [{"id": "q_2026-11_trail_visits_ab12", "kind": "trail_visits", "target": 5, "baseline": 4, "unit": "runs", "trail_name": "The Saddle Trail"}],
  "active": {"id": "q_2026-11_trail_visits_ab12", "kind": "trail_visits", "target": 5, "value": 3, "ends_on": "2026-12-02", "trail_name": "The Saddle Trail"},
  "done_now": "q_2026-11_trail_visits_ab12",
  "closed": {"id": "q_2026-11_trail_visits_ab12", "result": "dropped"},
  "month_skipped": "2026-11"
}
```
- `offers`: up to 3, distinct ids, `^q_[a-z0-9_-]{1,48}$`. `kind` is `trail_visits` (unit `runs`), `trail_best` or `climb_best` (`s`), `climb_month` (`m`) or `distance_month` (`km`);
  the unit must fit the kind. `baseline` (optional) is the runner's own best, for the card text. Offer 0 is the default.
- `active`: the quest the runner has taken, with progress `value`. It is the source of truth: it displaces a quest accepted in Telegram under another id.
- `done_now`: the id the run just finished. Send `active` (with `value` = `target`) in the same block, so the server has the row. The first run to finish it keeps the credit.
- `trail_name` is kept only while the place opt-in is on (cleared when it turns off) and goes through the trail-name filter; otherwise the copy says "your trail".
- `closed`: `{id, result}` with `result` one of `done | dropped | expired`. The app sends it when it ends a quest the server may still show (dropped = the runner gave it up).
  `dropped` is stored as `skipped`. The row stops being returned by next-session and no nudge goes.
- `month_skipped: "YYYY-MM"`: the runner said "Not this month" in the app for that offer month. That month's waiting offers are marked `skipped` and its queued (pending) offer card is cancelled. Ignored on a stale or older upload.
- A month is offered once. After a quest is taken, skipped, done or lapsed, new `offers` for that month are ignored. The month an offer belongs to is read from its id
  (`q_YYYY-MM_...`), falling back to the local month of the run that carried it.
- A stale upload, or one older than a run already stored, has its `active` and `offers` ignored (so an offline queue cannot undo today's quest); `done_now` and `closed` still apply.

Wire contract for the app (PR3), all keys snake_case:
- Keys are exactly `id, kind, target, baseline, unit, trail_name` on an offer and `id, kind, target, value, ends_on, trail_name` on `active`. `active` must not carry `baseline` or `unit`
  (the server derives the unit from the kind), and an offer must not carry `value`.
- `target`, `baseline` and `value` are JSON integers (strict: `3.0` or `"3"` drops the block); `target` 1 to 1,000,000, `value` 0 to 1,000,000. The app rounds down before sending: metres, whole km, seconds. `ends_on` is `YYYY-MM-DD`. `trail_name` is at most 30 characters or omitted.
- next-session returns `quest.accepted_at` as UTC with a trailing `Z`.

Table `quests` (PK `user_id, quest_id`): kind, target, baseline, unit, trail_name, state (`offered | accepted | skipped | done | expired`), value, `ends_on`,
plus `pos` (offer order), `card_id` (the offer card showing it), `accepted_at`, `done_run_id`. Rows go 90 days after `ends_on`, or 90 days after the end of the offer
month if never taken; deleted with the user; in the export as `quests` (without `card_id` and `done_run_id`).

Telegram, all fixed templates (no model writes them, nothing here reaches OpenRouter):
- **Offer.** The first run of a month that carries `offers` queues a `quest_offer` for the next 20:00 to 21:00 local window (retried by later runs until one goes).
  Not sent when the month is decided, a quest is running, the runner is on WhatsApp, or the weekly suggestion cap (2) or the day's one question is taken; it claims both.
  Buttons `q:take`, `q:next`, `q:skip` edit the message in place: Another cycles offers 1 to 3, Take it starts a 30 day quest (and the app adopts it from next-session),
  Not this month skips the month's offers. A card that has moved on answers "That one has moved on." and loses its buttons.
- **Done.** The run named by `done_now` gets `Quest done: ...` as the last line of its post-run card. No extra message.
- **Nudge.** When 1 to 7 days are left and the runner is one run (or a quarter of the target) short, the next evening suggestion ends with one line, once per quest
  (quota key `qnudge:<id>`). Never when the evening is in a lighter (care) window.

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

Heart vs hill: a trail block may carry `hr` (bpm, 30-250) and `hr_z` (the runner's own zone 1-5 of each), both exactly one per `profile` point
and sent together, only for a strap run with the app's "Heart rate on cards" switch on (`PUT /v1/me/settings {heart_rate}`, off by default,
`users.hr_optin`). The server drops them at storage unless the switch is on, drops every stored series the moment it goes off, and deletes them with
the rest of the trail block after 30 days (the series is inside `trail_json`). A board run with a series goes out as the `trail_heart` card in place of
`trail_board` (a record stays `trail_record`; the series is stripped from its facts and never reaches the worker). The worker's `trail_heart` kind takes
`TRAIL_KEYS` plus `hr_series` and `hr_zones` and refuses a mismatched length. The "The hill stopped at N m. My heart didn't." line is used only when the
run's peak bpm came at or after the top of the hill; otherwise the card states the climb and the peak.
