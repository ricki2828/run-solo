"""Settings, read from the environment. Secrets never have defaults and are never logged."""
from __future__ import annotations

import os
from dataclasses import dataclass, field


def _csv(v: str | None) -> frozenset[str]:
    return frozenset(x.strip() for x in (v or "").split(",") if x.strip())


def _flag(v: str | None) -> bool:
    return (v or "").strip().lower() in {"1", "true", "yes", "on"}


def _url_index(v: str | None) -> int:
    """Meta allows at most 10 buttons, so a template's URL button sits at 0..9. Anything else falls back to 3."""
    try:
        n = int((v or "3").strip())
    except ValueError:
        return 3
    return n if 0 <= n <= 9 else 3


def _https_base(v: str | None) -> str | None:
    v = (v or "").strip().rstrip("/")
    return v if v.startswith("https://") and len(v) > 8 and not any(c in v for c in " ?#") else None


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
    wa_url_index: int = 3  # the template's fixed button slot for the dynamic-URL button (after 3 quick replies)

    openrouter_key: str | None = field(default=None, repr=False)
    openrouter_url: str = "https://openrouter.ai/api/v1"
    model: str = "anthropic/claude-haiku-4.5"
    monthly_cap_usd: float = 5.0
    llm_timeout_s: float = 8.0
    # Used only when the response carries no usage.cost.
    est_usd_per_mtok_in: float = 1.0
    est_usd_per_mtok_out: float = 5.0

    # Open-Meteo weather for touches and suggestions. Off by default: it sends a lat/lon cell rounded to 0.1 degree
    # to a third party, which the privacy page says (section 2b). Even with this on, a user's area is stored and
    # sent only after the app's "Weather in suggestions" switch (users.weather_optin).
    weather_enabled: bool = False

    # Cards and videos as Telegram photos/videos. Off by default: it needs Chromium (and ffmpeg for video) on the host.
    media_enabled: bool = False
    trail_cards: bool = True      # trail board and trail record cards (COMPANION_TRAIL_CARDS=0 turns them off)
    trail_spoiler: bool = True    # trail cards go out with Telegram's has_spoiler: a tap to reveal (COMPANION_TRAIL_SPOILER=0)
    # Unix socket of the render worker (deploy/companion-render.service). COMPANION_MEDIA=1 means "use this socket";
    # Chromium and ffmpeg never run in the companion process.
    render_socket: str = "~/companion-data/render/render.sock"
    # https base the deep-link buttons point at (`<base>/run/<id>`, `<base>/week/<iso-week>`); no base, no link buttons.
    deeplink_base: str | None = None

    # Check-ins (evening readiness, morning card, post-run and Sunday questions). Off until the privacy page that
    # describes them is published and the site redeployed (eng-review P1); taps on messages already sent still work.
    checkins_enabled: bool = False
    # The app's kCompanionConsentVersion that covers check-in data (lib/state/companion.dart). A runner whose app has not
    # told the server it agreed to at least this version gets no check-in of any kind.
    checkin_consent_required: int = 2
    # Telegram Mini App (read-only week, latest run and lanes), served under /miniapp/. Off by default.
    miniapp_enabled: bool = False
    miniapp_url: str = "https://companion.taiaroa.xyz/miniapp/"  # what the web_app buttons open

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
            wa_url_index=_url_index(e.get("COMPANION_WA_URL_INDEX")),
            openrouter_key=key,
            model=e.get("COMPANION_MODEL", "anthropic/claude-haiku-4.5"),
            monthly_cap_usd=float(e.get("COMPANION_MONTHLY_CAP_USD", "5")),
            weather_enabled=_flag(e.get("COMPANION_WEATHER")),
            media_enabled=_flag(e.get("COMPANION_MEDIA")),
            trail_cards=e.get("COMPANION_TRAIL_CARDS", "1").strip().lower() not in ("0", "false", "no", "off"),
            trail_spoiler=e.get("COMPANION_TRAIL_SPOILER", "1").strip().lower() not in ("0", "false", "no", "off"),
            render_socket=os.path.expanduser(e.get("COMPANION_RENDER_SOCKET", "~/companion-data/render/render.sock")),
            deeplink_base=_https_base(e.get("COMPANION_DEEPLINK_BASE")),
            checkins_enabled=_flag(e.get("COMPANION_CHECKINS")),
            miniapp_enabled=_flag(e.get("COMPANION_MINIAPP")),
            miniapp_url=(_https_base(e.get("COMPANION_MINIAPP_URL")) or "https://companion.taiaroa.xyz/miniapp").rstrip("/") + "/",
            sends_paused=_flag(e.get("COMPANION_SENDS_PAUSED")),
        )
