package app.runsolo.core.record

import app.runsolo.core.live.CueComposer
import app.runsolo.core.model.Units

/**
 * The spoken start briefing for a planned session (C2b A2, eng-review #1, #9, #17). The briefing is a TEMPLATE with
 * slots; this fills them on the device, in the runner's units, from the same values the in-run cues use, so no number
 * is ever written by a model or a server:
 *
 *  - `{session}`   the session's name as spoken ("Norwegian 4 by 4")
 *  - `{pace}`      the target work pace, [SummaryWords.pace] ("4 minutes 48 per kilometre", "7 minutes 45 per mile")
 *  - `{minutes}`   the planned duration ("40 minutes", "1 hour 30 minutes")
 *  - `{distance}`  the planned distance ("10.5 kilometres", "6.5 miles")
 *  - `{reps}`      the work reps WITH the noun ("four reps"); the template never adds a unit or the word reps
 *
 * An unknown slot, or a slot whose value the run does not have, rejects the whole template. The word cap is on the
 * RENDERED text: over it the template is rejected too, never truncated. The order is the coach's template, then the
 * app's own, then (the caller) `SummaryWords.start`.
 *
 * Speech path: the line goes out through `CuePlayer.announceSummary`, so it has no 16-word cue cap, is exempt from the
 * `TalkBudget` yet resets its last-spoke clock, and every step and "go" cue queues behind it (P0, never dropped).
 */
object StartBriefing {
    /** Words, counted on the rendered text (about 15 s at the TTS rate). Matches the server's cap (`briefing.py` WORD_CAP). */
    const val MAX_WORDS = 40

    /** What the slots speak. A null value means the run does not have it. */
    data class Slots(
        val session: String? = null,
        val paceSecPerKm: Double? = null,
        val minutes: Int? = null,
        val distanceM: Double? = null,
        val reps: Int? = null,
    )

    private val SLOT = Regex("""\{([A-Za-z_]+)\}""")
    private val SPACES = Regex("\\s+")

    private val REP_WORDS = listOf(
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    )

    /**
     * `{reps}` for the run being recorded: the work steps of its spec ([specReps], what it will really do: the plan's
     * reps change by week and the runner may edit them after picking), the config's count only when the run has none.
     */
    fun repsFor(specReps: Int?, configReps: Int?): Int? = specReps?.takeIf { it > 0 } ?: configReps

    /** "four reps", "one rep", "24 reps"; null for a count that is not positive. */
    fun repsWords(n: Int): String? = when {
        n <= 0 -> null
        n == 1 -> "one rep"
        n <= REP_WORDS.size -> "${REP_WORDS[n - 1]} reps"
        else -> "$n reps"
    }

    /** [template] with every slot spoken, or null: an unknown slot, a slot with no value, leftover braces or nothing left. */
    fun render(template: String, slots: Slots, units: Units): String? {
        val miles = units == Units.mi
        var bad = false
        val filled = SLOT.replace(template) { m ->
            val spoken: String? = when (m.groupValues[1]) {
                "session" -> slots.session?.takeIf { s -> s.any { it.isLetterOrDigit() } }?.let { SummaryWords.speakable(it) }
                "pace" -> slots.paceSecPerKm?.let { SummaryWords.pace(it, units) }
                "minutes" -> slots.minutes?.takeIf { it > 0 }?.let { SummaryWords.duration(it * 60_000L, seconds = false) }
                "distance" -> slots.distanceM?.takeIf { it > 0 && it.isFinite() }?.let { SummaryWords.distance(it, miles, hundredths = false) }
                "reps" -> slots.reps?.let { repsWords(it) }
                else -> null
            }
            if (spoken == null) bad = true
            spoken ?: ""
        }
        if (bad || '{' in filled || '}' in filled) return null
        return filled.trim().replace(SPACES, " ").takeIf { it.isNotEmpty() }
    }

    /**
     * The briefing to speak: the first of [primary] (the coach's) and [fallback] (the app's own) that renders within
     * [MAX_WORDS]; null when neither does (or neither is there), and the caller speaks `SummaryWords.start`.
     */
    fun line(primary: String?, fallback: String?, slots: Slots, units: Units): String? {
        for (t in listOf(primary, fallback)) {
            if (t.isNullOrBlank()) continue
            val text = render(t, slots, units) ?: continue
            if (CueComposer.words(text) <= MAX_WORDS) return text
        }
        return null
    }
}

/**
 * "The start line was spoken for this run", persisted (the recorder's prefs hold [load] and [store]): a restored,
 * resumed or replayed session never speaks its start again, even in a process that no longer knows it already did.
 */
class StartSpoken(private val load: () -> String?, private val store: (String) -> Unit) {
    /** True the first time for [runId] (and records it); false when it was already spoken. */
    fun claim(runId: String): Boolean {
        if (load() == runId) return false
        store(runId)
        return true
    }
}
