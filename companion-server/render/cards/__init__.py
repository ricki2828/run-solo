"""Run Supreme card renderer. Each render_<card>(facts, memory) -> PNG bytes; see fixtures.py for the fact shapes."""
from .coach import render_moved, render_pinned_week, render_today, render_today_verdict
from .countdown import render_race_countdown
from .milestone import render_milestone
from .monthly import render_monthly_poster
from .pb import render_pb
from .post_run import render_post_run
from .share import render_share_card
from .suggestion import render_suggestion
from .trail import render_trail_board, render_trail_record
from .weekly import render_weekly_recap

__all__ = ["render_post_run", "render_pb", "render_suggestion", "render_weekly_recap", "render_race_countdown",
           "render_milestone", "render_monthly_poster", "render_share_card", "render_today", "render_today_verdict",
           "render_moved", "render_pinned_week", "render_trail_board", "render_trail_record"]
