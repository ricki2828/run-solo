# Deploying the companion server

Status: built and tested locally only. Nothing here has been run on the host. Port **8051**
(checked free with `lsof` on 9 Oct 2026; re-check before binding). Public host: `companion.taiaroa.xyz`.

## 0. Gate (do not skip)

1. Run the mandatory checks in `~/tools/validation/scripts/` (CLAUDE.md rule 1). Any failure: stop.
2. Keep the enrol allowlist on (`COMPANION_ALLOWED_IDS`, Ricki only). Do **not** set
   `COMPANION_OPEN_ENROLMENT=1` until the privacy page section 2b, the Play Data safety form, the web
   deletion link and the rewritten listing copy are live (eng-review B2). Flipping it is a recorded release step.
3. WhatsApp stays off (`COMPANION_WA_ENABLED` unset) until Meta config and the written Meta/BSP policy check exist.

## 1. Things Ricki supplies

- **New Telegram bot** from BotFather (separate from the assistant bot). Token goes in `COMPANION_TELEGRAM_TOKEN`,
  username in `COMPANION_TELEGRAM_BOT`. DM the bot once so it can message you; find your chat id from the first
  update, or message `@userinfobot`.
- **Own OpenRouter key** with a credit limit set on the key (OpenRouter dashboard). `COMPANION_OPENROUTER_KEY`.
  Without it the server runs template-only. The shared key is used only if `COMPANION_ALLOW_SHARED_KEY=1`.

## 2. Install (on the host, as ricki28)

```bash
cd ~/run-solo && git fetch && git checkout <merged main or the PR branch>
cd companion-server && python3 -m venv .venv && .venv/bin/pip install --require-hashes -r requirements.txt   # check `free -m` first; pins live in requirements.txt (pip-compile --generate-hashes from requirements.in)
.venv/bin/pip install --require-hashes -r requirements-dev.txt && .venv/bin/python -m pytest   # must be green

mkdir -p ~/.secrets ~/companion-data ~/backups/companion && chmod 700 ~/companion-data ~/backups/companion
cp deploy/companion.env.example ~/.secrets/companion.env && chmod 600 ~/.secrets/companion.env
# edit it: pepper, secrets, allowed ids, tokens (do not paste secrets into chat or logs)
openssl rand -hex 24 > ~/.secrets/companion-backup.key && chmod 600 ~/.secrets/companion-backup.key
```

Back up `companion-backup.key` somewhere safe: without it the backups cannot be restored.

Updating dependencies: edit `requirements.in`, run `pip-compile --generate-hashes --allow-unsafe --strip-extras` for both files, re-run the tests.

## 3. Services

```bash
mkdir -p ~/.config/systemd/user
cp deploy/companion.service deploy/companion-backup.service deploy/companion-backup.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now companion.service companion-backup.timer
curl -s localhost:8051/healthz        # {"ok":true,"overdue_outbox":0}
.venv/bin/python -m companion.cli status
```

The unit assumes the checkout at `~/run-solo/companion-server`; edit `WorkingDirectory` and `ExecStart` if it lives elsewhere.
`MemoryMax=200M`, one uvicorn worker, access log off.

Sandbox (tested on this host with `systemd-run --user` using the same properties): `$HOME` is an empty tmpfs, so
`~/.secrets`, `~/.ssh` and other projects are invisible to the process. Only the app dir (read-only) and
`~/companion-data` (read-write) are bound back in. Also `ProtectSystem=strict`, `NoNewPrivileges`, empty
capability set, `MemoryDenyWriteExecute`, syscall filter, and only AF_INET/AF_INET6/AF_UNIX sockets. The env file
is read by systemd outside the sandbox. The backup unit has no network at all (`IPAddressDeny=any`).
The full unit has not been installed; `systemctl --user status companion` must show it active after step 3.

**Before the first non-Ricki user: dedicated system user.** The user-service sandbox above is the dogfood
posture. For real users, create `companion` (system user, no shell, no login), keep the code in `/opt/companion`
(root-owned, read-only) and data in `/var/lib/companion` (`0700`, owned by `companion`), move the unit to
`/etc/systemd/system/` with `User=companion`, `StateDirectory=companion`, and keep the same sandbox lines.
Then no other process on the host, including every agent running as ricki28, can read the database.

## 3b. Render worker (only for `COMPANION_MEDIA=1`)

Cards and videos are rendered by a separate unit, `companion-render.service` (sec-review-225 F2). Chromium and ffmpeg
cannot run inside `companion.service` (`MemoryMax=200M`, `MemoryDenyWriteExecute`, `ProtectHome=tmpfs`), and that unit
holds the bot token, the WhatsApp secret and the DB, so its hardening is **not** loosened: `companion.service` is
unchanged. It already reaches the worker's socket because `~/companion-data` is bound into it.

How it fits together:
- The companion sends `{op, kind, facts}` as JSON over the unix socket `~/companion-data/render/render.sock` and gets PNG or MP4
  bytes back, or a short error code (`bad_request`, `timeout`, `too_big`, `render_failed`). Protocol: `render/protocol.py`.
- `facts` is exactly what the card shows (zone time, place name, distance, pace, headline, score moves). Keys outside
  `protocol.ALLOWED_FACT_KEYS` are refused by both sides, so no run id, user id, chat id or token can reach the worker.
- The suggestion, milestone, race countdown and monthly poster kinds are held to their own key lists
  (`protocol.KIND_FACT_KEYS`) and value shapes on top of that. Suggestion and touch (milestone, countdown) facts are stored in
  `convo_cards.media_json` when the coach decides to send the card (30 days, then the card goes; listed in `/v1/me` as
  `picture_facts`). The monthly poster stores nothing: it is rebuilt from the run rows when sent, route-less (day, type,
  distance, duration per run). Deploy the worker and the companion from the same commit: an old worker refuses the new kinds
  and the companion falls back to text.
- The worker has no DB, no env file, no network. It runs one render at a time, each in a child process that is killed at
  30 s (card) or 120 s (video). Output caps: 10 MB photo, 50 MB video (Telegram's limits).
- On any worker error, timeout or missing socket the companion sends the text card, as before. After a timeout it skips the
  worker for 60 s so a hung renderer cannot stall every send.

Sandbox of `companion-render.service` (tested on this host with a transient unit using the same properties): no network
(`IPAddressDeny=any`, `PrivateNetwork`, only `AF_UNIX`), `$HOME` is an empty tmpfs, `NoNewPrivileges`, empty capability set,
`ProtectSystem=strict`, private `/tmp`. Read-only binds: the app dir, `assets/fonts`, `assets/brand`, the Playwright
Chromium dir, the Chromium shared libs and `~/bin/ffmpeg`. The only writable path is `~/companion-data/render/`.
It cannot see `~/.secrets`, `~/companion-data/companion.db`, `~/.ssh` or other projects (checked from inside the sandbox).

Why this unit differs from `companion.service`:
- **No `MemoryDenyWriteExecute`.** Playwright's node driver aborts at start-up under it (tested), and Chromium runs the same
  V8 JIT. The exposure is limited to this unit, which has no network and no secrets.
- **Syscall filter**: `@system-service @sandbox`, minus `@privileged`, plus `capget capset setpriority`. Chromium installs its
  own seccomp filter and uses those three; with `~@resources` in place it crashed (SIGSYS) or failed about 1 render in 5.
- **`MemoryMax=900M`.** Measured on this host (aarch64, Playwright Chromium 1208 headless shell): peak summed RSS 533 MiB for a
  card (9 processes) and 544 MiB for a weekly video (worker, render child, ffmpeg); cgroup `MemoryPeak` 590-830 MiB
  including page cache. It runs one render at a time and only while a card is being sent.

Install (the venv is separate from the companion's, and never installed into it):

```bash
# The unit runs the LIVE tree (~/services/run-supreme-companion, a deployed copy), never the ~/run-solo checkout that
# agents switch branches in. Deploy the reviewed commit there first: the companion imports render.protocol and
# companion.render_client, and the worker needs render/worker.py, requirements-render.txt and deploy/.
cd ~/services/run-supreme-companion
python3 -m venv .venv-render && .venv-render/bin/pip install --require-hashes -r requirements-render.txt
mkdir -m700 ~/companion-data/render   # must exist before the unit starts: BindPaths fails without it
# the unit's Environment= lines name this host's Chromium, its libs and ffmpeg; edit them and the Bind lines together if they differ:
#   RS_CHROMIUM_PATH  ~/.cache/ms-playwright/chromium_headless_shell-1208/chrome-linux/headless_shell   (python -m playwright install chromium)
#   LD_LIBRARY_PATH   ~/.local/chromium-libs/usr/lib/aarch64-linux-gnu   (libatk/libasound/libXdamage; there is no root to apt install them here)
#   FFMPEG            ~/bin/ffmpeg
#   COMPANION_ASSETS_DIR  ~/services/run-supreme-companion/assets   (fonts + brand/svg)
cp deploy/companion-render.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now companion-render.service
systemctl --user status companion-render.service     # active; the socket appears in ~/companion-data/render/
journalctl --user -u companion-render -n 20           # "render worker listening"
```

Smoke test with the live companion's venv (run from `~/services/run-supreme-companion`) (writes nothing, sends nothing):

```bash
.venv/bin/python - <<'PY'
from companion.render_client import RenderClient
png = RenderClient("/home/ricki28/companion-data/render/render.sock").card("light", {"type": "easy", "start_local": "2026-10-10T06:00", "distance_km": 7.0, "duration_s": 2400, "headline": "Steady one"})
print(len(png), png[:4])
PY
```

Turn media on: add `COMPANION_MEDIA=1` to `~/.secrets/run-supreme-companion.env` (and `COMPANION_RENDER_SOCKET` only if the socket is elsewhere),
then `systemctl --user restart companion.service`. Turn it off by removing the line; with the flag off the companion never
touches the socket. Gate: sec-review-225 F1 (fixed), F2 (this unit), F5 (privacy copy live: redeploy the site first).

## 4. Public exposure (Cloudflare tunnel, same pattern as the other services)

Add to `~/.cloudflared/config.yml` **above** the final `http_status:404` rule. Only `/v1/*` and `/hooks/*` are routed:

```yaml
  - hostname: companion.taiaroa.xyz
    path: ^/(v1|hooks)/
    service: http://localhost:8051
```

```bash
cloudflared tunnel route dns performance-portal companion.taiaroa.xyz
systemctl --user list-units | grep -i tunnel     # restart whichever unit runs ~/.cloudflared/config.yml
```

In the Cloudflare dashboard add a rate-limit rule: `/v1/enrol/start`, per IP, 5 requests per hour (the app also limits to 5/h/IP).

## 4b. Mini App (off by default)

`COMPANION_MINIAPP=1` serves the read-only Mini App (week, latest run, four lanes) under `/miniapp/` on the same host, and adds an
"Open the week" web_app button to run and recap cards. Without the flag there are no `/miniapp` routes and no button.
- Env: `COMPANION_MINIAPP=1`; `COMPANION_MINIAPP_URL` only if the host differs (default `https://companion.taiaroa.xyz/miniapp/`, https only).
- Edge: apply `deploy/nginx-miniapp.conf` (location, rate limit, tunnel path). Telegram needs HTTPS on that origin.
- Check-in consent gate: no check-in of any kind goes to a runner until the app has told the server a consent version >= 2
  (`PUT /v1/me/consent {"consent_version": n}` or `consent_version` on a run upload). Seed one runner whose build predates this:
  `.venv/bin/python -m companion.cli set-consent <chat_ref|user_id> 2` (logged as `via cli`). Run it right after the deploy.
- Menu button: `.venv/bin/python -m companion.cli set-menu-button` (sets the bot's default menu button to "My week").
- Auth: `Authorization: tma <initData>` only (HMAC with the bot token, auth_date within 1 h, user id must match a linked Telegram chat, else 403).
  There is no session token: a session older than an hour gets 401 and the page asks the runner to reopen it from the chat.
- Deploy the whole `miniapp/` directory beside `companion/`; fonts are served from the live `assets/fonts` already used by the renderer.
- Smoke: `curl -s -o /dev/null -w '%{http_code}' https://companion.taiaroa.xyz/miniapp/api/me` returns 401; a forged `Authorization: tma x` returns 401.

## 5. Telegram webhook

```bash
cd ~/run-solo/companion-server && set -a && . ~/.secrets/companion.env && set +a
.venv/bin/python -m companion.cli set-webhook https://companion.taiaroa.xyz
```

Enrolment flow (the app drives it; each step is anti-phishing by design):
1. `POST /v1/enrol/start` returns `{nonce, poll_secret, links}`. Only the app ever holds `poll_secret`; it never goes into a link or message.
2. The user opens `links.telegram` and taps Start. The bot replies with a 6-digit code ("never share it").
3. `POST /v1/enrol/status {nonce, poll_secret}` shows `pending`, then `awaiting_code`.
4. The user types the chat code into the app: `POST /v1/enrol/confirm {nonce, poll_secret, code}` returns the device token once.
   Five wrong codes lock the enrolment. An existing token is revoked only at this step.

## 6. Post-deploy smoke (read-only unless noted)

- `curl -s https://companion.taiaroa.xyz/healthz` returns 404 (not routed publicly, by design); locally it returns ok.
- `curl -s -o /dev/null -w '%{http_code}' -XPOST https://companion.taiaroa.xyz/v1/runs` returns 401.
- `curl -s -o /dev/null -w '%{http_code}' -XPOST https://companion.taiaroa.xyz/hooks/telegram` returns 403.
- Enrol as Ricki (writes one user), post a test run, confirm a Telegram card, then `DELETE` it from the chat and
  confirm `companion.cli status` shows `users=0`.

## 7. Operations

- Assets: the card and video renderer reads fonts and the brand mark from the repo's `assets/`. The render unit binds the live tree (`~/services/run-supreme-companion`, including its `assets/`) read-only and sets `COMPANION_ASSETS_DIR=~/services/run-supreme-companion/assets`; a copy elsewhere must change both. Without them media sends fall back to text.
- Media (off by default): `COMPANION_MEDIA=1` sends run and recap cards as Telegram photos, and the weekly recap as a video, rendered by the separate worker unit in section 3b (`COMPANION_RENDER_SOCKET`, default `~/companion-data/render/render.sock`). Chromium and ffmpeg never run in `companion.service`. Any worker error, timeout or missing socket sends the text card instead. `COMPANION_DEEPLINK_BASE=https://<host>/l` adds an "Open in app" button (`<base>/run/<id>`, `<base>/week/<iso-week>`); Telegram and WhatsApp reject custom schemes, so that host must redirect to `runsupreme://run/<id>` or open as an App Link. No base, no button.
- Weather (off by default): `COMPANION_WEATHER=1` lets the server look up the forecast at a runner's rounded (0.1 degree) area, but only for runners who turned on "Weather in suggestions" in the app (`users.weather_optin`). The server keeps one area per runner, deletes it 30 days after the run the area came from, on switch-off, on re-enrol and on delete (backups keep data up to 14 days). Turn on: `grep -q '^COMPANION_WEATHER=' ~/.secrets/companion.env && sed -i 's/^COMPANION_WEATHER=.*/COMPANION_WEATHER=1/' ~/.secrets/companion.env || echo 'COMPANION_WEATHER=1' >> ~/.secrets/companion.env; systemctl --user restart companion.service`.
- Check-ins (off by default): `COMPANION_CHECKINS=1` starts the evening readiness question, the morning card, the post-run question and the Sunday question (Telegram only). **Order matters: publish the privacy page with the "Check-ins" section (docs/privacy, 2b) and redeploy the site first, then turn this on** (eng-review P1: the page is live before the server collects). **Also do not enable it until the app build that lists check-ins under "What the companion knows" (S3) has shipped:** the privacy page says the app shows them. With it off nothing new is sent or stored; taps on messages already sent still work. Answers, the send ledger (`checkin_slots`) and the daily cap ledger (`question_cap`) are purged after 14 days and left out of the nightly backup. Server deploys before the app ships: the app reads `GET /v1/me/next-session` and an older server answers 404, which the app must treat as "no coach session".
- Kill switches (global, per tester, and the spend backstop) are in section 7b.
- Sentinel: alert when `curl -s localhost:8051/healthz` shows `overdue_outbox` above 0 for more than an hour. Add to the
  cron sentinel / daily ops check.
- Spend: `companion.cli status` prints this month's model spend; the cap (US$20, `COMPANION_MONTHLY_CAP_USD`) trips to template-only automatically, with alerts at 50%, 80% and 100% (section 7b).
- Backups: nightly 03:10 to `~/backups/companion/*.db.enc`, 14 day retention, AES-256-GCM (authenticated; a wrong key or
  tampering fails loudly). The snapshot is encrypted in memory; no plaintext copy touches disk. Restore:
  `.venv/bin/python -m companion.backup restore FILE.db.enc restored.db` (uses `COMPANION_BACKUP_KEY` or the default key path).
  Deleted user data ages out of backups within 14 days; the privacy page must say so.
- Retention (automatic): message log and cards 30 days, niggle answers 8 weeks, accounts with no run for 6 months are hard-deleted.
- Logs: journald via `journalctl --user -u companion`. Phone numbers, chat ids and tokens are redacted; request URLs are not logged.
- Before the first non-Ricki user: run as a dedicated system user with a 700 data dir (eng-review C3), and add the row to
  `~/ai/docs/context/claude-infrastructure.md`.

## 7b. Tester rails: enrolment cap, cost and abuse limits, kill switches

What the server does by itself:
- **Enrolment cap.** With `COMPANION_OPEN_ENROLMENT=1`, at most `COMPANION_MAX_USERS` (default 25) runners are connected. The 26th
  gets "the test is full" and nothing about them is stored (only a per-day tally, `enrol_refused`). Ricki's allowlist
  (`COMPANION_ALLOWED_IDS`) is not held to the cap and takes none of the 25 places. An unfinished connection holds a place for up to an hour, then releases it.
- **Cost.** Every writing-service call is stored with the runner it was for (`llm_calls.user_id`). The monthly cap defaults to US$20
  (`COMPANION_MONTHLY_CAP_USD`); above it the coach sends template text only. Alerts to Ricki at 50%, 80% and 100% of the cap, each once a month.
- **Per-runner ceiling.** One runner can use at most US$3 of model spend a month (`COMPANION_USER_MONTHLY_CAP_USD`); above it they get template text and an alert, so one runner cannot drain the shared US$20. A paused runner makes no model calls.
- **Rate limit.** 20 messages a minute and 200 a day per chat (`COMPANION_RATE_PER_MIN`, `COMPANION_RATE_PER_DAY`, in memory, reset
  by a restart). Over it: one polite slow-down note per 10 minutes, then silence. A connected runner slowed down 3 times in 24 hours
  (`COMPANION_RATE_STRIKES`) is paused automatically and an alert is raised. Only `ops resume` un-pauses them (their own RESUME does not).
- **Alerts** are queued in the database. The service sandbox cannot reach `notify`, so the host cron below sends them.

Commands for Ricki on the host. `OPS` is this shorthand (it loads the service secrets, as for any CLI command):

```bash
OPS='systemd-run --user --wait --pipe -p EnvironmentFile=/home/ricki28/.secrets/run-supreme-companion.env -p EnvironmentFile=/home/ricki28/.secrets/run-supreme-companion-internal.env -p WorkingDirectory=/home/ricki28/services/run-supreme-companion /home/ricki28/services/run-supreme-companion/.venv/bin/python -m companion.cli'
$OPS ops status          # runners n/25, paused counts, spend vs cap, people turned away, unsent alerts
$OPS ops roster          # one line per tester: T-number, state, last run, runs, this month's model cost. No names, no chat ids.
$OPS ops pause T3        # per-tester pause: no messages, chat ignored (DELETE still works). Their own RESUME does not undo it.
$OPS ops resume T3
$OPS ops alerts          # alerts not yet sent
$OPS ops feedback [days]  # "Tell Ricki" feedback from the last N days (default 7, max 30), newest first, T-numbers only. Kept 30 days, then purged.
```

**Kill switches, from the broadest to the narrowest**
1. **OpenRouter key limit (hard stop on money, set in the dashboard, see below).** Works even if the server misbehaves.
2. **Global pause (nothing leaves the bot):** `$OPS pause` (sends are deferred, nothing is dropped) and `$OPS resume` to undo.
   Or set `COMPANION_SENDS_PAUSED=1` in a systemd drop-in and restart (the CLI flag survives restarts; the env flag needs the drop-in removed).
3. **Stop new people joining:** remove `COMPANION_OPEN_ENROLMENT` (or set it to 0) in its drop-in, `systemctl --user daemon-reload`,
   `systemctl --user restart companion.service`. People already connected are unaffected.
4. **Stop the model spending, keep the coach:** unset the key (`COMPANION_OPENROUTER_KEY`) and restart: the coach writes from templates.
5. **One tester:** `$OPS ops pause T3`.
6. **Turn the whole service off:** `systemctl --user stop companion.service` (section 8 for the full rollback).

**One-time host setup (Ricki, once, after this is deployed)**
1. Cron for alerts, every 5 minutes (a bad `cd` makes cron silently do nothing, so the line starts with it):
   `( crontab -l 2>/dev/null; echo '*/5 * * * * cd /home/ricki28/services/run-supreme-companion && bash deploy/flush-alerts.sh >> /home/ricki28/companion-data/flush-alerts.log 2>&1' ) | crontab -`
   Check with `crontab -l | grep flush-alerts`. The first real alert (or `$OPS ops alerts` listing one that then disappears) proves the path; the alert queue itself is covered by tests.
2. Make sure no old cap overrides the new default: `grep -n MONTHLY_CAP ~/.secrets/run-supreme-companion.env ~/.secrets/run-supreme-companion-internal.env ~/.config/systemd/user/companion.service.d/*.conf`.
   If any line sets 5, change it to 20 (or delete the line) and restart the service.
3. Open enrolment last, as a recorded release step, only after the privacy page is redeployed (server first, then the site), the Play Data safety form is updated and
   the app build with the coach is in testers' hands (section 0). Write a drop-in `~/.config/systemd/user/companion.service.d/enrolment.conf` containing
   `[Service]` and `Environment=COMPANION_OPEN_ENROLMENT=1` and `Environment=COMPANION_MAX_USERS=25`, then `systemctl --user daemon-reload && systemctl --user restart companion.service`,
   then check `systemctl --user show companion.service -p Environment` and `$OPS ops status` shows `open_enrolment=on` and `places=n/25`.

**Setting the OpenRouter key limit (Ricki, in the browser; the agent does not do this).** Target: US$25 on the coach's own key
(the cap in the server is US$20, so the key limit is the backstop that still holds if the server code is wrong). The labels below are from memory of the
dashboard; if a name differs, look for the key's "credit limit".
1. Open https://openrouter.ai and sign in with the account that owns the coach key.
2. Click your avatar (top right), then **Keys** (also reachable at https://openrouter.ai/settings/keys).
3. Find the key that is `COMPANION_OPENROUTER_KEY` (not your general key). If you are not sure which one: the key list shows a "last used" time; the coach's key is the one used within the last day.
4. Click that key's name (or its **Edit** / pencil button) to open its settings.
5. In **Credit limit**, enter `25` (US dollars). If there is a **Limit reset** option, choose **Monthly** so it renews on the 1st, matching the server cap; otherwise leave it and re-check each month.
6. Click **Save** / **Update**. The key row should now show "$25" as its limit.
7. Check it: reopen the key and read the limit back. Tell the agent "key limit set" so the digest records it.
If the key is ever refused (HTTP 402), the coach already falls back to template text; no action is needed beyond raising the limit.

## 7b2. Coach chat (C1, off by default; do not enable from this PR)

Free text from a gated runner goes to a Sonnet agent loop with read-only tools (`companion/coach/`). Every one of these
must be true for a message to reach the model: `COMPANION_COACH_CHAT=1`, the runner in `COMPANION_COACH_ALLOWLIST`
(user ids, T-numbers like `T1`, or `telegram:<chat id>`), the app's consent at or above `COMPANION_COACH_CONSENT_REQUIRED`
(3), not paused and not ops-paused. Before turning it on: the privacy page and consent v3 (C4) are live, the OpenRouter
account-level ZDR toggle is on, the eval gate has passed for the deployed `prompt_hash` (logged at start-up as
`coach chat on: prompt_hash=...`), and Ricki's consent is recorded with `companion.cli set-consent <chat_ref> 3` (W6; the
allowlist never bypasses consent).

- Prompt: compiled at start-up from `coach/` (`COMPANION_COACH_DIR`, default the repo's `coach/`) by `coach/scripts/build_prompt.py`.
  A skill that does not compile keeps the chat off. Deploy the `coach/` dir from the same reviewed commit as the server.
- Model and caps: `COMPANION_COACH_MODEL` (default `anthropic/claude-sonnet-5.5`), every call with `provider: {zdr, data_collection:
  deny, allow_fallbacks: false}`. `COMPANION_COACH_MONTHLY_CAP_USD` (50, all model spend, cards included, with
  `COMPANION_COACH_CARD_RESERVE_USD` kept back for cards), `COMPANION_COACH_DAILY_MSGS` (40) and `COMPANION_COACH_DAILY_USD`
  (1.5) per runner per UTC day, counted from the database. Alerts at 50/80/100% of the coach cap and when more than 20% of
  replies in 24 hours fall back to the template.
- Red flags, two layers. (1) Regex, hard tier (unambiguous: chest pain, collapsed, suicide, overdose): the fixed reply at
  once, in the webhook, before any cap or model; also on the merged turn, notes, Tell Ricki feedback and a paused runner's
  text. (2) Every other coach turn goes to a safety classifier first (`COMPANION_COACH_SCREEN_MODEL`, default
  `anthropic/claude-haiku-5.5`, same ZDR settings, max_tokens 60, 5 s, cost in the ledger). A classifier hit gets the fixed
  reply and no main model call. If the classifier fails, a soft regex hit (ambiguous words: dizzy, breath, dead, kms,
  pointless) still gets the fixed reply; a turn with no regex hit goes on to the main model, and more than 5% classifier
  errors in 24 hours raises an alert. Measure the real classifier with `OPENROUTER_API_KEY=... python3
  scripts/redflag_eval.py` before enabling. A fixed reply by country
  (NZ, AU, UK and US lines verified; ZA, SG and unknown get the emergency number and "your local crisis line"), a health
  flag and one alert per runner, kind and day. A safety reply that cannot be delivered after 5 tries raises its own alert.
  Clear a flag: `companion.cli ops clear-flag T<n> <urgent|wellbeing|ill|injury>`.
- Daily caps reset at the runner's local midnight.
- **C1 allowlist: only runners whose time zone maps to NZ, AU, UK or US** (the countries with verified crisis lines). The
  fixed reply is country-correct everywhere, but the chat validator accepts any crisis number, so a model reply could
  quote another country's line; per-country checking comes with C4.
- Cache hits: each call logs `prompt_tokens`, `cached_tokens` and `cache_write`; check the first 20 real messages (W5).
- Retention: `coach_messages` and `coach_jobs` 30 days, left out of the nightly backup; `cost_ledger` 400 days with the runner
  id cleared on DELETE. Dropping consent below 3 deletes the chat history at once.

## 7c. `ops send` (approved tester messages)

`python -m companion.cli ops send --tester T3 --template N1|N2|N3|INVITE [--dry-run]`, `ops sends`, `ops templates [--link URL]`.
It queues one message; the tick sends it through the normal rails (consent v2, quiet hours, kill switches, STOP, one ops
message per tester per 7 days, 10 a day). Nothing is approved until Ricki approves it.

- Texts: `~/ai/state/run-supreme-testers/templates-draft.md` (the `> ` lines). Approval: `templates-approved.json`
  (`{"approved": [{"id": "N1", "sha256": "..."}]}`; INVITE and N3 also carry `"link": "https://calendar.app.google/..."`, and
  the hash covers the message with that link in it). Get the hash from `ops templates` (`--link URL` for the link ones).
  Links must be https on `calendar.app.google` or `calendar.google.com`.
- **Unit must be reinstalled** for the server to see that folder: `deploy/companion.service` now binds it read-only and sets
  `COMPANION_OPS_STATE_DIR`. Until Ricki/main copies the unit and runs `systemctl --user daemon-reload` and a restart, every
  queued ops message is skipped as "approval withdrawn". Do not run sudo for this; it is a user unit.
- **What the gate is, and is not.** The draft and approval files are writable by `ricki28`, the same user the agents run as. The
  hash check stops accidents (an edited draft, a stale approval, a wrong link). It does not stop a determined agent running as
  ricki28 from editing both files. Ricki decides whether to make the approval file root-owned or `chattr +i` it between edits.
- The audit (`ops_sends`: tester, template, hash, time, result) is deleted with the user, appears in the runner's own export as
  template and date only, and is purged on `COMPANION_TEST_END_DATE` (default 2026-12-15).

## 7d. Daily concierge and Monday digest (`ops_jobs/`)

Both run from the deployed tree, read the database read-only and do their work through `companion.cli ops` (override with `RS_OPS_CMD`). Neither is installed by this repo. Crontab lines (cd first; times are UTC):

```
# cron has no user bus; `systemd-run --user` (the ops command) needs these two lines at the top of the crontab
XDG_RUNTIME_DIR=/run/user/1000
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
# rs-concierge, 09:00 SGT daily from 20 Oct. Dry run: decisions only. Add --apply only after Ricki approves the templates (7c).
0 1 * * * cd ~/services/run-supreme-companion && .venv/bin/python ops_jobs/concierge.py >> ~/ai/state/run-supreme-testers/concierge.log 2>&1
# rs-digest, Monday 07:00 SGT = Sunday 23:00 UTC. Add RS_TELEGRAM_ENV_FILE=<file with TELEGRAM_BOT_TOKEN> for the real send.
0 23 * * 0 cd ~/services/run-supreme-companion && .venv/bin/python ops_jobs/digest.py >> ~/ai/state/run-supreme-testers/digest.log 2>&1
```

- Concierge: no model. N1 (no run by day 3), N2 (silent 7 days), N3 (chat invite, week 3, needs `--link` or `RS_BOOKING_LINK`). It only asks `ops send` for what is due; `ops send` still refuses unapproved templates, paused runners, repeats and anything inside 7 days of the last ops message. Log: `~/ai/state/run-supreme-testers/concierge-YYYY-MM-DD.md` (`-dryrun` suffix without `--apply`).
- Digest: writes `digest-YYYY-WW.md` (private: contains feedback text, which never goes to the model or Telegram). A 6-line numbers-only summary goes to Ricki's topic only. `--dry-run` prints it instead of sending; `--no-narrative` skips `claude -p`. It files no GitHub issues; it lists candidates.
- Exit codes: 3 = the ops command could not run (concierge), or the digest refused to send because an ops call or the scorecard failed. `--dry-run` writes nothing but the digest file; it reads the newest scorecard snapshot already on disk.
- Smoke without sending: `python3 ops_jobs/concierge.py --no-log` and `python3 ops_jobs/digest.py --dry-run --no-narrative`.

## 8. Rollback

`systemctl --user disable --now companion.service`, remove the tunnel ingress block, and (if needed)
`curl "https://api.telegram.org/bot<token>/deleteWebhook"`. Data stays in `~/companion-data` until deleted.

## 9. Coach replay (history through the live bot)

Replays a runner's real history on a virtual clock: `python -m companion.cli replay <facts_dir> --every 300 [--dry-run [--full]] [--from YYYY-MM-DD]`.

Controls:
- `replay-stop`: a running replay finishes its current message, saves and stops. Run the same `replay` command to resume.
- `replay-abort`: asks a running process to stop and waits for it. If it does not stop, nothing is released; stop the unit (`systemctl --user stop companion-replay`) and run it again. Then the user goes back to the live coach and the replay's queued past items are dropped.
- `replay <dir> --fresh [--dry-run]`: first removes only what a replay created for the user (replayed runs, their cards, queued items, convo rows, notes, replay-dated memory and caps), told apart from real uploads by the replay's own marks or its virtual timestamps, then starts at item 1. A real upload (including a replayed run the app has since uploaded) is never touched; it refuses if it cannot tell them apart or a replay is running. `--dry-run` prints what would be removed.
- `replay-reset`: forget a finished or aborted replay so a new one can start (cards already sent stay sent).
- The existing `pause` holds the replay without losing items.

Notes:
1. Restart `companion.service` on the merged code first. The live worker refreshes `replay_aware_at` every tick; `replay` refuses to start unless it is under 10 minutes old, because an older worker would send the replay's virtual-past items at once.
2. Facts: `cd packages/run_engine && dart run tool/companion_facts.dart <export_dir> <facts_dir> [--max-hr N] [--age N] [--rest-hr N] [--no-route]` writes one JSON per run, exactly the body the app POSTs (including the route shape, per-km splits and rep times; `--no-route` is the app's "Show route shape on cards" switch off), sorted by start. Not derivable (absent, as in the app today): scores_delta, route_id, load_state, pb, plan_*, area_lat/lon. HR zones come from the options (default 190 max HR); locality only if the sidecar has it.
3. While a replay runs, the live worker leaves that user's replay items, planning and retention alone. The hold is bounded: it lapses 15 minutes after the last heartbeat of a running replay, or 48 hours after a stop, and the user is then released automatically (queued past items skipped, `replay auto-released` in the journal).
4. A real run uploaded during a replay is sent live and straight away, without the "Replay" line. A real upload of a run the replay is walking through updates it in place (no second card); a real upload of an old run before the replay reaches it keeps that run's replay card.
5. Taps are recorded by the live webhook as usual and dated on the card's own virtual clock. Media follows `COMPANION_MEDIA`, as live: run and recap cards go through the render worker, text on any failure, with the "Replay" line in the caption.
6. Health: `/healthz` also reports `replay_held`. `overdue_outbox` counts a held user's overdue items unless the replay has a heartbeat under 5 minutes old, so a stalled or forgotten replay trips the existing sentinel.
7. Run `--dry-run` first: the whole schedule on a scratch copy of the database (template phrasing, no taps), nothing sent.

Measurement (Phase A): `python -m companion.cli ops scorecard-snapshot [dir]` writes `scorecard-YYYY-WW.json` (T-numbers only; default `~/ai/state/run-supreme-testers`). Run it weekly from the host cron, because cards purge at 30 days. `python -m companion.scorecard --db PATH` prints the gate with n/N per signal (a percentage only from 8 answers). Survey answers (`survey_answers`) are kept until the test ends: delete them by hand afterwards.
