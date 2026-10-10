"""Sample specs for previews and tests, built from the shared fixtures in render/cards/fixtures.py (the same
facts the cards and the conversation layer use), so splits, reps, routes and weekly numbers come from one place."""
from __future__ import annotations

from ..cards import fixtures
from .run_video import RunVideoSpec, spec_from_facts
from .weekly_video import WeeklySpec, weekly_from_facts

RUN_FACTS = {"milos": fixtures.milos_trail, "intervals": fixtures.singapore_intervals, "slow": fixtures.slow_hot_day,
             "pb": fixtures.pb_5k}


def facts(which: str) -> dict:
    return RUN_FACTS[which]()


def run_spec(which: str) -> RunVideoSpec:
    return spec_from_facts(facts(which))


def weekly_facts() -> dict:
    return fixtures.weekly_recap()


def weekly() -> WeeklySpec:
    return weekly_from_facts(weekly_facts())
