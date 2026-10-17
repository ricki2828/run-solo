"""The trust question must not collide with Sunday's recap + 19:05 shape check-in: it goes out in the evening of a later day."""
from test_checkins import at, env  # noqa: F401  (env is a fixture)


def test_real_sunday_recap_then_shape_then_trust_on_monday(env):
    env.run("sat", at(2026, 10, 24, 7, 0), now=at(2026, 10, 24, 20, 0),
            plan_next={"type": "quality", "day": "2026-10-27", "week": 4, "distance_m": 6000})
    for t in (at(2026, 10, 25, 19, 1), at(2026, 10, 25, 19, 3)):
        env.svc.tick(t)
    assert "recap" in [r["kind"] for r in env.q("SELECT kind FROM cards")]
    for m in (6, 10, 15, 30, 45):
        env.svc.tick(at(2026, 10, 25, 19, m))
    assert any(s["text"].startswith("Next week\nHow many runs") for s in env.sends())   # the shape check-in still goes out
    assert env.q("SELECT COUNT(*) n FROM cards WHERE kind='trust'")[0]["n"] == 0        # trust waits for a later day
    env.svc.tick(at(2026, 10, 26, 19, 40))
    env.svc.tick(at(2026, 10, 26, 19, 41))
    env.svc.run_outbox(at(2026, 10, 26, 19, 42))
    assert env.q("SELECT COUNT(*) n FROM cards WHERE kind='trust'")[0]["n"] == 1         # lands Monday evening, exactly
