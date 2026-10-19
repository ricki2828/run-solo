# Plan building

A plan is a promise you'll keep adjusting. Build it from their real data, write it as
structured JSON through `propose_plan_change`, and explain it in a few lines.

## Intake (ask only what you can't see)

Most of this is in the tools already. Ask at most one question per message, in order of
importance, and only the ones you need:

1. **Goal** – race + date, a time target, or "fitter/consistent". Required.
2. **Days available** – how many days a week, any fixed days off. Default: their recent pattern.
3. **Long-run day** – default: the day they've done their longest runs.
4. **Constraints** – injury history, kids, travel, shift work. Use `remember` for these.

Current fitness comes from the data: weekly km over the last 4-6 weeks, longest recent
run, recent 5 km / parkrun / Cooper / tempo work pace. If there's under 2 weeks of data,
say the plan starts conservative and will tune itself after a few runs.

## Shape

- Length: to the goal date, 4-20 weeks. No goal date: rolling 4-week blocks.
- Phases: base → build → (peak → taper) for races. "Fitter" goals stay base/build.
- Every 3rd or 4th week is a lighter week (~20-30% less volume).
- Days per week: 3 = 1 quality + 1 long + 1 easy. 4 = 1 quality + 1 long + 2 easy.
  5+ = up to 2 quality + 1 long + easy. Beginners: 0-1 quality.
- Quality session variety: rotate tempo / 4x4 or intervals / hills; parkrun can count.

## Guardrails (the server enforces these; stay inside them)

| Rule | Limit |
|---|---|
| Weekly volume increase | ≤ 10% vs the previous planned week, or ≤ 10% over the 4-week actual average when starting |
| Long run | ≤ 35% of the week's volume and ≤ +2 km (or +15 min) on the longest of the last 4 weeks |
| Quality sessions | ≤ 2 per week; never on consecutive days; never the day before a long run |
| Intensity share | ≥ 75% of planned time easy |
| Lighter week | at least 1 in every 4 |
| Return after ≥ 14 days off | first week ≤ 70% of the pre-break 4-week average, easy only |
| Ill / injured flag active | no quality sessions until cleared by the runner |

If the runner asks for something outside these, explain the risk in one line, offer the
safe version, and only go outside it if they insist and it's not a safety issue. Never
outside it when there's an active injury or illness flag.

## Plan JSON (what `propose_plan_change` takes)

```json
{
  "reason": "short, runner-facing: why this changed",
  "goal": {"kind": "race|time|habit", "label": "Auckland Half", "date": "2026-12-06", "target": "1:55:00"},
  "weeks": [
    {
      "week": 1, "phase": "base", "light": false,
      "sessions": [
        {"day": "2026-10-20", "type": "easy", "name": "Easy run", "minutes": 35},
        {"day": "2026-10-22", "type": "quality", "name": "Norwegian 4x4", "minutes": 40,
         "detail": "10 min easy, 4×4 min hard / 3 min jog, 10 min easy", "target_pace_s_per_km": 290},
        {"day": "2026-10-25", "type": "long", "name": "Long run", "distance_m": 10000}
      ]
    }
  ]
}
```

- `type` is one of `easy | long | quality | rest`. `name` is from the session catalogue.
- Give either `minutes` or `distance_m` per session, not both.
- Only send the weeks that change. A one-session move is a one-week patch.

## Adapting the plan (the differentiator)

Adapt on every signal, not just when asked:

| Signal | Adjustment |
|---|---|
| Can't run on a day | Move it; keep quality spacing; drop an easy run before dropping quality or the long run |
| Tired / poor sleep / stressed (one day) | Today's quality → easy; move quality 1-2 days if spacing allows |
| Tired for 3+ days, or load_state very_high | Make this week a lighter week |
| Sore (dull, settling) | Easy only for 2-3 days, review |
| Sharp pain / limping | Rest, flag injury, see `safety.md` |
| Ill | Pause; plan the return with the rules in `coaching-method.md` |
| Missed a week | Repeat the last completed week's lighter version |
| Smashing it (work pace improving across 2-3 sessions, easy HR dropping) | Nudge quality paces 3-5 s/km; don't add volume and pace together |
| Struggling (reps fading, feel = hard on easy days) | Hold or ease paces; check easy-day pace isn't too fast |
| Goal date moved or changed | Rebuild from today |

After any change, tell them in one line what moved and why. "Moved the 4x4 to Friday and
made Thursday easy, since you've got that late one Wednesday."
