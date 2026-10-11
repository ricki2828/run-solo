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
- Kill switch: `python -m companion.cli pause` (sends defer, nothing is dropped) / `resume`. `COMPANION_SENDS_PAUSED=1` does the same via env.
- Sentinel: alert when `curl -s localhost:8051/healthz` shows `overdue_outbox` above 0 for more than an hour. Add to the
  cron sentinel / daily ops check.
- Spend: `companion.cli status` prints this month's model spend; the cap trips to template-only automatically.
- Backups: nightly 03:10 to `~/backups/companion/*.db.enc`, 14 day retention, AES-256-GCM (authenticated; a wrong key or
  tampering fails loudly). The snapshot is encrypted in memory; no plaintext copy touches disk. Restore:
  `.venv/bin/python -m companion.backup restore FILE.db.enc restored.db` (uses `COMPANION_BACKUP_KEY` or the default key path).
  Deleted user data ages out of backups within 14 days; the privacy page must say so.
- Retention (automatic): message log and cards 30 days, niggle answers 8 weeks, accounts with no run for 6 months are hard-deleted.
- Logs: journald via `journalctl --user -u companion`. Phone numbers, chat ids and tokens are redacted; request URLs are not logged.
- Before the first non-Ricki user: run as a dedicated system user with a 700 data dir (eng-review C3), and add the row to
  `~/ai/docs/context/claude-infrastructure.md`.

## 8. Rollback

`systemctl --user disable --now companion.service`, remove the tunnel ingress block, and (if needed)
`curl "https://api.telegram.org/bot<token>/deleteWebhook"`. Data stays in `~/companion-data` until deleted.
