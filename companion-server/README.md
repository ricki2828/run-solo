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

API: `POST /v1/enrol/start` (returns nonce + poll_secret), `POST /v1/enrol/status`, `POST /v1/enrol/confirm` (chat code, returns the token), `POST /v1/runs`, `PATCH /v1/runs/{id}/feel`, `GET|DELETE /v1/me`,
`PUT /v1/me/settings`, webhooks `/hooks/telegram` and `/hooks/whatsapp`. See `DEPLOY.md` for deployment.
