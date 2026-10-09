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
cd companion-server && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt   # check `free -m` first
.venv/bin/python -m pytest                                                                   # must be green

mkdir -p ~/.secrets ~/companion-data ~/backups/companion && chmod 700 ~/companion-data ~/backups/companion
cp deploy/companion.env.example ~/.secrets/companion.env && chmod 600 ~/.secrets/companion.env
# edit it: pepper, secrets, allowed ids, tokens (do not paste secrets into chat or logs)
openssl rand -hex 24 > ~/.secrets/companion-backup.key && chmod 600 ~/.secrets/companion-backup.key
```

Back up `companion-backup.key` somewhere safe: without it the backups cannot be restored.

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

Then in the bot DM: the app (or `curl -XPOST https://companion.taiaroa.xyz/v1/enrol/start`) gives a nonce; open
`https://t.me/<bot>?start=<nonce>`; poll `GET /v1/enrol/status?nonce=...` for the device token (returned once).

## 6. Post-deploy smoke (read-only unless noted)

- `curl -s https://companion.taiaroa.xyz/healthz` returns 404 (not routed publicly, by design); locally it returns ok.
- `curl -s -o /dev/null -w '%{http_code}' -XPOST https://companion.taiaroa.xyz/v1/runs` returns 401.
- `curl -s -o /dev/null -w '%{http_code}' -XPOST https://companion.taiaroa.xyz/hooks/telegram` returns 403.
- Enrol as Ricki (writes one user), post a test run, confirm a Telegram card, then `DELETE` it from the chat and
  confirm `companion.cli status` shows `users=0`.

## 7. Operations

- Kill switch: `python -m companion.cli pause` (sends defer, nothing is dropped) / `resume`. `COMPANION_SENDS_PAUSED=1` does the same via env.
- Sentinel: alert when `curl -s localhost:8051/healthz` shows `overdue_outbox` above 0 for more than an hour. Add to the
  cron sentinel / daily ops check.
- Spend: `companion.cli status` prints this month's model spend; the cap trips to template-only automatically.
- Backups: nightly 03:10 to `~/backups/companion/*.db.enc`, 14 day retention, AES-256 via openssl. Restore:
  `openssl enc -d -aes-256-cbc -pbkdf2 -in FILE.db.enc -out restored.db -pass file:$HOME/.secrets/companion-backup.key`.
  Deleted user data ages out of backups within 14 days; the privacy page must say so.
- Retention (automatic): message log and cards 30 days, niggle answers 8 weeks, accounts with no run for 6 months are hard-deleted.
- Logs: journald via `journalctl --user -u companion`. Phone numbers, chat ids and tokens are redacted; request URLs are not logged.
- Before the first non-Ricki user: run as a dedicated system user with a 700 data dir (eng-review C3), and add the row to
  `~/ai/docs/context/claude-infrastructure.md`.

## 8. Rollback

`systemctl --user disable --now companion.service`, remove the tunnel ingress block, and (if needed)
`curl "https://api.telegram.org/bot<token>/deleteWebhook"`. Data stays in `~/companion-data` until deleted.
