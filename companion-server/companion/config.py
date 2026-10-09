"""Settings, read from the environment. Secrets never have defaults and are never logged."""
from __future__ import annotations

import os
from dataclasses import dataclass, field


def _csv(v: str | None) -> frozenset[str]:
    return frozenset(x.strip() for x in (v or "").split(",") if x.strip())


def _flag(v: str | None) -> bool:
    return (v or "").strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    db_path: str
    pepper: bytes = field(repr=False)
    # "telegram:<chat id>" / "whatsapp:<number>". Only these may enrol until open_enrolment is on.
    allowed_ids: frozenset[str] = frozenset()
    open_enrolment: bool = False  # flipping this is a recorded release step (eng-review B2)
    consent_version: str = "1"

    telegram_token: str | None = field(default=None, repr=False)
    telegram_bot: str | None = None
    telegram_webhook_secret: str | None = field(default=None, repr=False)
    telegram_api: str = "https://api.telegram.org"

    wa_enabled: bool = False
    wa_number: str | None = None  # business number for the wa.me deep link
    wa_phone_id: str | None = None
    wa_token: str | None = field(default=None, repr=False)
    wa_app_secret: str | None = field(default=None, repr=False)
    wa_verify_token: str | None = field(default=None, repr=False)
    wa_api: str = "https://graph.facebook.com/v21.0"
    wa_template: str = "run_card"
    wa_template_lang: str = "en"

    openrouter_key: str | None = field(default=None, repr=False)
    openrouter_url: str = "https://openrouter.ai/api/v1"
    model: str = "anthropic/claude-haiku-4.5"
    monthly_cap_usd: float = 5.0
    llm_timeout_s: float = 8.0
    # Used only when the response carries no usage.cost.
    est_usd_per_mtok_in: float = 1.0
    est_usd_per_mtok_out: float = 5.0

    sends_paused: bool = False
    stale_card_hours: float = 6.0
    default_quiet: tuple[int, int] = (21 * 60 + 30, 7 * 60)  # minutes after local midnight

    @property
    def telegram_enabled(self) -> bool:
        return bool(self.telegram_token and self.telegram_webhook_secret)

    @property
    def wa_ready(self) -> bool:
        return bool(
            self.wa_enabled and self.wa_phone_id and self.wa_token
            and self.wa_app_secret and self.wa_verify_token
        )

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Settings":
        e = os.environ if env is None else env
        pepper = e.get("COMPANION_PEPPER")
        if not pepper or len(pepper) < 16:
            raise RuntimeError("COMPANION_PEPPER must be set (16+ chars)")
        key = e.get("COMPANION_OPENROUTER_KEY")
        if not key and _flag(e.get("COMPANION_ALLOW_SHARED_KEY")):
            key = e.get("OPENROUTER_API_KEY")  # dogfood only
        return cls(
            db_path=e.get("COMPANION_DB", os.path.expanduser("~/companion-data/companion.db")),
            pepper=pepper.encode(),
            allowed_ids=_csv(e.get("COMPANION_ALLOWED_IDS")),
            open_enrolment=_flag(e.get("COMPANION_OPEN_ENROLMENT")),
            consent_version=e.get("COMPANION_CONSENT_VERSION", "1"),
            telegram_token=e.get("COMPANION_TELEGRAM_TOKEN"),
            telegram_bot=e.get("COMPANION_TELEGRAM_BOT"),
            telegram_webhook_secret=e.get("COMPANION_TELEGRAM_WEBHOOK_SECRET"),
            wa_enabled=_flag(e.get("COMPANION_WA_ENABLED")),
            wa_number=e.get("COMPANION_WA_NUMBER"),
            wa_phone_id=e.get("COMPANION_WA_PHONE_ID"),
            wa_token=e.get("COMPANION_WA_TOKEN"),
            wa_app_secret=e.get("COMPANION_WA_APP_SECRET"),
            wa_verify_token=e.get("COMPANION_WA_VERIFY_TOKEN"),
            wa_template=e.get("COMPANION_WA_TEMPLATE", "run_card"),
            openrouter_key=key,
            model=e.get("COMPANION_MODEL", "anthropic/claude-haiku-4.5"),
            monthly_cap_usd=float(e.get("COMPANION_MONTHLY_CAP_USD", "5")),
            sends_paused=_flag(e.get("COMPANION_SENDS_PAUSED")),
        )
