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
        ("Quicker again", "{delta} s/km faster than your last similar run over {km} km. The legs are paying you back."),
        ("Faster legs", "{delta} s/km quicker than last time. The week is working."),
        ("A step up", "{km} km, {delta} s/km faster than last time. That is a real gain."),
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
        ("Behind a touch", "{delta} s/km slower than your last similar run over {km} km. A single run, not a trend."),
        ("Quiet legs", "{delta} s/km slower than last time. Look at sleep and the week before the run."),
        ("Not today", "{km} km, {delta} s/km slower than last time. Easy does it."),
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
        ("New best", "{time} for {km} km. A new {pb} at {pace}/km. Enjoy it, then go easy tomorrow."),
        ("PB", "{time}. That is a new {pb}, {pace}/km. It's yours."),
        ("Personal best", "{time} over {km} km, a new {pb}. The training is working."),
        ("You did it", "{time}. New {pb} at {pace}/km. Don't read the splits for a bit, just have a beer."),
        ("Best yet", "{time} for {km} km, your best. {pace}/km. Fair play."),
        ("Record", "{time}, a new {pb}. {pace}/km all the way. Take the win."),
        ("Quickest yet", "{time} at {pace}/km. New {pb}. This is what the quiet weeks were for."),
        ("PB, mate", "{time} for {km} km and a new {pb}. Sweet as."),
        ("New high", "{time}, {pace}/km. That's a new {pb}. Write the date down."),
        ("That's a PB", "{time} over {km} km. New {pb}. Rest up before you get greedy."),
    ],
    "pb_other": [
        ("New best", "{pb}: {km} km at {pace}/km. Enjoy it, then go easy tomorrow."),
        ("PB", "{pb} at {pace}/km. It's yours."),
        ("Personal best", "{pb}, {km} km at {pace}/km. The training is working."),
        ("You did it", "New {pb}. {pace}/km. Have a beer."),
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
    "interval_baseline": [
        ("Session logged", "{session_line}: {reps} reps at {work_pace}/km work pace. That is your marker for this session."),
        ("Work pace set", "{work_pace}/km across {reps} reps in your {session_line}. Next time gets compared to it."),
        ("First on the board", "{session_line}, {reps} reps, {work_pace}/km on the hard bits. Repeat it and we can measure."),
        ("Marker down", "{reps} reps at {work_pace}/km. That is the work pace to beat in your {session_line}."),
        ("Baseline in", "{session_line} done at {work_pace}/km work pace over {reps} reps. Don't race it, repeat it."),
        ("Your yardstick", "{work_pace}/km on the work reps of your {session_line}. Recoveries do not count against you."),
    ],
    "interval_work": [
        ("Session done", "{session_line}: {reps} reps at {work_pace}/km work pace. That is the quality work."),
        ("Reps ticked", "{reps} reps at {work_pace}/km in your {session_line}. Easy tomorrow."),
        ("Worked", "{work_pace}/km on the hard reps of your {session_line}. {reps} of them, done."),
        ("The hard bit", "{reps} reps, {work_pace}/km. Your {session_line} is in the bank."),
        ("Versus last time", "{delta} s/km {cmp_dir} than your last time, {work_pace}/km across {reps} reps."),
        ("Against last time", "{session_line} at {work_pace}/km work pace, {delta} s/km {cmp_dir} than last time."),
        ("Work pace", "{work_pace}/km over {reps} reps. That is {delta} s/km {cmp_dir} than your last go."),
        ("Same session, same yardstick", "{reps} reps at {work_pace}/km work pace. Judged on the reps, not the jog between."),
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
    "trail_easy": [
        ("Easy trail run", "{km} km of trail at an easy effort. Pace means little off-road."),
        ("Easy on the trails", "{min} minutes of easy running on trail. Good for the legs and the head."),
        ("Gentle trail", "An easy trail run, {km} km. Nothing to prove out there."),
        ("Trail, kept easy", "{km} km on trail, easy. That is the whole idea."),
    ],
    "trail_tempo": [
        ("Tempo on the trail", "{km} km of tempo on trail. Judge it by effort, not pace."),
        ("Trail tempo", "A tempo run off-road, {min} minutes of steady work on uneven ground."),
        ("Working the trail", "{km} km of tempo effort on trail. Go by feel."),
        ("Tempo, trail style", "{min} minutes of tempo on rough ground. Honest work."),
    ],
    "trail_long": [
        ("Long trail run", "{km} km on trail. Time on feet counts for more than pace."),
        ("Big day on the trail", "{min} minutes out on trail. That is the week's long run done."),
        ("Long and rough", "{km} km of long trail running. Eat, drink, sit down."),
        ("Trail distance", "{km} km off-road, and the engine is bigger for it."),
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
    "plan_week": [
        "This run is {why}.",
        "You're in {why}.",
        "Plan check: {why}.",
        "{why}, and you showed up.",
        "That run sits in {why}.",
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
        "{n} runs on the board.",
        "{n} runs logged since you joined.",
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
        "Sunrise run {n}.",
        "{n} sunrise runs now.",
        "Sunrise run {n}. Worth the alarm.",
        "Up before the sun again. Sunrise run {n}.",
    ],
    "zone2_week": [
        "{z2_min} min in {zname} this week so far.",
        "{zname} this week: {z2_min} min. That's the base-building zone.",
        "{z2_min} minutes of easy aerobic running this week.",
        "You have {z2_min} min of {zname} banked this week.",
    ],
    "feel_echo": [
        "You called {weekday} hard at an easy pace. {cause} Keep the easy runs easy.",
        "{weekday} felt hard at an easy pace. {cause} Worth keeping an eye on.",
        "You rated {weekday} hard. {cause} Go by feel again today.",
        "Hard on {weekday} at an easy pace. {cause} Noted.",
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
    "recap_first_full": [
        ("First full week", "{runs_txt}, {km} km, {min} min. Last week was only a few days, so there is nothing fair to compare yet. {moment}"),
        ("Full week logged", "{km} km over {runs_txt}. Your first week was a part week, so this is the real starting line. {moment}"),
        ("Starting line", "{runs_txt} for {km} km. No comparison with a part week. Next week we can. {moment}"),
        ("A whole week", "{min} minutes and {km} km. The first full week, so next week has something to be measured against. {moment}"),
    ],
    "recap_first": [
        ("First week", "{runs_txt}, {km} km, {min} min. That's the starting line for the weekly picture. {moment}"),
        ("First week logged", "{km} km over {runs_txt}. Next week we can compare. {moment}"),
        ("On the board", "{runs_txt} for {km} km. Good start. {moment}"),
        ("Starting point", "{km} km in {min} min. Baseline for the weeks to come. {moment}"),
        ("First recap", "{runs_txt}, {km} km. Nothing to compare yet. {moment}"),
        ("Week logged", "{min} minutes and {km} km. A fine first picture. {moment}"),
    ],
    # The month poster (the 1st, for the month just ended). Totals only: the picture adds each run's day, type and
    # distance from the stored rows, and nothing the runner has not already sent.
    "recap_month": [
        ("{month} in runs", "{runs_txt}, {km} km, {hours_txt} on the move."),
        ("{month} done", "{km} km over {runs_txt} in {month}, about {hours_txt} out there."),
        ("The month in numbers", "{month}: {km} km, {runs_txt}, {hours_txt} of running."),
        ("{month} wrapped", "{runs_txt} and {km} km in {month}, {hours_txt} on the move."),
        ("Last month", "{month} came to {km} km across {runs_txt}, about {hours_txt} of running."),
        ("Month check", "{km} km in {month}, over {runs_txt}. {hours_txt} on the move."),
    ],
}

# Suggestions name the session: {session} is "easy 7 km", "tempo 8 km" or "long run 16 km", {start} is
# "around 6:30". The reason (load, a hard run, weather, plan, gap, how the last run felt) is the clause.
SUGGESTIONS: dict[str, list[tuple[str, str]]] = {
    "sugg_easy_load": [
        ("For tomorrow", "Load is high. Tomorrow: {session}, or a rest day."),
        ("Back off", "You've stacked a lot lately. Tomorrow: {session}, nothing more."),
        ("Light day", "Load is high, so tomorrow is {session} at a chat pace, or rest."),
        ("Ease off", "Load says easy. {session} tomorrow, {start}."),
        ("Easy tomorrow", "Your load is high. Tomorrow: {session} or a day off."),
        ("Pull the reins", "High load right now. Keep tomorrow to {session}."),
        ("Rest is training", "Load is high. {session} tomorrow, or skip it and rest."),
        ("Go gentle", "Too much load lately. Tomorrow: {session}, {start}."),
    ],
    "sugg_recover": [
        ("For tomorrow", "Your last run was hard, {hours_txt} ago. Tomorrow: {session}."),
        ("Recover", "{hours_txt} since a hard run. {session} tomorrow lets it land."),
        ("Tomorrow", "Hard session {hours_txt} back. Tomorrow: {session}, {start}."),
        ("Soak it up", "That hard run was {hours_txt} ago. Go with {session} tomorrow."),
        ("Let it land", "Hard work {hours_txt} ago. Tomorrow is {session} or a rest."),
        ("Slow tomorrow", "Last run was hard, {hours_txt} ago. Tomorrow: {session}. Don't pile on."),
        ("Easy day", "{hours_txt} since your hard run. Tomorrow: {session}, {start}."),
        ("Take it easy", "After a hard run {hours_txt} ago, {session} tomorrow pays off."),
    ],
    "sugg_gap": [
        ("Quality tomorrow?", "It has been {gap_txt} since your last hard session. Tomorrow: {session}, {start}."),
        ("Time for some pace", "{gap_txt} without a hard run. Tomorrow: {session}."),
        ("Tomorrow's the day", "Last hard session was {gap_txt} ago. {session} tomorrow, {start}."),
        ("Sharpen up", "{gap_txt} since you pushed. Tomorrow: {session}, with some bite."),
        ("Something spicy", "No hard run for {gap_txt}. Tomorrow works for {session}."),
        ("Mix it up", "{gap_txt} since the last hard session. Add pace tomorrow: {session}."),
        ("Your call", "{gap_txt} since you last ran hard. Tomorrow is a fair day for {session}."),
        ("A bit of quality", "It's been {gap_txt}. {session} tomorrow keeps you sharp."),
    ],
    "sugg_plan_long": [
        ("Long run due", "Race is {weeks_txt} away and your last long run was {gap_txt} ago. Tomorrow: {session}, {start}."),
        ("Plan says long", "{weeks_txt} to the race, {gap_txt} since the last long run. Do {session} tomorrow."),
        ("Tomorrow: long", "{gap_txt} since a long run, race in {weeks_txt}. {session} tomorrow, {start}."),
        ("Keep the long run", "With {weeks_txt} to go, {session} tomorrow keeps the plan honest."),
        ("Long run tomorrow?", "Race day is {weeks_txt} out. Last long run was {gap_txt} back. Go {session} tomorrow."),
        ("For the plan", "{weeks_txt} to race, {gap_txt} since the long run. Tomorrow: {session}."),
        ("Distance day", "Plan wants a long run: {gap_txt} since the last, race in {weeks_txt}. {session}, {start}."),
        ("Stay on plan", "{weeks_txt} out from the race. Time for {session} tomorrow."),
    ],
    # Tomorrow is a planned session in the app's block. {session} is the plan's own size ("easy 6 km", "long run 14 km",
    # "quality session"); {why} is "week 3 of 4 of your plan". Weather and gap reasons never replace it.
    "sugg_plan_session": [
        ("Plan for tomorrow", "Tomorrow's planned session: {session}, {start}. That is {why}."),
        ("On the plan", "{session} is next on your plan, {start}. It's {why}."),
        ("Tomorrow: the plan", "Plan says {session} tomorrow, {start}. You're in {why}."),
        ("Next session", "Next up: {session} tomorrow, {start}. It comes from {why}."),
        ("Stay on plan", "{session} tomorrow keeps you on track. That's {why}."),
        ("Planned day", "Tomorrow is a planned day: {session}, {start}. Part of {why}."),
        ("Your plan says", "In {why}, tomorrow is {session}, {start}."),
        ("Tomorrow", "{session} tomorrow, {start}. It's in {why}."),
    ],
    "sugg_weather_heat": [
        ("Beat the heat", "Tomorrow: {session}, start {start}. It'll be {temp} degrees at {fc_at}, so go early."),
        ("Early start", "{temp} degrees forecast at {fc_at} tomorrow. {session}, before the sun is high."),
        ("Hot tomorrow", "{temp} degrees at {fc_at}. Keep it to {session}, carry water, start {start}."),
        ("Go early", "Forecast {temp} degrees. {session} tomorrow, and be done early."),
        ("Warm day coming", "Tomorrow looks like {temp} degrees. {session}, {start}, and expect slow."),
        ("Cooler is better", "{temp} degrees by {fc_at}. Move tomorrow's run early: {session}."),
        ("Mind the heat", "Forecast {temp} degrees. {session} tomorrow, by effort not pace."),
        ("Dawn run", "{temp} degrees tomorrow. {session} at first light, {start}."),
    ],
    "sugg_weather_wet": [
        ("Wet tomorrow", "{rain}% chance of rain tomorrow. {session}, {start}, before it arrives."),
        ("Rain's coming", "Forecast has {rain}% rain. Run {session} early, {start}."),
        ("Soggy forecast", "{rain}% rain forecast. Tomorrow: {session} near home, decent shoes."),
        ("Dodge the rain", "{rain}% rain tomorrow. {session}, {start}, or swap it indoors."),
        ("Might get wet", "{rain}% chance of a soaking. {session} on a short loop, {start}."),
        ("Wet day", "Forecast {rain}% rain. {session}, close to home."),
        ("Beat the weather", "{rain}% rain tomorrow. Get {session} done early, {start}."),
        ("Showers", "Tomorrow shows {rain}% rain. {session}, then a dry change of clothes."),
    ],
    "sugg_weather_good": [
        ("Good day for it", "Forecast {temp} degrees and {rain}% rain at {fc_at} tomorrow. {session} suits it, {start}."),
        ("Nice window", "{temp} degrees and little rain tomorrow. Do {session}, {start}."),
        ("Pick tomorrow", "Tomorrow: {session}. {temp} degrees, {rain}% rain, and {gap_txt} since your last hard run."),
        ("Weather's on your side", "{temp} degrees and only {rain}% rain. {session} tomorrow, {start}."),
        ("Conditions are right", "{temp} degrees at {fc_at}, {rain}% rain. Tomorrow: {session}."),
        ("Cracker of a day", "Forecast {temp} degrees, {rain}% rain. {session}, {start}. {gap_txt} since the last hard session."),
        ("Mild and dry", "{temp} degrees, {rain}% rain. {session} tomorrow, {start}."),
        ("Make the most", "{temp} degrees with {rain}% rain. {session} tomorrow, {start}."),
    ],
    "sugg_feel": [
        ("Keep it easy", "You called {weekday} hard at an easy pace. {cause} Tomorrow: {session}, {start}."),
        ("Noted", "{weekday} felt hard at an easy pace. {cause} {session} tomorrow, nothing more."),
        ("You said hard", "You rated {weekday} hard. {cause} Keep tomorrow to {session}."),
        ("Listen to that", "Hard on an easy {weekday} run. {cause} Tomorrow: {session}, {start}."),
        ("Easy again", "{weekday} felt hard at an easy pace. {cause} Stay with {session} tomorrow."),
        ("Back it off", "You called {weekday} hard. {cause} {session} tomorrow, {start}."),
        ("Go gentle", "{weekday} was hard for an easy run. {cause} Tomorrow: {session}."),
        ("Your legs said so", "You tapped hard on {weekday}. {cause} Tomorrow: {session}, {start}."),
    ],
    # Shown instead of any quality or long-run nudge while a recent note carries a niggle/sore/injury/tired/sick word.
    # Never mentions the note, so the text says nothing about what the runner wrote.
    "sugg_soft": [
        ("Easy does it", "Keep tomorrow gentle: {session}, or a rest day if that's the better call."),
        ("Go easy", "Nothing hard for now. {session} tomorrow, or rest if the legs say so."),
        ("Look after yourself", "Tomorrow: {session} at an easy effort, {start}. Skipping it is fine too."),
        ("Light day", "Take it light. {session} tomorrow, and stop early if anything grumbles."),
        ("Rest is allowed", "A rest day is a fair answer tomorrow. If you go, make it {session}."),
        ("Soft landing", "Keep the effort low. {session} tomorrow, {start}, nothing sharp."),
        ("No rush", "No need to chase anything. {session} tomorrow, easy, or take the day off."),
        ("Keep it small", "Tomorrow can be small: {session}, {start}. Easy or nothing."),
    ],
    "sugg_after_hard": [
        ("For tomorrow", "That was a hard run. Tomorrow: {session}."),
        ("Recover", "Hard work today. Tomorrow: {session}, nothing sharp."),
        ("Easy next", "After a session like that, go {session} tomorrow."),
        ("Soak it up", "Hard session done. Tomorrow: {session} or a rest day."),
        ("Back off tomorrow", "You earned an easy day. {session} tomorrow."),
        ("Let it land", "That was a hard run. Tomorrow: {session}."),
        ("Slow tomorrow", "Hard today means slow tomorrow: {session}."),
        ("Next up: easy", "Hard effort today. Tomorrow: {session}, {start}."),
    ],
    "sugg_gap_week": [
        ("This week", "It has been {gap_txt} since your last hard session. This week: {session}."),
        ("Quality this week?", "{gap_txt} without a hard run. Fit in {session} this week."),
        ("Add some pace", "Last hard session was {gap_txt} ago. Do {session} this week."),
        ("Sharpen up", "{gap_txt} since you pushed. This week: {session}, with some bite."),
        ("Time for harder work", "It's been {gap_txt}. Pick a day this week for {session}."),
        ("Mix it up", "{gap_txt} since the last hard session. This week, add {session}."),
        ("Your call", "{gap_txt} since you last ran hard. {session} this week is a fair ask."),
        ("A bit of quality", "{gap_txt} since you pushed. {session} this week keeps you sharp."),
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
