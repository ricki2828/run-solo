"""The Run Supreme voice: a dry, honest coach. Few words, one real number, a little Kiwi humour.

Every variant is (headline, body) with named slots. Numbers only ever arrive through slots, which
the facts layer fills from the run data (eng-review B4), so a template may not contain a digit or a
spelled-out number. `render` picks a variant that was not used in the last 30 days.

The LLM writer gets these as style exemplars (slots left as {placeholders}); the template fallback
uses them directly.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime, timedelta
from string import Formatter
from typing import Mapping, Sequence

NO_REPEAT_DAYS = 30

# situation -> [(headline, body)]
SITUATIONS: dict[str, list[tuple[str, str]]] = {
    "faster": [
        ("Faster", "{delta} s/km quicker than last time, at {pace}/km. The legs turned up."),
        ("Quicker", "{pace}/km over {km} km, {delta} s/km better than your last similar run. Take it."),
        ("Faster, properly", "You took {delta} s/km off. {km} km at {pace}/km. No notes."),
        ("Moving well", "{pace}/km, which is {delta} s/km faster than last time. Not a fluke if it happens again."),
        ("That's quicker", "{km} km at {pace}/km. {delta} s/km faster than last time. Sweet as."),
        ("Pace is up", "{delta} s/km faster over {km} km. Whatever you did this week, keep doing it."),
        ("Faster today", "Last time was slower by {delta} s/km. Today you ran {pace}/km. Good trade."),
        ("Ticking along nicely", "{pace}/km for {km} km. That is {delta} s/km quicker than last time."),
        ("Quick", "{delta} s/km faster, {pace}/km. Fitness is doing its thing."),
        ("Better pace", "{km} km at {pace}/km, {delta} s/km faster than your last similar run. Not bad at all."),
    ],
    "holding": [
        ("Holding steady", "{pace}/km over {km} km. Level with last time. Boring is the point."),
        ("Same again", "{km} km at {pace}/km, right where you were. Consistency is quietly working."),
        ("Level", "No real change at {pace}/km. That is what steady fitness looks like."),
        ("Steady as", "{pace}/km for {km} km. Holding is fine. Most weeks are holding weeks."),
        ("Holding", "{km} km in {min} min. Same shape as last time. Nothing to fix."),
        ("On the line", "{pace}/km again. You are banking the boring kilometres, which is how this works."),
        ("Neither up nor down", "{km} km at {pace}/km. Flat, in a good way."),
        ("Just right", "{pace}/km, level with your last run. {km} km in the bank."),
        ("Cruising", "{min} minutes, {km} km, {pace}/km. Right on form."),
    ],
    "slower": [
        ("Slower today", "{pace}/km, {delta} s/km down on last time. Happens. Look at the week, not the run."),
        ("Off the pace", "{delta} s/km slower over {km} km. No spin, just a slower day."),
        ("Yeah nah", "Legs were heavy. {pace}/km, {delta} s/km slower. It's a single run."),
        ("A slower day", "{km} km at {pace}/km. That is {delta} s/km behind last time. Still counts."),
        ("Not the quick day", "{delta} s/km slower. Sleep, food and stress all show up in pace. Check those first."),
        ("Slower, fair enough", "{pace}/km. Down {delta} s/km. You still turned up, which is the hard part."),
        ("Pace dipped", "{delta} s/km slower than your last similar run. A single data point is not a trend."),
        ("Heavy legs", "{km} km in {min} min, {delta} s/km slower. Easy day tomorrow and see."),
        ("Down a touch", "{pace}/km today, {delta} s/km slower. Honest answer: not your best, and that's allowed."),
        ("Slow day", "{delta} s/km off last time. Log it and move on."),
    ],
    "slower_heat": [
        ("Heat tax", "{temp} degrees at the start. {pace}/km is {delta} s/km slower, and the heat is the likely reason."),
        ("Slower, and it's hot", "{temp} degrees, {delta} s/km down. Heat costs pace. The effort was probably fine."),
        ("Hot day", "{km} km in {temp} degrees. Slower by {delta} s/km, and the weather is a fair suspect."),
        ("Cooked a bit", "{pace}/km in {temp} degrees. Slower by {delta} s/km. Don't chase it."),
        ("Sweaty", "{delta} s/km slower, {temp} degrees out. Judge the effort, not the pace."),
        ("Heat slowdown", "{temp} degrees and {delta} s/km slower. Heat usually does that. Go earlier next time."),
        ("Too warm for speed", "At {temp} degrees, {pace}/km is a decent result. Down {delta} s/km, probably the heat."),
        ("Soft pace, hard conditions", "{temp} degrees and {km} km done. A {delta} s/km slowdown fits the conditions."),
        ("Humid and slow", "{delta} s/km slower at {temp} degrees. Drink more, expect less, run anyway."),
    ],
    "slower_hills": [
        ("Hills", "{climb} m of climb, so {pace}/km is {delta} s/km slower and about right."),
        ("Up and down", "{km} km with {climb} m of climb. The {delta} s/km slowdown is probably the hills."),
        ("Slower on the climbs", "{climb} m up. {pace}/km is fair for that. Down {delta} s/km, and earned."),
        ("Hilly", "{delta} s/km off your usual pace, with {climb} m of climb. No worries."),
        ("Lumpy", "{climb} m of climb in {km} km. Slower by {delta} s/km. Hills do that."),
        ("Climb tax", "{pace}/km over {climb} m of up. Pace is the wrong scoreboard here."),
        ("Slower, but steep", "{delta} s/km slower and {climb} m higher. That's a fair swap."),
        ("Hills happened", "{km} km, {climb} m of climb, {pace}/km. Slower by {delta} s/km and stronger for it."),
        ("Good grunt", "{climb} m of climb costs pace. You paid {delta} s/km."),
    ],
    "slower_load": [
        ("Carrying a load", "Training load is up, and {pace}/km is {delta} s/km slower. Tired legs, not lost fitness."),
        ("Tired legs", "{delta} s/km slower with load high. The fix is boring: an easy day."),
        ("Slower, loaded", "{km} km at {pace}/km, {delta} s/km down. Load is high, so that tracks."),
        ("Load is showing", "{delta} s/km slower than last time. You have stacked a lot of work lately."),
        ("Heavy week", "{pace}/km, {delta} s/km slower. After this much load, I'd expect it."),
        ("Pay-back day", "Slower by {delta} s/km, load high. Rest is part of the plan, not a break from it."),
        ("Running on fumes", "{km} km at {pace}/km, {delta} s/km slower. Load says ease off."),
        ("Absorbing", "{delta} s/km down with high load. The work lands when you back off."),
        ("Fatigue, not form", "Pace is {delta} s/km slower. Load is high. Not the same thing as getting worse."),
    ],
    "baseline": [
        ("Baseline set", "{km} km at {pace}/km. That is your starting line. Everything from here gets compared to it."),
        ("First marker", "Baseline is in: {pace}/km over {km} km. The next run tells us something."),
        ("Line in the sand", "{pace}/km for {km} km is the number to beat. No pressure."),
        ("Starting point", "Now we have a baseline: {pace}/km. Run it again in a week or so."),
        ("We have a number", "{km} km at {pace}/km. That's the yardstick."),
        ("Benchmark done", "Baseline set at {pace}/km. Don't race it. Just repeat it."),
        ("On the board", "{pace}/km over {km} km. Good, now we can measure something."),
        ("Marker down", "Your baseline is {pace}/km for {km} km. Easy to improve on and easy to be honest about."),
        ("First reading", "{km} km, {min} min, {pace}/km. That's the start of the graph."),
    ],
    "pb": [
        ("New best", "{pb}. {pace}/km over {km} km. Enjoy it. Then go easy tomorrow."),
        ("PB", "{pb} at {pace}/km. That is yours."),
        ("Personal best", "{pb}: {km} km at {pace}/km. The training is working."),
        ("You did it", "New {pb}. {pace}/km. Don't read the splits for a bit, just have a beer."),
        ("Best yet", "{pb} for {km} km at {pace}/km. Fair play."),
        ("Record", "{pb}. {min} minutes, {pace}/km. Take the win."),
        ("Quickest yet", "{pb} at {pace}/km. This is what the quiet weeks were for."),
        ("PB, mate", "{pb}, {km} km in {min} min. Sweet as."),
        ("New high", "{pb} at {pace}/km. Write the date down."),
        ("That's a PB", "{km} km at {pace}/km and a new {pb}. Rest up before you get greedy."),
    ],
    "easy_right": [
        ("Easy, done right", "{km} km at {pace}/km, mostly low zones. This is the run that makes the hard ones work."),
        ("Properly easy", "{min} minutes of easy running, {pace}/km. Slow is the skill here."),
        ("Easy does it", "{km} km, {pace}/km, no heroics. Exactly what an easy day should be."),
        ("Quiet run", "{min} min at an easy effort. The bank account of fitness got a deposit."),
        ("Conversation pace", "{km} km at {pace}/km. You could have chatted the whole way. Good."),
        ("Nailed the easy", "{pace}/km kept honest. {km} km of base building."),
        ("Slow on purpose", "{km} km at {pace}/km. Easy runs only work when they are easy. This run was."),
        ("Base work", "{min} minutes at {pace}/km. Unglamorous and useful."),
        ("Easy as", "{km} km, nothing to prove. {pace}/km is the right pace for today."),
        ("Gentle", "{km} km in {min} min. Easy days are how the hard days get quick."),
    ],
    "intervals": [
        ("Intervals done", "{hard_min} minutes in the hard zones across {km} km. That is the quality work."),
        ("Session in the bag", "{km} km with {hard_min} min of real effort. Eat something."),
        ("Hard reps", "{hard_min} min at the sharp end. Easy tomorrow, no arguments."),
        ("Speed work", "{km} km total, {hard_min} min hard. This is where the pace comes from."),
        ("The hard bit", "You spent {hard_min} minutes in the red zones. Nobody enjoys it, everybody needs it."),
        ("Sharp", "{hard_min} min of hard running in a {min} minute session. Job done."),
        ("Reps ticked", "{km} km, {hard_min} min of effort. Keep the next day boring."),
        ("Quality day", "{hard_min} minutes hard. That's a proper session."),
        ("Worked", "{min} minutes, {hard_min} of them hard. You'll feel that tomorrow."),
    ],
    "long": [
        ("Long run", "{km} km in {min} minutes. The long run builds the engine. Refuel properly."),
        ("Big run done", "{km} km. {min} min on your feet. That's the week's main job finished."),
        ("Long and steady", "{km} km at {pace}/km. Patience paid."),
        ("Distance logged", "{km} km, {min} minutes. Nothing flash, just miles."),
        ("Time on feet", "{min} minutes out there. {km} km in the legs."),
        ("Long haul", "{km} km done. Eat, drink, sit down."),
        ("The long run", "{km} km at {pace}/km. This is the run that makes the race feel shorter."),
        ("Proper distance", "{min} min and {km} km. Easy tomorrow."),
        ("Endurance", "{km} km at a steady {pace}/km. Quiet strength."),
    ],
    "trail": [
        ("Trail day", "{km} km with {climb} m of climb. Pace doesn't mean much out there."),
        ("Off the road", "{climb} m up over {km} km. Good for the legs and the head."),
        ("Trail run", "{km} km, {climb} m of climb, {min} minutes. Go by effort, not pace."),
        ("Up and over", "{climb} m of climb in {km} km. That's a proper wee grunt."),
        ("Dirt and hills", "{km} km at {pace}/km, which is fast for {climb} m of up."),
        ("Rough ground", "{climb} m climbed. Ankles and calves got a workout."),
        ("Trail miles", "{km} km of trail in {min} min. Harder than the pace says."),
        ("Scenic grunt", "{climb} m up over {km} km. Worth it for the view, hopefully."),
        ("Climber", "{climb} m of climb today. Your pace chart will look odd, ignore it."),
    ],
    "steady": [
        ("Run logged", "{km} km in {min} minutes at {pace}/km. In the bank."),
        ("Done", "{pace}/km over {km} km. Another run counted."),
        ("Ticked off", "{km} km, {min} min. Keeps the streak of showing up alive."),
        ("Good enough", "{km} km at {pace}/km. Not every run needs a story."),
        ("In the log", "{min} minutes, {km} km. Fine."),
        ("Solid", "{pace}/km for {km} km. That's a run."),
        ("Another run", "{km} km at {pace}/km. The count goes up."),
        ("Showed up", "{min} min, {km} km. That's most of the job."),
        ("Quiet effort", "{km} km at {pace}/km. Nothing dramatic, nothing wrong."),
    ],
    "tempo": [
        ("Tempo done", "{km} km, {hard_min} min at the hard end. Comfortably uncomfortable."),
        ("Threshold work", "{hard_min} min in the upper zones. That's what tempo is for."),
        ("Steady push", "{km} km at {pace}/km with {hard_min} min of effort. Good session."),
        ("Held it", "{hard_min} min working. Pace was {pace}/km."),
        ("Tempo ticked", "{km} km, {min} min. Hard enough to count."),
        ("Lean in", "{hard_min} minutes at the sharp end. Easy day next."),
        ("Raised the bar", "{km} km at {pace}/km, with {hard_min} min of it hard."),
        ("Proper effort", "{hard_min} min of work in {min}. Do the cool-down walk."),
        ("Nice and spicy", "{km} km, {hard_min} min hard. Tomorrow is easy."),
    ],
    "back_after_break": [
        ("Back at it", "{gap_txt} since your last run, and today {km} km. Start was the hard part."),
        ("Welcome back", "{gap_txt} off. {km} km at {pace}/km. Don't try to catch up in a week."),
        ("Return run", "First run in {gap_txt}: {km} km. Easy does it for a bit."),
        ("Good to see you", "{km} km after {gap_txt}. Nobody is keeping score on the break."),
        ("Back on the road", "{gap_txt} gap, then {km} km at {pace}/km. Build slowly."),
        ("Restart", "You left {gap_txt}. Today {min} minutes. That's a fine restart."),
        ("Break's over", "{km} km after {gap_txt}. Keep the next few easy."),
        ("Welcome back, legs", "{gap_txt} and then {km} km. Expect some stiffness."),
        ("Starting again", "After {gap_txt}, {km} km is plenty. Keep the first week slow."),
    ],
    "missed_week": [
        ("Quiet week", "No runs logged this week. Last run was {gap_txt} ago. Life happens."),
        ("Nothing this week", "Nothing logged, {gap_txt} since the last run. A short easy run gets it moving."),
        ("Blank week", "Nothing logged for {gap_txt}. No lecture. A short easy run when you can."),
        ("Week off", "{gap_txt} since your last run. Rest is fine. So is starting again."),
        ("Rest week, apparently", "No runs this week and {gap_txt} since the last. Pick a day and keep it small."),
        ("Missed a week", "Nothing on the board this week. Last run {gap_txt} ago. Tomorrow's a decent day to fix it."),
        ("Hasn't happened", "{gap_txt} without a run. A short easy run puts you back."),
        ("Pause", "No runs for {gap_txt}. Fitness takes weeks to fade. You're fine."),
        ("Empty log", "Nothing this week, {gap_txt} since your last. Small restart beats a big plan."),
    ],
}

# Touches: one short line appended to a card. Same slot rules as above.
TOUCHES: dict[str, list[str]] = {
    "race_countdown": [
        "{weeks_txt} to race day.",
        "Race is {weeks_txt} away. The work now is mostly showing up.",
        "{weeks_txt} out. Nothing you do this week changes much, except skipping it.",
        "Countdown: {weeks_txt}.",
        "{weeks_txt} to go. Keep the easy days easy.",
    ],
    "race_month": [
        "Race month is {months_txt} away.",
        "Your race is {months_txt} out. Plenty of time to be patient.",
        "{months_txt} to race month. Build, don't rush.",
        "Race month in {months_txt}. Steady does it.",
    ],
    "last_year": [
        "This time last year: {ly_pace}/km. Today {pace}/km.",
        "A year ago this week you ran {ly_km} km at {ly_pace}/km.",
        "Last year, same week: {ly_pace}/km. You are {ly_cmp_s} s/km {ly_dir} now.",
        "A year back it was {ly_pace}/km over {ly_km} km.",
    ],
    "place": [
        "{ord} time on {place}.",
        "That's the {ord} run at {place}. You know it by now.",
        "{place} again, {ord} go.",
        "{ord} lap of {place}. Familiar ground.",
        "{ord} time out at {place}. Pace there was {place_pace}/km.",
        "Regular spot: {place}, {ord} run.",
    ],
    "streak": [
        "{streak} weeks in a row hitting your target. Quietly good.",
        "That makes {streak} straight weeks on target.",
        "{streak} weeks running without a gap. Don't make a big deal of it.",
        "Week-streak: {streak}. No fuss, just keep going.",
        "{streak} weeks on the trot. That's the habit forming.",
        "Still going: {streak} weeks in a row.",
    ],
    "milestone_runs": [
        "Run number {n} logged here.",
        "{n} runs on the board. That's a lot of mornings.",
        "That's {n} runs since you started with me. Fair effort over time.",
        "Milestone: {n} runs.",
    ],
    "milestone_km": [
        "{total_km} km logged here in total.",
        "You've passed {total_km} km since you started with me.",
        "{total_km} km on the odometer. Not bad.",
        "Milestone: {total_km} km.",
    ],
    "best_month": [
        "Best month on record so far: {month_km} km.",
        "{month_km} km this month already, your biggest month here.",
        "Biggest month yet at {month_km} km, and it isn't over.",
        "{month_km} km this month beats any other month I have.",
    ],
    "year_best": [
        "Quickest of your {cnt} runs at this distance, {pace}/km.",
        "Best pace for this distance among {cnt} logged runs: {pace}/km.",
        "{pace}/km is your fastest of {cnt} runs at this distance.",
        "Top of the list for this distance, {cnt} runs deep, at {pace}/km.",
    ],
    "new_place": [
        "First run in {place}. New streets, same legs.",
        "{place} is new on your map.",
        "First time running in {place}. Good stuff.",
        "New spot: {place}. Hope the view's decent.",
    ],
    "sunrise": [
        "Sunrise run number {n} logged here.",
        "That's {n} sunrise runs logged here.",
        "{n} sunrise starts so far. Worth the alarm.",
        "Another dawn start, number {n}.",
    ],
    "zone2_week": [
        "{z2_min} min in {zname} this week so far.",
        "{zname} this week: {z2_min} min. That's the base-building zone.",
        "{z2_min} minutes of easy aerobic running this week.",
        "You have {z2_min} min of {zname} banked this week.",
    ],
    "comeback": [
        "Run {n} since the break, in {days_txt}. You're back.",
        "{n} runs in {days_txt} since you returned. Back in it.",
        "The comeback is real: {n} runs in {days_txt}.",
        "{n} runs back, {days_txt}. Nicely done.",
    ],
}

RECAPS: dict[str, list[tuple[str, str]]] = {
    "recap_up": [
        ("Week in review", "{runs_txt}, {km} km, {min} min. That is {delta_km} km more than last week. {moment}"),
        ("Bigger week", "{km} km over {runs_txt}, up {delta_km} km on last week. {moment}"),
        ("Up on last week", "{runs_txt} for {km} km. {delta_km} km more than before. {moment}"),
        ("Good week", "{km} km in {min} minutes, {delta_km} km up. {moment}"),
        ("Stepping up", "{runs_txt}, {km} km, {delta_km} km more than last week. Hold here before adding more. {moment}"),
        ("Solid week", "{min} minutes and {km} km, up {delta_km} km. {moment}"),
    ],
    "recap_down": [
        ("Week in review", "{runs_txt}, {km} km, {delta_km} km down on last week. Lighter weeks are useful. {moment}"),
        ("Lighter week", "{km} km over {runs_txt}, {delta_km} km less than before. {moment}"),
        ("A bit less", "{runs_txt} for {km} km. Down {delta_km} km, and that's fine. {moment}"),
        ("Down week", "{km} km in {min} min, {delta_km} km under last week. {moment}"),
        ("Easing", "{runs_txt}, {km} km. {delta_km} km down. Recovery counts. {moment}"),
        ("Quieter week", "{min} minutes and {km} km, {delta_km} km less than last week. {moment}"),
    ],
    "recap_flat": [
        ("Week in review", "{runs_txt}, {km} km, {min} min. Level with last week. {moment}"),
        ("Steady week", "{km} km over {runs_txt}, much the same as last week. {moment}"),
        ("Same again", "{runs_txt} for {km} km. Consistent. {moment}"),
        ("Held the line", "{km} km in {min} minutes, level with last week. {moment}"),
        ("Right on pattern", "{runs_txt}, {km} km, no big swing. {moment}"),
        ("Even", "{min} minutes and {km} km. Even keel. {moment}"),
    ],
    "recap_return": [
        ("Back in the week", "{runs_txt}, {km} km, {min} min, after a quiet week. {moment}"),
        ("Week after the break", "{km} km over {runs_txt}. Good restart. {moment}"),
        ("Getting going", "{runs_txt} for {km} km after a week off. Build from here. {moment}"),
        ("Moving again", "{km} km in {min} minutes after a gap. {moment}"),
        ("Restart week", "{runs_txt}, {km} km. The quiet week is behind you. {moment}"),
        ("Back on track", "{min} minutes and {km} km over {runs_txt}. Keep it steady. {moment}"),
    ],
    "recap_first": [
        ("First week", "{runs_txt}, {km} km, {min} min. That's the starting line for the weekly picture. {moment}"),
        ("First week logged", "{km} km over {runs_txt}. Next week we can compare. {moment}"),
        ("On the board", "{runs_txt} for {km} km. Good start. {moment}"),
        ("Starting point", "{km} km in {min} min. Baseline for the weeks to come. {moment}"),
        ("First recap", "{runs_txt}, {km} km. Nothing to compare yet. {moment}"),
        ("Week logged", "{min} minutes and {km} km. A fine first picture. {moment}"),
    ],
}

# Evening-before suggestions. Each needs a reason, so the situation names it.
SUGGESTIONS: dict[str, list[tuple[str, str]]] = {
    "sugg_easy_load": [
        ("For tomorrow", "Load is high. Easy or rest tomorrow suits you."),
        ("Tomorrow", "You've stacked a lot lately. Keep tomorrow easy."),
        ("Back off", "Load is high, so tomorrow wants an easy run or a day off."),
        ("Light day", "Load is stacked up. I'd go easy tomorrow."),
        ("Easy tomorrow", "Your load is high. Tomorrow is for recovering."),
        ("Ease off", "Load says easy. {km} km at a chat pace would do it."),
        ("Rest is training", "Load is high. A rest day tomorrow wouldn't hurt."),
        ("Pull the reins", "High load right now. Tomorrow, nothing hard."),
    ],
    "sugg_recover": [
        ("For tomorrow", "Your last run was hard, {hours_txt} ago. Keep tomorrow easy."),
        ("Recover", "{hours_txt} since a hard run. Easy tomorrow lets it land."),
        ("Tomorrow", "Hard session {hours_txt} back. An easy {km} km tomorrow does the job."),
        ("Soak it up", "That hard run was {hours_txt} ago. Go easy tomorrow."),
        ("Let it land", "Hard work {hours_txt} ago. Tomorrow is a jog or a rest."),
        ("Slow tomorrow", "Last run was hard, {hours_txt} ago. Don't pile on."),
        ("Easy day", "{hours_txt} since your hard run. Tomorrow, keep it gentle."),
        ("Take it easy", "After a hard run {hours_txt} ago, easy tomorrow pays off."),
    ],
    "sugg_gap": [
        ("Quality tomorrow?", "It has been {gap_txt} since your last hard session. Tomorrow suits a hard run."),
        ("Time for some pace", "{gap_txt} without a hard run. Tomorrow could be the day."),
        ("Tomorrow's the day", "Last hard session was {gap_txt} ago. A short session tomorrow."),
        ("Sharpen up", "{gap_txt} since you pushed. Tomorrow, a session with some bite."),
        ("Something spicy", "No hard run for {gap_txt}. Tomorrow works for a tempo."),
        ("Mix it up", "{gap_txt} since the last hard session. Add a bit of pace tomorrow."),
        ("Your call", "{gap_txt} since you last ran hard. Tomorrow is a fair day for it."),
        ("A bit of quality", "It's been {gap_txt}. A hard session tomorrow keeps you sharp."),
    ],
    "sugg_after_hard": [
        ("For tomorrow", "That was a hard run. Easy tomorrow lets it land."),
        ("Recover", "Hard work today. Keep tomorrow gentle."),
        ("Easy next", "After a session like that, go easy next."),
        ("Soak it up", "Hard session done. A jog or a rest day is next."),
        ("Back off tomorrow", "You earned an easy day after that."),
        ("Let it land", "That was a hard run. Tomorrow, nothing sharp."),
        ("Slow tomorrow", "Hard today means slow tomorrow."),
        ("Next up: easy", "Hard effort today. Next run, keep it easy."),
    ],
    "sugg_gap_week": [
        ("This week", "It has been {gap_txt} since your last hard session. A hard session this week fits."),
        ("Quality this week?", "{gap_txt} without a hard run. This week's a good time."),
        ("Add some pace", "Last hard session was {gap_txt} ago. Fit a session in this week."),
        ("Sharpen up", "{gap_txt} since you pushed. A session with some bite this week."),
        ("Time for harder work", "It's been {gap_txt}. Pick a day this week for a tempo."),
        ("Mix it up", "{gap_txt} since the last hard session. This week, add a bit of pace."),
        ("Your call", "{gap_txt} since you last ran hard. This week is a fair time for it."),
        ("A bit of quality", "It's been {gap_txt} since you pushed. A hard session this week keeps you sharp."),
    ],
    "sugg_plan_long": [
        ("Long run due", "Race is {weeks_txt} away and your last long run was {gap_txt} ago. Tomorrow suits a long run."),
        ("Plan says long", "{weeks_txt} to the race. Last long run: {gap_txt} ago. Time for another."),
        ("Tomorrow: long", "{gap_txt} since a long run, race in {weeks_txt}. Tomorrow works."),
        ("Keep the long run", "With {weeks_txt} to go, a long run tomorrow keeps the plan honest."),
        ("Long run tomorrow?", "Race day is {weeks_txt} out. Your last long run was {gap_txt} back."),
        ("For the plan", "{weeks_txt} to race, {gap_txt} since the long run. Do a long run tomorrow."),
        ("Distance day", "Plan wants a long run: {gap_txt} since the last, race in {weeks_txt}."),
        ("Stay on plan", "{weeks_txt} out from the race. Time for a long run tomorrow."),
    ],
    "sugg_weather_heat": [
        ("Beat the heat", "Tomorrow morning is forecast at {temp} degrees. Go early or keep it short."),
        ("Early start", "{temp} degrees forecast tomorrow. Run at dawn, not at noon."),
        ("Hot tomorrow", "It'll be {temp} degrees. Easy pace, carry water, or run early."),
        ("Heat warning-ish", "Forecast {temp} degrees for tomorrow. Slower is expected, and fine."),
        ("Go early", "{temp} degrees tomorrow. Before the sun is up is the smart window."),
        ("Warm day coming", "Tomorrow looks like {temp} degrees. Shorter and easier."),
        ("Cooler is better", "{temp} degrees forecast. Move the run to early morning."),
        ("Mind the heat", "Forecast {temp} degrees tomorrow. Aim for effort, not pace."),
    ],
    "sugg_weather_wet": [
        ("Wet tomorrow", "{rain}% chance of rain tomorrow. Take the run early or keep it short."),
        ("Rain's coming", "Forecast has {rain}% rain. Grab the window before it arrives."),
        ("Soggy forecast", "{rain}% chance of rain. Shorter run, decent shoes."),
        ("Dodge the rain", "{rain}% rain forecast tomorrow. Run early if you can."),
        ("Might get wet", "{rain}% chance of a soaking. Plan a short loop near home."),
        ("Wet day", "Forecast {rain}% rain. Easy, close to home."),
        ("Umbrella weather", "{rain}% rain tomorrow. Go early or go indoors."),
        ("Showers", "Tomorrow shows {rain}% rain. Short and sharp, or a day off."),
    ],
    "sugg_weather_good": [
        ("Good day for it", "Forecast {temp} degrees and dry tomorrow. A fine day for a longer run."),
        ("Nice window", "{temp} degrees and dry tomorrow. Make it a good run."),
        ("Weather's on your side", "Tomorrow: {temp} degrees, only {rain}% rain. Best day this week for a session."),
        ("Cracker of a day", "Forecast {temp} degrees, dry. Do the quality run tomorrow."),
        ("Conditions are right", "{temp} degrees tomorrow and dry. Perfect for something harder."),
        ("Pick tomorrow", "A dry {temp} degrees forecast. Good day for the long run."),
        ("Mild and dry", "{temp} degrees, {rain}% rain. Tomorrow's the pick of the week."),
        ("Make the most", "Forecast {temp} degrees with little rain. Don't waste it."),
    ],
}

# Short question intros for the weekly question, so the question itself is not always dull.
ACK: dict[str, list[str]] = {
    "answer": ["Noted.", "Got it.", "Cheers, that helps.", "Sweet, noted."],
    "skip": ["Okay, nothing more this week.", "No worries, I'll leave it."],
}


def table_for(situation: str) -> dict[str, list[tuple[str, str]]]:
    if situation in SUGGESTIONS:
        return SUGGESTIONS
    return RECAPS if situation in RECAPS else SITUATIONS


def slots_of(template: str) -> set[str]:
    return {f for _, f, _, _ in Formatter().parse(template) if f}


@dataclass(frozen=True)
class Rendered:
    situation: str
    variant_id: str
    headline: str
    body: str
    allowed: str  # the slot values that produced the numbers: the B4 source of truth for this line


def _pick(options: Sequence[int], used: Mapping[str, datetime], prefix: str, now: datetime,
          seed: str) -> int:
    cut = now - timedelta(days=NO_REPEAT_DAYS)
    fresh = [i for i in options if used.get(f"{prefix}:{i}") is None or used[f"{prefix}:{i}"] < cut]
    pool = fresh or sorted(options, key=lambda i: used.get(f"{prefix}:{i}") or datetime.min.replace(tzinfo=now.tzinfo))[:1]
    h = int(hashlib.sha256(f"{seed}:{prefix}".encode()).hexdigest(), 16)
    return pool[h % len(pool)]


def render(situation: str, slots: Mapping[str, str], used: Mapping[str, datetime], now: datetime,
           seed: str) -> Rendered | None:
    """Fill a variant that was not used in the last 30 days and whose slots are all available."""
    variants = table_for(situation)[situation]
    ok = [i for i, (h, b) in enumerate(variants) if slots_of(h) | slots_of(b) <= set(slots)]
    if not ok:
        return None
    i = _pick(ok, used, situation, now, seed)
    h, b = variants[i]
    keys = slots_of(h) | slots_of(b)
    return Rendered(situation, f"{situation}:{i}", h.format(**slots), b.format(**slots),
                    " ".join(str(slots[k]) for k in sorted(keys)))


def render_touch(kind: str, slots: Mapping[str, str], used: Mapping[str, datetime], now: datetime,
                 seed: str) -> tuple[str, str, str] | None:
    """-> (variant_id, text, allowed)."""
    variants = TOUCHES[kind]
    ok = [i for i, t in enumerate(variants) if slots_of(t) <= set(slots)]
    if not ok:
        return None
    i = _pick(ok, used, f"touch_{kind}", now, seed)
    keys = slots_of(variants[i])
    return f"touch_{kind}:{i}", variants[i].format(**slots), " ".join(str(slots[k]) for k in sorted(keys))


def exemplars(situation: str, n: int = 3, seed: str = "") -> list[str]:
    """Style exemplars for the LLM: slots stay as {placeholders}, so no stray numbers can leak."""
    variants = table_for(situation).get(situation) or SITUATIONS["steady"]
    start = int(hashlib.sha256(seed.encode()).hexdigest(), 16) % len(variants) if seed else 0
    return [f"{variants[(start + k) % len(variants)][0]} | {variants[(start + k) % len(variants)][1]}"
            for k in range(min(n, len(variants)))]
