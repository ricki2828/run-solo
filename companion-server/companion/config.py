"""Settings, read from the environment. Secrets never have defaults and are never logged."""
from __future__ import annotations

import logging
import os
from datetime import date
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


DEFAULT_TEST_END = "2026-12-15"


def _iso_date(v: str | None, default: str = DEFAULT_TEST_END) -> str:
    """A YYYY-MM-DD date, else the default (with a warning): a bad value must never make the purge fire on every tick."""
    try:
        return date.fromisoformat((v or "").strip()).isoformat()
    except ValueError:
        if (v or "").strip():
            logging.getLogger("companion").warning("COMPANION_TEST_END_DATE %r is not YYYY-MM-DD: using %s", v, default)
        return default


def _nonneg(v: str | None, default: int) -> int:
    try:
        n = int((v or "").strip())
    except ValueError:
        return default
    return n if n >= 0 else default


def _posint(v: str | None, default: int) -> int:
    """A positive whole number, else the default (a typo must not turn a limit off)."""
    try:
        n = int((v or "").strip())
    except ValueError:
        return default
    return n if n > 0 else default


def _posfloat(v: str | None, default: float) -> float:
    """A positive number, else the default (a typo must not turn a cap off)."""
    try:
        n = float((v or "").strip())
    except ValueError:
        return default
    return n if n > 0 else default


def default_coach_dir() -> str:
    """The skill lives at the repo root (`coach/`), next to companion-server/."""
    return os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "coach")


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
    # With open enrolment on, at most this many runners may be connected at once. Runners on the allowlist neither count
    # towards it nor are held to it; an unfinished connection holds a place for up to an hour. Tester programme: 25.
    max_users: int = 25
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
    monthly_cap_usd: float = 20.0  # OpenRouter key limit on the dashboard is the hard backstop (DEPLOY.md, kill switches)
    # One runner's ceiling inside the shared cap, so one runner cannot drain it for everyone (templates only above it).
    user_monthly_cap_usd: float = 3.0
    # Spend alerts to Ricki, as fractions of the monthly cap (each fires once a month).
    cap_alert_fractions: tuple[float, ...] = (0.5, 0.8, 1.0)
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
    trail_clip: bool = True       # a trail record with a ghost series goes out as the race clip, not the still (COMPANION_TRAIL_CLIP=0)
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
    # The last day of the closed test (YYYY-MM-DD). From that day the tick deletes the tester-programme audit (ops_sends).
    test_end_date: str = DEFAULT_TEST_END
    # Telegram Mini App (read-only week, latest run and lanes), served under /miniapp/. Off by default.
    miniapp_enabled: bool = False
    miniapp_url: str = "https://companion.taiaroa.xyz/miniapp/"  # what the web_app buttons open

    # Inbound rate limit per chat (in memory). Over it the chat gets one polite slow-down note, then silence.
    # `rate_strikes_to_pause` slow-downs inside 24 hours pause a known runner (ops_paused) and raise an alert.
    rate_per_min: int = 20
    rate_per_day: int = 200
    rate_strikes_to_pause: int = 3

    # Coach chat (C1): free text from a gated runner goes to a model with read-only tools. Off by default; the gate is
    # COMPANION_COACH_CHAT and the allowlist and consent at or above coach_consent_required (eng-review B1).
    coach_chat: bool = False
    # Who may use it: user ids (u_...), T-numbers (T3) or "telegram:<chat id>". Empty = nobody, even with the flag on.
    coach_allowlist: frozenset[str] = frozenset()
    coach_consent_required: int = 3
    coach_model: str = "anthropic/claude-sonnet-5.5"
    # All model spend in a month (cards + chat). Chat stops when it would cross the cap less what the cards still have
    # reserved (coach_card_reserve_usd minus the cards' spend this month), so chat can never starve the cards.
    coach_monthly_cap_usd: float = 50.0
    coach_card_reserve_usd: float = 5.0
    # Per runner, per UTC day, counted from the database (a restart does not reset them, eng-review B9).
    coach_daily_msgs: int = 40
    coach_daily_usd: float = 1.5
    coach_max_tokens: int = 2000   # Sonnet 5.5 thinking is mandatory and counts here
    coach_max_tool_turns: int = 6
    coach_turn_timeout_s: float = 30.0
    coach_job_deadline_s: float = 60.0
    coach_job_deadline_tool_s: float = 90.0   # a job that called a slow tool (web search) may run this long
    # The safety classifier (coach/screen.py): every coach turn the hard regex tier did not answer, before the main model.
    coach_screen_model: str = "anthropic/claude-haiku-5.5"
    coach_screen_timeout_s: float = 5.0
    coach_screen_max_tokens: int = 60
    coach_merge_s: float = 2.0     # messages a runner sends within this long of each other are answered as one turn
    coach_briefing: bool = False      # COMPANION_COACH_BRIEFING: the briefing kill switch, off by default; needs the chat gates too
    coach_briefing_daily: int = 8     # briefing model calls per runner per local day (a retry counts)
    coach_briefing_ttl_h: float = 36.0   # a stored briefing is served for this long after it was generated
    coach_repair_turns: int = 1    # extra model turns after a validator miss, with the reason, before the template
    coach_show_cost: frozenset[str] = frozenset()   # runners (same forms as the allowlist) who see a cost/latency footer on replies
    coach_proactive: bool = False     # COMPANION_COACH_PROACTIVE: the proactive coach (niggle check-back, heat heads-up, race debrief), off by default; needs the chat gates too
    coach_proactive_tick_s: float = 60.0
    coach_proactive_allowlist: frozenset[str] = frozenset()   # COMPANION_COACH_PROACTIVE_ALLOWLIST: proactive needs this AND the chat allowlist; empty = nothing sent
    coach_history: int = 12        # earlier chat messages sent with each turn
    # Reservation estimates (USD per million tokens); the settle uses the cost OpenRouter reports.
    coach_usd_per_mtok_in: float = 3.0
    coach_usd_per_mtok_out: float = 15.0
    coach_dir: str = field(default_factory=default_coach_dir)

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
            max_users=_posint(e.get("COMPANION_MAX_USERS"), 25),
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
            monthly_cap_usd=float(e.get("COMPANION_MONTHLY_CAP_USD", "20")),
            user_monthly_cap_usd=float(e.get("COMPANION_USER_MONTHLY_CAP_USD", "3")),
            weather_enabled=_flag(e.get("COMPANION_WEATHER")),
            media_enabled=_flag(e.get("COMPANION_MEDIA")),
            trail_cards=e.get("COMPANION_TRAIL_CARDS", "1").strip().lower() not in ("0", "false", "no", "off"),
            trail_clip=e.get("COMPANION_TRAIL_CLIP", "1").strip().lower() not in ("0", "false", "no", "off"),
            trail_spoiler=e.get("COMPANION_TRAIL_SPOILER", "1").strip().lower() not in ("0", "false", "no", "off"),
            render_socket=os.path.expanduser(e.get("COMPANION_RENDER_SOCKET", "~/companion-data/render/render.sock")),
            deeplink_base=_https_base(e.get("COMPANION_DEEPLINK_BASE")),
            checkins_enabled=_flag(e.get("COMPANION_CHECKINS")),
            miniapp_enabled=_flag(e.get("COMPANION_MINIAPP")),
            miniapp_url=(_https_base(e.get("COMPANION_MINIAPP_URL")) or "https://companion.taiaroa.xyz/miniapp").rstrip("/") + "/",
            rate_per_min=_posint(e.get("COMPANION_RATE_PER_MIN"), 20),
            rate_per_day=_posint(e.get("COMPANION_RATE_PER_DAY"), 200),
            rate_strikes_to_pause=_posint(e.get("COMPANION_RATE_STRIKES"), 3),
            test_end_date=_iso_date(e.get("COMPANION_TEST_END_DATE")),
            sends_paused=_flag(e.get("COMPANION_SENDS_PAUSED")),
            coach_chat=_flag(e.get("COMPANION_COACH_CHAT")),
            coach_allowlist=_csv(e.get("COMPANION_COACH_ALLOWLIST")),
            coach_consent_required=_posint(e.get("COMPANION_COACH_CONSENT_REQUIRED"), 3),
            coach_model=(e.get("COMPANION_COACH_MODEL") or "anthropic/claude-sonnet-5.5").strip(),
            coach_monthly_cap_usd=_posfloat(e.get("COMPANION_COACH_MONTHLY_CAP_USD"), 50.0),
            coach_card_reserve_usd=_posfloat(e.get("COMPANION_COACH_CARD_RESERVE_USD"), 5.0),
            coach_daily_msgs=_posint(e.get("COMPANION_COACH_DAILY_MSGS"), 40),
            coach_daily_usd=_posfloat(e.get("COMPANION_COACH_DAILY_USD"), 1.5),
            coach_repair_turns=min(_nonneg(e.get("COMPANION_COACH_REPAIR_TURNS"), 1), 2),
            coach_show_cost=_csv(e.get("COMPANION_COACH_SHOW_COST")),
            coach_briefing=_flag(e.get("COMPANION_COACH_BRIEFING")),
            coach_proactive=_flag(e.get("COMPANION_COACH_PROACTIVE")),
            coach_proactive_allowlist=_csv(e.get("COMPANION_COACH_PROACTIVE_ALLOWLIST")),
            coach_briefing_daily=_posint(e.get("COMPANION_COACH_BRIEFING_DAILY"), 8),
            coach_max_tokens=_posint(e.get("COMPANION_COACH_MAX_TOKENS"), 2000),
            coach_screen_model=(e.get("COMPANION_COACH_SCREEN_MODEL") or "anthropic/claude-haiku-5.5").strip(),
            coach_max_tool_turns=min(_posint(e.get("COMPANION_COACH_MAX_TOOL_TURNS"), 6), 6),
            coach_dir=os.path.expanduser(e.get("COMPANION_COACH_DIR") or default_coach_dir()),
        )
